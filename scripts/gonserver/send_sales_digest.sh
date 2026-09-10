#!/bin/bash
# send_sales_digest.sh <archivo_utf8> — manda el digest a Gon + Isabel, NUNCA a Wide.
# Exige "ok":true en ambos chats; exit 1 si alguno falla.
# Env (override para tests): TG_SCHEME (https), TG_API_HOST (api.telegram.org),
# TG_ENV (/home/claw/.secrets/telegram-sales.env).
# Salidas: DIGEST_OK2 ids:... | DIGEST_PARCIAL ok:n/2 | ERR_* (exit 1).
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
ok=0; ids=""; n=0
for CHAT in "$TELEGRAM_CHAT_ID" "$TELEGRAM_CHAT_ID_2"; do
  n=$((n+1))
  R="$(curl -sS -X POST "$TG_SCHEME://$TG_API_HOST/bot${TELEGRAM_SALES_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=${MSG}")" || R=""
  if echo "$R" | grep -Eq '"ok":[[:space:]]*true'; then
    MID="$(echo "$R" | grep -Eo '"message_id"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -Eo '[0-9]+')"
    ok=$((ok+1)); ids="$ids $MID"
    echo "DIGEST_OK chat#$n mid=$MID"
  else
    echo "DIGEST_ERR chat#$n: $(echo "$R" | head -c 160)"
  fi
done
if [ "$ok" -eq 2 ]; then echo "DIGEST_OK2 ids:$ids"; exit 0; fi
echo "DIGEST_PARCIAL ok:$ok/2 (reenviar completo o marcar a mano)"; exit 1
