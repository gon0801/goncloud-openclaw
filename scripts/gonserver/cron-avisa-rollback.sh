#!/bin/bash
# Restaura el respaldo más reciente de /root/cron-avisa-respaldo y quita /etc/cron.d/cron-avisa.
# No pide argumentos. No toca el binario ni la carpeta de estado.
set -eu
. "$(dirname "$0")/cron-avisa-comun.sh"
echo "cron-avisa-rollback sha=${MOTOR_SHA:-sin-sha}"
remoto <<'REMOTO'
ultimo=$(ls -1 "$RESPALDO" 2>/dev/null | grep -v '^\.' | sort | tail -1 || true)
if [ -z "$ultimo" ]; then
  log "ERROR: no hay respaldo en $RESPALDO"
  exit 1
fi
R="$RESPALDO/$ultimo"
log "restaura $R"
for u in root gon; do
  [ -f "$R/crontab-$u" ] || continue
  if [ -s "$R/crontab-$u" ]; then
    crontab -u "$u" - < "$R/crontab-$u"
  else
    crontab -r -u "$u" 2>/dev/null || true
  fi
  log "  crontab de $u restaurado"
done
for f in "$R"/cron.d/*; do
  [ -f "$f" ] || continue
  escribe_crond "${f##*/}" < "$f"
  log "  $CROND/${f##*/} restaurado"
done
rm -f "$CROND/cron-avisa"
log "quité $CROND/cron-avisa"
REMOTO
