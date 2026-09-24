#!/bin/bash
# Fase 9.9: el TUI de mentira responde a teclas. Prueba directa del fixture, sin
# tmux: una tecla recibida por su stdin queda en teclas.log y, si hay
# al-aceptar.txt, la pantalla cambia; sin teclas, la pantalla no cambia.
# Uso: bash scripts/tests/test-tui-falso-fixture.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

FIX=scripts/tests/fixtures/tui-falso.sh
[ -x "$FIX" ] || fail "falta $FIX"

T=$(mktemp -d) || exit 1
PIDF="$T/pid"
trap '[ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -rf "$T"' EXIT

printf 'Do you trust this folder? %s\nEnter to confirm . Esc to cancel\n' "$T" >"$T/pantalla.txt"
printf 'confiado\n' >"$T/al-aceptar.txt"

mkfifo "$T/entrada" || fail "no se pudo crear el fifo de entrada"
# stdin queda abierto (el fifo no cierra) hasta que se manda una tecla, asi el
# fixture no ve EOF y sigue vivo esperando la siguiente lectura.
( exec 3<>"$T/entrada"; "$FIX" "$T" <&3 >"$T/salida.log" 2>&1 & echo $! >"$PIDF"; wait ) &
sleep 0.5
[ -f "$PIDF" ] || fail "el fixture no arranco"

# (1) sin teclas: ni teclas.log ni cambio de pantalla. El primer pintado llega
# despues del primer read (tope de 1s sin tecla), asi que hay que esperarlo.
sleep 1.5
[ -f "$T/teclas.log" ] && fail "sin teclas de humano, tui-falso ya escribio teclas.log"
grep -q 'confiado' "$T/salida.log" 2>/dev/null && fail "sin teclas, la pantalla ya cambio"
grep -q 'Do you trust' "$T/salida.log" || fail "la pantalla base nunca se pinto"

# (2) una tecla: queda en teclas.log (con epoch) y la pantalla cambia a al-aceptar.
printf '\r' >"$T/entrada" &
sleep 1.5
[ -s "$T/teclas.log" ] || fail "la tecla no quedo registrada en teclas.log"
grep -qE '^[0-9]+ ' "$T/teclas.log" || fail "teclas.log no trae el epoch de la tecla"
grep -q 'confiado' "$T/salida.log" || fail "la tecla no hizo que la pantalla cambiara a al-aceptar.txt"

echo OK
