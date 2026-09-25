#!/bin/bash
# corrida/abrir.sh (9.2). corrida.sh abrir <id> --runbook <ruta> --vigia <quien>
# [--cli-modos <ruta>] [--canal-de <cron>] [--simulacro]
corrida_abrir() {
  local id="$1"; shift
  corrida_id_valido "$id" || { echo "abrir: id invalido (solo letras, numeros, - y _): $id" >&2; return 2; }
  local runbook="" vigia="" cli_modos="" canal_de="cuotas-proveedores" sim="false"
  while [ $# -gt 0 ]; do
    case "$1" in
      --runbook|--vigia|--cli-modos|--canal-de)
        [ $# -ge 2 ] || { echo "abrir: $1 sin valor" >&2; return 2; };; esac
    case "$1" in
      --runbook) runbook="$2"; shift 2;;
      --vigia) vigia="$2"; shift 2;;
      --cli-modos) cli_modos="$2"; shift 2;;
      --canal-de) canal_de="$2"; shift 2;;
      --simulacro) sim="true"; shift;;
      *) echo "abrir: flag desconocido $1" >&2; return 2;;
    esac
  done
  [ -n "$runbook" ] && [ -n "$vigia" ] || { echo "abrir: faltan --runbook o --vigia" >&2; return 2; }
  case "$vigia" in claw|hermes) ;; *) echo "abrir: vigia fuera del conjunto" >&2; return 1;; esac
  [ -z "$cli_modos" ] && cli_modos="$HOME/bin/cli-modos.tsv"
  [ -f "$runbook" ] || { echo "abrir: no existe el runbook: $runbook" >&2; return 1; }
  # El registro manda: el runbook se guarda resuelto a absoluta.
  case "$runbook" in /*) ;; *) runbook="$PWD/$runbook";; esac
  [ -r "$cli_modos" ] || { echo "abrir: no se puede leer la tabla de modos: $cli_modos" >&2; return 1; }
  # El destino sale de la entrega de un cron que ya existe; jamas va en el repo ni en entorno.
  local dest
  dest="$(cron_dest_de "$canal_de")"
  [ "$dest" = "ILEGIBLE" ] && { echo "abrir: sin lista de crons legible" >&2; return 1; }
  [ "$dest" = "AMBIGUO" ] && { echo "abrir: el cron $canal_de tiene destinos ambiguos entre homonimos; no se elige por adivinanza" >&2; return 1; }
  [ -n "$dest" ] || { echo "abrir: el cron $canal_de no trae destino" >&2; return 1; }
  local dir="$CORRIDA_STATE/$id"
  if [ -e "$dir/registro.json" ]; then
    echo "abrir: ya existe la corrida $id (registro en $dir); si hay que reabrir, cerrarla antes" >&2
    return 1
  fi
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  dir="$(CDPATH= cd -P -- "$dir" && pwd)" || return 1
  # Reloj global: abrir ya no crea un cron hombre-muerto por corrida. El unico
  # reloj es el avance-tareas del director (cada 15 min, corte cada 30); los
  # AVANZA se acumulan en eventos-seguimiento.jsonl y lo inmediato
  # (NECESITO/DETENIDA/CERRADA) sale por su via. El destino del canal sigue
  # resolviendose del cron existente: lo necesitan los avisos inmediatos.
  # La existencia se RE-comprueba bajo lock: dos abrir del mismo id pueden pasar el
  # chequeo temprano de arriba a la vez; el perdedor falla sin escribir nada.
  # (El cron add y el destino van fuera del lock (red: el umbral de locks viejos
  # romperia un lock sostenido durante la llamada) — ahora solo el destino.)
  local reg="$dir/registro.json"
  if ! lock_tomar "$reg"; then
    echo "abrir: el lock de $id no cede; no se escribio nada" >&2
    return 1
  fi
  if [ -e "$reg" ]; then
    echo "abrir: ya existe la corrida $id (registro en $dir); si hay que reabrir, cerrarla antes" >&2
    lock_soltar "$reg"
    return 1
  fi
  CORR_ID="$id" CORR_RUNBOOK="$runbook" CORR_VIGIA="$vigia" CORR_SIM="$sim" CORR_CANAL="$canal_de" \
  CORR_DEST="$dest" CORR_MODOS="$cli_modos" CORR_REG="$dir/registro.json" python3 -c "
import json,os
E=os.environ
d={'schema':'corrida.v2','id':E['CORR_ID'],'runbook':E['CORR_RUNBOOK'],'vigia':E['CORR_VIGIA'],
'simulacro':E['CORR_SIM']=='true','canal':{'cron':E['CORR_CANAL'],'destino':E['CORR_DEST']},
'cli_modos':E['CORR_MODOS'],'seguimiento_global':True,
'inicio':'$(date +%Y-%m-%dT%H:%M:%S%z)','timebox_horas':6,'sesiones':[],'preaprobaciones':[],'estado':'abierta'}
t=E['CORR_REG']+'.tmp'
open(t,'w').write(json.dumps(d,indent=1)+chr(10))
os.chmod(t,0o600)
os.rename(t,E['CORR_REG'])
  " || { echo "abrir: no se pudo escribir el registro" >&2
       lock_soltar "$reg"; return 1; }
  # Self-check: el registro que sale de abrir pasa el mismo validador de corrida.v2.
  validar_registro "$reg" >/dev/null 2>&1 \
    || { echo "abrir: el registro escrito no pasa su propio contrato" >&2
       lock_soltar "$reg"; return 1; }
  # El canal de mensajes es la mitad del contrato de la corrida: si no nace, no hay
  # apertura — se retira el registro recien creado, y el error lo dice.
  if ! { : > "$dir/mensajes.jsonl" && chmod 600 "$dir/mensajes.jsonl"; }; then
    echo "abrir: no se pudo crear el canal de mensajes de $id; se retira el registro" >&2
    rm -f "$reg"
    lock_soltar "$reg"
    return 1
  fi
  lock_soltar "$reg"
  # El aviso de apertura (9.2: "recibe un mensaje cuando una corrida se abre y
  # cuando se cierra"). El numero de partes se sabe cuando cada una avisa; no
  # se inventa aqui. Un fallo de envio no deshace la apertura (la corrida ya
  # quedo abierta y utilizable): solo se avisa por stderr.
  corrida_mensaje "$id" "ABIERTA" "avance desconocido" \
    "Arrancó la corrida." \
    "Se irá viendo cuántas partes tiene conforme avance." \
    "nada" \
    || echo "abrir: no salio el aviso de apertura de $id (la corrida sigue abierta)" >&2
  echo "abierta $id"
}
