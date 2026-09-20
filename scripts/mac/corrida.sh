#!/bin/bash
# scripts/mac/corrida.sh — despachador de corridas autonomas (Fase 9, 9.2).
# Solo despacha y carga corrida/<subcomando>.sh relativo a si mismo: M y P agregan
# subcomandos sin tocar este archivo. Instalado vive en ~/bin/corrida.sh con
# ~/bin/corrida/ al lado, no en el repo.
# Uso: corrida.sh <abrir|lanzar-sesion|terminar-sesion|reconciliar-marcas|cerrar|preflight|estado|latido|responder> ...
set -u
AQUI="$(cd "$(dirname "$0")" && pwd)"
SUB="${1:-}"
[ -n "$SUB" ] || { echo "uso: corrida.sh <subcomando> ..." >&2; exit 2; }
FN="$(printf '%s' "$SUB" | tr '-' '_')"
case "$SUB" in lib|*/*|*..*) echo "subcomando invalido: $SUB" >&2; exit 2;; esac
[ -f "$AQUI/corrida/$SUB.sh" ] || { echo "subcomando desconocido: $SUB" >&2; exit 2; }
. "$AQUI/corrida/lib.sh"
. "$AQUI/corrida/$SUB.sh"
shift
"corrida_$FN" "$@"
