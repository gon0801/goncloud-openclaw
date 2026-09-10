#!/bin/bash
# T2 (discrimina #4): send_sales_digest.sh contra mock local, sin red real.
# Uso en gonserver como claw:
#   ./t2_digest.sh <script_bajo_prueba> [--legacy-solo-destinos]
# En modo legacy el script viejo ignora el archivo de entrada y TG_ENV/TG_SCHEME/
# TG_API_HOST (estan hardcodeados); el arnes lo parcha en /tmp (host del mock +
# env dummy) para demostrar a quien manda. Esperado: FAIL en destinos (manda a
# _2 y _CUSTOM en vez de _ID y _2) = bug #4 reproducido.
# Exit 0 = todos los casos PASS; != 0 = alguno FAIL.
set -u
SUT="${1:?uso: t2_digest.sh <script> [--legacy-solo-destinos]}"
LEGACY="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MOCK="$HERE/tg_mock.py"
TMPD="$(mktemp -d /tmp/t2.XXXXXX)"
trap 'rm -rf "$TMPD"; pkill -f "tg_mock.py --mode" 2>/dev/null' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$TMPD/tg_test.env" <<'EOF'
TELEGRAM_SALES_BOT_TOKEN=DUMMYTOKEN
TELEGRAM_CHAT_ID=11111
TELEGRAM_CHAT_ID_2=22222
TELEGRAM_CHAT_ID_CUSTOM=33333
EOF
printf '<b>digest de prueba</b> pedido 999' > "$TMPD/digest.txt"

start_mock() { # $1=mode $2=separators -> MOCK_PORT, $TMPD/mock.log
  rm -f "$TMPD/mock.log" "$TMPD/mock.port"
  python3 "$MOCK" --mode "$1" --separators "${2:-compact}" --log "$TMPD/mock.log" > "$TMPD/mock.port" 2>&1 &
  for _ in $(seq 1 50); do grep -q MOCK_PORT "$TMPD/mock.port" 2>/dev/null && break; sleep 0.1; done
  MOCK_PORT="$(sed 's/MOCK_PORT=//' "$TMPD/mock.port")"
}
stop_mock() { pkill -f "tg_mock.py --mode" 2>/dev/null; sleep 0.3; }
run_sut() { # corre el SUT contra el mock; deja salida en $TMPD/out y exit en RC
  if [ -n "$LEGACY" ]; then
    sed -e "s|https://api.telegram.org|http://127.0.0.1:$MOCK_PORT|" \
        -e "s|source /home/claw/.secrets/telegram-sales.env|source $TMPD/tg_test.env|" \
        "$SUT" > "$TMPD/legacy.sh"
    bash "$TMPD/legacy.sh" > "$TMPD/out" 2>&1; RC=$?
  else
    TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$TMPD/tg_test.env" \
      bash "$SUT" "$TMPD/digest.txt" > "$TMPD/out" 2>&1; RC=$?
  fi
}

echo "### T2 caso 1: destinos + ok:true en ambos (esperado: 11111,22222,DIGEST_OK2,exit 0)"
start_mock ok; run_sut; stop_mock
IDS="$(python3 -c "import json;print(' '.join(json.loads(l)['chat_id'] for l in open('$TMPD/mock.log')))")"
NPOST="$(wc -l < "$TMPD/mock.log")"
[ "$NPOST" = 2 ] && [ "$IDS" = "11111 22222" ] && grep -q DIGEST_OK2 "$TMPD/out" && [ "$RC" = 0 ] \
  && ok "destinos Gon+Isabel, DIGEST_OK2, exit 0" \
  || bad "destinos: posts=$NPOST ids=[$IDS] rc=$RC out=[$(head -c 120 "$TMPD/out")]"
if [ -n "$LEGACY" ]; then echo "### legacy: solo caso 1. PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]; exit; fi

echo "### T2 caso 2: mock ok:false en el 2do (esperado: DIGEST_PARCIAL, exit 1)"
start_mock fail-second
TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$TMPD/tg_test.env" \
  bash "$SUT" "$TMPD/digest.txt" > "$TMPD/out" 2>&1; RC=$?; stop_mock
grep -q DIGEST_PARCIAL "$TMPD/out" && [ "$RC" = 1 ] \
  && ok "DIGEST_PARCIAL exit 1" \
  || bad "rc=$RC out=[$(head -c 120 "$TMPD/out")]"

echo "### T2 caso 3: mensaje 4097 chars (esperado: ERR_MSG_LARGO, 0 POST)"
start_mock ok
python3 -c "print('x'*4097)" > "$TMPD/largo.txt"
TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$TMPD/tg_test.env" \
  bash "$SUT" "$TMPD/largo.txt" > "$TMPD/out" 2>&1; RC=$?; stop_mock
NPOST="$(wc -l < "$TMPD/mock.log" 2>/dev/null || echo 0)"
grep -q ERR_MSG_LARGO "$TMPD/out" && [ "$NPOST" = 0 ] \
  && ok "ERR_MSG_LARGO sin POST" \
  || bad "rc=$RC posts=$NPOST out=[$(head -c 120 "$TMPD/out")]"

echo "### T2 caso 4: CRLF (esperado: mock recibe sin CR)"
start_mock ok
printf 'linea1\r\nlinea2\r\n' > "$TMPD/crlf.txt"
TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$TMPD/tg_test.env" \
  bash "$SUT" "$TMPD/crlf.txt" > "$TMPD/out" 2>&1; RC=$?; stop_mock
CR="$(python3 -c "import json;print(any(json.loads(l)['has_cr'] for l in open('$TMPD/mock.log')))")"
[ "$CR" = False ] && grep -q DIGEST_OK2 "$TMPD/out" \
  && ok "sin CR en destino, DIGEST_OK2" \
  || bad "has_cr=$CR out=[$(head -c 120 "$TMPD/out")]"

echo "### T2 caso 5: archivo vacio (esperado: ERR_MSG_VACIO, 0 POST)"
start_mock ok
: > "$TMPD/vacio.txt"
TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$TMPD/tg_test.env" \
  bash "$SUT" "$TMPD/vacio.txt" > "$TMPD/out" 2>&1; RC=$?; stop_mock
NPOST="$(wc -l < "$TMPD/mock.log" 2>/dev/null || echo 0)"
grep -q ERR_MSG_VACIO "$TMPD/out" && [ "$NPOST" = 0 ] \
  && ok "ERR_MSG_VACIO sin POST" \
  || bad "rc=$RC posts=$NPOST out=[$(head -c 120 "$TMPD/out")]"

echo "### T2 caso 6: respuesta con espacios (esperado: DIGEST_OK2, parser tolerante)"
start_mock ok spaced
TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$TMPD/tg_test.env" \
  bash "$SUT" "$TMPD/digest.txt" > "$TMPD/out" 2>&1; RC=$?; stop_mock
grep -q DIGEST_OK2 "$TMPD/out" && [ "$RC" = 0 ] \
  && ok "DIGEST_OK2 con espacios" \
  || bad "rc=$RC out=[$(head -c 120 "$TMPD/out")]"

echo "### T2 resultado: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
