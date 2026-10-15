#!/usr/bin/env python3
"""La línea de comandos de los encargos "por CLI".

`preparar` y `estado` son de `main`: dicen en el mismo turno si un pedido puede correr y con qué host, y
después qué corrió de verdad una tarea y qué decirle al operador si falló.
`proveedores`, `permitir` y `cerrar` son del operador: muestran y cambian qué proveedores pueden correr,
con sus palabras. `permitir` y `cerrar` escriben la política del checkout donde corren, y el cambio llega
al host por un PR. Sale 0 si la respuesta es sí, 3 si es un rechazo y 1 si opencode o git no contestaron
a tiempo.

Qué protegen `permitir` y `cerrar`. Que una entrada de la política no le atribuya al operador, por
descuido, algo que no dijo, y que un proveedor que él cerró no se reabra por un comando. Protegen contra
los errores de quien opera y contra un agente que pide por un canal, por ejemplo `main` por Telegram.

Qué no protegen, ni pretenden. A quien corre el comando en la Mac con intención de falsear: esa persona
o ese agente también puede editar el JSON o este código. Contra eso la integridad de la política la dan
el PR revisado, la prueba que fija los cierres y el historial de git, no este comando.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import unicodedata
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable, Iterator, Literal

from contracts import HostBeat, RunDir, SessionRecord
import contexto
from modelos import (MODEL_PATTERN, POLICY_FILE, PROVIDER, Billing, Catalog, CatalogStore, CatalogUnavailable,
                     ContextoIncompleto, Explicacion, HostDown, HostMismatch, ModelFilter, ModelId, ModelNotListed,
                     OperatorCitation, PerfilRechazado, PermittedModel, PolicyUnreadable, ProviderClosure,
                     ProviderGrant, ProviderId, ProviderNotConfigured, ProviderPolicy, SlotBlocked, UNVERIFIED_REF,
                     WorkspaceRefused, authorize, explicar, pedido, policy_document)
from sesion import (ALLOWED_ROOT, COVERAGE_FILE, EXIT_NO_SCRATCH, EXIT_NO_WORKSPACE, EXIT_OUTSIDE_GROUP, PROFILE_ID,
                    Route, Workspace, model_in_use, read_events)

HOST_ID = "mac-local"
ADAPTER_ID = "opencode"
OPERATOR = "David"
CONTEXTO_DIR = Path("scripts/agent-work/contexto")
BEAT_ALIVE_SECONDS = 120.0
"""Una pasada del host con RPC colgados tarda hasta 105 s."""
CATALOG_RECHECK_SECONDS = 60.0
PREPARAR_DEADLINE_SECONDS = 30.0
"""Lo que `preparar` puede tardar en total: `main` lo corre dentro de su turno."""
GIT_TIMEOUT_SECONDS = 5.0
OPENCODE_BIN = Path(os.environ.get("AGENT_WORK_OPENCODE", "/opt/homebrew/bin/opencode"))
STATE_ROOT = Path(os.environ.get("AGENT_WORK_STATE_ROOT", str(Path.home() / ".local/state/agent-work-host")))
PROMPTS_DB = Path.home() / ".claude-mem/claude-mem.db"
CHECKOUT = Path(__file__).resolve().parents[2]
PROMPT_REF = re.compile(r"P(\d{1,18})")
"""Hasta 18 dígitos: un número más largo no cabe en un entero de sqlite."""


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
    """El que el host pidió a opencode, leído del `-m` de argv.json, no de la memoria de quien pidió.
    El que corrió es `modelo_usado`."""
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
    modelo_usado: str | None = None
    """El que opencode llamó de verdad, leído de sus logs y comparado con `modelo` (SUA-03, 4.7)."""
    modelo_usado_razon: str | None = None
    """Por qué `modelo_usado` es None."""
    permisos: tuple[str, ...] = ()
    """Cada permiso que opencode evaluó, permitido o negado, como "<permiso>:<acción>"."""
    flota: dict | None = None
    """El sistema-agentes.flota.v1 del intento, cuando la corrida tuvo paquete y ya cerró."""


PROVIDER_CAUSES = (
    ("The usage limit has been reached.", "proveedor-sin-cuota"),
    ("does not yet include access", "proveedor-sin-modelo"),
)
"""Los textos que opencode dio cuando el proveedor se negó, medidos en B22-canarios.md (gpt y canario
B). No hay texto medido de una sesión vencida: no se clasifica a ciegas."""


def causa_del_proveedor(error: str | None) -> str | None:
    for text, cause in PROVIDER_CAUSES:
        if error and text in error:
            return cause
    return None


@dataclass(frozen=True)
class ProviderRow:
    """Una fila de `encargo.py proveedores`: una por permiso, una por cierre y una por cada proveedor que
    opencode lista sin decisión del operador."""
    name: str | None
    provider: str | None
    decision: Literal["permitido", "cerrado", "sin-decision"]
    billing: Billing | None
    cited: str | None
    session: Literal["con-sesion", "sin-sesion", "sin-id", "sin-catalogo"]
    """"sin-catalogo": opencode no contestó y la fila se escribió sin saber qué lista."""
    listed_models: int
    permitted_models: int
    """Cuántos de los listados cubre el permiso. Difiere de `listed_models` cuando el permiso trae filtro."""


class DeadlineExceeded(RuntimeError):
    """El comando agotó su tope de tiempo fuera de opencode."""


def latido(state_root: Path, now: float) -> "HostBeat | HostDown":
    beat = HostBeat.read(state_root)
    if beat is None:
        return HostDown(None)
    if now - beat.beat_at >= BEAT_ALIVE_SECONDS:
        return HostDown(now - beat.beat_at)
    return beat


def _head(repo: Path) -> str | None:
    """El commit de HEAD, o None si el repo no tiene ninguno."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        done = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
                              capture_output=True, text=True, timeout=GIT_TIMEOUT_SECONDS, env=env)
    except subprocess.TimeoutExpired as exc:
        raise DeadlineExceeded(f"git rev-parse en {repo} no contestó en {GIT_TIMEOUT_SECONDS:.0f} s") from exc
    except OSError:
        return None
    sha = done.stdout.strip()
    return sha if done.returncode == 0 and re.fullmatch(r"[0-9a-f]{40,64}", sha) else None


def _paquete_del_checkout(checkout: Path) -> "dict | Explicacion":
    """El manifiesto del paquete que este checkout llevaría a la corrida, o por qué no se lo puede dar
    a nadie (SUA-03, 4.5): preparar avisa en el mismo turno con la misma compuerta que el host."""
    base = Path(checkout) / CONTEXTO_DIR
    try:
        manifiesto = contexto.leer_json(base / "poteto.v1.json")
        contexto.comprobar_generacion(manifiesto, contexto.leer_json(base / "generaciones.json"))
    except (OSError, ValueError) as error:
        return explicar(ContextoIncompleto(f"el paquete del checkout no se pudo leer: {error}"))
    return manifiesto


def preparar(repo: Path | None, modelo: str | None, *, perfil: str | None = None, state_root: Path, checkout: Path,
             now: float, opencode_bin: Path = OPENCODE_BIN, allowed_root: Path = ALLOWED_ROOT,
             deadline_seconds: float = PREPARAR_DEADLINE_SECONDS) -> "Preparado | Explicacion":
    """`encargo.py preparar [--repo <ruta>] [--modelo "<palabras>"] [--perfil <id>]`.

    El pedido se juzga antes que el host, así "ese proveedor no está permitido" no queda tapado por "el
    host no corre". Es un aviso y no la compuerta: usa la misma authorize, la misma política y el mismo
    catálogo que el host, y si alguien se la salta el host rechaza igual.

    Con `--perfil`, el perfil viaja en la cabecera del brief y el paquete del checkout se exige en el
    mismo turno, con la misma compuerta de generación que el host. Sin `--perfil`, un encargo de hoy:
    ninguna línea de perfil, ningún paquete, y el host lo lanza, lo reporta y lo cierra como siempre.
    Qué perfil lleva cada tipo de pedido lo enseña la skill `encargo-cli` (G4), no esta línea.

    Termina dentro de `deadline_seconds`: opencode tiene ese tope menos lo que se le reserva a git."""
    policy = ProviderPolicy.load(Path(checkout) / POLICY_FILE)
    if policy.unreadable is not None:
        # Antes de llamar a opencode: una política rota se dice aunque opencode no conteste.
        return explicar(PolicyUnreadable(policy.unreadable))
    manifiesto = None
    if perfil is not None:
        if not PROFILE_ID.fullmatch(perfil):
            return explicar(PerfilRechazado("perfil-desconocido", f"{perfil!r} no es un id de perfil"))
        base = Path(checkout) / CONTEXTO_DIR
        try:
            perfiles = contexto.leer_json(base / "perfiles.v1.json")
        except (OSError, ValueError) as error:
            return explicar(ContextoIncompleto(f"el paquete del checkout no se pudo leer: {error}"))
        try:
            contexto.perfil(perfiles, perfil)
        except KeyError:
            return explicar(PerfilRechazado("perfil-desconocido", f"ningún perfil se llama {perfil}"))
        manifiesto = _paquete_del_checkout(checkout)
        if isinstance(manifiesto, Explicacion):
            return manifiesto
    store = CatalogStore(opencode_bin, state_root, budget_seconds=deadline_seconds - GIT_TIMEOUT_SECONDS)
    catalog = store.current()
    request = pedido(modelo)
    model = authorize(request, policy, catalog)
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
    closed = Route.load(coverage, HOST_ID).open_for(catalog.cli_version,
                                                    manifiesto["generation"] if manifiesto else None, canary=canary)
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
            return explicar(WorkspaceRefused(str(repo), "no-commit"))
        revision = {"kind": "code", "repository": str(workspace.root), "sha": sha}
    args = ("--host", HOST_ID, "--adapter", ADAPTER_ID, "--model", str(model.model))
    if perfil is not None:
        args += ("--perfil", perfil)
    return Preparado(str(model.model), model.billing, revision, args,
                     beat.slot == "running", model.policy_digest[:12], beat.cli_version)


_SALIDAS = {
    EXIT_NO_SCRATCH: " El host no pudo crear la carpeta temporal del encargo.",
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
    tarea, qué modelo pidió el host y cuál corrió de verdad, qué permisos evaluó opencode, en qué carpeta
    abrió la sesión, a qué proveedores llamó, su flota.v1 si la tiene y, si hubo incidencia, la frase y
    la acción."""
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
            changed = _json(record.repo_after)
            if episode == "reviewer-wrote-source" and isinstance(changed, dict):
                medidas = {"head": "HEAD", "refs": "las refs", "status": "el status", "diff": "el diff",
                           "config": ".git/config", "hooks": ".git/hooks", "exclude": ".git/info/exclude"}
                cambio = ", ".join(medidas.get(field, field) for field in changed.get("changed", []))
                explicacion = replace(explicacion, frase=f"{explicacion.frase} En {changed.get('repo')} cambió "
                                                         f"{cambio}. El host no deshizo nada.")
            causa = causa_del_proveedor(events.error) if events else None
            if causa and episode in ("launch-failed", "session-closed"):
                explicacion = replace(explicacion, causa=causa)
    usado, razon = model_in_use(events, modelo)
    flota = _json(RunDir(Path(assignment["resultRef"]).parent).fleet) if assignment.get("resultRef") else None
    return EstadoTarea(
        task_id, modelo, grant.billing if grant else None, found["status"],
        found["resource"] if found["resource"] in ("AbsenceVerified", "CleanupPending") else None, explicacion,
        tuple(f"{denied.permission}:{denied.pattern}" for denied in events.denied) if events else (),
        events.providers_called if events else (), events.session_directory if events else None, salida,
        tuple(limpio(line) for line in (*events.tail, *events.log_errors)) if events else (),
        usado, razon, events.evaluations if events else (), flota if isinstance(flota, dict) else None)


def _cited(decision: OperatorCitation) -> str:
    return f"{decision.by} {decision.on} {decision.ref}"


def perfiles(checkout: Path) -> dict:
    """`encargo.py perfiles`. Solo lectura: los perfiles del checkout en una línea, para que quien
    pide vea qué especialidades existen, qué rutas las atienden y qué agentes siguen sin perfil
    (SUA-03, 4.4)."""
    documento = contexto.leer_json(Path(checkout) / CONTEXTO_DIR / "perfiles.v1.json")
    filas = []
    for perfil in documento["profiles"]:
        filas.append({
            "id": perfil["id"], "purpose": perfil["purpose"],
            "resultContracts": list(perfil["resultContracts"]),
            "rutas": [{"ruta": contexto.clave_de_ruta(ruta), "via": list(ruta["via"])}
                      for ruta in perfil["routes"]],
            "writesSource": perfil["writesSource"],
            "competencia": {clave: {"status": dato.get("status"), "validUntil": dato.get("validUntil")}
                            for clave, dato in perfil["competence"].items()},
        })
    return {"ok": True, "perfiles": filas,
            "agentesSinPerfil": [agente["agentId"] for agente in documento.get("agents", ())]}


def _session(provider: ProviderId | None,
             catalog: Catalog | None) -> Literal["con-sesion", "sin-sesion", "sin-id", "sin-catalogo"]:
    if provider is None:
        return "sin-id"
    if catalog is None:
        return "sin-catalogo"
    return "con-sesion" if catalog.of(provider) else "sin-sesion"


def _grant_row(grant: ProviderGrant, catalog: Catalog | None) -> ProviderRow:
    listed = catalog.of(grant.provider) if catalog is not None and grant.provider is not None else frozenset()
    return ProviderRow(grant.name, grant.provider, "permitido", grant.billing, _cited(grant.decision),
                       _session(grant.provider, catalog), len(listed), sum(grant.admits(model) for model in listed))


def _closure_row(closure: ProviderClosure, catalog: Catalog | None) -> ProviderRow:
    return ProviderRow(None, closure.provider, "cerrado", None, _cited(closure.decision),
                       _session(closure.provider, catalog), len(catalog.of(closure.provider)) if catalog else 0, 0)


def _catalog_for_the_row(store: CatalogStore) -> Catalog | None:
    """El catálogo cuando solo sirve para dibujar la fila: una escritura que no depende de él no espera
    a que opencode conteste."""
    try:
        return store.current()
    except CatalogUnavailable:
        return None


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


def citar(ref: str, quote: str, prompts: Path) -> "OperatorCitation | str":
    """Las palabras del operador, cotejadas contra el historial de prompts, o la razón por la que no valen.

    Es el único sitio que escribe `by` con el nombre del operador: sin un prompt P#### que contenga la
    cita, nada se le atribuye. El texto del prompt nunca sale de sqlite: la consulta contesta solo si la
    cita es una subcadena y la fecha del prompt. En esa base hay prompts con secretos."""
    if not quote.strip():
        return "la cita está vacía"
    numbered = PROMPT_REF.fullmatch(ref)
    if numbered is None:
        return f"{ref} no es un prompt P####: solo una cita cotejada contra el historial atribuye algo a {OPERATOR}"
    if not prompts.exists():
        return f"no existe la base de prompts {prompts}: sin ella la cita no se puede cotejar"
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
    return OperatorCitation.parse({"by": OPERATOR, "on": row[1], "ref": ref, "quote": quote})


def _host_checkout(checkout: Path, state_root: Path) -> str | None:
    beat = HostBeat.read(state_root)
    if beat is not None and os.path.realpath(beat.checkout) == os.path.realpath(checkout):
        return (f"{checkout} es el del host de encargos ({state_root}/host.json): la política entra al host por "
                "un PR y su git pull, no por una escritura en vivo")
    return None


_checkpoint: "Callable[[str], None]" = lambda where: None
"""Punto de espera de `_write_policy`, para las pruebas del candado: lo llama con "before-lock" y con
"before-replace"."""


@contextlib.contextmanager
def _policy_lock(path: Path) -> "Iterator[None]":
    """Candado exclusivo entre los procesos que escriben esa política. Va sobre la carpeta del archivo y
    no sobre un archivo de candado: así no queda nada sin trackear junto a la evidencia."""
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def _write_policy(checkout: Path, state_root: Path,
                  change: "Callable[[ProviderPolicy], tuple[tuple[ProviderGrant, ...], dict] | str]") -> str | None:
    """El único sitio que escribe la política. Aplica `change` a lo que hay en disco en ese momento, con
    el candado tomado desde que lo lee hasta que lo reemplaza: un comando que entra en medio espera y
    escribe sobre este resultado, no sobre una foto anterior.

    `change` recibe la política recién leída y devuelve los permisos y cierres nuevos, o la razón por la
    que no aplica. No se deja una política que no carga, ni una que quite o cambie un cierre que está en el
    archivo. `host.json` se vuelve a mirar aquí, porque antes de llegar el comando pudo esperar a opencode
    y un host pudo arrancar desde este checkout."""
    path = Path(checkout) / POLICY_FILE
    _checkpoint("before-lock")
    with _policy_lock(path):
        current = ProviderPolicy.load(path)
        if current.unreadable is not None:
            return current.unreadable
        changed = change(current)
        if isinstance(changed, str):
            return changed
        grants, closed = changed
        touched = [key for key, closure in current.closed.items() if closed.get(key) != closure]
        if touched:
            return f"un comando no quita ni cambia un cierre, y este tocaría el de {', '.join(touched)}"
        refused = _host_checkout(checkout, state_root)
        if refused is not None:
            return refused
        document = policy_document(grants, closed)
        unreadable = ProviderPolicy.parse(document, path.name).unreadable
        if unreadable is not None:
            return f"la política resultante no carga: {unreadable}"
        descriptor, pending = tempfile.mkstemp(prefix=".politica-", dir=path.parent)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(document)
                stream.flush()
                os.fsync(stream.fileno())
            _checkpoint("before-replace")
            os.chmod(pending, 0o644)
            os.replace(pending, path)
        finally:
            if os.path.exists(pending):
                os.unlink(pending)
    return None


def _closed_phrase(closure: ProviderClosure) -> str:
    decision = closure.decision
    return (f"{closure.provider} está cerrado por {decision.by} ({decision.on}, {decision.ref}): "
            f"«{decision.quote}». Ningún comando lo reabre. Reabrirlo es editar {POLICY_FILE} en un PR, con la "
            f"frase nueva de {OPERATOR}, y cambiar en ese mismo PR la prueba que fija los cierres")


def _closed(policy: ProviderPolicy, *keys: "str | None") -> str | None:
    return next((_closed_phrase(policy.closed[key]) for key in keys if key in policy.closed), None)


def permitir(name: str, *, provider: ProviderId | None, billing: Billing | None, ref: str | None,
             quote: str | None, checkout: Path, state_root: Path, prompts: Path = PROMPTS_DB,
             include: tuple[str, ...] = (), exclude: tuple[str, ...] = (),
             opencode_bin: Path = OPENCODE_BIN) -> "ProviderRow | str":
    """`encargo.py permitir <nombre> [--proveedor <id>] [--cobro subscription|per-token] [--solo <patrón>]
    [--menos <patrón>] [--ref P#### --cita "<palabras del operador>"]`

    La fila que quedó escrita, o la razón por la que no escribió. Tres usos:
      permiso nuevo, o frase nueva sobre uno que existe   `--cobro` con `--ref` y `--cita`. Reemplaza la
                                                          decisión y quita el filtro que hubiera.
      filtro de modelos de un permiso que existe          `--solo` (y `--menos`) con `--ref` y `--cita`.
      ligar el id de un permiso que existe                solo `--proveedor`. No pide otra frase: el
                                                          operador ya lo permitió y esto registra un hecho.
    Nunca abre un proveedor cerrado: si el nombre o el id está en `closed` se niega antes de mirar nada
    más, con cualquier combinación de argumentos. La cita se coteja aquí, contra `prompts`, así que no hay
    forma de pasarle una sin cotejar. Un id se liga cuando opencode ya lista modelos suyos, así nadie lo
    adivina. Nada se escribe en el checkout del host."""
    policy = ProviderPolicy.load(Path(checkout) / POLICY_FILE)
    if policy.unreadable is not None:
        return policy.unreadable
    refused = _closed(policy, name, provider)
    if refused is not None:
        return refused
    refused = _host_checkout(checkout, state_root)
    if refused is not None:
        return refused
    if not PROVIDER.fullmatch(name) or (provider is not None and not PROVIDER.fullmatch(provider)):
        return f"nombre inválido o id de proveedor inválido: {name} {provider or ''}".rstrip()
    for pattern in include + exclude:
        if not MODEL_PATTERN.fullmatch(pattern):
            return f"patrón de modelos inválido: {pattern!r}"
    if exclude and not include:
        return "--menos va con --solo"
    if (ref is None) != (quote is None):
        return "--ref y --cita van juntas"
    existing = next((grant for grant in policy.grants if grant.name == name), None)
    if ref is None:
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
        citation = citar(ref, quote, prompts)
        if isinstance(citation, str):
            return citation
        models = ModelFilter(include, exclude, citation) if include else None
        bound = provider if provider is not None else (existing.provider if existing is not None else None)
        if billing is not None:
            grant = ProviderGrant(name, bound, billing, citation, models)
        elif existing is not None and models is not None:
            grant = replace(existing, provider=bound, models=models)
        else:
            return ("con --ref y --cita pasa --cobro (permiso nuevo o frase nueva) o --solo (filtro de un permiso "
                    "que existe)")
    if grant.provider is not None:
        holder = policy.grant_for(grant.provider)
        if holder is not None and holder.name != name:
            return f"{grant.provider} ya es el id de {holder.name}"
    store = CatalogStore(opencode_bin, state_root)
    binds = grant.provider is not None and grant.provider != (existing.provider if existing is not None else None)
    if binds:
        catalog = store.refresh()
        if not catalog.of(grant.provider):
            return (f"opencode no lista ningún modelo con el id {grant.provider}: un id se liga cuando el operador "
                    "ya inició sesión y `encargo.py proveedores` lo muestra")
    else:
        catalog = store.current() if include else _catalog_for_the_row(store)
    if grant.models is not None and grant.provider is not None and (binds or include):
        # Al ligar también: un filtro puesto antes de que el permiso tuviera id nunca se comparó con nada.
        listed = catalog.of(grant.provider)
        if listed and not any(grant.admits(model) for model in listed):
            return (f"el filtro de {name} no cubre ninguno de los modelos que opencode lista de {grant.provider} "
                    f"({len(listed)}): dejaría el proveedor sin ningún modelo")
    def put(current: ProviderPolicy) -> "tuple[tuple[ProviderGrant, ...], dict] | str":
        refused = _closed(current, name, grant.provider)
        if refused is not None:
            return refused
        if next((entry for entry in current.grants if entry.name == name), None) != existing:
            return f"el permiso {name} cambió mientras este comando corría: vuelve a correrlo"
        grants = (tuple(grant if entry.name == name else entry for entry in current.grants) if existing is not None
                  else current.grants + (grant,))
        return grants, dict(current.closed)
    return _write_policy(checkout, state_root, put) or _grant_row(grant, catalog)


def _cannot_close(policy: ProviderPolicy, provider: ProviderId) -> str | None:
    if provider in policy.closed:
        return f"{provider} ya está cerrado y su cierre no se reemplaza. {_closed_phrase(policy.closed[provider])}"
    named = next((grant for grant in policy.grants
                  if grant.name == provider and grant.provider not in (None, provider)), None)
    if named is not None:
        # Cerrar la palabra dejaría vivo el permiso, y su proveedor seguiría corriendo.
        return f"{provider} es el nombre del permiso de {named.provider}: lo que se cierra es {named.provider}"
    return None


def _names_the_operator(by: str) -> bool:
    """Si quien dice cerrar se presenta con el nombre del operador, aunque venga con otras palabras, en
    otro ancho de letra o con caracteres que no se ven."""
    visible = "".join(char for char in unicodedata.normalize("NFKC", by) if unicodedata.category(char) != "Cf")
    return OPERATOR.casefold() in visible.casefold()


def cerrar(provider: ProviderId, *, ref: str | None, quote: str | None, by: str | None, reason: str | None,
           now: float, checkout: Path, state_root: Path, prompts: Path = PROMPTS_DB,
           opencode_bin: Path = OPENCODE_BIN) -> "ProviderRow | str":
    """`encargo.py cerrar <proveedor> --ref P#### --cita "<palabras del operador>"`, o de emergencia
    `encargo.py cerrar <proveedor> --por "<quién>" --motivo "<por qué>"`.

    Quita el permiso si lo había y deja el cierre. Un permiso sin id todavía se cierra por su nombre. Es
    el freno: cierra aunque no haya una frase del operador que cotejar. En ese caso el cierre no lleva su
    nombre: dice quién cerró, por qué, y `sin-cotejar` donde iría el número de prompt. Sobre un proveedor
    que ya está cerrado no escribe nada, así el cierre vigente y su cita no cambian."""
    policy = ProviderPolicy.load(Path(checkout) / POLICY_FILE)
    if policy.unreadable is not None:
        return policy.unreadable
    refused = _cannot_close(policy, provider) or _host_checkout(checkout, state_root)
    if refused is not None:
        return refused
    if not PROVIDER.fullmatch(provider):
        return f"id de proveedor inválido: {provider}"
    cited, emergency = ref is not None or quote is not None, by is not None or reason is not None
    if cited == emergency or (cited and None in (ref, quote)) or (emergency and None in (by, reason)):
        return (f"cerrar pide --ref y --cita con las palabras de {OPERATOR}, o --por y --motivo para cerrar de "
                "emergencia sin atribuirle nada")
    if cited:
        citation = citar(ref, quote, prompts)
    elif _names_the_operator(by):
        citation = f"--por no puede nombrar a {OPERATOR}: lo que él decide se cita con --ref y --cita"
    else:
        citation = OperatorCitation.parse({"by": by, "on": time.strftime("%Y-%m-%d", time.gmtime(now)),
                                           "ref": UNVERIFIED_REF, "quote": reason})
    if isinstance(citation, str):
        return citation
    closure = ProviderClosure(provider, citation)

    def close(current: ProviderPolicy) -> "tuple[tuple[ProviderGrant, ...], dict] | str":
        grants = tuple(grant for grant in current.grants
                       if grant.provider != provider and not (grant.provider is None and grant.name == provider))
        return _cannot_close(current, provider) or (grants, {**current.closed, provider: closure})
    written = _write_policy(checkout, state_root, close)
    return written or _closure_row(closure, _catalog_for_the_row(CatalogStore(opencode_bin, state_root)))


def _table(rows: "tuple[ProviderRow, ...]") -> str:
    cells = [("nombre", "proveedor", "decisión", "cobro", "sesión", "lista", "entran", "cita")]
    for row in rows:
        unbound = row.decision == "permitido" and row.provider is None
        unlisted = unbound or row.session == "sin-catalogo"
        cells.append((row.name or "-", "(sin id)" if unbound else row.provider, row.decision, row.billing or "-",
                      row.session, "-" if unlisted else str(row.listed_models),
                      str(row.permitted_models) if row.decision == "permitido" and not unlisted else "-",
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
                   "logTail": list(result.log_tail), "modeloUsado": result.modelo_usado,
                   "modeloUsadoRazon": result.modelo_usado_razon, "permisos": list(result.permisos),
                   "flota": result.flota}
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
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("preparar", help="dice si un pedido puede correr y con qué argumentos de brief.py")
    prepare.add_argument("--repo", type=Path)
    prepare.add_argument("--modelo")
    prepare.add_argument("--perfil", help="perfil de trabajador para la cabecera del brief; sin él, un encargo sin paquete")
    state = commands.add_parser("estado", help="el latido del host de encargos, o lo que corrió una tarea")
    state.add_argument("--tarea", metavar="TASKID")
    commands.add_parser("perfiles", help="los perfiles del checkout y los agentes sin perfil, en una línea JSON")
    listing = commands.add_parser("proveedores", help="qué proveedores pueden correr, cómo cobran y qué falta")
    listing.add_argument("--refrescar", action="store_true", help="pide a opencode que vuelva a bajar su lista")
    allow = commands.add_parser("permitir", help="escribe un permiso, un filtro o el id de un permiso que existe")
    allow.add_argument("nombre")
    allow.add_argument("--proveedor")
    allow.add_argument("--cobro", choices=("subscription", "per-token"))
    allow.add_argument("--solo", action="append", default=[], metavar="PATRÓN")
    allow.add_argument("--menos", action="append", default=[], metavar="PATRÓN")
    close = commands.add_parser("cerrar", help="cierra un proveedor con las palabras del operador")
    close.add_argument("proveedor")
    close.add_argument("--por", help="quién cierra de emergencia, sin una frase del operador que cotejar")
    close.add_argument("--motivo", help="por qué se cierra de emergencia")
    for command in (allow, close):
        command.add_argument("--ref", help="prompt P#### del historial que contiene la cita")
        command.add_argument("--cita", help="palabras literales del operador en ese prompt")
    return parser


def _say(result: "Preparado | Explicacion | HostBeat | EstadoTarea", now: float) -> int:
    code, answer = _answer(result, now)
    print(json.dumps(answer, ensure_ascii=False))
    return code


def _show(command: str, outcome: "tuple[ProviderRow, ...] | ProviderRow | str") -> int:
    if isinstance(outcome, str):
        print(f"{command}: {outcome}", file=sys.stderr)
        return 3
    rows = outcome if isinstance(outcome, tuple) else (outcome,)
    print(_table(rows))
    if any(row.session == "sin-catalogo" for row in rows):
        print(f"{command}: escrito. opencode no contestó, así que la fila va sin lo que lista.", file=sys.stderr)
    return 0


def _run_preparar(args: argparse.Namespace, where: dict, now: float) -> int:
    return _say(preparar(args.repo, args.modelo, perfil=args.perfil, now=now, allowed_root=args.workspace_root,
                         **where), now)


def _run_estado(args: argparse.Namespace, where: dict, now: float) -> int:
    return _say(estado(args.tarea, state_root=args.state_root, checkout=args.checkout, now=now), now)


def _run_perfiles(args: argparse.Namespace, where: dict, now: float) -> int:
    try:
        respuesta = perfiles(checkout=where["checkout"])
    except (OSError, ValueError, KeyError) as error:
        print(f"perfiles: no se pudo leer perfiles.v1.json del checkout: {error}", file=sys.stderr)
        return 3
    print(json.dumps(respuesta, ensure_ascii=False))
    return 0


def _run_proveedores(args: argparse.Namespace, where: dict, now: float) -> int:
    return _show("proveedores", proveedores(refrescar=args.refrescar, **where))


def _run_politica(args: argparse.Namespace, where: dict, now: float) -> int:
    if args.command == "permitir":
        outcome = permitir(args.nombre, provider=args.proveedor and ProviderId(args.proveedor), billing=args.cobro,
                           ref=args.ref, quote=args.cita, prompts=args.prompts, include=tuple(args.solo),
                           exclude=tuple(args.menos), **where)
    else:
        outcome = cerrar(ProviderId(args.proveedor), ref=args.ref, quote=args.cita, by=args.por, reason=args.motivo,
                         prompts=args.prompts, now=now, **where)
    if isinstance(outcome, ProviderRow) and (outcome.cited or "").endswith(UNVERIFIED_REF):
        print(f"cerrar: cerrado de emergencia, sin cita cotejada. No es una decisión de {OPERATOR}: falta su "
              "frase, que entra con un PR.", file=sys.stderr)
    return _show(args.command, outcome)


_COMMANDS = {"preparar": _run_preparar, "estado": _run_estado, "perfiles": _run_perfiles,
             "proveedores": _run_proveedores,
             "permitir": _run_politica, "cerrar": _run_politica}


def main(argv: "list[str] | None" = None, *, prompts: Path = PROMPTS_DB) -> int:
    """`prompts` no tiene bandera: la línea de comandos coteja siempre contra el historial fijo."""
    parser = _parser()
    args = parser.parse_args(argv)
    args.prompts = prompts
    if not args.opencode.is_absolute():
        parser.error(f"--opencode va con ruta absoluta: {args.opencode}")
    where = {"state_root": args.state_root, "checkout": args.checkout, "opencode_bin": args.opencode}
    try:
        return _COMMANDS[args.command](args, where, time.time())
    except CatalogUnavailable as exc:
        print(f"encargo: opencode no contestó: {exc}", file=sys.stderr)
    except DeadlineExceeded as exc:
        print(f"encargo: {exc}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
