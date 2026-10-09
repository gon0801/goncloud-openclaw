"""Durable director decisions for native task results.

The corrida record remains the only local authority.  A task-handling intent
is appended before the native ``resolve`` call; a receipt is appended only
after that call returns.  Reconciliation therefore retries a lost response
with the same task, result, decision, and decision digest.

The Gateway ``managedTasks.resolve`` operation is supplied by the native R
runtime.  It is not present in this repository; tests therefore inject or
mock that boundary and do not claim a live native consume.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from dataclasses import dataclass
from typing import Any, Callable, Mapping, Optional


class TaskHandlingError(ValueError):
    """The observed result or persisted decision violates the contract."""


@dataclass(frozen=True)
class HandlingEffect:
    """An effect understood by the existing corrida reconciler."""

    op: str
    args: Mapping[str, Any]


def _canonical(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def decision_digest(decision: Mapping[str, Any]) -> str:
    """Return the digest expected by the native managed-task resolver."""
    if not isinstance(decision, dict):
        raise TaskHandlingError("task decision is not an object")
    return hashlib.sha256(_canonical(decision)).hexdigest()


def _required_text(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value:
        raise TaskHandlingError("task handling requires " + name)
    return value


def _typed_review_payload(raw: Mapping[str, Any]) -> Optional[dict]:
    """Read the native review result, never a model-selected decision.

    ``agent-work.result.v1`` stores the typed result under ``typedPayload``.
    Observers may expose that result directly or under ``result``; accepting
    both shapes keeps this boundary independent of the host projection while
    preserving one source of truth for the review verdict.
    """
    result = raw.get("result")
    candidates = [raw.get("typedPayload"), raw.get("review")]
    if isinstance(result, dict):
        candidates.extend((result.get("typedPayload"), result))
    for candidate in candidates:
        if candidate is None:
            continue
        if not isinstance(candidate, dict):
            raise TaskHandlingError("managed task typed review result is not an object")
        if "verdict" in candidate:
            return dict(candidate)
    return None


def _review_revision(raw: Mapping[str, Any]) -> dict:
    result = raw.get("result")
    candidates = [raw.get("reviewedRevision"), raw.get("observedRevision")]
    if isinstance(result, dict):
        candidates.extend((result.get("observedRevision"), result.get("reviewedRevision")))
    for candidate in candidates:
        if isinstance(candidate, dict):
            sha = candidate.get("sha")
            if candidate.get("kind") == "code" and isinstance(sha, str) and sha:
                return dict(candidate)
    raise TaskHandlingError("approved review result is missing its code revision")


def _correction_assignment(
    raw: Mapping[str, Any], lane_observation: Mapping[str, Any]
) -> dict:
    correction = (
        raw.get("correctionAssignment")
        or raw.get("correction")
        or lane_observation.get("correctionAssignment")
        or lane_observation.get("correction")
    )
    if not isinstance(correction, dict):
        raise TaskHandlingError("Changes review result is missing correction assignment")
    assignment = correction.get("assignment", correction)
    if not isinstance(assignment, dict) or not assignment:
        raise TaskHandlingError("Changes review correction assignment is invalid")
    return dict(assignment)


def _requester_assignment(
    raw: Mapping[str, Any], lane_observation: Mapping[str, Any]
) -> dict:
    requester = (
        raw.get("requesterAssignment")
        or raw.get("requester")
        or lane_observation.get("requesterAssignment")
        or lane_observation.get("requester")
    )
    if not isinstance(requester, dict):
        raise TaskHandlingError("judgment-required result is missing requester assignment")
    assignment = requester.get("assignment", requester)
    if not isinstance(assignment, dict) or not assignment:
        raise TaskHandlingError("requester assignment is invalid")
    return dict(assignment)


def _verified_gate_evidence(gate: Mapping[str, Any]) -> tuple[str, str]:
    evidence_path = _required_text(gate.get("evidencePath"), "current gate evidencePath")
    path = Path(evidence_path)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise TaskHandlingError("current gate evidencePath is not a regular local file")
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise TaskHandlingError("current gate evidencePath is unreadable") from exc
    if len(raw) > 1_000_000:
        raise TaskHandlingError("current gate evidence is too large")
    digest = hashlib.sha256(raw).hexdigest()
    claimed = gate.get("evidenceDigest")
    if claimed is not None and claimed != digest:
        raise TaskHandlingError("current gate evidence digest differs")
    return str(path), digest


def _durable_gate_evidence(gate: Mapping[str, Any]) -> tuple[str, str]:
    """Read the already verified identity without reopening its artifact."""
    evidence_path = _required_text(gate.get("evidencePath"), "durable gate evidencePath")
    evidence_digest = _required_text(
        gate.get("evidenceDigest"), "durable gate evidenceDigest"
    )
    return evidence_path, evidence_digest


def _decision_from_review(
    raw: Mapping[str, Any],
    lane_observation: Mapping[str, Any],
    typed_payload: Mapping[str, Any],
    *,
    verify_gate_evidence: bool = True,
    fallback_gate: Optional[Mapping[str, Any]] = None,
) -> tuple[dict, Optional[dict]]:
    verdict = str(typed_payload.get("verdict") or "").lower()
    if verdict in ("changes", "cambios"):
        decision = {
            "kind": "continue",
            "children": [{
                "slot": "corregir",
                "assignment": _correction_assignment(raw, lane_observation),
            }],
        }
        return decision, None
    if verdict in ("approved", "aprobado"):
        result = raw.get("result")
        result = result if isinstance(result, dict) else {}
        evidence_ref = typed_payload.get("evidenceRef") or result.get("artifactRef")
        _required_text(evidence_ref, "approved review evidenceRef")
        revision = _review_revision(raw)
        gate = next(
            (
                candidate
                for candidate in (raw.get("gate"), lane_observation.get("gate"))
                if isinstance(candidate, dict)
            ),
            None,
        )
        if gate is None and isinstance(fallback_gate, dict):
            gate = dict(fallback_gate)
        elif isinstance(fallback_gate, dict) and not verify_gate_evidence:
            gate = {**dict(fallback_gate), **gate}
        if not isinstance(gate, dict):
            raise TaskHandlingError("approved review result is missing current gate")
        gate_action = gate.get("action") or raw.get("gateAction")
        _required_text(gate_action, "approved review gate action")
        if verify_gate_evidence:
            evidence_path, evidence_digest = _verified_gate_evidence(gate)
        else:
            evidence_path, evidence_digest = _durable_gate_evidence(gate)
        decision = {"kind": "complete", "evidenceRef": evidence_ref}
        return decision, {
            "action": gate_action,
            "sha": revision["sha"],
            "evidenceRef": evidence_ref,
            "evidencePath": evidence_path,
            "evidenceDigest": evidence_digest,
        }
    if verdict in ("judgment-required", "judgment_required", "needs-judgment"):
        return {
            "kind": "continue",
            "children": [{
                "slot": "solicitante",
                "assignment": _requester_assignment(raw, lane_observation),
            }],
        }, None
    raise TaskHandlingError("managed task review verdict is unsupported")


def _decision_payload(
    raw: Mapping[str, Any],
    lane_observation: Mapping[str, Any],
    *,
    verify_gate_evidence: bool = True,
    fallback_gate: Optional[Mapping[str, Any]] = None,
) -> tuple[dict, Optional[dict]]:
    result = raw.get("result")
    if isinstance(result, dict) and result.get("kind") in ("failed", "executor-cancelled"):
        return ({
            "kind": "continue",
            "children": [{
                "slot": "solicitante",
                "assignment": _requester_assignment(raw, lane_observation),
            }],
        }, None)
    typed_payload = _typed_review_payload(raw)
    if typed_payload is not None:
        return _decision_from_review(
            raw,
            lane_observation,
            typed_payload,
            verify_gate_evidence=verify_gate_evidence,
            fallback_gate=fallback_gate,
        )
    if raw.get("resultContract") == "review.v1":
        raise TaskHandlingError("review.v1 result is missing typed review payload")
    decision = raw.get("decision")
    if not isinstance(decision, dict):
        raise TaskHandlingError("managed task decision is missing")
    return dict(decision), None


def _task_payload(
    lane_observation: Mapping[str, Any],
    *,
    verify_gate_evidence: bool = True,
    fallback_gate: Optional[Mapping[str, Any]] = None,
) -> Optional[dict]:
    raw = lane_observation.get("managed_task")
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise TaskHandlingError("managed task observation is not an object")
    caller = raw.get("caller")
    receipt = raw.get("receipt")
    if not isinstance(caller, dict) or caller.get("kind") != "director":
        raise TaskHandlingError("managed task caller is not a director")
    if not isinstance(receipt, dict):
        raise TaskHandlingError("managed task result receipt is missing")
    decision, gate = _decision_payload(
        raw,
        lane_observation,
        verify_gate_evidence=verify_gate_evidence,
        fallback_gate=fallback_gate,
    )
    for field in ("authority", "corridaId", "decisionId", "fence"):
        _required_text(caller.get(field), "director " + field)
    task_id = _required_text(receipt.get("taskId"), "taskId")
    result_digest = _required_text(receipt.get("resultDigest"), "resultDigest")
    generation = receipt.get("generation")
    if isinstance(generation, bool) or not isinstance(generation, int) or generation < 1:
        raise TaskHandlingError("managed task generation is invalid")
    digest = decision_digest(decision)
    payload = {
        "caller": dict(caller),
        "receipt": {
            "taskId": task_id,
            "generation": generation,
            "resultDigest": result_digest,
        },
        "decision": decision,
        "decisionDigest": digest,
        "decisionId": caller["decisionId"],
    }
    # ``gate`` is local continuation metadata.  The native resolver receives
    # only the Decision contract; the existing gate runner remains the owner
    # of the external gate effect.
    if gate is not None:
        payload["gate"] = {
            **gate,
            "taskId": task_id,
            "decisionId": caller["decisionId"],
            "decisionDigest": digest,
        }
    return payload


def _intent_events(lane: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    return [
        event
        for event in lane.get("events") or []
        if isinstance(event, dict) and event.get("kind") == "intent.task_handling"
    ]


def _handled_events(lane: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    return [
        event
        for event in lane.get("events") or []
        if isinstance(event, dict) and event.get("kind") == "observed.task_handled"
    ]


def _gate_intent_events(lane: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    return [
        event
        for event in lane.get("events") or []
        if isinstance(event, dict) and event.get("kind") == "intent.task_gate"
    ]


def _gate_receipt_events(lane: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    return [
        event
        for event in lane.get("events") or []
        if isinstance(event, dict) and event.get("kind") == "observed.task_gate"
    ]


def _same_gate(payload: Mapping[str, Any], expected: Mapping[str, Any]) -> bool:
    return all(payload.get(field) == expected.get(field) for field in (
        "taskId", "decisionId", "decisionDigest", "action", "sha",
        "evidencePath", "evidenceDigest",
    ))


def _gate_event_receipt(
    lane: Mapping[str, Any], expected: Mapping[str, Any]
) -> Optional[dict]:
    for event in reversed(lane.get("events") or []):
        if not isinstance(event, dict) or event.get("kind") not in ("gate.allow", "gate.deny"):
            continue
        payload = event.get("payload") or {}
        if not isinstance(payload, dict):
            continue
        if (
            payload.get("task_id") == expected.get("taskId")
            and payload.get("decision_id") == expected.get("decisionId")
            and payload.get("decision_digest") == expected.get("decisionDigest")
            and payload.get("action") == expected.get("action")
            and payload.get("sha") == expected.get("sha")
            and payload.get("evidence_path") == expected.get("evidencePath")
            and payload.get("evidence_digest") == expected.get("evidenceDigest")
        ):
            return {
                **dict(expected),
                "verdict": "allow" if event.get("kind") == "gate.allow" else "deny",
                "gateKind": event.get("kind"),
                "code": payload.get("code", ""),
                "reason": payload.get("reason", ""),
            }
    return None


def _gate_handling_effects(
    lane: Mapping[str, Any], gate: Mapping[str, Any]
) -> tuple[HandlingEffect, ...]:
    intents = _gate_intent_events(lane)
    matching = [
        event.get("payload") or {}
        for event in intents
        if isinstance(event.get("payload"), dict)
        and _same_gate(event["payload"], gate)
    ]
    if not matching:
        other = [
            event.get("payload") or {}
            for event in intents
            if isinstance(event.get("payload"), dict)
            and event["payload"].get("taskId") == gate.get("taskId")
        ]
        if other:
            raise TaskHandlingError("task gate conflicts with durable intent")
        return (HandlingEffect("record_task_gate", gate),)

    intent = matching[-1]
    if not _same_gate(intent, gate):
        raise TaskHandlingError("task gate conflicts with durable intent")
    receipts = [
        event.get("payload") or {}
        for event in _gate_receipt_events(lane)
        if isinstance(event.get("payload"), dict)
        and _same_gate(event["payload"], gate)
    ]
    if receipts:
        return ()
    observed_gate = _gate_event_receipt(lane, gate)
    if observed_gate is not None:
        return (HandlingEffect("record_task_gate_receipt", observed_gate),)
    return (HandlingEffect("execute_task_gate", intent),)


def _same_task(payload: Mapping[str, Any], expected: Mapping[str, Any]) -> bool:
    receipt = payload.get("receipt") or {}
    expected_receipt = expected.get("receipt") or {}
    return (
        receipt.get("taskId") == expected_receipt.get("taskId")
        and receipt.get("generation") == expected_receipt.get("generation")
        and receipt.get("resultDigest") == expected_receipt.get("resultDigest")
    )


def _same_task_identity(payload: Mapping[str, Any], expected: Mapping[str, Any]) -> bool:
    caller = payload.get("caller") or {}
    expected_caller = expected.get("caller") or {}
    if not isinstance(caller, dict) or not isinstance(expected_caller, dict):
        return False
    return (
        _same_task(payload, expected)
        and payload.get("decisionId", caller.get("decisionId"))
        == expected.get("decisionId")
        and all(
            caller.get(field) == expected_caller.get(field)
            for field in ("kind", "authority", "corridaId", "decisionId", "fence")
        )
    )


def _same_decision(payload: Mapping[str, Any], expected: Mapping[str, Any]) -> bool:
    caller = payload.get("caller") or {}
    expected_caller = expected.get("caller") or {}
    if not isinstance(caller, dict) or not isinstance(expected_caller, dict):
        return False
    return (
        payload.get("decisionDigest") == expected.get("decisionDigest")
        and payload.get("decision") == expected.get("decision")
        and payload.get("decisionId") == expected.get("decisionId")
        and all(
            caller.get(field) == expected_caller.get(field)
            for field in ("kind", "authority", "corridaId", "decisionId", "fence")
        )
        and payload.get("gate") == expected.get("gate")
    )


def director_handling_effects(
    lane: Mapping[str, Any], lane_observation: Mapping[str, Any]
) -> tuple[HandlingEffect, ...]:
    """Plan one durable intent or one native resolve for a lane.

    Existing event reduction supplies serialization and replay protection.  A
    second consumer may calculate the same effect, but the stable native
    decision digest and the recorded receipt make the effect converge.  Once
    an intent exists, its verified gate identity is reused; only the gate
    executor reopens the evidence file.
    """
    intents = _intent_events(lane)
    current_task = lane_observation.get("managed_task")
    durable_intent = next(
        (
            event.get("payload")
            for event in reversed(intents)
            if (
                isinstance(current_task, dict)
                and isinstance(event.get("payload"), dict)
                and _same_task_identity(current_task, event["payload"])
            )
        ),
        None,
    )
    reuse_durable_intent = durable_intent is not None
    durable_gate = (
        durable_intent.get("gate")
        if reuse_durable_intent
        and isinstance(durable_intent.get("gate"), dict)
        else None
    )
    expected = _task_payload(
        lane_observation,
        verify_gate_evidence=not reuse_durable_intent,
        fallback_gate=durable_gate,
    )
    if expected is None:
        return ()
    _required_text(lane.get("id"), "lane id")
    matching = [
        event.get("payload") or {}
        for event in intents
        if isinstance(event.get("payload"), dict)
        and _same_task(event["payload"], expected)
    ]
    if not matching:
        other = [
            event.get("payload") or {}
            for event in intents
            if isinstance(event.get("payload"), dict)
            and event["payload"].get("decisionId") == expected["decisionId"]
        ]
        if other:
            raise TaskHandlingError("task handling decision conflicts with durable intent")
        return (HandlingEffect("record_task_handling", expected),)

    intent = matching[-1]
    if not _same_decision(intent, expected):
        raise TaskHandlingError("task handling decision conflicts with durable intent")
    handled = [
        event.get("payload") or {}
        for event in _handled_events(lane)
        if isinstance(event.get("payload"), dict)
        and event["payload"].get("taskId") == expected["receipt"]["taskId"]
        and event["payload"].get("resultDigest") == expected["receipt"]["resultDigest"]
        and event["payload"].get("decisionDigest") == expected["decisionDigest"]
    ]
    if handled:
        gate = expected.get("gate")
        if isinstance(gate, dict):
            return _gate_handling_effects(lane, gate)
        return ()
    return (HandlingEffect("resolve_task_handling", intent),)


def _validate_receipt(request: Mapping[str, Any], receipt: Any) -> dict:
    if not isinstance(receipt, dict):
        raise TaskHandlingError("native resolve returned a non-object receipt")
    expected = request.get("receipt") or {}
    for field in ("taskId", "resultDigest"):
        if receipt.get(field) != expected.get(field):
            raise TaskHandlingError("native resolve receipt does not match the intent")
    if receipt.get("decisionDigest") != request.get("decisionDigest"):
        raise TaskHandlingError("native resolve receipt has a different decision")
    child_ids = receipt.get("childTaskIds")
    if not isinstance(child_ids, list) or not all(isinstance(item, str) and item for item in child_ids):
        raise TaskHandlingError("native resolve receipt has invalid child task IDs")
    return receipt


def resolve_task_handling(
    request: Mapping[str, Any], resolver: Callable[[Mapping[str, Any]], Mapping[str, Any]]
) -> dict:
    """Resolve one intent through an injected native resolver.

    The caller owns persistence of the returned receipt.  If ``resolver``
    raises after committing remotely, the unchanged request can be retried.
    """
    if not isinstance(request, dict):
        raise TaskHandlingError("task handling request is not an object")
    receipt = resolver(request)
    return _validate_receipt(request, receipt)


def resolve_via_gateway(
    request: Mapping[str, Any],
    *,
    openclaw_bin: str,
    expected_url: Optional[str] = None,
    timeout: int = 30,
) -> dict:
    """Call the native resolver without exposing child producer credentials."""
    params = {
        "caller": request["caller"],
        "receipt": request["receipt"],
        "decision": request["decision"],
        "decisionDigest": request["decisionDigest"],
    }
    command = [
        openclaw_bin,
        "gateway",
        "call",
        "managedTasks.resolve",
        "--json",
        "--timeout",
        str(timeout * 1000),
        "--params",
        json.dumps(params, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
    ]
    if expected_url:
        command.extend(("--expect-url", expected_url))
    try:
        response = subprocess.run(command, capture_output=True, text=True, timeout=timeout + 5)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError("native task resolver Gateway unavailable") from exc
    if response.returncode:
        raise RuntimeError("native task resolver Gateway rejected request")
    try:
        return _validate_receipt(request, json.loads(response.stdout))
    except json.JSONDecodeError as exc:
        raise RuntimeError("native task resolver Gateway returned invalid JSON") from exc


def _load_request(raw: str) -> dict:
    try:
        request = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise TaskHandlingError("task handling request is invalid JSON") from exc
    if not isinstance(request, dict):
        raise TaskHandlingError("task handling request is not an object")
    return request


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Resolve one durable native task-handling intent")
    sub = parser.add_subparsers(dest="command", required=True)
    resolve = sub.add_parser("resolve")
    resolve.add_argument("--request-json", required=True)
    resolve.add_argument("--openclaw-bin", default=os.environ.get("OPENCLAW_BIN", "openclaw"))
    resolve.add_argument("--expect-url", default=os.environ.get("OPENCLAW_EXPECT_URL") or None)
    args = parser.parse_args(argv)
    if args.command == "resolve":
        request = _load_request(args.request_json)
        receipt = resolve_task_handling(
            request,
            lambda value: resolve_via_gateway(
                value, openclaw_bin=args.openclaw_bin, expected_url=args.expect_url
            ),
        )
        print(json.dumps(receipt, ensure_ascii=False, sort_keys=True))
        return 0
    parser.error("unknown task-handling command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
