#!/bin/bash
# send_sales_digest.sh <archivo_utf8> — manda el digest a Gon + Isabel, NUNCA a Wide.
# Exige "ok":true o un recibo previo explícito en cada chat; exit 1 si alguno falla.
# Env (override para tests): TG_SCHEME (https), TG_API_HOST (api.telegram.org),
# TG_ENV (/home/claw/.secrets/telegram-sales.env).
# TG_SKIP_CHATS_CON_RECIBO="1,2" omite solo chats ya verificados por el llamador.
# TG_SOLO_CHATS="1|2" limita el envío al chat cuyo contenido diferencial se preparó.
# Salidas: DIGEST_OK2 | DIGEST_OK_SELECCION | DIGEST_PARCIAL | ERR_* (exit 1).
# Nunca imprime token ni chat ids.
set -u
F="${1:?uso: send_sales_digest.sh <archivo_utf8>}"
TG_API_HOST="${TG_API_HOST:-api.telegram.org}"
TG_SCHEME="${TG_SCHEME:-https}"
TG_ENV="${TG_ENV:-/home/claw/.secrets/telegram-sales.env}"
[ -f "$TG_ENV" ] || { echo "ERR_ENV falta $TG_ENV"; exit 1; }
set -a; source "$TG_ENV"; set +a
: "${TELEGRAM_SALES_BOT_TOKEN:?ERR_ENV falta TELEGRAM_SALES_BOT_TOKEN}"
: "${TELEGRAM_CHAT_ID:?ERR_ENV falta TELEGRAM_CHAT_ID}"
: "${TELEGRAM_CHAT_ID_2:?ERR_ENV falta TELEGRAM_CHAT_ID_2}"
[ -f "$F" ] || { echo "ERR_NO_FILE $F"; exit 1; }
MSG="$(tr -d '\r' < "$F")"
[ -n "$MSG" ] || { echo "ERR_MSG_VACIO $F"; exit 1; }
[ "${#MSG}" -le 4096 ] || { echo "ERR_MSG_LARGO ${#MSG} chars (max 4096), nada enviado"; exit 1; }
TG_SKIP_CHATS_CON_RECIBO="${TG_SKIP_CHATS_CON_RECIBO:-}"
TG_SOLO_CHATS="${TG_SOLO_CHATS:-}"
for SKIP in ${TG_SKIP_CHATS_CON_RECIBO//,/ }; do
  case "$SKIP" in
    1|2) ;;
    *) echo "ERR_SKIP_CHAT $SKIP (solo 1,2 con recibo verificado)"; exit 1 ;;
  esac
  case ",$TG_SOLO_CHATS," in
    *",$SKIP,"*) echo "ERR_SKIP_CHAT $SKIP (también seleccionado para envío)"; exit 1 ;;
  esac
done
selected=2
if [ -n "$TG_SOLO_CHATS" ]; then
  selected=0
  for SOLO in ${TG_SOLO_CHATS//,/ }; do
    case "$SOLO" in
      1|2) ;;
      *) echo "ERR_SOLO_CHAT $SOLO (solo 1,2)"; exit 1 ;;
    esac
  done
  for n in 1 2; do
    case ",$TG_SOLO_CHATS," in *",$n,"*) selected=$((selected+1)) ;; esac
  done
fi
# tg_parse: una linea "OK <mid>" o "FAIL <descripcion>" (parseo JSON real, no grep).
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
ok=0; omitted=0; ids=""; n=0
for CHAT_RAW in "$TELEGRAM_CHAT_ID" "$TELEGRAM_CHAT_ID_2"; do
  n=$((n+1))
  if [ -n "$TG_SOLO_CHATS" ]; then
    case ",$TG_SOLO_CHATS," in *",$n,"*) ;; *) continue ;; esac
  fi
  case ",$TG_SKIP_CHATS_CON_RECIBO," in
    *",$n,"*) omitted=$((omitted+1)); echo "DIGEST_OMITIDO chat#$n recibo previo"; continue ;;
  esac
  CHAT="${CHAT_RAW//[[:space:]]/}"
  R="$(curl -sS --connect-timeout 10 --max-time 60 -X POST "$TG_SCHEME://$TG_API_HOST/bot${TELEGRAM_SALES_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=${MSG}")" || R=""
  PO="$(tg_parse "$R")"
  case "$PO" in
    "OK "|OK) echo "DIGEST_ERR chat#$n: ok:true sin message_id" ;;
    OK\ *)
      MID="${PO#OK }"; ok=$((ok+1)); ids="$ids $MID"
      echo "DIGEST_OK chat#$n mid=$MID" ;;
    *) echo "DIGEST_ERR chat#$n: ${PO#FAIL }" ;;
  esac
done
if [ "$((ok+omitted))" -eq "$selected" ]; then
  if [ "$selected" -eq 2 ]; then echo "DIGEST_OK2 ids:$ids omitidos:$omitted"; exit 0; fi
  echo "DIGEST_OK_SELECCION chats:$TG_SOLO_CHATS ids:$ids omitidos:$omitted"; exit 0
fi
echo "DIGEST_PARCIAL ok:$ok/$selected omitidos:$omitted (reintentar solo destinos sin recibo)"; exit 1
