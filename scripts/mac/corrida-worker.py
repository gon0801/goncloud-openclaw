#!/usr/bin/env python3
"""Plano de control de corridas nativas (Fase 14). Solo stdlib.

registry validate|list: valida el registro cerrado workers.v1.
record validate: valida un registro corrida.v2 legado o con workers nativos.
health probe: sonda acotada por worker (sin binario timeout externo).
select: selección determinista con un solo objeto JSON en stdout.
state reduce: aplica eventos append-only al registro (Fase 14, Task 5).
reconcile: propone efectos sin ejecutar nada (Fase 14, Task 5).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Mapping

sys.path.insert(0, str(Path(__file__).resolve().parent))

from corrida_worker.registry import RegistryError, Worker, load_registry, resolve_binary
from corrida_worker.selector import select_worker
from corrida_worker.state import (
    EventError,
    StateError,
    load_record,
    reduce_events,
    state_from_record,
    write_atomic,
)
from corrida_worker.reconcile import decision_digest, reconcile
from corrida_worker.gates import ACTIONS as GATE_ACTIONS
from corrida_worker.gates import gate_decision

NATIVE_KEYS = (
    "workers_registry",
    "automatic_routing",
    "lanes",
    "effects",
    "evidence",
    "outcome",
    "authorization_ref",
)


class RecordError(ValueError):
    diagnostic = "ERROR invalid record"


def validate_record(path: Path) -> str:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise RecordError(f"record not found: {path}")
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RecordError(f"unreadable record: {exc}")
    if not isinstance(raw, dict):
        raise RecordError("record is not an object")
    if raw.get("schema") != "corrida.v2":
        raise RecordError("bad schema")
    if raw.get("seguimiento_global") is not True:
        raise RecordError("missing seguimiento_global")
    if "cron_vigia_id" in raw:
        raise RecordError("legacy vigia cron present")
    present = [key for key in NATIVE_KEYS if key in raw]
    for key in present:
        _check_native_field(key, raw[key])
    if present:
        return "VALID corrida.v2 native-workers"
    return "VALID corrida.v2 legacy"


def _check_native_field(key: str, value: object) -> None:
    if key == "workers_registry":
        if not isinstance(value, str) or not value:
            raise RecordError("bad workers_registry")
    elif key == "automatic_routing":
        if not isinstance(value, dict) or not isinstance(value.get("enabled"), bool):
            raise RecordError("bad automatic_routing")
    elif key in ("lanes", "effects"):
        if not isinstance(value, list):
            raise RecordError(f"bad {key}")
    elif key == "evidence":
        if not isinstance(value, dict):
            raise RecordError("bad evidence")
    elif key == "outcome":
        if not isinstance(value, (str, dict)):
            raise RecordError("bad outcome")
    elif key == "authorization_ref":
        if not isinstance(value, str) or not value:
            raise RecordError("bad authorization_ref")


def cmd_registry_validate(args: argparse.Namespace) -> int:
    try:
        registry = load_registry(Path(args.registry))
    except RegistryError as exc:
        print(exc.diagnostic)
        return 1
    print(f"VALID workers.v1 {len(registry.workers)}")
    return 0


def cmd_registry_list(args: argparse.Namespace) -> int:
    try:
        registry = load_registry(Path(args.registry))
    except RegistryError as exc:
        print(exc.diagnostic)
        return 1
    for worker in registry.workers:
        print(worker.id)
    return 0


def cmd_record_validate(args: argparse.Namespace) -> int:
    try:
        print(validate_record(Path(args.record)))
    except RecordError as exc:
        print(exc.diagnostic)
        return 1
    return 0


class SelectionError(ValueError):
    diagnostic = "ERROR invalid selection input"


def _read_json_object(path: Path) -> dict:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SelectionError(f"input not found: {path}")
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SelectionError(f"unreadable input: {exc}")
    if not isinstance(raw, dict):
        raise SelectionError("input is not an object")
    return raw


def cmd_select(args: argparse.Namespace) -> int:
    try:
        registry = load_registry(Path(args.registry))
    except RegistryError as exc:
        print(exc.diagnostic)
        return 1
    try:
        request = _read_json_object(Path(args.request))
        state = _read_json_object(Path(args.state))
        health = state.get("health", {})
        history = state.get("history", [])
        active = state.get("active", [])
        if not isinstance(health, dict) or not isinstance(history, list) or not isinstance(active, list):
            raise SelectionError("bad state shape")
        decision = select_worker(
            registry,
            request,
            health,
            history,
            active,
            installed=state.get("installed"),
            exhausted=state.get("exhausted") or [],
            previous_reviewer=state.get("previous_reviewer"),
        )
    except SelectionError as exc:
        print(exc.diagnostic)
        return 1
    payload = {
        "winner": decision.winner,
        "status": decision.status,
        "score": decision.score,
        "parts": dict(decision.parts),
        "candidates": [
            {"worker": item.worker, "score": item.score, "parts": dict(item.parts)}
            for item in decision.candidates
        ],
        "discarded": [
            {"worker": item.worker, "reasons": list(item.reasons)}
            for item in decision.discarded
        ],
    }
    print(json.dumps(payload, sort_keys=True))
    return 0


def probe_worker(worker: Worker, env: Mapping[str, str], timeout: float) -> tuple[str, str]:
    """Corre el health argv con tope interno; clasifica por patrones y salida."""
    binary = resolve_binary(worker, env)
    if binary is None or not binary.is_file():
        return ("broken", "missing-executable")
    argv = [str(binary) if item == worker.binary else item for item in worker.commands["health"]]
    try:
        completed = subprocess.run(
            [argv[0], *argv[1:]],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except OSError:
        return ("broken", "launch-failed")
    except subprocess.TimeoutExpired:
        return ("broken", "timeout")
    output = f"{completed.stdout}\n{completed.stderr}".lower()
    if any(pattern.lower() in output for pattern in worker.auth_patterns):
        return ("unauthenticated", "auth-pattern")
    if any(pattern.lower() in output for pattern in worker.quota_patterns):
        return ("limited", "quota-pattern")
    if any(pattern.lower() in output for pattern in worker.blocked_patterns):
        return ("broken", "blocked-pattern")
    if completed.returncode == 0:
        return ("available", "ok")
    return ("broken", f"exit-{completed.returncode}")


def cmd_state_reduce(args: argparse.Namespace) -> int:
    try:
        record = load_record(Path(args.record))
    except StateError as exc:
        print(exc.diagnostic)
        return 1
    try:
        raws = json.loads(Path(args.events).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        print("ERROR invalid event")
        return 1
    if not isinstance(raws, list):
        print("ERROR invalid event")
        return 1
    try:
        next_record, applied, duplicated = reduce_events(record, raws)
    except EventError as exc:
        print(exc.diagnostic)
        return 1
    except StateError as exc:
        print(exc.diagnostic)
        return 1
    try:
        write_atomic(Path(args.record), next_record)
    except OSError:
        print("ERROR invalid record")
        return 1
    print(f"APPLIED {applied} DUPLICATED {duplicated}")
    return 0


def cmd_reconcile(args: argparse.Namespace) -> int:
    try:
        record = load_record(Path(args.record))
    except StateError as exc:
        print(exc.diagnostic)
        return 1
    try:
        observations = json.loads(Path(args.observations).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        print("ERROR invalid observations")
        return 1
    if not isinstance(observations, dict):
        print("ERROR invalid observations")
        return 1
    _, effects = reconcile(state_from_record(record), observations)
    print(json.dumps(
        {
            "effects": [effect.to_json() for effect in effects],
            "digest": decision_digest(record, observations),
        },
        sort_keys=True,
    ))
    return 0


def cmd_gate(args: argparse.Namespace) -> int:
    if args.action not in GATE_ACTIONS:
        print("ERROR invalid gate input")
        return 2
    try:
        record = load_record(Path(args.record))
    except StateError as exc:
        print(exc.diagnostic)
        return 1
    lane = next(
        (
            item
            for item in record.get("lanes") or []
            if isinstance(item, dict) and item.get("id") == args.lane
        ),
        None,
    )
    if lane is None:
        print("ERROR invalid gate input")
        return 2
    try:
        evidence = json.loads(Path(args.evidence).read_text(encoding="utf-8"))
        pr = json.loads(Path(args.pr).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        print("ERROR invalid gate input")
        return 2
    if not isinstance(evidence, dict) or not isinstance(pr, dict):
        print("ERROR invalid gate input")
        return 2
    try:
        raw_receipt = Path(args.receipt).read_text(encoding="utf-8").strip()
    except OSError:
        raw_receipt = ""
    receipt = None
    if raw_receipt:
        try:
            receipt = json.loads(raw_receipt)
        except json.JSONDecodeError:
            print("ERROR invalid gate input")
            return 2
        if not isinstance(receipt, dict):
            print("ERROR invalid gate input")
            return 2
    try:
        receipt_status = int(args.receipt_status)
    except (TypeError, ValueError):
        print("ERROR invalid gate input")
        return 2
    # Contrato: recibo presente equivale a kit aceptado. Si el kit lo
    # rechazo (status distinto de 0), el recibo no llega a la decision aunque
    # el llamador lo haya pasado; el motivo del kit da el codigo.
    if receipt_status != 0:
        receipt = None
    decision = gate_decision(
        {
            "lane": lane,
            "evidence": evidence,
            "receipt": receipt,
            "receipt_status": receipt_status,
            "receipt_error": args.receipt_error or "",
            "pr": pr,
        },
        args.action,
        args.sha,
    )
    print(json.dumps(decision.to_json(), sort_keys=True))
    return 0


def cmd_health_probe(args: argparse.Namespace) -> int:
    try:
        registry = load_registry(Path(args.registry))
    except RegistryError as exc:
        print(exc.diagnostic)
        return 1
    try:
        timeout = float(args.timeout)
    except (TypeError, ValueError):
        print("ERROR invalid timeout")
        return 1
    if timeout <= 0:
        print("ERROR invalid timeout")
        return 1
    if args.worker:
        workers = [worker for worker in registry.workers if worker.id == args.worker]
        if not workers:
            print("ERROR unknown worker")
            return 1
    elif args.format == "status":
        print("ERROR worker required for status format")
        return 1
    else:
        workers = list(registry.workers)
    env = dict(os.environ)
    results = {worker.id: probe_worker(worker, env, timeout) for worker in workers}
    if args.format == "status":
        print(results[workers[0].id][0])
        return 0
    print(json.dumps(
        {"results": {wid: {"status": st, "detail": dt} for wid, (st, dt) in sorted(results.items())}},
        sort_keys=True,
    ))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="corrida-worker.py")
    sub = parser.add_subparsers(dest="command", required=True)

    registry = sub.add_parser("registry")
    registry_sub = registry.add_subparsers(dest="action", required=True)
    validate = registry_sub.add_parser("validate")
    validate.add_argument("--registry", required=True)
    validate.set_defaults(func=cmd_registry_validate)
    listing = registry_sub.add_parser("list")
    listing.add_argument("--registry", required=True)
    listing.set_defaults(func=cmd_registry_list)

    record = sub.add_parser("record")
    record_sub = record.add_subparsers(dest="action", required=True)
    record_validate = record_sub.add_parser("validate")
    record_validate.add_argument("--record", required=True)
    record_validate.set_defaults(func=cmd_record_validate)

    select = sub.add_parser("select")
    select.add_argument("--registry", required=True)
    select.add_argument("--request", required=True)
    select.add_argument("--state", required=True)
    select.set_defaults(func=cmd_select)

    state = sub.add_parser("state")
    state_sub = state.add_subparsers(dest="action", required=True)
    reduce = state_sub.add_parser("reduce")
    reduce.add_argument("--record", required=True)
    reduce.add_argument("--events", required=True)
    reduce.set_defaults(func=cmd_state_reduce)

    reconcile_cmd = sub.add_parser("reconcile")
    reconcile_cmd.add_argument("--record", required=True)
    reconcile_cmd.add_argument("--observations", required=True)
    reconcile_cmd.set_defaults(func=cmd_reconcile)

    gate = sub.add_parser("gate")
    gate.add_argument("--record", required=True)
    gate.add_argument("--lane", required=True)
    gate.add_argument("--action", required=True)
    gate.add_argument("--sha", required=True)
    gate.add_argument("--evidence", required=True)
    gate.add_argument("--receipt", required=True)
    gate.add_argument("--receipt-status", required=True)
    gate.add_argument("--receipt-error", default="")
    gate.add_argument("--pr", required=True)
    gate.set_defaults(func=cmd_gate)

    health = sub.add_parser("health")
    health_sub = health.add_subparsers(dest="action", required=True)
    probe = health_sub.add_parser("probe")
    probe.add_argument("--registry", required=True)
    probe.add_argument("--worker", default=None)
    probe.add_argument("--timeout", default="10")
    probe.add_argument("--format", choices=("json", "status"), default="json")
    probe.set_defaults(func=cmd_health_probe)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
