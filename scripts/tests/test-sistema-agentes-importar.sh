#!/usr/bin/env bash
# SUA-02: el importador de filas de Plans.md contra su fixture.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 scripts/tests/test-sistema-agentes-importar.py
