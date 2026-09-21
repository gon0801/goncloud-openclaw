#!/bin/sh
# Fixture del carril R (15.1): la prueba roja de mentira. Sale 7 con una salida
# distintiva: el runner debe conservar ESA primera salida y su exit code en el log
# sin volver a ejecutarla, y el tally debe mostrar exactamente UNA linea 'roja'
# (dos lineas = el runner la re-corrio para diagnosticar, que es lo que 15.1 prohibe).
# Uso: solo via scripts/tests/test-runner-shards.sh (requiere TALLY_SHARDS).
printf 'arranque de la roja\n'
printf 'cuerpo de la roja\n'
printf 'PRIMERA SALIDA UNICA DE LA ROJA\n'
printf 'roja\n' >> "$TALLY_SHARDS"
exit 7
