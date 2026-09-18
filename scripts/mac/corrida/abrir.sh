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
  python3 -c "
import json
d={'schema':'corrida.v1','id':'$id','runbook':'$runbook','vigia':'$vigia','simulacro':('true'=='$sim'),
'canal':{'cron':'$canal_de','destino':'$dest'},'cli_modos':'$cli_modos',
'inicio':'$(date +%Y-%m-%dT%H:%M:%S%z)','timebox_horas':6,'sesiones':[],'preaprobaciones':[],'estado':'abierta'}
open('$dir/registro.json','w').write(json.dumps(d,indent=1)+chr(10))
" || return 1
  chmod 600 "$dir/registro.json"
  : > "$dir/mensajes.jsonl" && chmod 600 "$dir/mensajes.jsonl"
  local parte="Parte de la corrida $id para el vigia."
  [ "$sim" = "true" ] && parte="[SIMULACRO] $parte"
  "$OPENCLAW_BIN" cron add --name "corrida-vigia-$id" --every 60m --agent main --announce --channel telegram --to "$dest" --json --message "$parte" >/dev/null 2>&1 \
    || { echo "abrir: no entro el cron hombre-muerto" >&2; return 1; }
  echo "abierta $id"
}
