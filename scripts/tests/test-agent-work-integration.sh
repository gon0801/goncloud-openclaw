#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "agents_routing" ]; then
  shift
  exec python3 "$(dirname "$0")/test-agent-work-routing.py" "$@"
fi
exec python3 "$(dirname "$0")/test-agent-work-integration.py" "$@"
