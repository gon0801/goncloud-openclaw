#!/bin/bash
# Vuelve al estado anterior que funcionaba. Con $RAIZ/shopify-token.anterior: lo pone otra vez como
# $INSTALADO, regenera el plist y lo recarga (bootout + bootstrap); el cron de claw sigue desactivado.
# Sin .anterior: descarga el LaunchAgent, borra su plist y vuelve a activar el cron de claw.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"
rc=0
ANTERIOR=$RAIZ/shopify-token.anterior

if [ -d "$ANTERIOR" ]; then
  MALO=$RAIZ/.shopify-token.malo
  rm -rf "$MALO"
  if [ -e "$INSTALADO" ]; then
    mv "$INSTALADO" "$MALO" || { log "FALLA: no pude apartar $INSTALADO"; exit 1; }
  fi
  mv "$ANTERIOR" "$INSTALADO" || { log "FALLA: no pude devolver la receta anterior"; exit 1; }
  rm -rf "$MALO"
  log "receta anterior puesta otra vez en $INSTALADO"
  PLANTILLA=$INSTALADO/../ai.goncloud.shopify-token.plist
  mkdir -p "$LA_DIR"
  generar_plist "$PLIST.nuevo" && mv -f "$PLIST.nuevo" "$PLIST" || { rm -f "$PLIST.nuevo"; log "FALLA: no pude regenerar el plist"; exit 1; }
  if agente_cargado; then
    "$LAUNCHCTL" bootout "$DOMINIO/$LABEL" >/dev/null 2>&1 || { log "FALLA: launchctl no descargó $LABEL"; exit 1; }
  fi
  "$LAUNCHCTL" bootstrap "$DOMINIO" "$PLIST" && agente_cargado || { log "FALLA: launchctl no cargó $LABEL"; exit 1; }
  log "LaunchAgent $LABEL cargado con la receta anterior; el cron de claw sigue desactivado"
  exit 0
fi

if agente_cargado; then
  "$LAUNCHCTL" bootout "$DOMINIO/$LABEL" >/dev/null 2>&1 || { log "FALLA: launchctl no descargó $LABEL"; rc=1; }
fi
if [ -e "$PLIST" ]; then rm -f "$PLIST" && log "plist borrado" || { log "FALLA: no pude borrar $PLIST"; rc=1; }
else log "no había plist"; fi
"$OPENCLAW" cron enable "$CRON_CLAW" >/dev/null && log "cron de claw activado" || { log "FALLA: no pude activar el cron de claw"; rc=1; }
exit $rc
