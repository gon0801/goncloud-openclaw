#!/bin/bash
# B22: la política de proveedores, el catálogo de opencode, authorize y los comandos de encargo.py.
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-all}" in
  all) python3 scripts/tests/test-agent-work-modelos.py; exec python3 scripts/tests/test-agent-work-encargo.py ;;
  modelos) exec python3 scripts/tests/test-agent-work-modelos.py ;;
  encargo) exec python3 scripts/tests/test-agent-work-encargo.py ;;
  *) echo "unknown case: $1" >&2; exit 2 ;;
esac
