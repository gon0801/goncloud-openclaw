"""Reconciliacion idempotente tras reinicio (Fase 14, Task 5).

Compara el registro contra observaciones de solo lectura y propone efectos
en orden fijo: registry, tmux, worktree y HEAD, rama remota, PR y head SHA,
evidencia, merge, SHA desplegado, canary. Python propone y no ejecuta nada:
el wrapper Bash ejecuta un efecto cerrado, registra el resultado y vuelve a
invocar. Repetir la misma entrada propone lo mismo; un intent pendiente sin
confirmacion no se duplica.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from typing import Any, Mapping

from corrida_worker.state import RunState

OPS = (
    "record_observed",
    "resume_lane",
    "handoff_lane",
    "launch_successor",
    "stop_lane",
    "mark_lane_stopped",
)

ACTIONABLE_INSPECT = ("failed", "quota", "auth-vencida")


@dataclass(frozen=True)
class PlannedEffect:
    op: str
    lane: str
    args: Mapping[str, Any] = field(default_factory=dict)

    def to_json(self) -> dict:
        return {"op": self.op, "lane": self.lane, "args": dict(self.args)}


def _lane_events(lane: Mapping[str, Any]) -> list:
    events = lane.get("events") or []
    return [event for event in events if isinstance(event, dict)]


def _has_kind(lane: Mapping[str, Any], kind: str) -> bool:
    return any(event.get("kind") == kind for event in _lane_events(lane))


def _handoff(lane: Mapping[str, Any]) -> Mapping[str, Any]:
    handoff = lane.get("handoff") or {}
    return handoff if isinstance(handoff, dict) else {}


def decision_digest(record: Mapping[str, Any], observations: Mapping[str, Any]) -> str:
    canon = json.dumps({"record": record, "observations": observations}, sort_keys=True)
    return hashlib.sha1(canon.encode("utf-8")).hexdigest()


def _record(lane_id: str, kind: str, payload: Mapping[str, Any]) -> PlannedEffect:
    return PlannedEffect("record_observed", lane_id, {"kind": kind, "payload": dict(payload)})


def reconcile_lane(
    lane: Mapping[str, Any],
    lane_obs: Mapping[str, Any],
    observations: Mapping[str, Any],
) -> tuple[PlannedEffect, ...]:
    lane_id = str(lane.get("id") or "")
    if not lane_id or lane.get("estado") == "stopped":
        return ()
    effects: list[PlannedEffect] = []
    delivery = lane.get("delivery") or {}
    evidence = lane.get("evidence") or {}
    session = lane.get("session") or ""
    session_alive = bool(lane_obs.get("session_alive"))
    tmux_sessions = (observations.get("tmux") or {}).get("sessions") or []

    def live(name: str) -> bool:
        return bool(name) and name in tmux_sessions

    # tmux: la sesion registrada que no vive se anota una vez; un intent
    # pendiente se confirma solo contra la observacion, nunca por el intent.
    if (
        session
        and not live(session)
        and not session_alive
        and lane_obs.get("inspect") not in ACTIONABLE_INSPECT
    ):
        if not _has_kind(lane, "observed.session.vanished") and not _has_kind(
            lane, "observed.session.stopped"
        ):
            effects.append(
                _record(
                    lane_id,
                    "session.vanished",
                    {
                        "session": session,
                        "head": lane_obs.get("head"),
                        "commits_ahead": lane_obs.get("commits_ahead", 0),
                    },
                )
            )
    if _has_kind(lane, "intent.resume_lane") and not _has_kind(lane, "observed.resumed"):
        if live(session) or session_alive:
            effects.append(_record(lane_id, "resumed", {"session": session}))
    if _has_kind(lane, "intent.launch_successor") and not _has_kind(lane, "observed.launched"):
        successor = lane_obs.get("successor_session")
        if isinstance(successor, str) and live(successor):
            launched = dict(lane_obs.get("successor") or {})
            launched.setdefault("session", successor)
            effects.append(_record(lane_id, "launched", launched))

    # Rama remota, PR, merge, deploy y canary ya ocurridos se registran; jamas
    # se propone repetir un efecto externo consumado.
    if lane_obs.get("remote_branch") and not (delivery.get("push") or {}):
        if not _has_kind(lane, "observed.push.done"):
            effects.append(
                _record(
                    lane_id,
                    "push.done",
                    {"branch": lane.get("branch"), "head": lane_obs.get("head")},
                )
            )
    pr_obs = lane_obs.get("pr")
    if isinstance(pr_obs, dict) and not (delivery.get("pr") or {}):
        if not _has_kind(lane, "observed.pr.open"):
            effects.append(
                _record(
                    lane_id,
                    "pr.open",
                    {"number": pr_obs.get("number"), "head": pr_obs.get("head")},
                )
            )
    merge_obs = lane_obs.get("merge") or {}
    if merge_obs.get("merged") and not (delivery.get("merge") or {}):
        if not _has_kind(lane, "observed.merge.done"):
            effects.append(
                _record(
                    lane_id,
                    "merge.done",
                    {
                        "merge_commit": merge_obs.get("merge_commit"),
                        "reviewed_head": (delivery.get("pr") or {}).get("head")
                        or lane_obs.get("head"),
                    },
                )
            )
    deployed = lane_obs.get("deployed")
    if deployed and not (delivery.get("deploy") or {}):
        if not _has_kind(lane, "observed.deploy.seen"):
            effects.append(_record(lane_id, "deploy.seen", {"sha": deployed}))
    canary_obs = lane_obs.get("canary")
    if isinstance(canary_obs, dict) and not (delivery.get("canary") or {}):
        if canary_obs.get("result") == "pass" and not _has_kind(lane, "observed.canary.done"):
            pending = (observations.get("candidates") or {}).get("pending_hosts") or []
            effects.append(
                _record(
                    lane_id,
                    "canary.done",
                    {
                        "sha": canary_obs.get("sha"),
                        "result": "pass",
                        "pending_hosts": [entry.get("host") for entry in pending if isinstance(entry, dict)],
                    },
                )
            )
        elif canary_obs.get("result") == "failed" and not _has_kind(
            lane, "observed.canary.failed"
        ):
            effects.append(
                _record(
                    lane_id,
                    "canary.failed",
                    {"sha": canary_obs.get("sha"), "result": "failed"},
                )
            )

    # Evidencia: el inspect accionable y el test fallido se anotan; un test
    # fallido jamas produce un observado de pase o aprobado.
    inspect = lane_obs.get("inspect")
    if inspect in ACTIONABLE_INSPECT and evidence.get("inspect") != inspect:
        kind = f"inspect.{inspect}"
        if not _has_kind(lane, f"observed.{kind}"):
            effects.append(_record(lane_id, kind, {"session": session}))
    test_evidence = evidence.get("test") or {}
    if test_evidence.get("result") == "failed" and not _has_kind(lane, "observed.test.failed"):
        effects.append(
            _record(
                lane_id,
                "test.failed",
                {"result": "failed", "fallback": bool(test_evidence.get("fallback"))},
            )
        )

    effects.extend(_handoff_effects(lane, lane_obs, observations, live, session_alive))
    return tuple(effects)


def _blocked(lane_obs: Mapping[str, Any]) -> str:
    if lane_obs.get("predecessor_alive"):
        return "predecessor-writing"
    if lane_obs.get("children_writing"):
        return "children-writing"
    return ""


def _handoff_effects(
    lane: Mapping[str, Any],
    lane_obs: Mapping[str, Any],
    observations: Mapping[str, Any],
    live: Any,
    session_alive: bool,
) -> tuple[PlannedEffect, ...]:
    lane_id = str(lane.get("id") or "")
    delivery = lane.get("delivery") or {}
    merge_done = bool(
        (delivery.get("merge") or {}).get("merge_commit")
        or (lane_obs.get("merge") or {}).get("merged")
    )
    canary_done = bool(
        (delivery.get("canary") or {}) or (lane_obs.get("canary") or {}).get("result")
    )
    if merge_done or canary_done:
        return ()
    candidates = observations.get("candidates") or {}
    nxt = candidates.get("next")
    nxt = nxt if isinstance(nxt, dict) else None
    registry_workers = (observations.get("registry") or {}).get("workers") or []
    resumes = int(_handoff(lane).get("resumes", 0) or 0)
    inspect = lane_obs.get("inspect")
    binary_ok = lane_obs.get("binary_exists", True) is not False
    session = lane.get("session") or ""
    if not session:
        return ()

    handed_off = lane.get("estado") == "handoff" or _has_kind(lane, "intent.handoff_lane")
    if handed_off:
        return _successor_effects(
            lane, lane_obs, nxt, registry_workers, live, session_alive,
            candidates.get("exhausted") or [],
        )
    if inspect in ("quota", "auth-vencida"):
        reason = inspect
    elif not binary_ok:
        reason = "missing-binary"
    elif inspect == "failed" or (not session_alive and not live(session)):
        reason = "failed"
    else:
        return ()

    if reason == "failed" and resumes == 0 and not _has_kind(lane, "intent.resume_lane"):
        return (PlannedEffect("resume_lane", lane_id, {"session": session}),)
    blocked = _blocked(lane_obs)
    if blocked:
        if not _has_kind(lane, "observed.handoff.blocked"):
            return (_record(lane_id, "handoff.blocked", {"reason": blocked}),)
        return ()
    if nxt is None:
        exhausted = candidates.get("exhausted") or []
        if exhausted and not _has_kind(lane, "intent.mark_lane_stopped"):
            return (
                PlannedEffect(
                    "mark_lane_stopped", lane_id, {"reason": "candidates-exhausted"}
                ),
            )
        if not exhausted and not _has_kind(lane, "observed.handoff.blocked"):
            return (_record(lane_id, "handoff.blocked", {"reason": "no-candidate"}),)
        return ()
    if nxt.get("worker") not in registry_workers:
        if not _has_kind(lane, "observed.handoff.blocked"):
            return (_record(lane_id, "handoff.blocked", {"reason": "unknown-worker"}),)
        return ()
    if _has_kind(lane, "intent.handoff_lane"):
        return ()
    return (
        PlannedEffect(
            "handoff_lane",
            lane_id,
            {
                "reason": reason,
                "from_worker": lane.get("worker"),
                "from_session": session,
                "to_worker": nxt.get("worker"),
                "to_session": nxt.get("session"),
                "preserve_worktree": True,
                "dirty": bool(lane_obs.get("dirty")),
                "commits_ahead": lane_obs.get("commits_ahead", 0),
            },
        ),
    )


def _successor_effects(
    lane: Mapping[str, Any],
    lane_obs: Mapping[str, Any],
    nxt: Mapping[str, Any] | None,
    registry_workers: list,
    live: Any,
    session_alive: bool,
    exhausted: list,
) -> tuple[PlannedEffect, ...]:
    lane_id = str(lane.get("id") or "")
    if _has_kind(lane, "intent.launch_successor"):
        return ()
    blocked = _blocked(lane_obs)
    if blocked:
        if not _has_kind(lane, "observed.handoff.blocked"):
            return (_record(lane_id, "handoff.blocked", {"reason": blocked}),)
        return ()
    session = lane.get("session") or ""
    if session and (live(session) or session_alive):
        if _has_kind(lane, "intent.stop_lane"):
            if not _has_kind(lane, "observed.handoff.blocked"):
                return (
                    _record(lane_id, "handoff.blocked", {"reason": "stop-unconfirmed"}),
                )
            return ()
        return (PlannedEffect("stop_lane", lane_id, {"session": session}),)
    if _has_kind(lane, "intent.stop_lane") and not _has_kind(
        lane, "observed.session.stopped"
    ):
        return (_record(lane_id, "session.stopped", {"session": session}),)
    if nxt is None:
        if exhausted and not _has_kind(lane, "intent.mark_lane_stopped"):
            return (
                PlannedEffect(
                    "mark_lane_stopped", lane_id, {"reason": "candidates-exhausted"}
                ),
            )
        if not exhausted and not _has_kind(lane, "observed.handoff.blocked"):
            return (_record(lane_id, "handoff.blocked", {"reason": "no-candidate"}),)
        return ()
    if nxt.get("worker") not in registry_workers:
        if not _has_kind(lane, "observed.handoff.blocked"):
            return (_record(lane_id, "handoff.blocked", {"reason": "unknown-worker"}),)
        return ()
    return (
        PlannedEffect(
            "launch_successor",
            lane_id,
            {
                "worker": nxt.get("worker"),
                "session": nxt.get("session"),
                "worktree": lane.get("worktree"),
                "preserve_worktree": True,
            },
        ),
    )


def reconcile(
    state: RunState, observations: Mapping[str, Any]
) -> tuple[RunState, tuple[PlannedEffect, ...]]:
    """Propone efectos para cada carril en orden de lanes. No ejecuta nada."""
    lanes_obs = observations.get("lanes") or {}
    effects: list[PlannedEffect] = []
    for lane in state.record.get("lanes") or []:
        if not isinstance(lane, dict):
            continue
        lane_obs = lanes_obs.get(lane.get("id") or "") or {}
        if not isinstance(lane_obs, dict):
            lane_obs = {}
        effects.extend(reconcile_lane(lane, lane_obs, observations))
    return (state, tuple(effects))
