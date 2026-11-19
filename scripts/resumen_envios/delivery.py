from __future__ import annotations

from dataclasses import dataclass
import fcntl
from pathlib import Path
import threading
from typing import Any, Callable, Dict, List, Mapping, Optional

from .domain import notice_from_text
from .store import Store, dumps, utc_now


class SimulatedCrash(Exception):
    pass


@dataclass(frozen=True)
class TransportOutcome:
    outcome: str
    receipt: Optional[str] = None
    error: Optional[str] = None


class FakeTransportHub:
    def __init__(self):
        self.outbox: List[Dict[str, Any]] = []
        self.rules: Dict[str, str] = {}
        self.lookup_rules: Dict[str, str] = {}
        self.active: set = set()
        self.lock = threading.Lock()

    def send(self, unit: Mapping[str, Any], attempt: Mapping[str, Any]) -> TransportOutcome:
        with self.lock:
            if unit["id"] in self.active:
                raise AssertionError("entrega simultánea de la misma parte")
            self.active.add(unit["id"])
        try:
            behavior = self.rules.get(unit["id"], "accepted")
            if behavior == "rejected":
                return TransportOutcome("rejected", error="rechazo_conocido")
            entry = {
                "unit_id": unit["id"],
                "attempt_id": attempt["id"],
                "channel": unit["channel"],
                "recipient": unit["recipient"],
                "kind": unit["kind"],
                "ordinal": unit["ordinal"],
                "content": unit["content"],
                "members": unit["members"],
            }
            if behavior in {"accepted", "unknown_after_accept", "crash_after_accept"}:
                with self.lock:
                    entry["receipt"] = "receipt-" + str(len(self.outbox) + 1)
                    self.outbox.append(entry)
                if behavior == "crash_after_accept":
                    raise SimulatedCrash("caída después de aceptar")
                if behavior == "unknown_after_accept":
                    return TransportOutcome("unknown", error="respuesta_perdida")
                return TransportOutcome("accepted", receipt=entry["receipt"])
            return TransportOutcome("unknown", error="resultado_incierto_sin_recibo")
        finally:
            with self.lock:
                self.active.discard(unit["id"])

    def locate(self, unit: Mapping[str, Any], attempt: Mapping[str, Any]) -> TransportOutcome:
        forced = self.lookup_rules.get(attempt["id"])
        if forced == "unknown":
            return TransportOutcome("unknown", error="sin_consulta_fiable")
        for entry in self.outbox:
            if entry["attempt_id"] == attempt["id"]:
                return TransportOutcome("accepted", receipt=entry["receipt"])
        if forced == "rejected":
            return TransportOutcome("rejected", error="ausencia_confirmada")
        if unit["channel"] == "telegram":
            return TransportOutcome("unknown", error="sin_consulta_fiable")
        return TransportOutcome("rejected", error="ausencia_confirmada")


class DeliveryRunner:
    def __init__(self, store: Store, transports: FakeTransportHub, lock_dir: Path, worker_id: str = "worker", now: Callable[[], str] = utc_now):
        self.store = store
        self.transports = transports
        self.lock_dir = Path(lock_dir)
        self.lock_dir.mkdir(parents=True, exist_ok=True)
        self.worker_id = worker_id
        self.now = now

    def _lock(self, unit_id: str, nonblocking: bool = False):
        handle = (self.lock_dir / (unit_id + ".lock")).open("a+")
        flags = fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0)
        try:
            fcntl.flock(handle.fileno(), flags)
        except Exception:
            handle.close()
            raise
        return handle

    def deliver_pending(self, current_cut: Optional[str] = None, stop_after: Optional[int] = None) -> int:
        delivered = 0
        units = sorted(
            self.store.pending_units(),
            key=lambda unit: (unit["kind"] == "photo", unit["created_at"], unit["id"]),
        )
        for unit in units:
            if unit["kind"] == "photo" and self.store.summaries_blocking(unit["cut_id"]):
                continue
            if current_cut:
                for member in unit["members"]:
                    self.store.link_obligation(current_cut, notice_from_text(dumps(member)))
            if not self._deliver(unit):
                continue
            delivered += 1
            if stop_after is not None and delivered >= stop_after:
                raise SimulatedCrash("interrupción posterior a la primera entrega")
        return delivered

    def _deliver(self, unit: Mapping[str, Any]) -> bool:
        lock = self._lock(unit["id"])
        try:
            current = self.store.unit(unit["id"])
            if current["state"] not in {"planned", "retryable"}:
                return False
            attempt = self.store.claim_unit(unit["id"], self.worker_id, self.now())
            if attempt is None:
                return False
            outcome = self.transports.send(current, attempt)
            self.store.finish_attempt(attempt["id"], self.worker_id, outcome.outcome, outcome.receipt, outcome.error, self.now())
            return outcome.outcome == "accepted"
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
            lock.close()

    def recover(self) -> Dict[str, int]:
        recovered = {"confirmed": 0, "retryable": 0, "uncertain": 0, "active": 0}
        for attempt in self.store.attempts(("in_flight",)):
            unit = self.store.unit(attempt["unit_id"])
            try:
                lock = self._lock(unit["id"], nonblocking=True)
            except BlockingIOError:
                recovered["active"] += 1
                continue
            try:
                current = self.store.attempt(attempt["id"])
                if current["state"] == "in_flight":
                    self.store.mark_attempt_unknown(attempt["id"], self.now())
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                lock.close()
        for attempt in self.store.attempts(("unknown",)):
            unit = self.store.unit(attempt["unit_id"])
            lock = self._lock(unit["id"])
            try:
                current = self.store.attempt(attempt["id"])
                if current["state"] != "unknown":
                    continue
                outcome = self.transports.locate(unit, current)
                if outcome.outcome == "accepted":
                    self.store.finish_attempt(current["id"], current["worker_id"], "accepted", outcome.receipt, None, self.now())
                    recovered["confirmed"] += 1
                elif outcome.outcome == "rejected":
                    self.store.reconcile_absent(current["id"], self.now())
                    recovered["retryable"] += 1
                else:
                    recovered["uncertain"] += 1
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                lock.close()
        return recovered
