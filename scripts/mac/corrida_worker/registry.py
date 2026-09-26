"""Registro versionado de workers (workers.v1): tipos inmutables y validación estricta.

Esquema cerrado de 14.1: una entrada por CLI con model router.
"""
from __future__ import annotations

import json
import re
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

SCHEMA = "workers.v1"
MAX_EXTERNAL_SESSIONS = 4

ALLOWED_PLACEHOLDERS = frozenset({"session_id", "session_name", "worktree", "brief"})
ALLOWED_CAPABILITIES = frozenset({"read", "write", "review", "browser"})
ALLOWED_ROLES = ("write", "review")
ALLOWED_COMMANDS = frozenset(
    {"health", "stop", "start:write", "start:review", "resume:write", "resume:review"}
)
TOP_LEVEL_KEYS = frozenset({"schema", "max_external_sessions", "workers"})
WORKER_KEYS = frozenset(
    {
        "id",
        "harness",
        "binary",
        "provider",
        "model",
        "capabilities",
        "task_types",
        "permission_modes",
        "version",
        "commands",
        "quota_patterns",
        "auth_patterns",
        "blocked_patterns",
        "transcript",
    }
)
TASK_TYPE_RE = re.compile(r"^[a-z0-9_-]+$")
PLACEHOLDER_RE = re.compile(r"\{([^{}]*)\}")
SHELL_CHARS = frozenset(";|&$`\"'\\<>()*?!#~^")


class RegistryError(ValueError):
    """Cualquier defecto de forma del registro."""

    diagnostic = "ERROR invalid registry"


class CommandError(RegistryError):
    """Binario o argv con shell, metacaracteres o marcador desconocido."""

    diagnostic = "ERROR invalid command"


class PatternError(RegistryError):
    """Patrón vacío, no texto o con caracteres de control."""

    diagnostic = "ERROR invalid pattern"


@dataclass(frozen=True)
class Worker:
    id: str
    harness: str
    binary: str
    provider: str
    model: str
    capabilities: tuple[str, ...]
    task_types: tuple[str, ...]
    permission_modes: Mapping[str, str]
    version: str
    commands: Mapping[str, tuple[str, ...]]
    quota_patterns: tuple[str, ...]
    auth_patterns: tuple[str, ...]
    blocked_patterns: tuple[str, ...]
    transcript_kind: str


@dataclass(frozen=True)
class Registry:
    schema: str
    max_external_sessions: int
    workers: tuple[Worker, ...]


def resolve_binary(worker: Worker, env: Mapping[str, str]) -> Path | None:
    override = env.get(f"CORRIDA_WORKER_BIN_{worker.id.upper()}")
    candidate = override or shutil.which(worker.binary)
    return Path(candidate).resolve() if candidate else None


def _is_ascii(text: str) -> bool:
    try:
        text.encode("ascii")
    except UnicodeEncodeError:
        return False
    return True


def _check_binary(binary: object) -> str:
    if not isinstance(binary, str) or not binary:
        raise CommandError("empty binary")
    if any(ch.isspace() for ch in binary):
        raise CommandError("binary with whitespace")
    if any(ch in SHELL_CHARS or ch in "{}" for ch in binary):
        raise CommandError("binary with shell metacharacters")
    if not _is_ascii(binary):
        raise CommandError("non-ascii binary")
    if binary.startswith("/") or binary.startswith("~"):
        raise CommandError("absolute binary path")
    return binary


def _check_argv_element(element: object) -> str:
    if not isinstance(element, str) or not element:
        raise CommandError("empty argv element")
    if any(ch in SHELL_CHARS for ch in element):
        raise CommandError("shell operator in command")
    for name in PLACEHOLDER_RE.findall(element):
        if name not in ALLOWED_PLACEHOLDERS:
            raise CommandError(f"unknown placeholder {{{name}}}")
    rest = PLACEHOLDER_RE.sub("", element)
    if "{" in rest or "}" in rest:
        raise CommandError("unbalanced braces in command")
    return element


def _check_commands(raw: object, capabilities: tuple[str, ...]) -> dict[str, tuple[str, ...]]:
    if not isinstance(raw, dict):
        raise CommandError("commands is not a mapping")
    for key in raw:
        if key not in ALLOWED_COMMANDS:
            raise CommandError(f"unknown command {key}")
    required = {"health", "stop"}
    for role in ALLOWED_ROLES:
        if role in capabilities:
            required.add(f"start:{role}")
            required.add(f"resume:{role}")
    missing = required - set(raw)
    if missing:
        raise CommandError(f"missing role command: {sorted(missing)[0]}")
    checked: dict[str, tuple[str, ...]] = {}
    for key, argv in raw.items():
        if not isinstance(argv, list) or not argv:
            raise CommandError(f"command {key} is not a non-empty array")
        checked[key] = tuple(_check_argv_element(item) for item in argv)
    return checked


def _check_patterns(raw: object, field: str) -> tuple[str, ...]:
    if not isinstance(raw, list):
        raise PatternError(f"{field} is not a list")
    checked: list[str] = []
    for item in raw:
        if not isinstance(item, str) or not item:
            raise PatternError(f"empty pattern in {field}")
        if any(ord(ch) < 32 or ord(ch) == 127 for ch in item):
            raise PatternError(f"control-bearing pattern in {field}")
        checked.append(item)
    return tuple(checked)


def _check_id(raw: object) -> str:
    if not isinstance(raw, str) or not raw:
        raise RegistryError("empty worker id")
    if not _is_ascii(raw):
        raise RegistryError("non-ascii worker id")
    if any(ch.isspace() for ch in raw):
        raise RegistryError("worker id with whitespace")
    return raw


def _check_capabilities(raw: object) -> tuple[str, ...]:
    if not isinstance(raw, list) or not raw:
        raise RegistryError("missing required capabilities")
    for item in raw:
        if item not in ALLOWED_CAPABILITIES:
            raise RegistryError(f"unknown capability {item!r}")
    return tuple(raw)


def _check_task_types(raw: object) -> tuple[str, ...]:
    if not isinstance(raw, list) or not raw:
        raise RegistryError("missing task types")
    for item in raw:
        if not isinstance(item, str) or not TASK_TYPE_RE.match(item):
            raise RegistryError(f"bad task type {item!r}")
    return tuple(raw)


def _check_permission_modes(raw: object, capabilities: tuple[str, ...]) -> dict[str, str]:
    if not isinstance(raw, dict):
        raise RegistryError("permission_modes is not a mapping")
    for key in raw:
        if key not in ALLOWED_ROLES:
            raise RegistryError(f"unknown permission role {key}")
    for role in ALLOWED_ROLES:
        if role in capabilities and role not in raw:
            raise RegistryError(f"missing permission for {role}")
    for key, value in raw.items():
        if not isinstance(value, str) or not value:
            raise RegistryError(f"empty permission mode for {key}")
    return dict(raw)


def _check_transcript(raw: object) -> str:
    if not isinstance(raw, dict):
        raise RegistryError("transcript is not a mapping")
    path = raw.get("path")
    if path is not None:
        if not isinstance(path, str) or not path:
            raise RegistryError("empty transcript path")
        if path.startswith("/"):
            raise RegistryError("absolute transcript path")
    kind = raw.get("kind", "")
    if not isinstance(kind, str) or not kind:
        raise RegistryError("missing transcript kind")
    return kind


def _check_worker(raw: object) -> Worker:
    if not isinstance(raw, dict):
        raise RegistryError("worker is not a mapping")
    unknown = set(raw) - WORKER_KEYS
    if unknown:
        raise RegistryError(f"unknown worker key: {sorted(unknown)[0]}")
    missing = WORKER_KEYS - set(raw)
    if missing:
        raise RegistryError(f"missing worker key: {sorted(missing)[0]}")
    capabilities = _check_capabilities(raw["capabilities"])
    for field in ("harness", "provider"):
        value = raw[field]
        if not isinstance(value, str) or not value or not _is_ascii(value):
            raise RegistryError(f"bad {field}")
    for field in ("model", "version"):
        value = raw[field]
        if not isinstance(value, str) or not value:
            raise RegistryError(f"bad {field}")
    return Worker(
        id=_check_id(raw["id"]),
        harness=raw["harness"],
        binary=_check_binary(raw["binary"]),
        provider=raw["provider"],
        model=raw["model"],
        capabilities=capabilities,
        task_types=_check_task_types(raw["task_types"]),
        permission_modes=_check_permission_modes(raw["permission_modes"], capabilities),
        version=raw["version"],
        commands=_check_commands(raw["commands"], capabilities),
        quota_patterns=_check_patterns(raw["quota_patterns"], "quota_patterns"),
        auth_patterns=_check_patterns(raw["auth_patterns"], "auth_patterns"),
        blocked_patterns=_check_patterns(raw["blocked_patterns"], "blocked_patterns"),
        transcript_kind=_check_transcript(raw["transcript"]),
    )


def load_registry(path: Path) -> Registry:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise RegistryError(f"registry not found: {path}")
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RegistryError(f"unreadable registry: {exc}")
    if not isinstance(raw, dict):
        raise RegistryError("registry is not an object")
    unknown = set(raw) - TOP_LEVEL_KEYS
    if unknown:
        raise RegistryError(f"unknown top-level key: {sorted(unknown)[0]}")
    if raw.get("schema") != SCHEMA:
        raise RegistryError("bad schema")
    if raw.get("max_external_sessions") != MAX_EXTERNAL_SESSIONS:
        raise RegistryError("bad max_external_sessions")
    workers_raw = raw.get("workers")
    if not isinstance(workers_raw, list):
        raise RegistryError("workers is not a list")
    workers = tuple(_check_worker(item) for item in workers_raw)
    ids = [worker.id for worker in workers]
    if len(set(ids)) != len(ids):
        raise RegistryError("duplicate worker id")
    return Registry(schema=SCHEMA, max_external_sessions=MAX_EXTERNAL_SESSIONS, workers=workers)
