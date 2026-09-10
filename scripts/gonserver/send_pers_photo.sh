#!/bin/bash
# send_pers_photo.sh <order_id> <jpg_path> <caption_html> — v2
# Dedup + sendPhoto x3 (1=Gon, 2=Isabel, 3=Wide) + registro atomico en JSON bajo flock.
# Registro parcial por INDICE (nunca el chat id):
#   {"<order>": {"sent_at_utc":..,"msg_ids":[m1,m2,m3],"ok3":bool,"partial":{"1":mid,"2":mid}}}
# Dedup: ok3:true -> YA_ENVIADA; si hay partial, solo manda los indices faltantes.
# Env (override para tests): TG_SCHEME (https), TG_API_HOST (api.telegram.org),
# TG_ENV (/home/claw/.secrets/telegram-sales.env), PDIR (/home/claw/packing).
# Salidas: YA_ENVIADA <order> | ENVIADA_OK3 <order> ids:.. | ERR_NO_LOCK | ERR_PARCIAL |
#          ERR_NO_JPG | ERR_JSON_WRITE (exit 2) | ERR_JSON_READ (exit 2).
# Nunca imprime token ni chat ids.
set -u
umask 077
ORDER="${1:?falta order_id}"; JPG="${2:?falta jpg}"; CAPTION="${3:?falta caption}"
TG_API_HOST="${TG_API_HOST:-api.telegram.org}"
TG_SCHEME="${TG_SCHEME:-https}"
TG_ENV="${TG_ENV:-/home/claw/.secrets/telegram-sales.env}"
PDIR="${PDIR:-/home/claw/packing}"
JSON="$PDIR/personalizadas-sent.json"
LOCK="$PDIR/personalizadas-sent.lock"
mkdir -p "$PDIR"
[ -f "$JPG" ] || { echo "ERR_NO_JPG $JPG"; exit 1; }
[ -f "$TG_ENV" ] || { echo "ERR_ENV falta $TG_ENV"; exit 1; }
set -a; source "$TG_ENV"; set +a
: "${TELEGRAM_SALES_BOT_TOKEN:?ERR_ENV falta TELEGRAM_SALES_BOT_TOKEN}"
: "${TELEGRAM_CHAT_ID:?ERR_ENV falta TELEGRAM_CHAT_ID}"
: "${TELEGRAM_CHAT_ID_2:?ERR_ENV falta TELEGRAM_CHAT_ID_2}"
: "${TELEGRAM_CHAT_ID_CUSTOM:?ERR_ENV falta TELEGRAM_CHAT_ID_CUSTOM}"
exec 9>"$LOCK"
flock -w 20 9 || { echo "ERR_NO_LOCK $ORDER"; exit 1; }
[ -f "$JSON" ] || echo '{}' > "$JSON"
read_state() {
  python3 - "$JSON" "$ORDER" <<'PY' 2>/dev/null
import json,sys
p,o=sys.argv[1],sys.argv[2]
d=json.load(open(p))
e=d.get(o) or {}
if e.get("ok3"):
    print("YA"); sys.exit(0)
for k,v in (e.get("partial") or {}).items():
    print(f"PREV {k} {v}")
PY
}
STATE="$(read_state)" || { echo "ERR_JSON_READ $ORDER"; exit 2; }
if [ "$STATE" = "YA" ]; then echo "YA_ENVIADA $ORDER"; exit 0; fi
PREV1=""; PREV2=""; PREV3=""
while read -r _ idx mid; do
  case "$idx" in
    1) PREV1="$mid";; 2) PREV2="$mid";; 3) PREV3="$mid";;
  esac
done <<< "$STATE"
CHAT1="$TELEGRAM_CHAT_ID"; CHAT2="$TELEGRAM_CHAT_ID_2"; CHAT3="$TELEGRAM_CHAT_ID_CUSTOM"
NEW1=""; NEW2=""; NEW3=""
tg_parse() { printf '%s' "$1" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FAIL respuesta no-JSON"); sys.exit(0)
if d.get("ok") is True:
    print("OK", d.get("result", {}).get("message_id", ""))
else:
    print("FAIL", str(d.get("description", "sin description")).replace("\n", " ")[:160])'; }
send_one() { # $1=idx $2=chat -> imprime MID o nada (errores a stderr)
  local idx="$1" chat_raw="$2" R PO
  local chat="${chat_raw//[[:space:]]/}"
  R="$(curl -sS --connect-timeout 10 --max-time 60 -X POST "$TG_SCHEME://$TG_API_HOST/bot${TELEGRAM_SALES_BOT_TOKEN}/sendPhoto" \
      --form-string "chat_id=$chat" --form-string "parse_mode=HTML" \
      --form-string "caption=$CAPTION" -F photo=@"$JPG")" || R=""
  PO="$(tg_parse "$R")"
  case "$PO" in
    "OK "|OK) echo "ERR_CHAT chat#$idx: ok:true sin message_id" >&2 ;;
    OK\ *) echo "${PO#OK }" ;;
    *) echo "ERR_CHAT chat#$idx: ${PO#FAIL }" >&2 ;;
  esac
}
[ -n "$PREV1" ] || NEW1="$(send_one 1 "$CHAT1")"
[ -n "$PREV2" ] || NEW2="$(send_one 2 "$CHAT2")"
[ -n "$PREV3" ] || NEW3="$(send_one 3 "$CHAT3")"
ARGS=""
[ -n "$NEW1" ] && ARGS="$ARGS 1=$NEW1"
[ -n "$NEW2" ] && ARGS="$ARGS 2=$NEW2"
[ -n "$NEW3" ] && ARGS="$ARGS 3=$NEW3"
# shellcheck disable=SC2086
if ! python3 - "$JSON" "$ORDER" $ARGS <<'PY'; then
import json,os,sys,datetime
p,o=sys.argv[1],sys.argv[2]
new=dict(a.split("=",1) for a in sys.argv[3:])
d=json.load(open(p))
e=d.get(o) or {}
merged={k: v for k, v in (e.get("partial") or {}).items() if k in ("1", "2", "3")}
for k, v in new.items():
    if k in ("1", "2", "3"):
        merged[k] = v
sent_at=e.get("sent_at_utc") or (datetime.datetime.now(datetime.timezone.utc).isoformat())
ok3=len(merged)==3
d[o]={"sent_at_utc":sent_at,
      "msg_ids":[int(merged[str(i)]) for i in (1,2,3)] if ok3 else [],
      "ok3":ok3, "partial":{} if ok3 else merged}
tmp=p+".tmp"
json.dump(d,open(tmp,"w"),indent=1)
os.replace(tmp,p)
PY
  echo "ERR_JSON_WRITE $ORDER (fotos ENVIADAS, json NO marcado: marcar a mano)"; exit 2
fi
HAVE=0; IDS=""
for i in 1 2 3; do
  case "$i" in
    1) M="${NEW1:-$PREV1}";; 2) M="${NEW2:-$PREV2}";; 3) M="${NEW3:-$PREV3}";;
  esac
  if [ -n "$M" ]; then HAVE=$((HAVE+1)); IDS="$IDS $M"; fi
done
if [ "$HAVE" -eq 3 ]; then echo "ENVIADA_OK3 $ORDER ids:$IDS"; exit 0; fi
echo "ERR_PARCIAL $ORDER ok:$HAVE/3 (marcado parcial en json; reintentar manda solo faltantes)"; exit 1
