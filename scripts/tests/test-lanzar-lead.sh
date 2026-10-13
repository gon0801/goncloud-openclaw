#!/usr/bin/env bash
# Prueba scripts/lanzar-lead.sh con un tmux real en un socket privado.
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
TM=${TMUX_REAL:-/opt/homebrew/bin/tmux}
[ -x "$TM" ] || { echo "ok: sin tmux en $TM, prueba saltada (declarado)"; exit 0; }
T=$(mktemp -d) || exit 1
L="ll-$$"
TMUX_BIN="$T/tmux"; printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$TM" "$L" > "$TMUX_BIN"; chmod +x "$TMUX_BIN"
export TMUX_BIN
limpia() { "$TM" -L "$L" kill-server 2>/dev/null; rm -rf "$T"; }
trap limpia EXIT
CWD="$T/wt"; mkdir -p "$CWD"

# 1. cwd inexistente → 1
out=$(bash scripts/lanzar-lead.sh -s s1 -c "$T/no-existe" -m 'hola -saikit' -- cat 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'ATORADO cwd inexistente' || fail "(1) cwd inexistente: rc=$rc $out"
echo "ok (1): cwd inexistente aborta con 1"

# 2. lanzamiento real: un CLI falso que imprime su prompt y hace eco de lo que recibe
CLI="$T/cli.sh"; printf '#!/bin/sh\nprintf "FAKE> "\nexec cat\n' > "$CLI"; chmod +x "$CLI"
out=$(bash scripts/lanzar-lead.sh -s s1 -c "$CWD" -m 'Lee el runbook y ejecuta la fase -saikit' -p 'FAKE>' -t 15 -- "$CLI" --flag-falso 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "(2) lanzamiento: rc=$rc $out"
printf '%s\n' "$out" | tail -1 | grep -qE "^LISTO s1 " || fail "(2) sin LISTO final: $out"
printf '%s\n' "$out" | grep -q 'marca=OPENCLAW_WATCH=1' || fail "(2) la sesión no quedó marcada: $out"
printf '%s\n' "$out" | grep -q -- '--flag-falso' || fail "(2) el flag no aparece en la línea del proceso: $out"
real=$("$TMUX_BIN" display-message -p -t s1 '#{pane_current_path}')
[ "$(cd "$real" && pwd -P)" = "$(cd "$CWD" && pwd -P)" ] || fail "(2) cwd del proceso: $real"
"$TMUX_BIN" capture-pane -p -t s1 | grep -q 'ejecuta la fase -saikit' || fail "(2) el mensaje no llegó a la pantalla"
echo "ok (2): crea la sesión en el cwd, la marca, espera el prompt y el mensaje entra con su sentinel"

# 3. relanzar con la sesión viva → 2, sin tocarla
out=$(bash scripts/lanzar-lead.sh -s s1 -c "$CWD" -m 'otra -saikit' -- "$CLI" 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'YA-EXISTE s1' || fail "(3) sesión viva: rc=$rc $out"
echo "ok (3): con la sesión viva no relanza (YA-EXISTE, rc 2)"

# 4. prompt que nunca llega → 4 (el CLI falso no imprime nada)
CLI2="$T/mudo.sh"; printf '#!/bin/sh\nexec cat\n' > "$CLI2"; chmod +x "$CLI2"
out=$(bash scripts/lanzar-lead.sh -s s2 -c "$CWD" -m 'x -saikit' -p 'NUNCA>' -t 3 -- "$CLI2" 2>&1); rc=$?
[ "$rc" -eq 4 ] && printf '%s\n' "$out" | grep -q 'ATORADO sin prompt' || fail "(4) sin prompt: rc=$rc $out"
echo "ok (4): sin prompt no manda nada y sale con 4"

echo "TODO VERDE: lanzar-lead"
