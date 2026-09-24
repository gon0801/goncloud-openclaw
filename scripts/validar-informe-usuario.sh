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

# El contrato exige EXACTAMENTE una linea de veredicto, no "la primera que calce":
# un informe que dice NO FUNCIONA y mas abajo agrega FUNCIONA (o al reves) es
# contradictorio, y ademas cierre-de-fase.sh lee el VEREDICTO MAS RECIENTE de un
# bloque, asi que una segunda linea lo haria ganar en silencio. Se cuentan todas
# las lineas de veredicto antes de mirar cual es la primera.
total=$(grep -cE '^(FUNCIONA|NO FUNCIONA|NO PUDE PROBARLO) ' "$ARCHIVO")
if [ "$total" -ne 1 ]; then
  echo "el informe trae $total linea(s) de veredicto; el contrato exige exactamente una" >&2
  exit 1
fi

primera=$(head -n1 "$ARCHIVO")
if ! printf '%s' "$primera" | grep -qE '^(FUNCIONA|NO FUNCIONA|NO PUDE PROBARLO) '; then
  echo "la unica linea de veredicto no es la primera del informe: $primera" >&2
  exit 1
fi

for patron in "$@"; do
  # "--" antes del patron: uno que empieza con "-" (por ejemplo "--- a/", el
  # encabezado de un diff) se tomaria como opcion de grep sin el separador, grep
  # fallaria con su propio error y el validador devolveria exito sin haber
  # comprobado nada. Y un fallo de grep (rc>1, ej. patron invalido) no es lo mismo
  # que "no lo encontre": los dos se declaran, ninguno deja pasar el informe.
  grep -qF -- "$patron" "$ARCHIVO"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "el informe cita algo prohibido: \"$patron\"" >&2
    exit 1
  elif [ "$rc" -gt 1 ]; then
    echo "no pude comprobar el patron prohibido \"$patron\" (grep salió $rc); no se valida a ciegas" >&2
    exit 1
  fi
done

exit 0
