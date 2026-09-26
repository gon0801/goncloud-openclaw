"""Selección determinista de workers: filtros duros y puntaje entero.

Solo usa resultados cerrados; el texto libre del modelo no puntúa.
Sin empates por red: un empate usa el orden estable del registro.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping, Sequence

from .registry import MAX_EXTERNAL_SESSIONS, Registry, Worker

WEIGHTS = {"affinity": 40, "history": 25, "availability": 15, "quota": 10, "diversity": 10}
KNOWN_HEALTH = frozenset({"available", "limited", "unauthenticated", "broken"})
FAIL_OUTCOMES = frozenset({"failure", "blocked", "reversed"})


@dataclass(frozen=True)
class CandidateScore:
    worker: str
    score: int
    parts: tuple[tuple[str, int], ...]


@dataclass(frozen=True)
class Discard:
    worker: str
    reasons: tuple[str, ...]


@dataclass(frozen=True)
class SelectionDecision:
    winner: str | None
    score: int
    parts: tuple[tuple[str, int], ...]
    candidates: tuple[CandidateScore, ...]
    discarded: tuple[Discard, ...]
    status: str


def normalize_health(health: Mapping[str, object]) -> dict[str, str]:
    """Acepta `id -> estado` o `id -> {status, ...}`; lo demás es desconocido."""
    normalized: dict[str, str] = {}
    for worker_id, record in health.items():
        if isinstance(record, str):
            normalized[worker_id] = record
        elif isinstance(record, Mapping):
            status = record.get("status")
            normalized[worker_id] = status if isinstance(status, str) else "unknown"
        else:
            normalized[worker_id] = "unknown"
    return normalized


def closed_history(history: Sequence[Mapping[str, object]]) -> list[Mapping[str, object]]:
    """Solo resultados cerrados: éxito vivo, reversa, bloqueo, duración, rondas."""
    return [entry for entry in history if isinstance(entry, Mapping) and entry.get("status") == "closed"]


def _required_capabilities(request: Mapping[str, object]) -> list[str]:
    caps = request.get("capabilities")
    if isinstance(caps, list) and caps:
        return [str(cap) for cap in caps]
    if request.get("role") == "write":
        return ["read", "write"]
    return ["read", "review"]


def hard_filter_reasons(
    worker: Worker,
    request: Mapping[str, object],
    health: Mapping[str, str],
    active: Sequence[Mapping[str, object]],
    *,
    installed: bool = True,
    exhausted: Sequence[str] = (),
) -> list[str]:
    reasons: list[str] = []
    if not installed:
        reasons.append("missing-executable")
    status = health.get(worker.id)
    if status not in KNOWN_HEALTH:
        reasons.append("missing-health")
    elif status == "unauthenticated":
        reasons.append("unauthenticated")
    elif status == "broken":
        reasons.append("broken")
    if worker.id in exhausted:
        reasons.append("quota-exhausted")
    if not set(_required_capabilities(request)) <= set(worker.capabilities):
        reasons.append("missing-capability")
    denied = request.get("denied_harnesses") or []
    if worker.harness in denied:
        reasons.append("repo-denied")
    if request.get("role") == "review":
        authors = list(request.get("exclude_authors") or [])
        implemented_by = request.get("implemented_by")
        if implemented_by:
            authors.append(implemented_by)
        if worker.id in authors:
            reasons.append("author-excluded")
    want_tree = request.get("worktree")
    if want_tree:
        for entry in active:
            if (
                isinstance(entry, Mapping)
                and entry.get("worktree") == want_tree
                and entry.get("mode") == "write"
                and entry.get("worker") != worker.id
            ):
                reasons.append("worktree-occupied")
                break
    if len(active) >= MAX_EXTERNAL_SESSIONS:
        reasons.append("capacity-full")
    return reasons


def score_parts(
    worker: Worker,
    request: Mapping[str, object],
    status: str,
    history: Sequence[Mapping[str, object]],
    active_ids: frozenset[str],
    previous_reviewer: str | None,
) -> dict[str, int]:
    task_type = request.get("task_type")
    affinity = WEIGHTS["affinity"] if task_type in worker.task_types else 0
    mine = [
        entry
        for entry in history
        if entry.get("worker") == worker.id and entry.get("task_type") == task_type
    ]
    wins = sum(1 for entry in mine if entry.get("outcome") == "success")
    losses = sum(1 for entry in mine if entry.get("outcome") in FAIL_OUTCOMES)
    history_score = min(WEIGHTS["history"], max(0, 10 + 5 * wins - 5 * losses))
    availability = {"available": WEIGHTS["availability"], "limited": 5}.get(status, 0)
    quota_hit = any(
        entry.get("worker") == worker.id and entry.get("outcome") == "quota-exhausted"
        for entry in history
    )
    quota = 0 if quota_hit else WEIGHTS["quota"]
    diversity = 0 if (worker.id in active_ids or worker.id == previous_reviewer) else WEIGHTS["diversity"]
    return {
        "affinity": affinity,
        "history": history_score,
        "availability": availability,
        "quota": quota,
        "diversity": diversity,
    }


def select_worker(
    registry: Registry,
    request: Mapping[str, object],
    health: Mapping[str, object],
    history: Sequence[Mapping[str, object]],
    active: Sequence[Mapping[str, object]],
    *,
    installed: Mapping[str, bool] | None = None,
    exhausted: Sequence[str] = (),
    previous_reviewer: str | None = None,
) -> SelectionDecision:
    normalized = normalize_health(health)
    closed = closed_history(history)
    active_ids = frozenset(
        str(entry.get("worker")) for entry in active if isinstance(entry, Mapping)
    )
    candidates: list[tuple[int, int, Worker, dict[str, int]]] = []
    discarded: list[Discard] = []
    for order, worker in enumerate(registry.workers):
        present = True if installed is None else bool(installed.get(worker.id, True))
        reasons = hard_filter_reasons(
            worker, request, normalized, active, installed=present, exhausted=exhausted
        )
        if reasons:
            discarded.append(Discard(worker.id, tuple(reasons)))
            continue
        parts = score_parts(
            worker, request, normalized.get(worker.id, "unknown"),
            closed, active_ids, previous_reviewer,
        )
        candidates.append((sum(parts.values()), order, worker, parts))
    if not candidates:
        return SelectionDecision(None, 0, (), (), tuple(discarded), "no-compatible-worker")
    score, _, winner, parts = max(candidates, key=lambda item: (item[0], -item[1]))
    ranked = sorted(candidates, key=lambda item: (-item[0], item[1]))
    return SelectionDecision(
        winner.id,
        score,
        tuple(sorted(parts.items())),
        tuple(
            CandidateScore(item[2].id, item[0], tuple(sorted(item[3].items())))
            for item in ranked
        ),
        tuple(discarded),
        "selected",
    )
