#!/usr/bin/env python3
"""El extractor de eventos nativos de OpenClaw desde la Mini (SUA-03, sección 5, M-15).

Corre en la Mac. Por ssh corre en la Mini un python3 de solo lectura que llega por stdin
(`python3 -`): abre la base del agente con `file:...?mode=ro` y imprime una línea JSON por
fila de `transcript_events` de cada sesión pedida (todas sus ventanas), con el evento en
`event_json` o, comprimido, en `event_zstd` (base64). El zstd se decodifica acá: la Mini
tiene Python 3.9 y no trae `compression.zstd`. En `--salida` escribe filas
`{"session_key","session_id","seq","created_at","event"}`, las que `conducta.py --forma
openclaw` lee. Nunca escribe en la Mini: solo SELECT.

Con `--con-hijos` busca en los textos de los toolResult los `childSessionKey` que dejaron
los `sessions_spawn` y pide esas sesiones en otra llamada ssh, hasta que no aparecen nuevas.

    extraer-nativo.py --mini gon@mini --agente ingenieria \\
        --sesion agent:ingenieria:sua03-m15 --con-hijos --salida eventos.jsonl
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

SSH_OPCIONES = ("-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15")
TIMEOUT_SSH = 300
BASE_POR_DEFECTO = "~/.openclaw/agents/{agente}/agent/openclaw-agent.sqlite"
HIJO = re.compile(r'"childSessionKey"\s*:\s*"([^"]+)"')
# El SQL de la mitad Mini, en constantes por si hay que ajustar una línea contra el esquema
# real de la Mini (desde la Mac no hay forma de probarlo contra ella).
SQL_SESIONES = "SELECT session_id FROM session_windows WHERE session_key = ? ORDER BY session_id"
SQL_EVENTOS = (
    "SELECT seq, created_at, event_json, event_zstd FROM transcript_events "
    "WHERE session_id = ? ORDER BY seq"
)

PLANTILLA_REMOTA = '''"""La mitad Mini: solo lectura y Python 3.9 (sin match ni walrus), biblioteca
estándar solamente. Imprime una línea JSON por fila; el zstd se decodifica en la Mac."""
import argparse
import base64
import json
import os
import sqlite3

parser = argparse.ArgumentParser()
parser.add_argument("--db", required=True)
parser.add_argument("--sesiones", required=True)
args = parser.parse_args()

SQL_SESIONES = __SQL_SESIONES__
SQL_EVENTOS = __SQL_EVENTOS__

# mode=ro: esta mitad jamás escribe en la base.
conexion = sqlite3.connect("file:" + os.path.expanduser(args.db) + "?mode=ro", uri=True)
try:
    for clave in [c for c in args.sesiones.split(",") if c]:
        for (session_id,) in conexion.execute(SQL_SESIONES, (clave,)):
            for seq, created_at, event_json, event_zstd in conexion.execute(
                SQL_EVENTOS, (session_id,)
            ):
                print(
                    json.dumps(
                        {
                            "session_key": clave,
                            "session_id": session_id,
                            "seq": seq,
                            "created_at": created_at,
                            "event_json": event_json,
                            "event_zstd": (
                                base64.b64encode(event_zstd).decode("ascii")
                                if event_zstd is not None
                                else None
                            ),
                        }
                    )
                )
finally:
    conexion.close()
'''

CODIGO_REMOTO = PLANTILLA_REMOTA.replace("__SQL_SESIONES__", repr(SQL_SESIONES)).replace(
    "__SQL_EVENTOS__", repr(SQL_EVENTOS)
)


def _decodificador() -> str | None:
    """Cómo descomprimir zstd en esta Mac: "modulo" (`compression.zstd`, Python 3.14+),
    "binario" (el `zstd` del PATH) o None si no hay ninguno."""
    try:
        from compression import zstd  # noqa: F401
    except ImportError:
        return "binario" if shutil.which("zstd") is not None else None
    return "modulo"


def _descomprimir(datos: bytes, tipo: str) -> bytes:
    if tipo == "modulo":
        from compression import zstd

        try:
            return zstd.decompress(datos)
        except zstd.ZstdError as error:
            # ZstdError no es ValueError (N2): sin este puente un evento corrupto sale
            # como traceback en vez de la línea JSON de siempre.
            raise ValueError(f"event_zstd corrupto: {error}") from error
    resultado = subprocess.run(["zstd", "-d"], input=datos, capture_output=True, timeout=60)
    if resultado.returncode != 0:
        raise ValueError(f"zstd -d salió {resultado.returncode}: {resultado.stderr!r}")
    return resultado.stdout


def _traer(mini: str, base: str, sesiones: list[str], tipo: str) -> list[dict]:
    """Una llamada ssh: las filas crudas de esas sesiones, con el evento ya decodificado."""
    comando = [
        "ssh",
        *SSH_OPCIONES,
        mini,
        "python3",
        "-",
        "--db",
        shlex.quote(base),
        "--sesiones",
        shlex.quote(",".join(sesiones)),
    ]
    resultado = subprocess.run(
        comando,
        input=CODIGO_REMOTO,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=TIMEOUT_SSH,
    )
    if resultado.returncode != 0:
        raise ValueError(f"ssh salió {resultado.returncode}: {resultado.stderr.strip()}")
    filas = []
    for linea in resultado.stdout.splitlines():
        if not linea.strip():
            continue
        cruda = json.loads(linea)
        evento = cruda.get("event_json")
        if evento is None and cruda.get("event_zstd") is not None:
            evento = _descomprimir(base64.b64decode(cruda["event_zstd"]), tipo)
        filas.append(
            {
                "session_key": cruda.get("session_key"),
                "session_id": cruda.get("session_id"),
                "seq": cruda.get("seq"),
                "created_at": cruda.get("created_at"),
                "event": json.loads(evento) if evento is not None else {},
            }
        )
    return filas


def _hijas(filas: list[dict]) -> list[str]:
    """Las sesiones hijas que los toolResult de esta tanda anuncian. El resultado del
    `sessions_spawn` puede venir envuelto (`tool_call`) o directo: el patrón sobre el texto
    las encuentra igual."""
    claves = []
    for fila in filas:
        evento = fila.get("event")
        if not isinstance(evento, dict) or evento.get("type") != "message":
            continue
        mensaje = evento.get("message")
        if not isinstance(mensaje, dict) or mensaje.get("role") != "toolResult":
            continue
        contenido = mensaje.get("content")
        if not isinstance(contenido, list):
            continue
        for pieza in contenido:
            if isinstance(pieza, dict) and isinstance(pieza.get("text"), str):
                claves.extend(HIJO.findall(pieza["text"]))
    return claves


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--mini", required=True, help="usuario@host de la Mini")
    parser.add_argument("--agente", required=True, help="id del agente dueño de las sesiones")
    parser.add_argument(
        "--sesion",
        action="append",
        required=True,
        metavar="SESSION_KEY",
        help="session_key a extraer; repetible",
    )
    parser.add_argument(
        "--con-hijos",
        action="store_true",
        help="seguir los childSessionKey de los sessions_spawn (una llamada ssh más por tanda)",
    )
    parser.add_argument(
        "--salida", type=Path, required=True, help="jsonl de filas con el evento decodificado"
    )
    parser.add_argument(
        "--base",
        default=BASE_POR_DEFECTO,
        help=(
            f"base del agente en la Mini; {{agente}} se reemplaza por --agente "
            f"(default: {BASE_POR_DEFECTO})"
        ),
    )
    args = parser.parse_args(argv)
    try:
        # Las claves de sesión del agente comparten prefijo (agent:<id>:...): exigirlo
        # atrapa el --sesion escrito para otro agente antes de gastar una llamada ssh.
        prefijo = f"agent:{args.agente}:"
        for clave in args.sesion:
            if not clave.startswith(prefijo):
                raise ValueError(f"--sesion debe empezar con {prefijo}: {clave}")
        base = args.base.replace("{agente}", args.agente)
        tipo = _decodificador()
        if tipo is None:
            raise ValueError(
                "no hay forma de descomprimir zstd: falta compression.zstd (Python 3.14+) "
                "y el binario zstd no está en el PATH"
            )
        pendientes = list(dict.fromkeys(args.sesion))
        vistas: set[str] = set()
        filas: list[dict] = []
        while pendientes:
            tanda = _traer(args.mini, base, pendientes, tipo)
            filas.extend(tanda)
            vistas.update(pendientes)
            pendientes = []
            if args.con_hijos:
                candidatas = _hijas(tanda)
                pendientes = [c for c in dict.fromkeys(candidatas) if c not in vistas]
        args.salida.parent.mkdir(parents=True, exist_ok=True)
        with args.salida.open("w", encoding="utf-8") as archivo:
            for fila in filas:
                archivo.write(json.dumps(fila, ensure_ascii=False) + "\n")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 3
    print(
        json.dumps(
            {"ok": True, "filas": len(filas), "sesiones": sorted(vistas)}, ensure_ascii=False
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
