"""Authenticated Gateway transport for the native projection queue."""

import argparse
import base64
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from contracts import AuthorizedOperation, IncidentRejected, OperationKey
from host import Host, TmuxTransport, cli_adapter, reject_permission_dialog
from progress_bridge import transfer_host_projection, transfer_projection
from spool import canonical, incident_identity

DEFINITIVE_INCIDENT_REJECTIONS = (
    "Managed task incident conflict",
    "Managed task generation mismatch",
    "Managed task producer mismatch",
    "Managed task not found",
    "Managed task host does not own this CLI assignment",
    "Managed task incident key or digest is invalid",
    "Managed task host incident is invalid",
    "Managed host incident identity is invalid",
    "invalid managed host incident params",
    "Managed task assignment is invalid",
)


def _rejection(response):
    """The Gateway's own words for a failed call: error.message from the JSON on stdout, else stderr."""
    try:
        parsed = json.loads(response.stdout)
    except json.JSONDecodeError:
        parsed = None
    error = parsed.get("error") if isinstance(parsed, dict) else None
    message = error.get("message") if isinstance(error, dict) else None
    if not isinstance(message, str) or not message.strip():
        message = response.stderr or response.stdout or f"exit {response.returncode}"
    return " ".join(message.split())[:300]


class GatewayProjectionClient:
    def __init__(self, openclaw_bin, host_id, expected_url=None):
        if not host_id or not isinstance(host_id, str):
            raise ValueError("publisher host required")
        self.openclaw_bin = str(openclaw_bin)
        self.host_id = host_id
        self.expected_url = expected_url

    def _call(self, method, params, *, nullable=False, definitive=()):
        serialized = json.dumps(params, sort_keys=True, separators=(",", ":"))
        command = [self.openclaw_bin, "gateway", "call", method,
                   "--json", "--timeout", "30000"]
        if method.startswith("managedTasks.host."):
            command.append("--device-auth")
        if self.expected_url:
            command.extend(("--expect-url", self.expected_url))
        pending = None
        try:
            if len(serialized.encode()) > 100_000:
                descriptor, pending = tempfile.mkstemp(prefix="agent-work-gateway-", suffix=".json")
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    stream.write(serialized)
                    stream.flush()
                    os.fsync(stream.fileno())
                command.extend(("--params-file", pending))
            else:
                command.extend(("--params", serialized))
            response = subprocess.run(command, capture_output=True, text=True, timeout=35)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RuntimeError("native projection Gateway unavailable") from exc
        finally:
            if pending is not None:
                os.unlink(pending)
        if response.returncode:
            if definitive:
                try:
                    parsed = json.loads(response.stdout)
                except json.JSONDecodeError:
                    parsed = None
                if (isinstance(parsed, dict) and parsed.get("ok") is False
                        and isinstance(parsed.get("error"), dict)
                        and parsed["error"].get("type") == "gateway_request_error"
                        and parsed["error"].get("message") in definitive):
                    raise IncidentRejected(parsed["error"].get("message"))
            raise RuntimeError(f"native projection Gateway rejected request {method}: {_rejection(response)}")
        try:
            parsed = json.loads(response.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError("native projection Gateway returned invalid JSON") from exc
        if parsed is None and nullable:
            return None
        if not isinstance(parsed, dict):
            raise RuntimeError("native projection Gateway returned invalid response")
        return parsed

    def list_pending(self, after_task_id=None, limit=100):
        if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
            raise ValueError("projection page limit invalid")
        params = {"publisherHostId": self.host_id, "limit": limit}
        if after_task_id is not None:
            params["afterTaskId"] = after_task_id
        response = self._call("managedTasks.projections.list", params)
        rows = response.get("projections")
        if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
            raise RuntimeError("native projection Gateway returned invalid page")
        return rows

    def ack(self, receipt):
        response = self._call("managedTasks.projections.ack",
                              {"publisherHostId": self.host_id, "receipt": receipt})
        if response != receipt:
            raise RuntimeError("native projection Gateway ACK differs from queue receipt")
        return response

    def report_host_result(self, result, artifact_bytes):
        if not isinstance(result, dict) or result.get("hostId") != self.host_id:
            raise ValueError("host report identity mismatch")
        if (not isinstance(artifact_bytes, bytes) or len(artifact_bytes) > 10 * 1024 * 1024
                or hashlib.sha256(artifact_bytes).hexdigest() != result.get("digest")):
            raise ValueError("host artifact digest or size mismatch")
        result_id = hashlib.sha256(canonical(result).encode()).hexdigest()
        return self._call("managedTasks.host.report", {
            "hostId": self.host_id, "resultId": result_id, "result": result,
            "artifactBase64": base64.b64encode(artifact_bytes).decode("ascii"),
        })

    def close_host(self, assignment, state, reason, evidence_digest):
        if not isinstance(assignment, dict) or assignment.get("hostId") != self.host_id:
            raise ValueError("host closure identity mismatch")
        fields = ("taskId", "instanceId", "producerId", "capability")
        if any(not assignment.get(field) for field in fields):
            raise ValueError("host closure assignment incomplete")
        generation = assignment["generation"]
        if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
            raise ValueError("host closure generation must be positive")
        if state not in ("CleanupPending", "AbsenceVerified", "ReleasedAdopted"):
            raise ValueError("host closure state invalid")
        if (state == "CleanupPending" and not reason) or len(reason) > 4096:
            raise ValueError("host closure reason invalid")
        if not re.fullmatch(r"[0-9a-f]{64}", evidence_digest or ""):
            raise ValueError("host closure evidence digest invalid")
        params = {"hostId": self.host_id, "instanceId": assignment["instanceId"],
                  "capability": {"taskId": assignment["taskId"], "generation": generation,
                                 "producerId": assignment["producerId"],
                                 "token": assignment["capability"]},
                  "state": state, "reason": reason, "evidenceDigest": evidence_digest}
        if assignment.get("adapterId"):
            params["adapterId"] = assignment["adapterId"]
        receipt = self._call("managedTasks.host.close", params)
        if (not isinstance(receipt, dict) or receipt.get("taskId") != assignment["taskId"]
                or receipt.get("generation") != generation or receipt.get("state") != state
                or receipt.get("evidenceDigest") != evidence_digest):
            raise RuntimeError("native host closure receipt identity mismatch")
        return receipt

    def host_cancellation(self, assignment):
        """R's cancellation id for the task this host holds, or None while it is not cancelled."""
        if not isinstance(assignment, dict) or assignment.get("hostId") != self.host_id:
            raise ValueError("host cancellation identity mismatch")
        fields = ("taskId", "instanceId", "producerId", "capability", "adapterId")
        if any(not assignment.get(field) for field in fields):
            raise ValueError("host cancellation assignment incomplete")
        generation = assignment["generation"]
        if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
            raise ValueError("host cancellation generation must be positive")
        response = self._call("managedTasks.host.cancellation", {
            "hostId": self.host_id, "adapterId": assignment["adapterId"],
            "instanceId": assignment["instanceId"],
            "capability": {"taskId": assignment["taskId"], "generation": generation,
                           "producerId": assignment["producerId"], "token": assignment["capability"]}})
        cancellation_id = response.get("cancellationId")
        if (response.get("taskId") != assignment["taskId"] or response.get("generation") != generation
                or not (cancellation_id is None or (isinstance(cancellation_id, str) and cancellation_id))):
            raise RuntimeError("native host cancellation identity mismatch")
        return cancellation_id

    def report_host_incident(self, assignment, incident):
        if not isinstance(assignment, dict) or assignment.get("hostId") != self.host_id:
            raise ValueError("host incident identity mismatch")
        fields = ("taskId", "instanceId", "producerId", "capability")
        if any(not assignment.get(field) for field in fields):
            raise ValueError("host incident assignment incomplete")
        if not assignment.get("adapterId"):
            raise ValueError("host incident adapter required")
        generation = assignment["generation"]
        if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
            raise ValueError("host incident generation must be positive")
        incident_key, incident_digest = incident_identity(generation, incident)
        params = {"hostId": self.host_id, "adapterId": assignment["adapterId"],
                  "instanceId": assignment["instanceId"],
                  "capability": {"taskId": assignment["taskId"], "generation": generation,
                                 "producerId": assignment["producerId"],
                                 "token": assignment["capability"]},
                  "incident": incident}
        receipt = self._call("managedTasks.host.incident", params,
                             definitive=DEFINITIVE_INCIDENT_REJECTIONS)
        expected = {"taskId": assignment["taskId"], "generation": generation,
                    "incidentKey": incident_key, "incidentDigest": incident_digest}
        if receipt != expected:
            raise RuntimeError("native host incident receipt identity mismatch")
        return receipt

    def admit_host(self, assignment):
        if not isinstance(assignment, dict) or assignment.get("hostId") != self.host_id:
            raise ValueError("host admission identity mismatch")
        fields = ("taskId", "generation", "instanceId", "producerId", "capability", "claimId")
        if any(not assignment.get(field) for field in fields):
            raise ValueError("host admission assignment incomplete")
        params = {"hostId": self.host_id, "instanceId": assignment["instanceId"],
                  "claimId": assignment["claimId"],
                  "capability": {"taskId": assignment["taskId"],
                                 "generation": assignment["generation"],
                                 "producerId": assignment["producerId"],
                                 "token": assignment["capability"]}}
        if assignment.get("adapterId"):
            params["adapterId"] = assignment["adapterId"]
        receipt = self._call("managedTasks.host.admit", params)
        expected = {"state": "host-admitted", "claimId": assignment["claimId"],
                    "hostId": self.host_id, "instanceId": assignment["instanceId"],
                    "generation": assignment["generation"]}
        if receipt != expected:
            raise RuntimeError("native host admission receipt identity mismatch")
        return receipt

    def claim_host(self, adapter_id, instance_id):
        if not adapter_id or not instance_id:
            raise ValueError("host claim adapter and instance required")
        return self._call("managedTasks.host.claim", {
            "hostId": self.host_id, "adapterId": adapter_id, "instanceId": instance_id,
        }, nullable=True)

    def brief_chunk(self, adapter_id, instance_id, task_id, claim_id, offset, length):
        if not isinstance(offset, int) or offset < 0 or not 1 <= length <= 4096:
            raise ValueError("host brief range invalid")
        return self._call("managedTasks.host.brief", {
            "hostId": self.host_id, "adapterId": adapter_id, "instanceId": instance_id,
            "taskId": task_id, "claimId": claim_id, "offset": offset, "length": length,
        })


def _brief_to_workspace(client, claim, workspace_root):
    reference = claim["assignment"]["instructionRef"]
    digest = reference["digest"]
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("host brief digest invalid")
    if reference["ref"] != "artifact:" + digest[7:]:
        raise ValueError("host brief reference is not portable")
    root = Path(workspace_root)
    if root.is_symlink():
        raise ValueError("host workspace root is a symlink")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    briefs = root / "managed-briefs"
    if briefs.is_symlink():
        raise ValueError("host brief directory is a symlink")
    briefs.mkdir(mode=0o700, exist_ok=True)
    target = briefs / digest[7:]
    if target.is_symlink():
        raise ValueError("host brief target is a symlink")
    if target.exists():
        data = target.read_bytes()
        if not data or len(data) > 1024 * 1024 or hashlib.sha256(data).hexdigest() != digest[7:]:
            raise ValueError("host brief cache digest mismatch")
        return target
    data = bytearray()
    size = None
    while size is None or len(data) < size:
        offset = len(data)
        chunk = client.brief_chunk(claim["adapterId"], claim["instanceId"], claim["taskId"],
                                   claim["claimId"], offset, 4096)
        if (not isinstance(chunk, dict) or chunk.get("taskId") != claim["taskId"]
                or chunk.get("claimId") != claim["claimId"] or chunk.get("digest") != digest
                or chunk.get("offset") != offset or not isinstance(chunk.get("size"), int)
                or isinstance(chunk["size"], bool) or not 1 <= chunk["size"] <= 1024 * 1024
                or (size is not None and chunk["size"] != size)):
            raise ValueError("host brief response identity mismatch")
        size = chunk["size"]
        try:
            raw = base64.b64decode(chunk["dataBase64"], validate=True)
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError("host brief chunk encoding invalid") from exc
        if not raw or len(raw) > 4096 or len(data) + len(raw) > size:
            raise ValueError("host brief chunk length invalid")
        data.extend(raw)
    if hashlib.sha256(data).hexdigest() != digest[7:]:
        raise ValueError("host brief digest mismatch")
    fd, pending = tempfile.mkstemp(prefix=".pending-", dir=briefs)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o400)
        try:
            os.link(pending, target)
        except FileExistsError:
            if hashlib.sha256(target.read_bytes()).hexdigest() != digest[7:]:
                raise ValueError("host brief cache digest mismatch")
        directory = os.open(briefs, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        os.unlink(pending)
    return target


def claim_cli_once(client, *, host, manager, adapter_id, instance_id, session,
                   workspace_root, deliver, coverage):
    """Deliver to an existing session; adopting it never grants permission to stop it."""
    if coverage.get("hostAdapterCoverage", {}).get(client.host_id, {}).get(adapter_id) != "certified":
        raise ValueError("host adapter route is not certified")
    if not manager.can_take(instance_id):
        return None
    claim = client.claim_host(adapter_id, instance_id)
    if claim is None:
        return None
    if not isinstance(claim, dict):
        raise ValueError("host claim response invalid")
    if not isinstance(claim.get("assignment"), dict):
        raise ValueError("host claim assignment invalid")
    target = claim["assignment"].get("target")
    capability = claim.get("capability")
    if (claim.get("hostId") != client.host_id or claim.get("adapterId") != adapter_id
            or claim.get("instanceId") != instance_id
            or target != {"kind": "cli", "hostId": client.host_id, "adapterId": adapter_id}
            or not isinstance(claim.get("taskId"), str) or not claim["taskId"]
            or not isinstance(claim.get("generation"), int) or isinstance(claim["generation"], bool)
            or claim["generation"] < 1 or not isinstance(claim.get("claimId"), str)
            or not claim["claimId"] or not isinstance(capability, dict)
            or capability.get("taskId") != claim["taskId"]
            or capability.get("generation") != claim["generation"]
            or capability.get("producerId") != adapter_id
            or not isinstance(capability.get("token"), str) or not capability["token"]):
        raise ValueError("host claim identity mismatch")
    assignment = claim["assignment"]
    if not isinstance(assignment.get("inputRevision"), dict) or not assignment.get("resultContract"):
        raise ValueError("host claim contract invalid")
    brief = _brief_to_workspace(client, claim, workspace_root)
    key = OperationKey(client.host_id, claim["taskId"], claim["generation"], instance_id)
    manager.reserve(key, session, "UserAdopted")
    if manager.begin_launch(key).launch_now:
        manager.mark(key)
    if manager.attach(key).state != "Running":
        raise RuntimeError("host resource identity is not running")
    operation = AuthorizedOperation(
        key=key, producer_id=adapter_id, capability=capability["token"], session=session,
        workspace_ref=str(Path(workspace_root)), brief_ref=str(brief),
        brief_digest=assignment["instructionRef"]["digest"][7:],
        input_revision=assignment["inputRevision"], result_contract=assignment["resultContract"],
        claim_id=claim["claimId"], adapter_id=adapter_id,
    )
    return host.apply(key, operation, deliver, client.admit_host)


def transfer_gateway_projections(client, *, evidence_root, progress_state_dir, progress_client, host=None):
    """Drain bounded pages; a lost response leaves the same native intent for retry."""
    processed = 0
    after_task_id = None
    for _ in range(100):
        rows = client.list_pending(after_task_id=after_task_id, limit=100)
        if not rows:
            return processed
        for row in rows:
            task_id = row.get("taskId")
            if not isinstance(task_id, str) or not task_id or (after_task_id and task_id <= after_task_id):
                raise RuntimeError("native projection Gateway page is unordered")
            operation_key = (host.operation_key_for(client.host_id, task_id, row.get("generation"))
                             if host is not None else None)
            if operation_key is None:
                transfer_projection(row, host_id=client.host_id, evidence_root=evidence_root,
                                    progress_state_dir=progress_state_dir,
                                    progress_client=progress_client, acknowledge_native=client.ack)
            else:
                transfer_host_projection(row, host=host, operation_key=operation_key,
                                         progress_state_dir=progress_state_dir,
                                         progress_client=progress_client, acknowledge_native=client.ack)
            processed += 1
            after_task_id = task_id
        if len(rows) < 100:
            return processed
    raise RuntimeError("native projection Gateway page limit exceeded")


def close_pass(client, *, host, cli_release=None, cli_cancel=None, cli_retry=None, close_host=None):
    """Report results, release acknowledged adopted sessions, release cancelled tasks, retry pending
    cleanups and send the closures to R. Claims, delivers and types nothing; the cancellation step alone
    may deny a cancelled task's permission dialog. Returns counts, the report error and the other errors."""
    receipts = []
    report_error = None
    try:
        receipts = host.flush(client.host_id, client.report_host_result)
    except (OSError, RuntimeError, ValueError) as exc:
        report_error = exc
    counts, errors = {}, []
    for name, step in (("released", cli_release), ("cancelled", cli_cancel), ("recovered", cli_retry)):
        if step is None:
            continue
        try:
            counts[name], step_errors = step()
        except (OSError, RuntimeError, ValueError) as exc:
            counts[name], step_errors = 0, [str(exc)]
        errors += step_errors
    try:
        counts["closed"], closure_errors = host.flush_closures(client.host_id, close_host or client.close_host)
    except (OSError, RuntimeError, ValueError) as exc:
        counts["closed"], closure_errors = 0, [str(exc)]
    return {"reported": len(receipts), **counts}, report_error, errors + closure_errors


def close_only(client, *, host, manager, reject_dialog):
    """One closing pass over a spool no host runs any more, for the instances its own rows name. Returns
    each resource before and after, and the closure receipts R sent back."""
    def resources():
        with host.spool.connection() as db:
            rows = db.execute("SELECT r.operation_id,r.task_id,r.instance_id,r.state,r.reason,o.status "
                              "FROM resources r LEFT JOIN operations o ON o.operation_id=r.operation_id "
                              "ORDER BY r.operation_id").fetchall()
        return {row["operation_id"]: dict(row) for row in rows}

    before = resources()
    receipts = []

    def close_host(*args):
        receipt = client.close_host(*args)
        receipts.append(receipt)
        return receipt

    counts, report_error, errors = close_pass(
        client, host=host, cli_release=manager.release_acknowledged,
        cli_cancel=lambda: manager.release_cancelled(client.host_cancellation, reject_dialog),
        cli_retry=manager.retry_cleanup, close_host=close_host)
    if report_error is not None:
        errors.insert(0, f"report failed: {report_error}")
    after = resources()
    return {"counts": counts, "errors": errors, "rClosures": receipts,
            "resources": [{"operationId": op_id, "taskId": row["task_id"], "instanceId": row["instance_id"],
                           "operation": row["status"],
                           "before": [before.get(op_id, {}).get("state"), before.get(op_id, {}).get("reason")],
                           "after": [row["state"], row["reason"]],
                           "lastSent": host.spool.closure_last(op_id)}
                          for op_id, row in after.items()]}


def pump_once(client, *, host, evidence_root, progress_state_dir, progress_client,
              cli_claim=None, cli_watch=None, cli_release=None, cli_cancel=None, cli_retry=None):
    """Settle closures (close_pass), detect silent CLI failures, claim authorized work, and drain
    projections in one code-only pass."""
    counts, report_error, errors = close_pass(client, host=host, cli_release=cli_release,
                                              cli_cancel=cli_cancel, cli_retry=cli_retry)
    detected = 0
    watch_errors = []
    if cli_watch is not None:
        try:
            detected = len(cli_watch())
        except (OSError, RuntimeError, ValueError) as exc:
            watch_errors = [str(exc)]
    incidents_sent = 0
    incident_errors = []
    try:
        incidents_sent, incident_errors = host.flush_incidents(
            client.host_id, client.report_host_incident)
    except (OSError, RuntimeError, ValueError) as exc:
        incident_errors = [str(exc)]
    claimed = None
    claim_error = None
    if cli_claim is not None:
        try:
            claimed = cli_claim()
        except (OSError, RuntimeError, ValueError) as exc:
            claim_error = exc
    transferred = transfer_gateway_projections(
        client, evidence_root=evidence_root, progress_state_dir=progress_state_dir,
        progress_client=progress_client, host=host,
    )
    if report_error is not None:
        raise report_error
    if claim_error is not None:
        raise claim_error
    errors += watch_errors + incident_errors
    if errors:
        raise RuntimeError("; ".join(errors))
    result = {**counts, "transferred": transferred, "incidents": incidents_sent}
    if cli_claim is not None:
        result["claimed"] = 1 if claimed is not None else 0
    if cli_watch is not None:
        result["detected"] = detected
    return result


def watch_pump(client, *, host, evidence_root, progress_state_dir, progress_client,
               stop_event, interval=1.0, cli_claim=None, cli_watch=None, cli_release=None, cli_cancel=None,
               cli_retry=None):
    """Poll with code; a failed pass leaves durable host and native work for retry."""
    if not 0 < interval <= 5:
        raise ValueError("poll interval must be between zero and five seconds")
    last_error = None
    while not stop_event.is_set():
        try:
            result = pump_once(
                client, host=host, evidence_root=evidence_root,
                progress_state_dir=progress_state_dir, progress_client=progress_client,
                cli_claim=cli_claim, cli_watch=cli_watch, cli_release=cli_release, cli_cancel=cli_cancel,
                cli_retry=cli_retry,
            )
        except (OSError, RuntimeError, ValueError) as exc:
            error = str(exc)
            if error != last_error:
                print("agent-work pump: " + error, file=sys.stderr, flush=True)
            last_error = error
        else:
            last_error = None
            if any(result.values()):
                print(json.dumps(result, sort_keys=True), flush=True)
        stop_event.wait(interval)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Transfer native task results to progress events")
    parser.add_argument("--openclaw-bin", required=True)
    parser.add_argument("--host-id", required=True)
    parser.add_argument("--expect-url", required=True)
    parser.add_argument("--evidence-root")
    parser.add_argument("--progress-state-dir")
    parser.add_argument("--progress-client")
    parser.add_argument("--host-state-dir")
    parser.add_argument("--claim-once", action="store_true")
    parser.add_argument("--cli-adapter-id")
    parser.add_argument("--cli-instance-id")
    parser.add_argument("--cli-session")
    parser.add_argument("--cli-workspace-root")
    parser.add_argument("--cli-tmux-socket")
    parser.add_argument("--cli-deadline-seconds", type=float)
    parser.add_argument("--tmux-bin", default="tmux")
    parser.add_argument("--flush-results", action="store_true")
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--close-only", action="store_true",
                        help="one closing pass over --host-state-dir, for the instances its rows name; never claims")
    args = parser.parse_args(argv)
    client = GatewayProjectionClient(args.openclaw_bin, args.host_id, args.expect_url)
    if args.close_only:
        if not all((args.host_state_dir, args.cli_adapter_id, args.cli_tmux_socket)):
            parser.error("--close-only requires --host-state-dir, --cli-adapter-id and --cli-tmux-socket")
        if (args.claim_once or args.watch or args.flush_results or args.cli_instance_id or args.cli_session
                or args.cli_workspace_root):
            parser.error("--close-only takes its instances from the spool and never claims")
        from resources import ResourceManager, TmuxBackend
        host = Host(args.host_id, args.host_state_dir)
        backend = TmuxBackend(args.tmux_bin, args.cli_tmux_socket)
        adapter = cli_adapter(args.cli_adapter_id)
        report = close_only(client, host=host, manager=ResourceManager(host.spool, args.host_id, backend),
                            reject_dialog=lambda identity: reject_permission_dialog(backend, identity, adapter))
        print(json.dumps(report, indent=2, sort_keys=True))
        return 1 if report["errors"] else 0
    cli_fields = (args.cli_adapter_id, args.cli_instance_id, args.cli_session,
                  args.cli_workspace_root, args.cli_tmux_socket)
    cli_claim = None
    cli_watch = None
    cli_release = None
    cli_cancel = None
    cli_retry = None
    if args.claim_once or any(cli_fields):
        if not all(cli_fields) or not args.host_state_dir:
            parser.error("CLI claim requires adapter, stable instance, session, workspace, socket and host state")
        from resources import ResourceManager, TmuxBackend, load_approval_pattern
        host = Host(args.host_id, args.host_state_dir)
        backend = TmuxBackend(args.tmux_bin, args.cli_tmux_socket)
        manager = ResourceManager(host.spool, args.host_id, backend)
        transport = TmuxTransport(args.tmux_bin, args.cli_tmux_socket, cli_adapter(args.cli_adapter_id))
        coverage_path = Path(__file__).resolve().parents[2] / "docs/evidence/agent-work/coverage.json"
        coverage = json.loads(coverage_path.read_text())
        cli_claim = lambda: claim_cli_once(
            client, host=host, manager=manager, adapter_id=args.cli_adapter_id,
            instance_id=args.cli_instance_id, session=args.cli_session,
            workspace_root=args.cli_workspace_root, deliver=transport.deliver,
            coverage=coverage,
        )

        cli_release = manager.release_acknowledged
        adapter = cli_adapter(args.cli_adapter_id)
        cli_cancel = lambda: manager.release_cancelled(
            client.host_cancellation, lambda identity: reject_permission_dialog(backend, identity, adapter))
        cli_retry = manager.retry_cleanup

        if args.cli_deadline_seconds is not None and not args.cli_deadline_seconds > 0:
            parser.error("--cli-deadline-seconds must be positive")

        approval = load_approval_pattern(Path(__file__).resolve().parents[1] / "mac/corrida/lib.sh")
        cli_watch = lambda: host.detect_silent_failures(
            args.host_id, manager.session_gone, now=time.time(),
            deadline_seconds=args.cli_deadline_seconds,
            prompt_identity=lambda key: manager.prompt_identity(key, approval))
    if args.claim_once:
        if args.watch or args.flush_results:
            parser.error("--claim-once excludes --watch and --flush-results")
        observation = cli_claim()
        print(json.dumps({"claimed": observation.status if observation else None}))
        return 0
    if args.watch:
        if args.flush_results or not args.host_state_dir:
            parser.error("--watch requires --host-state-dir and excludes --flush-results")
        if not all((args.evidence_root, args.progress_state_dir, args.progress_client)):
            parser.error("--watch requires evidence and progress paths")
        stop = threading.Event()
        old_term = signal.signal(signal.SIGTERM, lambda *_: stop.set())
        old_int = signal.signal(signal.SIGINT, lambda *_: stop.set())
        try:
            watch_pump(
                client, host=Host(args.host_id, args.host_state_dir),
                evidence_root=args.evidence_root, progress_state_dir=args.progress_state_dir,
                progress_client=args.progress_client, stop_event=stop,
                cli_claim=cli_claim, cli_watch=cli_watch, cli_release=cli_release, cli_cancel=cli_cancel,
                cli_retry=cli_retry,
            )
        finally:
            signal.signal(signal.SIGTERM, old_term)
            signal.signal(signal.SIGINT, old_int)
        return 0
    if args.flush_results:
        if not args.host_state_dir:
            parser.error("--flush-results requires --host-state-dir")
        host = Host(args.host_id, args.host_state_dir)
        reported, report_error = 0, None
        try:
            reported = len(host.flush(args.host_id, client.report_host_result))
        except (OSError, RuntimeError, ValueError) as exc:
            report_error = exc
        try:
            closed, closure_errors = host.flush_closures(args.host_id, client.close_host)
        except (OSError, RuntimeError, ValueError) as exc:
            closed, closure_errors = 0, [str(exc)]
        if report_error is not None:
            print(f"agent-work flush: {report_error}", file=sys.stderr, flush=True)
        for error in closure_errors:
            print(f"agent-work closure: {error}", file=sys.stderr, flush=True)
        print(json.dumps({"closed": closed, "reported": reported}))
        return 1 if report_error is not None or closure_errors else 0
    if not all((args.evidence_root, args.progress_state_dir, args.progress_client)):
        parser.error("projection transfer requires evidence and progress paths")
    count = transfer_gateway_projections(
        client, evidence_root=args.evidence_root, progress_state_dir=args.progress_state_dir,
        progress_client=args.progress_client,
        host=Host(args.host_id, args.host_state_dir) if args.host_state_dir else None,
    )
    print(json.dumps({"transferred": count}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
