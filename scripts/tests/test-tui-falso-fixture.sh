#!/bin/bash
# Fase 9.9: el TUI de mentira responde a teclas, y SOLO a las que le tocan.
# Prueba directa del fixture, sin tmux: sin teclas la pantalla no cambia; toda
# tecla recibida queda en teclas.log; Enter (cadena vacia bajo `read -n1` —
# medido con tmux real: el CR que manda `send-keys Enter` se pierde como
# delimitador de read) "acepta" (copia al-aceptar.txt); Escape ($'\e', tambien
# medido con tmux real) "cancela" (copia al-cancelar.txt si existe) y NUNCA
# acepta; cualquier otra tecla no cambia nada.
# Uso: bash scripts/tests/test-tui-falso-fixture.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

FIX=scripts/tests/fixtures/tui-falso.sh
[ -x "$FIX" ] || fail "falta $FIX"

T=$(mktemp -d) || exit 1
PIDF="$T/pid"
trap '[ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -rf "$T"' EXIT

# Sondeo con tope, en vez de esperas fijas: sleep si soporta fraccion aqui
# (es el /bin/sleep del sistema, no el `read -t` de bash 3.2 que si lo rechaza).
espera() { # $1 archivo, $2 patron (grep -F), $3 tope en segundos (def. 10)
  local f="$1" pat="$2" tope="${3:-10}" ini=$SECONDS
  while [ "$((SECONDS - ini))" -lt "$tope" ]; do
    grep -qF -- "$pat" "$f" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

printf 'Do you trust this folder? %s\nEnter to confirm . Esc to cancel\n' "$T" >"$T/pantalla.txt"
printf 'confiado\n' >"$T/al-aceptar.txt"

mkfifo "$T/entrada" || fail "no se pudo crear el fifo de entrada"
# stdin queda abierto (el fifo no cierra) hasta que se manda una tecla, asi el
# fixture no ve EOF y sigue vivo esperando la siguiente lectura.
( exec 3<>"$T/entrada"; "$FIX" "$T" <&3 >"$T/salida.log" 2>&1 & echo $! >"$PIDF"; wait ) &
sleep 0.5
[ -f "$PIDF" ] || fail "el fixture no arranco"

# (1) sin teclas: pantalla base pintada, ni teclas.log ni cambio de pantalla.
espera "$T/salida.log" "Do you trust" 10 || fail "la pantalla base nunca se pinto"
[ -f "$T/teclas.log" ] && fail "sin teclas de humano, tui-falso ya escribio teclas.log"
grep -q 'confiado' "$T/salida.log" 2>/dev/null && fail "sin teclas, la pantalla ya cambio"

# (2) Escape: queda en teclas.log pero NUNCA acepta (sin al-cancelar.txt, la
# pantalla se queda como estaba).
printf '\033' >"$T/entrada" &
ini=$SECONDS
while [ ! -s "$T/teclas.log" ] && [ "$((SECONDS - ini))" -lt 5 ]; do sleep 0.2; done
[ -s "$T/teclas.log" ] || fail "Escape no quedo registrado en teclas.log"
grep -qE '^[0-9]+ .' "$T/teclas.log" || fail "teclas.log no trae el epoch de Escape"
sleep 1.2
grep -q 'confiado' "$T/salida.log" && fail "Escape acepto el dialogo (copio al-aceptar.txt): mutacion sin distinguir la tecla"

# (2b) Escape CON al-cancelar.txt presente: ahi si cancela.
printf 'cancelado\n' >"$T/al-cancelar.txt"
printf '\033' >"$T/entrada" &
espera "$T/salida.log" "cancelado" 5 || fail "Escape con al-cancelar.txt no cambio la pantalla a cancelado"
grep -q 'confiado' "$T/salida.log" && fail "Escape con al-cancelar.txt tambien acepto (no debia)"

# (3) Enter (cadena vacia, ver comentario de cabecera): acepta de verdad.
rm -f "$T/al-cancelar.txt"
printf '\n' >"$T/entrada" &
espera "$T/salida.log" "confiado" 5 || fail "Enter no hizo que la pantalla cambiara a al-aceptar.txt"
n_antes=$(wc -l <"$T/teclas.log")
[ "$n_antes" -ge 2 ] || fail "Enter no quedo registrado en teclas.log"

echo OK
