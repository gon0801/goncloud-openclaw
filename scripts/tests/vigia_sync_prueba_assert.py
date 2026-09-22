#!/usr/bin/env python3
"""Aserciones de la prueba D1/D2 de APLICAR_VIGIA_SYNC.sh (extraibles para TDD en seco)."""
from __future__ import annotations

import json
import re
import sys
from typing import Any


def _entries(runs: Any) -> list:
    if not isinstance(runs, dict):
        return []
    raw = runs.get("entries") or runs.get("runs") or []
    return [e for e in raw if isinstance(e, dict)]


def _entry(runs: Any) -> dict:
    es = _entries(runs)
    return es[0] if es else {}


def _blob(entry: dict) -> str:
    parts = [
        str(entry.get("summary") or ""),
        str(entry.get("error") or ""),
        str(entry.get("status") or ""),
        str(entry.get("completionStatus") or ""),
    ]
    return "\n".join(parts)


def _run_exitoso(entry: dict) -> str:
    """'' si el run fue exitoso; mensaje si no."""
    if not entry:
        return "sin entrada de run"
    status = str(entry.get("status") or "").lower()
    completion = str(entry.get("completionStatus") or "").lower()
    if completion in ("failed", "error", "cancelled", "aborted"):
        return f"completionStatus={completion}"
    if status in ("error", "failed", "cancelled"):
        return f"status={status}"
    ok_status = status in ("ok", "succeeded", "success")
    ok_completion = completion in ("ok", "succeeded", "success", "")
    # Exigir senal positiva de exito (status ok), no solo "no failed".
    if not ok_status:
        return f"run no exitoso status={status!r} completionStatus={completion!r}"
    if completion and not ok_completion:
        return f"completionStatus={completion}"
    return ""


# Contrato D1: UNA sola linea (sin DOTALL / sin que \\s cruce el salto).
_RE_CONTRATO_D1 = re.compile(
    r"VIGIA SYNC PENDIENTE\s+pr=[\d,]+\s+agentes=verifier\b",
    re.IGNORECASE,
)

# Contrato D3: UNA sola linea, igual disciplina que D1.
_RE_CONTRATO_D3 = re.compile(
    r"VIGIA SYNC DEPLOYED\s+sha=[0-9a-f]{7}\s+n=\d+",
    re.IGNORECASE,
)

_PISTAS_ARCHIVOS = (
    "archivo",
    "skill.md",
    "cron-payload-verify",
    "lane-claim-verify",
    "test-discrimination",
    "regression-triage",
    "egress-suppression",
    "workshop-skills",
)


def _linea_contrato_d1(blob: str) -> str | None:
    for line in blob.splitlines():
        if _RE_CONTRATO_D1.search(line):
            return line
    return None


def _linea_contrato_d3(blob: str) -> str | None:
    for line in blob.splitlines():
        if _RE_CONTRATO_D3.search(line):
            return line
    return None


def assert_d1_result(runs: Any) -> str:
    """D1: run exitoso + linea de contrato del aviso. '' = OK."""
    entries = _entries(runs)
    if not entries:
        return "D1: sin entradas — no hay evidencia de que corrio"
    entry = entries[0]
    why = _run_exitoso(entry)
    if why:
        return f"D1: run no exitoso ({why}) — un run fallido no es un aviso"
    blob = _blob(entry)
    if _linea_contrato_d1(blob) is None:
        return (
            "D1: falta la linea de contrato "
            "'VIGIA SYNC PENDIENTE pr=<n> agentes=verifier' (debe caber en UNA linea)"
        )
    # Archivos: en la misma linea de contrato o citadas en el summary
    if not any(p in blob.lower() for p in _PISTAS_ARCHIVOS):
        return "D1: tiene la linea de contrato pero no nombra archivos"
    return ""


def assert_d3_result(runs: Any) -> str:
    """D3: run exitoso + linea de contrato del deployado. '' = OK."""
    entries = _entries(runs)
    if not entries:
        return "D3: sin entradas — no hay evidencia de que corrio"
    entry = entries[0]
    why = _run_exitoso(entry)
    if why:
        return f"D3: run no exitoso ({why}) — un run fallido no es un aviso"
    blob = _blob(entry)
    if _linea_contrato_d3(blob) is None:
        return (
            "D3: falta la linea de contrato "
            "'VIGIA SYNC DEPLOYED sha=<7> n=<n>' (debe caber en UNA linea)"
        )
    if not any(p in blob.lower() for p in _PISTAS_ARCHIVOS):
        return "D3: tiene la linea de contrato pero no nombra archivos"
    return ""


def assert_d2_result(runs: Any) -> str:
    """D2: al menos un run exitoso y SIN aviso D. '' = OK."""
    entries = _entries(runs)
    if not entries:
        return "D2: sin entradas — no hay prueba de que corrio y estuvo callado"
    entry = entries[0]
    why = _run_exitoso(entry)
    if why:
        return f"D2: run no exitoso ({why})"
    blob = _blob(entry)
    if "VIGIA SYNC PENDIENTE" in blob:
        return "D2: aviso de pendiente (VIGIA SYNC PENDIENTE) — debia estar callado"
    if "VIGIA SYNC DEPLOYED" in blob:
        return "D2: aviso de deployado (VIGIA SYNC DEPLOYED) — debia estar callado"
    if "DIFERIDO_D" in blob:
        return "D2: DIFERIDO_D — fuera de franja no aplica; reintenta fuera de 23:00-08:00 CDMX"
    if "DIFERIDO_E" in blob:
        return "D2: DIFERIDO_E — fuera de franja no aplica; reintenta fuera de 23:00-08:00 CDMX"
    if "Ya esta en el gateway" in blob or "Todavia no esta en el gateway" in blob:
        return "D2: cierra con frase de aviso D — debia estar callado"
    return ""


def assert_rm_cleanup(tid: str, rm_ok: bool, list_status: str) -> str:
    """rm fallido, job listado, o lista ilegible → error. '' = OK.

    list_status: 'absent' | 'present' | 'unknown'
    """
    if not rm_ok:
        return f"cron rm fallo para id={tid}: borrar a mano (el job puede seguir vivo)"
    if list_status == "unknown":
        return (
            f"UNKNOWN: no pude leer cron list para verificar id={tid} "
            f"— el lead decide a mano (no se declara cleanup OK)"
        )
    if list_status == "present":
        return f"cron rm dijo OK pero id={tid} sigue en cron list: borrar a mano"
    if list_status != "absent":
        return f"list_status invalido: {list_status!r} (absent|present|unknown)"
    return ""


def jobs_from_cron_list(data: Any) -> tuple[str, list]:
    """Parsea cron list --json.

    Distingue clave `jobs` presente (aunque []) de ausente/invalida.
    Returns: ("ok", jobs_list) | ("unknown", []).
    """
    if not isinstance(data, dict):
        return "unknown", []
    if "jobs" not in data:
        return "unknown", []
    jobs = data["jobs"]
    if jobs is None or not isinstance(jobs, list):
        return "unknown", []
    return "ok", [j for j in jobs if isinstance(j, dict)]


def list_status_for_tid(data: Any, tid: str) -> str:
    """present | absent | unknown a partir del JSON de cron list."""
    kind, jobs = jobs_from_cron_list(data)
    if kind != "ok":
        return "unknown"
    ids = [j.get("id") for j in jobs]
    return "present" if tid in ids else "absent"


def main(argv: list[str]) -> int:
    # CLI: assert-d1|assert-d2|assert-d3 <runs.json>
    #      assert-rm <tid> <rm_ok:0|1> <absent|present|unknown>
    if len(argv) < 2:
        print("uso: vigia_sync_prueba_assert.py assert-d1|assert-d2|assert-d3 <runs.json>", file=sys.stderr)
        print("     vigia_sync_prueba_assert.py assert-rm <tid> <0|1> <absent|present|unknown>", file=sys.stderr)
        return 2
    op = argv[1]
    if op in ("assert-d1", "assert-d2", "assert-d3"):
        if len(argv) < 3:
            print("falta runs.json", file=sys.stderr)
            return 2
        data = json.load(open(argv[2], encoding="utf-8"))
        if op == "assert-d1":
            err = assert_d1_result(data)
        elif op == "assert-d3":
            err = assert_d3_result(data)
        else:
            err = assert_d2_result(data)
        if err:
            print("ASSERT_FAIL:", err)
            return 1
        print("ASSERT_OK:", op)
        return 0
    if op == "assert-rm":
        if len(argv) < 5:
            print("falta tid rm_ok list_status", file=sys.stderr)
            return 2
        tid, rm_ok, list_status = argv[2], argv[3] == "1", argv[4]
        # Compat: 0/1 antiguos → absent/present
        if list_status == "0":
            list_status = "absent"
        elif list_status == "1":
            list_status = "present"
        err = assert_rm_cleanup(tid, rm_ok, list_status)
        if err:
            print("ASSERT_FAIL:", err)
            return 1
        print("ASSERT_OK: assert-rm")
        return 0
    if op == "list-status":
        # list-status <tid> <cron-list.json|->
        if len(argv) < 4:
            print("falta tid cron-list.json", file=sys.stderr)
            return 2
        tid, path = argv[2], argv[3]
        raw = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
        try:
            data = json.loads(raw)
        except Exception:
            print("unknown")
            return 0
        print(list_status_for_tid(data, tid))
        return 0
    print("op desconocida:", op, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
