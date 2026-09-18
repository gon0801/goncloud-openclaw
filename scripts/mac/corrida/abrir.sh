#!/bin/bash
# corrida/abrir.sh (9.2). corrida.sh abrir <id> --runbook <ruta> --vigia <quien>
# [--cli-modos <ruta>] [--canal-de <cron>] [--simulacro]
corrida_abrir() {
  local id="$1"; shift
  local runbook="" vigia="" cli_modos="" canal_de="verif-sync-repos" sim="false"
  while [ $# -gt 0 ]; do
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
  # El destino sale de la entrega de un cron que ya existe; jamas va en el repo ni en entorno.
  local crons dest
  crons="$("$OPENCLAW_BIN" cron list --json 2>/dev/null)" || { echo "abrir: sin lista de crons" >&2; return 1; }
  dest="$(printf '%s' "$crons" | python3 -c "
import sys,json
t=sys.stdin.read(); d=json.loads(t[t.index('{'):])
print(next(((j.get('delivery') or {}).get('to') or '' for j in d.get('jobs',[]) if j.get('name')=='$canal_de'),''))")"
  [ -n "$dest" ] || { echo "abrir: el cron $canal_de no trae destino" >&2; return 1; }
  local dir="$CORRIDA_STATE/$id"
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  dir="$(cd "$dir" && pwd)"
  python3 -c "
import json
d={'schema':'corrida.v1','id':'$id','runbook':'$runbook','vigia':'$vigia','simulacro':('true'=='$sim'),
'canal':{'cron':'$canal_de','destino':'$dest'},'cli_modos':'$cli_modos',
'inicio':'$(date +%Y-%m-%dT%H:%M:%S%z)','timebox_horas':6,'sesiones':[],'preaprobaciones':[],'estado':'abierta'}
open('$dir/registro.json','w').write(json.dumps(d,indent=1)+chr(10))
" || return 1
  chmod 600 "$dir/registro.json"
  : > "$dir/mensajes.jsonl" && chmod 600 "$dir/mensajes.jsonl"
  # Hombre-muerto: si el latido (9.5) muere, este cron sigue pidiendole el parte a claw.
  # Texto adaptado del cron corrida-vigia-9 del runbook (0.4); el directorio de estado
  # sale del id de la corrida y el destino ya lo resuelve --to, jamas el texto.
  local parte="Parte de la corrida $id para el vigia, solo lectura. 1) En la Mac (exec con host node): cat $dir/registro.json y cat $dir/mensajes.jsonl: del registro salen las sesiones de esta corrida con sus roles y su estado. 2) Por cada sesion de ese registro: $TMUX_BIN capture-pane -p -t <sesion> y mira las ultimas 15 lineas no vacias. 3) Contesta SOLO con el parte, en cuatro lineas: etiqueta entre corchetes (AVANZA, DETENIDA o NECESITO TU RESPUESTA), Que cambio, Que sigue, Que necesito de ti. ESCRIBE PARA UNA PERSONA QUE NO LEE CODIGO: di como va la corrida (que partes estan terminadas, cual se esta trabajando, si avanza o esta detenido y desde cuando), sin nombres de archivo, comandos, ramas, siglas ni terminos tecnicos. Solo si una sesion espera a una persona, la etiqueta es NECESITO TU RESPUESTA: explica en palabras simples que se esta pidiendo y que implica decir si o no, y al final, como referencia, el comando textual. No escribas en ninguna sesion, no relances nada y no toques configuracion: este turno solo informa. Si los archivos no existen, contesta 'Corrida $id: todavia no hay avance registrado' y nada mas."
  [ "$sim" = "true" ] && parte="[SIMULACRO] Esta corrida es un simulacro: empieza tu parte con [SIMULACRO] para que David no actue sobre el. $parte"
  "$OPENCLAW_BIN" cron add --name "corrida-vigia-$id" --every 60m --agent main --announce --channel telegram --to "$dest" --json --message "$parte" >/dev/null 2>&1 \
    || { echo "abrir: no entro el cron hombre-muerto" >&2; return 1; }
  echo "abierta $id"
}
