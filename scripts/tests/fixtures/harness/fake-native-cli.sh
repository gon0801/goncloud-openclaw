#!/bin/sh
# scripts/tests/fixtures/harness/fake-native-cli.sh — doble de las seis CLIs
# nativas para el contrato del adaptador (Fase 14, Task 3). Se copia con el
# nombre de cada binario (claude, codex, zcode, kimi, cursor-agent, grok) y
# el adaptador lo resuelve por CORRIDA_WORKER_BIN_<ID>.
#
# Anota cada invocacion (argv) en $FAKE_ARGV_DIR/<nombre>.argv, pinta
# $FAKE_BAR y simula el modo de $FAKE_HARNESS_MODE:
#   health (--version en argv): quota|auth|broken|ok
#   TUI: complete|waiting|failed|quota|auth|silence|obedece|cualquiera (idle)
#   obedece: sin marca al arrancar; imprime la de completo solo si la linea
#   recibida trae la orden de adaptador_deliver (ADAPTADOR_ORDEN_MARCA).
#   confianza-claude|confianza-codex|confianza-kimi: pinta el dialogo de
#   confianza medido 2026-09-28 con la ruta $FAKE_CONFIANZA_RUTA y solo pinta
#   la barra si recibe las teclas exactas que aceptan (claude: Down Enter;
#   codex y kimi: Enter).
#   sin-uso: aviso de cuota de cursor-agent medido 2026-09-28.
# Los marcadores ADAPTADOR-MARCA son el contrato con adaptador_inspect.
set -u
nombre="$(basename "$0")"
[ -n "${FAKE_ARGV_DIR:-}" ] && printf '%s\n' "$*" >>"$FAKE_ARGV_DIR/$nombre.argv"

case " $* " in
  *" --version "*)
    case "${FAKE_HARNESS_MODE:-}" in
      quota) echo "fake-$nombre: rate limit exceeded, retry later"; exit 1;;
      auth) echo "fake-$nombre: login required"; exit 1;;
      cuota-auth)
        echo "fake-$nombre: login required"
        echo "fake-$nombre: rate limit exceeded, retry later"
        exit 1;;
      broken) exit 3;;
      blocked) echo "fake-$nombre: permission denied"; exit 0;;
      blocked-cap) echo "fake-$nombre: Permission denied"; exit 0;;

      *) echo "fake-$nombre 0.0-test"; exit 0;;
    esac
    ;;
esac

confianza() { # $1 linea que las teclas aceptadas dejan en el tty cocido
  IFS= read -r linea || exit 1
  [ "$linea" = "$1" ] || { printf 'RECHAZADO: %s\n' "$linea"; sleep 30; exit 1; }
  printf '%s\n' "$FAKE_BAR"
}
ruta="${FAKE_CONFIANZA_RUTA:-}"
case "${FAKE_HARNESS_MODE:-}" in
  confianza-claude)
    printf ' Accessing workspace:\n %s\n Claude Code'"'"'ll be able to read, edit, and execute files here.\n ❯ No, exit\n   Yes, I trust this folder\n Enter to confirm · Esc to cancel\n' "$ruta"
    confianza "$(printf '\033[B')";;
  confianza-codex)
    printf '  Folder access\n  %s\n  Trust this folder? Codex can read, edit, and run files here.\n› 1. Trust and continue\n  2. Back to Agent Command Center\n  enter continue · esc back\n' "$ruta"
    confianza "";;
  confianza-kimi)
    printf '  Trust this folder?\n  ↑↓ navigate · Enter select · Esc exit\n  %s\n   ❯ Trust this folder\n     Don'"'"'t trust\n' "$ruta"
    confianza "";;
  nobar) :;;
  *) [ -n "${FAKE_BAR:-}" ] && printf '%s\n' "$FAKE_BAR";;
esac
case "${FAKE_HARNESS_MODE:-}" in
  complete) printf 'ADAPTADOR-MARCA: completo\n';;
  waiting) printf 'ADAPTADOR-MARCA: esperando\n';;
  failed) printf 'ADAPTADOR-MARCA: fallo\n'; sleep 2; exit 1;;
  quota) printf 'fake-%s: rate limit exceeded, retry later\n' "$nombre";;
  auth) printf 'fake-%s: login required\n' "$nombre";;
  sin-uso) printf "  You're out of usage. Switch to Auto, or ask your admin to increase your limit to continue.\n";;
  cuota-auth) printf 'fake-%s: login required\nfake-%s: rate limit exceeded, retry later\n' "$nombre" "$nombre";;
  *) :;;
esac
# Como un TUI: consume el encargo por stdin y deja recibo en pantalla (la
# caja se vacia al entrar la linea); sin entrada, silencio = sigue corriendo.
while IFS= read -r linea; do
  printf 'RECIBIDO: %s\n' "$linea"
  if [ "${FAKE_HARNESS_MODE:-}" = obedece ]; then
    case "$linea" in
      *"linea sola con ADAPTADOR-MARCA seguido de dos puntos"*) printf 'ADAPTADOR-MARCA: completo\n';;
    esac
  fi
done
