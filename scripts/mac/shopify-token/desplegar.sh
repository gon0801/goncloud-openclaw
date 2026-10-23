#!/bin/bash
# Instala la receta en $RAIZ/shopify-token (fuera de ~/.motor, que se borra), pone la renovación
# automática del token de Shopify como LaunchAgent de gon (~/Library/LaunchAgents/
# ai.goncloud.shopify-token.plist, 00:05 y 12:05), la corre una vez con `launchctl kickstart` y, si
# launchd la vio salir con 0, desactiva el cron de claw que hacía lo mismo. Idempotente: si ya está cargado,
# bootout y bootstrap. No usa crontab. Reversa: rollback.sh. Verificación: checklist.sh.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

mkdir -p "$LA_DIR" "$(dirname "$LOG_RENUEVA")" "$RAIZ" 2>/dev/null

if [ "$AQUI" != "$INSTALADO" ]; then
  NUEVO=$RAIZ/.shopify-token.nuevo
  rm -rf "$NUEVO"
  mkdir -p "$NUEVO" && cp -R "$AQUI" "$NUEVO/shopify-token" && cp "$PLANTILLA" "$NUEVO/" \
    || { rm -rf "$NUEVO"; log "FALLA: no pude copiar la receta a $RAIZ"; exit 1; }
  cp "$NUEVO/$(basename "$PLANTILLA")" "$RAIZ/" || { log "FALLA: no pude copiar la plantilla del plist"; exit 1; }
  rm -rf "$RAIZ/shopify-token.anterior"
  if [ -e "$INSTALADO" ]; then
    mv "$INSTALADO" "$RAIZ/shopify-token.anterior" || { log "FALLA: no pude guardar la receta anterior"; exit 1; }
  fi
  mv "$NUEVO/shopify-token" "$INSTALADO" || { log "FALLA: no pude poner la receta en $INSTALADO"; exit 1; }
  rm -rf "$NUEVO"
  log "receta instalada en $INSTALADO"
fi
PLANTILLA=$INSTALADO/../ai.goncloud.shopify-token.plist
generar_plist "$PLIST.nuevo" || { rm -f "$PLIST.nuevo"; log "FALLA: no pude generar el plist"; exit 1; }
mv -f "$PLIST.nuevo" "$PLIST" || { log "FALLA: no pude escribir $PLIST"; exit 1; }

if agente_cargado; then
  "$LAUNCHCTL" bootout "$DOMINIO/$LABEL" >/dev/null 2>&1 || true
fi
"$LAUNCHCTL" bootstrap "$DOMINIO" "$PLIST" || { log "FALLA: launchctl no cargó $LABEL"; exit 1; }
agente_cargado || { log "FALLA: $LABEL no quedó cargado"; exit 1; }
log "LaunchAgent $LABEL cargado (00:05 y 12:05)"

"$LAUNCHCTL" kickstart -k "$DOMINIO/$LABEL" >/dev/null 2>&1 || { log "FALLA: launchd no quiso correr $LABEL; el cron de claw sigue activo"; exit 1; }
limite=$(( $(date +%s) + ${SHOPIFY_TOKEN_ESPERA:-90} ))
while :; do
  read -r runs rc <<<"$(estado_corrida)"
  if [ "${runs:-0}" -ge 1 ] 2>/dev/null && [ "${rc:--}" != "-" ]; then
    [ "$rc" = 0 ] && break
    log "FALLA: launchd corrió la renovación y salió con código $rc (mira $LOG_RENUEVA); el cron de claw sigue activo"; exit 1
  fi
  [ "$(date +%s)" -lt "$limite" ] || { log "FALLA: launchd no terminó la renovación a tiempo; el cron de claw sigue activo"; exit 1; }
  sleep 1
done
log "launchd corrió la renovación y salió con 0"

"$OPENCLAW" cron disable "$CRON_CLAW" >/dev/null || { log "FALLA: no pude desactivar el cron de claw"; exit 1; }
log "listo: cron de claw desactivado"
