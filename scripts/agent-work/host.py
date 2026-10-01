#!/usr/bin/env python3
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

from contracts import AuthorizedOperation, HostObservation, OperationKey, ResultReceipt, operation_id
from spool import Spool, atomic_json, canonical

MAX_ARTIFACT_BYTES = 10 * 1024 * 1024
RESULT_SCHEMA = "agent-work.result.v1"


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
              deliver: Callable[[str, str], None]) -> HostObservation:
        self._host(key.host_id)
        if operation.key != key:
            raise ValueError("operation key mismatch")
        if key.generation < 0 or not all((key.task_id, key.instance_id, operation.producer_id,
                                           operation.capability, operation.session)):
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
            "session": operation.session,
            "workspaceRef": str(Path(operation.workspace_ref).resolve()),
            "briefRef": str(brief),
            "briefDigest": operation.brief_digest,
            "resultRef": str(self.state_dir / "inbox" / f"{op_id}.json"),
        }
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
        if not self.spool.begin_delivery(op_id):
            status = self.spool.get(op_id)["status"]
            return HostObservation("uncertain" if status == "attempted" else status, str(assignment_ref))
        try:
            deliver(str(assignment_ref), operation.session)
        except Exception:
            return HostObservation("uncertain", str(assignment_ref))
        self.spool.delivered(op_id)
        return HostObservation("delivered", str(assignment_ref))

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
        if not result["observedRevision"]:
            raise ValueError("missing observed revision")
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

    def flush(self, host_id: str, report_to_runtime: Callable[[dict], dict]) -> list[dict]:
        self._host(host_id)
        receipts = []
        for result in self.pending(host_id):
            result_id = hashlib.sha256(canonical(result).encode()).hexdigest()
            key = OperationKey(result["hostId"], result["taskId"], result["generation"], result["instanceId"])
            op_id = operation_id(key)
            try:
                if self.result_snapshot(host_id, key)[0] != result:
                    raise ValueError("pending result identity mismatch")
            except (ValueError, OSError) as exc:
                self.spool.note_inbox_error(op_id, str(exc))
                continue
            self.spool.clear_inbox_error(op_id)
            receipt = report_to_runtime(result)
            identity = ("hostId", "taskId", "generation", "instanceId", "producerId")
            if not isinstance(receipt, dict) or any(receipt.get(field) != result[field] for field in identity) \
                    or receipt.get("resultId") != result_id or not receipt.get("receiptId"):
                raise ValueError("runtime receipt identity mismatch")
            self.spool.acknowledge(op_id, receipt)
            receipts.append(receipt)
        return receipts

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
        text = f"Open assignment JSON at {assignment_ref}. Follow briefRef and write agent-work.result.v1 atomically to resultRef."
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
