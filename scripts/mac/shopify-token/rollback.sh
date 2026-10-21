#!/bin/bash
# Quita del crontab la línea `# motor:shopify-token` (las demás quedan igual) y vuelve a activar el
# cron de claw.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"
rc=0
if [ "$(cuenta_marcadas)" != 0 ]; then
  { crontab_actual | grep -vF -- "$MARCA" || true; } | crontab_instalar || { log "FALLA: no pude escribir el crontab"; rc=1; }
  log "línea de shopify-token quitada del crontab"
else
  log "el crontab no tenía la línea de shopify-token"
fi
"$OPENCLAW" cron enable "$CRON_CLAW" >/dev/null && log "cron de claw activado" || { log "FALLA: no pude activar el cron de claw"; rc=1; }
exit $rc
