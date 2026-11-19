from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sqlite3
from typing import Any, Dict, Iterable, Iterator, List, Mapping, Optional, Sequence, Tuple
from uuid import uuid4

from .domain import NoticeKey, SourceReport, notice_from_text, parse_instant


SCHEMA = """
CREATE TABLE IF NOT EXISTS cuts (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    local_date TEXT NOT NULL,
    state TEXT NOT NULL,
    sealed_revision INTEGER,
    sources_complete INTEGER,
    draft_json TEXT,
    UNIQUE(kind, local_date)
);
CREATE TABLE IF NOT EXISTS sources (
    cut_id TEXT NOT NULL,
    source_key TEXT NOT NULL,
    revision INTEGER NOT NULL,
    status TEXT NOT NULL,
    details_json TEXT NOT NULL,
    report_json TEXT NOT NULL,
    received_at TEXT NOT NULL,
    late INTEGER NOT NULL,
    PRIMARY KEY(cut_id, source_key, revision)
);
CREATE TABLE IF NOT EXISTS plans (
    cut_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    sealed INTEGER NOT NULL,
    sources_complete INTEGER NOT NULL,
    assessment_json TEXT NOT NULL,
    PRIMARY KEY(cut_id, revision)
);
CREATE TABLE IF NOT EXISTS obligations (
    id TEXT PRIMARY KEY,
    notice_json TEXT NOT NULL UNIQUE,
    state TEXT NOT NULL,
    opened_cut TEXT,
    asset_ref TEXT,
    opened_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS units (
    id TEXT PRIMARY KEY,
    cut_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    channel TEXT NOT NULL,
    recipient TEXT NOT NULL,
    kind TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    content TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    state TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS unit_members (
    unit_id TEXT NOT NULL,
    notice_id TEXT NOT NULL,
    PRIMARY KEY(unit_id, notice_id)
);
CREATE TABLE IF NOT EXISTS attempts (
    id TEXT PRIMARY KEY,
    unit_id TEXT NOT NULL,
    worker_id TEXT NOT NULL,
    fencing INTEGER NOT NULL,
    state TEXT NOT NULL,
    receipt TEXT,
    error TEXT,
    started_at TEXT NOT NULL,
    finished_at TEXT
);
CREATE INDEX IF NOT EXISTS attempts_unit_state ON attempts(unit_id, state);
CREATE TABLE IF NOT EXISTS cut_obligations (
    cut_id TEXT NOT NULL,
    notice_id TEXT NOT NULL,
    PRIMARY KEY(cut_id, notice_id)
);
CREATE TABLE IF NOT EXISTS issues (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cut_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    subject TEXT NOT NULL,
    reason TEXT NOT NULL,
    resolved INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS history_assertions (
    id TEXT PRIMARY KEY,
    notice_id TEXT NOT NULL,
    confidence TEXT NOT NULL,
    reason TEXT NOT NULL,
    source_hash TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS history_notice ON history_assertions(notice_id, confidence);
CREATE TABLE IF NOT EXISTS watermarks (
    channel TEXT NOT NULL,
    recipient TEXT NOT NULL,
    complete_since TEXT NOT NULL,
    PRIMARY KEY(channel, recipient)
);
"""


def dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class Store:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.con = sqlite3.connect(str(self.path), timeout=30, isolation_level=None, check_same_thread=False)
        self.con.row_factory = sqlite3.Row
        self.con.execute("PRAGMA journal_mode=WAL")
        self.con.execute("PRAGMA foreign_keys=ON")
        self.con.execute("PRAGMA busy_timeout=30000")
        self.con.executescript(SCHEMA)

    def close(self) -> None:
        self.con.close()

    @contextmanager
    def transaction(self) -> Iterator[None]:
        self.con.execute("BEGIN IMMEDIATE")
        try:
            yield
        except Exception:
            self.con.rollback()
            raise
        self.con.commit()

    def cut_id(self, kind: str, local_date: str) -> str:
        return kind + ":" + local_date

    def ensure_cut(self, kind: str, local_date: str) -> str:
        cut = self.cut_id(kind, local_date)
        with self.transaction():
            self.con.execute(
                "INSERT OR IGNORE INTO cuts(id,kind,local_date,state) VALUES(?,?,?,'collecting')",
                (cut, kind, local_date),
            )
        return cut

    def get_cut(self, cut_id: str) -> Dict[str, Any]:
        row = self.con.execute("SELECT * FROM cuts WHERE id=?", (cut_id,)).fetchone()
        if row is None:
            raise KeyError(cut_id)
        return dict(row)

    def save_source(self, cut_id: str, report: SourceReport, status: str, details: Mapping[str, Any], late: bool) -> int:
        with self.transaction():
            row = self.con.execute(
                "SELECT COALESCE(MAX(revision),0)+1 AS revision FROM sources WHERE cut_id=? AND source_key=?",
                (cut_id, report.key),
            ).fetchone()
            revision = int(row["revision"])
            self.con.execute(
                "INSERT INTO sources(cut_id,source_key,revision,status,details_json,report_json,received_at,late) VALUES(?,?,?,?,?,?,?,?)",
                (cut_id, report.key, revision, status, dumps(details), dumps(report.as_dict()), report.received_at, int(late)),
            )
        return revision

    def latest_reports(self, cut_id: str) -> List[SourceReport]:
        rows = self.con.execute(
            "SELECT s.report_json FROM sources s JOIN (SELECT source_key,MAX(revision) AS revision FROM sources WHERE cut_id=? GROUP BY source_key) latest ON latest.source_key=s.source_key AND latest.revision=s.revision WHERE s.cut_id=?",
            (cut_id, cut_id),
        ).fetchall()
        return [SourceReport.from_dict(json.loads(row["report_json"])) for row in rows]

    def save_assessment(self, cut_id: str, assessment: Mapping[str, Any], complete: bool, sealed: bool) -> int:
        with self.transaction():
            row = self.con.execute("SELECT COALESCE(MAX(revision),0)+1 AS revision FROM plans WHERE cut_id=?", (cut_id,)).fetchone()
            revision = int(row["revision"])
            self.con.execute(
                "INSERT INTO plans(cut_id,revision,sealed,sources_complete,assessment_json) VALUES(?,?,?,?,?)",
                (cut_id, revision, int(sealed), int(complete), dumps(assessment)),
            )
            if sealed:
                self.con.execute(
                    "UPDATE cuts SET sealed_revision=?,sources_complete=?,state='sealed' WHERE id=?",
                    (revision, int(complete), cut_id),
                )
            else:
                self.con.execute("UPDATE cuts SET draft_json=?,state='assembling' WHERE id=?", (dumps(assessment), cut_id))
        return revision

    def sealed_assessment(self, cut_id: str) -> Dict[str, Any]:
        cut = self.get_cut(cut_id)
        if cut["sealed_revision"] is None:
            return {}
        row = self.con.execute(
            "SELECT assessment_json FROM plans WHERE cut_id=? AND revision=?",
            (cut_id, cut["sealed_revision"]),
        ).fetchone()
        return json.loads(row["assessment_json"])

    def watermark(self, channel: str, recipient: str, complete_since: str) -> None:
        with self.transaction():
            self.con.execute(
                "INSERT INTO watermarks(channel,recipient,complete_since) VALUES(?,?,?) ON CONFLICT(channel,recipient) DO UPDATE SET complete_since=excluded.complete_since",
                (channel, recipient, complete_since),
            )

    def import_notice(self, notice: NoticeKey, state: str, reason: str, source_hash: str) -> None:
        confidence = {"satisfied": "CONFIRMED_EXACT", "open": "OPEN_KNOWN", "unknown": "AMBIGUOUS"}[state]
        assertion_id = hashlib.sha256(dumps([notice.text(), confidence, reason, source_hash]).encode("utf-8")).hexdigest()
        with self.transaction():
            self.con.execute(
                "INSERT OR REPLACE INTO history_assertions(id,notice_id,confidence,reason,source_hash) VALUES(?,?,?,?,?)",
                (assertion_id, notice.text(), confidence, reason, source_hash),
            )
            self.con.execute(
                "INSERT OR IGNORE INTO obligations(id,notice_json,state,opened_at) VALUES(?,?,?,?)",
                (uuid4().hex, notice.text(), state, utc_now()),
            )

    def coverage(self, notice: NoticeKey, first_seen_at: str) -> str:
        row = self.con.execute("SELECT state FROM obligations WHERE notice_json=?", (notice.text(),)).fetchone()
        if row:
            return "CONFIRMED" if row["state"] in {"satisfied", "closed_not_required"} else ("UNKNOWN" if row["state"] == "unknown" else "OPEN_KNOWN")
        ambiguous = self.con.execute(
            "SELECT 1 FROM history_assertions WHERE notice_id=? AND confidence IN ('AMBIGUOUS','CONTRADICTORY','UNREADABLE') LIMIT 1",
            (notice.text(),),
        ).fetchone()
        if ambiguous:
            return "UNKNOWN"
        watermark = self.con.execute(
            "SELECT complete_since FROM watermarks WHERE channel=? AND recipient=?",
            (notice.channel, notice.recipient),
        ).fetchone()
        if watermark and parse_instant(first_seen_at) >= parse_instant(watermark["complete_since"]):
            return "NOT_OPENED_VERIFIED"
        return "UNKNOWN"

    def open_obligation(self, notice: NoticeKey, cut_id: str, state: str = "open", asset_ref: Optional[str] = None) -> str:
        with self.transaction():
            row = self.con.execute("SELECT id,state FROM obligations WHERE notice_json=?", (notice.text(),)).fetchone()
            if row is None:
                obligation_id = uuid4().hex
                self.con.execute(
                    "INSERT INTO obligations(id,notice_json,state,opened_cut,asset_ref,opened_at) VALUES(?,?,?,?,?,?)",
                    (obligation_id, notice.text(), state, cut_id, asset_ref, utc_now()),
                )
            else:
                obligation_id = row["id"]
                if row["state"] == "awaiting_asset" and state == "open":
                    self.con.execute("UPDATE obligations SET state='open',asset_ref=? WHERE id=?", (asset_ref, obligation_id))
                elif asset_ref and row["state"] == "open":
                    self.con.execute("UPDATE obligations SET asset_ref=? WHERE id=?", (asset_ref, obligation_id))
            self.con.execute("INSERT OR IGNORE INTO cut_obligations(cut_id,notice_id) VALUES(?,?)", (cut_id, obligation_id))
        return obligation_id

    def obligation_state(self, notice: NoticeKey) -> Optional[str]:
        row = self.con.execute("SELECT state FROM obligations WHERE notice_json=?", (notice.text(),)).fetchone()
        return row["state"] if row else None

    def obligation_id(self, notice: NoticeKey) -> Optional[str]:
        row = self.con.execute("SELECT id FROM obligations WHERE notice_json=?", (notice.text(),)).fetchone()
        return row["id"] if row else None

    def link_obligation(self, cut_id: str, notice: NoticeKey) -> None:
        obligation_id = self.obligation_id(notice)
        if obligation_id:
            with self.transaction():
                self.con.execute("INSERT OR IGNORE INTO cut_obligations(cut_id,notice_id) VALUES(?,?)", (cut_id, obligation_id))

    def summaries_blocking(self, cut_id: str) -> int:
        row = self.con.execute(
            "SELECT COUNT(*) AS n FROM units WHERE cut_id=? AND kind='summary' AND state IN ('planned','in_flight','retryable','uncertain')",
            (cut_id,),
        ).fetchone()
        return int(row["n"])

    def assigned_obligations(self) -> set:
        rows = self.con.execute(
            "SELECT DISTINCT m.notice_id FROM unit_members m JOIN units u ON u.id=m.unit_id WHERE u.state IN ('planned','in_flight','retryable','uncertain')"
        ).fetchall()
        return {row["notice_id"] for row in rows}

    def add_issue(self, cut_id: str, kind: str, subject: str, reason: str) -> None:
        with self.transaction():
            exists = self.con.execute(
                "SELECT 1 FROM issues WHERE cut_id=? AND kind=? AND subject=? AND reason=? AND resolved=0",
                (cut_id, kind, subject, reason),
            ).fetchone()
            if not exists:
                self.con.execute("INSERT INTO issues(cut_id,kind,subject,reason) VALUES(?,?,?,?)", (cut_id, kind, subject, reason))

    def create_unit(self, cut_id: str, revision: int, channel: str, recipient: str, kind: str, ordinal: int, content: str, notices: Sequence[NoticeKey], created_at: str) -> str:
        identity = dumps([cut_id, revision, channel, recipient, kind, ordinal])
        unit_id = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:24]
        content_hash = hashlib.sha256(content.encode("utf-8")).hexdigest()
        with self.transaction():
            self.con.execute(
                "INSERT INTO units(id,cut_id,revision,channel,recipient,kind,ordinal,content,content_hash,state,created_at) VALUES(?,?,?,?,?,?,?,?,?,'planned',?)",
                (unit_id, cut_id, revision, channel, recipient, kind, ordinal, content, content_hash, created_at),
            )
            for notice in notices:
                obligation = self.con.execute("SELECT id FROM obligations WHERE notice_json=?", (notice.text(),)).fetchone()
                if obligation is None:
                    raise ValueError("obligación inexistente en unidad")
                self.con.execute("INSERT INTO unit_members(unit_id,notice_id) VALUES(?,?)", (unit_id, obligation["id"]))
                self.con.execute("INSERT OR IGNORE INTO cut_obligations(cut_id,notice_id) VALUES(?,?)", (cut_id, obligation["id"]))
        return unit_id

    def unit(self, unit_id: str) -> Dict[str, Any]:
        row = self.con.execute("SELECT * FROM units WHERE id=?", (unit_id,)).fetchone()
        if row is None:
            raise KeyError(unit_id)
        result = dict(row)
        result["members"] = [notice_from_text(row["notice_json"]).as_dict() for row in self.con.execute("SELECT o.notice_json FROM unit_members m JOIN obligations o ON o.id=m.notice_id WHERE m.unit_id=?", (unit_id,)).fetchall()]
        return result

    def pending_units(self) -> List[Dict[str, Any]]:
        rows = self.con.execute("SELECT id FROM units WHERE state IN ('planned','retryable') ORDER BY created_at,id").fetchall()
        return [self.unit(row["id"]) for row in rows]

    def claim_unit(self, unit_id: str, worker_id: str, now: str) -> Optional[Dict[str, Any]]:
        with self.transaction():
            row = self.con.execute("SELECT state FROM units WHERE id=?", (unit_id,)).fetchone()
            if row is None or row["state"] not in {"planned", "retryable"}:
                return None
            active = self.con.execute("SELECT 1 FROM attempts WHERE unit_id=? AND state='in_flight'", (unit_id,)).fetchone()
            if active:
                return None
            fencing_row = self.con.execute("SELECT COALESCE(MAX(fencing),0)+1 AS fencing FROM attempts WHERE unit_id=?", (unit_id,)).fetchone()
            attempt_id = uuid4().hex
            fencing = int(fencing_row["fencing"])
            self.con.execute("UPDATE units SET state='in_flight' WHERE id=?", (unit_id,))
            self.con.execute(
                "INSERT INTO attempts(id,unit_id,worker_id,fencing,state,started_at) VALUES(?,?,?,?,'in_flight',?)",
                (attempt_id, unit_id, worker_id, fencing, now),
            )
        return {"id": attempt_id, "unit_id": unit_id, "worker_id": worker_id, "fencing": fencing, "state": "in_flight"}

    def attempt(self, attempt_id: str) -> Dict[str, Any]:
        row = self.con.execute("SELECT * FROM attempts WHERE id=?", (attempt_id,)).fetchone()
        if row is None:
            raise KeyError(attempt_id)
        return dict(row)

    def attempts(self, states: Sequence[str]) -> List[Dict[str, Any]]:
        placeholders = ",".join("?" for _ in states)
        rows = self.con.execute(f"SELECT * FROM attempts WHERE state IN ({placeholders}) ORDER BY started_at,id", states).fetchall()
        return [dict(row) for row in rows]

    def finish_attempt(self, attempt_id: str, worker_id: str, outcome: str, receipt: Optional[str], error: Optional[str], now: str) -> None:
        unit_state = {"accepted": "confirmed", "rejected": "retryable", "unknown": "uncertain"}[outcome]
        with self.transaction():
            attempt = self.con.execute("SELECT * FROM attempts WHERE id=?", (attempt_id,)).fetchone()
            if attempt is None or attempt["worker_id"] != worker_id:
                raise ValueError("intento o propietario inválido")
            if attempt["state"] == "accepted" and outcome == "accepted" and attempt["receipt"] == receipt:
                return
            if attempt["state"] not in {"in_flight", "unknown"}:
                raise ValueError("intento ya resuelto")
            self.con.execute(
                "UPDATE attempts SET state=?,receipt=?,error=?,finished_at=? WHERE id=?",
                (outcome, receipt, error, now, attempt_id),
            )
            self.con.execute("UPDATE units SET state=? WHERE id=?", (unit_state, attempt["unit_id"]))
            if outcome == "accepted":
                self.con.execute(
                    "UPDATE obligations SET state='satisfied' WHERE id IN (SELECT notice_id FROM unit_members WHERE unit_id=?)",
                    (attempt["unit_id"],),
                )

    def mark_attempt_unknown(self, attempt_id: str, now: str) -> None:
        with self.transaction():
            attempt = self.con.execute("SELECT state,unit_id FROM attempts WHERE id=?", (attempt_id,)).fetchone()
            if attempt and attempt["state"] == "in_flight":
                self.con.execute("UPDATE attempts SET state='unknown',error='resultado_perdido',finished_at=? WHERE id=?", (now, attempt_id))
                self.con.execute("UPDATE units SET state='uncertain' WHERE id=?", (attempt["unit_id"],))

    def reconcile_absent(self, attempt_id: str, now: str) -> None:
        with self.transaction():
            attempt = self.con.execute("SELECT state,unit_id FROM attempts WHERE id=?", (attempt_id,)).fetchone()
            if attempt is None or attempt["state"] not in {"unknown", "in_flight"}:
                raise ValueError("solo un intento incierto puede marcarse ausente")
            self.con.execute("UPDATE attempts SET state='rejected',error='ausencia_confirmada',finished_at=? WHERE id=?", (now, attempt_id))
            self.con.execute("UPDATE units SET state='retryable' WHERE id=?", (attempt["unit_id"],))

    def close_cut(self, cut_id: str) -> str:
        with self.transaction():
            cut = self.con.execute("SELECT * FROM cuts WHERE id=?", (cut_id,)).fetchone()
            if cut["state"] == "partial":
                return "partial"
            open_obligations = self.con.execute(
                "SELECT COUNT(*) AS n FROM cut_obligations c JOIN obligations o ON o.id=c.notice_id WHERE c.cut_id=? AND o.state IN ('open','awaiting_asset','unknown')",
                (cut_id,),
            ).fetchone()["n"]
            open_units = self.con.execute(
                "SELECT COUNT(*) AS n FROM units WHERE cut_id=? AND state IN ('planned','in_flight','retryable','uncertain')",
                (cut_id,),
            ).fetchone()["n"]
            issues = self.con.execute("SELECT COUNT(*) AS n FROM issues WHERE cut_id=? AND resolved=0", (cut_id,)).fetchone()["n"]
            if cut["sealed_revision"] is None:
                state = "pending"
            elif not cut["sources_complete"]:
                state = "partial"
            elif open_obligations or open_units or issues:
                state = "pending"
            else:
                state = "complete"
            self.con.execute("UPDATE cuts SET state=? WHERE id=?", (state, cut_id))
        return state

    def view(self, cut_id: str) -> Dict[str, Any]:
        cut = self.get_cut(cut_id)
        source_rows = self.con.execute(
            "SELECT s.source_key,s.status,s.details_json,s.late FROM sources s JOIN (SELECT source_key,MAX(revision) AS revision FROM sources WHERE cut_id=? GROUP BY source_key) latest ON latest.source_key=s.source_key AND latest.revision=s.revision WHERE s.cut_id=?",
            (cut_id, cut_id),
        ).fetchall()
        units = [dict(row) for row in self.con.execute("SELECT id,cut_id,revision,channel,recipient,kind,ordinal,content_hash,state,created_at FROM units WHERE cut_id=? ORDER BY revision,channel,recipient,kind,ordinal", (cut_id,)).fetchall()]
        obligations = [dict(row) for row in self.con.execute("SELECT o.notice_json,o.state,o.opened_cut FROM cut_obligations c JOIN obligations o ON o.id=c.notice_id WHERE c.cut_id=?", (cut_id,)).fetchall()]
        issues = [dict(row) for row in self.con.execute("SELECT id,kind,subject,reason,resolved FROM issues WHERE cut_id=?", (cut_id,)).fetchall()]
        return {
            "cut": cut,
            "sources": [{"source_key": row["source_key"], "status": row["status"], "details": json.loads(row["details_json"]), "late": bool(row["late"])} for row in source_rows],
            "assessment": self.sealed_assessment(cut_id) or (json.loads(cut["draft_json"]) if cut["draft_json"] else {}),
            "units": units,
            "obligations": obligations,
            "issues": issues,
        }
