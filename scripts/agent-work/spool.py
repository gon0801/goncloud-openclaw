from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import tempfile
from contextlib import contextmanager
from pathlib import Path

TERMINAL_STATES = ("AbsenceVerified", "ReleasedAdopted")
SENDABLE_STATES = ("CleanupPending", "AbsenceVerified", "ReleasedAdopted")


def canonical(data: object) -> str:
    return json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def closure_digest(evidence_json: str) -> str:
    return hashlib.sha256(canonical(json.loads(evidence_json)).encode()).hexdigest()


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
                CREATE UNIQUE INDEX IF NOT EXISTS one_active_per_instance
                    ON operations(instance_id) WHERE status != 'acknowledged';
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
            """)
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT value FROM metadata WHERE key='host_id'").fetchone()
            if row and row[0] != host_id:
                raise ValueError("host state belongs to another hostId")
            if not row:
                db.execute("INSERT INTO metadata VALUES ('host_id', ?)", (host_id,))
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
            updated = db.execute("UPDATE operations SET status='attempted' WHERE operation_id=? AND status='registered'",
                                 (operation_id,))
            return updated.rowcount == 1

    def delivered(self, operation_id: str) -> None:
        with self.connection() as db:
            db.execute("UPDATE operations SET status='delivered' WHERE operation_id=? AND status='attempted'",
                       (operation_id,))

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
            db.execute("UPDATE operations SET result_id=?,result_json=?,status='reported' WHERE operation_id=?",
                       (result_id, canonical(result), operation_id))

    def pending(self) -> list[dict]:
        with self.connection() as db:
            rows = db.execute("SELECT result_json FROM operations WHERE result_id IS NOT NULL AND receipt_json IS NULL ORDER BY operation_id").fetchall()
            return [json.loads(row[0]) for row in rows]

    def awaiting_results(self) -> list[dict]:
        with self.connection() as db:
            rows = db.execute("SELECT operation_json FROM operations WHERE result_id IS NULL ORDER BY operation_id").fetchall()
            return [json.loads(row[0]) for row in rows]

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

    def record_incident(self, task_id: str, incident_key: str, operation_id: str,
                        incident_json: str, incident_digest: str) -> dict:
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM incidents WHERE task_id=? AND incident_key=?",
                             (task_id, incident_key)).fetchone()
            if row:
                if row["incident_digest"] != incident_digest:
                    raise ValueError("incident conflicts with different evidence")
                return dict(row)
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
