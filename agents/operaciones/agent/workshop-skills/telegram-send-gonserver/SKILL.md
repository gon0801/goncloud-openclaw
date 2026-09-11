---
name: telegram-send-gonserver
description: Send packing digests (sendMessage) and personalizadas photos (sendPhoto to Gon/Isabel/Wide) through the telegram-sales bot on gonserver via ssh. Use whenever a packing run must deliver Telegram messages or photos.
---

# Telegram Send via Gonserver

Business Telegram sends run on gonserver with `/home/claw/.secrets/telegram-sales.env` (TELEGRAM_SALES_BOT_TOKEN, TELEGRAM_CHAT_ID Gon, TELEGRAM_CHAT_ID_2 Isabel, TELEGRAM_CHAT_ID_CUSTOM Wide). Never print the token or chat ids. Verify `ok:true` in every response.

## Steps

1. Send scripts run ON gonserver: write locally, `scp` to `/tmp/`, then `ssh gonserver "bash /tmp/<script>.sh"`. Simple literal ssh shapes pass the exec binder; PowerShell base64-with-variable or chained shapes may not.
2. Text digest ONLY through the helper `/home/claw/send_sales_digest.sh <archivo_utf8>`: author the digest as a UTF-8 file (accents, `•`, `–`, emoji travel byte-perfect), `scp` to `/tmp/`, then `ssh gonserver "bash /home/claw/send_sales_digest.sh /tmp/<file>"`. The helper strips CRLF, sends to Gon + Isabel (never Wide), requires `ok:true` on both (`DIGEST_OK2 ids:...`), and exits 1 otherwise (`DIGEST_PARCIAL`). Never hand-roll curl for a digest.
3. Photos: prefer the installed helper `/home/claw/packing/send_pers_photo.sh <order_id> <jpg> "$(cat <caption_file>)"` — it flocks, dedups against `/home/claw/packing/personalizadas-sent.json`, sends to the three chats, and marks the json only after `ok:true` ×3. The flock+dedup is not optional protection: the gateway can RETRY an ssh exec after losing the tool result, running your script twice (verified: one invocation sent the photos and marked the json at 02:58:05Z; the retry returned `YA_ENVIADA` and sent nothing) — any hand-rolled send loop without dedup would have double-delivered. From PowerShell, single-quote the ENTIRE remote command (`ssh gonserver 'bash /home/claw/packing/send_pers_photo.sh <order_id> /tmp/<jpg> "$(cat /tmp/<caption_file>)"'`) so `$(cat ...)` expands in remote bash — double quotes make PowerShell expand it locally and can send an empty caption. Template for the scp-then-run wrapper: `tmp/backfill_sendphoto.sh` in the operations workspace; helper source: `tmp/send_pers_photo.sh`. If a helper run returns `YA_ENVIADA` unexpectedly, check `personalizadas-sent.json` timestamps and msg-id sequence before assuming someone else sent: a gateway retry of YOUR OWN earlier call may have delivered it.
4. Hand-writing a sendPhoto curl: multipart only — `--form-string chat_id= --form-string parse_mode=HTML --form-string caption="..." -F photo=@file`. NEVER mix `-F` with `--data-urlencode` or `-d`: curl rejects the combination and returns an EMPTY response, and with `-s` (without `-S`) the error is completely silent — the send fails with no visible cause (verified: three empty responses in a row). Always use `-sS`. A caption starting with `<` or `@` under plain `-F caption=` is read as a file reference (send fails or caption arrives empty) — `--form-string` sends it literally.
5. A partial photo failure does NOT mark the dedup json — rerunning the helper is safe; `YA_ENVIADA <order>` means dedup already covered it.

## Completion check

- sendMessage: `ok:true` with a `message_id` for each chat.
- sendPhoto via helper: `ENVIADA_OK3 <order> ids:...` in the output.
