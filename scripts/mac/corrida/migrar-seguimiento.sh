#!/bin/bash
# corrida/migrar-seguimiento.sh. corrida.sh migrar-seguimiento --dry-run|--apply:
# retira los crones hombre-muerto legados (corrida-vigia-<id>) y reescribe esos
# registros de corrida.v1 a corrida.v2 (seguimiento_global:true), para que el
# cierre posterior no intente borrarlos de nuevo. El reloj global avance-tareas
# (uno solo, cada 15 min) lo crea el director; esta migracion nunca lo toca.
#
# --dry-run lista registros e ids sin mutar nada. --apply exige ANTES de mutar
# que haya exactamente un avance-tareas habilitado a cadencia de 15 min;
# faltante, apagado, duplicado, mal-cadencia o lista ilegible paran TODA la
# migracion sin tocar ningun registro v1. Luego quita cada cron legado por id,
# verifica su ausencia y reescribe ese registro a v2 de forma atomica bajo
# lock. Un fallo deja ese registro v1 y el resultado parcial se reporta.
corrida_migrar_seguimiento() {
  local modo="${1:-}"
  [ "$modo" = "--dry-run" ] || [ "$modo" = "--apply" ] \
    || { echo "uso: corrida.sh migrar-seguimiento --dry-run|--apply" >&2; return 2; }
  local base="${CORRIDA_STATE:-$HOME/.local/state/corridas}"
  local d reg schema id
  local nv1=0

  if [ "$modo" = "--dry-run" ]; then
    for d in "$base"/*/; do
      [ -d "$d" ] || continue
      reg="${d}registro.json"
      [ -f "$reg" ] || continue
      schema="$(json_campo "$reg" schema)"
      id="$(json_campo "$reg" id)"
      [ -n "$id" ] || id="$(basename "$d")"
      if [ "$schema" = "corrida.v1" ]; then
        nv1=$((nv1 + 1))
        printf 'v1 %s cron:%s\n' "$id" "$(cron_jobs_de "corrida-vigia-$id" | tr '\n' ',' 2>/dev/null)"
      elif [ "$schema" = "corrida.v2" ]; then
        printf 'v2 %s -\n' "$id"
      else
        printf 'roto %s -\n' "$id"
      fi
    done
    return 0
  fi

  # --apply: el reloj global manda. Sin exactamente un avance-tareas habilitado
  # a 15 min no se toca nada.
  local reloj
  reloj="$(reloj_global_ok)" || return 1

  local migradas=0 pendientes=""
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    reg="${d}registro.json"
    [ -f "$reg" ] || continue
    [ "$(json_campo "$reg" schema)" = "corrida.v1" ] || continue
    id="$(json_campo "$reg" id)"
    [ -n "$id" ] || id="$(basename "$d")"
    if migrar_un_registro "$reg" "$id"; then
      migradas=$((migradas + 1))
    else
      pendientes="$pendientes $id"
    fi
  done
  if [ -n "$pendientes" ]; then
    echo "migrar-seguimiento: migradas $migradas; pendientes:$pendientes" >&2
    return 1
  fi
  echo "migrar-seguimiento: migradas $migradas; nada pendiente"
  return 0
}

# reloj_global_ok: exactamente un avance-tareas habilitado a cadencia de 15
# min (everyMs 900000). Cualquiera otra cosa falla cerrado sin mutar nada.
reloj_global_ok() {
  local crons
  if ! crons="$(con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" cron list --json 2>/dev/null)"; then
    crons=""
  fi
  [ -n "$crons" ] || { echo "migrar-seguimiento: lista de crons ilegible; sin reloj global no se migra" >&2; return 1; }
  local n
  n="$(printf '%s' "$crons" | RELOJ_QUIERE=1 python3 -c "
import sys,json
t=sys.stdin.read()
try:
  d=json.loads(t[t.index('{'):])
except Exception:
  print('ILEGIBLE'); raise SystemExit
js=[j for j in d.get('jobs',[]) if j.get('name')=='avance-tareas']
ok=[j for j in js if j.get('enabled') and isinstance(j.get('schedule'),dict)
    and j['schedule'].get('kind')=='every' and j['schedule'].get('everyMs')==900000]
print('%d:%d'%(len(js),len(ok)))" 2>/dev/null)"
  case "$n" in
    "1:1") return 0;;
    "ILEGIBLE"|"") echo "migrar-seguimiento: lista de crons ilegible; sin reloj global no se migra" >&2; return 1;;
    *) echo "migrar-seguimiento: se esperaba exactamente un avance-tareas habilitado a 15 min (hay: $n); sin reloj global no se migra" >&2; return 1;;
  esac
}

# migrar_un_registro $1 reg, $2 id: quita cada cron legado por id, verifica
# ausencia y reescribe a v2 bajo lock. 0 = migrado; 1 = quedo v1.
migrar_un_registro() {
  local reg="$1" id="$2" ids i quedan
  ids="$(cron_jobs_de "corrida-vigia-$id")"
  if [ "$ids" = "ILEGIBLE" ]; then
    echo "migrar-seguimiento: $id: lista ilegible; queda v1" >&2
    return 1
  fi
  if [ "$ids" != "NINGUNO" ]; then
    while IFS= read -r i; do
      [ -n "$i" ] || continue
      con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" cron rm "$i" >/dev/null 2>&1 || {
        echo "migrar-seguimiento: $id: no se pudo quitar $i; queda v1" >&2
        return 1
      }
    done <<< "$ids"
    quedan="$(cron_jobs_de "corrida-vigia-$id")"
    if [ "$quedan" = "ILEGIBLE" ]; then
      echo "migrar-seguimiento: $id: no se pudo verificar la limpieza; queda v1" >&2
      return 1
    fi
    if [ "$quedan" != "NINGUNO" ]; then
      echo "migrar-seguimiento: $id: el cron sigue en la lista; queda v1" >&2
      return 1
    fi
  fi
  if ! lock_tomar "$reg"; then
    echo "migrar-seguimiento: $id: lock no cede; queda v1" >&2
    return 1
  fi
  MIG_REG="$reg" python3 -c "
import json,os
r=os.environ['MIG_REG']
d=json.load(open(r))
d['schema']='corrida.v2'
d['seguimiento_global']=True
d.pop('cron_vigia_id',None)
t=r+'.tmp'
open(t,'w').write(json.dumps(d,indent=1)+chr(10))
os.chmod(t,0o600)
os.rename(t,r)
" 2>/dev/null || {
    lock_soltar "$reg"
    echo "migrar-seguimiento: $id: no se pudo reescribir; queda v1" >&2
    return 1
  }
  validar_registro "$reg" >/dev/null 2>&1 || {
    lock_soltar "$reg"
    echo "migrar-seguimiento: $id: lo reescrito no pasa el contrato; queda v1" >&2
    return 1
  }
  lock_soltar "$reg"
  echo "migrar-seguimiento: $id migrada a v2"
  return 0
}
