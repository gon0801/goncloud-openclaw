#!/bin/sh
# Fixture del carril R (15.1): NO es una prueba, es el "test-corrida-nucleo.sh" de
# mentira que scripts/tests/test-runner-shards.sh instala en un arbol de juguete para
# auditar como scripts/run-checks.sh reparte los shards. Cada corrida deja UNA linea
# en $TALLY_SHARDS: el conteo de lineas es el conteo de ejecuciones.
# Uso: solo via scripts/tests/test-runner-shards.sh (requiere TALLY_SHARDS).
printf 'nucleo\n' >> "$TALLY_SHARDS"
exit 0
