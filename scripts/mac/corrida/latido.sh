#!/bin/bash
# corrida/latido.sh (9.5). latido: el seguimiento garantizado, sin modelo.
# Lo lanza el vigilante tmux-activity-watch.sh al final de un tick, cada
# LATIDO_SECS (300 s) y con tope LATIDO_TOPE (14.29 D1: el LaunchAgent
# ai.goncloud.corrida-latido sigue descargado y no hay otro reloj). Por cada
# corrida abierta calcula el parte (9.4), manda el mensaje a David cuando
# cambio el estado (o a la hora sin mensaje, o NECESITO cuando un dialogo
# lleva 10 min o la politica no lo cubre), y despierta al vigia con el parte y
# la accion que toca segun loop 12: system event para claw, linea en
# eventos.jsonl para hermes (9.0). Todo evento que produce queda en
# <dir>/eventos.jsonl. Tope: un mensaje cada 15 min salvo NECESITO. El cron
# hombre-muerto que abre creo en el gateway sigue hablando si este muere.
# Inyectables: CORR_AHORA (reloj), OPENCLAW_BIN, y los de estado.sh.
. "$(dirname "${BASH_SOURCE[0]}")/estado.sh"

LAT_TOPE_MSG=900    # 15 min entre mensajes, salvo NECESITO
LAT_HORA_MSJ=3600   # sin mensaje aunque todo avance: a la hora, uno
LAT_VENTANA=14400   # el consolidador calla mientras no hay novedad y manda un
                    # latido a las 4 horas (LATIDO_SIN_NOVEDAD_SECS en
                    # tablero-runbook/seguimiento-clock.ts). Pasado corte_base
                    # + ella el latido de verdad no llego. 14400 cae en la
                    # cuadricula de 15 min del cron.
LAT_SILENCIO=14700  # un tick (300 s) DESPUES del plazo: mientras el
                    # consolidador esta sano y callado este control no habla,
                    # y cuando habla es porque el latido ya no llego. Medido el
                    # 2026-10-07: con el umbral por debajo del plazo avisaba
                    # de un reloj sano antes de cada latido.

evento_jsonl() { # $1 dir de la corrida; pares EVT_<campo>=valor en el entorno.
                 # Solo los campos del evento van en la linea: la linea ya vive
                 # en el directorio de la corrida (nada de rutas absolutas).
  EVT_DIR="$1" EVT_AT="$(epoch_a_iso "$(corr_ahora)")" python3 -c "
import json,os
p={k[4:]:v for k,v in os.environ.items() if k.startswith('EVT_') and k not in ('EVT_DIR','EVT_AT')}
p['at']=os.environ['EVT_AT']
open(os.path.join(os.environ['EVT_DIR'],'eventos.jsonl'),'a').write(json.dumps(p)+chr(10))" 2>/dev/null
}

lat_consolidador_corte() { # -> "ILEGIBLE" (el gateway no entrego la lista de
                           # crons) o "<epoch>": la base del corte del
                           # consolidador (cron avance-tareas) tomada de su
                           # scratch, ultimoReporteConfirmado o inicioVentana
                           # segun kind. 0 = sin rastro legible (sin cron, o
                           # scratch ausente/roto/otra version).
  local ids id0 out
  ids="$(cron_jobs_de avance-tareas)"
  case "$ids" in
    ILEGIBLE|"") printf 'ILEGIBLE\n'; return 0;;
    NINGUNO) printf '0\n'; return 0;;
  esac
  id0="$(printf '%s\n' "$ids" | sed -n '1p')"
  [ -n "$id0" ] || { printf '0\n'; return 0; }
  out="$(con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" cron scratch "$id0" 2>/dev/null)" || out=""
  SCRATCH_RAW="$out" python3 -c "
import json,os
try:
  t=os.environ['SCRATCH_RAW']
  d=json.loads(t[t.index('{'):])
  if d.get('schema')!='seguimiento-clock.v1': raise ValueError
  c=d.get('corte') or {}
  k=c.get('kind')
  v=c.get('ultimoReporteConfirmado') if k=='reporte-confirmado' else (c.get('inicioVentana') if k=='esperando-primer-reporte' else None)
  if isinstance(v,bool) or not isinstance(v,(int,float)) or v<=0: raise ValueError
  print(int(v))
except Exception:
  print(0)" 2>/dev/null
}

lat_avance_ultima_senal() { # $1 dir de la corrida -> "ILEGIBLE" o "<senal> <corte>".
                            # senal: la ultima vez que hubo señal de avance,
                            # el max entre el ultimo mensaje entregado (linea
                            # con ok en mensajes.jsonl) y la confirmacion del
                            # consolidador (funcion de arriba). corte: la base
                            # del consolidador, para decir a que hora se debia
                            # el reporte que falta.
  local at cr
  cr="$(lat_consolidador_corte)"
  [ "$cr" = "ILEGIBLE" ] && { printf 'ILEGIBLE\n'; return 0; }
  at="$(MJL="$1/mensajes.jsonl" python3 -c "
import json,os
at=0
try:
  for l in open(os.environ['MJL']):
    try: d=json.loads(l)
    except Exception: continue
    if d.get('ok') is True:
      v=d.get('at')
      if isinstance(v,(int,float)) and not isinstance(v,bool) and v>at: at=v
except Exception:
  pass
print(int(at))" 2>/dev/null)"
  [ -n "$at" ] || at=0
  [ "$cr" -gt "$at" ] && at="$cr"
  printf '%s %s\n' "$at" "$cr"
}

lat_escribir() { # $1 latido.json $2 firma $3 ult_msj $4 etq $5 firma_vigia $6 ci_sha
  LATF="$1" L_FIRMA="$2" L_ULT="$3" L_ETQ="$4" L_FV="$5" L_CI="${6:-}" python3 -c "
import json,os
E=os.environ
d={'firma':E['L_FIRMA'],'ult_msj':int(E['L_ULT']),'etq':E['L_ETQ'],
   'firma_vigia':E['L_FV'],'ci_sha':E['L_CI']}
t=E['LATF']+'.tmp'
open(t,'w').write(json.dumps(d,indent=1)+chr(10))
os.chmod(t,0o600)
os.rename(t,E['LATF'])" 2>/dev/null
}

latido_de() { # $1 dir de la corrida (con el registro adentro)
  local dir="$1" id reg now lat lrc=0
  id="$(basename "$dir")"
  reg="$dir/registro.json"
  parte_calcular "$id" || return 0
  now="$(corr_ahora)"
  lat="$dir/latido.json"
  local lfirma="" lult=0 letq="" lfv="" lci=""
  if [ -f "$lat" ]; then
    lfirma="$(json_campo "$lat" firma)"
    lult="$(json_campo "$lat" ult_msj)"; [ -n "$lult" ] && [ "$lult" != "None" ] || lult=0
    letq="$(json_campo "$lat" etq)"
    lfv="$(json_campo "$lat" firma_vigia)"
    lci="$(json_campo "$lat" ci_sha)"
  fi
  local parte4
  parte4="[$P_ETIQ] Corrida, $P_AVANCE / Que cambio: $P_CAMBIO / Que sigue: $P_SIGUE / Que necesito de ti: $P_NECESITO"

  # (1) el mensaje a David: cambio de estado, hora sin mensaje, o NECESITO.
  # NECESITO no espera al tope cuando es nueva (la firma cambio) o lleva 15 min
  # sin nadie contestarla; pero la misma espera parada no se remanda cada tick.
  local enviar=0
  if [ "$P_ETIQ" = "NECESITO TU RESPUESTA" ]; then
    if [ "$P_FIRMA" != "$lfirma" ] || [ "$lult" -eq 0 ] || [ $(( now - lult )) -ge "$LAT_TOPE_MSG" ]; then
      enviar=1
    fi
  elif [ "$P_FIRMA" != "$lfirma" ]; then
    if [ "$lult" -eq 0 ] || [ $(( now - lult )) -ge "$LAT_TOPE_MSG" ]; then enviar=1; fi
  elif [ "$lult" -gt 0 ] && [ $(( now - lult )) -ge "$LAT_HORA_MSJ" ]; then
    enviar=1
  fi
  if [ "$enviar" -eq 1 ]; then
    if corrida_mensaje "$id" "$P_ETIQ" "$P_AVANCE" "$P_CAMBIO" "$P_SIGUE" "$P_NECESITO"; then
      lfirma="$P_FIRMA"; lult="$now"; letq="$P_ETIQ"
      # NG: la memoria caida no corta el resto del tick (vigia y CI siguen);
      # avisa, queda en el rc del tick y el proximo repite el aviso si hace falta.
      if ! lat_escribir "$lat" "$lfirma" "$lult" "$letq" "$lfv" "$lci"; then
        echo "latido: no se pudo escribir $lat; el proximo tick puede repetir el ultimo aviso" >&2
        lrc=1
      fi
      EVT_tipo=mensaje EVT_etiqueta="$P_ETIQ" EVT_firma="$P_FIRMA" evento_jsonl "$dir"
    else
      # sin memoria nueva: el proximo tick reintenta con el mismo cambio.
      EVT_tipo=mensaje EVT_etiqueta="$P_ETIQ" EVT_ok=false evento_jsonl "$dir"
    fi
  fi

  # (1b) 14.8 r2: el aviso de avance lo manda el corte del consolidador (cron
  # avance-tareas), y cuando ese corte calla nadie avisa — el silencio de sim9.
  # Este bloque es la garantia del latido: con corrida abierta y mas de
  # LAT_SILENCIO (4 horas mas un tick) sin NINGUNA senal de avance (ni confirmacion del
  # consolidador ni mensaje entregado a David), manda su PROPIO aviso por el
  # camino directo (corrida_aviso_directo, sin pasar por la acumulacion del
  # AVANZA, que es lo callado) y deja constancia en eventos.jsonl AUNQUE el
  # envio falle (el proximo tick reintenta: mensajes.jsonl no cambio). La
  # autodeduplicacion no necesita estado nuevo: el aviso entregado queda
  # anotado en mensajes.jsonl con ok, la senal avanza sola y el proximo tick
  # no reavisa hasta otro rago de LAT_SILENCIO. Con el gateway sin respuesta
  # (cron list ilegible) el control se salta este tick con su rastro en
  # stderr: contra un gateway callado no hay envio posible; al volver, si el
  # corte sigue callado, avisa. El umbral va DESPUES del plazo del latido del
  # consolidador (LAT_VENTANA): antes de el un reloj callado esta sano y este
  # control no dice nada; pasado, "se debía ... y no ha llegado" dice la verdad
  # con la hora real (owed es corte_base + LAT_VENTANA).
  local lect senal corte_base apertura owed cambio_td rc_td
  lect="$(lat_avance_ultima_senal "$dir")"
  if [ "$lect" = "ILEGIBLE" ]; then
    echo "latido: el consolidador no respondio (cron list ilegible): el control de silencio se salta este tick" >&2
  else
    senal="${lect%% *}"; corte_base="${lect#* }"
    apertura="$(REG_AP="$reg" python3 -c "
import json,os
from datetime import datetime
try: print(int(datetime.fromisoformat(json.load(open(os.environ['REG_AP'])).get('inicio') or '').timestamp()))
except Exception: print(0)" 2>/dev/null)"
    [ -n "$apertura" ] || apertura=0
    [ "$apertura" -gt "$senal" ] && senal="$apertura"
    if [ $(( now - senal )) -ge "$LAT_SILENCIO" ]; then
      if [ "$corte_base" -gt 0 ]; then
        # senal >= corte_base y LAT_SILENCIO > LAT_VENTANA: aqui el plazo ya
        # paso siempre, asi que la hora que se anuncia es la real.
        owed=$(( corte_base + LAT_VENTANA ))
        cambio_td="el reporte de avance se debía a las $(OWED_HM="$owed" python3 -c "
import os
from datetime import datetime
print(datetime.fromtimestamp(int(os.environ['OWED_HM'])).strftime('%H:%M'))" 2>/dev/null) y no ha llegado; te aviso desde el latido"
      else
        owed=""
        cambio_td="el reloj de avance no dejó rastro legible; te aviso desde el latido"
      fi
      rc_td=0
      # La etiqueta es la del parte (14.27 R16): una corrida DETENIDA no sale
      # como AVANZA. No se limita a AVANZA porque (1) solo reenvia un DETENIDO
      # igual a la hora y la promesa de 14.8 es no pasar de 4 horas sin aviso.
      corrida_aviso_directo "$id" "$P_ETIQ" "$P_AVANCE" "$cambio_td" "$P_SIGUE" "$P_NECESITO" || rc_td=1
      EVT_tipo=avance-tardanza EVT_owed="$(epoch_a_iso "$owed")" \
        EVT_ok="$([ "$rc_td" -eq 0 ] && echo true || echo false)" evento_jsonl "$dir"
    fi
  fi

  # (2) el vigia: con el parte y la accion que toca (loop 12). claw se despierta
  # con system event; hermes lee la linea de eventos.jsonl por ssh (9.0). Solo
  # cuando hay acciones: un parte sin nada pendiente no gasta un turno del vigia.
  if [ -n "$P_ACCIONES" ] && [ "$P_FIRMA" != "$lfv" ]; then
    local vigia rc=0 acc_claves
    vigia="$(json_campo "$reg" vigia)"
    acc_claves="$(printf '%s\n' "$P_ACCIONES" | cut -d'|' -f1 | paste -sd, -)"
    if [ "$vigia" = "claw" ]; then
      # Misma sesion de la corrida que usa send_event del vigilante
      # (tmux-activity-watch.sh): sin la clave el parte caia en agent:main:main
      # y los closed de la misma corrida en otra sesion.
      con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" system event --mode now --timeout 15000 \
        --session-key "agent:main:sim9-$id" \
        --text "corrida $id | accion: ${P_ACCIONES//$LF/ ; } | parte: $parte4 | estado: $dir" \
        >/dev/null 2>&1 || rc=1
      EVT_tipo=evento-vigia EVT_vigia="$vigia" EVT_accion="$acc_claves" \
        EVT_ok="$([ "$rc" -eq 0 ] && echo true || echo false)" \
        EVT_corrida="$id" EVT_parte="$parte4" evento_jsonl "$dir"
    else
      # hermes: la linea de eventos.jsonl ES el aviso; si no se pudo escribir,
      # no se marca enviada (el proximo tick la reintenta).
      EVT_tipo=evento-vigia EVT_vigia="$vigia" EVT_accion="$acc_claves" \
        EVT_ok=true EVT_corrida="$id" EVT_parte="$parte4" evento_jsonl "$dir" || rc=1
    fi
    if [ "$rc" -eq 0 ]; then
      lfv="$P_FIRMA"
      lat_escribir "$lat" "$lfirma" "$lult" "$letq" "$lfv" "$lci" \
        || { echo "latido: no se pudo escribir $lat; el vigia puede despertarse de mas al proximo tick" >&2; lrc=1; }
    fi
  fi

  # (3) 9.8: la rama por defecto en rojo no pasa en silencio (medido
  # 2026-09-17: main 8 h en rojo por un snapshot que no paso por CI de PR). Se
  # consulta la ultima corrida del workflow de calidad en la rama por defecto
  # (solo campos que el gh real soporta: con "actor" rechaza la invocacion
  # entera y el chequeo moria en silencio); si concluyo en fallo (incluido
  # timeout y fallo de arranque) y ese sha no se aviso, sale un DETENIDA en
  # lenguaje de usuario (sin decir "automatico": el rojo puede venir de un
  # merge humano, 14.27 R14) y el sha, el autor y los archivos — sacados de la
  # MISMA llamada al commit — quedan en el registro local de la corrida, que
  # es donde el lead los lee (el validador de 9.1 no deja citarlos en el
  # mensaje, y esta fila no es excepcion). gh caido: cero avisos, el latido
  # sigue — pero la consulta que no responde deja rastro (stderr y evento
  # gh-fallo), nunca un salto en silencio. El mismo sha avisado no se vuelve a
  # avisar; y el registro local con "avisado" solo se escribe tras un envio
  # que salio (si el envio cae, el proximo tick reintenta).
  local GH="${GH_BIN:-$(command -v gh 2>/dev/null || true)}"
  if [ -n "$GH" ]; then
    local repo def out sha="" concl="" stat=""
    repo="${REPO_DIR:-${CORR_REPO_RAIZ:-$PWD}}"
    def="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    [ -n "$def" ] || def="main"
    out="$(cd "$repo" 2>/dev/null && con_tope "$CORR_TOPE_RED" "$GH" run list --workflow quality.yml --branch "$def" --limit 1 --json headSha,conclusion,status 2>/dev/null)" \
      || out=""
    if [ -z "$out" ]; then
      # sin respuesta (gh caido o invocacion rechazada): cero mensajes, pero
      # el diagnostico no se pierde (ni siquiera si anotarlo tambien falla).
      echo "latido: no se pudo consultar la ultima corrida de CI (rama $def): el chequeo de rama en rojo se salto este tick" >&2
      EVT_tipo=gh-fallo EVT_rama="$def" evento_jsonl "$dir" \
        || echo "latido: y no se pudo anotar el fallo de gh en eventos.jsonl" >&2
    fi
    if [ -n "$out" ]; then
      # separador de unidad: un campo vacio no corre los demas (con tab y IFS
      # default, dos tab seguidos son un solo separador).
      IFS="$(printf '\037')" read -r sha concl stat <<EOF
$(printf '%s' "$out" | python3 -c "
import sys,json
try: d=(json.load(sys.stdin) or [{}])[0]
except Exception: d={}
print(chr(31).join([str(d.get(k) or '') for k in ('headSha','conclusion','status')]))" 2>/dev/null)
EOF
      local es_rojo=0
      case "$stat:$concl" in
        completed:failure|completed:timed_out|completed:startup_failure) es_rojo=1;;
      esac
      if [ "$es_rojo" = "1" ] && [ -n "$sha" ] && [ "$sha" != "$lci" ]; then
        local slug="" archivos="" autor=""
        slug="$(cd "$repo" 2>/dev/null && con_tope "$CORR_TOPE_RED" "$GH" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || slug=""
        if [ -n "$slug" ]; then
          # una sola llamada al commit trae autor Y archivos
          local info=""
          info="$(cd "$repo" 2>/dev/null && con_tope "$CORR_TOPE_RED" "$GH" api "repos/$slug/commits/$sha" 2>/dev/null \
            | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
a=(d.get('commit') or {}).get('author') or {}
print(a.get('name') or '')
print(chr(10).join(f.get('filename','') for f in d.get('files',[]) if f.get('filename')))" 2>/dev/null)" || info=""
          autor="$(printf '%s\n' "$info" | sed -n '1p')"
          archivos="$(printf '%s\n' "$info" | sed -n '2,$p')"
        fi
        if [ -z "$slug" ] || [ -z "$autor" ] || [ -z "$archivos" ]; then
          # TA: el rojo se vio, pero el commit no entrego sus metadatos: sin
          # aviso y sin registro (el contrato los exige), con rastro, y el sha
          # sin marcar para reintentar al proximo tick.
          echo "latido: el commit $sha no entrego autor o archivos: el aviso de rojo espera al proximo tick" >&2
          EVT_tipo=gh-fallo EVT_rama="$def" EVT_motivo="commit sin metadatos" evento_jsonl "$dir" \
            || echo "latido: y no se pudo anotar el fallo de gh en eventos.jsonl" >&2
        elif corrida_mensaje "$id" "DETENIDA" "$P_AVANCE" \
            "el repositorio central quedo en rojo tras un cambio; ya se esta revisando" \
            "$P_SIGUE" "nada"; then
          if CIDIR="$dir" CI_SHA="$sha" CI_AUTOR="$autor" CI_ARCH="$archivos" \
             CI_AT="$(epoch_a_iso "$now")" python3 -c "
import json,os
d={'sha':os.environ['CI_SHA'],'autor':os.environ['CI_AUTOR'],
   'archivos':[l for l in os.environ['CI_ARCH'].splitlines() if l],
   'avisado':os.environ['CI_AT']}
t=os.path.join(os.environ['CIDIR'],'ci-rojo.json')
open(t+'.tmp','w').write(json.dumps(d,indent=1)+chr(10))
os.chmod(t+'.tmp',0o600)
os.rename(t+'.tmp',t)" 2>/dev/null; then
            lci="$sha"
            lat_escribir "$lat" "$lfirma" "$lult" "$letq" "$lfv" "$lci" \
              || { echo "latido: no se pudo escribir $lat; el aviso de rojo puede repetirse al proximo tick" >&2; lrc=1; }
            EVT_tipo=ci-rojo EVT_sha="$sha" EVT_autor="$autor" EVT_ok=true evento_jsonl "$dir"
          else
            # TB: el registro no persistio: el sha NO queda marcado (el proximo
            # tick reavisa y reintenta el registro) y el tick sale fallado.
            echo "latido: no se pudo escribir $dir/ci-rojo.json; el sha queda sin marcar y el aviso se reintenta" >&2
            lrc=1
            EVT_tipo=ci-rojo EVT_sha="$sha" EVT_autor="$autor" EVT_ok=false evento_jsonl "$dir"
          fi
        else
          EVT_tipo=ci-rojo EVT_sha="$sha" EVT_autor="$autor" EVT_ok=false evento_jsonl "$dir"
        fi
      fi
    fi
  fi
  return "$lrc"
}

corrida_latido() {
  # El vigilante llama este tick aunque no haya corridas nativas abiertas. El
  # outbox también contiene tableros manuales y fases; se reintenta sin esperar
  # a que ocurra otro cambio de estado.
  local progress_bin="${PROGRESS_EVENTS_BIN:-$HOME/bin/progress-events.py}"
  if [ -x "$progress_bin" ]; then
    con_tope 20 "$progress_bin" publish-all >/dev/null 2>&1 \
      || echo "latido: progreso pendiente; se reintentará en el próximo tick" >&2
  fi
  [ -d "$CORRIDA_STATE" ] || return 0
  local dir reg rcg=0
  for dir in "$CORRIDA_STATE"/*/; do
    [ -d "$dir" ] || continue
    reg="${dir%/}/registro.json"
    [ -f "$reg" ] || continue
    validar_registro "$reg" >/dev/null 2>&1 || continue
    [ "$(json_campo "$reg" estado)" = "abierta" ] || continue
    latido_de "${dir%/}" || rcg=1
  done
  return "$rcg"
}
