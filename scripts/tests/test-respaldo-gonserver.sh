#!/bin/bash
# Lado gonserver del respaldo completo, corrido local contra carpetas temporales:
# el receptor scripts/gonserver/recibe-respaldo y el vigía scripts/gonserver/vigila-respaldos.
#
#   1. openclaw: guarda backup y extras, imprime el sha256 del archivo guardado.
#   2. Nombre fuera de su familia, con ruta o vacío, y familia desconocida: sale 2 sin escribir.
#   3. Datos que no son gzip o llegan truncados: sale 3 y no queda archivo ni temporal.
#   4. Retención: 7 de cada prefijo en openclaw (uno no poda al otro); el mismo día reemplaza.
#   5. hermes: hermes-backup en hermes/ (7) y el nombre viejo claw-backup en claw/ (8).
#   5b. Fecha del nombre: acepta de hoy-60 a hoy+1 (también cruzando mes y año); fuera de
#       eso sale 2 sin escribir nada.
#   5c. Tope de tamaño: lo que pasa de RECIBE_MAX_BYTES sale 4 sin archivo ni temporal;
#       justo el tope entra; deja de leer en el tope, no escribe el envío entero.
#   6. Vigía: todo al día no avisa ni imprime nada.
#   7. Vigía: falta, viejo y encogido van en un solo aviso HTML escapado al chat del env.
#   8. Vigía: si Telegram falla sale 2 y el token no aparece en ninguna salida.
#
# Uso: bash scripts/tests/test-respaldo-gonserver.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"
R="$REPO/scripts/gonserver/recibe-respaldo"
V="$REPO/scripts/gonserver/vigila-respaldos"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

SB="$(mktemp -d)"
MOCK_PID=""
trap '[ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$SB"' EXIT
B="$SB/backups"

mkdir -p "$SB/src/x"; printf 'hola\n' > "$SB/src/x/a.txt"
tar -czf "$SB/bueno.tar.gz" -C "$SB/src" x
head -c 40 "$SB/bueno.tar.gz" > "$SB/truncado.tar.gz"
printf 'esto no es gzip\n' > "$SB/basura"

recibir() { # $1 familia, $2 nombre, $3 archivo -> stdout en $SB/out, stderr en $SB/err
  SSH_ORIGINAL_COMMAND="$2" RECIBE_BASE="${BASE_PRUEBA:-$B}" RECIBE_HOY="${HOY:-20261015}" \
    sh "$R" "$1" < "$3" > "$SB/out" 2> "$SB/err"
}

# 1
recibir openclaw openclaw-backup-20261015.tar.gz "$SB/bueno.tar.gz" || { cat "$SB/err"; fail "no recibió un backup válido"; }
[ "$(cat "$SB/out")" = "$(sha "$SB/bueno.tar.gz")" ] || fail "el sha impreso no es el del archivo enviado: $(cat "$SB/out")"
cmp -s "$SB/bueno.tar.gz" "$B/openclaw/openclaw-backup-20261015.tar.gz" || fail "el backup guardado no es el enviado"
recibir openclaw openclaw-extras-20261015.tar.gz "$SB/bueno.tar.gz" || fail "no recibió los extras"
[ -f "$B/openclaw/openclaw-extras-20261015.tar.gz" ] || fail "los extras no quedaron en openclaw/"

# 2
for caso in "openclaw hermes-backup-20261015.tar.gz" "openclaw claw-backup-20261015.tar.gz" \
            "hermes openclaw-backup-20261015.tar.gz" "openclaw ../openclaw-backup-20261015.tar.gz" \
            "openclaw openclaw-backup-2026101.tar.gz" "openclaw openclaw-backup-20261015.tar.gz.sh" \
            "openclaw " "otra openclaw-backup-20261015.tar.gz"; do
  fam="${caso%% *}"; nom="${caso#* }"
  recibir "$fam" "$nom" "$SB/bueno.tar.gz"; rc=$?
  [ "$rc" -eq 2 ] || fail "aceptó '$nom' para la familia '$fam' (rc=$rc)"
  grep -q "nombre invalido" "$SB/err" || fail "rechazo de '$nom' sin causa"
done
[ ! -e "$B/hermes" ] || fail "un nombre inválido creó la carpeta hermes/"
[ "$(ls -A "$B/openclaw" | wc -l | tr -d ' ')" = 2 ] || fail "un nombre inválido dejó algo en openclaw/: $(ls -A "$B/openclaw" | tr "\n" " ")"

# 3
for malo in basura truncado.tar.gz; do
  recibir openclaw openclaw-backup-20261016.tar.gz "$SB/$malo"; rc=$?
  [ "$rc" -eq 3 ] || fail "aceptó un archivo $malo (rc=$rc)"
  grep -q "corrupto" "$SB/err" || fail "rechazo de $malo sin causa"
  [ -e "$B/openclaw/openclaw-backup-20261016.tar.gz" ] && fail "quedó el archivo $malo"
  ls -A "$B/openclaw" | grep -q '\.tmp' && fail "quedó un temporal tras rechazar $malo"
done
[ -s "$SB/out" ] && fail "un rechazo imprimió algo en stdout: $(cat "$SB/out")"

# 4
for d in 01 02 03 04 05 06 07 08 09; do
  recibir openclaw "openclaw-backup-202610$d.tar.gz" "$SB/bueno.tar.gz" || fail "no recibió el backup del día $d"
done
[ "$(ls "$B/openclaw" | grep -c '^openclaw-backup-')" = 7 ] || fail "no guardó 7 backups: $(ls "$B/openclaw" | tr "\n" " ")"
[ -e "$B/openclaw/openclaw-backup-20261015.tar.gz" ] || fail "borró el backup más nuevo"
[ -e "$B/openclaw/openclaw-backup-20261003.tar.gz" ] && fail "guardó un backup que ya no está entre los 7 más nuevos"
[ -e "$B/openclaw/openclaw-backup-20261004.tar.gz" ] || fail "borró uno de los 7 más nuevos"
[ -e "$B/openclaw/openclaw-extras-20261015.tar.gz" ] || fail "la poda de backups se llevó los extras"
printf 'otro\n' > "$SB/src/x/b.txt"; tar -czf "$SB/otro.tar.gz" -C "$SB/src" x
recibir openclaw openclaw-backup-20261015.tar.gz "$SB/otro.tar.gz" || fail "no aceptó reemplazar el del mismo día"
cmp -s "$SB/otro.tar.gz" "$B/openclaw/openclaw-backup-20261015.tar.gz" || fail "el mismo día no reemplazó el archivo"

# 5
for d in 01 02 03 04 05 06 07 08 09; do
  recibir hermes "hermes-backup-202610$d.tar.gz" "$SB/bueno.tar.gz" || fail "hermes: no recibió el día $d"
  recibir hermes "claw-backup-202610$d.tar.gz" "$SB/bueno.tar.gz" || fail "hermes: no recibió el nombre viejo del día $d"
done
[ "$(cat "$SB/out")" = "$(sha "$SB/bueno.tar.gz")" ] || fail "hermes: el sha impreso no es el del archivo"
[ "$(ls "$B/hermes" | wc -l | tr -d ' ')" = 7 ] || fail "hermes/ no guardó 7: $(ls "$B/hermes" | tr "\n" " ")"
[ "$(ls "$B/claw" | wc -l | tr -d ' ')" = 8 ] || fail "claw/ no guardó 8: $(ls "$B/claw" | tr "\n" " ")"
[ -e "$B/claw/claw-backup-20261002.tar.gz" ] || fail "claw/ borró uno de los 8 más nuevos"

# 5b
for caso in "20261015 20261016 si" "20261015 20260816 si" "20261015 20261017 no" "20261015 20260815 no" \
            "20261015 20991231 no" "20270101 20261102 si" "20270101 20261101 no" "20270101 20270102 si"; do
  # shellcheck disable=SC2086  # cada caso son tres palabras
  set -- $caso
  rm -rf "$SB/fechas"
  BASE_PRUEBA="$SB/fechas" HOY="$1" recibir openclaw "openclaw-backup-$2.tar.gz" "$SB/bueno.tar.gz"; rc=$?
  if [ "$3" = si ]; then
    [ "$rc" -eq 0 ] || fail "hoy $1: rechazó la fecha $2 (rc=$rc): $(cat "$SB/err")"
    [ -f "$SB/fechas/openclaw/openclaw-backup-$2.tar.gz" ] || fail "hoy $1: no guardó la fecha $2"
  else
    [ "$rc" -eq 2 ] || fail "hoy $1: aceptó la fecha $2 (rc=$rc)"
    grep -q "fecha fuera de rango" "$SB/err" || fail "hoy $1: rechazo de $2 sin causa: $(cat "$SB/err")"
    [ ! -e "$SB/fechas" ] || fail "hoy $1: la fecha $2 dejó algo escrito: $(find "$SB/fechas")"
  fi
done

# 5c
tam=$(wc -c < "$SB/bueno.tar.gz" | tr -d ' ')
rm -rf "$SB/tope"
BASE_PRUEBA="$SB/tope" RECIBE_MAX_BYTES=$((tam - 1)) recibir openclaw openclaw-backup-20261015.tar.gz "$SB/bueno.tar.gz"; rc=$?
[ "$rc" -eq 4 ] || fail "aceptó un archivo de $tam bytes con tope $((tam - 1)) (rc=$rc)"
grep -q "pasa de $((tam - 1)) bytes" "$SB/err" || fail "rechazo por tamaño sin causa: $(cat "$SB/err")"
[ -z "$(ls -A "$SB/tope/openclaw")" ] || fail "el rechazo por tamaño dejó algo: $(ls -A "$SB/tope/openclaw")"
BASE_PRUEBA="$SB/tope" RECIBE_MAX_BYTES=$tam recibir openclaw openclaw-backup-20261015.tar.gz "$SB/bueno.tar.gz" \
  || fail "rechazó un archivo de justo el tope: $(cat "$SB/err")"
cmp -s "$SB/bueno.tar.gz" "$SB/tope/openclaw/openclaw-backup-20261015.tar.gz" || fail "con justo el tope no guardó el archivo entero"
python3 -c '
import sys
n = 0
try:
    for _ in range(51200):
        sys.stdout.buffer.write(bytes(1024)); n += 1024
    sys.stdout.flush()
except BrokenPipeError:
    pass
open(sys.argv[1], "w").write(str(n))' "$SB/enviados" 2>/dev/null \
  | SSH_ORIGINAL_COMMAND=openclaw-backup-20261015.tar.gz RECIBE_BASE="$SB/tope" RECIBE_HOY=20261015 RECIBE_MAX_BYTES=4096 \
    sh "$R" openclaw > /dev/null 2> "$SB/err"; rc=$?
[ "$rc" -eq 4 ] || fail "un envío de 50 MB con tope 4096 no salió 4 (rc=$rc)"
[ "$(cat "$SB/enviados")" -lt 1048576 ] || fail "el receptor leyó $(cat "$SB/enviados") bytes con tope 4096: no corta en el tope"
[ "$(ls -A "$SB/tope/openclaw")" = openclaw-backup-20261015.tar.gz ] || fail "el envío de 50 MB dejó algo: $(ls -A "$SB/tope/openclaw")"

# Vigía. Telegram de mentira en 127.0.0.1: registra cada POST y responde ok, o 500 si existe $SB/tg-falla.
cat > "$SB/tg.py" <<'E'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
sb = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        cuerpo = self.rfile.read(int(self.headers["Content-Length"])).decode()
        with open(f"{sb}/tg.log", "a") as f:
            f.write(json.dumps({"path": self.path, "body": json.loads(cuerpo)}) + "\n")
        falla = os.path.exists(f"{sb}/tg-falla")
        self.send_response(500 if falla else 200)
        self.end_headers()
        self.wfile.write(b'{"ok":false}' if falla else b'{"ok":true,"result":{}}')
    def log_message(self, *a):
        pass
s = HTTPServer(("127.0.0.1", 0), H)
open(f"{sb}/tg.port", "w").write(str(s.server_port))
s.serve_forever()
E
python3 "$SB/tg.py" "$SB" & MOCK_PID=$!
for _ in $(seq 50); do [ -s "$SB/tg.port" ] && break; sleep 0.1; done
[ -s "$SB/tg.port" ] || fail "no arrancó el Telegram de mentira"
TOKEN="123456:TOKEN-SECRETO-de-prueba"
printf '# claves\nTELEGRAM_SALES_BOT_TOKEN=otro\nTELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID="6470689715"\n' "$TOKEN" > "$SB/acc.env"
vigilar() { # $1 carpeta base
  VIGILA_BASE="$1" VIGILA_ENV="$SB/acc.env" VIGILA_API="http://127.0.0.1:$(cat "$SB/tg.port")" \
    python3 "$V" > "$SB/vout" 2> "$SB/verr"
}
envios() { [ -f "$SB/tg.log" ] && wc -l < "$SB/tg.log" | tr -d ' ' || echo 0; }
hace_horas() { python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[1])*3600; os.utime(sys.argv[2],(t,t))' "$1" "$2"; }
poner() { # $1 base, $2 carpeta, $3 nombre, $4 bytes, $5 horas atrás
  mkdir -p "$1/$2"; head -c "$4" /dev/zero > "$1/$2/$3"; hace_horas "$5" "$1/$2/$3"
}

# 6
F="$SB/fresco"
poner "$F" openclaw openclaw-backup-20261014.tar.gz 1000 25
poner "$F" openclaw openclaw-backup-20261015.tar.gz 900 1
poner "$F" openclaw openclaw-extras-20261015.tar.gz 100 1
poner "$F" hermes hermes-backup-20261015.tar.gz 500 35
vigilar "$F"; rc=$?
[ "$rc" -eq 0 ] || fail "con todo al día salió $rc: $(cat "$SB/vout" "$SB/verr")"
[ -s "$SB/vout" ] || [ -s "$SB/verr" ] && fail "con todo al día imprimió algo: $(cat "$SB/vout" "$SB/verr")"
[ "$(envios)" = 0 ] || fail "con todo al día mandó un aviso"

# 7
M="$SB/mal<&>"
poner "$M" openclaw openclaw-backup-20261014.tar.gz 1000 25
poner "$M" openclaw openclaw-backup-20261015.tar.gz 400 1
poner "$M" hermes hermes-backup-20261013.tar.gz 500 40
vigilar "$M"; rc=$?
[ "$rc" -eq 1 ] || fail "con problemas no salió 1 (rc=$rc): $(cat "$SB/verr")"
[ "$(envios)" = 1 ] || fail "esperaba un solo aviso, hubo $(envios)"
python3 - "$SB/tg.log" "$TOKEN" "$M" <<'E' || fail "el aviso no es el esperado: $(cat "$SB/tg.log")"
import html, json, sys
d = json.loads(open(sys.argv[1]).readline())
token, base = sys.argv[2], sys.argv[3]
b = d["body"]
assert d["path"] == f"/bot{token}/sendMessage", d["path"]
assert b["chat_id"] == "6470689715" and b["parse_mode"] == "HTML", b
esperado = "\n".join([
    "<b>Respaldos con problema en gonserver</b>",
    "• openclaw-backup: openclaw-backup-20261015.tar.gz pesa 400 bytes, menos de la mitad de openclaw-backup-20261014.tar.gz (1000 bytes)",
    f"• openclaw-extras: no hay ningún respaldo en {html.escape(base, quote=False)}/openclaw",
    "• hermes-backup: el más reciente (hermes-backup-20261013.tar.gz) tiene 40 h",
])
assert b["text"] == esperado, b["text"]
assert "&lt;&amp;&gt;" in b["text"] and "<&>" not in b["text"]
E

# 8
touch "$SB/tg-falla"
vigilar "$M"; rc=$?
[ "$rc" -eq 2 ] || fail "con Telegram caído no salió 2 (rc=$rc)"
grep -q "no se pudo avisar" "$SB/verr" || fail "con Telegram caído no dijo la causa: $(cat "$SB/verr")"
cat "$SB/vout" "$SB/verr" | grep -qF "$TOKEN" && fail "el token apareció en la salida"
rm -f "$SB/tg-falla"

# 9
X="$SB/roto"
poner "$X" openclaw openclaw-backup-20261015.tar.gz 900 1
ln -s "$SB/no-existe" "$X/openclaw/openclaw-backup-20261016.tar.gz"
antes="$(envios)"
vigilar "$X"; rc=$?
[ "$rc" -eq 1 ] || fail "con un respaldo que no se puede leer no salió 1 (rc=$rc): $(cat "$SB/verr")"
[ "$(envios)" -eq $((antes + 1)) ] || fail "un vigía que no pudo revisar no avisó"
grep -q "no pude revisar los respaldos" "$SB/tg.log" || fail "el aviso no dice que no pudo revisar: $(tail -1 "$SB/tg.log")"

# 10
P="$SB/poda-propia"
for d in 09 10 11 12 13 14 15; do
  BASE_PRUEBA="$P" recibir openclaw "openclaw-backup-202610$d.tar.gz" "$SB/bueno.tar.gz" || fail "no recibió el día $d"
done
BASE_PRUEBA="$P" recibir openclaw openclaw-backup-20261001.tar.gz "$SB/bueno.tar.gz"; rc=$?
[ "$rc" -eq 5 ] || fail "un día más viejo que los que se guardan no se rechazó (rc=$rc, out='$(cat "$SB/out")')"
[ ! -s "$SB/out" ] || fail "un día rechazado imprimió un sha"
[ "$(ls "$P/openclaw" | tr '\n' ' ')" = "openclaw-backup-20261009.tar.gz openclaw-backup-20261010.tar.gz openclaw-backup-20261011.tar.gz openclaw-backup-20261012.tar.gz openclaw-backup-20261013.tar.gz openclaw-backup-20261014.tar.gz openclaw-backup-20261015.tar.gz " ] \
  || fail "un día rechazado cambió lo guardado: $(ls -A "$P/openclaw" | tr '\n' ' ')"

echo "ok: receptor por familia con validación, retención y sha; vigía callado al día y con un aviso sin token"
