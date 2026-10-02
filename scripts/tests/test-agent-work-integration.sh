#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "agents_routing" ]; then
  shift
  exec python3 "$(dirname "$0")/test-agent-work-routing.py" "$@"
fi
if [ "${1:-}" = "delegation_bypass" ]; then
  shift
  exec bash "$(dirname "$0")/../agent-work/test-runtime.sh" delegation_bypass "$@"
fi
if [ "${1:-}" = "hook_is_observation" ]; then
  shift
  if [ "$#" -ne 0 ]; then
    echo "hook_is_observation no acepta argumentos" >&2
    exit 2
  fi
  bash "$(dirname "$0")/test-corrida-avisos.sh"
  exec bash "$(dirname "$0")/test-tmux-activity-watch.sh"
fi
if [ "${1:-}" = "projection_crash" ]; then
  shift
  exec python3 "$(dirname "$0")/test-agent-work-integration.py" \
    ProjectionTransferTest.test_projection_crash_after_result_ack_reuses_one_durable_event "$@"
fi
if [ "${1:-}" = "director_handling" ]; then
  shift
  exec python3 "$(dirname "$0")/test-agent-work-integration.py" DirectorHandlingTest "$@"
fi
exec python3 "$(dirname "$0")/test-agent-work-integration.py" "$@"
