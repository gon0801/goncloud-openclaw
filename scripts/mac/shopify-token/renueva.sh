#!/bin/bash
# Renueva el token de Admin API de Shopify (client_credentials) y lo guarda solo si sirve.
# Lee shopify_app.json (UTF-8 o UTF-16; campos store, client_id, client_secret), pide el token con
# POST https://<store>/admin/oauth/access_token, lo prueba con GET /admin/api/2025-10/shop.json (200)
# y solo entonces lo escribe de forma atómica (600). Si algo falla no toca el token guardado, sale
# ≠0 y avisa a David por Telegram (bot de OpenClaw). Nunca imprime ni registra credenciales.
#
# Variables (para pruebas): SHOPIFY_APP_JSON, SHOPIFY_TOKEN_FILE, SHOPIFY_BASE (reemplaza
# https://<store>), OPENCLAW_ENV, TELEGRAM_CHAT.
set -u
APP_JSON=${SHOPIFY_APP_JSON:-$HOME/.openclaw/credentials/shopify_app.json}
TOKEN_FILE=${SHOPIFY_TOKEN_FILE:-$HOME/.openclaw/credentials/shopify_token.txt}
OPENCLAW_ENV=${OPENCLAW_ENV:-$HOME/.openclaw/.env}
CHAT=${TELEGRAM_CHAT:-6470689715}
API_VERSION=2025-10

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Manda un texto (sin secretos) a David. La URL con el token del bot va por stdin, no por argv.
avisar() {
  local texto=$1 bot
  bot=$(python3 -I - "$OPENCLAW_ENV" <<'PY' 2>/dev/null
import sys
for l in open(sys.argv[1], encoding="utf-8", errors="replace"):
    l = l.strip()
    if l.startswith("export "): l = l[7:]
    if l.startswith("TELEGRAM_BOT_TOKEN="):
        print(l.split("=", 1)[1].strip().strip("'\""))
        break
PY
)
  if [ -z "$bot" ]; then log "no pude avisar por Telegram: falta TELEGRAM_BOT_TOKEN"; return 1; fi
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text=%s"\n' \
    "$bot" "$CHAT" "$texto" | curl -sS -m 20 -o /dev/null -K - >/dev/null 2>&1 \
    || log "no pude avisar por Telegram"
}

falla() {
  log "FALLA: $1"
  avisar "No pude renovar el token de Shopify: $1. El token anterior sigue sirviendo mientras dure."
  exit 1
}

[ -r "$APP_JSON" ] || falla "no encuentro el archivo de la app de Shopify"

# store, client_id y client_secret salen como tres líneas por un archivo temporal 600 (no por argv).
TMP=$(mktemp -d "${TMPDIR:-/tmp}/shopify-token.XXXXXX") || falla "no pude crear una carpeta temporal"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

python3 -I - "$APP_JSON" "$TMP/cred" <<'PY' || falla "el archivo de la app de Shopify no se puede leer o le faltan datos"
import json, os, sys
raw = open(sys.argv[1], "rb").read()
if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
    txt = raw.decode("utf-16")
else:
    txt = raw.decode("utf-8-sig")
d = json.loads(txt.lstrip("﻿"))
vals = [str(d.get(k, "")).strip() for k in ("store", "client_id", "client_secret")]
if not all(vals) or any("\n" in v or "\r" in v for v in vals):
    sys.exit(1)
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("\n".join(vals) + "\n")
PY
{ read -r STORE; read -r CID; read -r CSEC; } < "$TMP/cred"
BASE=${SHOPIFY_BASE:-https://$STORE}

# 1. Pedir el token. El cuerpo con las credenciales y la configuración de curl van por archivos 600.
python3 -I - "$CID" "$CSEC" > "$TMP/body.json" <<'PY' || falla "no pude armar la petición"
import json, sys
print(json.dumps({"grant_type": "client_credentials", "client_id": sys.argv[1], "client_secret": sys.argv[2]}))
PY
CODE=$(printf 'url = "%s/admin/oauth/access_token"\nheader = "Content-Type: application/json"\ndata = "@%s"\n' \
  "$BASE" "$TMP/body.json" | curl -sS -m 30 -o "$TMP/resp.json" -w '%{http_code}' -K - 2>/dev/null)
[ "$CODE" = 200 ] || falla "Shopify rechazó la petición del token (respuesta ${CODE:-sin respuesta})"

python3 -I - "$TMP/resp.json" "$TMP/token" <<'PY' || falla "la respuesta de Shopify no trajo un token"
import json, os, sys
t = json.load(open(sys.argv[1])).get("access_token")
if not isinstance(t, str) or not t.strip() or any(c.isspace() for c in t.strip()):
    sys.exit(1)
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(t.strip())
PY
TOKEN=$(cat "$TMP/token")

# 2. Comprobar el token nuevo.
CODE=$(printf 'url = "%s/admin/api/%s/shop.json"\nheader = "X-Shopify-Access-Token: %s"\n' \
  "$BASE" "$API_VERSION" "$TOKEN" | curl -sS -m 30 -o /dev/null -w '%{http_code}' -K - 2>/dev/null)
[ "$CODE" = 200 ] || falla "el token nuevo no pasó la prueba contra la tienda (respuesta ${CODE:-sin respuesta})"

# 3. Escribir de forma atómica con 600 (temporal en la misma carpeta + mv).
DEST_DIR=$(dirname "$TOKEN_FILE")
mkdir -p "$DEST_DIR" 2>/dev/null
NEW=$(mktemp "$DEST_DIR/.shopify_token.XXXXXX") || falla "no pude escribir junto al token guardado"
if ! { chmod 600 "$NEW" && printf '%s' "$TOKEN" > "$NEW" && mv -f "$NEW" "$TOKEN_FILE"; }; then
  rm -f "$NEW"
  falla "no pude guardar el token nuevo"
fi
log "token de Shopify renovado y comprobado"
exit 0
