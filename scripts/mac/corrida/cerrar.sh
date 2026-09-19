#!/bin/bash
# corrida/cerrar.sh (9.2). cerrar <id>: desmarca, quita el cron por su id, manda CERRADA.
# Idempotente y honesto, y serializado contra lanzar-sesion: el lock se toma ANTES
# de listar las sesiones y se suelta al final — una sesion que entra, desmarca; una
# que llega tarde, lanzar la retira (re-verifica bajo lock antes de anotar).
corrida_cerrar() {
  local id="$1"
  corrida_id_valido "$id" || { echo "cerrar: id invalido: $id" >&2; return 2; }
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  if ! lock_tomar "$reg"; then
    echo "cerrar: lock del registro de $id no cede; no se ha hecho nada (ni desmarcado ni cron) y el aviso NO salio — reintentar cierra" >&2
    return 1
  fi
  # Ya cerrada (leido bajo lock): segunda llamada = no-op con confirmacion.
  if [ "$(json_campo "$reg" estado)" = "cerrada" ]; then
    lock_soltar "$reg"
    echo "cerrada $id"
    return 0
  fi
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
  if ! con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" cron rm "$cid" >/dev/null 2>&1; then
    local quedan; quedan="$(cron_jobs_de "corrida-vigia-$id")"
    if [ "$quedan" = "ILEGIBLE" ]; then
      lock_soltar "$reg"
      echo "cerrar: no se pudo verificar si el cron de $id sigue puesto (lista ilegible); las sesiones ya estan desmarcadas y el registro queda abierto — revisar el cron a mano y reintentar" >&2
      return 1
    fi
    if [ "$quedan" != "NINGUNO" ]; then
      lock_soltar "$reg"
      echo "cerrar: no se quito el cron de la corrida $id (quedan: $quedan); las sesiones ya estan desmarcadas y el registro queda abierto — reintentar cierra" >&2
      return 1
    fi
  fi
  # Un aviso de cierre YA entregado (intento anterior que fallo al escribir) no se
  # reenvia: mensajes.jsonl es la memoria de lo que David ya recibio.
  local ya
  ya="$(CORR_MSG_DIR="$CORRIDA_STATE/$id" python3 -c "
import json,os
try:
  filas=[json.loads(l) for l in open(os.path.join(os.environ['CORR_MSG_DIR'],'mensajes.jsonl'))]
except Exception:
  filas=[]
print('true' if any(f.get('etiqueta')=='CERRADA' and f.get('ok') for f in filas) else 'false')" 2>/dev/null)"
  if [ "$ya" != "true" ]; then
    if ! corrida_mensaje "$id" "CERRADA" "todas las partes terminadas" "la corrida termino" "no queda nada en curso" "nada"; then
      lock_soltar "$reg"
      echo "cerrar: no salio el aviso de cierre de $id; las sesiones ya estan desmarcadas y el cron ya esta quitado — el registro queda abierto, reintentar cierra" >&2
      return 1
    fi
  fi
  if ! registro_escribir "$reg" "d['estado']='cerrada'"; then
    lock_soltar "$reg"
    echo "cerrar: el aviso de $id ya salio pero el registro no se pudo marcar cerrado — reintentar cierra sin reenviar el aviso" >&2
    return 1
  fi
  lock_soltar "$reg"
  echo "cerrada $id"
}
