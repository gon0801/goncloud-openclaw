#!/bin/bash
# B22 fase 2: una sesión de opencode por encargo (sesion.py y la ruta run-per-task del host) y lanzar-encargos.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-all}" in
  all) python3 scripts/tests/test-agent-work-sesion.py; exec python3 scripts/tests/test-agent-work-lanzar-encargos.py ;;
  sesion) exec python3 scripts/tests/test-agent-work-sesion.py ;;
  lanzar_encargos) exec python3 scripts/tests/test-agent-work-lanzar-encargos.py ;;
  *) echo "unknown case: $1" >&2; exit 2 ;;
esac
