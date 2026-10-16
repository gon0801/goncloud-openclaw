#!/usr/bin/env python3
"""El aviso a David por Telegram (SUA-04, 4.8): un mensaje con el openclaw de la Mac.

Lo usan la sucesión de G3 al promover y, cuando G6 lo cablee, `fuentes --aviso`. El
destino sale de la política (`ownerTelegramChat`), no de un número escrito aquí. Un envío
fallido contesta que no salió: nunca rompe al que llama, que lo deja pendiente.
Biblioteca estándar.
"""

from __future__ import annotations

import subprocess


def avisar(texto: str, *, policy, openclaw_bin, dry_run: bool = False) -> dict:
    """{"enviado": bool, ...}: el resultado del envío, no el texto por stdout."""
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
    return {"enviado": True, "destino": destino, "salida": hecho.stdout.strip()[:500]}
