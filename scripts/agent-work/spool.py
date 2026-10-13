from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

TERMINAL_STATES = ("AbsenceVerified", "ReleasedAdopted")
SENDABLE_STATES = ("CleanupPending", "AbsenceVerified", "ReleasedAdopted")
SCHEMA_VERSION = 2
SETTLED = ("acknowledged", "abandoned", "cancelled")
DIALOG_STILL_OPEN = "left: permission dialog visible but Esc did not close it"
DIALOG_ATTEMPTS = 3
DIALOG_START = {"open_identity": None, "episode": 0, "candidate": None, "seen": 0, "clean": 0}


def canonical(data: object) -> str:
    return json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def closure_digest(evidence_json: str, proof_json: str | None = None) -> str:
    """What R receives as evidenceDigest. A closure that swept a process boundary also binds what it found,
    signalled and left there."""
    evidence = json.loads(evidence_json)
    if proof_json is not None:
        evidence = {"evidence": evidence, "proof": json.loads(proof_json)}
    return hashlib.sha256(canonical(evidence).encode()).hexdigest()


HOST_INCIDENT_KINDS = ("permission-required", "deadline-missed", "transport-unavailable",
                       "invalid-result")


def incident_identity(generation: int, incident: object) -> tuple[str, str]:
    if not isinstance(incident, dict):
        raise ValueError("host incident must be an object")
    kind = incident.get("kind")
    if kind not in HOST_INCIDENT_KINDS:
        raise ValueError("unknown host incident kind")
    identity_field = "promptIdentity" if kind == "permission-required" else "episodeId"
    if set(incident) != {"kind", identity_field, "evidenceRef"}:
        raise ValueError("host incident fields do not match its kind")
    for field in (identity_field, "evidenceRef"):
        if not isinstance(incident[field], str):
            raise ValueError(f"host incident {field} must be text")
    episode = incident[identity_field]

    def utf16_length(text: str) -> int:
        # zod .max/.min count string length in UTF-16 units, not code points.
        return len(text.encode("utf-16-le")) // 2

    if kind == "permission-required":
        if utf16_length(episode) < 1:
            raise ValueError("host incident promptIdentity must not be empty")
    elif not 1 <= utf16_length(episode) <= 256:
        raise ValueError("host incident episodeId must be 1..256 utf16 units")
    if utf16_length(incident["evidenceRef"]) < 1:
        raise ValueError("host incident evidenceRef must not be empty")
    return (f"host:{generation}:{kind}:{episode}",
            hashlib.sha256(canonical(incident).encode()).hexdigest())


def atomic_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(canonical(data) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def release_abandoned_sessions(db: sqlite3.Connection) -> None:
    """Every adopted session still held by an abandoned operation goes back to the operator untouched;
    the CLI is never stopped. Its tmux nonce stays until the next adoption clears it."""
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='resources'").fetchone():
        return
    db.execute("UPDATE resources SET state='ReleasedAdopted',reason='delivery abandoned',revision=revision+1 "
               "WHERE ownership='UserAdopted' "
               f"AND state NOT IN ({','.join('?' * len(TERMINAL_STATES))}) "
               "AND operation_id IN (SELECT operation_id FROM operations WHERE status='abandoned')",
               TERMINAL_STATES)


class Spool:
    def __init__(self, root: Path, host_id: str):
        self.root = root
        self.host_id = host_id
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        root.chmod(0o700)
        self.path = root / "host.sqlite"
        with self.connection() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS operations (
                    operation_id TEXT PRIMARY KEY,
                    instance_id TEXT NOT NULL,
                    operation_digest TEXT NOT NULL,
                    assignment_ref TEXT NOT NULL,
                    operation_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    result_id TEXT,
                    result_json TEXT,
                    receipt_json TEXT
                );
                CREATE TABLE IF NOT EXISTS inbox_errors (
                    operation_id TEXT PRIMARY KEY,
                    error TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS closure_sends (
                    operation_id TEXT PRIMARY KEY,
                    task_id TEXT NOT NULL,
                    generation INTEGER NOT NULL,
                    instance_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    evidence_digest TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS closure_sends_task_generation
                    ON closure_sends(task_id, generation);
                CREATE TABLE IF NOT EXISTS incidents (
                    task_id TEXT NOT NULL,
                    incident_key TEXT NOT NULL,
                    operation_id TEXT NOT NULL,
                    incident_json TEXT NOT NULL,
                    incident_digest TEXT NOT NULL,
                    status TEXT NOT NULL,
                    receipt_json TEXT,
                    error TEXT,
                    PRIMARY KEY (task_id, incident_key)
                );
                CREATE TABLE IF NOT EXISTS delivery_attempts (
                    operation_id TEXT PRIMARY KEY,
                    attempted_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS delivery_deferrals (
                    operation_id TEXT PRIMARY KEY,
                    first_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS closure_proofs (
                    operation_id TEXT PRIMARY KEY,
                    proof_json TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS delivery_clock (
                    operation_id TEXT PRIMARY KEY,
                    delivered_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS delivery_verdicts (
                    operation_id TEXT PRIMARY KEY,
                    previous_status TEXT NOT NULL,
                    verdict TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    decided_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS cancellations (
                    operation_id TEXT PRIMARY KEY,
                    cancellation_id TEXT NOT NULL,
                    dialog TEXT
                );
                CREATE TABLE IF NOT EXISTS reservation_claims (
                    operation_id TEXT PRIMARY KEY,
                    assignment_json TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS dialog_rejections (
                    operation_id TEXT PRIMARY KEY,
                    attempts INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS dialog_watch (
                    operation_id TEXT PRIMARY KEY,
                    open_identity TEXT,
                    episode INTEGER NOT NULL,
                    candidate TEXT,
                    seen INTEGER NOT NULL,
                    clean INTEGER NOT NULL
                );
            """)
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT value FROM metadata WHERE key='host_id'").fetchone()
            if row and row[0] != host_id:
                raise ValueError("host state belongs to another hostId")
            if not row:
                db.execute("INSERT INTO metadata VALUES ('host_id', ?)", (host_id,))
            if db.execute("PRAGMA user_version").fetchone()[0] < SCHEMA_VERSION:
                # 1: an abandoned operation no longer holds its instance. 2: nor does a cancelled one.
                db.execute("DROP INDEX IF EXISTS one_active_per_instance")
                db.execute("CREATE UNIQUE INDEX one_active_per_instance ON operations(instance_id) "
                           f"WHERE status NOT IN ({','.join(repr(status) for status in SETTLED)})")
                release_abandoned_sessions(db)
                db.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
        self.path.chmod(0o600)

    @contextmanager
    def connection(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            yield db
            db.commit()
        finally:
            db.close()

    def register(self, operation_id: str, instance_id: str, digest: str,
                 assignment_ref: str, operation: dict) -> dict:
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM operations WHERE operation_id=?", (operation_id,)).fetchone()
            if row:
                if row["operation_digest"] != digest:
                    raise ValueError("operation key conflicts with different content")
                return dict(row)
            try:
                db.execute("INSERT INTO operations VALUES (?,?,?,?,?,'registered',NULL,NULL,NULL)",
                           (operation_id, instance_id, digest, assignment_ref, canonical(operation)))
            except sqlite3.IntegrityError as exc:
                raise ValueError("active instance already owns an operation") from exc
            return dict(db.execute("SELECT * FROM operations WHERE operation_id=?", (operation_id,)).fetchone())

    def get(self, operation_id: str) -> dict | None:
        with self.connection() as db:
            row = db.execute("SELECT * FROM operations WHERE operation_id=?", (operation_id,)).fetchone()
            return dict(row) if row else None

    def find_assignment(self, task_id: str, generation: int) -> dict | None:
        with self.connection() as db:
            rows = db.execute("SELECT operation_json FROM operations").fetchall()
        matches = []
        for row in rows:
            assignment = json.loads(row[0])
            if assignment["taskId"] == task_id and assignment["generation"] == generation:
                matches.append(assignment)
        if len(matches) > 1:
            raise ValueError("multiple host operations for task generation")
        return matches[0] if matches else None

    def begin_delivery(self, operation_id: str) -> bool:
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            updated = db.execute("UPDATE operations SET status='attempted' "
                                 "WHERE operation_id=? AND status IN ('registered','deferred')",
                                 (operation_id,))
            if updated.rowcount != 1:
                return False
            db.execute("INSERT OR IGNORE INTO delivery_attempts VALUES (?,?)",
                       (operation_id, time.time()))
            return True

    def delivery_deferred(self, operation_id: str) -> None:
        """attempted -> deferred when the transport proved nothing was typed; the clock restarts on retry.
        The first deferral keeps its own time, so a delivery cannot be deferred for ever."""
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            updated = db.execute("UPDATE operations SET status='deferred' WHERE operation_id=? AND status='attempted'",
                                 (operation_id,))
            if updated.rowcount == 1:
                db.execute("DELETE FROM delivery_attempts WHERE operation_id=?", (operation_id,))
                db.execute("INSERT OR IGNORE INTO delivery_deferrals VALUES (?,?)", (operation_id, time.time()))

    def first_deferred_at(self, operation_id: str) -> float | None:
        with self.connection() as db:
            row = db.execute("SELECT first_at FROM delivery_deferrals WHERE operation_id=?",
                             (operation_id,)).fetchone()
        return row["first_at"] if row else None

    def resolve_delivery(self, operation_id: str, verdict: str, reason: str, now: float) -> bool:
        """attempted or uncertain -> the operator's verdict, recorded with it; False when it already left both.
        abandoned also releases the adopted session, so the instance and the host's capacity take new work."""
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT status FROM operations WHERE operation_id=?", (operation_id,)).fetchone()
            if row is None or row["status"] not in ("attempted", "uncertain"):
                return False
            db.execute("UPDATE operations SET status=? WHERE operation_id=?", (verdict, operation_id))
            db.execute("INSERT INTO delivery_verdicts VALUES (?,?,?,?,?)",
                       (operation_id, row["status"], verdict, reason, now))
            if verdict == "delivered":
                db.execute("INSERT OR IGNORE INTO delivery_clock VALUES (?,?)", (operation_id, now))
            else:
                release_abandoned_sessions(db)
            return True

    def delivered(self, operation_id: str) -> None:
        with self.connection() as db:
            updated = db.execute("UPDATE operations SET status='delivered' "
                                 "WHERE operation_id=? AND status IN ('attempted','uncertain')",
                                 (operation_id,))
            if updated.rowcount == 1:
                db.execute("INSERT OR IGNORE INTO delivery_clock VALUES (?,?)",
                           (operation_id, time.time()))

    def record(self, operation_id: str, result_id: str, result: dict, result_path: Path) -> None:
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT result_id FROM operations WHERE operation_id=?", (operation_id,)).fetchone()
            if row is None:
                raise ValueError("unknown operation")
            if row["result_id"] and row["result_id"] != result_id:
                raise ValueError("conflicting final result")
            if result_path.is_symlink():
                raise ValueError("result spool path is a symlink")
            if result_path.exists():
                if canonical(json.loads(result_path.read_text())) != canonical(result):
                    raise ValueError("conflicting final result")
            else:
                atomic_json(result_path, result)
            if row["result_id"]:
                return
            # A late result keeps an abandoned operation off the instance, which may hold new work now.
            db.execute("UPDATE operations SET result_id=?,result_json=?,"
                       "status=CASE WHEN status IN ('abandoned','cancelled') THEN status ELSE 'reported' END "
                       "WHERE operation_id=?",
                       (result_id, canonical(result), operation_id))

    def pending(self) -> list[dict]:
        with self.connection() as db:
            rows = db.execute("SELECT result_json FROM operations WHERE result_id IS NOT NULL AND receipt_json IS NULL "
                              "AND status != 'cancelled' ORDER BY operation_id").fetchall()
            return [json.loads(row[0]) for row in rows]

    def awaiting_results(self) -> list[dict]:
        with self.connection() as db:
            rows = db.execute("SELECT operation_json FROM operations WHERE result_id IS NULL AND status != 'cancelled' "
                              "ORDER BY operation_id").fetchall()
            return [json.loads(row[0]) for row in rows]

    def attempted_at(self, operation_id: str) -> float | None:
        with self.connection() as db:
            row = db.execute("SELECT attempted_at FROM delivery_attempts WHERE operation_id=?",
                             (operation_id,)).fetchone()
        return row["attempted_at"] if row else None

    def delivery_uncertain(self, operation_id: str, task_id: str, incident_key: str,
                           incident_json: str, incident_digest: str, *, deferred: bool = False) -> bool:
        """attempted -> uncertain together with its incident; False when it already left attempted. With
        deferred, a delivery that never left deferred ends the same way."""
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            updated = db.execute("UPDATE operations SET status='uncertain' WHERE operation_id=? "
                                 + ("AND status IN ('attempted','deferred')" if deferred else "AND status='attempted'"),
                                 (operation_id,))
            if updated.rowcount != 1:
                return False
            db.execute("INSERT OR IGNORE INTO incidents VALUES (?,?,?,?,?,'pending',NULL,NULL)",
                       (task_id, incident_key, operation_id, incident_json, incident_digest))
            return True

    def delivered_at(self, operation_id: str) -> float | None:
        with self.connection() as db:
            row = db.execute("SELECT delivered_at FROM delivery_clock WHERE operation_id=?",
                             (operation_id,)).fetchone()
        return row["delivered_at"] if row else None

    def has_incident(self, task_id: str, incident_key: str) -> bool:
        with self.connection() as db:
            row = db.execute("SELECT 1 FROM incidents WHERE task_id=? AND incident_key=?",
                             (task_id, incident_key)).fetchone()
        return row is not None

    def dialog_state(self, operation_id: str) -> dict:
        with self.connection() as db:
            row = db.execute("SELECT * FROM dialog_watch WHERE operation_id=?", (operation_id,)).fetchone()
        if row is None:
            return dict(DIALOG_START)
        return {field: row[field] for field in DIALOG_START}

    @staticmethod
    def _put_dialog(db, operation_id: str, state: dict) -> None:
        db.execute("INSERT INTO dialog_watch VALUES (?,?,?,?,?,?) "
                   "ON CONFLICT(operation_id) DO UPDATE SET open_identity=excluded.open_identity,"
                   "episode=excluded.episode,candidate=excluded.candidate,seen=excluded.seen,clean=excluded.clean",
                   (operation_id, state["open_identity"], state["episode"], state["candidate"],
                    state["seen"], state["clean"]))

    def save_dialog_state(self, operation_id: str, state: dict) -> None:
        with self.connection() as db:
            self._put_dialog(db, operation_id, state)

    def note_inbox_error(self, operation_id: str, error: str) -> None:
        with self.connection() as db:
            db.execute("INSERT INTO inbox_errors VALUES (?,?) ON CONFLICT(operation_id) DO UPDATE SET error=excluded.error",
                       (operation_id, error[:512]))

    def clear_inbox_error(self, operation_id: str) -> None:
        with self.connection() as db:
            db.execute("DELETE FROM inbox_errors WHERE operation_id=?", (operation_id,))

    def inbox_errors(self) -> list[dict]:
        with self.connection() as db:
            rows = db.execute("SELECT e.operation_id,o.operation_json,e.error FROM inbox_errors e "
                              "JOIN operations o ON o.operation_id=e.operation_id ORDER BY e.operation_id").fetchall()
            return [{"operationId": row[0], "taskId": json.loads(row[1])["taskId"], "error": row[2]}
                    for row in rows]

    def acknowledge(self, operation_id: str, receipt: dict) -> None:
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT receipt_json FROM operations WHERE operation_id=?", (operation_id,)).fetchone()
            if row is None:
                raise ValueError("unknown operation")
            if row["receipt_json"]:
                if json.loads(row["receipt_json"]) != receipt:
                    raise ValueError("conflicting receipt")
                return
            db.execute("UPDATE operations SET receipt_json=?,status='acknowledged' WHERE operation_id=?",
                       (canonical(receipt), operation_id))

    def cancel(self, operation_id: str, cancellation_id: str) -> dict:
        """R cancelled the task: the operation settles as cancelled, whatever it was waiting for, and keeps
        R's cancellation id as the evidence its resource closes with."""
        if not cancellation_id:
            raise ValueError("cancellation id required")
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM cancellations WHERE operation_id=?", (operation_id,)).fetchone()
            if row:
                if row["cancellation_id"] != cancellation_id:
                    raise ValueError("cancellation conflicts with a different id")
                return dict(row)
            updated = db.execute("UPDATE operations SET status='cancelled' WHERE operation_id=? "
                                 f"AND status NOT IN ({','.join('?' * len(SETTLED))})",
                                 (operation_id, *SETTLED))
            if updated.rowcount != 1:
                raise ValueError("only an unsettled operation can be cancelled")
            db.execute("INSERT INTO cancellations VALUES (?,?,NULL)", (operation_id, cancellation_id))
            return dict(db.execute("SELECT * FROM cancellations WHERE operation_id=?", (operation_id,)).fetchone())

    def reservation_claim(self, operation_id: str) -> dict | None:
        """The claim fields a reservation kept so its task can be read and closed in R before any operation
        is registered: hostId, taskId, generation, instanceId, producerId, capability and adapterId."""
        with self.connection() as db:
            row = db.execute("SELECT assignment_json FROM reservation_claims WHERE operation_id=?",
                             (operation_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def cancellation(self, operation_id: str) -> dict | None:
        with self.connection() as db:
            row = db.execute("SELECT * FROM cancellations WHERE operation_id=?", (operation_id,)).fetchone()
        return dict(row) if row else None

    def cancellation_dialog(self, operation_id: str, outcome: str) -> None:
        with self.connection() as db:
            db.execute("UPDATE cancellations SET dialog=? WHERE operation_id=? AND dialog IS NULL",
                       (outcome[:512], operation_id))

    def dialog_attempt(self, operation_id: str) -> int:
        """Count one more Esc that left a cancelled task's permission dialog on screen; returns the count."""
        with self.connection() as db:
            db.execute("INSERT INTO dialog_rejections VALUES (?,1) "
                       "ON CONFLICT(operation_id) DO UPDATE SET attempts=attempts+1", (operation_id,))
            return db.execute("SELECT attempts FROM dialog_rejections WHERE operation_id=?",
                              (operation_id,)).fetchone()[0]

    def record_incident(self, task_id: str, incident_key: str, operation_id: str,
                        incident_json: str, incident_digest: str, dialog_state: dict | None = None) -> dict:
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM incidents WHERE task_id=? AND incident_key=?",
                             (task_id, incident_key)).fetchone()
            if row:
                if row["incident_digest"] != incident_digest:
                    raise ValueError("incident conflicts with different evidence")
                return dict(row)
            if dialog_state is not None:
                self._put_dialog(db, operation_id, dialog_state)
            db.execute("INSERT INTO incidents VALUES (?,?,?,?,?,'pending',NULL,NULL)",
                       (task_id, incident_key, operation_id, incident_json, incident_digest))
            return dict(db.execute("SELECT * FROM incidents WHERE task_id=? AND incident_key=?",
                                   (task_id, incident_key)).fetchone())

    def pending_incidents(self) -> list[dict]:
        with self.connection() as db:
            rows = db.execute("SELECT * FROM incidents WHERE status='pending' "
                              "ORDER BY task_id, incident_key").fetchall()
            return [dict(row) for row in rows]

    def incident_sent(self, task_id: str, incident_key: str, receipt: dict) -> None:
        with self.connection() as db:
            db.execute("UPDATE incidents SET status='sent', receipt_json=?, error=NULL "
                       "WHERE task_id=? AND incident_key=? AND status='pending'",
                       (canonical(receipt), task_id, incident_key))

    def incident_failed(self, task_id: str, incident_key: str, error: str,
                        rejected: bool = False) -> None:
        with self.connection() as db:
            if rejected:
                db.execute("UPDATE incidents SET status='rejected', error=? "
                           "WHERE task_id=? AND incident_key=? AND status='pending'",
                           (error[:512], task_id, incident_key))
            else:
                db.execute("UPDATE incidents SET error=? "
                           "WHERE task_id=? AND incident_key=? AND status='pending'",
                           (error[:512], task_id, incident_key))

    def closure_rows(self) -> list[dict]:
        # Only ResourceManager builds the resources table; without one there
        # is nothing to send.
        try:
            with self.connection() as db:
                rows = db.execute(
                    f"SELECT * FROM resources WHERE evidence_json IS NOT NULL "
                    f"AND state IN ({','.join('?' * len(SENDABLE_STATES))}) ORDER BY operation_id",
                    SENDABLE_STATES,
                ).fetchall()
        except sqlite3.OperationalError as exc:
            if "no such table" not in str(exc):
                raise OSError(str(exc)) from exc
            return []
        return [dict(row) for row in rows]

    def save_closure_proof(self, operation_id: str, proof: dict) -> None:
        """What the last closing sweep of this resource found, signalled and left."""
        with self.connection() as db:
            db.execute("INSERT INTO closure_proofs VALUES (?,?) "
                       "ON CONFLICT(operation_id) DO UPDATE SET proof_json=excluded.proof_json",
                       (operation_id, canonical(proof)))

    def closure_proof(self, operation_id: str) -> str | None:
        with self.connection() as db:
            row = db.execute("SELECT proof_json FROM closure_proofs WHERE operation_id=?",
                             (operation_id,)).fetchone()
        return row["proof_json"] if row else None

    def closure_last(self, operation_id: str) -> dict | None:
        with self.connection() as db:
            row = db.execute("SELECT * FROM closure_sends WHERE operation_id=?", (operation_id,)).fetchone()
        return dict(row) if row else None

    def closure_terminal(self, task_id: str, generation: int) -> dict | None:
        with self.connection() as db:
            rows = db.execute("SELECT state FROM closure_sends WHERE task_id=? AND generation=?",
                              (task_id, generation)).fetchall()
        for row in rows:
            if row["state"] in TERMINAL_STATES:
                return {"state": row["state"]}
        return None

    def closure_record(self, operation_id: str, task_id: str, generation: int, instance_id: str,
                       state: str, reason: str, evidence_digest: str) -> None:
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute(
                "INSERT INTO closure_sends VALUES (?,?,?,?,?,?,?) "
                "ON CONFLICT(operation_id) DO UPDATE SET task_id=excluded.task_id,"
                "generation=excluded.generation,instance_id=excluded.instance_id,"
                "state=excluded.state,reason=excluded.reason,evidence_digest=excluded.evidence_digest",
                (operation_id, task_id, generation, instance_id, state, reason, evidence_digest))
