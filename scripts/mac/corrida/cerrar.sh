#!/bin/bash
# corrida/cerrar.sh (9.2). cerrar <id>: desmarca, quita el cron por su id, manda CERRADA.
# Idempotente y honesto: cada fallo dice que falló y en qué quedó la corrida; el
# estado pasa a cerrada SOLO cuando todo cerró, y reintentar tras un fallo cierra.
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
  # Si el rm falla porque el cron YA no esta en la lista, es un reintento tras media
  # corrida: cuenta como exito (idempotencia), no como error.
  local cid; cid="$(json_campo "$reg" cron_vigia_id)"
  [ -n "$cid" ] || cid="corrida-vigia-$id"
  if ! "$OPENCLAW_BIN" cron rm "$cid" >/dev/null 2>&1; then
    local quedan; quedan="$(cron_jobs_de "corrida-vigia-$id")"
    if [ "$quedan" != "NINGUNO" ]; then
      echo "cerrar: no se quito el cron de la corrida $id (quedan: $quedan); las sesiones ya estan desmarcadas y el registro queda abierto — reintentar cierra" >&2
      return 1
    fi
  fi
  # El registro se marca cerrada solo cuando todo lo anterior cerró; si el aviso no
  # sale, la corrida queda abierta PERO dicho, y el reintento tiene camino libre.
  if ! corrida_mensaje "$id" "CERRADA" "todas las partes terminadas" "la corrida termino" "no queda nada en curso" "nada"; then
    echo "cerrar: no salio el aviso de cierre de $id; las sesiones ya estan desmarcadas y el cron ya esta quitado — el registro queda abierto, reintentar cierra" >&2
    return 1
  fi
  registro_actualizar "$reg" "d['estado']='cerrada'" || return 1
  echo "cerrada $id"
}
