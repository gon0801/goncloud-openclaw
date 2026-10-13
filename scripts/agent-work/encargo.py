#!/usr/bin/env python3
"""La línea de comandos de los encargos "por CLI".

`preparar` y `estado` son de `main`: dicen en el mismo turno si un pedido puede correr y con qué host.
`proveedores`, `permitir` y `cerrar` son del operador: muestran y cambian qué proveedores pueden correr,
con sus palabras. `permitir` y `cerrar` escriben la política del checkout donde corren, y el cambio llega
al host por un PR. Sale 0 si la respuesta es sí, 3 si es un rechazo y 1 si opencode o git no contestaron
a tiempo.
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

from modelos import (MODEL_PATTERN, POLICY_FILE, PROVIDER, Billing, Catalog, CatalogStore, CatalogUnavailable,
                     Explicacion, HostDown, HostMismatch, ModelFilter, ModelNotListed, OperatorCitation,
                     PermittedModel, PolicyUnreadable, ProviderClosure, ProviderGrant, ProviderId,
                     ProviderNotConfigured, ProviderPolicy, SlotBlocked, WorkspaceRefused, authorize, explicar, pedido,
                     policy_document)
from native_gateway import HostBeat
from sesion import ALLOWED_ROOT, COVERAGE_FILE, Route, Workspace

HOST_ID = "mac-local"
ADAPTER_ID = "opencode"
OPERATOR = "David"
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


def preparar(repo: Path | None, modelo: str | None, *, state_root: Path, checkout: Path, now: float,
             opencode_bin: Path = OPENCODE_BIN, allowed_root: Path = ALLOWED_ROOT,
             deadline_seconds: float = PREPARAR_DEADLINE_SECONDS) -> "Preparado | Explicacion":
    """`encargo.py preparar [--repo <ruta>] [--modelo "<palabras>"]`.

    El pedido se juzga antes que el host, así "ese proveedor no está permitido" no queda tapado por "el
    host no corre". Es un aviso y no la compuerta: usa la misma authorize, la misma política y el mismo
    catálogo que el host, y si alguien se la salta el host rechaza igual.

    Termina dentro de `deadline_seconds`: opencode tiene ese tope menos lo que se le reserva a git."""
    policy = ProviderPolicy.load(Path(checkout) / POLICY_FILE)
    if policy.unreadable is not None:
        # Antes de llamar a opencode: una política rota se dice aunque opencode no conteste.
        return explicar(PolicyUnreadable(policy.unreadable))
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
    closed = Route.load(coverage, HOST_ID).open_for(catalog.cli_version, canary=False)
    if closed is not None:
        return explicar(closed)
    beat = latido(state_root, now)
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
    return Preparado(str(model.model), model.billing, revision,
                     ("--host", HOST_ID, "--adapter", ADAPTER_ID, "--model", str(model.model)),
                     beat.slot == "running", model.policy_digest[:12], beat.cli_version)


def _cited(decision: OperatorCitation) -> str:
    return f"{decision.by} {decision.on} {decision.ref}"


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


def _write_policy(checkout: Path, state_root: Path, grants: "tuple[ProviderGrant, ...]", closed: dict) -> str | None:
    """Escritura atómica en formato canónico. Relee lo escrito: una política que no carga no se deja.
    Vuelve a mirar `host.json` justo antes de reemplazar el archivo: entre la primera mirada y este punto
    el comando pudo esperar a opencode, y un host pudo arrancar desde este checkout."""
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
        refused = _host_checkout(checkout, state_root)
        if refused is not None:
            return refused
        os.chmod(pending, 0o644)
        os.replace(pending, path)
    finally:
        if os.path.exists(pending):
            os.unlink(pending)
    return None


def _closed_phrase(closure: ProviderClosure) -> str:
    decision = closure.decision
    return (f"{closure.provider} está cerrado por {decision.by} ({decision.on}, {decision.ref}): "
            f"«{decision.quote}». Abrirlo pide una frase nueva suya, posterior al cierre, en --ref y --cita, con "
            f"--proveedor {closure.provider} y --reabre en el mismo comando")


def _same_words(one: str, other: str) -> bool:
    """Una cita es la otra, o un trozo de la otra, sin contar mayúsculas ni espacios."""
    one, other = (" ".join(text.casefold().split()) for text in (one, other))
    return one in other or other in one


def _not_a_new_phrase(citation: OperatorCitation, closing: ProviderClosure, policy: ProviderPolicy) -> str | None:
    """Por qué `citation` no reabre el proveedor de `closing`, o None si es una frase nueva del operador.

    Nueva quiere decir dos cosas que se pueden comprobar: no es la frase de ningún cierre, ni por su
    prompt ni por sus palabras, y es posterior al cierre que quita."""
    for closure in policy.closed.values():
        decision = closure.decision
        if citation.ref == decision.ref or _same_words(citation.quote, decision.quote):
            return (f"es la frase con la que {decision.by} cerró {closure.provider} ({decision.ref}), y una frase "
                    "de cierre no abre nada")
    closed = closing.decision
    numbered = PROMPT_REF.fullmatch(citation.ref), PROMPT_REF.fullmatch(closed.ref)
    same_day_and_earlier = citation.on == closed.on and all(numbered) and int(numbered[0][1]) < int(numbered[1][1])
    if citation.on < closed.on or same_day_and_earlier:
        return f"es del {citation.on} ({citation.ref}), anterior al cierre del {closed.on} ({closed.ref})"
    return None


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
    Un id se liga cuando opencode ya lista modelos suyos, así nadie lo adivina. Un proveedor cerrado se
    abre solo con `--reabre`, su id en `--proveedor` y una frase nueva: posterior al cierre y distinta, por
    prompt y por palabras, de la frase de cualquier cierre. Nada se escribe en el checkout del host."""
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
    if name in policy.closed and grant.provider != name:
        # Quitar un cierre por la sola coincidencia del nombre dejaría un permiso sin id, y ligar un id no
        # pide frase: el proveedor quedaría abierto en dos pasos. Reabrir y ligar van en un solo comando.
        return _closed_phrase(policy.closed[name])
    closing = policy.closed.get(grant.provider)
    if closing is not None:
        if not reopens or citation is None:
            return _closed_phrase(closing)
        stale = _not_a_new_phrase(citation, closing, policy)
        if stale is not None:
            return f"{_closed_phrase(closing)}. La cita que pasaste no lo abre: {stale}"
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
        catalog = store.current() if include else _catalog_for_the_row(store)
    if include and grant.provider is not None:
        listed = catalog.of(grant.provider)
        if listed and not any(grant.admits(model) for model in listed):
            return (f"el filtro no cubre ninguno de los {len(listed)} modelos que opencode lista de "
                    f"{grant.provider}: dejaría el proveedor sin ningún modelo")
    grants = (tuple(grant if entry.name == name else entry for entry in policy.grants) if existing is not None
              else policy.grants + (grant,))
    closed = {key: closure for key, closure in policy.closed.items() if closure is not closing}
    return _write_policy(checkout, state_root, grants, closed) or _grant_row(grant, catalog)


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
    written = _write_policy(checkout, state_root, grants, {**policy.closed, provider: closure})
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


def _answer(result: "Preparado | Explicacion | HostBeat", now: float) -> tuple[int, dict]:
    if isinstance(result, Explicacion):
        return 3, {"ok": False, "causa": result.causa, "frase": result.frase, "accion": result.accion,
                   "candidatos": list(result.candidatos)}
    if isinstance(result, Preparado):
        return 0, {"ok": True, "modelo": result.modelo, "cobro": result.cobro, "inputRevision": result.input_revision,
                   "briefArgs": list(result.brief_args), "enFila": result.en_fila,
                   "host": {"politica": result.politica, "cli": result.cli}}
    return 0, {"ok": True, "pid": result.pid, "latidoHace": round(now - result.beat_at, 1), "slot": result.slot,
               "bloqueadoPor": list(result.blocked_by), "tarea": result.task_id, "modelo": result.model,
               "checkout": result.checkout, "commit": result.commit,
               "politica": result.policy_digest and result.policy_digest[:12], "cli": result.cli_version}


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
    state = commands.add_parser("estado", help="el latido del host de encargos")
    state.add_argument("--tarea")
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


def _say(result: "Preparado | Explicacion | HostBeat", now: float) -> int:
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
    return _say(preparar(args.repo, args.modelo, now=now, allowed_root=args.workspace_root, **where), now)


def _run_estado(args: argparse.Namespace, where: dict, now: float) -> int:
    beat = latido(args.state_root, now)
    return _say(explicar(beat) if isinstance(beat, HostDown) else beat, now)


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
    if args.command == "estado" and args.tarea is not None:
        parser.error("estado --tarea llega con la fase 2 de B22: lee el spool y los eventos de una sesión, que "
                     "todavía no existen")
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
