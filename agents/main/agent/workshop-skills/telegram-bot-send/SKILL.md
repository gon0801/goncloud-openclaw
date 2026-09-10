---
name: telegram-bot-send
description: Send Telegram notifications through the sales bot (Odoo Alerts) from goncloud over SSH. Use for "mándalo por Telegram", notifying Isabel/Wide/Gon of packing or personalizada orders, or any bot sendMessage using /home/claw/.secrets/telegram-sales.env. Produces delivered messages verified by ok:true/message_id without exposing the token.
---

# Telegram Bot Send (goncloud via SSH)

Send messages through the sales bot without ever exposing the token or the chat IDs. The credentials file lives on goncloud at `/home/claw/.secrets/telegram-sales.env` (owner claw, mode 600). Verified 2026-09-08: `getMe` OK (bot "Odoo Alerts", @goncloud_alerts_bot) and successful sends to Isabel and Wide.

Variables (reference by name; never print their values):
- `TELEGRAM_SALES_BOT_TOKEN` — bot token
- `TELEGRAM_CHAT_ID_2` — Isabel
- `TELEGRAM_CHAT_ID_CUSTOM` — Wide
- `TELEGRAM_CHAT_ID` — Gon (David)

## Steps

1. Write the whole send as a bash script in the local workspace (e.g. `tmp/<name>.sh`) — do NOT inline it in the ssh command. PowerShell `ssh gonserver "curl '...bot\${VAR}/getMe'"` breaks: single quotes around the API URL stop bash from expanding the variable, so the token never reaches the URL and Telegram answers `404 Not Found`; PowerShell also mangles `$` and backslashes in complex one-liners. A script file avoids all of it.
   - Completion: local script saved with the exact recipients and message text.

2. Copy and run: `scp tmp/<name>.sh gonserver:/home/claw/<name>.sh`, then `ssh gonserver "bash /home/claw/<name>.sh"`. Confirm the remote file is non-zero before running — a 0-byte copy means scp failed and the run silently does nothing.
   - Completion: ssh returns the script's curl output.

3. Script shape (verified working):
   ```bash
   #!/bin/bash
   set -a
   source /home/claw/.secrets/telegram-sales.env
   set +a
   MSG='<text; HTML tags allowed>'
   for CHAT in "$TELEGRAM_CHAT_ID_2" "$TELEGRAM_CHAT_ID_CUSTOM"; do
     curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_SALES_BOT_TOKEN}/sendMessage" \
       --data-urlencode "chat_id=${CHAT}" \
       --data-urlencode "parse_mode=HTML" \
       --data-urlencode "text=${MSG}"
     echo ""
   done
   ```
   Use `--data-urlencode` so quotes/newlines/UTF-8 inside MSG are safe.

   sendPhoto (personalizada with image) is multipart only — same loop, different flags:
   ```bash
   curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_SALES_BOT_TOKEN}/sendPhoto" \
     -F "chat_id=${CHAT}" \
     -F "photo=@/path/to/preview.jpg" \
     -F "caption=${MSG}" \
     -F "parse_mode=HTML"
   ```
   Never mix `-F` (multipart) with `--data-urlencode` (urlencoded) in one curl call — it is rejected and returns an empty response; use `-F` for photo AND caption, and `-sS` (not `-s`) so curl errors surface instead of being silenced. The photo is the order's personalization-illustrative preview (from the order gestalt), never a product/stock photo; if it is missing, stop and report rather than inventing one.

4. Verify each delivery: the response JSON must contain `"ok":true` and a `message_id` per chat. Report those as proof. If instead you see `"error_code":404`, the token variable did not expand (quoting) or the env file is wrong. Diagnose cleanly with `getMe`:
   `curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_SALES_BOT_TOKEN}/getMe"` must return `"ok":true` with the bot username; a 404 means the token never reached the URL.
   - Completion: every intended chat returned `ok:true` with its own `message_id`.

5. Routing rules are David's standing business rules and change over time — the packing runbook (`packing/RUNBOOK-20h.md`, maintained by `operaciones`) is their authoritative home. Read it before choosing recipients for any digest or personalizada; if it conflicts with the summary below, the runbook wins. Verified state as of 2026-09-09 (supersedes the 2026-09-08 sets): routine packing/extras digests → Gon + Isabel (`_ID` and `_2`), never Wide; personalizada Amazon orders (SKU contains PERS) → `sendPhoto` to Gon + Isabel + Wide (`_ID`, `_2`, `_CUSTOM`) with the order's personalization-illustrative image (never a product/stock photo) + full order detail, sent ~5 min after that run's emails — if the image is missing, stop and report rather than inventing one. The digest content spec (real client name, real platform order number, no amounts) also lives in the runbook.
   - Completion: recipients match the runbook before the script runs.

## Pitfalls

- Never print the token or chat IDs into chat, logs, prompts, or anywhere; only the env var names. Scripts contain variable names, never values, because they `source` the env file.
- Keep `parse_mode=HTML` when the text carries formatting; `--data-urlencode` already protects the payload.
- Reusable send script kept on the server: `/home/claw/send_sales_digest.sh` (sources env + loops recipients) — adapt MSG per run instead of rewriting from scratch.
