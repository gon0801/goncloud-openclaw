#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
if [ "${1:-}" = "agents_routing" ]; then
  shift
  python3 "$here/test-agent-work-routing.py" "$@"
  if [ -z "${AGENT_WORK_RUNTIME_SOURCE:-}" ]; then
    echo 'agents_routing completo requiere AGENT_WORK_RUNTIME_SOURCE con R construido' >&2
    exit 2
  fi
  if [ "$(jq -r .commit "$AGENT_WORK_RUNTIME_SOURCE/dist/build-info.json")" != "$(git -C "$AGENT_WORK_RUNTIME_SOURCE" rev-parse HEAD)" ]; then
    echo 'R sin construir en HEAD' >&2
    exit 2
  fi
  printf '{"candidateSha": "%s", "candidateDiffSha256": "%s"}\n' \
    "$(git -C "$AGENT_WORK_RUNTIME_SOURCE" rev-parse HEAD)" \
    "$(git -C "$AGENT_WORK_RUNTIME_SOURCE" diff --binary HEAD | shasum -a 256 | cut -d' ' -f1)"
  ( cd "$AGENT_WORK_RUNTIME_SOURCE" && pnpm exec vitest run -c test/vitest/vitest.e2e.config.ts src/gateway/server.managed-task-requester.e2e.test.ts )
  exec bash "$here/test-agent-work-e2e.sh" cli_gateway
fi
if [ "${1:-}" = "main_cli_loop" ]; then
  shift
  if [ -z "${AGENT_WORK_RUNTIME_SOURCE:-}" ]; then
    echo 'main_cli_loop requiere AGENT_WORK_RUNTIME_SOURCE con R construido' >&2
    exit 2
  fi
  exec bash "$here/test-agent-work-e2e.sh" main_cli_loop
fi
if [ "${1:-}" = "delegation_bypass" ]; then
  shift
  exec bash "$here/../agent-work/test-runtime.sh" delegation_bypass "$@"
fi
if [ "${1:-}" = "hook_is_observation" ]; then
  shift
  if [ "$#" -ne 0 ]; then
    echo "hook_is_observation no acepta argumentos" >&2
    exit 2
  fi
  bash "$here/test-corrida-avisos.sh"
  exec bash "$here/test-tmux-activity-watch.sh"
fi
if [ "${1:-}" = "projection_crash" ]; then
  shift
  exec python3 "$here/test-agent-work-integration.py" \
    ProjectionTransferTest.test_projection_crash_after_result_ack_reuses_one_durable_event \
    ProjectionTransferTest.test_projection_crash_before_enqueue_rebuilds_the_same_event_from_pending "$@"
fi
if [ "${1:-}" = "projection_board_outage" ]; then
  shift
  exec python3 "$here/test-agent-work-integration.py" \
    ProjectionTransferTest.test_lost_transfer_ack_and_board_outage_converge_without_repeating_the_review "$@"
fi
if [ "${1:-}" = "director_handling" ]; then
  shift
  exec python3 "$here/test-agent-work-integration.py" DirectorHandlingTest "$@"
fi
if [ "$#" -eq 0 ]; then
  python3 "$here/test-agent-work-routing.py"
fi
exec python3 "$here/test-agent-work-integration.py" "$@"
