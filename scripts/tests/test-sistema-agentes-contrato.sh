#!/usr/bin/env bash
# SUA-00: el validador del contrato sistema-agentes.v1 contra sus fixtures.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 scripts/tests/test-sistema-agentes-contrato.py
