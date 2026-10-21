#!/bin/bash
# Prueba scripts/mac/shopify-token/renueva.sh contra un servidor HTTP local falso (python3 con
# handler propio) y un `curl` falso para Telegram (los demás curl pasan al real).
# Casos: (1) todo bien; (2) Shopify da 400; (3) token nuevo pero shop.json da 401; (4) archivo en
# UTF-16; (5) ninguna salida contiene la clave ni los tokens.
# Uso: bash scripts/tests/test-shopify-token.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RENUEVA=$PWD/scripts/mac/shopify-token/renueva.sh
[ -f "$RENUEVA" ] || { echo "FAIL: falta $RENUEVA"; exit 1; }
T=$(mktemp -d); SRV_PID=
parar() { [ -n "$SRV_PID" ] && { kill "$SRV_PID"; wait "$SRV_PID"; } 2>/dev/null; SRV_PID=; }
trap 'parar; rm -rf "$T"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CLIENT_ID=cid-prueba-8f31
SECRET=shpss_SECRETO_de_prueba_93ac
NUEVO=shpat_TOKEN_NUEVO_5d27
VIEJO=shpat_TOKEN_VIEJO_0b11

cat > "$T/server.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
MODE = os.environ["FAKE_MODE"]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        good = (self.path == "/admin/oauth/access_token" and body.get("grant_type") == "client_credentials"
                and body.get("client_id") == os.environ["FAKE_CID"] and body.get("client_secret") == os.environ["FAKE_SECRET"])
        if MODE == "400" or not good:
            return self._send(400, {"error": "invalid_request"})
        self._send(200, {"access_token": os.environ["FAKE_TOKEN"], "scope": "read_products"})
    def do_GET(self):
        ok = (self.path == "/admin/api/2025-10/shop.json"
              and self.headers.get("X-Shopify-Access-Token") == os.environ["FAKE_TOKEN"])
        if MODE == "shop401" or not ok:
            return self._send(401, {"errors": "Unauthorized"})
        self._send(200, {"shop": {"name": "x"}})
s = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
PY

# curl falso: lo que va a api.telegram.org se anota; lo demás pasa al curl real.
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
cfg=$(cat)
case "$cfg" in
  *api.telegram.org*) printf 'AVISO %s\n' "$cfg" >> "$AVISOS"; exit 0 ;;
esac
printf '%s\n' "$cfg" | /usr/bin/curl "$@"
SH
chmod +x "$T/bin/curl"
printf 'TELEGRAM_BOT_TOKEN=123456:BOT-de-prueba\nOTRA=1\n' > "$T/env"

SALIDAS=$T/salidas.txt; : > "$SALIDAS"
# corre CASO MODO [utf16]: deja $T/rc, $T/out, $T/avisos y el token en $T/token.txt
corre() {
  local modo=$2 enc=${3:-utf8}
  parar
  rm -f "$T/port"
  FAKE_MODE=$modo FAKE_CID=$CLIENT_ID FAKE_SECRET=$SECRET FAKE_TOKEN=$NUEVO python3 "$T/server.py" "$T/port" &
  SRV_PID=$!
  for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
  [ -s "$T/port" ] || fail "caso $1: el servidor falso no arrancó"
  local json="{\"store\":\"tienda-falsa.myshopify.com\",\"client_id\":\"$CLIENT_ID\",\"client_secret\":\"$SECRET\"}"
  if [ "$enc" = utf16 ]; then printf '%s' "$json" | iconv -f UTF-8 -t UTF-16 > "$T/app.json"
  else printf '%s' "$json" > "$T/app.json"; fi
  printf '%s' "$VIEJO" > "$T/token.txt"; chmod 600 "$T/token.txt"
  : > "$T/avisos"
  AVISOS=$T/avisos PATH="$T/bin:$PATH" SHOPIFY_APP_JSON=$T/app.json SHOPIFY_TOKEN_FILE=$T/token.txt \
    OPENCLAW_ENV=$T/env SHOPIFY_BASE=http://127.0.0.1:$(cat "$T/port") \
    bash "$RENUEVA" > "$T/out" 2>&1
  echo $? > "$T/rc"
  { cat "$T/out"; cat "$T/avisos"; } >> "$SALIDAS"
}
perm() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
nuevos_avisos() { grep -c '^AVISO' "$T/avisos"; }

# (1) todo bien
corre 1 ok
[ "$(cat "$T/rc")" = 0 ] || fail "caso 1: debía salir 0 ($(cat "$T/out"))"
[ "$(cat "$T/token.txt")" = "$NUEVO" ] || fail "caso 1: el token guardado no es el nuevo"
[ "$(perm "$T/token.txt")" = 600 ] || fail "caso 1: permisos del token ≠ 600"
[ "$(nuevos_avisos)" = 0 ] || fail "caso 1: no debía avisar"
[ -z "$(ls -A "$T" | grep -E '^\.shopify_token')" ] || fail "caso 1: quedó un temporal"
echo "ok 1 todo bien"

# (2) Shopify da 400
corre 2 400
[ "$(cat "$T/rc")" != 0 ] || fail "caso 2: debía salir ≠0"
[ "$(cat "$T/token.txt")" = "$VIEJO" ] || fail "caso 2: tocó el token anterior"
[ "$(nuevos_avisos)" = 1 ] || fail "caso 2: debía mandar un aviso"
grep -q 'token anterior sigue' "$T/avisos" || fail "caso 2: el aviso no dice que el token anterior sigue"
echo "ok 2 Shopify 400"

# (3) token nuevo pero shop.json da 401
corre 3 shop401
[ "$(cat "$T/rc")" != 0 ] || fail "caso 3: debía salir ≠0"
[ "$(cat "$T/token.txt")" = "$VIEJO" ] || fail "caso 3: guardó un token que no pasó la prueba"
[ "$(nuevos_avisos)" = 1 ] || fail "caso 3: debía mandar un aviso"
grep -q 'chat_id=6470689715' "$T/avisos" || fail "caso 3: el aviso no va al chat de David"
echo "ok 3 shop.json 401"

# (4) archivo UTF-16
corre 4 ok utf16
[ "$(cat "$T/rc")" = 0 ] || fail "caso 4: no leyó el archivo UTF-16 ($(cat "$T/out"))"
[ "$(cat "$T/token.txt")" = "$NUEVO" ] || fail "caso 4: token no renovado"
echo "ok 4 UTF-16"

# (5) ni la clave ni los tokens en ninguna salida (de los 4 casos)
[ -s "$SALIDAS" ] || fail "caso 5: no se capturó ninguna salida"
for s in "$SECRET" "$NUEVO" "$VIEJO"; do
  grep -qF "$s" "$SALIDAS" && fail "caso 5: una salida contiene un valor de credencial"
done
grep -q '^AVISO' "$SALIDAS" || fail "caso 5: no hubo avisos que revisar"
echo "ok 5 sin credenciales en salidas"
echo "PASS test-shopify-token"
