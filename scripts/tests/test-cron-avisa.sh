#!/bin/bash
# scripts/gonserver/cron-avisa contra un Telegram falso y una carpeta de estado temporal:
#
#   1. Un comando que sale 0 no avisa.
#   2. Uno que sale 3 avisa una vez y sale 3.
#   3. Tres fallos seguidos con --tras 3 avisan solo al tercero.
#   4. Fallo y luego éxito manda el aviso de "ya volvió".
#   5. El código 75 no avisa y no cambia la racha.
#   6. La salida del comando llega intacta.
#   7. --revisa avisa de un estado viejo, calla con uno fresco y --seco no avisa.
#   8. Ningún aviso contiene la ruta del comando ni el token.
#   9. Si Telegram no contesta, el código del comando no cambia y el token no se imprime.
#
# Uso: bash scripts/tests/test-cron-avisa.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
C="$PWD/scripts/gonserver/cron-avisa"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

SB="$(mktemp -d)"
MOCK_PID=""
trap '[ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$SB"' EXIT
EST="$SB/estado"
TOKEN="123456:secreto-de-prueba"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=42\n' "$TOKEN" > "$SB/env"
CMD="$SB/ruta-secreta-del-comando"
cat > "$CMD" <<'S'
#!/bin/bash
echo "salida uno"
echo "salida error" >&2
exit "${1:-0}"
S
chmod +x "$CMD"

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

correr() { # correr <args…>: deja la salida en $SB/out y el rc en $RC
  : > "$SB/tg.log"
  CRON_AVISA_ESTADO="$EST" CRON_AVISA_ENV="$SB/env" \
    CRON_AVISA_API="${API:-http://127.0.0.1:$PORT}" python3 "$C" "$@" > "$SB/out" 2>&1
  RC=$?
}
avisos() { [ -s "$SB/tg.log" ] && wc -l < "$SB/tg.log" | tr -d ' ' || echo 0; }
texto() { python3 -c 'import json,sys; print(json.loads(sys.stdin.readlines()[int(sys.argv[1])])["body"]["text"])' "$1" < "$SB/tg.log"; }
estado() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$EST/$1.json" "$2"; }
reset() { rm -rf "$EST"; }

# 1
reset
correr --nombre "Copia de prueba" --cada 24 -- "$CMD" 0
[ "$RC" -eq 0 ] || fail "éxito no salió 0 (rc=$RC)"
[ "$(avisos)" = 0 ] || fail "el éxito mandó un aviso"
[ "$(estado copia-de-prueba codigo)" = 0 ] || fail "el estado no guardó el código"
[ "$(estado copia-de-prueba cada)" = 24.0 ] || fail "el estado no guardó cada"
[ "$(estado copia-de-prueba nombre)" = "Copia de prueba" ] || fail "el estado no guardó el nombre"
ls "$EST" | grep -q tmp && fail "quedó un temporal en la carpeta de estado"

# 2
reset
correr --nombre "Copia de prueba" --cada 24 -- "$CMD" 3
[ "$RC" -eq 3 ] || fail "el fallo no salió 3 (rc=$RC)"
[ "$(avisos)" = 1 ] || fail "el fallo no avisó una vez"
[ "$(texto 0)" = "• Copia de prueba: su última corrida falló." ] || fail "texto del fallo: $(texto 0)"
python3 - "$SB/tg.log" "$TOKEN" <<'E' || fail "el aviso no va al bot y chat esperados: $(cat "$SB/tg.log")"
import json, sys
d = json.loads(open(sys.argv[1]).readline())
assert d["path"] == f"/bot{sys.argv[2]}/sendMessage", d["path"]
assert d["body"]["chat_id"] == "42", d["body"]
E
correr --nombre "Copia de prueba" --cada 24 -- "$CMD" 3
[ "$RC" -eq 3 ] && [ "$(avisos)" = 0 ] || fail "el segundo fallo seguido volvió a avisar (rc=$RC)"

# 3
reset
for n in 1 2 3; do
  correr --nombre "Tres fallos" --cada 24 --tras 3 -- "$CMD" 2
  [ "$RC" -eq 2 ] || fail "fallo $n no salió 2"
  if [ "$n" -lt 3 ]; then [ "$(avisos)" = 0 ] || fail "avisó en el fallo $n de 3"; fi
done
[ "$(avisos)" = 1 ] || fail "no avisó al tercer fallo"
[ "$(estado tres-fallos fallos)" = 3 ] || fail "la racha no es 3"
correr --nombre "Tres fallos" --cada 24 --tras 3 -- "$CMD" 2
[ "$(avisos)" = 0 ] || fail "avisó otra vez en el cuarto fallo"

# 4
reset
correr --nombre "Sube y baja" --cada 24 -- "$CMD" 1
correr --nombre "Sube y baja" --cada 24 -- "$CMD" 0
[ "$RC" -eq 0 ] || fail "la recuperación no salió 0"
[ "$(avisos)" = 1 ] || fail "la recuperación no avisó una vez"
[ "$(texto 0)" = "• Sube y baja: ya volvió a correr bien." ] || fail "texto de recuperación: $(texto 0)"
[ "$(estado sube-y-baja fallos)" = 0 ] || fail "la racha no se reinició"
correr --nombre "Sube y baja" --cada 24 -- "$CMD" 0
[ "$(avisos)" = 0 ] || fail "un segundo éxito volvió a avisar"
reset
correr --nombre "Sin aviso previo" --cada 24 --tras 3 -- "$CMD" 1
correr --nombre "Sin aviso previo" --cada 24 --tras 3 -- "$CMD" 0
[ "$(avisos)" = 0 ] || fail "avisó que volvió sin haber avisado del fallo"

# 5
reset
correr --nombre "Con candado" --cada 24 --tras 2 -- "$CMD" 1
correr --nombre "Con candado" --cada 24 --tras 2 -- "$CMD" 75
[ "$RC" -eq 75 ] || fail "75 no salió 75 (rc=$RC)"
[ "$(avisos)" = 0 ] || fail "75 avisó"
[ "$(estado con-candado fallos)" = 1 ] || fail "75 cambió la racha"
correr --nombre "Con candado" --cada 24 --tras 2 -- "$CMD" 1
[ "$(avisos)" = 1 ] || fail "el 75 entre dos fallos rompió la racha"
correr --nombre "Con candado" --cada 24 --tras 2 -- "$CMD" 75
[ "$(avisos)" = 0 ] || fail "75 después de avisar mandó aviso"
[ "$(estado con-candado fallos)" = 2 ] || fail "75 tras el aviso cambió la racha"
reset
correr --nombre "Primera saltada" --cada 24 -- "$CMD" 75
[ "$RC" -eq 75 ] && [ ! -e "$EST/primera-saltada.json" ] || fail "75 sin historia creó estado"

# 6
reset
CRON_AVISA_ESTADO="$EST" CRON_AVISA_ENV="$SB/env" CRON_AVISA_API="http://127.0.0.1:$PORT" \
  python3 "$C" --nombre "Salida" --cada 1 -- "$CMD" 0 > "$SB/so" 2> "$SB/se"
[ "$(cat "$SB/so")" = "salida uno" ] || fail "stdout cambió: $(cat "$SB/so")"
[ "$(cat "$SB/se")" = "salida error" ] || fail "stderr cambió: $(cat "$SB/se")"
correr --nombre "Salida" --cada 1 -- /no/existe/jamas
[ "$RC" -eq 127 ] || fail "comando inexistente no salió 127 (rc=$RC)"
[ "$(avisos)" = 1 ] || fail "comando inexistente no avisó"

# 7
reset
VIEJO=$(python3 -c 'import time; print(int(time.time()) - 3 * 3600 - 2)')
FRESCO=$(python3 -c 'import time; print(int(time.time()) - 3600)')
mkdir -p "$EST"
printf '{"nombre":"Tarea vieja","inicio":1,"fin":%s,"codigo":0,"cada":1,"fallos":0}\n' "$VIEJO" > "$EST/vieja.json"
printf '{"nombre":"Tarea fresca","inicio":1,"fin":%s,"codigo":0,"cada":1,"fallos":0}\n' "$FRESCO" > "$EST/fresca.json"
correr --revisa --seco
[ "$RC" -eq 1 ] || fail "--seco con atraso no salió 1 (rc=$RC)"
[ "$(avisos)" = 0 ] || fail "--seco avisó"
grep -q "• Tarea vieja: no está corriendo." "$SB/out" || fail "--seco no imprimió la tarea vieja: $(cat "$SB/out")"
grep -q "Tarea fresca" "$SB/out" && fail "--seco nombró la tarea fresca"
correr --revisa
[ "$RC" -eq 1 ] || fail "--revisa con atraso no salió 1 (rc=$RC)"
[ "$(avisos)" = 1 ] || fail "--revisa no avisó una vez"
[ "$(texto 0)" = "$(printf '<b>En el servidor · Tareas programadas:</b>\n• Tarea vieja: no está corriendo.\nPídele a tu asistente que lo revise; lo demás sigue trabajando.')" ] \
  || fail "texto de --revisa: $(texto 0)"
rm "$EST/vieja.json"
correr --revisa
[ "$RC" -eq 0 ] || fail "--revisa con todo fresco no salió 0 (rc=$RC)"
[ "$(avisos)" = 0 ] || fail "--revisa avisó con todo fresco"
DIARIA=$(python3 -c 'import time; print(int(time.time()) - 30 * 3600)')
GRACIA=$(python3 -c 'import time; print(int(time.time()) - 2 * 3600)')
printf '{"nombre":"Diaria","inicio":1,"fin":%s,"codigo":0,"cada":24,"fallos":0}\n' "$DIARIA" > "$EST/diaria.json"
printf '{"nombre":"Con gracia","inicio":1,"fin":%s,"codigo":0,"cada":1,"fallos":0}\n' "$GRACIA" > "$EST/gracia.json"
correr --revisa --seco
[ "$RC" -eq 0 ] || fail "umbral 1.5 × cada + 1 h: diaria a 30 h o con gracia a 2 h salió atrasada (rc=$RC): $(cat "$SB/out")"
rm "$EST/diaria.json" "$EST/gracia.json"
printf '{"nombre":"A<b> & c","inicio":1,"fin":1,"codigo":0,"cada":1,"fallos":0}\n' > "$EST/h.json"
correr --revisa --seco
grep -qF "• A<b> & c: no está corriendo." "$SB/out" || fail "--seco deformó un nombre con <b> o &: $(cat "$SB/out")"
correr --revisa
grep -qF "A&lt;b&gt; &amp; c" "$SB/tg.log" || fail "el aviso no escapó el nombre: $(cat "$SB/tg.log")"
rm "$EST/h.json"
printf 'no es json' > "$EST/rota.json"
correr --revisa
[ "$RC" -eq 2 ] || fail "--revisa con un estado ilegible no salió 2 (rc=$RC)"
rm "$EST/rota.json"
for n in 8 9; do
  rm -f "$EST"/t*.json
  for i in $(seq "$n"); do
    printf '{"nombre":"Tarea %s","inicio":1,"fin":%s,"codigo":0,"cada":1,"fallos":0}\n' "$i" "$VIEJO" > "$EST/t$i.json"
  done
  correr --revisa
  if [ "$n" -eq 8 ]; then
    texto 0 | grep -q "tareas:" && fail "agrupó con solo 8 tareas"
    [ "$(texto 0 | grep -c '^• ')" -eq 8 ] || fail "con 8 no listó 8 líneas"
  else
    texto 0 | grep -q "• 9 tareas:" || fail "con 9 no agrupó: $(texto 0)"
  fi
done
rm -f "$EST"/t*.json
for i in $(seq 10); do
  printf '{"nombre":"Tarea %s","inicio":1,"fin":%s,"codigo":0,"cada":1,"fallos":0}\n' "$i" "$VIEJO" > "$EST/t$i.json"
done
correr --revisa
[ "$RC" -eq 1 ] || fail "--revisa con diez atrasadas no salió 1"
[ "$(texto 0 | wc -l | tr -d ' ')" -le 10 ] || fail "--revisa pasó de 8 líneas de tareas"
texto 0 | grep -q "• 10 tareas:" || fail "no agrupó en '• 10 tareas:': $(texto 0)"
reset
correr --revisa
[ "$RC" -eq 2 ] || fail "--revisa sin carpeta de estados no salió 2 (rc=$RC)"
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$EST"
  chmod 000 "$EST"
  correr --revisa --seco
  chmod 755 "$EST"
  [ "$RC" -eq 2 ] || fail "--revisa con la carpeta sin permiso no salió 2 (rc=$RC)"
fi

reset
mkdir -p "$EST"
printf '{"nombre":"Rota","inicio":1,"fin":1,"codigo":1,"cada":24,"fallos":null,"avisado":false}\n' > "$EST/rota.json"
correr --nombre "Rota" --cada 24 -- "$CMD" 6
[ "$RC" -eq 6 ] || fail "un estado con fallos null cambió el código (rc=$RC)"
[ "$(estado rota fallos)" = 1 ] || fail "fallos null no se tomó como 0"
for malo in nan inf 0 -1; do
  correr --nombre "Mala cada" --cada "$malo" -- "$CMD" 0
  [ "$RC" -eq 2 ] || fail "--cada $malo no se rechazó (rc=$RC)"
done
[ ! -e "$EST/mala-cada.json" ] || fail "--cada inválido dejó estado"

# 8
reset
correr --nombre "Privada" --cada 24 -- "$CMD" 4
correr --nombre "Privada" --cada 24 -- "$CMD" 0
printf '{"nombre":"Vieja privada","inicio":1,"fin":1,"codigo":0,"cada":1,"fallos":0}\n' > "$EST/v.json"
correr --revisa
grep -qF "$CMD" "$SB/tg.log" && fail "un aviso trae la ruta del comando"
grep -qF "$SB" "$SB/tg.log" && fail "un aviso trae una ruta del sistema"
python3 - "$SB/tg.log" "$TOKEN" <<'E' || fail "el token está en el texto de un aviso"
import json, sys
for linea in open(sys.argv[1]):
    assert sys.argv[2] not in json.loads(linea)["body"]["text"]
E

# 9
reset
API="http://127.0.0.1:9" correr --nombre "Sin Telegram" --cada 24 -- "$CMD" 5
[ "$RC" -eq 5 ] || fail "con Telegram caído el código cambió (rc=$RC)"
grep -q "no se pudo avisar" "$SB/out" || fail "no anotó que el aviso no salió: $(cat "$SB/out")"
grep -q "$TOKEN" "$SB/out" && fail "el token apareció en la salida"
correr --nombre "Sin Telegram" --cada 24 -- "$CMD" 5
[ "$(avisos)" = 1 ] || fail "no reintentó el aviso que no había salido"

echo "OK: test-cron-avisa (9 casos)"
