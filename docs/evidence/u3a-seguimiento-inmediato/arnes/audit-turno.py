#!/usr/bin/env python3
"""Espera un turno del dueño en el audit del gateway (19.0-r2).

Uso: audit-turno.py <session-key> <after-epoch-ms> <started|finished> <tope-s> [run-id]
Imprime "<occurredAt-ms> <run-id>" del evento mas ANTIGUO del tipo pedido (el
audit pagina de mas nuevo a mas viejo) y sale 0; con run-id, filtra por ese
turno. Sale 1 si vence el tope sin verlo. Solo lectura.
"""
import json
import os
import subprocess
import sys
import time

clave, after_ms, objetivo, tope_s = sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
run_id = sys.argv[5] if len(sys.argv) > 5 else None
binario = os.environ.get("OPENCLAW_REAL_BIN") or os.path.expanduser("~/.openclaw/bin/openclaw")
accion = "agent.run.started" if objetivo == "started" else "agent.run.finished"

fin = time.monotonic() + tope_s
mejor = None
while time.monotonic() < fin:
    p = subprocess.run(
        [binario, "audit", "--kind", "agent_run", "--session", clave,
         "--after", str(after_ms), "--limit", "50", "--json"],
        capture_output=True, text=True, timeout=30)
    try:
        cuerpo = p.stdout[p.stdout.index("{"):]
        datos = json.loads(cuerpo)
    except (ValueError, json.JSONDecodeError):
        time.sleep(3)
        continue
    for ev in datos.get("events", []):
        if ev.get("action") != accion or ev.get("sessionKey") != clave:
            continue
        if run_id and ev.get("runId") != run_id:
            continue
        ms = ev.get("occurredAt")
        if isinstance(ms, int) and (mejor is None or ms < mejor[0]):
            mejor = (ms, ev.get("runId"))
    if mejor:
        print(mejor[0], mejor[1])
        sys.exit(0)
    time.sleep(3)
sys.exit(1)
