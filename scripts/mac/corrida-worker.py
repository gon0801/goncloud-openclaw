#!/usr/bin/env python3
"""Plano de control de corridas nativas (Fase 14). Solo stdlib.

registry validate|list: valida el registro cerrado workers.v1.
record validate: valida un registro corrida.v2 legado o con workers nativos.
health probe: sonda acotada por worker (sin binario timeout externo).
select: selección determinista con un solo objeto JSON en stdout.
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
