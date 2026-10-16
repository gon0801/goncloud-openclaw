#!/usr/bin/env python3
"""Altas y retiros de agentes (SUA-04, 4.5): descubrir contra la lista viva de la Mini y sondear
la ruta de encargo nativo a un agente, que hasta hoy ningún pedido usó.

`descubrir` es de solo lectura: por ssh como el publicador, o de un archivo con --agentes-json.
`sondear` manda a un agente una tarea gestionada como solicitante `main`, con instrucciones
exactas, y comprueba que llega a result-recorded con el marcador, sin entregas hacia David y
con memory/ igual. Lo corre el coordinador (M-18); aquí se prueba con una Mini falsa.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import contexto  # noqa: E402

SSH_OPCIONES = (
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=15",
    "-o",
    "ServerAliveInterval=15",
)
"""Las del publicador (publicar-contexto.py): sin cola de clave, con límite y latido."""
OPENCLAW = "~/.openclaw/bin/openclaw"
RAIZ = Path(__file__).resolve().parents[2]
PERFILES = Path("scripts/agent-work/contexto/perfiles.v1.json")
COVERAGE = Path("docs/evidence/agent-work/coverage.json")
TIMEOUT_SSH = 120


def descubrir(perfiles: dict, vivos: list, requesters=()) -> list:
    """Una fila por agente y su estado (4.5). Un solicitante no es trabajador ni alta."""
    con_perfil: dict[str, list] = {}
    for perfil in perfiles.get("profiles", ()):
        for ruta in perfil.get("routes", ()):
            if ruta.get("agentId"):
                con_perfil.setdefault(ruta["agentId"], []).append(perfil["id"])
    sin_perfil = {
        a["agentId"] for a in perfiles.get("agents", ()) if a.get("status") == "sin-perfil"
    }
    vivos_ids = {a["id"] for a in vivos}
    filas = []
    for agente_id in sorted(vivos_ids):
        # El salto de solicitante vale solo para quien no es trabajador: requesters trae
        # también a ingenieria, reviewer y los demás con perfil, y esos se clasifican
        # como cualquiera (B1). Hoy el único solicitante que no es trabajador es main.
        if agente_id in requesters and agente_id not in con_perfil and agente_id not in sin_perfil:
            continue
        if agente_id in con_perfil:
            filas.append(
                {"agentId": agente_id, "estado": "con-perfil", "perfiles": con_perfil[agente_id]}
            )
        elif agente_id in sin_perfil:
            filas.append({"agentId": agente_id, "estado": "sin-perfil"})
        else:
            filas.append({"agentId": agente_id, "estado": "alta-sin-registrar"})
    for agente_id in sorted((set(con_perfil) | sin_perfil) - vivos_ids):
        filas.append({"agentId": agente_id, "estado": "retirado"})
    for perfil in perfiles.get("profiles", ()):
        for ruta in perfil.get("routes", ()):
            if ruta.get("agentId") and ruta["agentId"] not in vivos_ids:
                fila = {
                    "perfil": perfil["id"],
                    "agentId": ruta["agentId"],
                    "estado": "perfil-incompleto",
                }
                if fila not in filas:
                    filas.append(fila)
    return filas


def _ssh(mini: str):
    def correr(argv, entrada=None, timeout=None):
        tope = timeout or TIMEOUT_SSH
        try:
            hecho = subprocess.run(
                ["ssh", *SSH_OPCIONES, mini, *argv],
                input=entrada,
                capture_output=True,
                text=True,
                timeout=tope,
            )
        except subprocess.TimeoutExpired:
            return 1, "", f"ssh no contestó en {tope}s"
        return hecho.returncode, hecho.stdout, hecho.stderr

    return correr


def lista_viva(mini: str, correr) -> list:
    rc, out, err = correr([OPENCLAW, "agents", "list", "--json"])
    if rc != 0:
        raise ValueError(f"openclaw agents list falló: {err.strip()}")
    agentes = json.loads(out)
    if not isinstance(agentes, list) or not all(
        isinstance(a, dict) and isinstance(a.get("id"), str) and isinstance(a.get("workspace"), str)
        for a in agentes
    ):
        raise ValueError("la lista de agentes no tiene la forma esperada")
    return agentes


AYUDANTE = r"""
import json, sqlite3, sys, os
req = json.loads(sys.argv[1])
base = os.path.expanduser("~/.openclaw/state/openclaw.sqlite")
db = sqlite3.connect("file:" + base + "?mode=ro", uri=True)
db.row_factory = sqlite3.Row
tareas = []
for row in db.execute("select task_id, assignment_json, result_json"
                      " from managed_tasks order by created_at desc"):
    try:
        asignacion = json.loads(row["assignment_json"] or "{}")
    except Exception:
        asignacion = {}
    objetivo = asignacion.get("target") or {}
    resultado = row["result_json"]
    texto = None
    if resultado:
        try:
            parsed = json.loads(resultado)
            texto = parsed if isinstance(parsed, str) else json.dumps(parsed, ensure_ascii=False)
        except Exception:
            texto = resultado
    tareas.append({"taskId": row["task_id"], "kind": objetivo.get("kind"),
                   "agentId": objetivo.get("agentId"),
                   "estado": "result-recorded" if resultado else "registered",
                   "resultado": texto})
agente = req["agentId"]
try:
    adb = sqlite3.connect("file:" + os.path.expanduser(
        f"~/.openclaw/agents/{agente}/agent/openclaw-agent.sqlite") + "?mode=ro", uri=True)
    sesiones_agente = [r[0] for r in adb.execute("select session_key from session_windows")]
    reportada = req.get("tareaReportada")
    # Solo la hija de ESTA tarea (F1): una sesión gestionada ajena no es de la sonda.
    hijas = [k for k in sesiones_agente if reportada and reportada in k]
    previas = set(req.get("sesionesPrevias") or [])
    spawn = False
    for clave in [k for k in sesiones_agente if k not in previas]:
        if reportada and reportada in clave:
            continue
        # El diagnóstico de spawn: una sesión nueva cuyo transcript trae el marcador.
        try:
            filas = adb.execute(
                "select count(*) from transcript_events where session_id in "
                "(select session_id from session_windows where session_key = ?) "
                "and event_json like ?", (clave, "%" + req["marcador"] + "%")).fetchone()[0]
        except Exception:
            filas = 0
        if filas:
            spawn = True
except Exception:
    sesiones_agente, hijas, spawn = [], [], False

def entregas_en(ruta, clausula, parametro):
    # Las entregas viven en la base de cada agente (F7), no en la de estado. Sin la
    # tabla, salir con error (SystemExit atraviesa los except Exception): un 0 en
    # silencio diría "sin entregas hacia David".
    ruta = os.path.expanduser(ruta)
    try:
        edb = sqlite3.connect("file:" + ruta + "?mode=ro", uri=True)
        columnas = [c[1] for c in edb.execute("pragma table_info(conversation_deliveries)")]
        if "source_session_key" not in columnas:
            sys.exit("sin conversation_deliveries.source_session_key en " + ruta)
        return edb.execute("select count(*) from conversation_deliveries where " + clausula,
                           parametro).fetchone()[0]
    except Exception:
        sys.exit("no se pudo leer conversation_deliveries de " + ruta)

dueno = req["sesionMain"].split(":")[1]
entregas = entregas_en(f"~/.openclaw/agents/{dueno}/agent/openclaw-agent.sqlite",
                       "source_session_key like ?", (req["sesionMain"] + "%",))
for hija in hijas:
    entregas += entregas_en(f"~/.openclaw/agents/{agente}/agent/openclaw-agent.sqlite",
                            "source_session_key = ?", (hija,))
print(json.dumps({"tareas": tareas, "entregas": entregas, "sesionesHijas": hijas,
                  "sesionesAgente": sesiones_agente, "spawn": spawn}))
"""


def _foto_memoria(correr, workspace: str) -> str:
    orden = (
        f"cd {shlex.quote(workspace)} && find memory -type f -print0 | sort -z | "
        "xargs -0 shasum -a 256"
    )
    # El orden entero como UN argumento citado (F6): el ssh une el argv con espacios y
    # el shell remoto lo vuelve a partir, así que suelto se machacea.
    rc, out, err = correr(["sh", "-c", shlex.quote(orden)])
    if rc != 0:
        raise ValueError(f"la foto de memory/ falló: {err.strip()}")
    return out


def _estado_remoto(
    correr,
    sesion_main: str,
    agent_id: str,
    marcador: str,
    sesiones_previas=(),
    tarea_reportada=None,
) -> dict:
    pedido = {
        "sesionMain": sesion_main,
        "agentId": agent_id,
        "marcador": marcador,
        "sesionesPrevias": list(sesiones_previas),
        "tareaReportada": tarea_reportada,
    }
    # Como _traer (extraer-nativo.py): el código va por stdin y los datos como un
    # argumento ya citado (F6), porque el argv llega unido con espacios al shell remoto.
    rc, out, err = correr(["python3", "-", shlex.quote(json.dumps(pedido))], entrada=AYUDANTE)
    if rc != 0:
        raise ValueError(f"la lectura de la tarea falló: {err.strip()}")
    return json.loads(out)


UUID_EN_TEXTO = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)


def _task_id_en_texto(salida: str):
    """El taskId en el texto del turno de main (4.5b): un uuid junto a "taskId" o a
    managed_tasks_submit; si no, el primer uuid del texto."""
    for marca in ("taskId", "managed_tasks_submit"):
        for encontrado in re.finditer(marca, salida):
            uuid = UUID_EN_TEXTO.search(salida, encontrado.start())
            if uuid and uuid.start() - encontrado.start() < 200:
                return uuid.group(0)
    primero = UUID_EN_TEXTO.search(salida)
    return primero.group(0) if primero else None


def _task_id_reportado(salida: str):
    """El taskId que main reporta en su turno, si viene: la tarea de la sonda es esa (F1)."""
    try:
        doc = json.loads(salida)
    except ValueError:
        return None
    pila = [doc]
    while pila:
        actual = pila.pop()
        if isinstance(actual, dict):
            if isinstance(actual.get("taskId"), str):
                return actual["taskId"]
            pila.extend(actual.values())
        elif isinstance(actual, list):
            pila.extend(actual)
    return None


MENSAJE = (
    "Sonda de SUA-04 (no avises a David, no escribas a Telegram, no uses sessions_spawn).\n"
    "\n"
    "1. Escribe el brief con brief.py {perfil} --agente {agente} "
    "--contrato ready.v1 en la Mini (con --perfiles ~/.local/share/agent-work/perfiles.v1.json): "
    "pide contestar exactamente {marcador} y nada más, y reportarlo con managed_tasks_report "
    "usando el resultado que arma reporte.py, como dice la sección de protocolo del brief.\n"
    "2. Pega los tres fragmentos que contesta brief.py (instructionRef, target e inputRevision) "
    "en managed_tasks_submit, con resultContract ready.v1.\n"
    "3. Admite la tarea con managed_tasks_admit y dime su taskId.\n"
)


def sondear(
    agent_id: str,
    *,
    mini: str,
    correr,
    perfiles: dict,
    marca: str,
    dormir=time.sleep,
    reloj=time.monotonic,
    tope: float = 300.0,
) -> dict:
    """La sonda de ida y vuelta de 4.5. Todo lo que escribe en la Mini se borra al final."""
    sesion_main = f"agent:main:sua04-sonda-{agent_id}-{marca}"
    marcador = f"SONDA-{marca}"
    mensaje_remoto = f"/tmp/sua04-sonda-{agent_id}-{marca}.txt"
    fila = {
        "ok": False,
        "agentId": agent_id,
        "taskId": None,
        "estado": None,
        "marcador": False,
        "entregas": None,
        "memoriaIgual": None,
        "causa": None,
    }
    hijas: list = []
    turno_cortado = False
    try:
        vivos = {a["id"]: a for a in lista_viva(mini, correr)}
        if agent_id not in vivos:
            fila["causa"] = f"{agent_id} no está en la lista viva de la Mini"
            return fila
        perfil = next(
            (
                p["id"]
                for p in perfiles.get("profiles", ())
                for r in p.get("routes", ())
                if r.get("agentId") == agent_id
            ),
            None,
        )
        antes = _foto_memoria(correr, vivos[agent_id]["workspace"])
        estado0 = _estado_remoto(correr, sesion_main, agent_id, marcador)
        previas = {t["taskId"] for t in estado0["tareas"]}
        sesiones_previas = estado0.get("sesionesAgente") or []
        texto = MENSAJE.format(
            perfil=f"--perfil {perfil}" if perfil else "(sin --perfil)",
            marcador=marcador,
            agente=agent_id,
        )
        rc, _, err = correr(["sh", "-c", shlex.quote("cat > " + mensaje_remoto)], entrada=texto)
        if rc != 0:
            fila["causa"] = f"no se pudo escribir el mensaje en la Mini: {err.strip()}"
            return fila
        # El turno tiene su propio tope, mayor que el de la espera (F5): un turno de main
        # tarda lo que tarde en mandar la tarea, y cortarlo no es un fallo de la sonda.
        rc, out, err = correr(
            [
                OPENCLAW,
                "agent",
                "--agent",
                "main",
                "--session-key",
                sesion_main,
                "--message-file",
                mensaje_remoto,
                "--json",
            ],
            timeout=tope + 600,
        )
        if rc != 0 and "no contestó" in err:
            turno_cortado = True
            fila["causa"] = f"turno cortado, sesión conservada: {sesion_main}"
            return fila
        if rc != 0:
            fila["causa"] = f"el turno a main falló: {err.strip()}"
            return fila
        reportada = _task_id_en_texto(out) or _task_id_reportado(out)
        inicio = reloj()
        estado = _estado_remoto(
            correr, sesion_main, agent_id, marcador, sesiones_previas, reportada
        )
        while True:
            # Solo la hija de esta tarea (F1): el ayudante puede traer sesiones ajenas.
            reportado_id = reportada or fila["taskId"]
            hijas = [
                k for k in (estado.get("sesionesHijas") or []) if reportado_id and reportado_id in k
            ] or hijas
            nuevas = [
                t
                for t in estado["tareas"]
                if t["taskId"] not in previas
                and t.get("kind") == "agent"
                and t.get("agentId") == agent_id
            ]
            # La tarea de la sonda es la que main reportó o la nueva cuyo resultado trae
            # el marcador (F1): una tarea real concurrente al mismo agente no es suya.
            tarea = None
            if reportada:
                tarea = next((t for t in nuevas if t["taskId"] == reportada), None)
            else:
                tarea = next(
                    (
                        t
                        for t in nuevas
                        if t["estado"] == "result-recorded"
                        and marcador in (t.get("resultado") or "")
                    ),
                    None,
                )
            if tarea is not None:
                fila["taskId"], fila["estado"] = tarea["taskId"], tarea["estado"]
                # La hija de la tarea reconocida por su marcador también es de la sonda
                # (F8): el ayudante deja sesionesHijas vacía sin taskId del pedido, así
                # que el filtro se repite sobre la lista completa con el id ya conocido.
                reportado_id = reportada or fila["taskId"]
                hijas = [
                    k
                    for k in (estado.get("sesionesAgente") or [])
                    if reportado_id and reportado_id in k
                ] or hijas
                if tarea["estado"] == "result-recorded":
                    fila["marcador"] = marcador in (tarea.get("resultado") or "")
                    break
            if reloj() - inicio >= tope:
                if not nuevas and estado.get("spawn"):
                    fila["causa"] = "main usó sessions_spawn en vez de la tarea gestionada"
                elif tarea is None and not reportada:
                    fila["causa"] = (
                        "la tarea no llegó: main no mandó una tarea gestionada a este agente"
                    )
                else:
                    fila["causa"] = (
                        f"la tarea llegó ({fila['taskId'] or reportada}) "
                        "pero el agente no reportó resultado"
                    )
                break
            dormir(5)
            # El taskId ya reconocido también viaja al ayudante (F8): filtra hijas en el
            # origen aunque main nunca haya reportado el suyo.
            estado = _estado_remoto(
                correr,
                sesion_main,
                agent_id,
                marcador,
                sesiones_previas,
                reportada or fila["taskId"],
            )
        fila["entregas"] = estado["entregas"]
        despues = _foto_memoria(correr, vivos[agent_id]["workspace"])
        fila["memoriaIgual"] = antes == despues
        if fila["causa"] is None:
            if not fila["marcador"]:
                fila["causa"] = "el resultado no trae el marcador"
            elif fila["entregas"]:
                fila["causa"] = "hubo entregas hacia David"
            elif not fila["memoriaIgual"]:
                fila["causa"] = "memory/ cambió durante la sonda"
        fila["ok"] = fila["causa"] is None
        return fila
    finally:
        correr(["rm", "-f", mensaje_remoto])
        # Solo lo suyo (F1): la sesión de main de la sonda y la hija de su tarea. Con el
        # turno cortado, la sesión de main se conserva (F5).
        if not turno_cortado:
            correr([OPENCLAW, "sessions", "delete", sesion_main, "--yes"])
        for hija in hijas:
            correr([OPENCLAW, "sessions", "delete", hija, "--yes"])


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    comandos = parser.add_subparsers(dest="comando", required=True)
    d = comandos.add_parser("descubrir", help="la lista viva contra lo que G conoce, solo lectura")
    d.add_argument("--mini", help="user@host de la Mini (ssh); sin él se usa --agentes-json")
    d.add_argument("--agentes-json", type=Path, help="una lista de agentes ya leída, para pruebas")
    s = comandos.add_parser(
        "sondear", help="la sonda de ida y vuelta a un agente (la corre el coordinador)"
    )
    s.add_argument("agent_id")
    s.add_argument("--mini", required=True, help="user@host de la Mini")
    s.add_argument("--tope", type=float, default=300.0)
    args = parser.parse_args(argv)
    try:
        return _main(args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"ok": False, "causa": str(error)}, ensure_ascii=False))
        return 3


def _main(args) -> int:
    perfiles = contexto.leer_json(RAIZ / PERFILES)
    if args.comando == "descubrir":
        if args.agentes_json is not None:
            vivos = contexto.leer_json(args.agentes_json)
            if not isinstance(vivos, list) or not all(
                isinstance(a, dict)
                and isinstance(a.get("id"), str)
                and isinstance(a.get("workspace"), str)
                for a in vivos
            ):
                raise ValueError("la lista de agentes no tiene la forma esperada")
        elif args.mini:
            vivos = lista_viva(args.mini, _ssh(args.mini))
        else:
            print(
                json.dumps(
                    {"ok": False, "causa": "pasa --mini o --agentes-json"}, ensure_ascii=False
                )
            )
            return 3
        coverage = contexto.leer_json(RAIZ / COVERAGE)
        salida = {"ok": True, "agentes": descubrir(perfiles, vivos, coverage.get("requesters", ()))}
        print(json.dumps(salida, ensure_ascii=False))
        return 0
    marca = str(int(time.time()))
    fila = sondear(
        args.agent_id,
        mini=args.mini,
        correr=_ssh(args.mini),
        perfiles=perfiles,
        marca=marca,
        tope=args.tope,
    )
    print(json.dumps(fila, ensure_ascii=False))
    return 0 if fila["ok"] else 3


if __name__ == "__main__":
    sys.exit(main())
