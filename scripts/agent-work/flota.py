"""El documento `sistema-agentes.flota.v1` de un intento por CLI (diseño de SUA-03, 4.7).

Lo escribe el host en `runs/<op>/flota.json` cuando la operación cierra, con los logs ya leídos. Una
corrida sin paquete (sin `runs/<op>/contexto/`) no tiene perfil ni generación, y no tiene documento:
`documento` contesta None y no se inventa nada.
"""

from __future__ import annotations

import json
from pathlib import Path

from contexto import digest_de_perfil
from contracts import OperationKey, RunDir, SessionRecord, operation_id
from modelos import ModelId, ProviderPolicy
from sesion import model_in_use, read_events
from spool import atomic_json

SCHEMA = "sistema-agentes.flota.v1"
EXECUTOR = "opencode"
"""La ruta por CLI de hoy es opencode; `cli` queda para la de Claude (diseño, 4.11, conflicto 3)."""
SESSION_AGENTS = ("build", "title")
"""Los agentes de opencode que son la sesión misma, no un hijo de `task`."""


def _json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def requested_model(record: SessionRecord) -> str | None:
    argv = _json(record.argv)
    if isinstance(argv, list) and "-m" in argv[:-1]:
        return argv[argv.index("-m") + 1]
    return None


def documento(assignment: dict, *, state_dir: Path, policy: ProviderPolicy) -> dict | None:
    """El documento de flota de la operación de esa asignación, o None si la corrida no tuvo
    paquete."""
    key = OperationKey(
        assignment["hostId"],
        assignment["taskId"],
        assignment["generation"],
        assignment["instanceId"],
    )
    run = RunDir(Path(assignment["resultRef"]).parent)
    record = SessionRecord.locate(state_dir, operation_id(key))
    manifest = _json(run.context / "poteto.v1.json")
    profile = _json(run.context / "perfil.json")
    launched = _json(record.context)
    if not (
        isinstance(manifest, dict) and isinstance(profile, dict) and isinstance(launched, dict)
    ):
        return None
    events = read_events(record.path)
    asked = requested_model(record)
    used, reason = model_in_use(events, asked)
    parsed = ModelId.parse(asked) if asked else None
    grant = policy.grant_for(parsed.provider) if isinstance(parsed, ModelId) else None
    children = []
    for call in events.calls if events else ():
        child = {"agent": call.agent, "model": call.model}
        if call.agent not in SESSION_AGENTS and child not in children:
            children.append(child)
    # Specialist, generation and the profile digest come from what the HOST recorded at launch,
    # not from the copy the session could have edited (4.7: the document holds what was launched).
    specialist = (
        launched.get("specialist") if isinstance(launched.get("specialist"), str) else profile["id"]
    )
    generation = (
        launched.get("generation")
        if isinstance(launched.get("generation"), int)
        else manifest["generation"]
    )
    profile_digest = (
        launched.get("profile")
        if isinstance(launched.get("profile"), str)
        else digest_de_perfil(profile)
    )
    return {
        "schema": SCHEMA,
        # A loose task is the root of its own tree in R (4.11, conflict 2).
        "rootId": key.task_id,
        "unitId": key.task_id,
        "attempt": key.generation,
        "specialist": specialist,
        "host": key.host_id,
        "executor": EXECUTOR,
        "accountRef": grant.name if grant else None,
        "model": {"id": used} if used else {"id": None, "reason": reason},
        "generation": generation,
        "permissions": list(events.evaluations) if events else [],
        "attestations": [
            {"what": "poteto", "digest": launched["poteto"]},
            {"what": "profile", "digest": profile_digest},
            {"what": "tools", "digest": launched["tools"]},
        ],
        "children": children,
    }


def escribir(assignment: dict, *, state_dir: Path, policy: ProviderPolicy) -> Path | None:
    """Escribe `runs/<op>/flota.json` una vez. Lo escrito no cambia: es lo que se lanzó."""
    run = RunDir(Path(assignment["resultRef"]).parent)
    if run.fleet.exists():
        return run.fleet
    doc = documento(assignment, state_dir=state_dir, policy=policy)
    if doc is None:
        return None
    atomic_json(run.fleet, doc)
    return run.fleet
