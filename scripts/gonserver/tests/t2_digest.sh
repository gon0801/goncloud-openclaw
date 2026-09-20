#!/bin/bash
# T2 (discrimina #4): send_sales_digest.sh contra mock local, sin red real.
# Uso en gonserver como claw:
#   ./t2_digest.sh <script_bajo_prueba> [--legacy-solo-destinos]
# En modo legacy el script viejo ignora el archivo de entrada y TG_ENV/TG_SCHEME/
# TG_API_HOST (estan hardcodeados); el arnes lo parcha en /tmp (host del mock +
# env dummy) para demostrar a quien manda. Esperado: FAIL en destinos (manda a
# _2 y _CUSTOM en vez de _ID y _2) = bug #4 reproducido.
# Exit 0 = todos los casos PASS; 1 = alguno FAIL; 2 = infra (mock no arranco).
set -u
SUT="${1:?uso: t2_digest.sh <script> [--legacy-solo-destinos]}"
LEGACY="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MOCK="$HERE/tg_mock.py"
TMPD="$(mktemp -d /tmp/t2.XXXXXX)"
trap 'rm -rf "$TMPD"; [ -n "${MOCK_PID:-}" ] && kill "${MOCK_PID}" 2>/dev/null' EXIT
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

start_mock() { # $1=mode $2=separators -> MOCK_PORT/MOCK_PID o ABORTO exit 2
  rm -f "$TMPD/mock.log" "$TMPD/mock.port" "$TMPD/mock.err"
  python3 "$MOCK" --mode "$1" --separators "${2:-compact}" --log "$TMPD/mock.log" \
    > "$TMPD/mock.port" 2>"$TMPD/mock.err" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do grep -q MOCK_PORT "$TMPD/mock.port" 2>/dev/null && break; sleep 0.1; done
  MOCK_PORT="$(sed 's/MOCK_PORT=//' "$TMPD/mock.port" 2>/dev/null)"
  case "$MOCK_PORT" in ''|*[!0-9]*)
    echo "ABORTO: mock no arranco (stderr en $TMPD/mock.err)"
    kill "$MOCK_PID" 2>/dev/null; exit 2 ;;
  esac
}
stop_mock() { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""; }
run_sut() { # [$1=env] corre el SUT contra el mock; salida en $TMPD/out, exit en RC
  local env="${1:-$TMPD/tg_test.env}"
  if [ -n "$LEGACY" ]; then
    sed -e "s|https://api.telegram.org|http://127.0.0.1:$MOCK_PORT|" \
        -e "s|source /home/claw/.secrets/telegram-sales.env|source $TMPD/tg_test.env|" \
        "$SUT" > "$TMPD/legacy.sh"
    bash "$TMPD/legacy.sh" > "$TMPD/out" 2>&1; RC=$?
  else
    TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$env" \
      bash "$SUT" "$TMPD/digest.txt" > "$TMPD/out" 2>&1; RC=$?
  fi
}
nposts() { wc -l < "$TMPD/mock.log" 2>/dev/null || echo 0; }
post_ids() { python3 -c "import json;print(' '.join(json.loads(l)['chat_id'] for l in open('$TMPD/mock.log')))" 2>/dev/null; }

echo "### T2 caso 1: destinos + ok:true en ambos (esperado: 11111,22222,DIGEST_OK2,exit 0)"
start_mock ok; run_sut; stop_mock
[ "$(nposts)" -eq 2 ] && [ "$(post_ids)" = "11111 22222" ] && grep -q DIGEST_OK2 "$TMPD/out" && [ "$RC" -eq 0 ] \
  && ok "destinos Gon+Isabel, DIGEST_OK2, exit 0" \
  || bad "destinos: posts=$(nposts) ids=[$(post_ids)] rc=$RC out=[$(head -c 120 "$TMPD/out")]"
if [ -n "$LEGACY" ]; then echo "### legacy: solo caso 1. PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]; exit; fi

echo "### T2 caso 2: mock ok:false en el 2do (esperado: 2 POST 11111 22222, DIGEST_PARCIAL, exit 1)"
start_mock fail-second; run_sut; stop_mock
[ "$(nposts)" -eq 2 ] && [ "$(post_ids)" = "11111 22222" ] && grep -q DIGEST_PARCIAL "$TMPD/out" && [ "$RC" -eq 1 ] \
  && ok "DIGEST_PARCIAL exit 1, ambos chats intentados en orden" \
  || bad "posts=$(nposts) ids=[$(post_ids)] rc=$RC out=[$(head -c 120 "$TMPD/out")]"

echo "### T2 caso 3: mensaje 4097 chars (esperado: ERR_MSG_LARGO, 0 POST, exit != 0)"
start_mock ok
python3 -c "print('x'*4097)" > "$TMPD/largo.txt"
TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$TMPD/tg_test.env" \
  bash "$SUT" "$TMPD/largo.txt" > "$TMPD/out" 2>&1; RC=$?; stop_mock
grep -q ERR_MSG_LARGO "$TMPD/out" && [ "$(nposts)" -eq 0 ] && [ "$RC" -ne 0 ] \
  && ok "ERR_MSG_LARGO sin POST, exit $RC" \
  || bad "rc=$RC posts=$(nposts) out=[$(head -c 120 "$TMPD/out")]"

echo "### T2 caso 4: CRLF (esperado: mock recibe sin CR)"
start_mock ok
printf 'linea1\r\nlinea2\r\n' > "$TMPD/crlf.txt"
TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$TMPD/tg_test.env" \
  bash "$SUT" "$TMPD/crlf.txt" > "$TMPD/out" 2>&1; RC=$?; stop_mock
CR="$(python3 -c "import json;print(any(json.loads(l)['has_cr'] for l in open('$TMPD/mock.log')))")"
[ "$CR" = False ] && grep -q DIGEST_OK2 "$TMPD/out" \
  && ok "sin CR en destino, DIGEST_OK2" \
  || bad "has_cr=$CR out=[$(head -c 120 "$TMPD/out")]"

echo "### T2 caso 5: archivo vacio (esperado: ERR_MSG_VACIO, 0 POST, exit != 0)"
start_mock ok
: > "$TMPD/vacio.txt"
TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$TMPD/tg_test.env" \
  bash "$SUT" "$TMPD/vacio.txt" > "$TMPD/out" 2>&1; RC=$?; stop_mock
grep -q ERR_MSG_VACIO "$TMPD/out" && [ "$(nposts)" -eq 0 ] && [ "$RC" -ne 0 ] \
  && ok "ERR_MSG_VACIO sin POST, exit $RC" \
  || bad "rc=$RC posts=$(nposts) out=[$(head -c 120 "$TMPD/out")]"

echo "### T2 caso 6: respuesta con espacios (esperado: DIGEST_OK2, parser tolerante)"
start_mock ok spaced; run_sut; stop_mock
grep -q DIGEST_OK2 "$TMPD/out" && [ "$RC" -eq 0 ] \
  && ok "DIGEST_OK2 con espacios" \
  || bad "rc=$RC out=[$(head -c 120 "$TMPD/out")]"

echo "### T2 caso 7: ok:false con description (esperado: PARCIAL exit 1, solo description en salida)"
start_mock tricky-false; run_sut; stop_mock
grep -q DIGEST_PARCIAL "$TMPD/out" && [ "$RC" -eq 1 ] && grep -q 'waf block' "$TMPD/out" \
  && ! grep -q 'error_code' "$TMPD/out" \
  && ok "PARCIAL con description, sin volcar JSON" \
  || bad "rc=$RC out=[$(head -c 160 "$TMPD/out")]"

echo "### T2 caso 8: HTML no-JSON con 'ok:true' adentro (esperado: PARCIAL exit 1, no falso OK)"
start_mock html-false; run_sut; stop_mock
grep -q DIGEST_PARCIAL "$TMPD/out" && [ "$RC" -eq 1 ] && ! grep -q DIGEST_OK2 "$TMPD/out" \
  && ok "HTML no cuenta como exito" \
  || bad "rc=$RC out=[$(head -c 160 "$TMPD/out")]"

echo "### T2 caso 9: ok:true sin message_id (esperado: PARCIAL exit 1, sin DIGEST_OK2)"
start_mock ok-no-mid; run_sut; stop_mock
grep -q DIGEST_PARCIAL "$TMPD/out" && [ "$RC" -eq 1 ] && ! grep -q DIGEST_OK2 "$TMPD/out" \
  && grep -q 'sin message_id' "$TMPD/out" \
  && ok "ok sin mid no cuenta como exito" \
  || bad "rc=$RC out=[$(head -c 160 "$TMPD/out")]"

echo "### T2 caso 10: chat ids con espacios/CR en env (esperado: se limpian, DIGEST_OK2)"
printf 'TELEGRAM_SALES_BOT_TOKEN=DUMMYTOKEN\nTELEGRAM_CHAT_ID=" 11111 "\nTELEGRAM_CHAT_ID_2="22222\r"\nTELEGRAM_CHAT_ID_CUSTOM=33333\n' > "$TMPD/dirty.env"
start_mock ok; run_sut "$TMPD/dirty.env"; stop_mock
[ "$(post_ids)" = "11111 22222" ] && grep -q DIGEST_OK2 "$TMPD/out" \
  && ok "chat ids limpios" \
  || bad "ids=[$(post_ids)] out=[$(head -c 120 "$TMPD/out")]"

echo "### T2 resultado: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
