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

if [ "${1:-}" = "--lista" ]; then
  encontrados=0
  for f in "$DIR"/autopilot-fase*.md; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .md); n=${n#autopilot-fase}
    case "$n" in
      *[!0-9.]*) continue ;;   # autopilot-fase8-hallazgos.md y compania no son el runbook de una fase
    esac
    printf '%-6s %s\n' "$n" "$f"
    encontrados=$((encontrados + 1))
  done
  [ "$encontrados" -gt 0 ] || morir "no hay ningun runbook de fase en $DIR"
  exit 0
fi

FASE=${1:-}
[ -n "$FASE" ] || morir "falta la fase: bash scripts/runbook.sh <fase>   (o --lista)"

# La fase es clave de archivo: forma cerrada, igual que en el spec del tablero. Sin esto
# un argumento con `/` o `..` haria que este comando imprima la ruta de otra cosa.
case "$FASE" in
  *[!0-9.]*|""|.|..) morir "fase invalida: '$FASE' (solo digitos y punto, p. ej. 9 o 9.1)" ;;
esac

RUTA="$DIR/autopilot-fase$FASE.md"
if [ ! -f "$RUTA" ]; then
  hay=$(cd "$DIR" 2>/dev/null && ls autopilot-fase*.md 2>/dev/null | sed 's/^autopilot-fase//; s/\.md$//' | tr '\n' ' ')
  morir "no hay runbook de la fase $FASE en este clon. Los que si estan: ${hay:-ninguno}"
fi
[ -r "$RUTA" ] || morir "$RUTA existe pero no se puede leer"

printf '%s\n' "$RUTA"

if [ "${2:-}" = "--ver" ]; then
  printf '\n' >&2
  cat "$RUTA"
fi
