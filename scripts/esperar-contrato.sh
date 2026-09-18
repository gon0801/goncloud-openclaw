#!/usr/bin/env bash
# Espera la línea de contrato de un implementador leyéndola de un ARCHIVO, no
# de la pantalla, y distingue «sigue trabajando» de «se murió» antes de
# declarar silencio.
#
# Por qué existe (medido 2026-09-17, Fase 10 de Orbit): muse imprime todo con
# sangría y la pantalla conserva el eco del brief y el LISTO del encargo
# anterior, así que un grep del capture-pane o no ve nada o ve una línea
# falsa. Y un carril de código son horas: un tope corto sin prueba de vida
# declaraba muerto a un implementador que estaba a medio trabajo.
#
# uso: esperar-contrato.sh <archivo> [-t <seg>] [-s <sesion tmux>]
#   <archivo>  el .saikit/scratch/<carril>/contrato.txt que el BRIEF pide escribir
#   -t         tope en segundos; default 10800 (3 h)
#   -s         sesión de tmux del implementador, para la prueba de vida al vencer el tope
# salida (última línea): la línea de contrato (`LISTO <sha>` / `ATORADO <razón>`), o
#   `SIN-CONTRATO VIVA` (tope vencido, pantalla cambió: renovar la espera, no reenviar),
#   `SIN-CONTRATO QUIETA` (tope vencido, pantalla idéntica: reenviar una vez),
#   `SIN-CONTRATO` (tope vencido, sin sesión para probar vida), o
#   `ATORADO sin reporte: <linea>` (el archivo no empieza por LISTO/ATORADO)
# códigos: 0 contrato leído · 1 uso · 3 VIVA · 4 QUIETA · 5 sin reporte · 124 tope sin sesión
# INTERVALO (default 120 s) e INTERVALO_VIDA (default 120 s) se fijan por entorno; los tests los acortan.
set -u
TMUX_BIN=${TMUX_BIN:-/opt/homebrew/bin/tmux}
INTERVALO=${INTERVALO:-120}
INTERVALO_VIDA=${INTERVALO_VIDA:-120}
[ $# -ge 1 ] || { echo "ATORADO uso: falta el archivo"; exit 1; }
ARCHIVO=$1; shift
TOPE=10800; SESION=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) TOPE=$2; shift 2 ;;
    -s) SESION=$2; shift 2 ;;
    *) echo "ATORADO uso: argumento desconocido $1"; exit 1 ;;
  esac
done

t=0
until [ -s "$ARCHIVO" ]; do
  if [ "$t" -ge "$TOPE" ]; then
    if [ -z "$SESION" ]; then
      echo "SIN-CONTRATO"
      exit 124
    fi
    a=$("$TMUX_BIN" capture-pane -p -t "$SESION" -S -40 2>/dev/null)
    sleep "$INTERVALO_VIDA"
    b=$("$TMUX_BIN" capture-pane -p -t "$SESION" -S -40 2>/dev/null)
    if [ "$a" != "$b" ]; then
      echo "SIN-CONTRATO VIVA"
      exit 3
    fi
    echo "SIN-CONTRATO QUIETA"
    exit 4
  fi
  sleep "$INTERVALO"
  t=$((t + INTERVALO))
done

linea=$(sed -n 1p "$ARCHIVO" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
case "$linea" in
  "LISTO "*|"ATORADO "*) echo "$linea"; exit 0 ;;
  *) echo "ATORADO sin reporte: $linea"; exit 5 ;;
esac
