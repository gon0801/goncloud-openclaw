#!/bin/sh
# Fixture del carril R (15.1): se instala CON UN NOMBRE que no existia antes en el
# arbol de juguete, para probar que el inventario sale del glob y un archivo nuevo
# entra solo, sin tocar ninguna lista a mano (ver nucleo.sh para el porque del tally).
# Uso: solo via scripts/tests/test-runner-shards.sh (requiere TALLY_SHARDS).
printf 'nuevo\n' >> "$TALLY_SHARDS"
exit 0
