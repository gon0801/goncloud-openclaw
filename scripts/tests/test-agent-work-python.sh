#!/bin/bash
# Las baterías de Python del publicador que no tenían entrada propia de CI
# (VEREDICTO-SUA03-G4-r1, M1): conducta, contexto, flota y publicar.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/tests/test-agent-work-conducta.py
python3 scripts/tests/test-agent-work-contexto.py
python3 scripts/tests/test-agent-work-flota.py
python3 scripts/tests/test-agent-work-publicar.py
