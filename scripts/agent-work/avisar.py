#!/usr/bin/env python3
"""El aviso a David por Telegram (SUA-04, 4.8): un mensaje con el openclaw de la Mac.

Lo usan la sucesión de G3 al promover y, cuando G6 lo cablee, `fuentes --aviso`. El
destino sale de la política (`ownerTelegramChat`), no de un número escrito aquí. Un envío
fallido contesta que no salió: nunca rompe al que llama, que lo deja pendiente.
Biblioteca estándar.
"""

from __future__ import annotations

import json
import os
import subprocess


def _message_id(stdout: str) -> int | None:
    """El messageId del primer objeto JSON de la salida, si es una confirmación válida.

    Solo un entero positivo cuenta (una cadena de dígitos se convierte): el checkpoint
    del emisor de raíces no avanza con un envío que el gateway no confirmó.
    """
    lineas = stdout.splitlines(keepends=True)
    for indice, linea in enumerate(lineas):
        if not linea.lstrip().startswith("{"):
            continue
        try:
            respuesta, _ = json.JSONDecoder().raw_decode("".join(lineas[indice:]).lstrip())
        except json.JSONDecodeError:
            continue
        if not isinstance(respuesta, dict):
            return None
        crudo = respuesta.get("messageId")
        if isinstance(crudo, bool):
            return None
        if isinstance(crudo, int) and crudo > 0:
            return crudo
        if isinstance(crudo, str) and crudo.isdigit() and int(crudo) > 0:
            return int(crudo)
        return None
    return None


def avisar(texto: str, *, policy, openclaw_bin, dry_run: bool = False) -> dict:
    """{"enviado": bool, ...}: el resultado del envío, no el texto por stdout."""
    # Compuerta (B1): solo manda con AGENT_WORK_AVISOS=1, que pone el plist de la
    # sucesión y nadie más. Una prueba o una corrida a mano no le escribe a David.
    if os.environ.get("AGENT_WORK_AVISOS") != "1":
        return {"enviado": False, "causa": "avisos apagados (AGENT_WORK_AVISOS no es 1)"}
    destino = getattr(policy, "owner_telegram_chat", None)
    if not destino:
        return {"enviado": False, "causa": "la política no trae ownerTelegramChat"}
    orden = [
        str(openclaw_bin),
        "message",
        "send",
        "--channel",
        "telegram",
        "--target",
        destino,
        "--message",
        texto,
        "--json",
    ]
    if dry_run:
        orden.append("--dry-run")
    try:
        hecho = subprocess.run(orden, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"enviado": False, "causa": f"openclaw no corrió: {error}"}
    if hecho.returncode != 0:
        return {
            "enviado": False,
            "causa": f"openclaw salió {hecho.returncode}: {hecho.stderr.strip()[:200]}",
        }
    resultado = {"enviado": True, "destino": destino, "salida": hecho.stdout.strip()[:500]}
    message_id = _message_id(hecho.stdout)
    if message_id is not None:
        resultado["messageId"] = message_id
    return resultado
