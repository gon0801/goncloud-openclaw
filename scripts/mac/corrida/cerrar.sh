#!/bin/bash
# corrida/cerrar.sh (9.2). cerrar <id>: desmarca, quita el cron por su id, manda CERRADA.
corrida_cerrar() {
  local id="$1"
  corrida_id_valido "$id" || { echo "cerrar: id invalido: $id" >&2; return 2; }
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  local s nombres
  nombres="$(CORR_REG="$reg" python3 -c "
import json,os
print(' '.join(x.get('nombre','') for x in json.load(open(os.environ['CORR_REG'])).get('sesiones',[])))")"
  for s in $nombres; do
    "$TMUX_BIN" set-environment -t "=$s" -u OPENCLAW_WATCH 2>/dev/null
  done
  # El cron se quita por el id que devolvio cron add; por nombre puede no borrar nada.
  local cid; cid="$(json_campo "$reg" cron_vigia_id)"
  [ -n "$cid" ] || cid="corrida-vigia-$id"
  "$OPENCLAW_BIN" cron rm "$cid" >/dev/null 2>&1 \
    || { echo "cerrar: no se quito el cron $cid de la corrida $id" >&2; return 1; }
  corrida_mensaje "$id" "CERRADA" "todas las partes terminadas" "la corrida termino" "no queda nada en curso" "nada" || return 1
  registro_actualizar "$reg" "d['estado']='cerrada'" || return 1
  echo "cerrada $id"
}
