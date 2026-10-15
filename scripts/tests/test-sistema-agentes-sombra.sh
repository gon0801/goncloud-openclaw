#!/usr/bin/env bash
# SUA-02: la sombra del controlador contra su extracto. Sin AGENT_WORK_RUNTIME_SOURCE se salta.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 scripts/tests/test-sistema-agentes-sombra.py
