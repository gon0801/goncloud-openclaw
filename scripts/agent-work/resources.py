import argparse
import json
import os
import secrets
import sqlite3
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
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
            if self.backend.boot_id != original["boot_id"]:
                return self._state(key, revision, "AbsenceVerified")
            try:
                observed = self.backend.observe(original["session_name"])
            except OSError:
                return self._state(key, revision, "CleanupPending", "host unavailable")
            if (observed is not None and observed.get("nonce") == original["nonce"]
                    and observed.get("bootId") == original["boot_id"]):
                return self._state(key, revision, "CleanupPending", "launch identity recovered", observed)
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
    NONCE_OPTION = "@agent_work_resource_nonce"

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

    def _fields(self, target: str) -> tuple[str, str, str, str, str] | None:
        result = self._tmux("display-message", "-p", "-t", target,
                            f"#{{pid}}|#{{session_id}}|#{{pane_id}}|#{{pane_pid}}|#{{{self.NONCE_OPTION}}}")
        if result.returncode:
            return None
        parts = result.stdout.strip().split("|")
        return tuple(parts) if len(parts) == 5 else None

    def _guarded(self, fields: tuple[str, str, str, str, str], command: str) -> bool:
        session_id = fields[1]
        expected = "|".join(fields)
        condition = (f"#{{==:#{{pid}}|#{{session_id}}|#{{pane_id}}|#{{pane_pid}}|"
                     f"#{{{self.NONCE_OPTION}}},{expected}}}")
        return self._tmux("if-shell", "-F", "-t", session_id, condition, command).returncode == 0

    def mark(self, session: str, nonce: str) -> None:
        if not session or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in session):
            raise ValueError("invalid tmux session")
        if not nonce or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in nonce):
            raise ValueError("invalid tmux resource nonce")
        current = self._fields(f"={session}:")
        if current is None:
            raise OSError("tmux session unavailable before delivery")
        if current[4] and current[4] != nonce:
            raise ValueError("tmux session already belongs to another resource")
        session_id = current[1]
        if not self._guarded(current, f"set-option -t {session_id} {self.NONCE_OPTION} {nonce}"):
            raise OSError("cannot mark tmux resource before delivery")
        marked = self._fields(f"{session_id}:")
        if marked != (*current[:4], nonce):
            raise OSError("tmux resource identity changed before delivery")

    def observe(self, session: str) -> dict | None:
        if not session or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in session):
            raise ValueError("invalid tmux session")
        parts = self._fields(f"={session}:")
        if parts is None:
            return None
        server_pid, session_id, pane_id, pane_pid, nonce = parts
        server_start = self._start(server_pid)
        pane_start = self._start(pane_pid)
        if not server_start or not pane_start:
            return None
        return {"bootId": self.boot_id, "nonce": nonce, "socket": self.socket,
                "sessionName": session, "serverPid": int(server_pid), "serverStart": server_start,
                "sessionId": session_id, "paneId": pane_id, "panePid": int(pane_pid),
                "paneStart": pane_start}

    def stop(self, identity: dict) -> bool:
        if self.observe(identity["sessionName"]) != identity:
            return False
        fields = (str(identity["serverPid"]), identity["sessionId"], identity["paneId"],
                  str(identity["panePid"]), identity["nonce"])
        if not self._guarded(fields, f"kill-session -t {identity['sessionId']}"):
            return False
        return self._fields(f"{identity['sessionId']}:") is None

    def prove_absent(self, identity: dict) -> bool | None:
        if self.observe(identity["sessionName"]) == identity:
            return False
        # tmux can only prove that its pane is gone. A child can call setsid,
        # outlive the pane, and be reparented; PID and session scans cannot
        # prove that every such child has exited.
        return None

    def revoke(self, identity: dict) -> bool:
        if self.observe(identity["sessionName"]) != identity:
            return False
        fields = (str(identity["serverPid"]), identity["sessionId"], identity["paneId"],
                  str(identity["panePid"]), identity["nonce"])
        if not self._guarded(fields, f"set-option -u -t {identity['sessionId']} {self.NONCE_OPTION}"):
            return False
        return self._fields(f"{identity['sessionId']}:") == (*fields[:4], "")


AGENT_USER = "agentes"
LAUNCHD_DOMAIN = "user/502"
AGENT_PATH = "/opt/homebrew/bin:/usr/bin:/bin"
LOCK_PATH = "/private/tmp/b32-agentes.lock"
WORKROOT = "/private/tmp"
LOCK_ARGV = ["/usr/bin/lockf", "-t", "30", "-k", LOCK_PATH]
APPLE_LABEL_PREFIX = "com.apple."
NEVER_SIGNAL_PREFIXES = ("/System/", "/usr/libexec/", "/usr/sbin/")


@dataclass(frozen=True)
class CommandOutcome:
    rc: int
    stdout: str


@dataclass(frozen=True)
class AgentProcess:
    pid: int
    ppid: int
    lstart: str
    command: str


@dataclass(frozen=True)
class LaunchdService:
    label: str
    pid: int


@dataclass(frozen=True)
class Presence:
    pid: int
    lstart: str
    command: str
    label: str | None
    signalable: bool
    reason: str


class AccountBusyError(RuntimeError):
    pass


def parse_agent_ps(text: str) -> tuple[AgentProcess, ...]:
    processes = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split(maxsplit=7)
        if len(parts) < 8 or not parts[0].isdigit() or not parts[1].isdigit():
            raise OSError(f"agent ps line unreadable: {line!r}")
        processes.append(AgentProcess(int(parts[0]), int(parts[1]),
                                      " ".join(parts[2:7]), parts[7]))
    return tuple(processes)


def parse_launchd_services(text: str) -> tuple[LaunchdService, ...]:
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if line.strip() == "services = {"), None)
    if start is None:
        raise OSError("launchd services block missing")
    services = []
    closed = False
    for line in lines[start + 1:]:
        if line.strip() == "}":
            closed = True
            break
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) != 3 or not parts[0].isdigit():
            raise OSError(f"launchd service entry unreadable: {line!r}")
        services.append(LaunchdService(parts[2], int(parts[0])))
    if not closed or not services:
        raise OSError("launchd services block empty or unterminated")
    return tuple(services)


def classify_presence(processes: tuple[AgentProcess, ...],
                      services: tuple[LaunchdService, ...]) -> tuple[Presence, ...]:
    excluded = {service.pid for service in services
                if service.pid > 0 and service.label.startswith(APPLE_LABEL_PREFIX)}
    label_by_pid = {}
    for service in services:
        if service.pid > 0:
            label_by_pid.setdefault(service.pid, service.label)
    presences = []
    for process in processes:
        if process.pid in excluded:
            continue
        executable = process.command.split()[0] if process.command.split() else ""
        forbidden = executable == "xpcproxy" or executable.startswith(NEVER_SIGNAL_PREFIXES)
        presences.append(Presence(process.pid, process.lstart, process.command,
                                  label_by_pid.get(process.pid), not forbidden,
                                  "system binary not signalable" if forbidden
                                  else "agent process"))
    for service in services:
        if service.pid == 0 and not service.label.startswith(APPLE_LABEL_PREFIX):
            presences.append(Presence(0, "", "", service.label, False,
                                      "launchd label may be relaunched"))
    presences.sort(key=lambda presence: (presence.pid, presence.label or ""))
    return tuple(presences)


def _subprocess_outcome(argv: list[str], timeout: float) -> CommandOutcome:
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise OSError(f"command timed out: {' '.join(argv)}") from exc
    return CommandOutcome(done.returncode, done.stdout)


def default_ps_reader():
    def read() -> CommandOutcome:
        return _subprocess_outcome(["ps", "-o", "pid=,ppid=,lstart=,command=", "-U", AGENT_USER], 10)
    return read


def default_launchd_reader():
    def read() -> CommandOutcome:
        return _subprocess_outcome(LOCK_ARGV + ["sudo", "-n", "-u", AGENT_USER,
                                                "/bin/launchctl", "print", LAUNCHD_DOMAIN], 15)
    return read


def default_killer():
    def run_argv(argv: list[str]) -> CommandOutcome:
        return _subprocess_outcome(argv, 35)
    return run_argv


class AgentesBackend(TmuxBackend):
    def __init__(self, tmux_bin: str, socket: str, boot_id: str | None = None, *,
                 ps_reader=None, launchd_reader=None, killer=None, grace_seconds: float = 5.0):
        super().__init__(tmux_bin, socket, boot_id)
        self._ps_reader = ps_reader if ps_reader is not None else default_ps_reader()
        self._launchd_reader = launchd_reader if launchd_reader is not None else default_launchd_reader()
        self._killer = killer if killer is not None else default_killer()
        self.grace_seconds = grace_seconds
        self.last_containment = None

    def account_presence(self) -> tuple[Presence, ...]:
        ps_out = self._ps_reader()
        if ps_out.rc != 0:
            raise OSError("agent ps read failed")
        processes = parse_agent_ps(ps_out.stdout)
        ld_out = self._launchd_reader()
        if ld_out.rc != 0:
            raise OSError("launchd read failed")
        return classify_presence(processes, parse_launchd_services(ld_out.stdout))

    def prove_absent(self, identity: dict) -> bool | None:
        before = self.account_presence()
        self.last_containment = {"session": identity.get("sessionName"),
                                 "nonce": identity.get("nonce"),
                                 "before": [asdict(entry) for entry in before],
                                 "signals": [], "after": None}
        if not before:
            self.last_containment["after"] = []
            return True
        second = self.account_presence()
        alive = {(entry.pid, entry.lstart) for entry in second}
        signaled = []
        for candidate in before:
            if not candidate.signalable or (candidate.pid, candidate.lstart) not in alive:
                continue
            argv = LOCK_ARGV + ["sudo", "-n", "-u", AGENT_USER, "/bin/kill",
                                "-TERM", str(candidate.pid)]
            outcome = self._killer(argv)
            self.last_containment["signals"].append({"argv": argv, "rc": outcome.rc})
            signaled.append((candidate.pid, candidate.lstart))
        if signaled:
            deadline = time.monotonic() + self.grace_seconds
            while time.monotonic() < deadline:
                try:
                    ps_out = self._ps_reader()
                    if ps_out.rc == 0:
                        remaining = {(p.pid, p.lstart) for p in parse_agent_ps(ps_out.stdout)}
                        if not any(pair in remaining for pair in signaled):
                            break
                except OSError:
                    pass
                time.sleep(0.1)
        after = self.account_presence()
        self.last_containment["after"] = [asdict(entry) for entry in after]
        return not after

    def launch(self, session: str, command: list[str]) -> str:
        present = self.account_presence()
        if present:
            detail = "; ".join(f"pid={entry.pid} label={entry.label} {entry.reason}"
                               for entry in present)
            raise AccountBusyError(f"agent account busy ({len(present)} present): {detail}")
        mktemp = LOCK_ARGV + ["sudo", "-n", "-u", AGENT_USER, "/usr/bin/mktemp",
                              "-d", f"{WORKROOT}/b32-ag-XXXXXX"]
        made = self._killer(mktemp)
        workdir = made.stdout.strip()
        if made.rc != 0 or not workdir:
            raise OSError("agent workdir creation failed")
        # sh recibe workdir como $1 ("run" es solo $0); shift+exec deja al CLI
        # como proceso del pane en lugar de un sh envolvente.
        # TMPDIR explicito: sin el, el dirhelper XPC de la cuenta en sesion
        # Background deja colgado a todo CLI que llame temp_dir (codex medido).
        panel = LOCK_ARGV + [self.tmux_bin, "-L", self.socket, "new-session", "-d",
                             "-s", session, "--", "sudo", "-n", "-u", AGENT_USER,
                             "-H", "env", "PATH=" + AGENT_PATH, "TMPDIR=" + workdir,
                             "/bin/sh", "-c",
                             'cd "$1" && shift && exec "$@"', "run", workdir, *command]
        if self._killer(panel).rc != 0:
            raise OSError("agent panel spawn failed")
        return workdir


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("close",))
    parser.add_argument("--host-id", required=True)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--assignment", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--tmux-socket", required=True)
    parser.add_argument("--tmux-bin", default="tmux")
    parser.add_argument("--backend", choices=("tmux", "agentes"),
                        default=os.environ.get("AGENT_WORK_BACKEND", "tmux"))
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
    backend = (AgentesBackend(args.tmux_bin, args.tmux_socket) if args.backend == "agentes"
               else TmuxBackend(args.tmux_bin, args.tmux_socket))
    manager = ResourceManager(host.spool, args.host_id, backend)
    view = manager.close(key, evidence)
    report = {"state": view.state, "reason": view.reason}
    containment = getattr(backend, "last_containment", None)
    if containment is not None:
        report["containment"] = containment
    print(canonical(report))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc)) from exc
