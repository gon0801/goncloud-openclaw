#!/bin/bash
# Sale 0 solo si: el binario está, la carpeta de estado es root:gon 2775, ninguna línea activa
# fuera de NO_ENVOLVER queda sin envolver y `cron-avisa --revisa --seco` sale 0 o 1.
# Solo lee; no corre ninguna tarea del cron.
set -eu
. "$(dirname "$0")/cron-avisa-comun.sh"
echo "cron-avisa-checklist sha=${MOTOR_SHA:-sin-sha}"
llevar_archivos
remoto "$CA_STAGE" <<'REMOTO'
D=$1
mal=0
ok() { echo "OK: $1"; }
no() { echo "FALLA: $1"; mal=1; }

if [ -x "$BIN/cron-avisa" ]; then ok "el binario está en $BIN/cron-avisa"; else no "falta $BIN/cron-avisa"; fi

dueno=$(stat -c '%U:%G %a' "$ESTADO" 2>/dev/null || echo ausente)
if [ "$dueno" = "root:gon 2775" ]; then ok "$ESTADO es root:gon 2775"; else no "$ESTADO es '$dueno', debía ser 'root:gon 2775'"; fi

sin=0
for o in $(objetivos); do
  vivo "$o" > "$D/vivo"
  python3 -I "$D/cron-avisa-envuelve.py" --destino "$o" < "$D/vivo" > "$D/esperado" || { no "no pude revisar $o"; sin=1; continue; }
  if ! cmp -s "$D/vivo" "$D/esperado"; then
    sin=1
    no "$o tiene líneas activas sin envolver (o la de spapi_vigilante repetida):"
    diff "$D/vivo" "$D/esperado" | grep '^<' | cut -c1-160 || true
  fi
done
[ "$sin" = 0 ] && ok "ninguna línea activa queda sin envolver"

rc=0
"$BIN/cron-avisa" --revisa --seco > "$D/revisa" 2>&1 || rc=$?
if [ "$rc" = 0 ] || [ "$rc" = 1 ]; then ok "cron-avisa --revisa --seco salió $rc"; else no "cron-avisa --revisa --seco salió $rc"; head -3 "$D/revisa"; fi

exit "$mal"
REMOTO
