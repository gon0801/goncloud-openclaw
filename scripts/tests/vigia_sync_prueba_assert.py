#!/usr/bin/env python3
"""Aserciones de la prueba D1/D2 de APLICAR_VIGIA_SYNC.sh (extraibles para TDD en seco)."""
from __future__ import annotations

import json
import sys
from typing import Any


def _entry(runs: Any) -> dict:
    if isinstance(runs, dict):
        e = (runs.get("entries") or runs.get("runs") or [None])[0]
        return e if isinstance(e, dict) else {}
    return {}


def _blob(entry: dict) -> str:
    parts = [
        str(entry.get("summary") or ""),
        str(entry.get("error") or ""),
        str(entry.get("status") or ""),
        str(entry.get("completionStatus") or ""),
    ]
    return "\n".join(parts)


def assert_d1_result(runs: Any) -> str:
    """D1 debe nombrar a verifier y sus archivos. '' = OK, mensaje = fallo."""
    entry = _entry(runs)
    blob = _blob(entry)
    if not blob.strip():
        return "D1: runs vacio o sin summary (no hay evidencia de aviso)"
    if "verifier" not in blob.lower():
        return "D1: el resultado no nombra a verifier"
    # Al menos una pista de los archivos del 43097da / workshop-skills
    pistas = (
        "archivo",
        "skill.md",
        "cron-payload-verify",
        "lane-claim-verify",
        "test-discrimination",
        "regression-triage",
        "egress-suppression",
        "workshop-skills",
    )
    if not any(p in blob.lower() for p in pistas):
        return "D1: nombra verifier pero no sus archivos"
    # Con --tools exec el Telegram es imposible; si el summary afirma envio, es sospechoso
    # pero no bloqueamos: lo importante es el aviso en el resultado del job.
    return ""


def assert_d2_result(runs: Any) -> str:
    """D2 debe terminar sin nada que avisar por D. '' = OK, mensaje = fallo."""
    entry = _entry(runs)
    blob = _blob(entry)
    # Senales de que aviso por CASO D (no debe aparecer)
    if "VIGIA SYNC SKILLS" in blob:
        return "D2: aviso por D (VIGIA SYNC SKILLS) — debia estar callado"
    if "Ya esta en main" in blob or "Ya está en main" in blob:
        return "D2: cierra con la frase del aviso D — debia estar callado"
    # Si habla de verifier + skills juntos como aviso, falla
    low = blob.lower()
    if "verifier" in low and ("skills" in low or "archivo(s)" in low or "archivo(s)" in blob):
        # Puede mencionar skills en prosa de OK; exigir el patron de aviso
        if "SKILLS" in blob and "verifier" in low:
            return "D2: menciona SKILLS verifier como aviso — debia estar callado"
    return ""


def assert_rm_cleanup(tid: str, rm_ok: bool, still_listed: bool) -> str:
    """rm fallido o job aun listado → error. '' = OK."""
    if not rm_ok:
        return f"cron rm fallo para id={tid}: borrar a mano (el job puede seguir vivo)"
    if still_listed:
        return f"cron rm dijo OK pero id={tid} sigue en cron list: borrar a mano"
    return ""


def main(argv: list[str]) -> int:
    # CLI: assert-d1|assert-d2 <runs.json>
    #      assert-rm <tid> <rm_ok:0|1> <still_listed:0|1>
    if len(argv) < 2:
        print("uso: vigia_sync_prueba_assert.py assert-d1|assert-d2 <runs.json>", file=sys.stderr)
        print("     vigia_sync_prueba_assert.py assert-rm <tid> <0|1> <0|1>", file=sys.stderr)
        return 2
    op = argv[1]
    if op in ("assert-d1", "assert-d2"):
        if len(argv) < 3:
            print("falta runs.json", file=sys.stderr)
            return 2
        data = json.load(open(argv[2], encoding="utf-8"))
        err = assert_d1_result(data) if op == "assert-d1" else assert_d2_result(data)
        if err:
            print("ASSERT_FAIL:", err)
            return 1
        print("ASSERT_OK:", op)
        return 0
    if op == "assert-rm":
        if len(argv) < 5:
            print("falta tid rm_ok still_listed", file=sys.stderr)
            return 2
        tid, rm_ok, still = argv[2], argv[3] == "1", argv[4] == "1"
        err = assert_rm_cleanup(tid, rm_ok, still)
        if err:
            print("ASSERT_FAIL:", err)
            return 1
        print("ASSERT_OK: assert-rm")
        return 0
    print("op desconocida:", op, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
