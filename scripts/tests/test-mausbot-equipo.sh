#!/usr/bin/env bash
# El generador y el aplicador del equipo de MausBot, sin la app ni la PC.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 scripts/tests/test-mausbot-equipo.py
