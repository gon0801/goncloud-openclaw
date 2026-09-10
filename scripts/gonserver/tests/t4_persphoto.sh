#!/bin/bash
# T4 (discrimina #6): send_pers_photo.sh contra mock local, sin red real.
# Uso en gonserver como claw:
#   ./t4_persphoto.sh <script_bajo_prueba> [--legacy-de]
# --legacy-de: el v1 tiene PDIR/URL/env hardcodeados; el arnes los parcha en /tmp
# (conserva -F caption=, que es el bug) y corre solo casos (d) y (e).
# Exit 0 = todos los casos PASS; != 0 = alguno FAIL.
set -u
SUT="${1:?uso: t4_persphoto.sh <script> [--legacy-de]}"
LEGACY="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MOCK="$HERE/tg_mock.py"
TMPD="$(mktemp -d /tmp/t4.XXXXXX)"
trap 'chmod -R u+w "$TMPD" 2>/dev/null; rm -rf "$TMPD"; pkill -f "tg_mock.py --mode" 2>/dev/null' EXIT
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
CAP='<b>pedido 999</b> foto prueba'

start_mock() { # $1=mode $2=separators
  rm -f "$TMPD/mock.log" "$TMPD/mock.port"
  python3 "$MOCK" --mode "$1" --separators "${2:-compact}" --log "$TMPD/mock.log" > "$TMPD/mock.port" 2>&1 &
  for _ in $(seq 1 50); do grep -q MOCK_PORT "$TMPD/mock.port" 2>/dev/null && break; sleep 0.1; done
  MOCK_PORT="$(sed 's/MOCK_PORT=//' "$TMPD/mock.port")"
}
stop_mock() { pkill -f "tg_mock.py --mode" 2>/dev/null; sleep 0.3; }
run_sut() { # $1=order $2=caption -> $TMPD/out, RC
  if [ -n "$LEGACY" ]; then
    sed -e "s|https://api.telegram.org|http://127.0.0.1:$MOCK_PORT|" \
        -e "s|source /home/claw/.secrets/telegram-sales.env|source $TMPD/tg_test.env|" \
        -e "s|^PDIR=/home/claw/packing|PDIR=$PDIR|" \
        "$SUT" > "$TMPD/legacy.sh"
    bash "$TMPD/legacy.sh" "$1" "$TMPD/foto.jpg" "$2" > "$TMPD/out" 2>&1; RC=$?
  else
    TG_SCHEME=http TG_API_HOST="127.0.0.1:$MOCK_PORT" TG_ENV="$TMPD/tg_test.env" PDIR="$PDIR" \
      bash "$SUT" "$1" "$TMPD/foto.jpg" "$2" > "$TMPD/out" 2>&1; RC=$?
  fi
}
nposts() { wc -l < "$TMPD/mock.log" 2>/dev/null || echo 0; }

if [ -z "$LEGACY" ]; then
echo "### T4 caso a: mock ok x3 (esperado: ENVIADA_OK3, json con orden)"
start_mock ok; run_sut ORD-A "$CAP"; stop_mock
OK3="$(python3 -c "import json;print(json.load(open('$PDIR/personalizadas-sent.json')).get('ORD-A',{}).get('ok3'))" 2>/dev/null)"
[ "$(nposts)" = 3 ] && grep -q ENVIADA_OK3 "$TMPD/out" && [ "$OK3" = True ] \
  && ok "ENVIADA_OK3, ok3:true, 3 POST" \
  || bad "posts=$(nposts) ok3=$OK3 rc=$RC out=[$(head -c 150 "$TMPD/out")]"

echo "### T4 caso a2: respuesta con espacios (esperado: ENVIADA_OK3, parser tolerante)"
start_mock ok spaced; run_sut ORD-AS "$CAP"; stop_mock
grep -q ENVIADA_OK3 "$TMPD/out" \
  && ok "ENVIADA_OK3 con espacios" \
  || bad "rc=$RC out=[$(head -c 150 "$TMPD/out")]"

echo "### T4 caso b: rerun (esperado: YA_ENVIADA, 0 POST)"
start_mock ok; run_sut ORD-A "$CAP"; stop_mock
[ "$(nposts)" = 0 ] && grep -q YA_ENVIADA "$TMPD/out" \
  && ok "YA_ENVIADA sin POST" \
  || bad "posts=$(nposts) out=[$(head -c 150 "$TMPD/out")]"

echo "### T4 caso c: falla el 3ro -> parcial {1,2}; rerun manda solo #3"
start_mock fail-third; run_sut ORD-C "$CAP"; RC1=$RC; OUT1="$(cat "$TMPD/out")"; stop_mock
PART="$(python3 -c "import json;print(sorted(json.load(open('$PDIR/personalizadas-sent.json'))['ORD-C']['partial'].keys()))" 2>/dev/null)"
echo "$OUT1" | grep -q ERR_PARCIAL && [ "$RC1" = 1 ] && [ "$PART" = "['1', '2']" ] \
  && ok "ERR_PARCIAL exit 1, partial {1,2}" \
  || bad "rc=$RC1 partial=$PART out=[$(echo "$OUT1" | head -c 150)]"
start_mock ok; run_sut ORD-C "$CAP"; stop_mock
CHATS="$(python3 -c "import json;print(' '.join(json.loads(l)['chat_id'] for l in open('$TMPD/mock.log')))" 2>/dev/null)"
MIDS="$(python3 -c "import json;print(len(json.load(open('$PDIR/personalizadas-sent.json'))['ORD-C']['msg_ids']))" 2>/dev/null)"
[ "$(nposts)" = 1 ] && [ "$CHATS" = 33333 ] && grep -q ENVIADA_OK3 "$TMPD/out" && [ "$MIDS" = 3 ] \
  && ok "reintento: 1 POST a #3, ENVIADA_OK3, 3 mids" \
  || bad "posts=$(nposts) chats=[$CHATS] mids=$MIDS out=[$(head -c 150 "$TMPD/out")]"
fi

echo "### T4 caso d: json no escribible (v2 esperado: ERR_JSON_WRITE exit 2)"
CAPD='foto prueba orden D'
start_mock ok; run_sut ORD-SEED "$CAPD" >/dev/null 2>&1; stop_mock
start_mock ok
chmod 555 "$PDIR"; chmod 444 "$PDIR/personalizadas-sent.json"
run_sut "ORD-D" "$CAPD"
chmod 755 "$PDIR"; chmod 644 "$PDIR/personalizadas-sent.json"
stop_mock
if [ -n "$LEGACY" ]; then
  grep -q ENVIADA_OK3 "$TMPD/out" && [ "$RC" = 0 ] \
    && bad "ROJO reproducido: v1 dice ENVIADA_OK3 exit 0 aunque json NO se marco" \
    || ok "v1 no afirma exito (inesperado)"
else
  grep -q ERR_JSON_WRITE "$TMPD/out" && ! grep -q ENVIADA_OK3 "$TMPD/out" && [ "$RC" = 2 ] \
    && ok "ERR_JSON_WRITE exit 2, sin ENVIADA_OK3" \
    || bad "rc=$RC out=[$(head -c 150 "$TMPD/out")]"
fi

echo "### T4 caso e: captions con < y @ iniciales (esperado: caption intacto)"
for CAPE in '<b>x</b> pedido' '@x pedido'; do
  start_mock ok; run_sut "ORD-E$RANDOM" "$CAPE"; stop_mock
  GOT="$(python3 -c "import json;print([json.loads(l)['caption'] for l in open('$TMPD/mock.log')][0])" 2>/dev/null)"
  if [ -n "$LEGACY" ]; then
    [ "$GOT" = "$CAPE" ] && NOCR=1 || NOCR=0
    [ "$NOCR" = 0 ] \
      && bad "ROJO reproducido: caption '$CAPE' llego como [$GOT] (posts=$(nposts))" \
      || ok "caption intacto (inesperado en v1)"
  else
    [ "$GOT" = "$CAPE" ] \
      && ok "caption intacto: [$CAPE]" \
      || bad "caption '$CAPE' llego como [$GOT] (posts=$(nposts))"
  fi
done

echo "### T4 resultado: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
