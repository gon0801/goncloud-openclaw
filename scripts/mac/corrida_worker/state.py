"""Estado persistente append-only de corridas nativas (Fase 14, Task 5).

El registro corrida.v2 es la unica fuente: los eventos se agregan al carril
y jamas se reescriben. Repetir un evento con el mismo id no cambia nada y
repetir la misma secuencia deja el mismo estado byte a byte.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Mapping

INTENT_PREFIX = "intent."
OBSERVED_PREFIX = "observed."

EVENT_KINDS = frozenset(
    {
        "intent.push",
        "intent.pr",
        "intent.merge",
        "intent.deploy",
        "intent.canary",
        "intent.rollback",
        "intent.resume_lane",
        "intent.handoff_lane",
        "intent.launch_successor",
        "intent.stop_lane",
        "intent.mark_lane_stopped",
        "observed.session.vanished",
        "observed.resumed",
        "observed.launched",
        "observed.inspect.failed",
        "observed.inspect.quota",
        "observed.inspect.auth-vencida",
        "observed.push.done",
        "observed.pr.open",
        "observed.merge.done",
        "observed.deploy.seen",
        "observed.canary.done",
        "observed.handoff.blocked",
        "observed.lane.stopped",
        "observed.session.stopped",
        "observed.test.failed",
        "observed.canary.failed",
        "gate.allow",
        "gate.deny",
        "evidence.receipt",
        "evidence.ci",
        "evidence.review",
        "evidence.coderabbit",
        "evidence.rebase",
        "evidence.deploy",
        "evidence.canary",
        "evidence.rollback",
        "evidence.push_pr",
    }
)


class StateError(ValueError):
    """Record o evento con forma invalida."""

    diagnostic = "ERROR invalid record"


class EventError(StateError):
    """Evento fuera del catalogo o sin carril conocido."""

    diagnostic = "ERROR invalid event"


@dataclass(frozen=True)
class Event:
    id: str
    lane: str
    kind: str
    payload: Mapping[str, Any] = field(default_factory=dict)
    at: str = ""


@dataclass(frozen=True)
class RunState:
    record: Mapping[str, Any]
    applied_event_ids: frozenset = frozenset()


def event_id(lane: str, kind: str, payload: Mapping[str, Any]) -> str:
    """Id determinista: la misma terna da el mismo id en cada corrida."""
    canon = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha1(f"{lane}\x00{kind}\x00{canon}".encode("utf-8")).hexdigest()[:12]
    return f"{lane}:{kind}:{digest}"


def coerce_event(raw: Any) -> Event:
    if not isinstance(raw, dict):
        raise EventError("event is not an object")
    lane = raw.get("lane")
    kind = raw.get("kind")
    if not isinstance(lane, str) or not lane:
        raise EventError("event without lane")
    if kind not in EVENT_KINDS:
        raise EventError(f"unknown event kind: {kind!r}")
    payload = raw.get("payload", {})
    if not isinstance(payload, dict):
        raise EventError("event payload is not an object")
    at = raw.get("at", "")
    if not isinstance(at, str):
        raise EventError("event at is not a string")
    ident = raw.get("id") or event_id(lane, kind, payload)
    if not isinstance(ident, str) or not ident:
        raise EventError("event without id")
    return Event(id=ident, lane=lane, kind=kind, payload=payload, at=at)


def _lane_of(record: dict, lane_id: str) -> dict:
    for lane in record.get("lanes") or []:
        if isinstance(lane, dict) and lane.get("id") == lane_id:
            return lane
    raise EventError(f"unknown lane: {lane_id}")


def _bump_attempt(lane: dict, event: Event) -> None:
    handoff = lane.setdefault("handoff", {})
    attempts = handoff.setdefault("attempts", [])
    attempts.append({"kind": event.kind, "at": event.at})


def apply_event(record: Mapping[str, Any], event: Event) -> dict:
    """Aplica un evento sobre una copia del registro y la devuelve."""
    next_record = copy.deepcopy(dict(record))
    lane = _lane_of(next_record, event.lane)
    lane.setdefault("events", []).append(
        {
            "id": event.id,
            "lane": event.lane,
            "kind": event.kind,
            "payload": dict(event.payload),
            "at": event.at,
        }
    )
    kind = event.kind
    payload = dict(event.payload)
    if kind == "intent.resume_lane":
        handoff = lane.setdefault("handoff", {})
        handoff["resumes"] = int(handoff.get("resumes", 0)) + 1
        _bump_attempt(lane, event)
    elif kind in ("intent.handoff_lane", "intent.launch_successor", "intent.stop_lane"):
        _bump_attempt(lane, event)
        if kind == "intent.handoff_lane":
            lane["estado"] = "handoff"
    elif kind == "observed.resumed":
        lane["estado"] = "activo"
    elif kind == "observed.launched":
        if payload.get("worker"):
            lane["worker"] = payload["worker"]
        if payload.get("session"):
            lane["session"] = payload["session"]
        lane["estado"] = "activo"
    elif kind == "observed.lane.stopped":
        lane["estado"] = "stopped"
    elif kind == "observed.push.done":
        lane.setdefault("delivery", {})["push"] = payload
    elif kind == "observed.pr.open":
        lane.setdefault("delivery", {})["pr"] = payload
    elif kind == "observed.merge.done":
        lane.setdefault("delivery", {})["merge"] = payload
    elif kind == "observed.deploy.seen":
        lane.setdefault("delivery", {})["deploy"] = payload
    elif kind == "observed.canary.done":
        lane.setdefault("delivery", {})["canary"] = payload
    elif kind == "observed.canary.failed":
        lane.setdefault("delivery", {})["canary"] = payload
    elif kind.startswith("observed.inspect."):
        lane.setdefault("evidence", {})["inspect"] = kind.rsplit(".", 1)[-1]
    elif kind == "observed.test.failed":
        lane.setdefault("evidence", {})["test_observed"] = True
    elif kind.startswith("gate."):
        lane.setdefault("evidence", {})["last_gate"] = {"kind": kind, "payload": payload}
    elif kind.startswith("evidence."):
        lane.setdefault("evidence", {})[kind[len("evidence.") :]] = payload
    return next_record


def reduce_state(state: RunState, event: Event) -> RunState:
    if event.id in state.applied_event_ids:
        return state
    next_record = apply_event(state.record, event)
    return replace(state, record=next_record, applied_event_ids=state.applied_event_ids | {event.id})


def state_from_record(record: Mapping[str, Any]) -> RunState:
    ids: set[str] = set()
    for lane in record.get("lanes") or []:
        if not isinstance(lane, dict):
            continue
        for event in lane.get("events") or []:
            if isinstance(event, dict) and event.get("id"):
                ids.add(event["id"])
    return RunState(record=record, applied_event_ids=frozenset(ids))


def reduce_events(record: Mapping[str, Any], raws: list[Any]) -> tuple[dict, int, int]:
    """Reduce una lista en orden. Devuelve (registro, aplicados, duplicados)."""
    state = state_from_record(record)
    applied = 0
    duplicated = 0
    for raw in raws:
        event = coerce_event(raw)
        before = len(state.applied_event_ids)
        state = reduce_state(state, event)
        if len(state.applied_event_ids) == before:
            duplicated += 1
        else:
            applied += 1
    result = dict(state.record)
    return (result, applied, duplicated)


def load_record(path: Path) -> dict:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise StateError(f"record not found: {path}")
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StateError(f"unreadable record: {exc}")
    if not isinstance(raw, dict):
        raise StateError("record is not an object")
    if raw.get("schema") != "corrida.v2":
        raise StateError("bad schema")
    return raw


def normalize(record: Mapping[str, Any]) -> str:
    return json.dumps(record, sort_keys=True, indent=2) + "\n"


def digest_of(record: Mapping[str, Any]) -> str:
    return hashlib.sha1(normalize(record).encode("utf-8")).hexdigest()


def write_atomic(path: Path, payload: Mapping[str, Any]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(normalize(payload), encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
