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

run_review_tail_restart() {
  python3 scripts/tests/test_agent_work_review_tail_restart.py
}

run_cli_gateway() {
  python3 scripts/tests/test_agent_work_cli_gateway_e2e.py
}

case "${1:-all}" in
  all)
    run_delivery_latency
    run_review_tail_restart
    run_cli_gateway
    ;;
  delivery_latency)
    run_delivery_latency
    ;;
  review_tail_restart)
    if [ -z "${AGENT_WORK_RUNTIME_SOURCE:-}" ]; then
      echo "review_tail_restart requiere AGENT_WORK_RUNTIME_SOURCE con R construido" >&2
      exit 2
    fi
    run_review_tail_restart
    ;;
  cli_gateway)
    if [ -z "${AGENT_WORK_RUNTIME_SOURCE:-}" ]; then
      echo "cli_gateway requiere AGENT_WORK_RUNTIME_SOURCE con R construido" >&2
      exit 2
    fi
    run_cli_gateway
    ;;
  *)
    echo "casos disponibles: delivery_latency, review_tail_restart, cli_gateway" >&2
    exit 2
    ;;
esac
