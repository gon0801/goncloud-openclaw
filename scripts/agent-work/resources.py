import argparse
import json
import secrets
import sqlite3
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from contracts import OperationKey, operation_id
from spool import Spool, canonical

TERMINAL = ("AbsenceVerified", "ReleasedAdopted")
OWNERS = ("TaskCreated", "UserAdopted", "IntentionalPool")


@dataclass(frozen=True)
class ResourceView:
    state: str
    nonce: str
    reason: str = ""
    launch_now: bool = False


class ResourceManager:
    def __init__(self, spool: Spool, host_id: str, backend, capacity: int = 1):
        if capacity < 1:
            raise ValueError("host capacity must be positive")
        if spool.host_id != host_id:
            raise ValueError("hostId does not own this spool")
        self.spool = spool
        self.host_id = host_id
        self.backend = backend
        self.capacity = capacity
        with spool.connection() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS resources (
                    operation_id TEXT PRIMARY KEY,
                    host_id TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    generation INTEGER NOT NULL,
                    instance_id TEXT NOT NULL,
                    session_name TEXT NOT NULL,
                    ownership TEXT NOT NULL,
                    nonce TEXT NOT NULL,
                    boot_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    identity_json TEXT,
                    evidence_json TEXT,
                    reason TEXT NOT NULL DEFAULT '',
                    revision INTEGER NOT NULL DEFAULT 0
                );
                CREATE UNIQUE INDEX IF NOT EXISTS one_active_resource_per_instance
                    ON resources(instance_id)
                    WHERE state NOT IN ('AbsenceVerified','ReleasedAdopted');
            """)

    def _key(self, key: OperationKey) -> str:
        if key.host_id != self.host_id or not key.task_id or not key.instance_id or key.generation < 0:
            raise ValueError("resource key hostId or identity invalid")
        return operation_id(key)

    @staticmethod
    def _view(row: dict, launch_now: bool = False) -> ResourceView:
        return ResourceView(row["state"], row["nonce"], row["reason"], launch_now)

    def _row(self, key: OperationKey) -> dict:
        with self.spool.connection() as db:
            row = db.execute("SELECT * FROM resources WHERE operation_id=?", (self._key(key),)).fetchone()
            if row is None:
                raise ValueError("resource reservation missing")
            return dict(row)

    def _state(self, key: OperationKey, revision: int, state: str, reason: str = "",
               identity: dict | None = None) -> ResourceView:
        with self.spool.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            if identity is None:
                db.execute("UPDATE resources SET state=?,reason=?,revision=revision+1 WHERE operation_id=? AND revision=?",
                           (state, reason, self._key(key), revision))
            else:
                db.execute("UPDATE resources SET state=?,reason=?,identity_json=?,revision=revision+1 WHERE operation_id=? AND revision=?",
                           (state, reason, canonical(identity), self._key(key), revision))
            row = db.execute("SELECT * FROM resources WHERE operation_id=?", (self._key(key),)).fetchone()
            return self._view(dict(row))

    def reserve(self, key: OperationKey, session: str, ownership: str) -> ResourceView:
        op_id = self._key(key)
        if ownership not in OWNERS or not session or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in session):
            raise ValueError("invalid resource ownership or session")
        with self.spool.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM resources WHERE operation_id=?", (op_id,)).fetchone()
            if row:
                if row["session_name"] != session or row["ownership"] != ownership:
                    raise ValueError("resource key conflicts with different content")
                return self._view(dict(row))
            active = db.execute("SELECT COUNT(*) FROM resources WHERE state NOT IN ('AbsenceVerified','ReleasedAdopted')").fetchone()[0]
            if active >= self.capacity:
                raise ValueError("host resource capacity exhausted")
            nonce = secrets.token_hex(16)
            try:
                db.execute("INSERT INTO resources (operation_id,host_id,task_id,generation,instance_id,session_name,ownership,nonce,boot_id,state) "
                           "VALUES (?,?,?,?,?,?,?,?,?,'Reserved')",
                           (op_id, key.host_id, key.task_id, key.generation, key.instance_id,
                            session, ownership, nonce, self.backend.boot_id))
            except sqlite3.IntegrityError as exc:
                raise ValueError("active instance already owns a resource") from exc
            return ResourceView("Reserved", nonce)

    def begin_launch(self, key: OperationKey) -> ResourceView:
        with self.spool.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM resources WHERE operation_id=?", (self._key(key),)).fetchone()
            if row is None:
                raise ValueError("resource reservation missing")
            if row["state"] != "Reserved":
                return self._view(dict(row))
            db.execute("UPDATE resources SET state='Launching',revision=revision+1 WHERE operation_id=?", (self._key(key),))
            return ResourceView("Launching", row["nonce"], launch_now=True)

    def attach(self, key: OperationKey) -> ResourceView:
        row = self._row(key)
        if row["state"] not in ("Launching", "CleanupPending", "Running"):
            raise ValueError("resource has no launch to attach")
        try:
            observed = self.backend.observe(row["session_name"])
        except OSError:
            return self._state(key, row["revision"], "CleanupPending", "host unavailable")
        if not observed or observed.get("nonce") != row["nonce"] or observed.get("bootId") != row["boot_id"]:
            return self._state(key, row["revision"], "CleanupPending", "launch identity uncertain")
        if row["identity_json"] and json.loads(row["identity_json"]) != observed:
            return self._state(key, row["revision"], "CleanupPending", "resource identity changed")
        if row["evidence_json"]:
            return self._state(key, row["revision"], "CleanupPending", "closure already requested", observed)
        return self._state(key, row["revision"], "Running", identity=observed)

    def close(self, key: OperationKey, evidence: dict) -> ResourceView:
        if not isinstance(evidence, dict) or evidence.get("kind") not in ("result", "cancel") or not evidence.get("receipt"):
            raise ValueError("durable result or cancellation evidence required")
        op_id = self._key(key)
        with self.spool.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM resources WHERE operation_id=?", (op_id,)).fetchone()
            if row is None:
                raise ValueError("resource reservation missing")
            original = dict(row)
            if row["evidence_json"] and json.loads(row["evidence_json"]) != evidence:
                raise ValueError("resource closure evidence changed")
            if row["state"] in TERMINAL:
                return self._view(original)
            db.execute("UPDATE resources SET evidence_json=?,state='Closing',revision=revision+1 WHERE operation_id=?",
                       (canonical(evidence), op_id))
        revision = original["revision"] + 1
        if original["ownership"] == "UserAdopted":
            identity = json.loads(original["identity_json"]) if original["identity_json"] else None
            try:
                observed = self.backend.observe(original["session_name"])
            except OSError:
                return self._state(key, revision, "CleanupPending", "host unavailable")
            if identity is None or observed != identity:
                return self._state(key, revision, "CleanupPending", "adopted identity uncertain")
            try:
                revoked = self.backend.revoke(identity)
            except OSError:
                revoked = False
            if not revoked:
                return self._state(key, revision, "CleanupPending", "adopted capability removal failed")
            return self._state(key, revision, "ReleasedAdopted")
        identity = json.loads(original["identity_json"]) if original["identity_json"] else None
        if identity is None:
            if original["state"] == "Reserved":
                return self._state(key, revision, "AbsenceVerified")
            return self._state(key, revision, "CleanupPending", "launch outcome uncertain")
        if self.backend.boot_id != identity["bootId"]:
            return self._state(key, revision, "AbsenceVerified")
        try:
            observed = self.backend.observe(original["session_name"])
        except OSError:
            return self._state(key, revision, "CleanupPending", "host unavailable")
        if observed is not None and observed != identity:
            return self._state(key, revision, "CleanupPending", "resource identity changed")
        try:
            if observed == identity and not self.backend.stop(identity):
                return self._state(key, revision, "CleanupPending", "stop failed")
            absent = self.backend.prove_absent(identity)
        except OSError:
            return self._state(key, revision, "CleanupPending", "host unavailable")
        if absent is not True:
            return self._state(key, revision, "CleanupPending", "descendant absence unverified")
        return self._state(key, revision, "AbsenceVerified")

    def counts(self) -> dict:
        with self.spool.connection() as db:
            rows = db.execute("SELECT ownership,state FROM resources").fetchall()
            active = sum(row["state"] not in TERMINAL for row in rows)
            pool = sum(row["ownership"] == "IntentionalPool" and row["state"] not in TERMINAL for row in rows)
            return {"active": active, "history": len(rows) - active, "pool": pool}


class TmuxBackend:
    def __init__(self, tmux_bin: str, socket: str, boot_id: str | None = None):
        if not socket or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in socket):
            raise ValueError("an explicit isolated tmux socket is required")
        self.tmux_bin = tmux_bin
        self.socket = socket
        if boot_id:
            self.boot_id = boot_id
        elif sys.platform == "darwin":
            self.boot_id = subprocess.check_output(["sysctl", "-n", "kern.boottime"], text=True).strip()
        elif sys.platform.startswith("linux"):
            self.boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        else:
            raise RuntimeError("host platform has no verified boot identity")

    def _tmux(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([self.tmux_bin, "-L", self.socket, *args], capture_output=True, text=True)

    @staticmethod
    def _start(pid: str) -> str:
        if not pid.isdigit():
            return ""
        result = subprocess.run(["ps", "-o", "lstart=", "-p", pid], capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else ""

    def mark(self, session: str, nonce: str) -> None:
        current = self._tmux("show-environment", "-t", f"={session}", "AGENT_WORK_RESOURCE_NONCE")
        if current.returncode == 0 and current.stdout.strip() != f"AGENT_WORK_RESOURCE_NONCE={nonce}":
            raise ValueError("tmux session already belongs to another resource")
        result = self._tmux("set-environment", "-t", f"={session}", "AGENT_WORK_RESOURCE_NONCE", nonce)
        if result.returncode:
            raise OSError("cannot mark tmux resource before delivery")

    def observe(self, session: str) -> dict | None:
        if not session or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in session):
            raise ValueError("invalid tmux session")
        result = self._tmux("display-message", "-p", "-t", f"={session}:",
                            "#{pid}|#{session_id}|#{pane_id}|#{pane_pid}")
        if result.returncode:
            return None
        parts = result.stdout.strip().split("|")
        if len(parts) != 4:
            return None
        server_pid, session_id, pane_id, pane_pid = parts
        server_start = self._start(server_pid)
        pane_start = self._start(pane_pid)
        if not server_start or not pane_start:
            return None
        marker = self._tmux("show-environment", "-t", f"={session}", "AGENT_WORK_RESOURCE_NONCE")
        nonce = marker.stdout.strip().partition("=")[2] if marker.returncode == 0 else ""
        return {"bootId": self.boot_id, "nonce": nonce, "socket": self.socket,
                "sessionName": session, "serverPid": int(server_pid), "serverStart": server_start,
                "sessionId": session_id, "paneId": pane_id, "panePid": int(pane_pid),
                "paneStart": pane_start}

    def stop(self, identity: dict) -> bool:
        if self.observe(identity["sessionName"]) != identity:
            return False
        return self._tmux("kill-session", "-t", f"={identity['sessionName']}").returncode == 0

    def prove_absent(self, identity: dict) -> bool | None:
        if self.observe(identity["sessionName"]) == identity:
            return False
        return None

    def revoke(self, identity: dict) -> bool:
        if self.observe(identity["sessionName"]) != identity:
            return False
        return self._tmux("set-environment", "-t", f"={identity['sessionName']}", "-u",
                          "AGENT_WORK_RESOURCE_NONCE").returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("close",))
    parser.add_argument("--host-id", required=True)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--assignment", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--tmux-socket", required=True)
    parser.add_argument("--tmux-bin", default="tmux")
    args = parser.parse_args()
    from host import Host
    host = Host(args.host_id, args.state_dir)
    assignment = json.loads(args.assignment.read_text())
    host.verify_reference(args.host_id, assignment["session"], str(args.assignment))
    key = OperationKey(assignment["hostId"], assignment["taskId"],
                       assignment["generation"], assignment["instanceId"])
    evidence = json.loads(args.evidence.read_text())
    if evidence.get("kind") == "result":
        receipt = host.receipt(args.host_id, key)
        if not receipt or receipt["receiptId"] != evidence.get("receipt"):
            raise ValueError("result receipt is not durable for this task")
    backend = TmuxBackend(args.tmux_bin, args.tmux_socket)
    manager = ResourceManager(host.spool, args.host_id, backend)
    view = manager.close(key, evidence)
    print(canonical({"state": view.state, "reason": view.reason}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc)) from exc
