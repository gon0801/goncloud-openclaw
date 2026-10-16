#!/usr/bin/env python3
"""El derivador de proyecciones (SUA-06, 4.1): snapshot de una raíz -> proyeccion.v1.

`derivar` es una función pura: ni el reloj ni el mapa de notados salen del snapshot, los
pasa quien llama. `leer` y `listar` hablan con el gateway por el `openclaw` del host.
Biblioteca estándar, Python 3.9 (corre en la Mac y en la Mini).
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import socket
import subprocess
import sys
from collections.abc import Mapping
from datetime import datetime, timedelta, timezone
from pathlib import Path

import spool

SCHEMA = "sistema-agentes.proyeccion.v1"
CHECKPOINT_SCHEMA = "sistema-agentes.emisor-raices.v1"
POLITICA_POR_OMISION = (
    Path(__file__).resolve().parents[2] / "docs/evidence/agent-work/proveedores-permitidos.json"
)
ID_RE = re.compile(r"[A-Za-z0-9._-]{1,80}")
SECRET_RE = re.compile(
    r"gh[pousr]_[A-Za-z0-9]|github_pat_[A-Za-z0-9_]|sk-[A-Za-z0-9_-]{8,}|AKIA[0-9A-Z]{16}"
)
FECHA_RE = re.compile(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z")
REPORTADOS = frozenset({"reported", "accepted"})


def _fecha(momento: datetime) -> str:
    return momento.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _instante(texto: object, nombre: str) -> datetime:
    partes = FECHA_RE.fullmatch(texto) if isinstance(texto, str) else None
    if partes is None:
        raise ValueError(f"{nombre} no es una fecha ISO 8601 en UTC con Z: {texto!r}")
    *enteros, fraccion = partes.groups()
    micros = int((fraccion or "")[:6].ljust(6, "0"))
    return datetime(*(int(parte) for parte in enteros), micros, tzinfo=timezone.utc)


def _con_zona(momento: object, nombre: str) -> datetime:
    if not isinstance(momento, datetime) or momento.tzinfo is None:
        raise ValueError(f"{nombre} debe ser un datetime con zona horaria")
    return momento


def _entero_positivo(valor: object, nombre: str) -> int:
    if not isinstance(valor, int) or isinstance(valor, bool) or valor <= 0:
        raise ValueError(f"{nombre} debe ser un entero positivo")
    return valor


def _como(condicion: bool, detalle: str) -> None:
    if not condicion:
        raise ValueError(f"snapshot malformado: {detalle}")


def _identificador(valor: object, nombre: str) -> str:
    if not isinstance(valor, str) or ID_RE.fullmatch(valor) is None:
        raise ValueError(f"{nombre} fuera de la allowlist [A-Za-z0-9._-]{{1,80}}: {valor!r}")
    if SECRET_RE.search(valor):
        raise ValueError(f"{nombre} parece un secreto y no puede entrar a la proyección")
    return valor


def _lista(snapshot: dict, clave: str) -> list:
    valor = snapshot.get(clave, [])
    _como(isinstance(valor, list), f"{clave} no es una lista")
    return valor


def derivar(
    snapshot: object,
    ahora: datetime,
    stale_after_ms: int,
    intervalo_ms: int,
    notados: Mapping[str, datetime],
    host_gateway: str | None = None,
) -> dict:
    """La proyección de una raíz (sistema-agentes.proyeccion.v1). Nunca ordena trabajo."""
    _con_zona(ahora, "ahora")
    _entero_positivo(stale_after_ms, "stale_after_ms")
    _entero_positivo(intervalo_ms, "intervalo_ms")
    for exception_id, momento in notados.items():
        _con_zona(momento, f"notados[{exception_id!r}]")

    def gateway() -> str:
        if host_gateway is None:
            raise ValueError("host_gateway es requerido: la fila necesita el host del gateway")
        return _identificador(host_gateway, "host_gateway")

    _como(isinstance(snapshot, dict), "la raíz no es un objeto")
    meta = snapshot.get("meta")
    _como(isinstance(meta, dict), "meta no es un objeto")
    plan = meta.get("plan")
    _como(isinstance(plan, dict), "meta.plan no es un objeto")
    revision = plan.get("revision")
    _como(
        isinstance(revision, int) and not isinstance(revision, bool) and revision >= 1,
        "meta.plan.revision no es un entero >= 1",
    )
    unidades = plan.get("units")
    _como(isinstance(unidades, list), "meta.plan.units no es una lista")
    epoch = meta.get("controlEpoch")
    _como(
        isinstance(epoch, int) and not isinstance(epoch, bool) and epoch >= 1,
        "meta.controlEpoch no es un entero >= 1",
    )
    root_id = _identificador(meta.get("rootId"), "meta.rootId")

    deadline = None
    autoridad = meta.get("authority")
    if autoridad is not None:
        _como(isinstance(autoridad, dict), "meta.authority no es un objeto")
        if autoridad.get("deadline") is not None:
            deadline = _instante(autoridad["deadline"], "meta.authority.deadline")

    por_unidad: dict[str, list[dict]] = {}
    for doc in _lista(snapshot, "units"):
        _como(isinstance(doc, dict), "units[] no es un objeto")
        if doc.get("planRevision") != revision:
            continue
        _como(
            isinstance(doc.get("attempt"), int) and not isinstance(doc["attempt"], bool),
            f"units[] (unitId {doc.get('unitId')!r}) attempt no es un entero",
        )
        _como(
            isinstance(doc.get("state"), str),
            f"units[] (unitId {doc.get('unitId')!r}) state no es un texto",
        )
        unit_id = doc.get("unitId")
        _como(isinstance(unit_id, str), "units[].unitId no es un texto")
        por_unidad.setdefault(unit_id, []).append(doc)

    pasados: dict[str, set[str]] = {}
    for evidencia in _lista(snapshot, "evidence"):
        _como(isinstance(evidencia, dict), "evidence[] no es un objeto")
        if evidencia.get("planRevision") != revision or evidencia.get("outcome") != "passed":
            continue
        unit_id, criterio = evidencia.get("unitId"), evidencia.get("criterionId")
        if isinstance(unit_id, str) and isinstance(criterio, str):
            pasados.setdefault(unit_id, set()).add(criterio)

    ultimo_incidente: dict[str, object] = {}
    for incidente in _lista(snapshot, "incidents"):
        _como(isinstance(incidente, dict), "incidents[] no es un objeto")
        registro = incidente.get("incident")
        _como(isinstance(registro, dict), "incidents[].incident no es un objeto")
        unit_id = incidente.get("unitId")
        if isinstance(unit_id, str):
            ultimo_incidente[unit_id] = registro.get("kind")

    abiertas: dict[str, list[tuple[str, int]]] = {}
    for excepcion in _lista(snapshot, "exceptions"):
        _como(isinstance(excepcion, dict), "exceptions[] no es un objeto")
        if excepcion.get("response") is not None:
            continue
        unit_id = excepcion.get("unitId")
        if not isinstance(unit_id, str):
            continue
        exception_id = excepcion.get("exceptionId")
        _como(isinstance(exception_id, str), "exceptions[].exceptionId no es un texto")
        renotice = excepcion.get("renoticeAfterMs")
        _como(
            isinstance(renotice, int) and not isinstance(renotice, bool),
            f"exceptions[] (exceptionId {exception_id!r}) renoticeAfterMs no es un entero",
        )
        abiertas.setdefault(unit_id, []).append((exception_id, renotice))

    sin_bound: dict[str, object] = {}
    for suelta in _lista(snapshot, "unbound"):
        _como(isinstance(suelta, dict), "unbound[] no es un objeto")
        unit_id = suelta.get("unitId")
        if isinstance(unit_id, str):
            sin_bound[unit_id] = suelta.get("state")

    filas = []
    validas = declarados = observados = aceptados = 0
    for indice, unidad in enumerate(unidades):
        _como(isinstance(unidad, dict), f"meta.plan.units[{indice}] no es un objeto")
        unit_id = _identificador(unidad.get("unitId"), f"meta.plan.units[{indice}].unitId")
        criterios = unidad.get("criteria")
        _como(isinstance(criterios, list), f"meta.plan.units[{indice}].criteria no es una lista")
        ids_de_criterio = set()
        for criterio in criterios:
            _como(
                isinstance(criterio, dict),
                f"meta.plan.units[{indice}].criteria[] no es un objeto",
            )
            identificador = criterio.get("criterionId")
            _como(
                isinstance(identificador, str),
                f"meta.plan.units[{indice}].criteria[].criterionId no es un texto",
            )
            ids_de_criterio.add(identificador)

        docs_de = por_unidad.get(unit_id, [])
        ultimo = None
        for doc in docs_de:
            if ultimo is None or doc["attempt"] >= ultimo["attempt"]:
                ultimo = doc

        if ultimo is not None:
            estado = ultimo["state"]
            asignacion = ultimo.get("assignment")
            _como(
                isinstance(asignacion, dict),
                f"units[] (unitId {unit_id}) assignment no es un objeto",
            )
            destino = asignacion.get("target")
            _como(
                isinstance(destino, dict),
                f"units[] (unitId {unit_id}) assignment.target no es un objeto",
            )
            prefijo = f"units[] (unitId {unit_id}) assignment.target"
            clase = destino.get("kind")
            if clase == "cli":
                executor = "cli:" + _identificador(destino.get("adapterId"), f"{prefijo}.adapterId")
                host = _identificador(destino.get("hostId"), f"{prefijo}.hostId")
            elif clase == "agent":
                executor = "agent:" + _identificador(destino.get("agentId"), f"{prefijo}.agentId")
                host = gateway()
            else:
                raise ValueError(f"snapshot malformado: {prefijo}.kind desconocido: {clase!r}")
        else:
            estado = sin_bound.get(unit_id, "pending")
            _como(isinstance(estado, str), f"unbound[] (unitId {unit_id}) state no es un texto")
            executor, host = "sin-asignar", gateway()

        proximo = None
        for exception_id, renotice in abiertas.get(unit_id, []):
            notado = notados.get(exception_id)
            candidato = notado + timedelta(milliseconds=renotice) if notado is not None else ahora
            if proximo is None or candidato < proximo:
                proximo = candidato
        if proximo is None:
            proximo = ahora + timedelta(milliseconds=intervalo_ms)
        if deadline is not None and deadline < proximo:
            proximo = deadline

        error = ultimo_incidente.get(unit_id)
        if error is not None:
            error = _identificador(error, f"incidents[] (unitId {unit_id}) incident.kind")

        filas.append(
            {
                "unitId": unit_id,
                "state": estado,
                "host": host,
                "executor": executor,
                "modelId": None,
                "nextCheckAt": _fecha(proximo),
                "error": error,
            }
        )

        if ids_de_criterio:
            validas += 1
            if any(doc["state"] in REPORTADOS for doc in docs_de):
                declarados += 1
            if ids_de_criterio <= pasados.get(unit_id, set()):
                observados += 1
            if ultimo is not None and ultimo["state"] == "accepted":
                aceptados += 1

    def porcentaje(numero: int) -> int | None:
        return None if validas == 0 else (100 * numero) // validas

    return {
        "schema": SCHEMA,
        "rootId": root_id,
        "planRevision": revision,
        "controlEpoch": epoch,
        "generatedAt": _fecha(ahora),
        "progress": {
            "declared": porcentaje(declarados),
            "observed": porcentaje(observados),
            "accepted": porcentaje(aceptados),
        },
        "units": filas,
        "freshness": {"staleAfterMs": stale_after_ms},
    }


def cargar_snapshot(ruta: str | Path) -> dict:
    try:
        return json.loads(Path(ruta).read_bytes())
    except ValueError as fallo:
        raise ValueError(f"snapshot {ruta} no es JSON válido: {fallo}") from fallo


def _cargar_notados(ruta: str | Path | None) -> dict[str, datetime]:
    if ruta is None:
        return {}
    try:
        crudo = json.loads(Path(ruta).read_bytes())
    except ValueError as fallo:
        raise ValueError(f"notados {ruta} no es JSON válido: {fallo}") from fallo
    if not isinstance(crudo, dict):
        raise ValueError(f"notados {ruta} no es un objeto {{exceptionId: fecha}}")
    return {clave: _instante(valor, f"notados[{clave!r}]") for clave, valor in crudo.items()}


def _cargar_checkpoint(ruta: Path) -> tuple[dict[str, datetime], datetime | None]:
    try:
        crudo = json.loads(ruta.read_bytes())
    except ValueError as fallo:
        raise ValueError(f"no es JSON válido: {fallo}") from fallo
    if not isinstance(crudo, dict) or crudo.get("schema") != CHECKPOINT_SCHEMA:
        raise ValueError(f"no es un checkpoint {CHECKPOINT_SCHEMA}")
    notados = crudo.get("notados")
    if not isinstance(notados, dict):
        raise ValueError("notados no es un objeto {exceptionId: fecha}")
    ultimo = crudo.get("ultimoConsolidado")
    return (
        {clave: _instante(valor, f"notados[{clave!r}]") for clave, valor in notados.items()},
        None if ultimo is None else _instante(ultimo, "ultimoConsolidado"),
    )


def _doc_checkpoint(ultimo: datetime | None, notados: Mapping[str, datetime]) -> dict:
    return {
        "schema": CHECKPOINT_SCHEMA,
        "ultimoConsolidado": None if ultimo is None else _fecha(ultimo),
        "notados": {clave: _fecha(notados[clave]) for clave in sorted(notados)},
    }


def _confirmacion(contesto: object) -> tuple[int | None, str | None]:
    """El messageId y la causa de un resultado de avisar; None si no confirmó."""
    if not isinstance(contesto, dict):
        contesto = {"enviado": False, "causa": "el emisor no contestó"}
    message_id = contesto.get("messageId")
    if isinstance(message_id, bool) or not isinstance(message_id, int) or message_id <= 0:
        message_id = None
    causa = contesto.get("causa")
    return message_id, causa if isinstance(causa, str) else None


def _recortar(lineas: list[str], tope: int = 3500) -> str:
    texto = "\n".join(lineas)
    if len(texto) <= tope:
        return texto
    resultado = [lineas[0]]
    largo = len(lineas[0])
    colocadas = 0
    for linea in lineas[1:]:
        if largo + len(linea) + len("… y 999 más") + 2 > tope:
            break
        resultado.append(linea)
        largo += len(linea) + 1
        colocadas += 1
    omitidas = len(lineas) - 1 - colocadas
    if omitidas:
        resultado.append(f"… y {omitidas} más")
    return "\n".join(resultado)


def _porcentaje(valor: int | None) -> str:
    return "?" if valor is None else f"{valor}%"


def _mensaje_consolidado(entradas: list[tuple[str, dict]]) -> str:
    lineas = [f"📊 *Raíces con pendientes* ({len(entradas)})"]
    for root_id, proyeccion_de_raiz in entradas[:12]:
        progreso = proyeccion_de_raiz["progress"]
        lineas.append("")
        lineas.append(
            f"*{root_id}* · declarado {_porcentaje(progreso['declared'])}"
            f" / observado {_porcentaje(progreso['observed'])}"
            f" / aceptado {_porcentaje(progreso['accepted'])}"
        )
        pendientes = [fila for fila in proyeccion_de_raiz["units"] if fila["state"] != "accepted"]
        for fila in pendientes[:8]:
            detalle = f"• {fila['unitId']} ({fila['state']}) · {fila['executor']}"
            if fila["error"] is not None:
                detalle += f" ⚠️ {fila['error']}"
            lineas.append(detalle)
        if len(pendientes) > 8:
            lineas.append(f"… y {len(pendientes) - 8} más")
    if len(entradas) > 12:
        lineas.append("")
        lineas.append(f"… y {len(entradas) - 12} más")
    return _recortar(lineas)


def _mensaje_excepciones(debidas: list[tuple[str, dict]]) -> str:
    lineas = [f"⚠️ *Excepciones sin respuesta* ({len(debidas)})"]
    for root_id, excepcion in debidas[:8]:
        unidad = excepcion["unitId"] or "(raíz)"
        desde = _instante(excepcion["raisedAt"], "raisedAt").strftime("%H:%MZ")
        lineas.append("")
        lineas.append(
            f"*{root_id}*/{unidad} · {excepcion['type']}"
            f" ({excepcion['exceptionId']}) · desde {desde}"
        )
        opciones = " | ".join(
            f"{opcion['optionId']}={opcion['text']}" for opcion in excepcion.get("options") or []
        )
        if opciones:
            lineas.append(f"responder: {opciones}.")
    if len(debidas) > 8:
        lineas.append("")
        lineas.append(f"… y {len(debidas) - 8} más")
    return _recortar(lineas)


def pasar(
    raices_dir: str | Path,
    *,
    stale_after_ms: int,
    ahora: datetime,
    gateway,
    intervalo_ms: int = 300_000,
    consolidado_ms: int = 1_800_000,
    host_gateway: str | None = None,
    avisar_fn=None,
) -> dict:
    """Una pasada del emisor (SUA-06, 4.2): proyecta, avisa y avanza el checkpoint.

    `gateway` es un callable (método, params); `avisar_fn` un callable (texto) -> dict.
    Sin `avisar_fn` la pasada es muda (la Mac): no envía y no avanza el checkpoint.
    """
    _con_zona(ahora, "ahora")
    _entero_positivo(stale_after_ms, "stale_after_ms")
    _entero_positivo(intervalo_ms, "intervalo_ms")
    _entero_positivo(consolidado_ms, "consolidado_ms")
    raices_dir = Path(raices_dir)
    avisos: dict = {"consolidado": None, "excepciones": None}

    def salida(raices: int, escritas: int, errores: list[str]) -> dict:
        return {
            "raices": raices,
            "escritas": escritas,
            "avisos": avisos,
            "errores": [error[:200] for error in errores],
        }

    if raices_dir.is_symlink():
        return salida(0, 0, [f"el directorio de raíces {raices_dir} es un symlink"])
    raices_dir.mkdir(parents=True, exist_ok=True)
    proyecciones_dir = raices_dir / "proyecciones"
    proyecciones_dir.mkdir(parents=True, exist_ok=True)

    candado = open(raices_dir / ".pasada.lock", "a")
    try:
        try:
            fcntl.flock(candado, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"saltada": True}

        errores: list[str] = []
        notados: dict[str, datetime] = {}
        ultimo_consolidado: datetime | None = None
        checkpoint_malo = False
        ruta_checkpoint = raices_dir / "checkpoint.json"
        if ruta_checkpoint.exists():
            try:
                notados, ultimo_consolidado = _cargar_checkpoint(ruta_checkpoint)
            except (ValueError, OSError) as fallo:
                checkpoint_malo = True
                errores.append(f"checkpoint {ruta_checkpoint}: {fallo}")
        if checkpoint_malo:
            notados, ultimo_consolidado = {}, None

        try:
            listado = gateway("managedTasks.root.list", {})
        except (OSError, RuntimeError, ValueError) as fallo:
            return salida(0, 0, errores + [f"managedTasks.root.list: {fallo}"])
        if not isinstance(listado, dict) or not isinstance(listado.get("roots"), list):
            return salida(0, 0, errores + ["managedTasks.root.list no devolvió {roots: [...]}"])

        vivos: list[str] = []
        for entrada in listado["roots"]:
            if not isinstance(entrada, dict):
                errores.append(f"managedTasks.root.list: entrada sin objeto: {entrada!r}")
                continue
            try:
                root_id = _identificador(entrada.get("rootId"), "rootId")
            except ValueError as fallo:
                errores.append(f"managedTasks.root.list: {fallo}")
                continue
            if root_id not in vivos:
                vivos.append(root_id)

        proyecciones: dict[str, dict] = {}
        debidas: list[tuple[str, dict]] = []
        escritas = 0
        for root_id in sorted(vivos):
            try:
                snapshot = gateway("managedTasks.root.read", {"rootId": root_id})
                if not isinstance(snapshot, dict):
                    raise ValueError("managedTasks.root.read no devolvió un snapshot")
                proyeccion_de_raiz = derivar(
                    snapshot,
                    ahora,
                    stale_after_ms,
                    intervalo_ms,
                    notados,
                    host_gateway=host_gateway,
                )
                spool.atomic_json(proyecciones_dir / f"{root_id}.json", proyeccion_de_raiz)
                proyecciones[root_id] = proyeccion_de_raiz
                for excepcion in _lista(snapshot, "exceptions"):
                    if not isinstance(excepcion, dict) or excepcion.get("response") is not None:
                        continue
                    if not isinstance(excepcion.get("exceptionId"), str):
                        continue
                    renotice = excepcion.get("renoticeAfterMs")
                    if not isinstance(renotice, int) or isinstance(renotice, bool):
                        continue
                    notado = notados.get(excepcion["exceptionId"])
                    if notado is None or ahora >= notado + timedelta(milliseconds=renotice):
                        debidas.append((root_id, excepcion))
            except (OSError, RuntimeError, ValueError) as fallo:
                errores.append(f"raíz {root_id}: {fallo}")
                continue
            escritas += 1

        vivos_set = set(vivos)
        for vieja in proyecciones_dir.glob("*.json"):
            try:
                stem = _identificador(vieja.stem, "proyección")
            except ValueError:
                continue
            if stem not in vivos_set:
                vieja.unlink()

        if debidas:
            debidas.sort(
                key=lambda par: (
                    par[0],
                    par[1].get("unitId") is None,
                    par[1].get("unitId") or "",
                    par[1]["exceptionId"],
                )
            )
        notados_inicial, ultimo_inicial = dict(notados), ultimo_consolidado

        puede_avisar = avisar_fn is not None and not checkpoint_malo
        if debidas and puede_avisar:
            texto = _mensaje_excepciones(debidas)
            contesto = avisar_fn(texto)
            message_id, causa = _confirmacion(contesto)
            avisos["excepciones"] = {
                "enviado": bool(isinstance(contesto, dict) and contesto.get("enviado")),
                "messageId": message_id,
                "causa": causa,
                "avisadas": [excepcion["exceptionId"] for _, excepcion in debidas],
            }
            if message_id is None:
                detalle = f": {causa}" if isinstance(causa, str) else ""
                errores.append(f"excepciones: el aviso no se confirmó{detalle}")
            else:
                for _, excepcion in debidas:
                    notados[excepcion["exceptionId"]] = ahora

        if proyecciones and not checkpoint_malo:
            con_pendientes = [
                (root_id, proyecciones[root_id])
                for root_id in sorted(proyecciones)
                if any(fila["state"] != "accepted" for fila in proyecciones[root_id]["units"])
            ]
            consolidado_debido = bool(con_pendientes) and (
                ultimo_consolidado is None
                or ahora >= ultimo_consolidado + timedelta(milliseconds=consolidado_ms)
            )
            if consolidado_debido and puede_avisar:
                texto = _mensaje_consolidado(
                    [(root_id, proyecciones[root_id]) for root_id in sorted(proyecciones)]
                )
                contesto = avisar_fn(texto)
                message_id, causa = _confirmacion(contesto)
                avisos["consolidado"] = {
                    "enviado": bool(isinstance(contesto, dict) and contesto.get("enviado")),
                    "messageId": message_id,
                    "causa": causa,
                }
                if message_id is None:
                    detalle = f": {causa}" if isinstance(causa, str) else ""
                    errores.append(f"consolidado: el aviso no se confirmó{detalle}")
                else:
                    ultimo_consolidado = ahora

        if not checkpoint_malo:
            documento = _doc_checkpoint(ultimo_consolidado, notados)
            if documento != _doc_checkpoint(ultimo_inicial, notados_inicial):
                spool.atomic_json(ruta_checkpoint, documento)
        return salida(len(vivos), escritas, errores)
    finally:
        candado.close()


def _gateway(openclaw_bin: str | Path, metodo: str, params: dict) -> object:
    """Una llamada `openclaw gateway call`; devuelve el primer JSON de la salida."""
    resultado = subprocess.run(
        [
            str(openclaw_bin),
            "gateway",
            "call",
            metodo,
            "--params",
            json.dumps(params, ensure_ascii=False, separators=(",", ":")),
            "--json",
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if resultado.returncode:
        detalle = " ".join((resultado.stderr or resultado.stdout).split())[:200]
        raise RuntimeError(f"gateway no disponible para {metodo}: {detalle}")
    lineas = resultado.stdout.splitlines(keepends=True)
    for indice, linea in enumerate(lineas):
        if not linea.lstrip().startswith("{"):
            continue
        try:
            respuesta, _ = json.JSONDecoder().raw_decode("".join(lineas[indice:]).lstrip())
        except json.JSONDecodeError:
            continue
        return respuesta
    try:
        return json.loads(resultado.stdout.strip())
    except ValueError:
        raise RuntimeError(f"respuesta JSON inválida del gateway para {metodo}") from None


def _binario(openclaw_bin: str | None) -> Path:
    binario = openclaw_bin or os.environ.get("OPENCLAW_BIN")
    return Path(binario) if binario else Path.home() / ".openclaw/bin/openclaw"


def construir_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="proyeccion.py", description=__doc__)
    subcomandos = parser.add_subparsers(dest="comando", required=True)

    def comunes(destino):
        destino.add_argument("--stale-after-ms", type=int, required=True)
        destino.add_argument("--intervalo-ms", type=int, required=True)
        destino.add_argument("--notados", type=Path, default=None)
        destino.add_argument("--host-gateway", default=socket.gethostname())

    derivar_cli = subcomandos.add_parser(
        "derivar", help="deriva la proyección de un snapshot en disco"
    )
    derivar_cli.add_argument("snapshot", type=Path)
    comunes(derivar_cli)

    leer_cli = subcomandos.add_parser("leer", help="lee la raíz del gateway y la deriva")
    leer_cli.add_argument("--root", required=True)
    leer_cli.add_argument("--openclaw-bin", default=None)
    comunes(leer_cli)

    listar_cli = subcomandos.add_parser("listar", help="lista las raíces del gateway")
    listar_cli.add_argument("--openclaw-bin", default=None)

    pasar_cli = subcomandos.add_parser("pasar", help="una pasada del emisor de raíces")
    pasar_cli.add_argument("--dir", type=Path, required=True)
    pasar_cli.add_argument("--stale-after-ms", type=int, required=True)
    pasar_cli.add_argument("--intervalo-ms", type=int, default=300_000)
    pasar_cli.add_argument("--consolidado-ms", type=int, default=1_800_000)
    pasar_cli.add_argument("--openclaw-bin", default=None)
    pasar_cli.add_argument("--politica", type=Path, default=POLITICA_POR_OMISION)
    pasar_cli.add_argument("--host-gateway", default=socket.gethostname())
    return parser


def main(argv: list[str] | None = None) -> int:
    args = construir_parser().parse_args(argv)
    try:
        if args.comando == "pasar":
            import avisar
            import modelos

            binario = _binario(args.openclaw_bin)
            politica = modelos.ProviderPolicy.load(Path(args.politica))
            resultado = pasar(
                args.dir,
                stale_after_ms=args.stale_after_ms,
                ahora=datetime.now(timezone.utc),
                gateway=lambda metodo, params: _gateway(binario, metodo, params),
                intervalo_ms=args.intervalo_ms,
                consolidado_ms=args.consolidado_ms,
                host_gateway=args.host_gateway,
                avisar_fn=lambda texto: avisar.avisar(texto, policy=politica, openclaw_bin=binario),
            )
            print(json.dumps(resultado, ensure_ascii=False))
            if resultado.get("saltada"):
                return 0
            return 1 if resultado.get("errores") else 0
        if args.comando == "listar":
            print(
                json.dumps(
                    _gateway(_binario(args.openclaw_bin), "managedTasks.root.list", {}),
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return 0
        if args.comando == "leer":
            snapshot = _gateway(
                _binario(args.openclaw_bin), "managedTasks.root.read", {"rootId": args.root}
            )
            if not isinstance(snapshot, dict):
                raise ValueError(
                    f"managedTasks.root.read no devolvió un snapshot para {args.root!r}"
                )
        else:
            snapshot = cargar_snapshot(args.snapshot)
        resultado = derivar(
            snapshot,
            datetime.now(timezone.utc),
            args.stale_after_ms,
            args.intervalo_ms,
            _cargar_notados(args.notados),
            host_gateway=args.host_gateway,
        )
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"proyeccion: {error}", file=sys.stderr)
        return 2
    print(json.dumps(resultado, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
