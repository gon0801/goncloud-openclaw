#!/bin/bash
# Cadena completa agent-work. Sin argumentos corre el caso que queda,
# porque run-checks.sh invoca cada scripts/tests/*.sh sin args.
# Con un nombre corre solo ese caso: `bash scripts/tests/test-agent-work-e2e.sh main_cli_loop`.
set -euo pipefail
cd "$(dirname "$0")/../.."

run_main_cli_loop() {
  python3 scripts/tests/test_agent_work_main_cli_loop_e2e.py
}

case "${1:-all}" in
  all)
    run_main_cli_loop
    ;;
  main_cli_loop)
    if [ -z "${AGENT_WORK_RUNTIME_SOURCE:-}" ]; then
      echo "main_cli_loop requiere AGENT_WORK_RUNTIME_SOURCE con R construido" >&2
      exit 2
    fi
    run_main_cli_loop
    ;;
  *)
    echo "casos disponibles: main_cli_loop" >&2
    exit 2
    ;;
esac
