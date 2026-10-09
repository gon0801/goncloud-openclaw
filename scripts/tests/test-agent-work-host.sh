#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-all}" in
  all) python3 scripts/tests/test-agent-work-host.py; exec python3 scripts/tests/test-agent-work-resources.py ;;
  host_receipts) exec python3 scripts/tests/test-agent-work-host.py ;;
  resource_identity|resource_close|resource_100_cycles)
    # -v names each skipped test in the log, so the acceptance pair can tell the declared
    # launchd skip apart from any other skip.
    exec python3 scripts/tests/test-agent-work-resources.py -v -k "$1" ;;
  *) echo "unknown case: $1" >&2; exit 2 ;;
esac
