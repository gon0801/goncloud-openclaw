#!/bin/bash
# Descarga el LaunchAgent ai.goncloud.shopify-token, borra su plist y vuelve a activar el cron de claw.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"
rc=0
if agente_cargado; then
  "$LAUNCHCTL" bootout "$DOMINIO/$LABEL" >/dev/null 2>&1 || { log "FALLA: launchctl no descargó $LABEL"; rc=1; }
fi
if [ -e "$PLIST" ]; then rm -f "$PLIST" && log "plist borrado" || { log "FALLA: no pude borrar $PLIST"; rc=1; }
else log "no había plist"; fi
"$OPENCLAW" cron enable "$CRON_CLAW" >/dev/null && log "cron de claw activado" || { log "FALLA: no pude activar el cron de claw"; rc=1; }
exit $rc
