from __future__ import annotations

import json
import os
import re
import secrets
import sqlite3
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

from contracts import OperationKey, operation_id
from spool import SETTLED, TERMINAL_STATES as TERMINAL, Spool, canonical

TERMINAL_SQL = ",".join(repr(state) for state in TERMINAL)
OWNERS = ("TaskCreated", "UserAdopted", "IntentionalPool")
CLAIM_FIELDS = ("hostId", "taskId", "generation", "instanceId", "producerId", "capability", "adapterId")
PS_ENV = {"TZ": "UTC", "LC_ALL": "C"}
BOOTTIME_RE = re.compile(r"sec\s*=\s*(\d+),\s*usec\s*=\s*(\d+)")
BOOT_ID_RE = re.compile(r"\d+\.\d{6}")
LINUX_BOOT_ID_RE = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
TMUX_TIMEOUT_SECONDS = 5.0
# A clock adjustment moves macOS kern.boottime within one boot (58 ms between two canary spools); a new
# boot normally moves it far more. Nothing guarantees a minimum, so a change within this window is one boot.
BOOT_DRIFT_SECONDS = 10.0


def _ps(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["ps", *args], capture_output=True, text=True,
                          env={**os.environ, **PS_ENV})


def recognized_boot_id(value: str) -> bool:
    return bool(BOOT_ID_RE.fullmatch(value) or LINUX_BOOT_ID_RE.fullmatch(value))


def drifted_boot_id(saved: str, current: str) -> bool:
    """A boottime this host saved earlier in the boot it is running now, read before a clock adjustment."""
    return (saved != current and bool(BOOT_ID_RE.fullmatch(saved)) and bool(BOOT_ID_RE.fullmatch(current))
            and abs(float(saved) - float(current)) <= BOOT_DRIFT_SECONDS)


NONCE_RE = re.compile(r"[0-9a-f]{32}")


def adopted_mark_lost(identity: dict, observed: dict, socket: str) -> str | None:
    """Why the host no longer holds an adopted pane, seen alive on the tmux server that held its mark: the
    pane carries no mark, or another resource's. None while the pane may still carry ours, or when the
    observation comes from another server or shows a value that is not a nonce."""
    if identity.get("socket") != socket or observed.get("socket") != socket:
        return None
    mark = observed.get("nonce")
    if mark == "":
        return "adopted mark cleared"
    if isinstance(mark, str) and mark != identity.get("nonce") and NONCE_RE.fullmatch(mark):
        return "adopted mark superseded"
    return None


class BoundaryBusy(Exception):
    """The slot's process boundary holds processes before a launch. The launch is deferred, never stacked
    on top of them."""

    def __init__(self, processes: tuple):
        super().__init__(f"slot boundary holds {len(processes)} process(es): " + "; ".join(map(str, processes)))
        self.processes = tuple(str(process) for process in processes)


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
            db.executescript(f"""
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
                    WHERE state NOT IN ({TERMINAL_SQL});
            """)
        self._align_boot_ids()

    def _align_boot_ids(self) -> None:
        """Rewrite to this boot's id the boot ids that unsettled resources saved before a clock adjustment, so
        identity comparisons stay exact. Settled rows keep what they saved."""
        current = self.backend.boot_id
        with self.spool.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            rows = db.execute("SELECT operation_id,boot_id,identity_json FROM resources "
                              f"WHERE state NOT IN ({TERMINAL_SQL})").fetchall()
            for row in rows:
                if drifted_boot_id(row["boot_id"], current):
                    db.execute("UPDATE resources SET boot_id=? WHERE operation_id=?", (current, row["operation_id"]))
                identity = json.loads(row["identity_json"]) if row["identity_json"] else {}
                if drifted_boot_id(str(identity.get("bootId")), current):
                    db.execute("UPDATE resources SET identity_json=? WHERE operation_id=?",
                               (canonical({**identity, "bootId": current}), row["operation_id"]))

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

    def reserve(self, key: OperationKey, session: str, ownership: str, claim: dict | None = None) -> ResourceView:
        """claim keeps the claim fields R needs (CLAIM_FIELDS), so a reservation whose host died before
        registering its operation can still learn that R cancelled its task, and close."""
        op_id = self._key(key)
        if ownership not in OWNERS or not session or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in session):
            raise ValueError("invalid resource ownership or session")
        if claim is not None and (set(claim) != set(CLAIM_FIELDS)
                                  or (claim["hostId"], claim["taskId"], claim["generation"], claim["instanceId"])
                                  != (key.host_id, key.task_id, key.generation, key.instance_id)):
            raise ValueError("reservation claim does not match its resource key")
        with self.spool.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            if claim is not None:
                db.execute("INSERT OR IGNORE INTO reservation_claims VALUES (?,?)", (op_id, canonical(claim)))
            row = db.execute("SELECT * FROM resources WHERE operation_id=?", (op_id,)).fetchone()
            if row:
                if row["session_name"] != session or row["ownership"] != ownership:
                    raise ValueError("resource key conflicts with different content")
                return self._view(dict(row))
            active = db.execute(f"SELECT COUNT(*) FROM resources WHERE state NOT IN ({TERMINAL_SQL})").fetchone()[0]
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

    def can_take(self, instance_id: str) -> bool:
        """Whether a claim for this instance can be reserved: its own unfinished operation, which the claim
        replays, or room for a new resource. R binds a claimed task to the instance, so ask it only then."""
        with self.spool.connection() as db:
            rows = db.execute("SELECT r.instance_id,o.status,o.result_id FROM resources r "
                              "LEFT JOIN operations o ON o.operation_id=r.operation_id "
                              f"WHERE r.state NOT IN ({TERMINAL_SQL})").fetchall()
        own = [row for row in rows if row["instance_id"] == instance_id]
        if own:
            return any(row["status"] is None or (row["result_id"] is None and row["status"] not in SETTLED)
                       for row in own)
        return len(rows) < self.capacity

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

    def ensure_launched(self, key: OperationKey, launch: Callable[[str], None]) -> ResourceView:
        """Converge to: one session carries this resource's nonce, and it was launched once. launch gets
        the nonce and starts that session. BoundaryBusy while the slot's boundary holds a process before
        the first launch: nothing changed, and the caller defers. A host that died after launching attaches
        the session it finds. One that died before launching launches again only while the empty boundary
        proves no earlier launch is alive."""
        row = self._row(key)
        if row["ownership"] != "TaskCreated":
            raise ValueError("only a task-created resource is launched")
        if row["state"] == "Reserved":
            busy = self.backend.boundary()
            if busy:
                raise BoundaryBusy(busy)
            self.begin_launch(key)
        elif row["state"] != "Launching":
            return self._view(row)
        else:
            observed = self.backend.observe(row["session_name"])
            if observed is not None and observed.get("nonce") == row["nonce"]:
                return self.attach(key)
            if self.backend.boundary():
                return self._state(key, row["revision"], "CleanupPending", "launch outcome uncertain")
        launch(row["nonce"])
        return self.attach(key)

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

    def _boot_state(self, saved: str) -> str:
        if saved == self.backend.boot_id:
            return "same"
        return "reboot" if recognized_boot_id(saved) else "unrecognized"

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
            if original["state"] == "Reserved":
                return self._state(key, revision, "ReleasedAdopted", "adopted session never marked")
            identity = json.loads(original["identity_json"]) if original["identity_json"] else None
            try:
                observed = self.backend.observe(original["session_name"])
            except OSError:
                return self._state(key, revision, "CleanupPending", "host unavailable")
            if observed is not None:
                if identity is not None and observed != identity:
                    lost = adopted_mark_lost(identity, observed, self.backend.socket)
                    if lost:
                        return self._state(key, revision, "ReleasedAdopted", lost)
                if identity is None or observed != identity:
                    return self._state(key, revision, "CleanupPending", "adopted identity uncertain")
                try:
                    revoked = self.backend.revoke(identity)
                except OSError:
                    revoked = False
                if not revoked:
                    return self._state(key, revision, "CleanupPending", "adopted capability removal failed")
                return self._state(key, revision, "ReleasedAdopted")
            if identity is not None and identity.get("socket") == self.backend.socket:
                try:
                    gone = self.backend.pane_gone(identity)
                except OSError:
                    return self._state(key, revision, "CleanupPending", "host unavailable")
                if gone is True:
                    return self._state(key, revision, "ReleasedAdopted", "adopted session gone")
            return self._state(key, revision, "CleanupPending", "adopted session unverifiable")
        identity = json.loads(original["identity_json"]) if original["identity_json"] else None
        if identity is None:
            if original["state"] == "Reserved":
                return self._state(key, revision, "AbsenceVerified")
            boot = self._boot_state(original["boot_id"])
            if boot == "reboot":
                return self._state(key, revision, "AbsenceVerified")
            if boot == "unrecognized":
                return self._state(key, revision, "CleanupPending", "boot identity unrecognized")
            try:
                observed = self.backend.observe(original["session_name"])
            except OSError:
                return self._state(key, revision, "CleanupPending", "host unavailable")
            if (observed is not None and observed.get("nonce") == original["nonce"]
                    and observed.get("bootId") == original["boot_id"]):
                return self._state(key, revision, "CleanupPending", "launch identity recovered", observed)
            # No session carries the nonce. Only a backend that owns a process boundary can still prove
            # that the launch left nothing alive.
            try:
                empty = getattr(self.backend, "prove_slot_empty", lambda: None)()
            except OSError:
                return self._state(key, revision, "CleanupPending", "host unavailable")
            self._keep_proof(op_id)
            if empty is True:
                return self._state(key, revision, "AbsenceVerified")
            return self._state(key, revision, "CleanupPending", "launch outcome uncertain")
        boot = self._boot_state(identity["bootId"])
        if boot == "reboot":
            return self._state(key, revision, "AbsenceVerified")
        if boot == "unrecognized":
            return self._state(key, revision, "CleanupPending", "boot identity unrecognized")
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
        self._keep_proof(op_id)
        if absent is not True:
            return self._state(key, revision, "CleanupPending", "descendant absence unverified")
        return self._state(key, revision, "AbsenceVerified")

    def _keep_proof(self, op_id: str) -> None:
        """A backend that swept a process boundary says what it found; the closure R receives binds it."""
        proof = getattr(self.backend, "last_closure", None)
        if proof is not None:
            self.spool.save_closure_proof(op_id, asdict(proof))

    def release_acknowledged(self) -> tuple[int, list[str]]:
        """Close each session once R acknowledged its result. An adopted one goes back to the operator: the
        CLI keeps running and close only revokes the host's nonce. One the host launched is stopped, and it
        counts only once its process boundary is proven empty."""
        with self.spool.connection() as db:
            rows = db.execute("SELECT r.task_id,r.generation,r.instance_id,o.receipt_json FROM resources r "
                              "JOIN operations o ON o.operation_id=r.operation_id "
                              "WHERE ((r.ownership='UserAdopted' AND r.state IN ('Running','Closing')) "
                              "OR (r.ownership='TaskCreated' AND r.state IN ('Launching','Running','Closing'))) "
                              "AND o.status='acknowledged'").fetchall()
        released, errors = 0, []
        for row in rows:
            key = OperationKey(self.host_id, row["task_id"], row["generation"], row["instance_id"])
            try:
                receipt = json.loads(row["receipt_json"])["receiptId"]
                released += self.close(key, {"kind": "result", "receipt": receipt}).state in TERMINAL
            except (OSError, ValueError, KeyError, TypeError) as exc:
                errors.append(f"{operation_id(key)}: release failed: {exc}")
        return released, errors

    def release_cancelled(self, read_cancellation) -> tuple[int, list[str]]:
        """Close the resource of every operation R cancelled, with R's cancellation id as evidence. R is asked
        once per held operation and pass; once the spool records the cancellation, retries stay local.
        A session an abandoned delivery already gave back has no evidence, so its closure never reached R;
        once R cancels that task, the cancellation becomes its evidence and flush_closures sends it."""
        with self.spool.connection() as db:
            rows = db.execute("SELECT r.*,o.operation_json,c.cancellation_id FROM resources r "
                              "JOIN operations o ON o.operation_id=r.operation_id "
                              "LEFT JOIN cancellations c ON c.operation_id=r.operation_id "
                              f"WHERE (r.state NOT IN ({','.join('?' * len(TERMINAL))}) "
                              "AND (c.operation_id IS NOT NULL OR "
                              f"o.status NOT IN ({','.join('?' * len(SETTLED))}))) "
                              "OR (r.state='ReleasedAdopted' AND r.evidence_json IS NULL AND o.status='abandoned') "
                              "ORDER BY r.operation_id",
                              (*TERMINAL, *SETTLED)).fetchall()
        released, errors = 0, []
        for row in rows:
            key = OperationKey(self.host_id, row["task_id"], row["generation"], row["instance_id"])
            op_id = row["operation_id"]
            try:
                evidence = json.loads(row["evidence_json"]) if row["evidence_json"] else None
                if evidence is not None and evidence.get("kind") != "cancel":
                    continue
                cancellation_id = row["cancellation_id"]
                if row["state"] in TERMINAL:
                    cancellation_id = read_cancellation(json.loads(row["operation_json"]))
                    if cancellation_id is not None:
                        with self.spool.connection() as db:
                            db.execute("UPDATE resources SET evidence_json=?,revision=revision+1 "
                                       "WHERE operation_id=? AND evidence_json IS NULL",
                                       (canonical({"kind": "cancel", "receipt": cancellation_id}), op_id))
                        released += 1
                    continue
                if cancellation_id is None:
                    cancellation_id = read_cancellation(json.loads(row["operation_json"]))
                    if cancellation_id is None:
                        continue
                    self.spool.cancel(op_id, cancellation_id)
                view = self.close(key, {"kind": "cancel", "receipt": cancellation_id})
                if view.state in TERMINAL:
                    released += 1
                else:
                    errors.append(f"{op_id}: cancelled; resource {view.state}: {view.reason}")
            except (OSError, RuntimeError, ValueError, KeyError, TypeError) as exc:
                errors.append(f"{op_id}: cancel failed: {exc}")
        orphans, orphan_errors = self._release_cancelled_reservations(read_cancellation)
        return released + orphans, errors + orphan_errors

    def _release_cancelled_reservations(self, read_cancellation) -> tuple[int, list[str]]:
        """A host that died between reserve and register left a resource no operation names, and a claim
        replay never reaches it once R cancels the task. Its stored claim asks R; R's cancellation closes it.
        Without a stored claim (reserved before B18) R cannot be asked, so the resource stays as it is."""
        with self.spool.connection() as db:
            rows = db.execute("SELECT r.task_id,r.generation,r.instance_id,r.operation_id,c.assignment_json "
                              "FROM resources r JOIN reservation_claims c ON c.operation_id=r.operation_id "
                              "LEFT JOIN operations o ON o.operation_id=r.operation_id "
                              "WHERE o.operation_id IS NULL AND r.evidence_json IS NULL "
                              f"AND r.state NOT IN ({TERMINAL_SQL}) ORDER BY r.operation_id").fetchall()
        released, errors = 0, []
        for row in rows:
            key = OperationKey(self.host_id, row["task_id"], row["generation"], row["instance_id"])
            try:
                cancellation_id = read_cancellation(json.loads(row["assignment_json"]))
                if cancellation_id is None:
                    continue
                view = self.close(key, {"kind": "cancel", "receipt": cancellation_id})
                if view.state in TERMINAL:
                    released += 1
                else:
                    errors.append(f"{row['operation_id']}: cancelled before registering; "
                                  f"resource {view.state}: {view.reason}")
            except (OSError, RuntimeError, ValueError, KeyError, TypeError) as exc:
                errors.append(f"{row['operation_id']}: cancel failed: {exc}")
        return released, errors

    def retry_cleanup(self) -> tuple[int, list[str]]:
        """Close again every resource a pass left CleanupPending with its evidence, so flush_closures tells
        R once it ends terminal: an adopted pane that since lost the host's mark or died, and a launched
        session whose boundary still held a process. Closing a launched one sweeps its boundary again, so a
        survivor of the first sweep cannot hold the slot for ever."""
        with self.spool.connection() as db:
            rows = db.execute("SELECT task_id,generation,instance_id,evidence_json FROM resources "
                              "WHERE ownership IN ('UserAdopted','TaskCreated') AND state='CleanupPending' "
                              "AND evidence_json IS NOT NULL ORDER BY operation_id").fetchall()
        released, errors = 0, []
        for row in rows:
            key = OperationKey(self.host_id, row["task_id"], row["generation"], row["instance_id"])
            try:
                released += self.close(key, json.loads(row["evidence_json"])).state in TERMINAL
            except (OSError, ValueError) as exc:
                errors.append(f"{operation_id(key)}: cleanup retry failed: {exc}")
        return released, errors

    def _running_identity(self, key: OperationKey) -> dict | None:
        try:
            row = self._row(key)
        except ValueError:
            return None
        if row["state"] != "Running" or not row["identity_json"]:
            return None
        return json.loads(row["identity_json"])

    def session_exit(self, key: OperationKey):
        """How the launched session of a running resource left, or None while it lives or cannot be read."""
        identity = self._running_identity(key)
        if identity is None:
            return None
        try:
            return self.backend.exit_of(identity)
        except OSError:
            return None

    def stop_session(self, key: OperationKey) -> bool:
        """Stop the launched session of a running resource. The resource keeps the slot until it closes."""
        identity = self._running_identity(key)
        if identity is None:
            return False
        try:
            return self.backend.stop(identity)
        except OSError:
            return False

    def held(self) -> list[dict]:
        """Every resource that still holds the slot, with its task."""
        with self.spool.connection() as db:
            rows = db.execute("SELECT operation_id,task_id,state FROM resources "
                              f"WHERE state NOT IN ({TERMINAL_SQL}) ORDER BY operation_id").fetchall()
        return [dict(row) for row in rows]

    def counts(self) -> dict:
        with self.spool.connection() as db:
            rows = db.execute("SELECT ownership,state FROM resources").fetchall()
            active = sum(row["state"] not in TERMINAL for row in rows)
            pool = sum(row["ownership"] == "IntentionalPool" and row["state"] not in TERMINAL for row in rows)
            return {"active": active, "history": len(rows) - active, "pool": pool}


class TmuxBackend:
    NONCE_OPTION = "@agent_work_resource_nonce"

    def __init__(self, tmux_bin: str, socket: str, boot_id: str | None = None, *,
                 timeout: float = TMUX_TIMEOUT_SECONDS):
        if not socket or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in socket):
            raise ValueError("an explicit isolated tmux socket is required")
        self.tmux_bin = tmux_bin
        self.socket = socket
        self.timeout = timeout
        if boot_id:
            self.boot_id = boot_id
        elif sys.platform == "darwin":
            match = BOOTTIME_RE.search(subprocess.check_output(["sysctl", "-n", "kern.boottime"], text=True))
            if match is None:
                raise RuntimeError("host boottime unreadable")
            self.boot_id = f"{match.group(1)}.{int(match.group(2)):06d}"
        elif sys.platform.startswith("linux"):
            self.boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        else:
            raise RuntimeError("host platform has no verified boot identity")

    def _tmux(self, *args: str) -> subprocess.CompletedProcess:
        # A hung tmux is an unreachable host (OSError), never a missing session.
        try:
            return subprocess.run([self.tmux_bin, "-L", self.socket, *args], capture_output=True,
                                  encoding="utf-8", errors="replace", timeout=self.timeout)
        except subprocess.TimeoutExpired as exc:
            raise OSError(f"tmux {args[0]} timed out") from exc

    @staticmethod
    def _start(pid: str) -> str:
        if not pid.isdigit():
            return ""
        result = _ps("-o", "lstart=", "-p", pid)
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
        # With another session on the server, display-message on a dead session id exits 0 with empty fields.
        remaining = self._fields(f"{identity['sessionId']}:")
        return remaining is None or remaining[1] != identity["sessionId"]

    def pane_gone(self, identity: dict) -> bool:
        # A pane pid missing from the process table (rc=1, both streams empty)
        # is the only positive proof of death here. Any other outcome stays
        # False, including a reused pid, so close keeps CleanupPending.
        pane_pid = identity.get("panePid")
        if isinstance(pane_pid, bool) or not isinstance(pane_pid, int) or pane_pid <= 1:
            return False
        result = _ps("-p", str(pane_pid), "-o", "pid=")
        return result.returncode == 1 and result.stdout == "" and result.stderr == ""

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
AGENT_UID = 502
LAUNCHD_DOMAIN = "user/502"
AGENT_PATH = "/opt/homebrew/bin:/usr/bin:/bin"
LOCK_PATH = "/private/tmp/b32-agentes.lock"
WORKROOT = "/private/tmp"
# Every account mutation (spawn, mktemp, kill) and the privileged launchctl
# read take lockf so they never interleave with another process's containment;
# ps is an advisory read and runs unlocked. Never wrap the pane CLI itself.
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
    # ps -A output carries a uid column, filtered here to the agent account:
    # `ps -U agentes` exits 1 with empty output when the account has no live
    # process, which would read the clearest possible state as a read failure.
    # ps prints an argv-embedded newline as a raw line break, so any line that
    # is not a full pid row belongs to the previous process's command text.
    # Joining it there keeps a multi-line command from blocking every future
    # read, and keeps injected look-alike rows inert instead of signal targets.
    rows: list[tuple[str, int, str, str]] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split(maxsplit=8)
        if len(parts) >= 9 and parts[0].isdigit() and parts[1].isdigit() and parts[2].isdigit():
            rows.append((parts[0], int(parts[1]), " ".join(parts[3:8]), parts[8]))
        elif rows:
            uid, pid, lstart, command = rows[-1]
            rows[-1] = (uid, pid, lstart, command + "\n" + line)
        else:
            raise OSError(f"agent ps line unreadable: {line!r}")
    return tuple(AgentProcess(pid, lstart, command)
                 for uid, pid, lstart, command in rows if int(uid) == AGENT_UID)


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


def protected_command(command: str) -> bool:
    # xpcproxy and OS binaries under /System, /usr/libexec and /usr/sbin are
    # never signal targets, no matter what labels or argv text claim.
    executable = command.split()[0] if command.split() else ""
    return executable == "xpcproxy" or executable.startswith(NEVER_SIGNAL_PREFIXES)


def classify_presence(processes: tuple[AgentProcess, ...],
                      services: tuple[LaunchdService, ...]) -> tuple[Presence, ...]:
    apple_live = {service.pid for service in services
                  if service.pid > 0 and service.label.startswith(APPLE_LABEL_PREFIX)}
    label_by_pid = {}
    for service in services:
        if service.pid > 0:
            label_by_pid.setdefault(service.pid, service.label)
    presences = []
    for process in processes:
        # Only a live com.apple.* label backed by an OS binary is excluded. A
        # label alone is forgeable by any process of the account once user/502
        # hosts labels, and a forged exclusion would fake AbsenceVerified.
        if process.pid in apple_live and protected_command(process.command):
            continue
        forbidden = protected_command(process.command)
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
        # -A (all users) exits 0 even when the agent account has no process;
        # parse_agent_ps filters the uid column. Any nonzero rc stays a closed failure.
        return _subprocess_outcome(["ps", "-A", "-o", "uid=,pid=,ppid=,lstart=,command="], 10)
    return read


def default_launchd_reader():
    def read() -> CommandOutcome:
        return _subprocess_outcome(LOCK_ARGV + ["sudo", "-n", "-u", AGENT_USER,
                                                "/bin/launchctl", "print", LAUNCHD_DOMAIN], 15)
    return read


def default_runner():
    def run_argv(argv: list[str]) -> CommandOutcome:
        return _subprocess_outcome(argv, 35)
    return run_argv


class AgentesBackend(TmuxBackend):
    """TaskCreated backend whose pane tree runs as the dedicated `agentes`
    account. Absence is proven at the account boundary (ps -U + launchctl
    user/502), not by process tree: the account must stay exclusive to this
    system while a task is active, or this backend will sweep foreign work
    and foreign presence will wedge the single capacity slot."""

    def __init__(self, tmux_bin: str, socket: str, boot_id: str | None = None, *,
                 ps_reader=None, launchd_reader=None, runner=None, grace_seconds: float = 5.0):
        super().__init__(tmux_bin, socket, boot_id)
        self._ps_reader = ps_reader if ps_reader is not None else default_ps_reader()
        self._launchd_reader = launchd_reader if launchd_reader is not None else default_launchd_reader()
        self._runner = runner if runner is not None else default_runner()
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

    def _process_truth(self, pid: int) -> tuple[str, str] | None:
        # Kernel truth for one pid: a forged ps row (argv text injected by any
        # process of the account) never survives this direct read, so a signal
        # only ever lands on a pid whose real birth time and real command were
        # both confirmed.
        out = self._runner(["ps", "-o", "lstart=,command=", "-p", str(pid)])
        if out.rc != 0:
            return None
        lines = [line for line in out.stdout.splitlines() if line.strip()]
        if len(lines) != 1:
            return None
        parts = lines[0].split(maxsplit=5)
        if len(parts) < 6:
            return None
        return " ".join(parts[:5]), parts[5]

    def prove_absent(self, identity: dict) -> bool | None:
        # Contain and prove, despite the name: ResourceManager.close skips
        # stop() whenever observe() returns None (pane already dead, detached
        # child alive), so this is the only method both closure paths reach.
        # Read failures raise OSError instead of returning None, which close()
        # maps to CleanupPending with no signal sent.
        self.last_containment = None
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
            truth = self._process_truth(candidate.pid)
            if truth is None or truth[0] != candidate.lstart or protected_command(truth[1]):
                continue
            argv = LOCK_ARGV + ["sudo", "-n", "-u", AGENT_USER, "/bin/kill",
                                "-TERM", str(candidate.pid)]
            outcome = self._runner(argv)
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
        if not session or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in session):
            raise ValueError("invalid tmux session")
        present = self.account_presence()
        if present:
            detail = "; ".join(f"pid={entry.pid} label={entry.label} {entry.reason}"
                               for entry in present)
            raise AccountBusyError(f"agent account busy ({len(present)} present): {detail}")
        mktemp = LOCK_ARGV + ["sudo", "-n", "-u", AGENT_USER, "/usr/bin/mktemp",
                              "-d", f"{WORKROOT}/b32-ag-XXXXXX"]
        made = self._runner(mktemp)
        workdir = made.stdout.strip()
        if made.rc != 0 or not workdir:
            raise OSError("agent workdir creation failed")
        # sh receives workdir as $1 ("run" is just $0); shift+exec leaves the
        # CLI as the pane process instead of a wrapping sh.
        # TMPDIR is required: without it the account's Background-session
        # dirhelper XPC hangs every CLI that calls temp_dir (codex, measured).
        panel = LOCK_ARGV + [self.tmux_bin, "-L", self.socket, "new-session", "-d",
                             "-s", session, "--", "sudo", "-n", "-u", AGENT_USER,
                             "-H", "env", "PATH=" + AGENT_PATH, "TMPDIR=" + workdir,
                             "/bin/sh", "-c",
                             'cd "$1" && shift && exec "$@"', "run", workdir, *command]
        if self._runner(panel).rc != 0:
            raise OSError("agent panel spawn failed")
        return workdir
