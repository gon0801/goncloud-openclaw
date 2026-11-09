#!/bin/bash
# Respaldo de OpenBot (scripts/mac/respaldo-openbot.sh), sin red: un OpenBot de mentira,
# un sqlite3 real con WAL, y un ssh de mentira que corre el receptor real
# (scripts/gonserver/recibe-respaldo) con el nombre como SSH_ORIGINAL_COMMAND.
#
#   1. Corrida buena: el archivo llega al servidor con el sha256 local, trae openbot.db
#      íntegro con la fila que solo estaba en el WAL, y las carpetas pedidas; deja fuera
#      provider-runtimes, cachés, logs, Crashpad y Singleton*. Sin aviso.
#   2. Una carpeta que no existe se anota y la corrida sigue.
#   3. El receptor rechaza el nombre de otra familia en openbot y el de openbot en otra
#      familia; openbot guarda los 2 más nuevos.
#   4. Reintento alternando servidores; sha256 distinto falla; tope por intento; lock
#      vivo sale 3 sin aviso.
#   5. Archivo sobre el tope (bajo por entorno) falla y avisa.
#   6. Vigía: openbot a 71 h no avisa y a 73 h sí; claw/Hermes siguen avisando a 37 h;
#      el encogimiento a la mitad aplica a openbot.
#   7. El plist, con la plantilla llena, es válido: 03:45 y apunta al script.
#
# Corre el script con /bin/bash: en macOS es el 3.2 de la MacBook.
# Uso: bash scripts/tests/test-respaldo-openbot.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"
S="$REPO/scripts/mac/respaldo-openbot.sh"
P="$REPO/scripts/mac/ai.goncloud.respaldo-openbot.plist"
R="$REPO/scripts/gonserver/recibe-respaldo"
V="$REPO/scripts/gonserver/vigila-respaldos"
SQLITE3="$(command -v sqlite3 || true)"
[ -n "$SQLITE3" ] || { printf 'FAIL: falta sqlite3\n'; exit 1; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

SB="$(mktemp -d)"
WAL_PID=""
MOCK_PID=""
trap '[ -n "$WAL_PID" ] && kill "$WAL_PID" 2>/dev/null; [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$SB"' EXIT
F=20261015

H="$SB/home"
RAIZ="$H/Library/Application Support/OpenBot"
mkdir -p "$RAIZ" "$H/.ssh"
printf 'llave\n' > "$H/.ssh/openbot_goncloud"

# OpenBot de mentira: estado y carpetas que la app necesita, más lo regenerable que no
# debe entrar al archivo.
for d in automation agent-api-keys provider-state provider-handoffs provider-toolsets \
         provider-work-steps local-skills Partitions IndexedDB "Local Storage" \
         "Session Storage" WebStorage avatars themes remote-desktop-runtime \
         provider-runtimes Cache "Code Cache" GPUCache DawnCache GraphiteDawnCache logs Crashpad; do
  mkdir -p "$RAIZ/$d"
  printf '%s\n' "$d" > "$RAIZ/$d/marca.txt"
done
for f in Preferences "Local State" Cookies custom-agents.json otro.json cosa.bin SingletonLock; do
  printf '%s\n' "$f" > "$RAIZ/$f"
done
"$SQLITE3" "$RAIZ/openbot.db" 'create table notas(x text); insert into notas values ("fila-en-el-principal");' \
  || fail "no se pudo crear openbot.db"
# Escritura que queda en el WAL: una copia cruda del .db no la vería.
python3 - "$RAIZ/openbot.db" "$SB/wal-listo" <<'PY' &
import pathlib, sqlite3, sys, time
con = sqlite3.connect(sys.argv[1])
con.execute("pragma journal_mode=wal")
con.execute("insert into notas values ('fila-solo-en-wal')")
con.commit()
pathlib.Path(sys.argv[2]).write_text("si")
time.sleep(120)
PY
WAL_PID=$!
for _ in $(seq 100); do [ -s "$SB/wal-listo" ] && [ -s "$RAIZ/openbot.db-wal" ] && break; sleep 0.1; done
[ -s "$RAIZ/openbot.db-wal" ] || fail "la prueba no dejó escrituras en el WAL"

# openclaw de mentira: solo para que las pruebas existentes de la Mini sigan teniendo su
# binario si algún día se comparte el HOME. Aquí no se usa.
cat > "$SB/ssh" <<EOS
#!/bin/sh
n=\$(cat "$SB/ssh-n" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$SB/ssh-n"
printf '%s\n' "\$*" >> "$SB/ssh-llamadas"
for a in "\$@"; do host="\$nombre"; nombre="\$a"; done
if [ "\$n" -le "\${FAKE_FALLAS:-0}" ]; then cat > /dev/null; echo "ssh: connect to host \${host#*@}: Network is unreachable" >&2; exit 255; fi
case "\${FAKE_MODO:-}" in
  mudo) echo \$\$ > "$SB/ssh-pid"; exec sleep 30 ;;
  sha-malo) cat > /dev/null; echo 0000; exit 0 ;;
esac
SSH_ORIGINAL_COMMAND="\$nombre" RECIBE_BASE="$SB/servidor" RECIBE_HOY=$F sh "$R" openbot
EOS
chmod +x "$SB/ssh"
cat > "$SB/osascript" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "$SB/avisos"
EOS
chmod +x "$SB/osascript"

correr() {
  rm -f "$SB/ssh-n"
  env HOME="$H" OB_RAIZ="$RAIZ" OB_DIR="$SB/local" OB_LOG="$SB/log" OB_FECHA="$F" \
    OB_SSH="$SB/ssh" OB_ESPERA=0 OB_LLAVE="$H/.ssh/openbot_goncloud" \
    OB_OSASCRIPT="$SB/osascript" OB_SQLITE3="$SQLITE3" "$@" /bin/bash "$S"
}
lanzar() {
  rm -f "$SB/ssh-n" "$SB/ssh-pid"
  env HOME="$H" OB_RAIZ="$RAIZ" OB_DIR="$SB/local" OB_LOG="$SB/log" OB_FECHA="$F" \
    OB_SSH="$SB/ssh" OB_ESPERA=0 OB_LLAVE="$H/.ssh/openbot_goncloud" \
    OB_OSASCRIPT="$SB/osascript" OB_SQLITE3="$SQLITE3" "$@" /bin/bash "$S" &
  PID=$!
  for _ in $(seq 100); do [ -s "$SB/ssh-pid" ] && return 0; sleep 0.1; done
  fail "la corrida no llegó a la subida"
}
avisos() { [ -f "$SB/avisos" ] && wc -l < "$SB/avisos" | tr -d ' ' || echo 0; }
L="$SB/local"; SV="$SB/servidor/openbot"

# 1
correr; rc=$?
[ "$rc" -eq 0 ] || { cat "$SB/log"; fail "la corrida buena salió $rc"; }
[ -f "$L/openbot-backup-$F.tar.gz" ] || fail "no quedó openbot-backup-$F.tar.gz en la Mac"
[ "$(sha "$SV/openbot-backup-$F.tar.gz" 2>/dev/null)" = "$(sha "$L/openbot-backup-$F.tar.gz")" ] \
  || fail "openbot-backup-$F.tar.gz no llegó igual al servidor"
[ "$(avisos)" = 0 ] || fail "una corrida buena avisó"
[ "$(head -1 "$SB/ssh-llamadas")" = "-i $H/.ssh/openbot_goncloud -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 clawbackup@10.13.13.1 openbot-backup-$F.tar.gz" ] \
  || fail "ssh no se llamó como se espera: $(head -1 "$SB/ssh-llamadas")"
grep -q "terminado sin fallas" "$SB/log" || fail "el log no cierra la corrida buena"
ls -A "$L" | grep -q '^\.' && fail "quedó el lock o un temporal: $(ls -A "$L" | tr '\n' ' ')"

mkdir -p "$SB/extraido"
tar -xzf "$L/openbot-backup-$F.tar.gz" -C "$SB/extraido" || fail "el archivo no se puede desempacar"
[ "$("$SQLITE3" "$SB/extraido/openbot.db" 'pragma integrity_check')" = ok ] \
  || fail "openbot.db no pasa integrity_check"
[ "$("$SQLITE3" "$SB/extraido/openbot.db" 'select x from notas where x = "fila-solo-en-wal"')" = fila-solo-en-wal ] \
  || fail "openbot.db no trae la escritura que estaba en el WAL"
tar -tzf "$L/openbot-backup-$F.tar.gz" | sed 's|^\./||' > "$SB/lista"
for r in openbot.db Preferences "Local State" Cookies custom-agents.json otro.json cosa.bin \
         automation/marca.txt agent-api-keys/marca.txt provider-state/marca.txt \
         provider-handoffs/marca.txt provider-toolsets/marca.txt \
         provider-work-steps/marca.txt local-skills/marca.txt Partitions/marca.txt \
         IndexedDB/marca.txt "Local Storage/marca.txt" "Session Storage/marca.txt" \
         WebStorage/marca.txt avatars/marca.txt themes/marca.txt \
         remote-desktop-runtime/marca.txt; do
  grep -qxF "$r" "$SB/lista" || fail "el archivo no trae $r"
done
for r in provider-runtimes Cache "Code Cache" GPUCache DawnCache GraphiteDawnCache logs Crashpad; do
  grep -q "^$r/" "$SB/lista" && fail "el archivo trae lo regenerable $r"
done
grep -qxF "SingletonLock" "$SB/lista" && fail "el archivo trae SingletonLock"

# 2
mv "$RAIZ/themes" "$SB/themes.guardado"
rm -rf "$SB/servidor"
correr || { cat "$SB/log"; fail "una carpeta que no existe detuvo la corrida"; }
grep -q "omitido (no existe): themes" "$SB/log" || fail "no anotó la carpeta que no existe"
[ -f "$SV/openbot-backup-$F.tar.gz" ] || fail "con una carpeta ausente no subió el archivo"
mv "$SB/themes.guardado" "$RAIZ/themes"

# 3
mkdir -p "$SB/src/x"; printf 'hola\n' > "$SB/src/x/a.txt"
tar -czf "$SB/bueno.tar.gz" -C "$SB/src" x
recibir() { # $1 familia, $2 nombre -> rc; deja stderr en $SB/err
  SSH_ORIGINAL_COMMAND="$2" RECIBE_BASE="$SB/receptor" RECIBE_HOY=$F sh "$R" "$1" \
    < "$SB/bueno.tar.gz" > "$SB/out" 2> "$SB/err"
}
for caso in "openbot hermes-backup-20261015.tar.gz" "openbot openclaw-backup-20261015.tar.gz" \
            "hermes openbot-backup-20261015.tar.gz" "openclaw openbot-backup-20261015.tar.gz" \
            "openbot ../openbot-backup-20261015.tar.gz" "otra openbot-backup-20261015.tar.gz"; do
  fam="${caso%% *}"; nom="${caso#* }"
  recibir "$fam" "$nom"; rc=$?
  [ "$rc" -eq 2 ] || fail "aceptó '$nom' para la familia '$fam' (rc=$rc)"
  grep -q "nombre invalido" "$SB/err" || fail "rechazo de '$nom' sin causa"
done
for d in 13 14 15; do
  recibir openbot "openbot-backup-202610$d.tar.gz" || { cat "$SB/err"; fail "no recibió openbot del día $d"; }
done
[ "$(ls "$SB/receptor/openbot" | tr '\n' ' ')" = "openbot-backup-20261014.tar.gz openbot-backup-20261015.tar.gz " ] \
  || fail "openbot/ no guardó los 2 más nuevos: $(ls "$SB/receptor/openbot" | tr '\n' ' ')"

# 4
rm -rf "$SB/servidor" "$L"; rm -f "$SB/avisos" "$SB/ssh-llamadas"
correr FAKE_FALLAS=2 || { cat "$SB/log"; fail "no reintentó la subida"; }
[ "$(awk '{ print $(NF-1) }' "$SB/ssh-llamadas" | tr '\n' ' ')" = "clawbackup@10.13.13.1 clawbackup@100.127.167.103 clawbackup@10.13.13.1 " ] \
  || fail "los intentos no alternaron servidores: $(awk '{ print $(NF-1) }' "$SB/ssh-llamadas" | tr '\n' ' ')"
[ "$(avisos)" = 0 ] || fail "un reintento que terminó bien avisó"
rm -f "$SB/avisos"
correr FAKE_MODO=sha-malo OB_INTENTOS=2; rc=$?
[ "$rc" -eq 1 ] || fail "un sha256 distinto no hizo fallar la corrida (rc=$rc)"
grep -q "el sha256 no coincide (servidor: 0000)" "$SB/log" || fail "el log no dice que el sha256 no coincide"
rm -f "$SB/avisos"
t0=$(date +%s)
correr FAKE_MODO=mudo OB_TOPE=1 OB_INTENTOS=2; rc=$?
[ "$rc" -eq 1 ] || fail "una subida muda no salió 1 (rc=$rc)"
[ $(( $(date +%s) - t0 )) -lt 20 ] || fail "una subida muda retuvo la corrida más de 20 s"
grep -q "sin respuesta en 1s" "$SB/log" || fail "el log no dice que la subida quedó muda"
rm -f "$SB/avisos"
yo="$$ $(ps -o lstart= -p $$ | tr -s ' ')"
mkdir -p "$L/.lock"; printf '%s' "$yo" > "$L/.lock/dueno"
correr; rc=$?
[ "$rc" -eq 3 ] || fail "con el lock de un proceso vivo no salió 3 (rc=$rc)"
[ "$(cat "$L/.lock/dueno")" = "$yo" ] || fail "se robó el lock de un proceso vivo"
[ "$(avisos)" = 0 ] || fail "el lock de otra corrida avisó"
rm -rf "$L/.lock"

# 5
rm -rf "$SB/servidor" "$L"; rm -f "$SB/avisos"
correr OB_MAX_BYTES=100; rc=$?
[ "$rc" -eq 1 ] || fail "pasar el tope no hizo fallar la corrida (rc=$rc)"
[ "$(avisos)" = 1 ] || fail "pasar el tope no avisó exactamente una vez: $(avisos)"
grep -q "OpenBot a gonserver falló: openbot-backup-$F.tar.gz pesa .* más del tope 100" "$SB/avisos" \
  || fail "el aviso no dice que pasó el tope: $(cat "$SB/avisos")"
[ -e "$SV/openbot-backup-$F.tar.gz" ] && fail "se subió un archivo que pasó el tope"
[ -e "$L/openbot-backup-$F.tar.gz" ] && fail "quedó local el archivo que pasó el tope y desplazaría a uno válido"

# 6
cat > "$SB/tg.py" <<'PY'
import json, os, sys
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
PY
python3 "$SB/tg.py" "$SB" & MOCK_PID=$!
for _ in $(seq 50); do [ -s "$SB/tg.port" ] && break; sleep 0.1; done
[ -s "$SB/tg.port" ] || fail "no arrancó el Telegram de mentira"
TOKEN="123456:TOKEN-SECRETO-de-prueba"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID="6470689715"\n' "$TOKEN" > "$SB/acc.env"
vigilar() {
  VIGILA_BASE="$1" VIGILA_ENV="$SB/acc.env" VIGILA_API="http://127.0.0.1:$(cat "$SB/tg.port")" \
    python3 "$V" > "$SB/vout" 2> "$SB/verr"
}
envios() { [ -f "$SB/tg.log" ] && wc -l < "$SB/tg.log" | tr -d ' ' || echo 0; }
aviso_contiene() { # $1 texto que tiene que aparecer en el aviso de Telegram
  python3 - "$SB/tg.log" "$1" <<'P'
import json, sys
for linea in open(sys.argv[1]):
    if sys.argv[2] in json.loads(linea)["body"]["text"]:
        raise SystemExit(0)
raise SystemExit(1)
P
}
hace_horas() { python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[1])*3600; os.utime(sys.argv[2],(t,t))' "$1" "$2"; }
poner() { mkdir -p "$1/$2"; head -c "$4" /dev/zero > "$1/$2/$3"; hace_horas "$5" "$1/$2/$3"; }

W="$SB/vigia"
poner "$W" openbot openbot-backup-20261015.tar.gz 1000 71
poner "$W" openclaw openclaw-backup-20261015.tar.gz 1000 1
poner "$W" openclaw openclaw-extras-20261015.tar.gz 1000 1
poner "$W" hermes hermes-backup-20261015.tar.gz 1000 1
vigilar "$W"; rc=$?
[ "$rc" -eq 0 ] || fail "openbot a 71 h con las demás al día salió $rc: $(cat "$SB/vout" "$SB/verr")"
[ "$(envios)" = 0 ] || fail "openbot a 71 h avisó"
poner "$W" openbot openbot-backup-20261015.tar.gz 1000 73
vigilar "$W"; rc=$?
[ "$rc" -eq 1 ] || fail "openbot a 73 h no salió 1 (rc=$rc): $(cat "$SB/verr")"
[ "$(envios)" = 1 ] || fail "openbot a 73 h no mandó un aviso: $(envios)"
aviso_contiene "openbot-backup: el más reciente (openbot-backup-20261015.tar.gz) tiene 73 h" \
  || fail "el aviso de openbot no lo nombra a las 73 h: $(cat "$SB/tg.log")"
: > "$SB/tg.log"

A="$SB/vigia-viejas"
poner "$A" openbot openbot-backup-20261015.tar.gz 1000 1
poner "$A" openclaw openclaw-backup-20261015.tar.gz 1000 37
poner "$A" openclaw openclaw-extras-20261015.tar.gz 1000 1
poner "$A" hermes hermes-backup-20261015.tar.gz 1000 37
vigilar "$A"; rc=$?
[ "$rc" -eq 1 ] || fail "claw/Hermes a 37 h no salió 1 (rc=$rc): $(cat "$SB/verr")"
aviso_contiene "openclaw-backup: el más reciente (openclaw-backup-20261015.tar.gz) tiene 37 h" \
  || fail "el aviso no nombra openclaw-backup a las 37 h: $(cat "$SB/tg.log")"
aviso_contiene "hermes-backup: el más reciente (hermes-backup-20261015.tar.gz) tiene 37 h" \
  || fail "el aviso no nombra hermes-backup a las 37 h: $(cat "$SB/tg.log")"
aviso_contiene "openbot-backup" && fail "openbot a 1 h apareció en el aviso"
: > "$SB/tg.log"

C="$SB/vigia-encoge"
poner "$C" openbot openbot-backup-20261014.tar.gz 1000 25
poner "$C" openbot openbot-backup-20261015.tar.gz 400 1
poner "$C" openclaw openclaw-backup-20261015.tar.gz 1000 1
poner "$C" openclaw openclaw-extras-20261015.tar.gz 1000 1
poner "$C" hermes hermes-backup-20261015.tar.gz 1000 1
vigilar "$C"; rc=$?
[ "$rc" -eq 1 ] || fail "openbot encogido no salió 1 (rc=$rc): $(cat "$SB/verr")"
aviso_contiene "openbot-backup: openbot-backup-20261015.tar.gz pesa 400 bytes, menos de la mitad de openbot-backup-20261014.tar.gz (1000 bytes)" \
  || fail "el aviso no trae el encogimiento de openbot: $(cat "$SB/tg.log")"

# 7
sed -e "s|__HOME__|/Users/gon|g" "$P" > "$SB/p.plist"
grep -q '__' "$SB/p.plist" && fail "la plantilla tiene un marcador que la instalación no llena"
plutil -lint "$SB/p.plist" > /dev/null || fail "plutil -lint rechazó el plist"
python3 - "$SB/p.plist" <<'E' || fail "plist inválido o con otro horario o script"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
assert d["Label"] == "ai.goncloud.respaldo-openbot"
assert d["ProgramArguments"] == ["/bin/bash", "/Users/gon/bin/respaldo-openbot.sh"], d["ProgramArguments"]
assert d["StartCalendarInterval"] == {"Hour": 3, "Minute": 45}
assert d["EnvironmentVariables"]["HOME"] == "/Users/gon"
assert d["StandardOutPath"] == "/Users/gon/Library/Logs/goncloud/respaldo-openbot.log"
assert not d.get("KeepAlive") and not d.get("RunAtLoad")
E

echo "ok: OpenBot respaldado con openbot.db consistente, sin regenerables, retención, reintentos, tope, aviso y vigía de 72 h"
