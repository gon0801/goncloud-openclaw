#!/bin/bash
# Pone la renovación automática del token de Shopify en el crontab de gon (00:05 y 12:05, una sola
# línea marcada `# motor:shopify-token`), corre renueva.sh una vez y, si salió bien, desactiva el
# cron de claw que hacía lo mismo. Idempotente: repetirlo no duplica la línea ni toca las demás.
# Reversa: rollback.sh. Verificación: checklist.sh.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

LINEA=$(linea_cron)
ACTUAL=$(crontab_actual)
if [ "$(printf '%s\n' "$ACTUAL" | grep -cxF -- "$LINEA")" = 1 ] && [ "$(cuenta_marcadas)" = 1 ]; then
  log "el crontab ya tiene la línea de shopify-token"
else
  { printf '%s\n' "$ACTUAL" | grep -vF -- "$MARCA" || true; printf '%s\n' "$LINEA"; } | sed '1{/^$/d;}' | crontab_instalar \
    || { log "FALLA: no pude escribir el crontab"; exit 1; }
  log "línea de shopify-token puesta en el crontab"
fi
[ "$(cuenta_marcadas)" = 1 ] || { log "FALLA: la línea marcada no quedó una sola vez"; exit 1; }

mkdir -p "$(dirname "$LOG_RENUEVA")" 2>/dev/null
"$RENUEVA" || { log "FALLA: renueva.sh no salió bien; el cron de claw sigue activo"; exit 1; }

"$OPENCLAW" cron disable "$CRON_CLAW" >/dev/null || { log "FALLA: no pude desactivar el cron de claw"; exit 1; }
log "listo: cron de claw desactivado"
