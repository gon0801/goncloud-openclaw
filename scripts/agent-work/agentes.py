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
from pathlib import Path
import shlex
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import contexto  # noqa: E402

SSH_OPCIONES = (
    "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
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
    sin_perfil = {a["agentId"] for a in perfiles.get("agents", ()) if a.get("status") == "sin-perfil"}
    vivos_ids = {a["id"] for a in vivos}
    filas = []
    for agente_id in sorted(vivos_ids):
        if agente_id in requesters:
            continue
        if agente_id in con_perfil:
            filas.append({"agentId": agente_id, "estado": "con-perfil", "perfiles": con_perfil[agente_id]})
        elif agente_id in sin_perfil:
            filas.append({"agentId": agente_id, "estado": "sin-perfil"})
        else:
            filas.append({"agentId": agente_id, "estado": "alta-sin-registrar"})
    for agente_id in sorted((set(con_perfil) | sin_perfil) - vivos_ids):
        if agente_id not in requesters:
            filas.append({"agentId": agente_id, "estado": "retirado"})
    for perfil in perfiles.get("profiles", ()):
        for ruta in perfil.get("routes", ()):
            if ruta.get("agentId") and ruta["agentId"] not in vivos_ids:
                fila = {"perfil": perfil["id"], "agentId": ruta["agentId"], "estado": "perfil-incompleto"}
                if fila not in filas:
                    filas.append(fila)
    return filas


def _ssh(mini: str):
    def correr(argv, entrada=None):
        try:
            hecho = subprocess.run(["ssh", *SSH_OPCIONES, mini, *argv], input=entrada,
                                   capture_output=True, text=True, timeout=TIMEOUT_SSH)
        except subprocess.TimeoutExpired:
            return 1, "", f"ssh no contestó en {TIMEOUT_SSH}s"
        return hecho.returncode, hecho.stdout, hecho.stderr
    return correr


def _local():
    def correr(argv, entrada=None):
        orden = [str(Path(a).expanduser()) if isinstance(a, str) and a.startswith("~/") else a for a in argv]
        try:
            hecho = subprocess.run(orden, input=entrada, capture_output=True, text=True, timeout=TIMEOUT_SSH)
        except subprocess.TimeoutExpired:
            return 1, "", f"el comando local no contestó en {TIMEOUT_SSH}s"
        return hecho.returncode, hecho.stdout, hecho.stderr
    return correr


def lista_viva(mini: str, correr) -> list:
    rc, out, err = correr([OPENCLAW, "agents", "list", "--json"])
    if rc != 0:
        raise ValueError(f"openclaw agents list falló: {err.strip()}")
    agentes = json.loads(out)
    if not isinstance(agentes, list) or not all(
            isinstance(a, dict) and isinstance(a.get("id"), str) and isinstance(a.get("workspace"), str)
            for a in agentes):
        raise ValueError("la lista de agentes no tiene la forma esperada")
    return agentes


AYUDANTE = r"""
import json, sqlite3, sys, os
req = json.load(sys.stdin)
base = os.path.expanduser("~/.openclaw/state/openclaw.sqlite")
db = sqlite3.connect("file:" + base + "?mode=ro", uri=True)
db.row_factory = sqlite3.Row
tareas = []
for row in db.execute("select task_id, assignment_json, result_json from managed_tasks order by created_at desc"):
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
cols = [r[1] for r in db.execute("pragma table_info(conversation_deliveries)")]
entregas = 0
for col in [c for c in cols if c.endswith("session_key")]:
    entregas += db.execute(
        f"select count(*) from conversation_deliveries where {col} = ?", (req["sesionMain"],)).fetchone()[0]
hijas = []
try:
    adb = sqlite3.connect("file:" + os.path.expanduser(
        f"~/.openclaw/agents/{req['agentId']}/agent/openclaw-agent.sqlite") + "?mode=ro", uri=True)
    hijas = [r[0] for r in adb.execute(
        "select session_key from session_windows where session_key like ?",
        (f"agent:{req['agentId']}:managed%",))]
    spawn = adb.execute("select count(*) from session_windows where session_key like ? and session_key not like ?",
                        (f"agent:{req['agentId']}%", "agent:%:managed%")).fetchone()[0] > 0
except Exception:
    spawn = False
print(json.dumps({"tareas": tareas, "entregas": entregas, "sesionesHijas": hijas, "spawn": spawn}))
"""


def _foto_memoria(correr, workspace: str) -> str:
    orden = (f"cd {shlex.quote(workspace)} && find memory -type f -print0 | sort -z | "
             "xargs -0 shasum -a 256")
    rc, out, err = correr(["sh", "-c", orden])
    if rc != 0:
        raise ValueError(f"la foto de memory/ falló: {err.strip()}")
    return out


def _estado_remoto(correr, sesion_main: str, agent_id: str) -> dict:
    rc, out, err = correr(["python3", "-c", AYUDANTE],
                          entrada=json.dumps({"sesionMain": sesion_main, "agentId": agent_id}))
    if rc != 0:
        raise ValueError(f"la lectura de la tarea falló: {err.strip()}")
    return json.loads(out)


MENSAJE = """Sonda de SUA-04 (no avises a David, no escribas a Telegram, no uses sessions_spawn).

1. Escribe el brief con brief.py {perfil} en la Mini: pide contestar exactamente {marcador} y nada más.
2. Manda UNA tarea gestionada con managed_tasks_submit, target {{"kind": "agent", "agentId": "{agente}"}}, resultContract ready.v1.
3. Admítela con managed_tasks_admit.
"""


def sondear(agent_id: str, *, mini: str, correr, perfiles: dict, marca: str,
            dormir=time.sleep, reloj=time.monotonic, tope: float = 300.0) -> dict:
    """La sonda de ida y vuelta de 4.5. Todo lo que escribe en la Mini se borra al final."""
    sesion_main = f"agent:main:sua04-sonda-{agent_id}-{marca}"
    marcador = f"SONDA-{marca}"
    mensaje_remoto = f"/tmp/sua04-sonda-{agent_id}-{marca}.txt"
    fila = {"ok": False, "agentId": agent_id, "taskId": None, "estado": None,
            "marcador": False, "entregas": None, "memoriaIgual": None, "causa": None}
    hijas: list = []
    try:
        vivos = {a["id"]: a for a in lista_viva(mini, correr)}
        if agent_id not in vivos:
            fila["causa"] = f"{agent_id} no está en la lista viva de la Mini"
            return fila
        perfil = next((p["id"] for p in perfiles.get("profiles", ())
                       for r in p.get("routes", ()) if r.get("agentId") == agent_id), None)
        antes = _foto_memoria(correr, vivos[agent_id]["workspace"])
        previas = {t["taskId"] for t in _estado_remoto(correr, sesion_main, agent_id)["tareas"]}
        texto = MENSAJE.format(perfil=f"--perfil {perfil}" if perfil else "(sin --perfil)",
                               marcador=marcador, agente=agent_id)
        rc, _, err = correr(["sh", "-c", f"cat > {shlex.quote(mensaje_remoto)}"], entrada=texto)
        if rc != 0:
            fila["causa"] = f"no se pudo escribir el mensaje en la Mini: {err.strip()}"
            return fila
        rc, _, err = correr([OPENCLAW, "agent", "--agent", "main", "--session-key", sesion_main,
                             "--message-file", mensaje_remoto, "--json"])
        if rc != 0:
            fila["causa"] = f"el turno a main falló: {err.strip()}"
            return fila
        inicio = reloj()
        estado = _estado_remoto(correr, sesion_main, agent_id)
        while True:
            hijas = estado.get("sesionesHijas") or hijas
            nuevas = [t for t in estado["tareas"] if t["taskId"] not in previas
                      and t.get("kind") == "agent" and t.get("agentId") == agent_id]
            if nuevas:
                tarea = nuevas[0]
                fila["taskId"], fila["estado"] = tarea["taskId"], tarea["estado"]
                if tarea["estado"] == "result-recorded":
                    fila["marcador"] = marcador in (tarea.get("resultado") or "")
                    break
            if reloj() - inicio >= tope:
                if not nuevas and estado.get("spawn"):
                    fila["causa"] = "main usó sessions_spawn en vez de la tarea gestionada"
                elif not nuevas:
                    fila["causa"] = "la tarea no llegó: main no mandó una tarea gestionada a este agente"
                else:
                    fila["causa"] = "la tarea no llegó a result-recorded en el tope"
                break
            dormir(5)
            estado = _estado_remoto(correr, sesion_main, agent_id)
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
        correr([OPENCLAW, "sessions", "delete", sesion_main, "--yes"])
        for hija in hijas:
            correr([OPENCLAW, "sessions", "delete", hija, "--yes"])


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    comandos = parser.add_subparsers(dest="comando", required=True)
    d = comandos.add_parser("descubrir", help="la lista viva contra lo que G conoce, solo lectura")
    d.add_argument("--mini", help="user@host de la Mini (ssh); sin él se usa --agentes-json")
    d.add_argument("--agentes-json", type=Path, help="una lista de agentes ya leída, para pruebas")
    s = comandos.add_parser("sondear", help="la sonda de ida y vuelta a un agente (la corre el coordinador)")
    s.add_argument("agent_id")
    s.add_argument("--mini", required=True, help="user@host de la Mini")
    s.add_argument("--tope", type=float, default=300.0)
    args = parser.parse_args(argv)
    perfiles = contexto.leer_json(RAIZ / PERFILES)
    if args.comando == "descubrir":
        if args.agentes_json is not None:
            vivos = contexto.leer_json(args.agentes_json)
        elif args.mini:
            vivos = lista_viva(args.mini, _ssh(args.mini))
        else:
            print(json.dumps({"ok": False, "causa": "pasa --mini o --agentes-json"}, ensure_ascii=False))
            return 3
        coverage = contexto.leer_json(RAIZ / COVERAGE)
        print(json.dumps({"ok": True, "agentes": descubrir(perfiles, vivos, coverage.get("requesters", ()))},
                         ensure_ascii=False))
        return 0
    marca = str(int(time.time()))
    fila = sondear(args.agent_id, mini=args.mini, correr=_ssh(args.mini), perfiles=perfiles,
                   marca=marca, tope=args.tope)
    print(json.dumps(fila, ensure_ascii=False))
    return 0 if fila["ok"] else 3


if __name__ == "__main__":
    sys.exit(main())
