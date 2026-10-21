#!/usr/bin/env bash
# B.1: árbol falso con una clave tapada, una vacía, un UTF-16 y una sana.
set -u
cd "$(dirname "$0")/../.." || exit 1
S=scripts/mac/credenciales-tapadas.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/credentials" "$T/workspace-x" "$T/workspace-a"
printf 'QmFzZTY0VmFsb3I=\n' > "$T/workspace-a/.env"
printf 'QmFzZTY0VmFsb3J0b3A=\n' >> "$T/.env"
printf 'TAPADA_KEY=*****\nVACIA_KEY=\nSANA_KEY=valorsecreto123\n' > "$T/.env"
printf 'UTF16_KEY=hola\n' | iconv -f UTF-8 -t UTF-16 > "$T/workspace-x/.env"
echo '{"a":{"apiKey":"valorjson999"}}' > "$T/openclaw.json"
mkdir -p "$T/workspace-b"; printf 'JBSWY3DPEHPK3PXP=\n' > "$T/workspace-b/.env"
printf 'abc=\n' > "$T/credentials/abc.token"
printf 'dGVzdF9_c2VjcmV0X3ZhbG9y=\n' > "$T/credentials/relay.secret"
printf 'TELEGRAM_BOT_TOKEN=\n' > "$T/credentials/telegram"
printf -- '-----BEGIN PRIVATE KEY-----\nMIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6AgEAAkEAxyz\nQ0E=\n-----END PRIVATE KEY-----\n' > "$T/credentials/key.pem"
mkdir -p "$T/workspace-q"; printf 'MFRGGZA=\n' > "$T/workspace-q/.env"
mkdir -p "$T/workspace-w"; printf 'c2Vj_cmV0bw=\n' > "$T/workspace-w/.env"
fails=0
chk() { if eval "$2"; then echo "OK: $1"; else echo "FALLO: $1"; fails=$((fails+1)); fi; }
out=$(OPENCLAW_HOME="$T" bash "$S" 2>&1)
chk "lista la tapada" 'echo "$out" | grep -q "TAPADA_KEY"'
chk "lista la vacía" 'echo "$out" | grep -q "VACIA_KEY"'
chk "lista el UTF-16" 'echo "$out" | grep -q "workspace-x/.env"'
chk "no lista la sana" '! echo "$out" | grep -q "SANA_KEY"'
chk "valor con '=' final no se lista ni se imprime" '! echo "$out" | grep -Eq "relay.secret|abc"'
chk "valor suelto con '=' en .env: no se imprime el texto, solo la línea" '! echo "$out" | grep -q "QmFzZTY0" && echo "$out" | grep -q "workspace-a/.env.*línea 1.*vacia?"'
chk "base32 con '=' final en .env: no se imprime el texto, solo la línea" '! echo "$out" | grep -q "JBSWY3DPEHPK3PXP" && echo "$out" | grep -q "workspace-b/.env.*línea 1.*vacia?"'
chk "una sola línea CLAVE= en credentials/ se lista" 'echo "$out" | grep -q "credentials/telegram.*TELEGRAM_BOT_TOKEN"'
chk "última línea de un PEM no se imprime" '! echo "$out" | grep -q "Q0E"'
chk "base32 corto MFRGGZA= no se imprime" '! echo "$out" | grep -q "MFRGGZA"'
chk "base64url con '_' y '=' en credentials/ no se imprime" '! echo "$out" | grep -q "dGVzdF9_c2VjcmV0X3ZhbG9y=" && ! echo "$out" | grep -q "relay.secret"'
chk "base64url con '_' y '=' suelto en workspace .env no se imprime" '! echo "$out" | grep -q "c2Vj_cmV0bw="'
chk "ningún valor en la salida" '! echo "$out" | grep -Eq "valorsecreto123|valorjson999|\*\*\*"'
res=$(OPENCLAW_HOME="$T" bash "$S" --resumen); rc=$?
chk "--resumen cuenta 8 y sale 0" '[ "$rc" = 0 ] && [ "$res" = "credenciales tapadas: 8" ]'
# archivo ilegible: se lista y no aborta el escaneo de los siguientes
U=$(mktemp -d); mkdir -p "$U/credentials" "$U/workspace-z"
printf 'A_TOKEN=\n' > "$U/credentials/a.txt"; chmod 000 "$U/credentials/a.txt"
printf 'B_TOKEN=***\n' > "$U/workspace-z/.env"
uo=$(OPENCLAW_HOME="$U" bash "$S" 2>&1); urc=$?
chmod 600 "$U/credentials/a.txt"; rm -rf "$U"
chk "ilegible se lista y sigue con los demás" 'echo "$uo" | grep -q "a.txt.*ilegible" && echo "$uo" | grep -q "B_TOKEN" && [ "$urc" = 1 ]'
[ "$fails" = 0 ] && echo "TODO OK" || { echo "$fails fallos"; exit 1; }
