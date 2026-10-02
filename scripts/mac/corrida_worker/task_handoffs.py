"""Durable director decisions for native task results.

The corrida record remains the only local authority.  A task-handling intent
is appended before the native ``resolve`` call; a receipt is appended only
after that call returns.  Reconciliation therefore retries a lost response
with the same task, result, decision, and decision digest.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
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


def _task_payload(lane_observation: Mapping[str, Any]) -> Optional[dict]:
    raw = lane_observation.get("managed_task")
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise TaskHandlingError("managed task observation is not an object")
    caller = raw.get("caller")
    receipt = raw.get("receipt")
    decision = raw.get("decision")
    if not isinstance(caller, dict) or caller.get("kind") != "director":
        raise TaskHandlingError("managed task caller is not a director")
    if not isinstance(receipt, dict):
        raise TaskHandlingError("managed task result receipt is missing")
    if not isinstance(decision, dict):
        raise TaskHandlingError("managed task decision is missing")
    for field in ("authority", "corridaId", "decisionId", "fence"):
        _required_text(caller.get(field), "director " + field)
    task_id = _required_text(receipt.get("taskId"), "taskId")
    result_digest = _required_text(receipt.get("resultDigest"), "resultDigest")
    generation = receipt.get("generation")
    if isinstance(generation, bool) or not isinstance(generation, int) or generation < 1:
        raise TaskHandlingError("managed task generation is invalid")
    digest = decision_digest(decision)
    return {
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


def _same_task(payload: Mapping[str, Any], expected: Mapping[str, Any]) -> bool:
    receipt = payload.get("receipt") or {}
    expected_receipt = expected.get("receipt") or {}
    return (
        receipt.get("taskId") == expected_receipt.get("taskId")
        and receipt.get("generation") == expected_receipt.get("generation")
        and receipt.get("resultDigest") == expected_receipt.get("resultDigest")
    )


def _same_decision(payload: Mapping[str, Any], expected: Mapping[str, Any]) -> bool:
    return (
        payload.get("decisionDigest") == expected.get("decisionDigest")
        and payload.get("decision") == expected.get("decision")
    )


def director_handling_effects(
    lane: Mapping[str, Any], lane_observation: Mapping[str, Any]
) -> tuple[HandlingEffect, ...]:
    """Plan one durable intent or one native resolve for a lane.

    Existing event reduction supplies serialization and replay protection.  A
    second consumer may calculate the same effect, but the stable native
    decision digest and the recorded receipt make the effect converge.
    """
    expected = _task_payload(lane_observation)
    if expected is None:
        return ()
    _required_text(lane.get("id"), "lane id")
    intents = _intent_events(lane)
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
