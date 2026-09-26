#!/bin/sh
# scripts/tests/fixtures/harness/fake-native-cli.sh — doble de las seis CLIs
# nativas para el contrato del adaptador (Fase 14, Task 3). Se copia con el
# nombre de cada binario (claude, codex, zcode, kimi, cursor-agent, grok) y
# el adaptador lo resuelve por CORRIDA_WORKER_BIN_<ID>.
#
# Anota cada invocacion (argv) en $FAKE_ARGV_DIR/<nombre>.argv, pinta
# $FAKE_BAR y simula el modo de $FAKE_HARNESS_MODE:
#   health (--version en argv): quota|auth|broken|ok
#   TUI: complete|waiting|failed|quota|auth|silence|cualquiera (idle)
# Los marcadores ADAPTADOR-MARCA son el contrato con adaptador_inspect.
set -u
nombre="$(basename "$0")"
[ -n "${FAKE_ARGV_DIR:-}" ] && printf '%s\n' "$*" >>"$FAKE_ARGV_DIR/$nombre.argv"

case " $* " in
  *" --version "*)
    case "${FAKE_HARNESS_MODE:-}" in
      quota) echo "fake-$nombre: rate limit exceeded, retry later"; exit 1;;
      auth) echo "fake-$nombre: login required"; exit 1;;
      broken) exit 3;;
      blocked) echo "fake-$nombre: permission denied"; exit 0;;

      *) echo "fake-$nombre 0.0-test"; exit 0;;
    esac
    ;;
esac

[ "${FAKE_HARNESS_MODE:-}" != "nobar" ] && [ -n "${FAKE_BAR:-}" ] && printf '%s\n' "$FAKE_BAR"
case "${FAKE_HARNESS_MODE:-}" in
  complete) printf 'ADAPTADOR-MARCA: completo\n';;
  waiting) printf 'ADAPTADOR-MARCA: esperando\n';;
  failed) printf 'ADAPTADOR-MARCA: fallo\n'; sleep 2; exit 1;;
  quota) printf 'fake-%s: rate limit exceeded, retry later\n' "$nombre";;
  auth) printf 'fake-%s: login required\n' "$nombre";;
  *) :;;
esac
# Como un TUI: consume el encargo por stdin y deja recibo en pantalla (la
# caja se vacia al entrar la linea); sin entrada, silencio = sigue corriendo.
while IFS= read -r linea; do
  printf 'RECIBIDO: %s\n' "$linea"
done
