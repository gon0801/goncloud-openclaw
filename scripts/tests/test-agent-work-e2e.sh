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

run_main_cli_loop() {
  python3 scripts/tests/test_agent_work_main_cli_loop_e2e.py
}

run_acceptance_matrix() {
  python3 scripts/tests/test_agent_work_acceptance.py
}

run_acceptance() {
  AGENT_WORK_ACCEPTANCE_STRICT=1 python3 scripts/tests/test_agent_work_acceptance.py AcceptanceMatrixTest AcceptanceStrictTest
}

case "${1:-all}" in
  all)
    run_delivery_latency
    run_review_tail_restart
    run_main_cli_loop
    run_acceptance_matrix
    ;;
  acceptance_matrix)
    run_acceptance_matrix
    ;;
  acceptance)
    run_acceptance
    ;;
  cutover_fencing)
    if [ -z "${AGENT_WORK_RUNTIME_SOURCE:-}" ]; then
      echo "cutover_fencing requiere AGENT_WORK_RUNTIME_SOURCE con R construido" >&2
      exit 2
    fi
    python3 scripts/tests/test_agent_work_cutover_fencing_e2e.py -v
    ;;
  cutover_rollback)
    if [ -z "${AGENT_WORK_CUTOVER_CANDIDATE_PREFIX:-}" ] || [ -z "${AGENT_WORK_CUTOVER_PREVIOUS_PREFIX:-}" ] \
        || [ -z "${AGENT_WORK_CUTOVER_COPY:-}" ]; then
      echo "cutover_rollback requiere AGENT_WORK_CUTOVER_CANDIDATE_PREFIX, AGENT_WORK_CUTOVER_PREVIOUS_PREFIX y AGENT_WORK_CUTOVER_COPY" >&2
      exit 2
    fi
    python3 -W ignore scripts/tests/test_agent_work_cutover_rollback_e2e.py -v
    ;;
  acceptance_pair)
    if [ -z "${AGENT_WORK_RUNTIME_SOURCE:-}" ]; then
      echo "acceptance_pair requiere AGENT_WORK_RUNTIME_SOURCE con R construido" >&2
      exit 2
    fi
    python3 scripts/tests/agent-work-acceptance-pair.py
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
  main_cli_loop)
    if [ -z "${AGENT_WORK_RUNTIME_SOURCE:-}" ]; then
      echo "main_cli_loop requiere AGENT_WORK_RUNTIME_SOURCE con R construido" >&2
      exit 2
    fi
    run_main_cli_loop
    ;;
  *)
    echo "casos disponibles: delivery_latency, review_tail_restart, main_cli_loop, acceptance_matrix, acceptance, acceptance_pair, cutover_fencing, cutover_rollback" >&2
    exit 2
    ;;
esac
