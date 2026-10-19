#!/bin/bash
# Las baterías de Python del publicador que no tenían entrada propia de CI
# (VEREDICTO-SUA03-G4-r1): contexto, merge, avisar, reporte y proyección.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/tests/test-agent-work-avisar.py
python3 scripts/tests/test-agent-work-proyeccion.py
python3 scripts/tests/test-sistema-agentes-derivar.py
python3 scripts/tests/test-agent-work-contexto.py
python3 scripts/tests/test-agent-work-merge.py
