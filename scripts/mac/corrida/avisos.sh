#!/bin/bash
# corrida/avisos.sh (19.1 B2): avisos corrida-aviso.v1 con pendiente durable.
# emitir <corrida> <sesion> <tipo> --llave <cadena> [detalle ...]:
#   un JSON por aviso en $CORRIDA_STATE/<corrida>/avisos/<id>.json. La identidad
#   <corrida>-<sesion>-<tipo>-<sha1 corto de la llave> es dedupable: la misma
#   senal con la misma llave produce el MISMO id, y la escritura temporal+rename
#   deja un solo archivo aunque el aviso y el tick del vigia choquen. Validacion
#   bajo lock del registro: corrida existente y abierta, sesion registrada (rol y
#   cli salen de ahi). Despues despierta a la sesion lead con
#   "corrida.sh avisos atender <corrida>"; si su cola de panel trae un dialogo de
#   aprobacion (dueno ocupado) o la sesion lead no existe, no manda teclas: el
#   pendiente persiste y el reintento del vigia lo despertara despues.
# atender <corrida>: lo corre el dueno. Reclama TODOS los pendientes renombrandolos
#   a avisos/tratados/ (el rename ES el reclamo: dos consumidores concurrentes no
#   duplican), revalida bajo lock (corrida abierta, sesiones aun registradas) y
#   anota atendido o descartado con motivo; si quedo alguno valido corre UNA vez
#   el reconciliar de la corrida y anota su salida en eventos.jsonl.
# despertar <corrida>: SOLO reintenta el despertar del emitir sobre pendientes
#   que ya existen, sin reescribirlos; lo llama el reintento del vigia.
# Reversa: CORRIDA_AVISOS=0 deja los tres subcomandos en no-op rc 0.
# Compatible con /bin/bash 3.2: sin arrays asociativos, sin mapfile, sin ${var,,}.
AVISOS_APROB_RE='allow once|always allow|would you like to allow|waiting for approval|do you trust|\[y/n\]|\(yes/no\)'

avisos_sha1() { # $1 cadena -> sha1 hex corto; la identidad dedupable de un aviso
  local h
  if command -v shasum >/dev/null 2>&1; then
    h="$(printf '%s' "$1" | shasum -a 1)"
  else
    h="$(printf '%s' "$1" | sha1sum 2>/dev/null)"
  fi
  printf '%s\n' "$h" | awk '{ print substr($1, 1, 10) }'
}

avisos_datos_de() { # $1 reg $2 sesion -> "estado\trol\tcli\tlead" (rol/cli vacios si no esta)
  AV_REG="$1" AV_S="$2" python3 -c "
import json,os
d=json.load(open(os.environ['AV_REG']))
ent=None; lead=''
for x in d.get('sesiones') or []:
    if not isinstance(x,dict): continue
    if x.get('nombre')==os.environ['AV_S']: ent=x
    if x.get('rol')=='lead' and x.get('nombre'): lead=x['nombre']
print('\t'.join([str(d.get('estado') or ''), str((ent or {}).get('rol') or ''),
                 str((ent or {}).get('cli') or ''), lead]))" 2>/dev/null
}

avisos_lead_de() { # $1 reg -> nombre de la sesion lead (vacio si no hay)
  AV_REG="$1" python3 -c "
import json,os
d=json.load(open(os.environ['AV_REG']))
for x in d.get('sesiones') or []:
    if isinstance(x,dict) and x.get('rol')=='lead' and x.get('nombre'):
        print(x['nombre']); break" 2>/dev/null
}

avisos_registradas_de() { # $1 reg -> nombres de sesiones registradas, uno por linea
  AV_REG="$1" python3 -c "
import json,os
d=json.load(open(os.environ['AV_REG']))
for x in d.get('sesiones') or []:
    if isinstance(x,dict) and x.get('nombre'): print(x['nombre'])" 2>/dev/null
}

avisos_escribir() { # $1 dir $2 id $3 corrida $4 sesion $5 rol $6 cli $7 tipo $8 detalle
  mkdir -p "$1" || return 1
  AV_D="$1" AV_ID="$2" AV_C="$3" AV_S="$4" AV_ROL="$5" AV_CLI="$6" AV_T="$7" AV_DET="$8" \
  python3 -c "
import json,os,time
d={'schema':'corrida-aviso.v1','id':os.environ['AV_ID'],'corrida':os.environ['AV_C'],
   'sesion':os.environ['AV_S'],'rol':os.environ['AV_ROL'],'cli':os.environ['AV_CLI'],
   'tipo':os.environ['AV_T'],'creado':int(time.time()*1000),'detalle':os.environ['AV_DET']}
p=os.path.join(os.environ['AV_D'],os.environ['AV_ID']+'.json')
t=os.path.join(os.environ['AV_D'],'.'+os.environ['AV_ID']+'.'+str(os.getpid())+'.tmp')
open(t,'w').write(json.dumps(d,ensure_ascii=False,sort_keys=True)+chr(10))
os.chmod(t,0o600)
os.rename(t,p)" 2>/dev/null
}

avisos_marcar() { # $1 archivo $2 campo (atendido|descartado) $3 valor; reescritura atomica
  AV_F="$1" AV_K="$2" AV_V="$3" python3 -c "
import json,os
p=os.environ['AV_F']
d=json.load(open(p))
d[os.environ['AV_K']]=int(os.environ['AV_V']) if os.environ['AV_K']=='atendido' else os.environ['AV_V']
t=p+'.tmp'
open(t,'w').write(json.dumps(d,ensure_ascii=False,sort_keys=True)+chr(10))
os.chmod(t,0o600)
os.rename(t,p)" 2>/dev/null
}

avisos_evento() { # $1 corrida $2 true|false $3 detalle -> una linea en eventos.jsonl
  AV_EV="$CORRIDA_STATE/$1/eventos.jsonl" AV_OK="$2" AV_D="$3" python3 -c "
import json,os,time
p={'tipo':'avisos-atendidos','ok':os.environ['AV_OK']=='true','detalle':os.environ['AV_D'],
   'at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
open(os.environ['AV_EV'],'a').write(json.dumps(p,ensure_ascii=False)+chr(10))" 2>/dev/null
}

avisos_despertar_dueno() { # $1 corrida $2 reg; 0 = desperto (o no habia a quien).
                           # Jamas falla el emitir: el pendiente persiste y el
                           # reintento del vigia vuelve a intentarlo.
  local corrida="$1" reg="$2" lead pantalla
  lead="$(avisos_lead_de "$reg")"
  [ -n "$lead" ] || return 0
  "$TMUX_BIN" has-session -t "=$lead" 2>/dev/null || return 0
  pantalla="$("$TMUX_BIN" capture-pane -p -t "=$lead:" 2>/dev/null)" || return 0
  # Solo la cola del panel es un dialogo: un lead que HABLA de aprobaciones mas
  # arriba no esta ocupado (mismo criterio conservador del vigia).
  if printf '%s\n' "$pantalla" | grep -v '^[[:space:]]*$' | tail -n 15 | grep -Eqi -- "$AVISOS_APROB_RE"; then
    return 0
  fi
  "$TMUX_BIN" send-keys -t "=$lead:" -l -- "corrida.sh avisos atender $corrida" 2>/dev/null || return 0
  "$TMUX_BIN" send-keys -t "=$lead:" Enter 2>/dev/null || return 0
  return 0
}

avisos_emitir() {
  [ "${CORRIDA_AVISOS:-1}" = "0" ] && return 0
  if [ "$#" -lt 3 ]; then
    echo "uso: corrida.sh avisos emitir <corrida> <sesion> <fin-turno|aprobacion|cierre> --llave <cadena> [detalle ...]" >&2
    return 2
  fi
  local corrida="$1" sesion="$2" tipo="$3"; shift 3
  local llave="" detalle="" datos estado rol cli reg id
  while [ $# -gt 0 ]; do
    case "$1" in
      --llave)
        [ $# -ge 2 ] || { echo "avisos emitir: --llave sin valor" >&2; return 2; }
        llave="$2"; shift 2;;
      -*)
        echo "avisos emitir: flag desconocido $1" >&2; return 2;;
      *)
        detalle="${detalle:+$detalle }$1"; shift;;
    esac
  done
  case "$tipo" in
    fin-turno|aprobacion|cierre) ;;
    *) echo "avisos emitir: tipo fuera del conjunto: $tipo" >&2; return 2;;
  esac
  [ -n "$llave" ] || { echo "avisos emitir: llave vacia" >&2; return 2; }
  [ "${#detalle}" -le 200 ] || { echo "avisos emitir: el detalle supera 200 caracteres" >&2; return 2; }
  # Codigos de salida de emitir: 0 = emitido o deduplicado; 2 = uso invalido;
  # 1 = fallo pasajero (el lock no cedio: el reintento del vigia aplica); 3 =
  # RECHAZO DEFINITIVO (no existe, corrida cerrada o sesion ajena: ningun
  # reintento puede arreglarlo y el vigia descarta el registro).
  corrida_id_valido "$corrida" || { echo "avisos emitir: id invalido: $corrida" >&2; return 3; }
  reg="$(registro_de "$corrida")"
  [ -f "$reg" ] || { echo "avisos emitir: sin registro: $corrida" >&2; return 3; }
  lock_tomar "$reg" || { echo "avisos emitir: el lock de $corrida no cedio" >&2; return 1; }
  datos="$(avisos_datos_de "$reg" "$sesion")"
  estado="$(printf '%s' "$datos" | cut -f1)"
  rol="$(printf '%s' "$datos" | cut -f2)"
  cli="$(printf '%s' "$datos" | cut -f3)"
  if [ "$estado" != "abierta" ]; then
    lock_soltar "$reg"
    echo "avisos emitir: la corrida $corrida no esta abierta (estado: $estado)" >&2
    return 3
  fi
  if [ -z "$rol" ]; then
    lock_soltar "$reg"
    echo "avisos emitir: la sesion $sesion no esta en el registro de $corrida" >&2
    return 3
  fi
  id="${corrida}-${sesion}-${tipo}-$(avisos_sha1 "$llave")"
  if [ -e "$CORRIDA_STATE/$corrida/avisos/$id.json" ]; then
    lock_soltar "$reg"
    return 0
  fi
  if ! avisos_escribir "$CORRIDA_STATE/$corrida/avisos" "$id" "$corrida" "$sesion" "$rol" "$cli" "$tipo" "$detalle"; then
    lock_soltar "$reg"
    echo "avisos emitir: no se pudo escribir el aviso de $sesion" >&2
    return 1
  fi
  lock_soltar "$reg"
  avisos_despertar_dueno "$corrida" "$reg"
  return 0
}

avisos_atender() {
  [ "${CORRIDA_AVISOS:-1}" = "0" ] && return 0
  if [ "$#" -ne 1 ]; then
    echo "uso: corrida.sh avisos atender <corrida>" >&2
    return 2
  fi
  local corrida="$1" reg dir f estado ses salida rc=0 n=0 validos=0
  corrida_id_valido "$corrida" || { echo "avisos atender: id invalido: $corrida" >&2; return 1; }
  reg="$(registro_de "$corrida")"
  [ -f "$reg" ] || { echo "avisos atender: sin registro: $corrida" >&2; return 1; }
  dir="$CORRIDA_STATE/$corrida/avisos"
  [ -d "$dir" ] || { echo "sin pendientes"; return 0; }
  mkdir -p "$dir/tratados" || { echo "avisos atender: no se pudo crear tratados" >&2; return 1; }
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    mv "$f" "$dir/tratados/" || continue
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "sin pendientes"; return 0; }
  lock_tomar "$reg" || { echo "avisos atender: el lock de $corrida no cedio" >&2; return 1; }
  estado="$(json_campo "$reg" estado)"
  ses="$(avisos_registradas_de "$reg")"
  lock_soltar "$reg"
  for f in "$dir/tratados"/*.json; do
    [ -f "$f" ] || continue
    if [ "$estado" != "abierta" ]; then
      avisos_marcar "$f" descartado "la corrida $corrida no esta abierta"
      continue
    fi
    if printf '%s\n' "$ses" | grep -Fxq -- "$(json_campo "$f" sesion)"; then
      avisos_marcar "$f" atendido "$(python3 -c 'import time; print(int(time.time()*1000))')" \
        || { echo "avisos atender: no se pudo anotar $f" >&2; continue; }
      validos=$((validos + 1))
    else
      avisos_marcar "$f" descartado "la sesion $(json_campo "$f" sesion) ya no esta registrada"
    fi
  done
  printf 'avisos: %s atendidos, %s descartados\n' "$validos" "$((n - validos))"
  [ "$validos" -gt 0 ] || return 0
  local corr_bin="${CORRIDA_BIN:-}"
  if [ -z "$corr_bin" ]; then
    corr_bin="$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/corrida.sh"
  fi
  salida="$(bash "$corr_bin" reconciliar "$corrida" 2>&1)" || rc=$?
  avisos_evento "$corrida" "$( [ "$rc" -eq 0 ] && echo true || echo false )" \
    "$(printf '%s\n' "$salida" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-200)"
  return 0
}

avisos_despertar() {
  [ "${CORRIDA_AVISOS:-1}" = "0" ] && return 0
  [ "$#" -ge 1 ] || { echo "uso: corrida.sh avisos despertar <corrida> [corrida ...]" >&2; return 2; }
  # Varios ids en UNA invocacion: el reintento del vigia corre una vez por tick
  # y un spawn de corrida.sh por pendiente retrasaba el tick entero.
  local corrida reg dir f hay
  for corrida in "$@"; do
    corrida_id_valido "$corrida" || continue
    reg="$(registro_de "$corrida")"
    [ -f "$reg" ] || continue
    [ "$(json_campo "$reg" estado)" = "abierta" ] || continue
    dir="$CORRIDA_STATE/$corrida/avisos"
    [ -d "$dir" ] || continue
    hay=""
    for f in "$dir"/*.json; do
      [ -f "$f" ] || { continue; }
      hay=1
      break
    done
    [ -n "$hay" ] || continue
    avisos_despertar_dueno "$corrida" "$reg"
  done
  return 0
}

corrida_avisos() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    emitir) avisos_emitir "$@";;
    atender) avisos_atender "$@";;
    despertar) avisos_despertar "$@";;
    *) echo "uso: corrida.sh avisos <emitir|atender|despertar> ..." >&2; return 2;;
  esac
}
