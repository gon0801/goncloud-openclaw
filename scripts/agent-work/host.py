#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import hmac
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable

from contracts import AuthorizedOperation, HostObservation, IncidentRejected, OperationKey, ResultReceipt, operation_id
from spool import TERMINAL_STATES, Spool, atomic_json, canonical, closure_digest, incident_identity

MAX_ARTIFACT_BYTES = 10 * 1024 * 1024
RESULT_SCHEMA = "agent-work.result.v1"
SILENT_EPISODES = {"invalid-result": "invalid-result", "transport-unavailable": "session-closed",
                   "deadline-missed": "deadline"}
DIALOG_PASSES = 2
ACCEPT_SCHEMA = "agent-work.accept.v1"
UNACCEPTED_EPISODE = "delivery-unaccepted"
ACCEPT_BOUND = ("hostId", "taskId", "generation", "instanceId", "claimId")
MAX_ACCEPT_BYTES = 4096


def next_dialog_state(state: dict, observed: str) -> tuple[dict, bool]:
    dialog = dict(state)
    if observed == "":
        dialog["candidate"] = None
        dialog["seen"] = 0
        dialog["clean"] = min(dialog["clean"] + 1, DIALOG_PASSES)
        if dialog["clean"] >= DIALOG_PASSES:
            dialog["open_identity"] = None
        return dialog, False
    if observed == state["open_identity"]:
        dialog["clean"] = 0
        dialog["candidate"] = None
        dialog["seen"] = 0
        return dialog, False
    dialog["clean"] = 0
    dialog["seen"] = dialog["seen"] + 1 if observed == state["candidate"] else 1
    if dialog["seen"] < DIALOG_PASSES:
        dialog["candidate"] = observed
        return dialog, False
    dialog["open_identity"] = observed
    dialog["episode"] = dialog["episode"] + 1
    dialog["candidate"] = None
    dialog["seen"] = 0
    return dialog, True


def check_deadline(deadline_seconds: float | None) -> None:
    if deadline_seconds is not None and (isinstance(deadline_seconds, bool)
                                         or not isinstance(deadline_seconds, (int, float))
                                         or deadline_seconds <= 0):
        raise ValueError("deadline must be a positive number of seconds")


def read_acceptance(assignment: dict) -> bool:
    """True only for the CLI's own agent-work.accept.v1 bound to this assignment."""
    accept_ref = Path(assignment["acceptRef"])
    if accept_ref.is_symlink() or not accept_ref.exists():
        return False
    info = accept_ref.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_ACCEPT_BYTES:
        return False
    try:
        accept = json.loads(accept_ref.read_bytes().decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    if not isinstance(accept, dict) or set(accept) != {"schema", "capability", *ACCEPT_BOUND}:
        return False
    if accept["schema"] != ACCEPT_SCHEMA or not isinstance(accept["capability"], str):
        return False
    for field in ACCEPT_BOUND:
        if type(accept[field]) is not type(assignment[field]) or accept[field] != assignment[field]:
            return False
    return hmac.compare_digest(accept["capability"].encode("utf-8", "surrogatepass"),
                               assignment["capability"].encode("utf-8", "surrogatepass"))


def under(path: str, root: str) -> Path:
    try:
        resolved = Path(path).resolve(strict=True)
    except OSError as exc:
        raise ValueError("reference does not exist") from exc
    if not resolved.is_relative_to(Path(root).resolve(strict=True)) or not resolved.is_file():
        raise ValueError("reference outside authorized workspace")
    return resolved


class Host:
    def __init__(self, host_id: str, state_dir: Path):
        if not host_id:
            raise ValueError("hostId required")
        self.host_id = host_id
        self.state_dir = Path(state_dir)
        self.spool = Spool(self.state_dir, host_id)

    def _host(self, host_id: str) -> None:
        if host_id != self.host_id:
            raise ValueError("hostId mismatch")

    def _snapshot_path(self, op_id: str, result_id: str) -> Path:
        return self.state_dir / "artifacts" / op_id / f"{result_id}.bin"

    @staticmethod
    def _snapshot_bytes(path: Path, expected_digest: str) -> bytes:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        except FileNotFoundError:
            raise
        except OSError as exc:
            raise ValueError("artifact snapshot unavailable") from exc
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_ARTIFACT_BYTES:
                raise ValueError("artifact snapshot invalid")
            raw = stream.read(MAX_ARTIFACT_BYTES + 1)
        if len(raw) > MAX_ARTIFACT_BYTES or hashlib.sha256(raw).hexdigest() != expected_digest:
            raise ValueError("artifact snapshot digest mismatch")
        return raw

    @staticmethod
    def _write_snapshot(path: Path, raw: bytes) -> None:
        root = path.parent.parent
        for directory in (root, path.parent):
            if directory.is_symlink():
                raise ValueError("artifact snapshot directory is a symlink")
            directory.mkdir(mode=0o700, exist_ok=True)
            directory.chmod(0o700)
        fd, pending = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
                os.fchmod(stream.fileno(), 0o400)
            try:
                os.link(pending, path)
            except FileExistsError:
                pass
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            os.unlink(pending)

    def apply(self, key: OperationKey, operation: AuthorizedOperation,
              deliver: Callable[[str, str], None],
              admit: Callable[[dict], dict]) -> HostObservation:
        self._host(key.host_id)
        if operation.key != key:
            raise ValueError("operation key mismatch")
        if key.generation < 0 or not all((key.task_id, key.instance_id, operation.producer_id,
                                           operation.capability, operation.session, operation.result_contract,
                                           operation.claim_id)) \
                or not isinstance(operation.input_revision, dict):
            raise ValueError("invalid authorized operation")
        brief = under(operation.brief_ref, operation.workspace_ref)
        if hashlib.sha256(brief.read_bytes()).hexdigest() != operation.brief_digest:
            raise ValueError("brief digest mismatch")
        op_id = operation_id(key)
        assignment_ref = self.state_dir / "assignments" / f"{op_id}.json"
        assignment = {
            "schema": "agent-work.assignment.v1",
            "hostId": key.host_id,
            "taskId": key.task_id,
            "generation": key.generation,
            "instanceId": key.instance_id,
            "producerId": operation.producer_id,
            "capability": operation.capability,
            "claimId": operation.claim_id,
            "session": operation.session,
            "workspaceRef": str(Path(operation.workspace_ref).resolve()),
            "briefRef": str(brief),
            "briefDigest": operation.brief_digest,
            "inputRevision": operation.input_revision,
            "resultContract": operation.result_contract,
            "resultRef": str(self.state_dir / "inbox" / f"{op_id}.json"),
        }
        if operation.adapter_id:
            assignment["adapterId"] = operation.adapter_id
            assignment["acceptRef"] = str(self.state_dir / "inbox" / f"{op_id}.accept.json")
        digest = hashlib.sha256(canonical(assignment).encode()).hexdigest()
        current = self.spool.get(op_id)
        if current and current["operation_digest"] != digest:
            raise ValueError("operation key conflicts with different content")
        self.spool.register(op_id, key.instance_id, digest, str(assignment_ref), assignment)
        (self.state_dir / "inbox").mkdir(parents=True, exist_ok=True)
        if assignment_ref.is_symlink():
            raise ValueError("assignment reference is a symlink")
        if assignment_ref.exists():
            if json.loads(assignment_ref.read_text()) != assignment:
                raise ValueError("assignment reference changed")
        else:
            atomic_json(assignment_ref, assignment)
        status = self.spool.get(op_id)["status"]
        if status == "registered":
            receipt = admit(assignment)
            if (not isinstance(receipt, dict) or receipt.get("state") != "host-admitted"
                    or receipt.get("claimId") != operation.claim_id
                    or receipt.get("hostId") != key.host_id
                    or receipt.get("instanceId") != key.instance_id
                    or receipt.get("generation") != key.generation):
                raise ValueError("native host admission receipt mismatch")
        if not self.spool.begin_delivery(op_id):
            status = self.spool.get(op_id)["status"]
            return HostObservation("uncertain" if status == "attempted" else status, str(assignment_ref))
        try:
            deliver(str(assignment_ref), operation.session)
        except Exception:
            return HostObservation("uncertain", str(assignment_ref))
        if "acceptRef" not in assignment:
            self.spool.delivered(op_id)
            return HostObservation("delivered", str(assignment_ref))
        try:
            accepted = self.take_acceptance(key.host_id, key)
        except OSError:
            accepted = False
        return HostObservation("delivered" if accepted else "typed", str(assignment_ref))

    def report(self, host_id: str, result: dict) -> ResultReceipt:
        self._host(host_id)
        if not isinstance(result, dict) or result.get("schema") != RESULT_SCHEMA or result.get("kind") != "produced":
            raise ValueError("result schema or kind mismatch")
        required = ("hostId", "taskId", "generation", "instanceId", "producerId", "capability",
                    "observedRevision", "typedPayload", "artifactRef", "digest")
        if any(field not in result for field in required) or not isinstance(result["typedPayload"], dict):
            raise ValueError("partial final result")
        self._host(result["hostId"])
        if not isinstance(result["generation"], int) or isinstance(result["generation"], bool):
            raise ValueError("invalid generation")
        key = OperationKey(result["hostId"], result["taskId"], result["generation"], result["instanceId"])
        op_id = operation_id(key)
        current = self.spool.get(op_id)
        if current is None:
            raise ValueError("unknown or old generation")
        assignment = json.loads(current["operation_json"])
        for field in ("hostId", "taskId", "generation", "instanceId", "producerId"):
            if result[field] != assignment[field]:
                raise ValueError(f"result {field} mismatch")
        if not hmac.compare_digest(str(result["capability"]), assignment["capability"]):
            raise ValueError("producer capability mismatch")
        if result["observedRevision"] != assignment["inputRevision"]:
            raise ValueError("observed revision mismatch")
        encoded = canonical(result).encode()
        if len(encoded) > 1024 * 1024:
            raise ValueError("result too large")
        result_id = hashlib.sha256(encoded).hexdigest()
        if current["result_id"] and current["result_id"] != result_id:
            raise ValueError("conflicting final result")
        snapshot = self._snapshot_path(op_id, result_id)
        try:
            self._snapshot_bytes(snapshot, result["digest"])
        except FileNotFoundError:
            if current["result_id"]:
                raise ValueError("recorded artifact snapshot missing")
            artifact = under(result["artifactRef"], assignment["workspaceRef"])
            with artifact.open("rb") as stream:
                raw = stream.read(MAX_ARTIFACT_BYTES + 1)
            if len(raw) > MAX_ARTIFACT_BYTES:
                raise ValueError("artifact too large")
            if hashlib.sha256(raw).hexdigest() != result["digest"]:
                raise ValueError("artifact digest mismatch")
            self._write_snapshot(snapshot, raw)
            self._snapshot_bytes(snapshot, result["digest"])
        self.spool.record(op_id, result_id, result, self.state_dir / "results" / f"{op_id}.json")
        return ResultReceipt(result_id)

    def result_snapshot(self, host_id: str, key: OperationKey) -> tuple[dict, bytes]:
        self._host(host_id)
        self._host(key.host_id)
        row = self.spool.get(operation_id(key))
        if row is None or not row["result_id"] or not row["result_json"]:
            raise ValueError("result is not recorded for this identity")
        result = json.loads(row["result_json"])
        if hashlib.sha256(canonical(result).encode()).hexdigest() != row["result_id"]:
            raise ValueError("recorded result identity mismatch")
        try:
            raw = self._snapshot_bytes(self._snapshot_path(operation_id(key), row["result_id"]), result["digest"])
        except FileNotFoundError as exc:
            raise ValueError("recorded artifact snapshot missing") from exc
        return result, raw

    def operation_key_for(self, host_id: str, task_id: str, generation: int) -> OperationKey | None:
        self._host(host_id)
        assignment = self.spool.find_assignment(task_id, generation)
        if assignment is None:
            return None
        return OperationKey(assignment["hostId"], assignment["taskId"],
                            assignment["generation"], assignment["instanceId"])

    def collect(self, host_id: str, key: OperationKey) -> ResultReceipt | None:
        self._host(host_id)
        self._host(key.host_id)
        current = self.spool.get(operation_id(key))
        if current is None:
            raise ValueError("unknown operation")
        result_ref = Path(json.loads(current["operation_json"])["resultRef"])
        if result_ref.is_symlink():
            raise ValueError("result reference is a symlink")
        if not result_ref.exists():
            return None
        if not result_ref.is_file():
            raise ValueError("result reference is not a regular file")
        if result_ref.stat().st_size > 1024 * 1024:
            raise ValueError("result too large")
        return self.report(host_id, json.loads(result_ref.read_text()))

    def take_acceptance(self, host_id: str, key: OperationKey) -> bool:
        """True only when the CLI's own agent-work.accept.v1 for this assignment is on disk; promotes it."""
        self._host(host_id)
        op_id = operation_id(key)
        current = self.spool.get(op_id)
        if current is None:
            raise ValueError("unknown operation")
        assignment = json.loads(current["operation_json"])
        if "acceptRef" not in assignment or not read_acceptance(assignment):
            return False
        self.spool.delivered(op_id)
        return True

    def settle_deliveries(self, host_id: str, *, now: float,
                          deadline_seconds: float | None = None) -> list[str]:
        """Typed CLI deliveries: accepted -> delivered; past the deadline -> uncertain plus one incident."""
        self._host(host_id)
        check_deadline(deadline_seconds)
        detected = []
        for assignment in self.spool.awaiting_results():
            if "acceptRef" not in assignment:
                continue
            key = OperationKey(assignment["hostId"], assignment["taskId"],
                               assignment["generation"], assignment["instanceId"])
            op_id = operation_id(key)
            current = self.spool.get(op_id)
            if current is None or current["status"] not in ("attempted", "uncertain"):
                continue
            try:
                if self.take_acceptance(host_id, key):
                    continue
            except OSError:
                continue
            if current["status"] == "uncertain":
                continue
            try:
                receipt = self.collect(host_id, key)
            except ValueError:
                receipt = None
            except OSError:
                continue
            if receipt is not None:
                continue
            attempted = self.spool.attempted_at(op_id)
            if deadline_seconds is None or attempted is None or now - attempted < deadline_seconds:
                continue
            incident = {"kind": "transport-unavailable", "episodeId": UNACCEPTED_EPISODE,
                        "evidenceRef": f"host-operation:{op_id}"}
            incident_key, incident_digest = incident_identity(key.generation, incident)
            if self.spool.delivery_uncertain(op_id, key.task_id, incident_key,
                                             canonical(incident), incident_digest):
                detected.append(incident_key)
        return detected

    def detect_silent_failures(self, host_id: str, session_gone: Callable[[OperationKey], bool], *,
                               now: float, deadline_seconds: float | None = None,
                               prompt_identity: Callable[[OperationKey], str | None] | None = None
                               ) -> list[str]:
        self._host(host_id)
        check_deadline(deadline_seconds)
        detected = self.settle_deliveries(host_id, now=now, deadline_seconds=deadline_seconds)
        for assignment in self.spool.awaiting_results():
            key = OperationKey(assignment["hostId"], assignment["taskId"],
                               assignment["generation"], assignment["instanceId"])
            op_id = operation_id(key)
            current = self.spool.get(op_id)
            if current is None or current["status"] != "delivered" or not assignment.get("adapterId"):
                continue
            try:
                receipt = self.collect(host_id, key)
                if receipt is not None:
                    continue
                kind = None
            except ValueError:
                kind = "invalid-result"
            except OSError:
                continue
            if kind is None and session_gone(key):
                kind = "transport-unavailable"
            incidents = []
            dialog = None
            before = None
            dialog_recorded = False
            if kind is None:
                if prompt_identity is not None:
                    observed = prompt_identity(key)
                    if observed is not None:
                        before = self.spool.dialog_state(op_id)
                        dialog, opened = next_dialog_state(before, observed)
                        if opened:
                            incidents.append({"kind": "permission-required",
                                              "promptIdentity": f"{dialog['open_identity']}-{dialog['episode']}",
                                              "evidenceRef": f"host-operation:{op_id}"})
                if deadline_seconds is not None:
                    delivered = self.spool.delivered_at(op_id)
                    if delivered is not None and now - delivered >= deadline_seconds:
                        incidents.append({"kind": "deadline-missed", "episodeId": SILENT_EPISODES["deadline-missed"],
                                          "evidenceRef": f"host-operation:{op_id}"})
            else:
                incidents.append({"kind": kind, "episodeId": SILENT_EPISODES[kind],
                                  "evidenceRef": f"host-operation:{op_id}"})
            for incident in incidents:
                incident_key = incident_identity(key.generation, incident)[0]
                if self.spool.has_incident(key.task_id, incident_key):
                    continue
                if incident["kind"] == "permission-required":
                    self.record_incident(host_id, key, incident, dialog_state=dialog)
                    dialog_recorded = True
                else:
                    self.record_incident(host_id, key, incident)
                detected.append(incident_key)
            if dialog is not None and dialog != before and not dialog_recorded:
                self.spool.save_dialog_state(op_id, dialog)
        return detected

    def pending(self, host_id: str) -> list[dict]:
        self._host(host_id)
        for assignment in self.spool.awaiting_results():
            key = OperationKey(assignment["hostId"], assignment["taskId"],
                               assignment["generation"], assignment["instanceId"])
            op_id = operation_id(key)
            try:
                self.collect(host_id, key)
            except (ValueError, OSError) as exc:
                self.spool.note_inbox_error(op_id, str(exc))
                continue
            self.spool.clear_inbox_error(op_id)
        return self.spool.pending()

    def inbox_errors(self, host_id: str) -> list[dict]:
        self._host(host_id)
        return self.spool.inbox_errors()

    def flush(self, host_id: str, report_to_runtime: Callable[[dict, bytes], dict]) -> list[dict]:
        self._host(host_id)
        receipts = []
        for result in self.pending(host_id):
            result_id = hashlib.sha256(canonical(result).encode()).hexdigest()
            key = OperationKey(result["hostId"], result["taskId"], result["generation"], result["instanceId"])
            op_id = operation_id(key)
            try:
                snapshot_result, artifact_bytes = self.result_snapshot(host_id, key)
                if snapshot_result != result:
                    raise ValueError("pending result identity mismatch")
            except (ValueError, OSError) as exc:
                self.spool.note_inbox_error(op_id, str(exc))
                continue
            self.spool.clear_inbox_error(op_id)
            receipt = report_to_runtime(result, artifact_bytes)
            identity = ("hostId", "taskId", "generation", "instanceId", "producerId")
            if not isinstance(receipt, dict) or any(receipt.get(field) != result[field] for field in identity) \
                    or receipt.get("resultId") != result_id or not receipt.get("receiptId"):
                raise ValueError("runtime receipt identity mismatch")
            self.spool.acknowledge(op_id, receipt)
            receipts.append(receipt)
        return receipts

    def flush_closures(self, host_id: str,
                       close_to_runtime: Callable[[dict, str, str, str], dict]) -> tuple[int, list[str]]:
        """Send every changed resource closure; each one fails alone."""
        self._host(host_id)
        closed, errors = 0, []
        rows = self.spool.closure_rows()
        seen_terminals = {(row["task_id"], row["generation"]) for row in rows
                          if row["state"] in TERMINAL_STATES}
        for row in rows:
            op_id = row["operation_id"]
            try:
                current = self.spool.get(op_id)
                if current is None:
                    self.spool.note_inbox_error(op_id, "closure without assignment")
                    continue
                assignment = json.loads(current["operation_json"])
                digest = closure_digest(row["evidence_json"])
                last = self.spool.closure_last(op_id)
                if last and (last["state"], last["reason"], last["evidence_digest"]) \
                        == (row["state"], row["reason"], digest):
                    self.spool.clear_inbox_error(op_id)
                    continue
                if row["state"] == "CleanupPending" and (
                        (row["task_id"], row["generation"]) in seen_terminals
                        or self.spool.closure_terminal(row["task_id"], row["generation"])
                        is not None):
                    continue
                receipt = close_to_runtime(assignment, row["state"], row["reason"], digest)
                self.spool.closure_record(op_id, row["task_id"], row["generation"],
                                          row["instance_id"], row["state"], row["reason"], digest)
                self.spool.clear_inbox_error(op_id)
                closed += 1
            except (OSError, RuntimeError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
                self.spool.note_inbox_error(op_id, f"closure failed: {exc}")
                errors.append(f"{op_id}: {exc}")
        return closed, errors

    def record_incident(self, host_id: str, key: OperationKey, incident: dict, *,
                        dialog_state: dict | None = None) -> dict:
        self._host(host_id)
        self._host(key.host_id)
        current = self.spool.get(operation_id(key))
        if current is None:
            raise ValueError("unknown operation")
        assignment = json.loads(current["operation_json"])
        adapter = assignment.get("adapterId")
        generation = assignment.get("generation")
        if not isinstance(adapter, str) or not adapter.strip() \
                or not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
            raise ValueError("operation cannot carry host incidents")
        incident_key, incident_digest = incident_identity(generation, incident)
        return self.spool.record_incident(key.task_id, incident_key, operation_id(key),
                                          canonical(incident), incident_digest, dialog_state=dialog_state)

    def flush_incidents(self, host_id: str, send: Callable[[dict, dict], dict]) -> tuple[int, list[str]]:
        """Send every pending incident; each one fails alone and rejections never retry."""
        self._host(host_id)
        sent, errors = 0, []
        for row in self.spool.pending_incidents():
            try:
                current = self.spool.get(row["operation_id"])
                if current is None:
                    raise ValueError("incident without assignment")
                assignment = json.loads(current["operation_json"])
                receipt = send(assignment, json.loads(row["incident_json"]))
                self.spool.incident_sent(row["task_id"], row["incident_key"], receipt)
                sent += 1
            except IncidentRejected as exc:
                self.spool.incident_failed(row["task_id"], row["incident_key"], str(exc), rejected=True)
                errors.append(f"{row['operation_id']}: {exc}")
            except (OSError, RuntimeError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
                self.spool.incident_failed(row["task_id"], row["incident_key"], str(exc))
                errors.append(f"{row['operation_id']}: {exc}")
        return sent, errors

    def receipt(self, host_id: str, key: OperationKey) -> dict | None:
        self._host(host_id)
        self._host(key.host_id)
        row = self.spool.get(operation_id(key))
        if row is None:
            raise ValueError("unknown operation")
        return json.loads(row["receipt_json"]) if row["receipt_json"] else None

    def verify_reference(self, host_id: str, session: str, assignment_ref: str) -> None:
        self._host(host_id)
        candidate = Path(assignment_ref).resolve(strict=True)
        if candidate.parent != (self.state_dir / "assignments").resolve():
            raise ValueError("assignment outside host state")
        assignment = json.loads(candidate.read_text())
        key = OperationKey(assignment["hostId"], assignment["taskId"],
                           assignment["generation"], assignment["instanceId"])
        row = self.spool.get(operation_id(key))
        if not row or Path(row["assignment_ref"]).resolve() != candidate or assignment != json.loads(row["operation_json"]) \
                or assignment["hostId"] != host_id or assignment["session"] != session:
            raise ValueError("assignment not registered for this host and session")


class TmuxTransport:
    def __init__(self, tmux_bin: str, socket: str):
        self.tmux_bin = tmux_bin
        self.socket = socket

    def deliver(self, assignment_ref: str, session: str) -> None:
        if not session.replace("-", "").replace("_", "").isalnum():
            raise ValueError("invalid session")
        text = (f"Open assignment JSON at {assignment_ref}. First write agent-work.accept.v1 atomically to "
                "acceptRef with schema, hostId, taskId, generation, instanceId, claimId and capability copied "
                "from the assignment. Then follow briefRef and write agent-work.result.v1 atomically to resultRef.")
        subprocess.run([self.tmux_bin, "-L", self.socket, "set-environment", "-t", f"={session}",
                        "AGENT_WORK_MANAGED", "1"], check=True, capture_output=True)
        command = [self.tmux_bin, "-L", self.socket, "send-keys", "-t", f"={session}:"]
        subprocess.run(command + ["-l", "--", text], check=True, capture_output=True)
        subprocess.run(command + ["Enter"], check=True, capture_output=True)


class ShellAdapterTransport:
    def __init__(self, corrida_script: Path, run_id: str, lane_id: str, worker_id: str,
                 host_id: str, state_dir: Path, tmux_bin: str):
        self.corrida_script = corrida_script
        self.run_id = run_id
        self.lane_id = lane_id
        self.worker_id = worker_id
        self.host_id = host_id
        self.state_dir = state_dir
        self.tmux_bin = tmux_bin

    def deliver(self, assignment_ref: str, session: str) -> None:
        command = ["bash", str(self.corrida_script), "adaptador", "deliver-ref", self.run_id,
                   self.lane_id, self.worker_id, session, self.host_id, assignment_ref]
        env = dict(os.environ, TMUX_BIN=self.tmux_bin, AGENT_WORK_HOST_STATE_DIR=str(self.state_dir))
        sent = subprocess.run(command, capture_output=True, text=True, env=env)
        if sent.returncode or sent.stdout.strip() != "accepted":
            raise RuntimeError(f"reference delivery uncertain: {sent.stderr.strip() or sent.stdout.strip()}")


if __name__ == "__main__":
    if len(sys.argv) != 6 or sys.argv[1] != "verify-ref":
        raise SystemExit("usage: host.py verify-ref <hostId> <stateDir> <session> <assignmentRef>")
    try:
        Host(sys.argv[2], Path(sys.argv[3])).verify_reference(sys.argv[2], sys.argv[4], sys.argv[5])
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc)) from exc
