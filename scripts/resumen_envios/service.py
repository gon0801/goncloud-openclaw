from __future__ import annotations

from contextlib import contextmanager
from datetime import time
import fcntl
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, Optional, Set
from uuid import uuid4
from zoneinfo import ZoneInfo

from .delivery import DeliveryRunner, FakeTransportHub
from .domain import SourceReport, parse_instant
from .planner import seal_plan
from .policy import assess_sources, source_assessment
from .store import Store


class CutService:
    def __init__(self, store: Store, transports: FakeTransportHub, lock_dir: Path, holidays: Optional[Set[str]] = None):
        self.store = store
        self.transports = transports
        self.lock_dir = Path(lock_dir)
        self.lock_dir.mkdir(parents=True, exist_ok=True)
        self.holidays = holidays

    def runner(self) -> DeliveryRunner:
        return DeliveryRunner(self.store, self.transports, self.lock_dir, "worker-" + uuid4().hex)

    @contextmanager
    def planning_lock(self) -> Iterator[None]:
        handle = (self.lock_dir / "planning.lock").open("a+")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            handle.close()

    def advance_cut(self, kind: str, local_date: str, scheduled_at: str, reports: Iterable[SourceReport], deliver: bool = True) -> Dict[str, Any]:
        cut_id = self.store.ensure_cut(kind, local_date)
        instant = parse_instant(scheduled_at)
        for report in reports:
            late = self.store.get_cut(cut_id)["sealed_revision"] is not None
            status, details, _ = source_assessment(report, kind, instant, self.holidays)
            self.store.save_source(cut_id, report, status, details, late)
        if self.store.get_cut(cut_id)["sealed_revision"] is not None:
            self.store.close_cut(cut_id)
            return self.store.view(cut_id)
        if kind == "principal":
            local_instant = instant.astimezone(ZoneInfo("America/Vancouver"))
            if local_instant.time() < time(18, 15):
                return self.store.view(cut_id)
            if local_instant.time() < time(18, 30):
                latest = self.store.latest_reports(cut_id)
                assessment = assess_sources(latest, kind, instant, self.holidays)
                self.store.save_assessment(cut_id, assessment.as_dict(), assessment.complete, False)
                return self.store.view(cut_id)
        with self.planning_lock():
            if self.store.get_cut(cut_id)["sealed_revision"] is not None:
                self.store.close_cut(cut_id)
                return self.store.view(cut_id)
            latest = self.store.latest_reports(cut_id)
            assessment = assess_sources(latest, kind, instant, self.holidays)
            seal_plan(self.store, cut_id, kind, local_date, scheduled_at, assessment)
        if deliver:
            self.runner().deliver_pending(current_cut=cut_id)
        self.store.close_cut(cut_id)
        return self.store.view(cut_id)

    def resume_cut(self, cut_id: str) -> Dict[str, Any]:
        runner = self.runner()
        runner.recover()
        runner.deliver_pending(current_cut=cut_id)
        self.store.close_cut(cut_id)
        return self.store.view(cut_id)

    def reconcile_attempt(self, attempt_id: str) -> Dict[str, Any]:
        self.runner().recover()
        return self.store.attempt(attempt_id)

    def close_cut(self, cut_id: str) -> str:
        return self.store.close_cut(cut_id)

    def view(self, cut_id: str) -> Dict[str, Any]:
        return self.store.view(cut_id)
