#!/bin/bash
# Instala cron-avisa en el servidor y envuelve las tareas calladas del cron. Siete pasos:
# 1 binario, 2 carpeta de estado, 3 respaldo, 4 envuelve, 5 escribe lo que cambia, 6 la revisión
# diaria, 7 cuántas líneas por archivo. Se puede repetir: sin cambios no toca ni respalda nada.
set -eu
. "$(dirname "$0")/cron-avisa-comun.sh"
echo "cron-avisa-instala sha=${MOTOR_SHA:-sin-sha}"
llevar_archivos
remoto "$CA_STAGE" <<'REMOTO'
D=$1
envuelve() { python3 -I "$D/cron-avisa-envuelve.py" "$@"; }

log "paso 1: instala $BIN/cron-avisa"
cp "$D/cron-avisa" "$BIN/.cron-avisa.nuevo"
chmod 755 "$BIN/.cron-avisa.nuevo"
chown root:root "$BIN/.cron-avisa.nuevo"
mv -f "$BIN/.cron-avisa.nuevo" "$BIN/cron-avisa"

log "paso 2: carpeta de estado $ESTADO (root:gon 2775)"
mkdir -p "$ESTADO"
chown root:gon "$ESTADO"
chmod 2775 "$ESTADO"

S=$(mktemp -d "$D/trabajo.XXXXXX")
mkdir "$S/viejo" "$S/nuevo" "$S/viejo/cron.d" "$S/nuevo/cron.d"
: > "$S/cambian"
for o in $(objetivos); do
  f=${o/:/\/}
  f=${f/usuario\//crontab-}
  vivo "$o" > "$S/viejo/$f"
  if ! envuelve --destino "$o" --cuenta < "$S/viejo/$f" > "$S/nuevo/$f" 2> "$S/cuenta"; then
    log "ERROR: no pude envolver $o; no cambié nada"
    exit 1
  fi
  cmp -s "$S/viejo/$f" "$S/nuevo/$f" || echo "$o" >> "$S/cambian"
  printf '%s %s\n' "$o" "$(cat "$S/cuenta")" >> "$S/resumen"
done
if grep -q spapi_vigilante "$S/viejo/crontab-root" && ! grep -q spapi_vigilante "$S/nuevo/crontab-gon"; then
  log "ERROR: root tiene spapi_vigilante y gon no; no quito la única copia"
  exit 1
fi
{ [ -f "$CROND/cron-avisa" ] && grep -qxF "$REVISA_LINEA" "$CROND/cron-avisa"; } || echo cron.d:cron-avisa >> "$S/cambian"

if [ -s "$S/cambian" ]; then
  R="$RESPALDO/$(date '+%Y%m%d-%H%M%S')"
  log "paso 3: respaldo en $R"
  mkdir -p "$R/cron.d"
  cp "$S/viejo/crontab-root" "$S/viejo/crontab-gon" "$R/"
  for o in $(grep '^cron.d:' "$S/cambian" | grep -v '^cron.d:cron-avisa$' || true); do
    cp "$S/viejo/cron.d/${o#cron.d:}" "$R/cron.d/"
  done
  log "paso 4 y 5: escribe lo que cambia"
  for o in $(grep -v '^cron.d:' "$S/cambian" || true); do
    u=${o#usuario:}
    crontab -u "$u" - < "$S/nuevo/crontab-$u"
    vivo "$o" | cmp -s - "$S/nuevo/crontab-$u" || { log "ERROR: el crontab de $u no quedó como esperaba"; exit 1; }
  done
  for o in $(grep '^cron.d:' "$S/cambian" | grep -v '^cron.d:cron-avisa$' || true); do
    escribe_crond "${o#cron.d:}" < "$S/nuevo/cron.d/${o#cron.d:}"
  done
else
  log "paso 3 a 5: nada que cambiar, no respaldo ni escribo"
fi

log "paso 6: $CROND/cron-avisa"
printf '%s\n' '# Revisa a diario que las tareas envueltas sigan corriendo (cron-avisa-instala.sh)' \
  'SHELL=/bin/bash' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
  "$REVISA_LINEA" | escribe_crond cron-avisa

log "paso 7: líneas envueltas por archivo"
while read -r o resto; do
  log "  $o ${resto:-envueltas=0 quitadas=0}"
done < "$S/resumen"
log "listo"
REMOTO
