#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 -m scripts.tests.resumen_envios_harness
PYTHONDONTWRITEBYTECODE=1 python3 -m scripts.tests.resumen_envios_previews --check
