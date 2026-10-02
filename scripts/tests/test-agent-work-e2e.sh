#!/usr/bin/env bash
# Cadena completa agent-work (T10). Sin argumentos corre todos los casos
# implementados, porque run-checks.sh invoca cada scripts/tests/*.sh sin args.
# Con un nombre corre solo ese caso: `bash scripts/tests/test-agent-work-e2e.sh delivery_latency`.
set -euo pipefail
cd "$(dirname "$0")/../.."

run_delivery_latency() {
  python3 scripts/tests/test-agent-work-integration.py \
    ProjectionTransferTest.test_delivery_latency_acceptance_records_both_legs
}

case "${1:-all}" in
  all)
    run_delivery_latency
    ;;
  delivery_latency)
    run_delivery_latency
    ;;
  *)
    echo "casos disponibles: delivery_latency" >&2
    exit 2
    ;;
esac
