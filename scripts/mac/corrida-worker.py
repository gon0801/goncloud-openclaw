#!/usr/bin/env python3
"""Plano de control de corridas nativas (Fase 14). Solo stdlib.

registry validate|list: valida el registro cerrado workers.v1.
record validate: valida un registro corrida.v2 legado o con workers nativos.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from corrida_worker.registry import RegistryError, load_registry

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
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
