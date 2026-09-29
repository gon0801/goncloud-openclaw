#!/bin/bash
# Doble de CORRIDA_BIN SOLO para el vigia doblado de --ensayo
# (SIM_VIGIA_CORRIDA_BIN): su relanzo automatico falla y todo lo demas
# (responder, latido) va al corrida.sh del checkout. Con SIM_MAIN=mudo modela
# "nadie relanza": los casos 5 y 6 tienen que salir NO FUNCIONA.
[ "${1:-}" = lanzar-sesion ] && { echo "lanzar-sesion: relanzo roto a proposito (ensayo)" >&2; exit 1; }
exec "$(cd "$(dirname "$0")/../../../mac" && pwd)/corrida.sh" "$@"
