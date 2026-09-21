#!/bin/sh
# Fixture del carril R (15.1): una prueba del "resto de shell" que cae en el shard 3
# (ver nucleo.sh para el porque del tally).
# Uso: solo via scripts/tests/test-runner-shards.sh (requiere TALLY_SHARDS).
printf 'resto-a\n' >> "$TALLY_SHARDS"
exit 0
