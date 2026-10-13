#!/usr/bin/env python3
"""La línea de comandos de los encargos "por CLI".

`preparar` y `estado` son de `main`: dicen en el mismo turno si un pedido puede correr y con qué host, y
después qué corrió de verdad una tarea y qué decirle al operador si falló.
`proveedores`, `permitir` y `cerrar` son del operador: muestran y cambian qué proveedores pueden correr,
con sus palabras. `permitir` y `cerrar` escriben la política del checkout donde corren, y el cambio llega
al host por un PR. Sale 0 si la respuesta es sí, 3 si es un rechazo y 1 si opencode no contestó.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Literal

from contracts import HostBeat, SessionRecord
from modelos import (MODEL_PATTERN, POLICY_FILE, PROVIDER, Billing, Catalog, CatalogStore, CatalogUnavailable,
                     Explicacion, HostDown, HostMismatch, MalformedModel, ModelFilter, ModelId, ModelNotListed,
                     OperatorCitation, PermittedModel, ProviderClosure, ProviderGrant, ProviderId,
                     ProviderNotConfigured, ProviderPolicy, SlotBlocked, WorkspaceRefused, authorize, explicar, pedido,
                     policy_document)
from sesion import (ALLOWED_ROOT, COVERAGE_FILE, EXIT_NO_WORKSPACE, EXIT_OUTSIDE_GROUP, Route, Workspace,
                    read_events)

HOST_ID = "mac-local"
ADAPTER_ID = "opencode"
OPERATOR = "David"
BEAT_ALIVE_SECONDS = 120.0
"""Una pasada del host con RPC colgados tarda hasta 105 s."""
CATALOG_RECHECK_SECONDS = 60.0
GIT_TIMEOUT_SECONDS = 10.0
OPENCODE_BIN = Path(os.environ.get("AGENT_WORK_OPENCODE", "/opt/homebrew/bin/opencode"))
STATE_ROOT = Path(os.environ.get("AGENT_WORK_STATE_ROOT", str(Path.home() / ".local/state/agent-work-host")))
PROMPTS_DB = Path.home() / ".claude-mem/claude-mem.db"
CHECKOUT = Path(__file__).resolve().parents[2]
PROMPT_REF = re.compile(r"P(\d+)")


@dataclass(frozen=True)
class Preparado:
    modelo: str
    cobro: Billing
    input_revision: dict | None
    """None para un trabajo sin repo: `main` arma su inputRevision de tipo artifact con el brief."""
    brief_args: tuple[str, ...]
    en_fila: bool
    politica: str
    cli: str


@dataclass(frozen=True)
class EstadoTarea:
    """Lo que el host sabe de una tarea. Nada de aquí lleva la capacidad de la tarea: los logs de opencode
    copian los comandos del modelo, y el modelo escribe la capacidad en su acuse."""
    task_id: str
    modelo: str | None
    """El que el host lanzó de verdad, leído de argv.json, no de la memoria de quien pidió."""
    cobro: Billing | None
    estado: str
    cierre: str | None
    explicacion: Explicacion | None
    permisos_negados: tuple[str, ...]
    proveedores_llamados: tuple[str, ...]
    """Debe ser solo el proveedor del modelo."""
    carpeta_de_sesion: str | None
    """Debe ser el repo del encargo."""
    salida: int | None
    """El código con que salió el proceso, cuando el host lo vio salir sin resultado."""
    log_tail: tuple[str, ...]


@dataclass(frozen=True)
class ProviderRow:
    """Una fila de `encargo.py proveedores`: una por permiso, una por cierre y una por cada proveedor que
    opencode lista sin decisión del operador."""
    name: str | None
    provider: str | None
    decision: Literal["permitido", "cerrado", "sin-decision"]
    billing: Billing | None
    cited: str | None
    session: Literal["con-sesion", "sin-sesion", "sin-id"]
    listed_models: int
    permitted_models: int
    """Cuántos de los listados cubre el permiso. Difiere de `listed_models` cuando el permiso trae filtro."""


@dataclass(frozen=True)
class CitaCotejada:
    citation: OperatorCitation
    verificada: bool


def latido(state_root: Path, now: float) -> "HostBeat | HostDown":
    beat = HostBeat.read(state_root)
    if beat is None:
        return HostDown(None)
    if now - beat.beat_at >= BEAT_ALIVE_SECONDS:
        return HostDown(now - beat.beat_at)
    return beat


def _head(repo: Path) -> str | None:
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        done = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
                              capture_output=True, text=True, timeout=GIT_TIMEOUT_SECONDS, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None
    sha = done.stdout.strip()
    return sha if done.returncode == 0 and re.fullmatch(r"[0-9a-f]{40,64}", sha) else None


def preparar(repo: Path | None, modelo: str | None, *, state_root: Path, checkout: Path, now: float,
             opencode_bin: Path = OPENCODE_BIN, allowed_root: Path = ALLOWED_ROOT) -> "Preparado | Explicacion":
    """`encargo.py preparar [--repo <ruta>] [--modelo "<palabras>"]`.

    El pedido se juzga antes que el host, así "ese proveedor no está permitido" no queda tapado por "el
    host no corre". Es un aviso y no la compuerta: usa la misma authorize, la misma política y el mismo
    catálogo que el host, y si alguien se la salta el host rechaza igual."""
    policy = ProviderPolicy.load(Path(checkout) / POLICY_FILE)
    store = CatalogStore(opencode_bin, state_root)
    catalog = store.current()
    request = pedido(modelo)
    model = request if isinstance(request, MalformedModel) else authorize(request, policy, catalog)
    if isinstance(model, (ProviderNotConfigured, ModelNotListed)) and now - catalog.listed_at > CATALOG_RECHECK_SECONDS:
        # David pudo acabar de correr `opencode auth login`: se mira una vez más antes de decir que falta.
        catalog = store.refresh()
        model = authorize(request, policy, catalog)
    if not isinstance(model, PermittedModel):
        return explicar(model)
    workspace = None
    if repo is not None:
        workspace = Workspace.for_repository(str(repo), allowed_root=allowed_root)
        if not isinstance(workspace, Workspace):
            return explicar(workspace)
    try:
        coverage = json.loads((Path(checkout) / COVERAGE_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        coverage = {}
    beat = latido(state_root, now)
    # Un host canario vivo corre también una ruta todavía sin certificar: su canario es un pedido real.
    canary = isinstance(beat, HostBeat) and beat.canary
    closed = Route.load(coverage, HOST_ID).open_for(catalog.cli_version, canary=canary)
    if closed is not None:
        return explicar(closed)
    if isinstance(beat, HostDown):
        return explicar(beat)
    for what, theirs, ours in (("checkout", os.path.realpath(beat.checkout), os.path.realpath(checkout)),
                               ("policy", beat.policy_digest, policy.digest),
                               ("cli-version", beat.cli_version, catalog.cli_version)):
        if theirs != ours:
            return explicar(HostMismatch(what, str(theirs), str(ours)))
    if beat.slot == "blocked":
        return explicar(SlotBlocked(beat.blocked_by))
    revision = None
    if workspace is not None:
        sha = _head(workspace.root)
        if sha is None:
            return explicar(WorkspaceRefused(str(repo), "not-a-git-toplevel"))
        revision = {"kind": "code", "repository": str(workspace.root), "sha": sha}
    return Preparado(str(model.model), model.billing, revision,
                     ("--host", HOST_ID, "--adapter", ADAPTER_ID, "--model", str(model.model)),
                     beat.slot == "running", model.policy_digest[:12], beat.cli_version)


_SALIDAS = {
    EXIT_NO_WORKSPACE: " El host no pudo entrar a la carpeta del encargo.",
    EXIT_OUTSIDE_GROUP: " El proceso no quedó en el grupo del slot y el host no lanzó opencode.",
}


def _operacion(spool: Path, task_id: str) -> "dict | None":
    """La operación más reciente de esa tarea, con su recurso y sus incidencias, leída sin abrir el spool
    para escritura."""
    path = Path(spool) / "host.sqlite"
    if not path.is_file():
        return None
    db = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        rows = db.execute("SELECT o.operation_id,o.operation_json,o.status,r.state FROM operations o "
                          "LEFT JOIN resources r ON r.operation_id=o.operation_id").fetchall()
        found = None
        for row in rows:
            assignment = json.loads(row["operation_json"])
            if assignment.get("taskId") == task_id and (found is None or assignment["generation"]
                                                        > found["assignment"]["generation"]):
                found = {"operation": row["operation_id"], "assignment": assignment, "status": row["status"],
                         "resource": row["state"]}
        if found is not None:
            incidents = db.execute("SELECT incident_json FROM incidents WHERE operation_id=? ORDER BY rowid",
                                   (found["operation"],)).fetchall()
            found["episodes"] = [json.loads(row[0]).get("episodeId", "permission-required") for row in incidents]
        return found
    except (sqlite3.Error, ValueError, KeyError, TypeError):
        return None
    finally:
        db.close()


def _json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def estado(task_id: "str | None", *, state_root: Path, checkout: Path,
           now: float) -> "EstadoTarea | HostBeat | Explicacion":
    """`encargo.py estado [--tarea <taskId>]`. Solo lectura. Sin tarea contesta el latido del host. Con
    tarea, qué modelo corrió de verdad, en qué carpeta abrió la sesión, a qué proveedores llamó y, si hubo
    incidencia, la frase y la acción."""
    if task_id is None:
        beat = latido(state_root, now)
        return explicar(beat) if isinstance(beat, HostDown) else beat
    beat = HostBeat.read(state_root)
    if beat is None:
        return explicar(HostDown(None))
    found = _operacion(Path(beat.spool), task_id)
    if found is None:
        return Explicacion("tarea-desconocida", f"El host de encargos no tiene ninguna operación de la tarea {task_id}. "
                           "Puede que todavía no la haya reclamado.", "esperar")
    assignment = found["assignment"]
    record = SessionRecord.locate(Path(beat.spool), found["operation"])
    capability = assignment.get("capability") or None

    def limpio(text: str) -> str:
        return text.replace(capability, "<capacidad>") if capability else text

    argv = _json(record.argv)
    modelo = argv[argv.index("-m") + 1] if isinstance(argv, list) and "-m" in argv[:-1] else None
    parsed = ModelId.parse(modelo) if modelo else None
    grant = (ProviderPolicy.load(Path(checkout) / POLICY_FILE).grant_for(parsed.provider)
             if isinstance(parsed, ModelId) else None)
    events = read_events(record.path)
    left = _json(record.exit)
    salida = left.get("code") if isinstance(left, dict) and isinstance(left.get("code"), int) else None
    explicacion = None
    if found["episodes"]:
        episode = found["episodes"][-1]
        blocked = _json(record.blocked)
        refused = assignment.get("refused")
        if episode == "launch-refused" and isinstance(refused, dict):
            explicacion = Explicacion(refused["causa"], refused["frase"], "cancelar")
        elif episode == "launch-failed" and argv is None and isinstance(blocked, dict):
            explicacion = explicar(SlotBlocked(tuple(blocked.get("boundary", ()))), registrado=True)
        else:
            explicacion = explicar(episode, eventos=events)
            explicacion = replace(explicacion, frase=limpio(explicacion.frase + _SALIDAS.get(salida, "")))
    return EstadoTarea(
        task_id, modelo, grant.billing if grant else None, found["status"],
        found["resource"] if found["resource"] in ("AbsenceVerified", "CleanupPending") else None, explicacion,
        tuple(f"{denied.permission}:{denied.pattern}" for denied in events.denied) if events else (),
        events.providers_called if events else (), events.session_directory if events else None, salida,
        tuple(limpio(line) for line in (*events.tail, *events.log_errors)) if events else ())


def _cited(decision: OperatorCitation) -> str:
    return f"{decision.by} {decision.on} {decision.ref}"


def _session(provider: ProviderId | None, catalog: Catalog) -> Literal["con-sesion", "sin-sesion", "sin-id"]:
    if provider is None:
        return "sin-id"
    return "con-sesion" if catalog.of(provider) else "sin-sesion"


def _grant_row(grant: ProviderGrant, catalog: Catalog) -> ProviderRow:
    listed = catalog.of(grant.provider) if grant.provider is not None else frozenset()
    return ProviderRow(grant.name, grant.provider, "permitido", grant.billing, _cited(grant.decision),
                       _session(grant.provider, catalog), len(listed), sum(grant.admits(model) for model in listed))


def _closure_row(closure: ProviderClosure, catalog: Catalog) -> ProviderRow:
    return ProviderRow(None, closure.provider, "cerrado", None, _cited(closure.decision),
                       _session(closure.provider, catalog), len(catalog.of(closure.provider)), 0)


def proveedores(*, state_root: Path, checkout: Path, refrescar: bool = False,
                opencode_bin: Path = OPENCODE_BIN) -> "tuple[ProviderRow, ...] | str":
    """`encargo.py proveedores [--refrescar]`. Solo lectura. Las filas, o la razón por la que la política
    no se puede leer. "con-sesion" significa que opencode lista al menos un modelo suyo."""
    policy = ProviderPolicy.load(Path(checkout) / POLICY_FILE)
    if policy.unreadable is not None:
        return policy.unreadable
    store = CatalogStore(opencode_bin, state_root)
    catalog = store.refresh(upstream=True) if refrescar else store.current()
    decided = {grant.provider for grant in policy.grants} | set(policy.closed)
    undecided = sorted({model.provider for model in catalog.models} - decided)
    return (tuple(_grant_row(grant, catalog) for grant in policy.grants)
            + tuple(_closure_row(closure, catalog) for closure in policy.closed.values())
            + tuple(ProviderRow(None, provider, "sin-decision", None, None, "con-sesion", len(catalog.of(provider)), 0)
                    for provider in undecided))


def citar(ref: str, quote: str, fecha: str | None, prompts: Path) -> "CitaCotejada | str":
    """La cita del operador, cotejada contra el historial de prompts, o la razón por la que no vale.

    El texto del prompt nunca sale de sqlite: la consulta contesta solo si la cita es una subcadena y la
    fecha del prompt. En esa base hay prompts con secretos."""
    if not quote.strip():
        return "la cita está vacía"
    numbered = PROMPT_REF.fullmatch(ref)
    verified = False
    if numbered and prompts.exists():
        try:
            db = sqlite3.connect(f"{prompts.resolve().as_uri()}?mode=ro", uri=True)
            try:
                row = db.execute("SELECT instr(prompt_text, ?) > 0, substr(created_at, 1, 10) FROM user_prompts "
                                 "WHERE id = ?", (quote, int(numbered[1]))).fetchone()
            finally:
                db.close()
        except sqlite3.Error as exc:
            return f"no se pudo leer la base de prompts {prompts}: {exc}"
        if row is None:
            return f"no existe el prompt {ref} en {prompts}"
        if not row[0]:
            return f"la cita no es una subcadena literal del prompt {ref}"
        if fecha is not None and fecha != row[1]:
            return f"--fecha {fecha} no es la fecha del prompt {ref}, que es {row[1]}"
        on, verified = row[1], True
    elif fecha is None:
        return (f"la cita no se puede cotejar (sin {prompts}, o {ref} no es un P####): pasa --fecha AAAA-MM-DD y "
                "queda como cita sin verificar")
    else:
        on = fecha
    citation = OperatorCitation.parse({"by": OPERATOR, "on": on, "ref": ref, "quote": quote})
    return citation if isinstance(citation, str) else CitaCotejada(citation, verified)


def _host_checkout(checkout: Path, state_root: Path) -> str | None:
    beat = HostBeat.read(state_root)
    if beat is not None and os.path.realpath(beat.checkout) == os.path.realpath(checkout):
        return (f"{checkout} es el del host de encargos ({state_root}/host.json): la política entra al host por "
                "un PR y su git pull, no por una escritura en vivo")
    return None


def _write_policy(checkout: Path, grants: "tuple[ProviderGrant, ...]", closed: dict) -> str | None:
    """Escritura atómica en formato canónico. Relee lo escrito: una política que no carga no se deja."""
    path = Path(checkout) / POLICY_FILE
    document = policy_document(grants, closed)
    descriptor, pending = tempfile.mkstemp(prefix=".politica-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(document)
            stream.flush()
            os.fsync(stream.fileno())
        unreadable = ProviderPolicy.load(Path(pending)).unreadable
        if unreadable is not None:
            return f"la política resultante no carga: {unreadable}"
        os.chmod(pending, 0o644)
        os.replace(pending, path)
    finally:
        if os.path.exists(pending):
            os.unlink(pending)
    return None


def _closed_phrase(closure: ProviderClosure) -> str:
    decision = closure.decision
    return (f"{closure.provider} está cerrado por {decision.by} ({decision.on}, {decision.ref}): "
            f"«{decision.quote}». Abrirlo pide --reabre con una frase nueva suya en --ref y --cita")


def permitir(name: str, *, provider: ProviderId | None, billing: Billing | None,
             citation: OperatorCitation | None, reopens: bool, checkout: Path, state_root: Path,
             include: tuple[str, ...] = (), exclude: tuple[str, ...] = (),
             opencode_bin: Path = OPENCODE_BIN) -> "ProviderRow | str":
    """`encargo.py permitir <nombre> [--proveedor <id>] [--cobro subscription|per-token] [--solo <patrón>]
    [--menos <patrón>] [--ref P#### --cita "<palabras del operador>"] [--reabre]`

    La fila que quedó escrita, o la razón por la que no escribió. Tres usos:
      permiso nuevo, o frase nueva sobre uno que existe   `--cobro` con `--ref` y `--cita`. Reemplaza la
                                                          decisión y quita el filtro que hubiera.
      filtro de modelos de un permiso que existe          `--solo` (y `--menos`) con `--ref` y `--cita`.
      ligar el id de un permiso que existe                solo `--proveedor`. No pide otra frase: el
                                                          operador ya lo permitió y esto registra un hecho.
    Un id se liga cuando opencode ya lista modelos suyos, así nadie lo adivina. Un proveedor cerrado no
    se abre sin `--reabre` y una frase nueva. Nada se escribe en el checkout del host."""
    refused = _host_checkout(checkout, state_root)
    if refused is not None:
        return refused
    policy = ProviderPolicy.load(Path(checkout) / POLICY_FILE)
    if policy.unreadable is not None:
        return policy.unreadable
    if not PROVIDER.fullmatch(name) or (provider is not None and not PROVIDER.fullmatch(provider)):
        return f"nombre inválido o id de proveedor inválido: {name} {provider or ''}".rstrip()
    for pattern in include + exclude:
        if not MODEL_PATTERN.fullmatch(pattern):
            return f"patrón de modelos inválido: {pattern!r}"
    if exclude and not include:
        return "--menos va con --solo"
    existing = next((grant for grant in policy.grants if grant.name == name), None)
    if citation is None:
        if billing is not None or include:
            return "un permiso nuevo, un cambio de cobro o un filtro piden --ref y --cita con las palabras del operador"
        if provider is None:
            return "sin --ref y --cita solo se liga un id: pasa --proveedor"
        if existing is None:
            return f"{name} no tiene permiso: uno nuevo pide --cobro, --ref y --cita"
        if existing.provider not in (None, provider):
            return (f"{name} ya está ligado a {existing.provider}: cambiarlo pide una frase nueva del operador "
                    "en --ref y --cita")
        grant = replace(existing, provider=provider)
    else:
        models = ModelFilter(include, exclude, citation) if include else None
        bound = provider if provider is not None else (existing.provider if existing is not None else None)
        if billing is not None:
            grant = ProviderGrant(name, bound, billing, citation, models)
        elif existing is not None and models is not None:
            grant = replace(existing, provider=bound, models=models)
        else:
            return ("con --ref y --cita pasa --cobro (permiso nuevo o frase nueva) o --solo (filtro de un permiso "
                    "que existe)")
    closed_here = [key for key in dict.fromkeys((name, grant.provider)) if key in policy.closed]
    if closed_here and not (reopens and citation is not None):
        return _closed_phrase(policy.closed[closed_here[0]])
    if grant.provider is not None:
        holder = policy.grant_for(grant.provider)
        if holder is not None and holder.name != name:
            return f"{grant.provider} ya es el id de {holder.name}"
    store = CatalogStore(opencode_bin, state_root)
    if grant.provider is not None and grant.provider != (existing.provider if existing is not None else None):
        catalog = store.refresh()
        if not catalog.of(grant.provider):
            return (f"opencode no lista ningún modelo con el id {grant.provider}: un id se liga cuando el operador "
                    "ya inició sesión y `encargo.py proveedores` lo muestra")
    else:
        catalog = store.current()
    grants = (tuple(grant if entry.name == name else entry for entry in policy.grants) if existing is not None
              else policy.grants + (grant,))
    closed = {key: closure for key, closure in policy.closed.items() if key not in closed_here}
    return _write_policy(checkout, grants, closed) or _grant_row(grant, catalog)


def cerrar(provider: ProviderId, *, citation: OperatorCitation, checkout: Path, state_root: Path,
           opencode_bin: Path = OPENCODE_BIN) -> "ProviderRow | str":
    """`encargo.py cerrar <proveedor> --ref P#### --cita "<palabras del operador>"`. Quita el permiso si lo
    había y deja el cierre con su cita. Un permiso sin id todavía se cierra por su nombre."""
    refused = _host_checkout(checkout, state_root)
    if refused is not None:
        return refused
    policy = ProviderPolicy.load(Path(checkout) / POLICY_FILE)
    if policy.unreadable is not None:
        return policy.unreadable
    if not PROVIDER.fullmatch(provider):
        return f"id de proveedor inválido: {provider}"
    named = next((grant for grant in policy.grants
                  if grant.name == provider and grant.provider not in (None, provider)), None)
    if named is not None:
        # Cerrar la palabra dejaría vivo el permiso, y su proveedor seguiría corriendo.
        return f"{provider} es el nombre del permiso de {named.provider}: lo que se cierra es {named.provider}"
    closure = ProviderClosure(provider, citation)
    grants = tuple(grant for grant in policy.grants
                   if grant.provider != provider and not (grant.provider is None and grant.name == provider))
    catalog = CatalogStore(opencode_bin, state_root).current()
    return _write_policy(checkout, grants, {**policy.closed, provider: closure}) or _closure_row(closure, catalog)


def _table(rows: "tuple[ProviderRow, ...]") -> str:
    cells = [("nombre", "proveedor", "decisión", "cobro", "sesión", "lista", "entran", "cita")]
    for row in rows:
        unbound = row.decision == "permitido" and row.provider is None
        cells.append((row.name or "-", "(sin id)" if unbound else row.provider, row.decision, row.billing or "-",
                      row.session, "-" if unbound else str(row.listed_models),
                      str(row.permitted_models) if row.decision == "permitido" and not unbound else "-",
                      row.cited or "-"))
    widths = [max(len(line[column]) for line in cells) for column in range(len(cells[0]))]
    return "\n".join("  ".join(cell.ljust(width) for cell, width in zip(line, widths)).rstrip() for line in cells)


def _answer(result: "Preparado | Explicacion | HostBeat | EstadoTarea", now: float) -> tuple[int, dict]:
    if isinstance(result, Explicacion):
        return 3, {"ok": False, "causa": result.causa, "frase": result.frase, "accion": result.accion,
                   "candidatos": list(result.candidatos)}
    if isinstance(result, EstadoTarea):
        why = result.explicacion
        return 0, {"ok": True, "tarea": result.task_id, "modelo": result.modelo, "cobro": result.cobro,
                   "estado": result.estado, "cierre": result.cierre,
                   "explicacion": why and {"causa": why.causa, "frase": why.frase, "accion": why.accion},
                   "permisosNegados": list(result.permisos_negados),
                   "proveedoresLlamados": list(result.proveedores_llamados),
                   "carpetaDeSesion": result.carpeta_de_sesion, "salida": result.salida,
                   "logTail": list(result.log_tail)}
    if isinstance(result, Preparado):
        return 0, {"ok": True, "modelo": result.modelo, "cobro": result.cobro, "inputRevision": result.input_revision,
                   "briefArgs": list(result.brief_args), "enFila": result.en_fila,
                   "host": {"politica": result.politica, "cli": result.cli}}
    return 0, {"ok": True, "pid": result.pid, "latidoHace": round(now - result.beat_at, 1), "slot": result.slot,
               "bloqueadoPor": list(result.blocked_by), "tarea": result.task_id, "modelo": result.model,
               "checkout": result.checkout, "commit": result.commit,
               "politica": result.policy_digest and result.policy_digest[:12], "cli": result.cli_version,
               "canario": result.canary}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="encargo.py", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--checkout", type=Path, default=CHECKOUT, help="checkout de G cuya política se lee o escribe")
    parser.add_argument("--state-root", type=Path, default=STATE_ROOT, help="donde viven host.json y catalogo.json")
    parser.add_argument("--opencode", type=Path, default=OPENCODE_BIN, help="ruta absoluta de opencode")
    parser.add_argument("--workspace-root", type=Path, default=ALLOWED_ROOT, help="raíz de los repos de encargos")
    parser.add_argument("--prompts", type=Path, default=PROMPTS_DB, help="historial de prompts para cotejar una cita")
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("preparar", help="dice si un pedido puede correr y con qué argumentos de brief.py")
    prepare.add_argument("--repo", type=Path)
    prepare.add_argument("--modelo")
    state = commands.add_parser("estado", help="el latido del host de encargos, o lo que corrió una tarea")
    state.add_argument("--tarea", metavar="TASKID")
    listing = commands.add_parser("proveedores", help="qué proveedores pueden correr, cómo cobran y qué falta")
    listing.add_argument("--refrescar", action="store_true", help="pide a opencode que vuelva a bajar su lista")
    allow = commands.add_parser("permitir", help="escribe un permiso, un filtro o el id de un permiso que existe")
    allow.add_argument("nombre")
    allow.add_argument("--proveedor")
    allow.add_argument("--cobro", choices=("subscription", "per-token"))
    allow.add_argument("--solo", action="append", default=[], metavar="PATRÓN")
    allow.add_argument("--menos", action="append", default=[], metavar="PATRÓN")
    allow.add_argument("--reabre", action="store_true")
    close = commands.add_parser("cerrar", help="cierra un proveedor con las palabras del operador")
    close.add_argument("proveedor")
    for command in (allow, close):
        command.add_argument("--ref")
        command.add_argument("--cita")
        command.add_argument("--fecha", help="solo cuando la cita no se puede cotejar contra el historial")
    return parser


def _citation(args: argparse.Namespace) -> "CitaCotejada | str | None":
    if args.ref is None and args.cita is None:
        return None
    if args.ref is None or args.cita is None:
        return "--ref y --cita van juntas"
    return citar(args.ref, args.cita, args.fecha, args.prompts)


def _say(result: "Preparado | Explicacion | HostBeat | EstadoTarea", now: float) -> int:
    code, answer = _answer(result, now)
    print(json.dumps(answer, ensure_ascii=False))
    return code


def _show(command: str, outcome: "tuple[ProviderRow, ...] | ProviderRow | str") -> int:
    if isinstance(outcome, str):
        print(f"{command}: {outcome}", file=sys.stderr)
        return 3
    print(_table(outcome if isinstance(outcome, tuple) else (outcome,)))
    return 0


def _run_preparar(args: argparse.Namespace, where: dict, now: float) -> int:
    return _say(preparar(args.repo, args.modelo, now=now, allowed_root=args.workspace_root, **where), now)


def _run_estado(args: argparse.Namespace, where: dict, now: float) -> int:
    return _say(estado(args.tarea, state_root=args.state_root, checkout=args.checkout, now=now), now)


def _run_proveedores(args: argparse.Namespace, where: dict, now: float) -> int:
    return _show("proveedores", proveedores(refrescar=args.refrescar, **where))


def _run_politica(args: argparse.Namespace, where: dict, now: float) -> int:
    cited = _citation(args)
    if isinstance(cited, str):
        return _show(args.command, cited)
    citation = cited.citation if cited is not None else None
    if args.command == "permitir":
        outcome = permitir(args.nombre, provider=args.proveedor and ProviderId(args.proveedor), billing=args.cobro,
                           citation=citation, reopens=args.reabre, include=tuple(args.solo),
                           exclude=tuple(args.menos), **where)
    elif citation is None:
        outcome = "cerrar pide --ref y --cita con las palabras del operador"
    else:
        outcome = cerrar(ProviderId(args.proveedor), citation=citation, **where)
    code = _show(args.command, outcome)
    if code == 0 and cited is not None and not cited.verificada:
        print("cita sin verificar: no se cotejó contra el historial de prompts")
    return code


_COMMANDS = {"preparar": _run_preparar, "estado": _run_estado, "proveedores": _run_proveedores,
             "permitir": _run_politica, "cerrar": _run_politica}


def main(argv: "list[str] | None" = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if not args.opencode.is_absolute():
        parser.error(f"--opencode va con ruta absoluta: {args.opencode}")
    where = {"state_root": args.state_root, "checkout": args.checkout, "opencode_bin": args.opencode}
    try:
        return _COMMANDS[args.command](args, where, time.time())
    except CatalogUnavailable as exc:
        print(f"encargo: opencode no contestó: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
