#!/bin/bash
# Valida el formato de un informe del agente `usuario` (agents/usuario/agent/AGENTS.md).
#
# El contrato exige exactamente una de tres lineas de veredicto y prohibe citar el
# diff, las pruebas o el PR del cambio. Este validador es chico a proposito: no
# reemplaza el juicio del agente, solo comprueba lo mecanico -- la forma de la linea
# y que ningun patron prohibido (por ejemplo, un marcador plantado en su directorio
# para la prueba) aparezca en el texto.
#
# Uso:
#   bash scripts/validar-informe-usuario.sh <archivo-informe> [<patron-prohibido> ...]
#
# Salida: 0 si el informe pasa; 1 con el motivo en stderr si no.
set -u

ARCHIVO=${1:-}
if [ -z "$ARCHIVO" ] || [ ! -r "$ARCHIVO" ]; then
  echo "uso: bash scripts/validar-informe-usuario.sh <archivo-informe> [<patron-prohibido> ...]" >&2
  exit 2
fi
shift || true

primera=$(head -n1 "$ARCHIVO")
if ! printf '%s' "$primera" | grep -qE '^(FUNCIONA|NO FUNCIONA|NO PUDE PROBARLO) '; then
  echo "la primera linea no es una de las tres del contrato: FUNCIONA / NO FUNCIONA / NO PUDE PROBARLO, con lo que vio despues: $primera" >&2
  exit 1
fi

for patron in "$@"; do
  if grep -qF "$patron" "$ARCHIVO"; then
    echo "el informe cita algo prohibido: \"$patron\"" >&2
    exit 1
  fi
done

exit 0
