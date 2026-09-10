#!/bin/bash
# T4 (discrimina #6): send_pers_photo.sh contra mock local, sin red real.
# Uso en gonserver como claw:
#   ./t4_persphoto.sh <script_bajo_prueba> [--legacy-de]
# --legacy-de: el v1 tiene PDIR/URL/env hardcodeados; el arnes los parcha en /tmp
# (conserva -F caption=, que es el bug) y corre solo casos (d) y (e).
# Exit 0 = todos los casos PASS; 1 = alguno FAIL; 2 = infra (mock no arranco).
set -u
SUT="${1:?uso: t4_persphoto.sh <script> [--legacy-de]}"
LEGACY="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MOCK="$HERE/tg_mock.py"
TMPD="$(mktemp -d /tmp/t4.XXXXXX)"
trap 'chmod -R u+w "$TMPD" 2>/dev/null; rm -rf "$TMPD"; [ -n "${MOCK_PID:-}" ] && kill "${MOCK_PID}" 2>/dev/null' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$TMPD/tg_test.env" <<'EOF'
TELEGRAM_SALES_BOT_TOKEN=DUMMYTOKEN
TELEGRAM_CHAT_ID=11111
TELEGRAM_CHAT_ID_2=22222
TELEGRAM_CHAT_ID_CUSTOM=33333
EOF
printf 'FAKEJPGDATA' > "$TMPD/foto.jpg"
PDIR="$TMPD/p"; mkdir -p "$PDIR"
CAPN='foto prueba pedido 999'

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
run_sut() { # $1=order $2=caption [$3=env] -> $TMPD/out, RC
  local env="${3:-$TMPD/tg_test.env}"
  if [ -n "$LEGACY" ]; then
    sed -e "s|https://api.telegram.org|http://127.0.0.1:$MOCK_PORT|" \
        -e "s|source /home/claw/.secrets/telegram-sales.env|source $TMPD/tg_test.env|" \
        -e "s|^PDIR=/home/claw/packing|PDIR=$PDIR|" \
        "$SUT" > "$TMPD/legacy.sh"
    bash "$TMPD/legacy.sh" "$1" "$TMPD/foto.jpg" "$2" > "$TMPD/out" 2>&1; RC=$?
  else
    TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$env" PDIR="$PDIR" \
      bash "$SUT" "$1" "$TMPD/foto.jpg" "$2" > "$TMPD/out" 2>&1; RC=$?
  fi
}
nposts() { wc -l < "$TMPD/mock.log" 2>/dev/null || echo 0; }
jget() { python3 -c "import json;print(json.load(open('$PDIR/personalizadas-sent.json'))$1)" 2>/dev/null; }
jlen() { python3 -c "import json;print(len(json.load(open('$PDIR/personalizadas-sent.json'))$1))" 2>/dev/null; }

if [ -z "$LEGACY" ]; then
echo "### T4 caso a: mock ok x3 (esperado: ENVIADA_OK3 exit 0, ok3:true, json 600)"
start_mock ok; run_sut ORD-A "$CAPN"; stop_mock
[ "$(nposts)" -eq 3 ] && [ "$RC" -eq 0 ] && grep -q ENVIADA_OK3 "$TMPD/out" \
  && [ "$(jget "['ORD-A']['ok3']")" = True ] && [ "$(stat -c %a "$PDIR/personalizadas-sent.json")" = 600 ] \
  && ok "ENVIADA_OK3 exit 0, ok3:true, 3 POST, json 600" \
  || bad "posts=$(nposts) rc=$RC mode=$(stat -c %a "$PDIR/personalizadas-sent.json") out=[$(head -c 150 "$TMPD/out")]"

echo "### T4 caso a2: respuesta con espacios (esperado: ENVIADA_OK3, 3 POST)"
start_mock ok spaced; run_sut ORD-AS "$CAPN"; stop_mock
grep -q ENVIADA_OK3 "$TMPD/out" && [ "$(nposts)" -eq 3 ] \
  && ok "ENVIADA_OK3 con espacios, 3 POST" \
  || bad "posts=$(nposts) rc=$RC out=[$(head -c 150 "$TMPD/out")]"

echo "### T4 caso b: rerun orden propia (esperado: 2da YA_ENVIADA, 0 POST)"
start_mock ok; run_sut ORD-B "$CAPN" >/dev/null 2>&1; stop_mock
start_mock ok; run_sut ORD-B "$CAPN"; stop_mock
[ "$(nposts)" -eq 0 ] && grep -q YA_ENVIADA "$TMPD/out" \
  && ok "YA_ENVIADA sin POST" \
  || bad "posts=$(nposts) out=[$(head -c 150 "$TMPD/out")]"

echo "### T4 caso c: falla el 3ro -> parcial {1,2}; rerun manda solo #3"
start_mock fail-third; run_sut ORD-C "$CAPN"; RC1=$RC; OUT1="$(cat "$TMPD/out")"; stop_mock
PART="$(jget "['ORD-C'].get('partial',{})" | python3 -c 'import ast,sys;print(sorted(ast.literal_eval(sys.stdin.read()).keys()))')"
echo "$OUT1" | grep -q ERR_PARCIAL && [ "$RC1" -eq 1 ] && [ "$PART" = "['1', '2']" ] \
  && ok "ERR_PARCIAL exit 1, partial {1,2}" \
  || bad "rc=$RC1 partial=$PART out=[$(echo "$OUT1" | head -c 150)]"
start_mock ok; run_sut ORD-C "$CAPN"; stop_mock
CHATS="$(python3 -c "import json;print(' '.join(json.loads(l)['chat_id'] for l in open('$TMPD/mock.log')))" 2>/dev/null)"
[ "$(nposts)" -eq 1 ] && [ "$CHATS" = 33333 ] && grep -q ENVIADA_OK3 "$TMPD/out" \
  && [ "$(jget "['ORD-C']['ok3']")" = True ] && [ "$(jlen "['ORD-C']['msg_ids']")" -eq 3 ] \
  && ok "reintento: 1 POST a #3, ENVIADA_OK3, ok3 con 3 mids" \
  || bad "posts=$(nposts) chats=[$CHATS] out=[$(head -c 150 "$TMPD/out")]"

echo "### T4 caso f: partial con basura (esperado: se ignora, ENVIADA_OK3 con ok3:true)"
python3 -c "import json;p='$PDIR/personalizadas-sent.json';d=json.load(open(p));d['ORD-F']={'sent_at_utc':'x','msg_ids':[],'ok3':False,'partial':{'x':1}};json.dump(d,open(p,'w'))"
start_mock ok; run_sut ORD-F "$CAPN"; stop_mock
[ "$(nposts)" -eq 3 ] && grep -q ENVIADA_OK3 "$TMPD/out" \
  && [ "$(jget "['ORD-F']['ok3']")" = True ] && [ "$(jlen "['ORD-F']['msg_ids']")" -eq 3 ] \
  && ok "basura ignorada, 3 mids acumulados" \
  || bad "posts=$(nposts) ok3=$(jget "['ORD-F']['ok3']") out=[$(head -c 150 "$TMPD/out")]"

echo "### T4 caso g: ok:false con description (esperado: ERR_PARCIAL, solo description)"
start_mock tricky-false; run_sut ORD-G "$CAPN"; stop_mock
grep -q ERR_PARCIAL "$TMPD/out" && [ "$RC" -eq 1 ] && grep -q 'waf block' "$TMPD/out" \
  && ! grep -q 'error_code' "$TMPD/out" \
  && ok "PARCIAL con description, sin volcar JSON" \
  || bad "rc=$RC out=[$(head -c 160 "$TMPD/out")]"

echo "### T4 caso h: HTML no-JSON (esperado: ERR_PARCIAL, no falso OK3)"
start_mock html-false; run_sut ORD-H "$CAPN"; stop_mock
grep -q ERR_PARCIAL "$TMPD/out" && [ "$RC" -eq 1 ] && ! grep -q ENVIADA_OK3 "$TMPD/out" \
  && ok "HTML no cuenta como exito" \
  || bad "rc=$RC out=[$(head -c 160 "$TMPD/out")]"

echo "### T4 caso i: ok:true sin message_id (esperado: ERR_PARCIAL con aviso explicito)"
start_mock ok-no-mid; run_sut ORD-I "$CAPN"; stop_mock
grep -q ERR_PARCIAL "$TMPD/out" && [ "$RC" -eq 1 ] && grep -q 'sin message_id' "$TMPD/out" \
  && ok "ok sin mid no se marca" \
  || bad "rc=$RC out=[$(head -c 160 "$TMPD/out")]"

echo "### T4 caso j: chat ids con espacios/CR en env (esperado: se limpian)"
printf 'TELEGRAM_SALES_BOT_TOKEN=DUMMYTOKEN\nTELEGRAM_CHAT_ID=" 11111 "\nTELEGRAM_CHAT_ID_2="22222\r"\nTELEGRAM_CHAT_ID_CUSTOM=" 33333"\n' > "$TMPD/dirty.env"
start_mock ok; run_sut ORD-J "$CAPN" "$TMPD/dirty.env"; stop_mock
CHATS="$(python3 -c "import json;print(' '.join(json.loads(l)['chat_id'] for l in open('$TMPD/mock.log')))" 2>/dev/null)"
[ "$CHATS" = "11111 22222 33333" ] && grep -q ENVIADA_OK3 "$TMPD/out" \
  && ok "chat ids limpios" \
  || bad "chats=[$CHATS] out=[$(head -c 150 "$TMPD/out")]"
fi

echo "### T4 caso d: json no escribible (v2 esperado: ERR_JSON_WRITE exit 2, 3 POST)"
CAPD='foto prueba orden D'
start_mock ok; run_sut ORD-SEED "$CAPD" >/dev/null 2>&1; stop_mock
start_mock ok
chmod 555 "$PDIR"; chmod 444 "$PDIR/personalizadas-sent.json"
run_sut "ORD-D" "$CAPD"
chmod 755 "$PDIR"; chmod 644 "$PDIR/personalizadas-sent.json"
stop_mock
if [ -n "$LEGACY" ]; then
  grep -q ENVIADA_OK3 "$TMPD/out" && [ "$RC" -eq 0 ] \
    && bad "ROJO reproducido: v1 dice ENVIADA_OK3 exit 0 aunque json NO se marco" \
    || ok "v1 no afirma exito (inesperado)"
else
  grep -q ERR_JSON_WRITE "$TMPD/out" && ! grep -q ENVIADA_OK3 "$TMPD/out" && [ "$RC" -eq 2 ] \
    && [ "$(nposts)" -eq 3 ] \
    && ok "ERR_JSON_WRITE exit 2, 3 fotos enviadas, sin ENVIADA_OK3" \
    || bad "posts=$(nposts) rc=$RC out=[$(head -c 150 "$TMPD/out")]"
fi

echo "### T4 caso e: captions con < y @ iniciales (esperado: caption intacto)"
for CAPE in '<b>x</b> pedido' '@x pedido'; do
  start_mock ok; run_sut "ORD-E$RANDOM" "$CAPE"; stop_mock
  GOT="$(python3 -c "import json;print([json.loads(l)['caption'] for l in open('$TMPD/mock.log')][0])" 2>/dev/null)"
  if [ -n "$LEGACY" ]; then
    [ "$GOT" = "$CAPE" ] \
      && ok "caption intacto (inesperado en v1)" \
      || bad "ROJO reproducido: caption '$CAPE' llego como [$GOT] (posts=$(nposts))"
  else
    [ "$GOT" = "$CAPE" ] \
      && ok "caption intacto: [$CAPE]" \
      || bad "caption '$CAPE' llego como [$GOT] (posts=$(nposts))"
  fi
done

echo "### T4 resultado: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
