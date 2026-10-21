#!/usr/bin/env bash
# B.1: árbol falso con una clave tapada, una vacía, un UTF-16 y una sana.
set -u
cd "$(dirname "$0")/../.." || exit 1
S=scripts/mac/credenciales-tapadas.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/credentials" "$T/workspace-x"
printf 'TAPADA_KEY=*****\nVACIA_KEY=\nSANA_KEY=valorsecreto123\n' > "$T/.env"
printf 'UTF16_KEY=hola\n' | iconv -f UTF-8 -t UTF-16 > "$T/workspace-x/.env"
echo '{"a":{"apiKey":"valorjson999"}}' > "$T/openclaw.json"
fails=0
chk() { if eval "$2"; then echo "OK: $1"; else echo "FALLO: $1"; fails=$((fails+1)); fi; }
out=$(OPENCLAW_HOME="$T" bash "$S" 2>&1)
chk "lista la tapada" 'echo "$out" | grep -q "TAPADA_KEY"'
chk "lista la vacía" 'echo "$out" | grep -q "VACIA_KEY"'
chk "lista el UTF-16" 'echo "$out" | grep -q "workspace-x/.env"'
chk "no lista la sana" '! echo "$out" | grep -q "SANA_KEY"'
chk "ningún valor en la salida" '! echo "$out" | grep -Eq "valorsecreto123|valorjson999|\*\*\*"'
res=$(OPENCLAW_HOME="$T" bash "$S" --resumen); rc=$?
chk "--resumen cuenta 3 y sale 0" '[ "$rc" = 0 ] && [ "$res" = "credenciales tapadas: 3" ]'
[ "$fails" = 0 ] && echo "TODO OK" || { echo "$fails fallos"; exit 1; }
