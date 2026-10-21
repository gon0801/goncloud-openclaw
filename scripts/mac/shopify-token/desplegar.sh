#!/bin/bash
# Pone la renovación automática del token de Shopify como LaunchAgent de gon
# (~/Library/LaunchAgents/ai.goncloud.shopify-token.plist, 00:05 y 12:05), corre renueva.sh una vez
# y, si salió bien, desactiva el cron de claw que hacía lo mismo. Idempotente: si ya está cargado,
# bootout y bootstrap. No usa crontab. Reversa: rollback.sh. Verificación: checklist.sh.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

mkdir -p "$LA_DIR" "$(dirname "$LOG_RENUEVA")" 2>/dev/null
generar_plist "$PLIST.nuevo" || { rm -f "$PLIST.nuevo"; log "FALLA: no pude generar el plist"; exit 1; }
mv -f "$PLIST.nuevo" "$PLIST" || { log "FALLA: no pude escribir $PLIST"; exit 1; }

if agente_cargado; then
  "$LAUNCHCTL" bootout "$DOMINIO/$LABEL" >/dev/null 2>&1 || true
fi
"$LAUNCHCTL" bootstrap "$DOMINIO" "$PLIST" || { log "FALLA: launchctl no cargó $LABEL"; exit 1; }
agente_cargado || { log "FALLA: $LABEL no quedó cargado"; exit 1; }
log "LaunchAgent $LABEL cargado (00:05 y 12:05)"

"$RENUEVA" || { log "FALLA: renueva.sh no salió bien; el cron de claw sigue activo"; exit 1; }

"$OPENCLAW" cron disable "$CRON_CLAW" >/dev/null || { log "FALLA: no pude desactivar el cron de claw"; exit 1; }
log "listo: cron de claw desactivado"
