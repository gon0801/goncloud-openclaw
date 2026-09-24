#!/bin/bash
# corrida/cerrar.sh (9.2). cerrar <id>: desmarca, quita el cron legado por su id
# solo en v1 (en v2 no hay cron por corrida y el reloj global no se toca),
# manda CERRADA.
# Idempotente y honesto, y serializado contra lanzar-sesion: el lock se toma ANTES
# de listar las sesiones y se suelta al final — una sesion que entra, desmarca; una
# que llega tarde, lanzar la retira (re-verifica bajo lock antes de anotar).
corrida_cerrar() {
  local id="$1"
  corrida_id_valido "$id" || { echo "cerrar: id invalido: $id" >&2; return 2; }
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  # 9.16: espera acotada y compartida por las dos tomas: un lanzamiento lento
  # (sondeo de barra + entrega) retiene el lock global mas de los ~10 s de un
  # intento suelto; cerrar lo espera sin pedir reintento manual y sin robar nada.
  case "$CORR_CIERRE_ESPERA" in
    ''|*[!0-9]*) echo "cerrar: CORR_CIERRE_ESPERA='$CORR_CIERRE_ESPERA' no es un numero de segundos; no se ha hecho nada" >&2; return 2;;
  esac
  CIERRE_TOPE=$((SECONDS + 10#$CORR_CIERRE_ESPERA)) # 10#: un 08 son 8 s, no octal
  if ! cerrar_esperar_lock "lock global de marcas" marcas_lock_tomar; then
    echo "cerrar: no se ha hecho nada" >&2
    return 1
  fi
  if ! cerrar_esperar_lock "lock del registro de $id" lock_tomar "$reg"; then
    marcas_lock_soltar
    echo "cerrar: no se ha hecho nada (ni desmarcado ni cron) y el aviso NO salio — reintentar cierra" >&2
    return 1
  fi
  # Ya cerrada (leido bajo lock): segunda llamada = no-op con confirmacion.
  if [ "$(json_campo "$reg" estado)" = "cerrada" ]; then
    lock_soltar "$reg"
    marcas_lock_soltar
    echo "cerrada $id"
    return 0
  fi
  local s nombres
  nombres="$(CORR_REG="$reg" python3 -c "
import json,os
print(' '.join(x.get('nombre','') for x in json.load(open(os.environ['CORR_REG'])).get('sesiones',[])))")"
  for s in $nombres; do
    if ! marca_retirar_si_dueno "$id" "$s"; then
      lock_soltar "$reg"
      marcas_lock_soltar
      echo "cerrar: no se pudieron retirar las marcas propias de $s" >&2
      return 1
    fi
  done
  marcas_lock_soltar
  # El cron se quita SOLO en v1, por el id que guardo el registro; por nombre
  # puede no borrar nada. En v2 no hay cron por corrida: el reloj es el unico
  # avance-tareas global y cerrar una corrida jamas lo toca. Si el rm falla
  # porque el cron YA no esta en la lista, es un reintento tras media
  # corrida: cuenta como exito (idempotencia), no como error.
  local schema; schema="$(json_campo "$reg" schema)"
  local cid=""
  if [ "$schema" = "corrida.v1" ]; then
    cid="$(json_campo "$reg" cron_vigia_id)"
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
  elif [ "$schema" != "corrida.v2" ]; then
    lock_soltar "$reg"
    echo "cerrar: registro con schema desconocido ($schema); no se ha hecho nada" >&2
    return 1
  fi
  # Lease: la red de arriba pudo tardar; el token se refresca antes de la
  # siguiente llamada larga para que ningun lock_tomar ajeno lo crea muerto.
  lock_refrescar "$reg"
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
  # Lease otra vez: el envio es la llamada mas larga bajo el lock.
  lock_refrescar "$reg"
  if ! registro_escribir "$reg" "d['estado']='cerrada'"; then
    lock_soltar "$reg"
    echo "cerrar: el aviso de $id ya salio pero el registro no se pudo marcar cerrado — reintentar cierra sin reenviar el aviso" >&2
    return 1
  fi
  lock_soltar "$reg"
  echo "cerrada $id"
}
