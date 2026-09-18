#!/usr/bin/env bash
# Dice DONDE esta el runbook de una fase, en la maquina donde se corre.
#
# POR QUE EXISTE. Medido el 2026-09-18, arrancando la Fase 9: los implementadores no
# encontraban su runbook. Se les habia dado un enlace de GitHub y el repo es privado,
# asi que la pagina no abre; y la ruta que traian los documentos era la de OTRA maquina.
# El archivo estaba en las dos, en su sitio, todo el tiempo. Lo que faltaba no era el
# archivo: era una forma de preguntar "donde esta" que contestara igual de bien en la
# Mac, en el gateway Windows y en cualquier maquina nueva.
#
# La regla que implementa: un runbook se localiza con un comando, no con una ruta
# escrita a mano ni con un enlace. Ningun documento vuelve a fijar una ruta absoluta:
# fijan esta llamada. Cuando alguien mueva el repo, o entre una maquina nueva, no hay
# nada que actualizar en veinte documentos.
#
# DONDE CORRE. Necesita bash y grep. En la Mac, tal cual. En el gateway Windows hay
# bash (el de Git) pero NO en el PATH: alli se invoca por su ruta completa,
# `"C:\Program Files\Git\bin\bash.exe" scripts/runbook.sh <fase>`. Medido el
# 2026-09-18 contra el gateway real: la gramatica se comporta igual en los dos (acepta
# `9` y `9.1`, rechaza `.9`, `9.`, `9..1`, `1234` y `a9`). Se escribe porque la version
# anterior de esta cabecera prometia "cualquier maquina" sin haberlo probado en ninguna
# que no fuera esta. Hallazgo de kimi en la revision cruzada.
#
# Uso:
#   bash scripts/runbook.sh <fase>        # imprime la ruta absoluta, o falla diciendo por que
#   bash scripts/runbook.sh <fase> --ver  # ademas imprime el archivo entero
#   bash scripts/runbook.sh --lista       # todas las fases que tienen runbook aqui
#
# Salida: 0 con la ruta en stdout. 1 si no existe, con la razon en stderr y stdout vacio,
# para que `$(bash scripts/runbook.sh 9)` no devuelva basura silenciosamente.
set -u

AQUI=$(cd "$(dirname "$0")/.." && pwd -P)
DIR="$AQUI/docs/runbooks"

morir() { printf 'runbook.sh: %s\n' "$1" >&2; exit 1; }

[ -d "$DIR" ] || morir "no encuentro $DIR; este comando se corre desde un clon del repo"

# Una sola fuente para "que fases hay": la usan `--lista` y el mensaje de error de una
# fase que no existe. Antes cada uno tenia su propio filtro y el del error colaba
# `8-hallazgos`, o sea que sugeria una fase imposible. Hallazgo de CodeRabbit.
fases_presentes() {
  for f in "$DIR"/autopilot-fase*.md; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .md); n=${n#autopilot-fase}
    printf '%s' "$n" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3})?$' || continue
    printf '%s\t%s\n' "$n" "$f"
  done
}

if [ "${1:-}" = "--lista" ]; then
  salida=$(fases_presentes)
  [ -n "$salida" ] || morir "no hay ningun runbook de fase en $DIR"
  printf '%s\n' "$salida" | while IFS="$(printf '\t')" read -r n f; do
    printf '%-6s %s\n' "$n" "$f"
  done
  exit 0
fi

FASE=${1:-}
[ -n "$FASE" ] || morir "falta la fase: bash scripts/runbook.sh <fase>   (o --lista)"

# La fase es clave de archivo: forma cerrada, igual que en el spec del tablero. Sin esto
# un argumento con `/` o `..` haria que este comando imprima la ruta de otra cosa.
# Misma forma cerrada que el spec (`FASE_RE` en tablero-runbook/lib.ts). Un filtro de
# "solo digitos y punto" aceptaba `.9`, `9.` y `9..1`, que no son claves de nada.
# Hallazgo de CodeRabbit, 2026-09-18.
if ! printf '%s' "$FASE" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3})?$'; then
  morir "fase invalida: '$FASE' (forma cerrada: uno a tres digitos, con un solo punto opcional; p. ej. 9 o 9.1)"
fi

RUTA="$DIR/autopilot-fase$FASE.md"
if [ ! -f "$RUTA" ]; then
  hay=$(fases_presentes | cut -f1 | tr '\n' ' ')
  morir "no hay runbook de la fase $FASE en este clon. Los que si estan: ${hay:-ninguno}"
fi
[ -r "$RUTA" ] || morir "$RUTA existe pero no se puede leer"

printf '%s\n' "$RUTA"

if [ "${2:-}" = "--ver" ]; then
  printf '\n' >&2
  cat "$RUTA"
fi
