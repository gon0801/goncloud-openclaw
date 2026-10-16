#!/bin/bash
# Las baterías de Python del publicador que no tenían entrada propia de CI
# (VEREDICTO-SUA03-G4-r1, M1): conducta, contexto, flota y publicar. El banco de la ruta
# CLI entra sin AGENT_WORK_BANCO_REAL: sus casos reales se saltan solos y sus pruebas de
# contrato (los briefs) corren siempre (A5 de SUA03-G5b).
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/tests/test-agent-work-lineas.py
python3 scripts/tests/test-agent-work-sucesion.py
python3 scripts/tests/test-agent-work-conducta.py
python3 scripts/tests/test-agent-work-contexto.py
python3 scripts/tests/test-agent-work-flota.py
python3 scripts/tests/test-agent-work-publicar.py
python3 scripts/tests/test_agent_work_banco_e2e.py
