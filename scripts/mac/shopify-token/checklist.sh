#!/bin/bash
# Sale 0 solo si: el LaunchAgent ai.goncloud.shopify-token responde a launchctl print, cada ruta de
# su plist instalado existe y ninguna está dentro de ~/.motor/, launchd la corrió al menos una vez y
# salió con 0 (runs >= 1, last exit code = 0), el token se
# escribió hace menos de 12 h (incluye "hace menos de 15 min") y shop.json responde 200 con él, y el
# cron de claw está desactivado.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"
MAX_EDAD=${SHOPIFY_TOKEN_MAX_EDAD:-43200}
rc=0
no() { log "NO: $*"; rc=1; }

agente_cargado && log "ok: LaunchAgent $LABEL cargado" || no "launchctl print no responde para $LABEL"

if [ -f "$PLIST" ]; then
  if rutas=$(python3 -I - "$PLIST" 2>&1 <<'PY'
import os, plistlib, sys
malas = []
for a in plistlib.load(open(sys.argv[1], "rb"))["ProgramArguments"]:
    if a.startswith("/"):
        if not os.path.exists(a):
            malas.append("no existe " + a)
        if "/.motor/" in a:
            malas.append("está dentro de ~/.motor/: " + a)
if malas:
    print("; ".join(malas))
    sys.exit(1)
PY
  ); then log "ok: las rutas del plist existen y ninguna está en ~/.motor/"
  else no "el plist apunta a una ruta mala (${rutas:-no pude leerlo})"; fi
else
  no "no hay plist instalado en $PLIST"
fi

read -r runs salio <<<"$(estado_corrida)"
if [ "${runs:-0}" -ge 1 ] 2>/dev/null && [ "${salio:--}" = 0 ]; then log "ok: launchd la corrió ${runs} vez/veces y salió con 0"
else no "launchd no la corrió bien (runs = ${runs:-?}, last exit code = ${salio:-?})"; fi

if [ -s "$TOKEN_FILE" ]; then
  edad=$(( $(date +%s) - $(stat -c %Y "$TOKEN_FILE" 2>/dev/null || stat -f %m "$TOKEN_FILE") ))
  [ "$edad" -lt "$MAX_EDAD" ] && log "ok: token escrito hace ${edad}s" || no "el token tiene ${edad}s (máximo ${MAX_EDAD}s)"
  store=$(python3 -I - "$APP_JSON" 2>/dev/null <<'PY'
import json, sys
b = open(sys.argv[1], "rb").read()
t = b.decode("utf-16") if b[:2] in (b"\xff\xfe", b"\xfe\xff") else b.decode("utf-8-sig")
print(json.loads(t)["store"])
PY
)
  base=${SHOPIFY_BASE:-https://$store}
  if [ -z "${SHOPIFY_BASE:-}" ] && [ -z "$store" ]; then
    no "no pude leer la tienda de shopify_app.json"
  else
    code=$(printf 'url = "%s/admin/api/2025-10/shop.json"\nheader = "X-Shopify-Access-Token: %s"\n' "$base" "$(cat "$TOKEN_FILE")" \
      | curl -sS -m 30 -o /dev/null -w '%{http_code}' -K - 2>/dev/null)
    [ "$code" = 200 ] && log "ok: shop.json responde 200" || no "shop.json respondió ${code:-nada} con el token guardado"
  fi
else
  no "no hay token guardado"
fi

cron_claw_activo; est=$?
case $est in
  1) log "ok: cron de claw desactivado" ;;
  0) no "el cron de claw sigue activado" ;;
  *) no "no pude saber si el cron de claw está desactivado" ;;
esac
[ "$rc" = 0 ] && log "checklist OK"
exit $rc
