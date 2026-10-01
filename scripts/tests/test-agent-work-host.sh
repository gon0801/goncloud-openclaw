#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-host_receipts}" in
  host_receipts) exec python3 scripts/tests/test-agent-work-host.py ;;
  *) echo "unknown case: $1" >&2; exit 2 ;;
esac
