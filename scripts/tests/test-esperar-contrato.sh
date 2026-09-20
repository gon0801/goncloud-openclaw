#!/usr/bin/env bash
# Prueba scripts/esperar-contrato.sh: contrato por archivo, tope y prueba de vida.
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
TM=${TMUX_REAL:-/opt/homebrew/bin/tmux}
T=$(mktemp -d) || exit 1
L="ec-$$"
TMUX_BIN="$T/tmux"; printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$TM" "$L" > "$TMUX_BIN"; chmod +x "$TMUX_BIN"
export TMUX_BIN INTERVALO=1 INTERVALO_VIDA=2
limpia() { "$TM" -L "$L" kill-server 2>/dev/null; rm -rf "$T"; }
trap limpia EXIT
F="$T/contrato.txt"

# 1. archivo ausente, sin sesión → SIN-CONTRATO, 124
out=$(bash scripts/esperar-contrato.sh "$F" -t 2 2>&1); rc=$?
[ "$rc" -eq 124 ] && [ "$out" = "SIN-CONTRATO" ] || fail "(1) tope sin sesión: rc=$rc $out"
echo "ok (1): sin archivo y sin sesión vence el tope con 124"

# 2. archivo vacío no cuenta (touch); con contenido sangrado sí, y se limpia la sangría
: > "$F"
out=$(bash scripts/esperar-contrato.sh "$F" -t 2 2>&1); rc=$?
[ "$rc" -eq 124 ] || fail "(2a) un archivo vacío no es contrato: rc=$rc $out"
printf '  LISTO abc1234\n' > "$F"
out=$(bash scripts/esperar-contrato.sh "$F" -t 2 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "LISTO abc1234" ] || fail "(2b) contrato sangrado: rc=$rc [$out]"
echo "ok (2): touch no cuenta; la línea sangrada se lee limpia"

# 3. contenido que no es contrato → 5
printf 'hola, ya casi\n' > "$F"
out=$(bash scripts/esperar-contrato.sh "$F" -t 2 2>&1); rc=$?
[ "$rc" -eq 5 ] && printf '%s\n' "$out" | grep -q '^ATORADO sin reporte: hola' || fail "(3) sin reporte: rc=$rc $out"
echo "ok (3): una línea que no es LISTO/ATORADO es 'sin reporte' (rc 5)"

# 4. prueba de vida: pantalla que cambia → VIVA (3); pantalla quieta → QUIETA (4)
[ -x "$TM" ] || { echo "ok (4): sin tmux, prueba de vida saltada (declarado)"; echo "TODO VERDE: esperar-contrato"; exit 0; }
rm -f "$F"
"$TMUX_BIN" new-session -d -s viva -x 80 -y 20 'while true; do date +%N; sleep 1; done'
"$TMUX_BIN" new-session -d -s quieta -x 80 -y 20 'cat'
sleep 1
out=$(bash scripts/esperar-contrato.sh "$F" -t 1 -s viva 2>&1); rc=$?
[ "$rc" -eq 3 ] && [ "$out" = "SIN-CONTRATO VIVA" ] || fail "(4a) viva: rc=$rc $out"
out=$(bash scripts/esperar-contrato.sh "$F" -t 1 -s quieta 2>&1); rc=$?
[ "$rc" -eq 4 ] && [ "$out" = "SIN-CONTRATO QUIETA" ] || fail "(4b) quieta: rc=$rc $out"
echo "ok (4): al vencer el tope distingue pantalla viva (3) de pantalla quieta (4)"

echo "TODO VERDE: esperar-contrato"
