#!/bin/bash
# corrida/estado.sh (9.4). estado <id> [--solo-mensaje]: el parte de la corrida,
# sin modelo. Lee el registro, el espejo del progreso (progress.json), la ultima
# linea de contrato de cada sesion, los dialogos y la quietud del estado del
# vigilante, la ventana de trabajo con pausas y las propuestas abiertas por gh;
# emite el texto de seguimiento.v1 y, debajo, el detalle para el vigia (que no
# va a David). Inyectables: CORR_AHORA (reloj), TMUX_BIN, GH_BIN,
# WATCH_STATE_DIR, CORRIDA_STATE, REPO_DIR. Compatible con /bin/bash 3.2.

LF='
'

corr_ahora() { # reloj inyectable: CORR_AHORA en segundos de epoch
  if [ -n "${CORR_AHORA:-}" ] && printf '%s' "$CORR_AHORA" | grep -qE '^[0-9]+$'; then
    printf '%s' "$CORR_AHORA"
  else
    date +%s
  fi
}

iso_a_epoch() { # $1 ISO con zona (la forma que abre escribe); vacio si no parsea
  ISOS="$1" python3 -c "
import os,calendar,time
try:
  print(int(calendar.timegm(time.strptime(os.environ['ISOS'],'%Y-%m-%dT%H:%M:%S%z'))))
except Exception:
  print('')" 2>/dev/null
}

epoch_a_iso() { # $1 epoch -> ISO UTC; determinista tambien bajo reloj inyectado
  EPE="$1" python3 -c "
import os,time
try: print(time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(int(os.environ['EPE']))))
except Exception: print('')" 2>/dev/null
}

watch_campo() { # $1 sesion, $2 campo del .state del vigilante (vacio si no hay)
  awk -v k="$2" 'index($0, k "=")==1 {print substr($0, length(k)+2)}' \
    "${WATCH_STATE_DIR:-$HOME/.local/state/tmux-activity-watch}/$1.state" 2>/dev/null
}

min_desde() { # $1 epoch del hito -> minutos enteros desde ahi (0 si negativo)
  local d=$(( $(corr_ahora) - $1 ))
  [ "$d" -lt 0 ] && d=0
  echo $(( d / 60 ))
}

# panel_limpio <archivo crudo> <archivo destino>: ultima pantalla legible para el
# detalle. Solo imprimible mas tab y salto de linea (nada de escapes ni retornos
# de carro), las ultimas 15 lineas no vacias, tope de 5000 bytes con marca.
panel_limpio() {
  local tmp bytes
  tmp="$(mktemp)" || return 1
  LC_ALL=C tr -cd '\11\12\40-\176' < "$1" > "$tmp" 2>/dev/null
  grep -v '^[[:space:]]*$' "$tmp" 2>/dev/null | tail -15 > "$tmp.15"
  bytes="$(wc -c < "$tmp.15" 2>/dev/null | tr -d ' ')"
  if [ "${bytes:-0}" -gt 5000 ]; then
    head -c 5000 "$tmp.15" > "$2"; printf '\n[panel recortado]\n' >> "$2"
  else
    cp "$tmp.15" "$2" 2>/dev/null || : > "$2"
  fi
  rm -f "$tmp" "$tmp.15"
  return 0
}

contrato_de_panel() { # $1 panel -> "LISTO <sha>" | "ATORADO ..." | "" (la ultima)
  grep -E '^[[:space:]]*(LISTO [0-9a-f]{7,}|ATORADO .+)' "$1" 2>/dev/null \
    | tail -1 | sed 's/^[[:space:]]*//'
}

# Dialogo cubierto por la tabla de preaprobaciones del registro: algun patron
# aprobado calza en la cola de la pantalla. Sin tabla, o con patron que no calza,
# la politica no lo cubre y eso escala de inmediato.
dialogo_cubierto() { # $1 registro, $2 panel; 0 = cubierto
  local patron restos
  restos="$(grep -v '^[[:space:]]*$' "$2" 2>/dev/null | tail -15)"
  [ -n "$restos" ] || return 1
  while IFS= read -r patron; do
    [ -n "$patron" ] || continue
    printf '%s' "$restos" | grep -qiE -- "$patron" && return 0
  done <<EOF
$(REGPRE="$1" python3 -c "
import json,os
try:
  d=json.load(open(os.environ['REGPRE']))
except Exception:
  d={}
for p in d.get('preaprobaciones') or []:
  if p.get('decision')=='Aprobado' and p.get('patron'):
    print(p['patron'])" 2>/dev/null)
EOF
  return 1
}

prs_por_gh() { # deja en GH_TXT el recuento en palabras; gh caido = sin verificar
  GH_TXT="GitHub: sin verificar"
  local GH="${GH_BIN:-$(command -v gh 2>/dev/null || true)}"
  [ -n "$GH" ] || return 0
  local dir="${REPO_DIR:-${CORR_REPO_RAIZ:-$PWD}}" out n
  out="$(cd "$dir" 2>/dev/null && con_tope "$CORR_TOPE_RED" "$GH" pr list --state open --limit 30 --json number 2>/dev/null)" \
    || return 0
  n="$(printf '%s' "$out" | python3 -c "
import sys,json
try: print(len(json.load(sys.stdin)))
except Exception: print(-1)" 2>/dev/null)"
  case "${n:-}" in
    0) GH_TXT="GitHub: sin propuestas abiertas";;
    1) GH_TXT="GitHub: una propuesta abierta";;
    [0-9]*) GH_TXT="GitHub: $n propuestas abiertas";;
  esac
  return 0
}

# parte_calcular <id>: deja el parte en P_ETIQ P_AVANCE P_CAMBIO P_SIGUE
# P_NECESITO, la firma discreta del estado en P_FIRMA (para que el latido sepa
# que cambio sin depender de los minutos), las acciones para el vigia en
# P_ACCIONES (una por linea "clave|texto") y el detalle en P_DETALLE.
parte_calcular() {
  local id="$1"
  local reg; reg="$(registro_de "$id")"
  local reg_roto
  reg_roto="$(validar_registro "$reg" 2>/dev/null)" \
    || { echo "estado: registro fuera de contrato: $id $(printf '%s' "$reg_roto" | tr '\n' ' ')" >&2; return 1; }
  local ahora; ahora="$(corr_ahora)"
  local estado inicio tb vigia ses
  estado="$(json_campo "$reg" estado)"
  inicio="$(json_campo "$reg" inicio)"
  tb="$(json_campo "$reg" timebox_horas)"
  [ -n "$tb" ] || tb=6
  vigia="$(json_campo "$reg" vigia)"
  local iep; iep="$(iso_a_epoch "$inicio")"; [ -n "$iep" ] || iep="$ahora"

  # Espejo del progreso: N de M partes. Lo que no se puede leer no se inventa:
  # sin espejo legible, cero de cero.
  local nav=0 m=0
  if [ -f "$CORRIDA_STATE/$id/progress.json" ]; then
    read -r nav m <<EOF
$(PROG="$CORRIDA_STATE/$id/progress.json" python3 -c "
import json,os
try:
  d=json.load(open(os.environ['PROG']))
except Exception:
  print(0,0); raise SystemExit
if d.get('schema')!='runbook-progress.v1':
  print(0,0); raise SystemExit
cs=d.get('carriles') or []
tot=sum(len(c.get('tareas') or []) for c in cs)
hechas=sum(len(c.get('tareas') or []) for c in cs if c.get('estado')=='mergeado')
print(hechas,tot)" 2>/dev/null)
EOF
  fi

  if [ "$estado" = "cerrada" ]; then
    P_ETIQ="CERRADA"
    P_AVANCE="todas las partes terminadas"
    P_CAMBIO="la corrida cerro y no queda trabajo en curso"
    P_SIGUE="no queda nada por hacer"
    P_NECESITO="nada"
    P_FIRMA="cerrada"
    P_ACCIONES=""
    P_DETALLE="corrida $id cerrada desde $inicio, vigia $vigia
cerrada: nada que vigilar"
    return 0
  fi

  # Cada sesion: viva o muerta, contrato, dialogo (y si la politica lo cubre),
  # quietud de 30 min sin haber terminado. Estados discretos por prioridad.
  local nombres="" n rol cli ses_st contrato panel pan_limp
  local trabajando=0 det="" fir_ses="" acc=""
  local n_dlg_joven=0 n_dlg_pedir=0 n_callada=0 n_listo=0 n_atorada=0 n_muerta=0 n_muerta_lead=0
  local quieta_primera="" desde_pedir="" desde_dialogo=""
  nombres="$(CORR_REG="$reg" python3 -c "
import json,os
print(chr(10).join('%s|%s|%s'%(s.get('nombre',''),s.get('rol') or '',s.get('cli','')) for s in json.load(open(os.environ['CORR_REG'])).get('sesiones',[])))" 2>/dev/null)"
  while IFS='|' read -r n rol cli; do
    [ -n "$n" ] || continue
    panel="$CORRIDA_STATE/$id/.panel.$n.$$"
    pan_limp="$panel.limpio"
    ses_st="muerta"; contrato=""; : > "$panel"
    if "$TMUX_BIN" has-session -t "=$n" >/dev/null 2>&1; then
      ses_st="trabajando"
      "$TMUX_BIN" capture-pane -p -t "=$n:" > "$panel" 2>/dev/null
    fi
    local aprob="" desde=0 quieta=0 edad=0 st_det="$ses_st"
    if [ "$ses_st" != "muerta" ]; then
      aprob="$(watch_campo "$n" approval)"
      desde="$(watch_campo "$n" approval_since)"; [ -n "$desde" ] || desde=0
      quieta="$(watch_campo "$n" since)"; [ -n "$quieta" ] || quieta=0
      [ "$desde" -gt 0 ] && edad=$(( ahora - desde ))
    fi
    case "$ses_st" in
      trabajando)
        contrato="$(contrato_de_panel "$panel")"
        case "$contrato" in
          LISTO\ *)
            ses_st="listo"; n_listo=$((n_listo+1))
            st_det="listo (contrato: $contrato)";;
          ATORADO\ *)
            ses_st="atorada"; n_atorada=$((n_atorada+1))
            st_det="atorada (contrato: $contrato)";;
          *)
            if [ -n "$aprob" ]; then
              if [ -z "$desde_dialogo" ] || [ "$desde" -lt "$desde_dialogo" ]; then
                desde_dialogo="$desde"
              fi
              if [ "$edad" -ge 600 ] || ! dialogo_cubierto "$reg" "$panel"; then
                ses_st="dialogo-pedir"; n_dlg_pedir=$((n_dlg_pedir+1))
                if [ -z "$desde_pedir" ] || [ "$desde" -lt "$desde_pedir" ]; then
                  desde_pedir="$desde"
                fi
                st_det="dialogo desde hace $(min_desde "$desde") min (la politica no lo cubre o ya espero demasiado)"
              else
                ses_st="dialogo-joven"; n_dlg_joven=$((n_dlg_joven+1))
                st_det="dialogo desde hace $(min_desde "$desde") min (cubierto por preaprobaciones)"
              fi
            elif [ "$quieta" -gt 0 ] && [ $(( ahora - quieta )) -ge 1800 ]; then
              ses_st="callada"; n_callada=$((n_callada+1))
              [ -n "$quieta_primera" ] || quieta_primera="$quieta"
              st_det="callada $(min_desde "$quieta") min con la pantalla quieta, sin contrato"
            else
              trabajando=$((trabajando+1))
            fi ;;
        esac ;;
      muerta)
        n_muerta=$((n_muerta+1))
        [ "$rol" = "lead" ] && n_muerta_lead=$((n_muerta_lead+1))
        st_det="muerta (sin sesion de tmux)";;
    esac
    fir_ses="$fir_ses$n:$ses_st,"
    det="$det
sesion $n ($rol, $cli): $st_det"
    if [ -s "$panel" ]; then
      panel_limpio "$panel" "$pan_limp"
      det="$det
$(sed 's/^/  /' "$pan_limp")"
    else
      det="$det
  (sin pantalla)"
    fi
    rm -f "$panel" "$pan_limp"
  done <<EOF
$nombres
EOF

  # Acciones para el vigia, segun loop 12.
  [ "$n_muerta_lead" -gt 0 ] \
    && acc="$acc
relanzar-lead|la sesion del lead murio: relanzar al lead en otro host (loop 12 y 9)"
  [ "$n_muerta" -gt "$n_muerta_lead" ] \
    && acc="$acc
relanzar|sesion de carril muerta: relanzar una vez con el mismo encargo; a la segunda, declarar atorado (loop 12)"
  [ "$n_callada" -gt 0 ] \
    && acc="$acc
relanzar|carril callado 30 min o mas sin terminar: relanzar una vez con el mismo encargo; a la segunda, declarar atorado (loop 12)"
  [ $((n_dlg_joven + n_dlg_pedir)) -gt 0 ] \
    && acc="$acc
contestar|dialogo esperando: contestar con la tabla de preaprobaciones; lo que no este en la tabla, rechazar y declarar (loop 12)"
  [ "$n_atorada" -gt 0 ] \
    && acc="$acc
declarar|carril atorado: declararlo y seguir con lo demas (loop 12)"
  [ "$n_listo" -gt 0 ] \
    && acc="$acc
recoger|carril con LISTO sin recoger: recoger lo terminado (loop 3)"

  # Etiqueta y frases, en palabras de usuario.
  if [ "$n_dlg_pedir" -gt 0 ]; then
    P_ETIQ="NECESITO TU RESPUESTA"
  elif [ "$n_muerta" -gt 0 ] || [ "$n_atorada" -gt 0 ] || [ "$n_callada" -gt 0 ] || [ "$n_dlg_joven" -gt 0 ]; then
    P_ETIQ="DETENIDA"
  else
    P_ETIQ="AVANZA"
  fi
  P_AVANCE="$nav de $m partes terminadas"

  if [ "$n_dlg_pedir" -gt 0 ]; then
    if [ $((n_dlg_pedir + n_dlg_joven)) -gt 1 ]; then
      P_CAMBIO="varios carriles esperan hace rato una decision tuya"
    else
      P_CAMBIO="un carril lleva $(min_desde "$desde_pedir") minutos esperando una decision tuya"
    fi
  elif [ "$n_dlg_joven" -gt 1 ]; then
    P_CAMBIO="$n_dlg_joven carriles se detuvieron a esperar una decision tuya"
  elif [ "$n_dlg_joven" -gt 0 ]; then
    P_CAMBIO="un carril se detuvo a esperar una decision tuya"
  elif [ "$n_muerta_lead" -gt 0 ]; then
    P_CAMBIO="la sesion que coordina la corrida dejo de existir"
  elif [ "$n_muerta" -gt 1 ]; then
    P_CAMBIO="las sesiones de $n_muerta carriles dejaron de existir"
  elif [ "$n_muerta" -gt 0 ]; then
    P_CAMBIO="la sesion de un carril dejo de existir"
  elif [ "$n_atorada" -gt 1 ]; then
    P_CAMBIO="$n_atorada carriles se declararon atorados"
  elif [ "$n_atorada" -gt 0 ]; then
    P_CAMBIO="un carril se declaro atorado"
  elif [ "$n_callada" -gt 1 ]; then
    P_CAMBIO="$n_callada carriles llevan $(min_desde "$quieta_primera") minutos sin actividad en su pantalla"
  elif [ "$n_callada" -gt 0 ]; then
    P_CAMBIO="un carril lleva $(min_desde "$quieta_primera") minutos sin actividad en su pantalla"
  elif [ "$n_listo" -gt 1 ]; then
    P_CAMBIO="$n_listo carriles terminaron su parte y aun no se recogen"
  elif [ "$n_listo" -gt 0 ]; then
    P_CAMBIO="un carril termino su parte y aun no se recoge"
  else
    P_CAMBIO="los carriles siguen trabajando sin contratiempos"
  fi

  # Ventana de trabajo: timebox desde el inicio; la espera de una decision pone
  # el reloj en pausa (se descuenta el tiempo esperando, no trabajando).
  local tseg restante h mm pausa_txt="" consumido
  tseg=$(( tb * 3600 ))
  restante=$(( tseg - (ahora - iep) ))
  if [ -n "$desde_dialogo" ] && [ "$desde_dialogo" -gt 0 ]; then
    consumido=$(( desde_dialogo - iep ))
    [ "$consumido" -lt 0 ] && consumido=0
    [ "$consumido" -gt "$tseg" ] && consumido="$tseg"
    restante=$(( tseg - consumido ))
    pausa_txt=" (en pausa por la espera)"
  fi
  h=$(( restante / 3600 )); mm=$(( (restante % 3600) / 60 ))
  local ventana
  if [ "$restante" -le 0 ]; then
    ventana="la ventana de trabajo se agoto"
  elif [ "$h" -gt 0 ]; then
    ventana="quedan $h horas y $mm minutos de ventana de trabajo$pausa_txt"
  else
    ventana="quedan $mm minutos de ventana de trabajo$pausa_txt"
  fi
  local en_marcha
  if [ "$trabajando" -gt 0 ]; then
    en_marcha="trabajan $trabajando sesiones"
  else
    en_marcha="ninguna sesion esta trabajando"
  fi
  prs_por_gh
  P_SIGUE="$en_marcha; $ventana; $GH_TXT"

  if [ "$n_dlg_pedir" -gt 0 ]; then
    local min_dlg; min_dlg="$(min_desde "$desde_pedir")"
    if [ "$n_dlg_pedir" -gt 1 ]; then
      P_NECESITO="$n_dlg_pedir carriles esperan desde hace $min_dlg minutos tu decision: con tu si siguen solos, con tu no se detienen ahi"
    else
      P_NECESITO="un carril espera desde hace $min_dlg minutos tu decision: con tu si sigue solo, con tu no se detiene ahi"
    fi
  elif [ "$n_dlg_joven" -gt 0 ]; then
    P_NECESITO="nada por ahora; si sigue esperando, te pregunto"
  else
    P_NECESITO="nada"
  fi

  P_FIRMA="e=$P_ETIQ|av=$nav/$m|pr=$GH_TXT|ses=$fir_ses"
  P_ACCIONES="${acc#"$LF"}"
  P_DETALLE="corrida $id $estado desde $inicio, vigia $vigia
${det#"$LF"}
$GH_TXT"
  return 0
}

corrida_estado() {
  local id="${1:-}"
  corrida_id_valido "$id" || { echo "estado: id invalido (solo letras, numeros, - y _): $id" >&2; return 2; }
  shift
  local solo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --solo-mensaje) solo=1; shift;;
      *) echo "estado: flag desconocido $1" >&2; return 2;;
    esac
  done
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "estado: sin registro: $id" >&2; return 1; }
  parte_calcular "$id" || return 1
  printf '[%s] Corrida, %s\nQue cambio: %s\nQue sigue: %s\nQue necesito de ti: %s\n' \
    "$P_ETIQ" "$P_AVANCE" "$P_CAMBIO" "$P_SIGUE" "$P_NECESITO"
  [ -n "$solo" ] && return 0
  printf -- '--- detalle (para el vigia; no va a David) ---\n%s\n' "$P_DETALLE"
  return 0
}
