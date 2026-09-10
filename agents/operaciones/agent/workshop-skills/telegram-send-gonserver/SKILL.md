---
name: telegram-send-gonserver
description: Send packing digests (sendMessage) and personalizadas photos (sendPhoto to Gon/Isabel/Wide) through the telegram-sales bot on gonserver via ssh. Use whenever a packing run must deliver Telegram messages or photos.
---

# Telegram Send via Gonserver

Business Telegram sends run on gonserver with `/home/claw/.secrets/telegram-sales.env` (TELEGRAM_SALES_BOT_TOKEN, TELEGRAM_CHAT_ID Gon, TELEGRAM_CHAT_ID_2 Isabel, TELEGRAM_CHAT_ID_CUSTOM Wide). Never print the token or chat ids. Verify `ok:true` in every response.

## Steps

1. Send scripts run ON gonserver: write locally, `scp` to `/tmp/`, then `ssh gonserver "bash /tmp/<script>.sh"`. Simple literal ssh shapes pass the exec binder; PowerShell base64-with-variable or chained shapes may not.
2. Text digest (all-urlencoded call, `-d`/`--data-urlencode` are correct here): `source` the env file, then per chat `curl -sS -X POST https://api.telegram.org/bot${TELEGRAM_SALES_BOT_TOKEN}/sendMessage -d chat_id="$CHAT" -d parse_mode=HTML --data-urlencode text="$MSG"`. Multi-line rich text (accents, `•`, `–`, emoji) travels byte-perfect when authored as a UTF-8 file, scp'd to `/tmp/`, and read remotely as `MSG="$(tr -d '\r' < /tmp/<file>)"` — the `tr` strips Windows CRLF that would otherwise leave artifacts — then passed with `--data-urlencode`; confirm rendering from the echoed `text` field plus the returned `message_id`.
3. Photos: prefer the installed helper `/home/claw/packing/send_pers_photo.sh <order_id> <jpg> "$(cat <caption_file>)"` — it flocks, dedups against `/home/claw/packing/personalizadas-sent.json`, sends to the three chats, and marks the json only after `ok:true` ×3. From PowerShell, single-quote the ENTIRE remote command (`ssh gonserver 'bash /home/claw/packing/send_pers_photo.sh <order_id> /tmp/<jpg> "$(cat /tmp/<caption_file>)"'`) so `$(cat ...)` expands in remote bash — double quotes make PowerShell expand it locally and can send an empty caption. Template for the scp-then-run wrapper: `tmp/backfill_sendphoto.sh` in the operations workspace; helper source: `tmp/send_pers_photo.sh`.
4. Hand-writing a sendPhoto curl: multipart only — `-F chat_id= -F photo=@file -F parse_mode=HTML -F caption="..."`. NEVER mix `-F` with `--data-urlencode` or `-d`: curl rejects the combination and returns an EMPTY response, and with `-s` (without `-S`) the error is completely silent — the send fails with no visible cause (verified: three empty responses in a row). Always use `-sS`.
5. A partial photo failure does NOT mark the dedup json — rerunning the helper is safe; `YA_ENVIADA <order>` means dedup already covered it.

## Completion check

- sendMessage: `ok:true` with a `message_id` for each chat.
- sendPhoto via helper: `ENVIADA_OK3 <order> ids:...` in the output.
