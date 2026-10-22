#!/bin/bash
# scripts/gonserver/actualiza-nextcloud contra un docker falso y un Telegram falso:
#
#   1. La imagen bajada es la misma que corre: sale 0 sin respaldo, sin reinicio y sin aviso.
#   2. Imagen nueva: respaldo ANTES del reinicio, espera a que salga de mantenimiento, sale 0 sin aviso.
#   3. El respaldo falla: no reinicia, avisa nombrando el paso y sale 1.
#   4. Sigue en mantenimiento al acabarse la espera: avisa y sale 1.
#   5. Falla y Telegram no contesta: sale 2 y el token no aparece en ninguna salida.
#   6. --prueba-aviso manda un solo aviso y sale 0.
#
# Uso: bash scripts/tests/test-actualiza-nextcloud.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
A="$PWD/scripts/gonserver/actualiza-nextcloud"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

SB="$(mktemp -d)"
MOCK_PID=""
trap '[ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$SB"' EXIT
F="$SB/falso"; NC="$SB/nc"; mkdir -p "$F" "$NC"
TOKEN="123456:secreto-de-prueba"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=42\n' "$TOKEN" > "$SB/env"
printf 'services: {}\n' > "$NC/docker-compose.yml"
cat > "$NC/nextcloud_backup.sh" <<'B'
echo respaldo >> "$FALSO/llamadas"
[ ! -e "$FALSO/falla-respaldo" ]
B
cat > "$F/docker" <<'D'
#!/bin/bash
echo "$*" >> "$FALSO/llamadas"
case "$*" in
  "inspect nextcloud-app --format {{.Image}}") cat "$FALSO/corriendo" ;;
  *" pull -q app") cp "$FALSO/remota" "$FALSO/local" ;;
  *" config --format json") echo '{"services":{"app":{"image":"nextcloud:33-apache"}}}' ;;
  "image inspect nextcloud:33-apache --format {{.Id}}") cat "$FALSO/local" ;;
  *" up -d app") cp "$FALSO/local" "$FALSO/corriendo"; echo reinicio >> "$FALSO/llamadas" ;;
  "exec -u www-data nextcloud-app php occ status --output=json") cat "$FALSO/estado" ;;
  "exec nextcloud-app php -r echo PHP_VERSION;") printf '8.4.27' ;;
  *) echo "docker falso: no sé hacer: $*" >&2; exit 9 ;;
esac
D
chmod +x "$F/docker"

# Telegram de mentira en 127.0.0.1, como en test-respaldo-gonserver.sh: registra cada POST y responde ok.
cat > "$SB/tg.py" <<'E'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
sb = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        cuerpo = self.rfile.read(int(self.headers["Content-Length"])).decode()
        with open(f"{sb}/tg.log", "a") as f:
            f.write(json.dumps({"path": self.path, "body": json.loads(cuerpo)}) + "\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"ok":true,"result":{}}')
    def log_message(self, *a):
        pass
s = HTTPServer(("127.0.0.1", 0), H)
open(f"{sb}/tg.port", "w").write(str(s.server_port))
s.serve_forever()
E
python3 "$SB/tg.py" "$SB" & MOCK_PID=$!
for _ in $(seq 50); do [ -s "$SB/tg.port" ] && break; sleep 0.1; done
[ -s "$SB/tg.port" ] || fail "no arrancó el Telegram de mentira"
PORT=$(cat "$SB/tg.port")

correr() { # deja la salida en $SB/out y el rc en $RC
  : > "$F/llamadas"; : > "$SB/tg.log"
  FALSO="$F" ACTUALIZA_NC="$NC" ACTUALIZA_DOCKER="$F/docker" ACTUALIZA_ENV="$SB/env" \
    ACTUALIZA_API="${API:-http://127.0.0.1:$PORT}" ACTUALIZA_ESPERA_S="${ESPERA:-5}" ACTUALIZA_PASO_S=0.1 \
    python3 "$A" "$@" > "$SB/out" 2>&1
  RC=$?
}
avisos() { [ -s "$SB/tg.log" ] && wc -l < "$SB/tg.log" | tr -d ' ' || echo 0; }
OK='{"installed":true,"versionstring":"33.0.11","maintenance":false,"needsDbUpgrade":false}'
MANT='{"installed":true,"versionstring":"33.0.11","maintenance":true,"needsDbUpgrade":true}'

# 1
echo sha256:vieja > "$F/corriendo"; echo sha256:vieja > "$F/remota"; echo "$OK" > "$F/estado"
correr
[ "$RC" -eq 0 ] || { cat "$SB/out"; fail "al día no salió 0 (rc=$RC)"; }
grep -q "al día" "$SB/out" || fail "al día no lo dijo: $(cat "$SB/out")"
grep -qE "respaldo|reinicio" "$F/llamadas" && fail "al día respaldó o reinició"
[ "$(avisos)" = 0 ] || fail "al día mandó un aviso"

# 2
echo sha256:nueva > "$F/remota"
correr
[ "$RC" -eq 0 ] || { cat "$SB/out"; fail "la actualización buena no salió 0 (rc=$RC)"; }
orden=$(grep -nE "^(respaldo|reinicio)$" "$F/llamadas" | cut -d: -f2 | tr '\n' ' ')
[ "$orden" = "respaldo reinicio " ] || fail "el respaldo no fue antes del reinicio: '$orden'"
grep -q "actualizado: Nextcloud 33.0.11 con PHP 8.4.27" "$SB/out" || fail "no dijo con qué quedó: $(cat "$SB/out")"
[ "$(avisos)" = 0 ] || fail "la actualización buena mandó un aviso"

# 3
echo sha256:vieja > "$F/corriendo"; touch "$F/falla-respaldo"
correr
[ "$RC" -eq 1 ] || { cat "$SB/out"; fail "el respaldo fallido no salió 1 (rc=$RC)"; }
grep -q reinicio "$F/llamadas" && fail "reinició aunque el respaldo falló"
[ "$(avisos)" = 1 ] || fail "el respaldo fallido no avisó una vez"
python3 - "$SB/tg.log" "$TOKEN" <<'E' || fail "el aviso no es el esperado: $(cat "$SB/tg.log")"
import json, sys
d = json.loads(open(sys.argv[1]).readline())
assert d["path"] == f"/bot{sys.argv[2]}/sendMessage", d["path"]
b = d["body"]
assert b["chat_id"] == "42" and b["parse_mode"] == "HTML", b
assert "sacar el respaldo" in b["text"], b["text"]
E
grep -q "sacar el respaldo" "$SB/out" || fail "no nombró el paso que falló: $(cat "$SB/out")"
rm "$F/falla-respaldo"

# 4
echo sha256:vieja > "$F/corriendo"; echo "$MANT" > "$F/estado"
ESPERA=0.5 correr
[ "$RC" -eq 1 ] || { cat "$SB/out"; fail "mantenimiento eterno no salió 1 (rc=$RC)"; }
grep -q "mantenimiento" "$SB/out" || fail "no dijo que quedó en mantenimiento: $(cat "$SB/out")"
[ "$(avisos)" = 1 ] || fail "mantenimiento eterno no avisó una vez"

# 5
echo sha256:vieja > "$F/corriendo"; touch "$F/falla-respaldo"
API="http://127.0.0.1:9" correr
[ "$RC" -eq 2 ] || { cat "$SB/out"; fail "sin Telegram no salió 2 (rc=$RC)"; }
grep -q "$TOKEN" "$SB/out" && fail "el token apareció en la salida"
rm "$F/falla-respaldo"

# 6
correr --prueba-aviso
[ "$RC" -eq 0 ] || { cat "$SB/out"; fail "--prueba-aviso no salió 0 (rc=$RC)"; }
[ "$(avisos)" = 1 ] || fail "--prueba-aviso no mandó exactamente un aviso"
[ -s "$F/llamadas" ] && fail "--prueba-aviso tocó docker"

echo "OK: test-actualiza-nextcloud (6 casos)"
