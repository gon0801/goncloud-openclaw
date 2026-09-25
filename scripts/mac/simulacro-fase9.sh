#!/bin/bash
# scripts/mac/simulacro-fase9.sh — arnes del simulacro 9.9 (Fase 9). Completo:
# prerrequisitos, arranque, limpieza, --limpiar, --dry-run y el generador de
# evidencia. Los 7 casos corren de verdad: contrato LISTO + recoger; dialogo
# de confianza aceptado por politica; comando que escala a NECESITO TU
# RESPUESTA; reloj inyectado de 30 min sin actividad (DETENIDA + relanzar +
# runbook.progress.decide inmediato); kill-session de un carril y del lead
# con relanzamiento real (vigia -> system event -> "main"); corte de 30 min
# de runbook.progress.decide con reporte-confirmado. Los casos 4 y 7 miden
# con reloj inyectado; con --observar-avance (opcion A de David, ~35 min en
# vivo, SIN reloj falso) se suben a "observado real" si el cron avance-tareas
# aparece de verdad y su scratch confirma un reporte con messageId.
#
# Uso:
#   simulacro-fase9.sh [--ensayo] [--dry-run] [--salida <md>] [--tope-pared <s>]
#                       [--observar-avance <min>]
#   simulacro-fase9.sh --limpiar <id>
#
# Salida: 0 solo con 7/7 FUNCIONA; 1 si algun caso NO FUNCIONA o NO OBSERVADO;
# 2 NO APTO (no se lanzo nada: ni registro, ni sesion, ni tabla). --dry-run
# corre los prerrequisitos de verdad (son de solo lectura) y sale 0/2 sin
# abrir ninguna corrida.
#
# Variables inyectables. En vivo (sin --ensayo) OPENCLAW_BIN/TMUX_BIN/
# CORRIDA_STATE/WATCH_STATE_DIR con un valor DISTINTO de su default es NO
# APTO (protege una corrida real de un doble accidental). CORRIDA_BIN no esta
# en esa lista: el arnes vive en el checkout y siempre necesita poder apuntar
# a SU PROPIA copia de corrida.sh (o a la instalada) sin que eso cuente como
# "inyeccion" a rechazar.
#   OPENCLAW_BIN      def. $HOME/.openclaw/bin/openclaw
#   TMUX_BIN          def. tmux del PATH, si no /opt/homebrew/bin/tmux
#   CORRIDA_STATE     def. $HOME/.local/state/corridas
#   WATCH_STATE_DIR   def. $HOME/.local/state/tmux-activity-watch (STATE_DIR
#                     del vigia; solo se usa de verdad con --ensayo, que
#                     lanza una segunda instancia del vigia del checkout)
#   CORRIDA_BIN       def. $HOME/bin/corrida.sh (--ensayo: apunta al checkout)
# glm se resuelve por PATH (igual que lanzar-sesion): con --ensayo, quien
# invoca este arnes pone un "glm" de mentira delante en el PATH.
#
# Nota de diseno (PIEZA a): `corrida.sh preflight <id>` necesita un registro
# que TODAVIA NO EXISTE durante los prerrequisitos "vivos" (los que corren
# antes de abrir nada) — preflight.sh exige `-f $reg`. Se resuelve corriendo
# preflight justo DESPUES de abrir, como el ultimo portazo antes de declarar
# la corrida lista para casos: si preflight no da APTO, se limpia (cerrar +
# registro) igual que si un prerrequisito de antes hubiera fallado, y se sale
# NO APTO — ningun caso ni sesion del simulacro llega a lanzarse.
set -u

AQUI="$(cd "$(dirname "$0")" && pwd)"
REPO_RAIZ="$(cd "$AQUI/../.." && pwd)"

# --- defaults y deteccion de inyeccion (antes de tocar nada) ---------------
DEF_OPENCLAW_BIN="$HOME/.openclaw/bin/openclaw"
def_tmux() { command -v tmux 2>/dev/null || echo /opt/homebrew/bin/tmux; }
DEF_TMUX_BIN="$(def_tmux)"
DEF_CORRIDA_STATE="$HOME/.local/state/corridas"
DEF_WATCH_STATE_DIR="$HOME/.local/state/tmux-activity-watch"

ORIG_OPENCLAW_BIN="${OPENCLAW_BIN-__sim9_sin_valor__}"
ORIG_TMUX_BIN="${TMUX_BIN-__sim9_sin_valor__}"
ORIG_CORRIDA_STATE="${CORRIDA_STATE-__sim9_sin_valor__}"
ORIG_WATCH_STATE_DIR="${WATCH_STATE_DIR-__sim9_sin_valor__}"

OPENCLAW_BIN="${OPENCLAW_BIN:-$DEF_OPENCLAW_BIN}"
TMUX_BIN="${TMUX_BIN:-$DEF_TMUX_BIN}"
CORRIDA_STATE="${CORRIDA_STATE:-$DEF_CORRIDA_STATE}"
WATCH_STATE_DIR="${WATCH_STATE_DIR:-$DEF_WATCH_STATE_DIR}"
CORRIDA_BIN="${CORRIDA_BIN:-$HOME/bin/corrida.sh}"
export OPENCLAW_BIN TMUX_BIN CORRIDA_STATE WATCH_STATE_DIR

# --- argumentos --------------------------------------------------------
ENSAYO=0
DRY_RUN=0
SALIDA=""
TOPE_PARED=570
TOPE_PARED_EXPLICITO=0
OBSERVAR_AVANCE=""
LIMPIAR_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ensayo) ENSAYO=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --salida) [ "$#" -ge 2 ] || { echo "simulacro-fase9: --salida sin valor" >&2; exit 2; }; SALIDA="$2"; shift 2;;
    --tope-pared) [ "$#" -ge 2 ] || { echo "simulacro-fase9: --tope-pared sin valor" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "simulacro-fase9: --tope-pared no es un numero de segundos: $2" >&2; exit 2;; esac
      TOPE_PARED="$2"; TOPE_PARED_EXPLICITO=1; shift 2;;
    --observar-avance) [ "$#" -ge 2 ] || { echo "simulacro-fase9: --observar-avance sin valor" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "simulacro-fase9: --observar-avance no es un numero de minutos: $2" >&2; exit 2;; esac
      OBSERVAR_AVANCE="$2"; shift 2;;
    --limpiar) [ "$#" -ge 2 ] || { echo "simulacro-fase9: --limpiar sin valor" >&2; exit 2; }; LIMPIAR_ID="$2"; shift 2;;
    *) echo "simulacro-fase9: flag desconocido: $1" >&2; exit 2;;
  esac
done

# --- topes por caso (inyectables; solo --ensayo los acorta) ----------------
SIM_TOPE_C1="${SIM_TOPE_C1:-180}"
SIM_TOPE_C2="${SIM_TOPE_C2:-90}"
SIM_TOPE_C3="${SIM_TOPE_C3:-150}"
SIM_TOPE_C4="${SIM_TOPE_C4:-60}"
SIM_TOPE_C5="${SIM_TOPE_C5:-180}"
SIM_TOPE_C6="${SIM_TOPE_C6:-240}"
# Segunda mirada tras un relanzamiento (casos 5/6), para confirmar que no
# hay un segundo relanzamiento indebido. No hace falta que sean los 60s
# reales: el vigia solo dispara "closed" UNA vez por sesion que desaparece
# (el .state se borra al mandar el evento, tmux-activity-watch.sh) — el
# margen es una comprobacion de sanidad, no lo que impide el doble disparo.
SIM_ESPERA_DOBLE="${SIM_ESPERA_DOBLE:-15}"
# Observacion extendida (pieza d): sondeo real cada 60s (opcion A, sin reloj
# falso); solo se acorta con --ensayo para probarla con topes cortos.
SIM_TOPE_OBS_POLL="${SIM_TOPE_OBS_POLL:-60}"
# Ventana minima que tiene que pasar de verdad (reloj real, nunca inyectado)
# antes de aceptar un scratch "reporte-confirmado" como el aviso real: sin
# esto, un scratch viejo que ya estuviera confirmado por otra razon se
# leeria como si el aviso hubiera salido en la propia observacion.
SIM_TOPE_OBS_VENTANA="${SIM_TOPE_OBS_VENTANA:-1800}"
# Tope del turno de la observacion a main (pieza d). Ese turno es sincrono:
# la CLI espera a que main TERMINE de trabajar antes de devolver control, y
# main tarda minutos (medido 2026-09-24: ~2 min; lanzo un subagente de
# ingenieria antes de seguir su seccion "Avisos de avance"). El tope general
# de red CORR_TOPE_RED=30 lo mataba a mitad del turno, el arnes leia "no se
# pudo mandar" aunque el turno SI llego, y los casos 4 y 7 quedaban en
# NO OBSERVADO sin haber medido nada. Tope propio, holgado para un turno con
# subagente, solo para este envio; el resto de las llamadas de red del arnes
# siguen con su tope corto.
SIM_TOPE_TURNO_MAIN="${SIM_TOPE_TURNO_MAIN:-300}"

# --tope-pared (CodeRabbit, PR #153): con --observar-avance, el reloj de
# pared tiene que alcanzar para los 7 casos Y para la observacion completa
# (que no acepta un aviso confirmado antes de SIM_TOPE_OBS_VENTANA segundos
# reales) — el default de 570s no alcanza ni de cerca para "opcion A" (~35
# min). Minimo = los casos secuenciales en su peor momento (1, el peor de
# 2/3 en paralelo, 4, el peor de 5/6 en paralelo — 7 es casi instantaneo) +
# los minutos de observacion pedidos + un margen para arranque/cierre.
if [ -n "$OBSERVAR_AVANCE" ]; then
  MAX_23="$SIM_TOPE_C2"; [ "$SIM_TOPE_C3" -gt "$MAX_23" ] && MAX_23="$SIM_TOPE_C3"
  MAX_56="$SIM_TOPE_C5"; [ "$SIM_TOPE_C6" -gt "$MAX_56" ] && MAX_56="$SIM_TOPE_C6"
  CASOS_TOPE_TOTAL=$((SIM_TOPE_C1 + MAX_23 + SIM_TOPE_C4 + MAX_56))
  MARGEN_OBS=120
  TOPE_MINIMO=$((CASOS_TOPE_TOTAL + OBSERVAR_AVANCE*60 + MARGEN_OBS))
  if [ "$TOPE_PARED_EXPLICITO" = "1" ] && [ "$TOPE_PARED" -lt "$TOPE_MINIMO" ]; then
    echo "simulacro-fase9: --tope-pared $TOPE_PARED es menor que lo que --observar-avance $OBSERVAR_AVANCE necesita (minimo ${TOPE_MINIMO}s = casos ${CASOS_TOPE_TOTAL}s + observacion $((OBSERVAR_AVANCE*60))s + margen ${MARGEN_OBS}s); no se abre nada" >&2
    exit 2
  fi
  [ "$TOPE_PARED" -lt "$TOPE_MINIMO" ] && TOPE_PARED="$TOPE_MINIMO"
fi

# --- lib.sh/estado.sh de la corrida que se va a usar (checkout o instalada) -
CORRIDA_DIR="$(cd "$(dirname "$CORRIDA_BIN")" 2>/dev/null && pwd)/corrida"
[ -f "$CORRIDA_DIR/lib.sh" ] || { echo "simulacro-fase9: no encuentro $CORRIDA_DIR/lib.sh (CORRIDA_BIN=$CORRIDA_BIN)" >&2; exit 2; }
. "$CORRIDA_DIR/lib.sh"
# estado.sh solo define funciones (parte_calcular, corr_ahora...); se
# sourcea para leer P_ACCIONES directo (el caso 4 necesita confirmar que la
# accion interna es "relanzar", y corrida.sh estado nunca imprime P_ACCIONES
# — eso solo lo consume corrida.sh latido).
[ -f "$CORRIDA_DIR/estado.sh" ] || { echo "simulacro-fase9: no encuentro $CORRIDA_DIR/estado.sh" >&2; exit 2; }
. "$CORRIDA_DIR/estado.sh"

RUNBOOK="$REPO_RAIZ/scripts/tests/fixtures/corrida/runbook-simulacro.md"
CANAL_DE="cuotas-proveedores"

# --- rutas que nunca deben casar [0-9][smh] (Hallazgo del diseno: --------
# approval_tail/resp_cola borran ese patron de las rutas que escanean) ------
ruta_sin_reloj() { # $1 ruta; 0 = segura
  case "$1" in *[0-9][smh]*) return 1;; esac
  return 0
}

# ============================= limpieza (idempotente, sin rm -r) ===========
# Definida ANTES de --limpiar (que la llama de inmediato, sin abrir nada
# nuevo) y antes de arrancar nada mas. Un --dry-run PURO (sin --limpiar) no
# reserva el log: no va a limpiar nada de verdad, y con `set -u` un archivo
# que nadie necesita es una razon menos para que algo falle.
LIMPIEZA_LOG=""
if [ "$DRY_RUN" != "1" ] || [ -n "$LIMPIAR_ID" ]; then
  LIMPIEZA_LOG="$(mktemp)" || { echo "simulacro-fase9: sin mktemp para el log de limpieza" >&2; exit 2; }
fi
limpiar_corrida() { # $1 id; nunca falla el script: todo es best-effort y anotado
  local id="$1"
  corrida_id_valido "$id" || return 0
  local reg; reg="$(registro_de "$id")"
  local habia_registro=0 nombres_registro=""
  if [ -f "$reg" ]; then
    habia_registro=1
    # Los nombres se leen ANTES de cerrar: cerrar() ya retira las marcas
    # (OPENCLAW_WATCH/OPENCLAW_WATCH_RUN) de cada sesion del registro, asi que
    # el barrido por marca de mas abajo ya no las encontraria — el nombre de
    # sesion casi nunca contiene el id de la corrida (sim9-c1, no sim9-<id>-c1).
    nombres_registro="$(CORR_REG="$reg" python3 -c "
import json,os
try: d=json.load(open(os.environ['CORR_REG']))
except Exception: d={}
print(chr(10).join(s.get('nombre','') for s in d.get('sesiones',[]) if isinstance(s,dict) and s.get('nombre')))
" 2>/dev/null)"
    local estado; estado="$(json_campo "$reg" estado)"
    if [ "$estado" = "abierta" ]; then
      # Cerrar ANTES de matar sesiones: asi el vigia nunca ve un "closed" de
      # una corrida que ya se estaba yendo, y main no intenta relanzar nada.
      "$CORRIDA_BIN" cerrar "$id" >>"$LIMPIEZA_LOG" 2>&1
      echo "cerrar $id: $?" >>"$LIMPIEZA_LOG"
    fi
  else
    echo "sin registro para $id (nada que cerrar)" >>"$LIMPIEZA_LOG"
  fi
  if [ -n "$nombres_registro" ]; then
    local s
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      "$TMUX_BIN" kill-session -t "=$s" 2>/dev/null
      echo "kill-session $s (sesion del registro de $id)" >>"$LIMPIEZA_LOG"
    done <<EOF
$nombres_registro
EOF
  fi
  # Barrido adicional: TODA sesion viva marcada con este id (por nombre que lo
  # contenga, o por OPENCLAW_WATCH_RUN) — cubre huerfanas que nunca quedaron
  # en un registro legible (--limpiar tras un kill -9 a mitad del arranque).
  local sesiones
  sesiones="$("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null)" || sesiones=""
  if [ -n "$sesiones" ]; then
    local s marca
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      case "$s" in
        *"$id"*) "$TMUX_BIN" kill-session -t "=$s" 2>/dev/null; echo "kill-session $s (nombre)" >>"$LIMPIEZA_LOG"; continue;;
      esac
      marca="$("$TMUX_BIN" show-environment -t "=$s" OPENCLAW_WATCH_RUN 2>/dev/null)" || marca=""
      if [ "$marca" = "OPENCLAW_WATCH_RUN=$id" ]; then
        "$TMUX_BIN" kill-session -t "=$s" 2>/dev/null
        echo "kill-session $s (dueno=$id)" >>"$LIMPIEZA_LOG"
      fi
    done <<EOF
$sesiones
EOF
  fi
  # progress.set de cierre solo si de verdad hubo una corrida abierta: nada
  # que anunciar para un id que nunca llego a abrir (prerrequisito fallido).
  [ "$habia_registro" = "1" ] && progress_set_cierre "$id" >>"$LIMPIEZA_LOG" 2>&1
  # Los dirs de trabajo del caso (trabajo/<caso>) se QUEDAN a proposito (el
  # diseno los pide para inspeccion; nunca `rm -r`/`rm -rf` sobre ellos).
  return 0
}

# runbook.progress.set con cierre.at, best effort (una escritura fallida no
# detiene nada: es lo que dice el contrato v2 de progreso).
progress_set_cierre() {
  local id="$1" doc
  doc="$(mktemp)" || return 1
  SIM_ID="$id" SIM_RUNBOOK="$RUNBOOK" python3 -c "
import json,os,time
d={'schema':'runbook-progress.v1','runbook':os.environ['SIM_RUNBOOK'],'fase':'9',
'corrida':os.environ['SIM_ID'],'titulo':'Simulacro 9.9',
'siguiente_paso':'corrida de simulacro cerrada',
'carriles':[{'id':'S','nombre':'Simulacro','estado':'mergeado','ultimo_evento':
  {'at':time.strftime('%Y-%m-%dT%H:%M:%S%z'),'que':'cierre del arnes','situacion':None}}],
'cola':[],'eventos':[],
'cierre':{'at':time.strftime('%Y-%m-%dT%H:%M:%S%z'),'telegram_message_id':None,'resumen':'simulacro 9.9 cerrado'}}
open('$doc','w').write(json.dumps(d))
" 2>/dev/null || { rm -f "$doc"; return 1; }
  con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" gateway call runbook.progress.set --params "$(cat "$doc")" --timeout 30000 >/dev/null 2>&1
  local rc=$?
  rm -f "$doc"
  return $rc
}

# ============================= --limpiar ===================================
if [ -n "$LIMPIAR_ID" ]; then
  corrida_id_valido "$LIMPIAR_ID" || { echo "simulacro-fase9: id invalido: $LIMPIAR_ID" >&2; exit 2; }
  echo "limpiando $LIMPIAR_ID (repite lo que un trap habria hecho tras un kill -9)"
  limpiar_corrida "$LIMPIAR_ID"
  echo "limpieza de $LIMPIAR_ID terminada"
  exit 0
fi

# ============================= id de esta corrida ===========================
generar_id() {
  local base id n=0
  base="sim9-$(date +%Y%m%d-%H%M)"
  id="$base"
  while [ -e "$CORRIDA_STATE/$id/registro.json" ] || ! ruta_sin_reloj "$id"; do
    n=$((n+1)); id="$base-$n"
  done
  printf '%s\n' "$id"
}
SIM_ID="$(generar_id)"

LIMPIEZA_HECHA=0
VIGIA_PID=""
WATCHDOG_PID=""
limpieza_exit() {
  local rc=$?
  [ "$LIMPIEZA_HECHA" = "1" ] && exit "$rc"
  LIMPIEZA_HECHA=1
  limpiar_corrida "$SIM_ID"
  if [ "$ENSAYO" = "1" ] && [ -n "$VIGIA_PID" ]; then
    kill "$VIGIA_PID" 2>/dev/null
    wait "$VIGIA_PID" 2>/dev/null
  fi
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
  exit "$rc"
}
# --limpiar ya salio (exit 0) antes de llegar aqui, asi que a esta altura
# DRY_RUN=1 solo puede ser un --dry-run PURO: no abre ni lanza nada, no hay
# nada que limpiar, y el trap solo agregaria un `limpiar_corrida` de un id
# que nunca se abrio (ademas de LIMPIEZA_LOG, que aqui puede no existir).
if [ "$DRY_RUN" != "1" ]; then
  trap limpieza_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # --tope-pared, exigido (BRIEF): un reloj de pared que solo se imprimia y
  # nunca se aplicaba. Vencido el tope, termina el arnes por la via normal
  # (SIGTERM -> el trap de arriba -> limpieza_exit), nunca a la fuerza.
  # >/dev/null 2>&1 es obligatorio: sin redirigir sus propios descriptores,
  # este job de fondo hereda el stdout/stderr del arnes, y quien lo capture
  # con "$(...)" (la prueba, por ejemplo) queda esperando a que el WATCHDOG
  # tambien cierre esos descriptores — hasta el tope entero, aunque el
  # arnes ya haya terminado hace rato (medido: la bateria completa se colgaba
  # varios minutos por esto).
  if [ "$TOPE_PARED" -gt 0 ]; then
    ( sleep "$TOPE_PARED"; kill -TERM $$ 2>/dev/null ) >/dev/null 2>&1 &
    WATCHDOG_PID=$!
  fi
fi

# ============================= --ensayo: vigia doblada ======================
# Contradiccion real, resuelta aqui (documentada tambien en el reporte):
# corrida/preflight.sh trae SU PROPIO chequeo de vigia, con el patron
# 'bin/tmux-activity-watch.sh' escrito a fuego (no es inyectable). Si la
# instancia doblada de --ensayo corriera directo desde el checkout
# (.../scripts/mac/tmux-activity-watch.sh, sin "bin/" en la ruta), el pgrep
# de preflight NO la encontraria y preflight fallaria "vigilante no corre"
# aun con el vigia vivo. Se resuelve copiando el script del checkout a un
# "bin/" temporal antes de lanzarlo: el mismo patron 'bin/tmux-activity-watch.sh'
# encuentra tanto el prerrequisito propio del arnes como el de preflight.sh, y
# WATCH_INSTALADO apunta a esa copia para que la comprobacion de blob de
# preflight (contra origin/main) compare lo mismo que esta corriendo.
VIGIA_PATRON="bin/tmux-activity-watch.sh"
# --dry-run no lanza nada, ni siquiera el vigia doblado de --ensayo (la
# comprobacion de que "el vigia esta vivo" tambien se salta mas abajo, en
# prerrequisitos: nada lo levanto para que hubiera algo que encontrar).
if [ "$ENSAYO" = "1" ] && [ "$DRY_RUN" != "1" ]; then
  VIGIA_ENSAYO_DIR="$CORRIDA_STATE/.arnes-vigia-bin"
  mkdir -p "$VIGIA_ENSAYO_DIR/bin" || { echo "simulacro-fase9: no se pudo preparar el vigia doblado" >&2; exit 2; }
  cp "$REPO_RAIZ/scripts/mac/tmux-activity-watch.sh" "$VIGIA_ENSAYO_DIR/bin/tmux-activity-watch.sh" \
    && chmod +x "$VIGIA_ENSAYO_DIR/bin/tmux-activity-watch.sh" \
    || { echo "simulacro-fase9: no se pudo copiar el vigia doblado" >&2; exit 2; }
  export WATCH_INSTALADO="$VIGIA_ENSAYO_DIR/bin/tmux-activity-watch.sh"
  VIGIA_LOG="${SIM9_VIGIA_LOG:-$(mktemp)}"
  STATE_DIR="$WATCH_STATE_DIR" LOG_FILE="$VIGIA_LOG" TICK_SECS=1 \
    TMUX_BIN="$TMUX_BIN" OPENCLAW_BIN="$OPENCLAW_BIN" CORRIDA_BIN="$CORRIDA_BIN" \
    "$WATCH_INSTALADO" >>"$VIGIA_LOG" 2>&1 &
  VIGIA_PID=$!
  sleep 0.3
fi
# En vivo, VIGIA_LOG queda apuntando al log del vigia global real (nunca se
# lanza una segunda instancia): es de ahi de donde los casos 2 y 4 leen
# "dialog answered by policy" y las lineas SEND/tick.
[ "$ENSAYO" = "1" ] || VIGIA_LOG="$HOME/Library/Logs/tmux-activity-watch.log"

# ============================= prerrequisitos vivos =========================
RAZONES=""
razon() { RAZONES="$RAZONES
- $1"; }

prerrequisitos() {
  if [ "$ENSAYO" != "1" ]; then
    [ "$ORIG_OPENCLAW_BIN" = "__sim9_sin_valor__" ] || [ "$ORIG_OPENCLAW_BIN" = "$DEF_OPENCLAW_BIN" ] \
      || razon "OPENCLAW_BIN inyectado fuera de --ensayo"
    [ "$ORIG_TMUX_BIN" = "__sim9_sin_valor__" ] || [ "$ORIG_TMUX_BIN" = "$DEF_TMUX_BIN" ] \
      || razon "TMUX_BIN inyectado fuera de --ensayo"
    [ "$ORIG_CORRIDA_STATE" = "__sim9_sin_valor__" ] || [ "$ORIG_CORRIDA_STATE" = "$DEF_CORRIDA_STATE" ] \
      || razon "CORRIDA_STATE inyectado fuera de --ensayo"
    [ "$ORIG_WATCH_STATE_DIR" = "__sim9_sin_valor__" ] || [ "$ORIG_WATCH_STATE_DIR" = "$DEF_WATCH_STATE_DIR" ] \
      || razon "WATCH_STATE_DIR inyectado fuera de --ensayo"
  fi

  con_tope "$CORR_TOPE_RED" "$REPO_RAIZ/scripts/mac/instalar-mac.sh" --verificar >/dev/null 2>&1 \
    || razon "instalar-mac.sh --verificar no salio 0"

  if launchctl list 2>/dev/null | grep -F 'ai.goncloud.corrida-latido' >/dev/null 2>&1; then
    razon "el reloj viejo ai.goncloud.corrida-latido sigue cargado"
  fi

  # En vivo, esta comprobacion mira al vigia global real (siempre vale, sea o
  # no --dry-run). En --ensayo, el vigia lo lanza este mismo arnes un poco
  # mas arriba -- y --dry-run no lo lanza a proposito, asi que aqui no habria
  # nada que encontrar y no es una razon real para NO APTO.
  if [ "$ENSAYO" != "1" ] || [ "$DRY_RUN" != "1" ]; then
    pgrep -f "$VIGIA_PATRON" >/dev/null 2>&1 || razon "el vigia no esta vivo ($VIGIA_PATRON)"
  fi

  command -v glm >/dev/null 2>&1 || razon "glm no esta en el PATH"

  con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" gateway call runbook.progress.list --params '{}' --timeout 30000 >/dev/null 2>&1 \
    || razon "runbook.progress.list no respondio"

  local dest; dest="$(cron_dest_de "$CANAL_DE")"
  case "$dest" in
    ILEGIBLE) razon "abrir no resuelve destino: lista de crons ilegible";;
    AMBIGUO) razon "abrir no resuelve destino: $CANAL_DE tiene destinos ambiguos";;
    '') razon "abrir no resuelve destino: $CANAL_DE sin destino";;
  esac

  local sesiones
  sesiones="$("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null)" || sesiones=""
  printf '%s\n' "$sesiones" | grep -qE '^sim9-' && razon "ya hay una sesion sim9-* viva"

  [ -z "$RAZONES" ]
}

no_apto() {
  printf 'NO APTO%s\n' "$RAZONES" >&2
  exit 2
}

prerrequisitos || no_apto

# --dry-run: los prerrequisitos SI se corrieron de verdad (son de solo
# lectura: nada se abre, nada se lanza) — esto dice que iba a hacer el resto,
# sin tocarlo. Pensado para que David o el lead lo corran antes de una
# corrida real y sepan exactamente que se va a crear.
if [ "$DRY_RUN" = "1" ]; then
  [ -n "$SALIDA" ] || SALIDA="$REPO_RAIZ/docs/evidence/fase9-simulacro-$(date +%Y-%m-%d).md"
  echo "DRY-RUN: prerrequisitos APTO (nada se toco todavia)"
  echo "  id de la corrida: $SIM_ID"
  echo "  runbook: $RUNBOOK"
  echo "  canal: $CANAL_DE (su destino ya se resolvio en los prerrequisitos; nunca se imprime)"
  echo "  tabla de modos que generaria: $CORRIDA_STATE/$SIM_ID/cli-modos.tsv (filas tui-falso -> sim9-tui-falso, glm -> glm)"
  echo "  abriria con: corrida.sh abrir $SIM_ID --runbook $RUNBOOK --vigia claw --cli-modos <tabla> --simulacro"
  echo "  encenderia: $CORRIDA_STATE/$SIM_ID/responder.on"
  echo "  reloj global (tope de pared efectivo): ${TOPE_PARED}s"
  echo "  casos que correria (con su tope): 1 (${SIM_TOPE_C1}s) | 2 (${SIM_TOPE_C2}s) y 3 (${SIM_TOPE_C3}s) en paralelo | 4 (${SIM_TOPE_C4}s) | 5 (${SIM_TOPE_C5}s) y 6 (${SIM_TOPE_C6}s) en paralelo | 7"
  if [ -n "$OBSERVAR_AVANCE" ]; then
    echo "  observacion extendida: SI, ${OBSERVAR_AVANCE} min en vivo (sin reloj falso) — manda un turno normal a main y sondea cada ${SIM_TOPE_OBS_POLL}s"
  else
    echo "  observacion extendida: no pedida (usa --observar-avance <min> para pedirla)"
  fi
  echo "  al terminar (o si algo falla a medio camino): cerraria la corrida $SIM_ID y mataria sus sesiones sim9-*"
  echo "  evidencia que escribiria: $SALIDA"
  echo "DRY-RUN: nada de esto se ejecuto"
  exit 0
fi

# ============================= arranque =====================================
DIR_SIM="$CORRIDA_STATE/$SIM_ID"
generar_tabla() {
  mkdir -p "$DIR_SIM/bin" && chmod 700 "$DIR_SIM" "$DIR_SIM/bin" || return 1
  cp "$REPO_RAIZ/scripts/tests/fixtures/tui-falso.sh" "$DIR_SIM/bin/sim9-tui-falso" \
    && chmod +x "$DIR_SIM/bin/sim9-tui-falso" || return 1
  {
    printf 'tui-falso\tsim9-tui-falso\t\tTUI-FALSO\tunknown\tEnter\tEscape\n'
    printf 'glm\tglm\t--mode yolo\tyolo\t/mode yolo\tunknown\tunknown\n'
  } > "$DIR_SIM/cli-modos.tsv" || return 1
  TABLA="$DIR_SIM/cli-modos.tsv"
}

ARR_RAZON=""
arrancar() {
  # El guardian [0-9][smh] se aplica al id (generar_id, ya verificado) y a
  # cada nombre de dir de trabajo QUE EL ARNES ELIGE (trabajo/<caso>, piezas
  # b-e); no al prefijo ambiental de CORRIDA_STATE, que el arnes no controla
  # y puede traer digitos y letras sueltas por pura coincidencia (medido con
  # un mktemp -d real: rechazaba corridas sanas por su propio directorio
  # temporal, no por nada que el arnes hubiera generado).
  generar_tabla || { ARR_RAZON="no se pudo generar la tabla de modos"; return 1; }
  export PATH="$DIR_SIM/bin:$PATH"
  local salida
  salida="$("$CORRIDA_BIN" abrir "$SIM_ID" --runbook "$RUNBOOK" --vigia claw --cli-modos "$TABLA" --simulacro 2>&1)"
  if [ "$?" -ne 0 ]; then
    ARR_RAZON="abrir fallo: $salida"
    return 1
  fi
  # SIM9_SIN_RESPONDER es solo para --ensayo (probar que un responder apagado
  # deja los casos de dialogo en NO FUNCIONA, tal como pasaria de verdad): en
  # vivo el arnes SIEMPRE enciende responder.on.
  if [ "$ENSAYO" != "1" ] || [ "${SIM9_SIN_RESPONDER:-0}" != "1" ]; then
    touch "$DIR_SIM/responder.on" || { ARR_RAZON="no se pudo encender responder.on"; return 1; }
  fi
  SIM_PROGRESS_SET_OK=1
  progress_set_arranque "$SIM_ID" || SIM_PROGRESS_SET_OK=0
  return 0
}

progress_set_arranque() {
  local id="$1" doc
  doc="$(mktemp)" || return 1
  SIM_ID="$id" SIM_RUNBOOK="$RUNBOOK" python3 -c "
import json,os,time
now=time.strftime('%Y-%m-%dT%H:%M:%S%z')
d={'schema':'runbook-progress.v1','runbook':os.environ['SIM_RUNBOOK'],'fase':'9',
'corrida':os.environ['SIM_ID'],'titulo':'Simulacro 9.9',
'lead':{'agente':'arnes-simulacro','inicio':now,'actualizado':now},
'atencion_requerida':{'necesita':False,'motivo':None,'desde':None},
'siguiente_paso':'corriendo los 7 casos del simulacro',
'carriles':[{'id':'S','nombre':'Simulacro','repo':None,'rama':None,'tareas':['9.9'],
  'estado':'implementando','paso_loop':None,'ronda':1,'pr':None,'head':None,
  'approve_lead':None,'ci':'sin-ci','coderabbit':'sin-cuota','residuales':[],
  'detenido_por':None,'ultimo_evento':{'at':now,'que':'arranque del arnes','situacion':None}}],
'cola':[],'eventos':[],'cierre':{'at':None,'telegram_message_id':None,'resumen':None}}
open('$doc','w').write(json.dumps(d))
" 2>/dev/null || { rm -f "$doc"; return 1; }
  con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" gateway call runbook.progress.set --params "$(cat "$doc")" --timeout 30000 >/dev/null 2>&1
  local rc=$?
  rm -f "$doc"
  return $rc
}

arrancar || { RAZONES="
- $ARR_RAZON"; no_apto; }

# El ultimo portazo: preflight sobre el registro recien abierto. Si no da
# APTO, se limpia igual que un prerrequisito fallido y se sale NO APTO —
# ningun caso ni sesion del simulacro llego a lanzarse (ver nota de diseno
# arriba).
PF_SALIDA="$("$CORRIDA_BIN" preflight "$SIM_ID" 2>&1)"
if ! printf '%s\n' "$PF_SALIDA" | head -1 | grep -q '^APTO'; then
  RAZONES="
- corrida.sh preflight no dio APTO:
$(printf '%s' "$PF_SALIDA" | sed 's/^/  /')"
  no_apto
fi

echo "arrancada $SIM_ID"

# ============================= casos =========================================
# Las piezas c-e llenan lo que falta (4-7). Cada caso escribe su resultado en
# un archivo de texto de 7 lineas bajo casos/<n>.txt (escribir_caso/leer_caso):
# asi los casos 2 y 3, que corren en paralelo como procesos hijos, pueden
# reportar su resultado sin depender de variables compartidas entre shells.
CASOS_NOMBRE="1|contrato LISTO 0000000 y recoger|2|dialogo de confianza aceptado por politica|3|comando que escala y NECESITA TU RESPUESTA|4|reloj inyectado: 30 min sin actividad|5|kill-session de un carril y relanzamiento|6|kill-session del lead y relanzamiento|7|corte de 30 min con reporte-confirmado"

escribir_caso() { # $1 numero; $2 resultado $3 detalle $4 hora_evento $5 hora_mensaje $6 msg_id $7 observable $8 simulado
  local n="$1"; shift
  mkdir -p "$DIR_SIM/casos" 2>/dev/null
  # leer_caso lee por NUMERO DE LINEA fijo: un campo con saltos de linea
  # propios (p.ej. la salida de lanzar-sesion cuando falla, o un traceback de
  # python de registro_escribir) correria los campos siguientes. Se
  # aplastan a espacios ANTES de guardar -- el escape de Markdown (| y \)
  # queda para tabla_casos, solo al momento de imprimir.
  local c
  for c in "$1" "$2" "$3" "$4" "$5" "$6" "$7"; do
    printf '%s\n' "$(printf '%s' "$c" | tr '\n\r' '  ')"
  done > "$DIR_SIM/casos/$n.txt"
}
leer_caso() { # $1 numero -> llena CASO_RESULTADO..CASO_SIMULADO
  local n="$1"
  local f="$DIR_SIM/casos/$n.txt"
  if [ -f "$f" ]; then
    CASO_RESULTADO="$(sed -n '1p' "$f")"
    CASO_DETALLE="$(sed -n '2p' "$f")"
    CASO_HORA_EVENTO="$(sed -n '3p' "$f")"
    CASO_HORA_MENSAJE="$(sed -n '4p' "$f")"
    CASO_MSG_ID="$(sed -n '5p' "$f")"
    CASO_OBSERVABLE="$(sed -n '6p' "$f")"
    CASO_SIMULADO="$(sed -n '7p' "$f")"
  else
    CASO_RESULTADO="NO OBSERVADO"; CASO_DETALLE="pendiente de implementar (pieza c-e)"
    CASO_HORA_EVENTO="pendiente"; CASO_HORA_MENSAJE="pendiente"; CASO_MSG_ID="pendiente"
    CASO_OBSERVABLE="pendiente"; CASO_SIMULADO="pendiente"
  fi
}

# Cero teclas de humano en cada sondeo: si alguien se conecto a la sesion
# mientras el arnes esperaba, el caso no puede declararse FUNCIONA por su
# cuenta (una tecla de persona pudo haber sido la que lo resolvio).
sin_clientes_humanos() { # $1 sesion; 0 = nadie conectado
  ! "$TMUX_BIN" list-clients -t "=$1" 2>/dev/null | grep -q .
}

# ---------- caso 1: contrato LISTO 0000000 y accion recoger -----------------
correr_caso1() {
  local dir="$DIR_SIM/trabajo/c1"
  ruta_sin_reloj "trabajo/c1" && mkdir -p "$dir" || {
    escribir_caso 1 "NO FUNCIONA" "no se pudo crear el directorio de trabajo" "" "" "" "" ""; return; }
  local encargo; encargo="$(mktemp)" || { escribir_caso 1 "NO FUNCIONA" "sin mktemp para el encargo" "" "" "" "" ""; return; }
  printf 'responde solo la linea LISTO 0000000\n' > "$encargo"
  local salida rc=0
  salida="$("$CORRIDA_BIN" lanzar-sesion "$SIM_ID" carril glm "$dir" --nombre sim9-c1 --encargo "$encargo" 2>&1)" || rc=1
  rm -f "$encargo"
  local simulado="lanzar-sesion carril glm <trabajo/c1> --encargo 'responde solo la linea LISTO 0000000'; corrida.sh estado cada 5s"
  if [ "$rc" -ne 0 ]; then
    escribir_caso 1 "NO FUNCIONA" "lanzar-sesion no dio rc 0 (la barra + el Enter del encargo no se confirmaron): $salida" "" "" "" "" "$simulado"
    return
  fi
  local tope="$SIM_TOPE_C1" ini=$SECONDS estado_txt hora_evento=""
  while [ "$((SECONDS-ini))" -lt "$tope" ]; do
    if ! sin_clientes_humanos sim9-c1; then
      escribir_caso 1 "NO FUNCIONA" "un cliente humano se conecto a sim9-c1 a mitad del sondeo" "" "" "" "" "$simulado"
      return
    fi
    estado_txt="$("$CORRIDA_BIN" estado "$SIM_ID" 2>&1)"
    if printf '%s' "$estado_txt" | grep -qF 'listo (contrato: LISTO 0000000)' \
      && printf '%s' "$estado_txt" | grep -qi 'recoge'; then
      hora_evento="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      break
    fi
    sleep 5
  done
  if [ -z "$hora_evento" ]; then
    escribir_caso 1 "NO FUNCIONA" "no se vio 'listo (contrato: LISTO 0000000)' + accion recoger en ${tope}s" "" "" "" "" "$simulado"
    return
  fi
  local avanza; avanza="$(tail -n1 "$DIR_SIM/eventos-seguimiento.jsonl" 2>/dev/null)"
  [ -n "$avanza" ] || avanza="(eventos-seguimiento.jsonl vacio todavia)"
  escribir_caso 1 "FUNCIONA" "" "$hora_evento" "no aplica: sin mensaje por diseno" "no aplica: sin mensaje por diseno" \
    "corrida.sh estado: 'listo (contrato: LISTO 0000000)' y 'aun no se recoge'; linea AVANZA en eventos-seguimiento.jsonl: $avanza" \
    "$simulado"
}

# ---------- caso 2: dialogo de confianza aceptado por politica --------------
correr_caso2() {
  local dir="$DIR_SIM/trabajo/c2" simulado="sim9-t2 (sim9-tui-falso) con dialogo de confianza de carpeta + al-aceptar.txt listo"
  ruta_sin_reloj "trabajo/c2" && mkdir -p "$dir" || {
    escribir_caso 2 "NO FUNCIONA" "no se pudo crear el directorio de trabajo" "" "" "" "" ""; return; }
  local salida rc=0
  salida="$("$CORRIDA_BIN" lanzar-sesion "$SIM_ID" carril tui-falso "$dir" --nombre sim9-t2 2>&1)" || rc=1
  if [ "$rc" -ne 0 ]; then
    escribir_caso 2 "NO FUNCIONA" "lanzar-sesion no dio rc 0: $salida" "" "" "" "" "$simulado"
    return
  fi
  printf 'confiado: la carpeta ya se acepto\n' > "$dir/al-aceptar.txt"
  printf 'Do you trust this folder? %s\nEnter to confirm . Esc to cancel\n' "$dir" > "$dir/pantalla.txt"
  local t0; t0="$(date +%s)"
  local t0_iso; t0_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tope="$SIM_TOPE_C2" ini=$SECONDS ok=0
  while [ "$((SECONDS-ini))" -lt "$tope" ]; do
    if ! sin_clientes_humanos sim9-t2; then
      escribir_caso 2 "NO FUNCIONA" "un cliente humano se conecto a sim9-t2 a mitad del sondeo" "$t0_iso" "" "" "" "$simulado"
      return
    fi
    if caso2_confirmar "$t0"; then ok=1; break; fi
    sleep 2
  done
  if [ "$ok" -eq 1 ]; then
    escribir_caso 2 "FUNCIONA" "" "$t0_iso" "no aplica: sin mensaje por diseno" "no aplica: sin mensaje por diseno" \
      "decisiones.jsonl {clase:confianza, decision:acepta}; $VIGIA_LOG trae 'dialog answered by policy: sim9-t2'; pantalla de sim9-t2 paso a al-aceptar.txt" \
      "$simulado"
  else
    escribir_caso 2 "NO FUNCIONA" "en ${tope}s no se vio la decision acepta + el log del vigia + la pantalla cambiada (ts-T0<60 exigido)" \
      "$t0_iso" "" "" "" "$simulado"
  fi
}
caso2_confirmar() { # $1 t0 epoch; 0 = decisiones.jsonl + log del vigia + pantalla, los tres
  local t0="$1"
  DEC="$DIR_SIM/decisiones.jsonl" T0="$t0" python3 -c "
import json,os
try: lineas=open(os.environ['DEC']).read().splitlines()
except Exception: raise SystemExit(1)
t0=int(os.environ['T0'])
for l in lineas:
  try: d=json.loads(l)
  except Exception: continue
  if d.get('sesion')!='sim9-t2': continue
  if d.get('clase')=='confianza' and d.get('decision')=='acepta':
    ts=d.get('ts')
    if isinstance(ts,(int,float)) and not isinstance(ts,bool) and (ts-t0)<60:
      raise SystemExit(0)
raise SystemExit(1)
" 2>/dev/null || return 1
  grep -qF 'dialog answered by policy: sim9-t2' "$VIGIA_LOG" 2>/dev/null || return 1
  "$TMUX_BIN" capture-pane -p -t "=sim9-t2:" 2>/dev/null | grep -qF 'confiado: la carpeta ya se acepto' || return 1
  return 0
}

# ---------- caso 3: comando que escala y NECESITA TU RESPUESTA --------------
correr_caso3() {
  local dir="$DIR_SIM/trabajo/c3"
  local simulado="sim9-t3 (sim9-tui-falso) con 'Run this command? \$ ssh otra-maquina uptime', preaprobaciones vacias"
  ruta_sin_reloj "trabajo/c3" && mkdir -p "$dir" || {
    escribir_caso 3 "NO FUNCIONA" "no se pudo crear el directorio de trabajo" "" "" "" "" ""; return; }
  local salida rc=0
  salida="$("$CORRIDA_BIN" lanzar-sesion "$SIM_ID" carril tui-falso "$dir" --nombre sim9-t3 2>&1)" || rc=1
  if [ "$rc" -ne 0 ]; then
    escribir_caso 3 "NO FUNCIONA" "lanzar-sesion no dio rc 0: $salida" "" "" "" "" "$simulado"
    return
  fi
  printf 'Run this command?\n$ ssh otra-maquina uptime\nEnter to confirm\n' > "$dir/pantalla.txt"
  local t0; t0="$(date +%s)"
  local t0_iso; t0_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tope="$SIM_TOPE_C3" ini=$SECONDS ok=0 humano=0
  while [ "$((SECONDS-ini))" -lt "$tope" ]; do
    if ! sin_clientes_humanos sim9-t3; then humano=1; break; fi
    if caso3_confirmar "$t0"; then ok=1; break; fi
    sleep 2
  done
  # Resolver reescribiendo pantalla (no teclas): la corrida no se queda
  # esperando una decision que el arnes ya observo (o dejo de esperar).
  printf 'resuelto por el arnes (simulacro)\n' > "$dir/pantalla.txt"
  if [ "$humano" -eq 1 ]; then
    escribir_caso 3 "NO FUNCIONA" "un cliente humano se conecto a sim9-t3 a mitad del sondeo" "$t0_iso" "" "" "" "$simulado"
  elif [ "$ok" -eq 1 ]; then
    local info hora_msg msg_id
    info="$(caso3_msg_info)"
    hora_msg="$(printf '%s\n' "$info" | sed -n '1p')"
    msg_id="$(printf '%s\n' "$info" | sed -n '2p')"
    escribir_caso 3 "FUNCIONA" "" "$t0_iso" "$hora_msg" "$msg_id" \
      "decisiones.jsonl {clase:comando, decision:escala, enviado:true}; mensajes.jsonl NECESITO TU RESPUESTA ok:true con message_id, texto con el contrato de seguimiento.v1 y el prefijo [SIMULACRO] (lo garantiza corrida_mensaje, commit 9.9.1)" \
      "$simulado"
  else
    escribir_caso 3 "NO FUNCIONA" "en ${tope}s no se vio la escalada + el mensaje NECESITO TU RESPUESTA con message_id (at-T0<120 exigido)" \
      "$t0_iso" "" "" "" "$simulado"
  fi
}
caso3_confirmar() { # $1 t0 epoch; 0 = escalo Y el mensaje salio con id a tiempo
  local t0="$1"
  DEC="$DIR_SIM/decisiones.jsonl" MSG="$DIR_SIM/mensajes.jsonl" T0="$t0" python3 -c "
import json,os
t0=int(os.environ['T0'])
esc=False
try:
  for l in open(os.environ['DEC']).read().splitlines():
    try: d=json.loads(l)
    except Exception: continue
    if d.get('sesion')=='sim9-t3' and d.get('clase')=='comando' and d.get('decision')=='escala' and d.get('enviado') is True:
      esc=True; break
except Exception:
  pass
if not esc: raise SystemExit(1)
ok=False
try:
  for l in open(os.environ['MSG']).read().splitlines():
    try: d=json.loads(l)
    except Exception: continue
    if d.get('etiqueta')!='NECESITO TU RESPUESTA' or not d.get('ok'): continue
    if d.get('message_id') is None: continue
    at=d.get('at')
    if not isinstance(at,(int,float)) or isinstance(at,bool): continue
    if (at-t0)>=120: continue
    ok=True
except Exception:
  pass
raise SystemExit(0 if ok else 1)
" 2>/dev/null
}
caso3_msg_info() { # -> dos lineas: hora ISO, message_id (de la ultima fila que casa)
  MSG="$DIR_SIM/mensajes.jsonl" python3 -c "
import json,os,datetime
try: lineas=open(os.environ['MSG']).read().splitlines()
except Exception: lineas=[]
ult=None
for l in lineas:
  try: d=json.loads(l)
  except Exception: continue
  if d.get('etiqueta')=='NECESITO TU RESPUESTA' and d.get('ok') and d.get('message_id') is not None:
    ult=d
if ult:
  at=ult.get('at')
  try: iso=datetime.datetime.utcfromtimestamp(float(at)).strftime('%Y-%m-%dT%H:%M:%SZ')
  except Exception: iso='desconocida'
  print(iso); print(ult.get('message_id'))
else:
  print('desconocida'); print('desconocido')
"
}

# ---------- caso 4: reloj inyectado, 30 min sin actividad -------------------
# El reloj se inyecta en corrida.sh estado (CORR_AHORA); no hace falta
# esperar 30 minutos de verdad, solo que el vigia deje una vez su .state con
# "since" — de ahi sale S y CORR_AHORA=S+1800 simula el resto.
caso4_decide() { # $1 ahora $2 texto del inmediato DETENIDA -> JSON de decidirSeguimiento
  local ahora="$1" texto="$2"
  CASO4_AHORA="$ahora" CASO4_TEXTO="$texto" python3 -c "
import json,os
d={'modo':'tick','ahora':int(os.environ['CASO4_AHORA']),
'estado':{'schema':'seguimiento-clock.v1','corte':{'kind':'reporte-confirmado','ultimoReporteConfirmado':int(os.environ['CASO4_AHORA'])},'ultimoEstado':'','ultimoInmediato':None,'messageId':None,'trabajosActivos':[]},
'inmediato':{'tipo':'DETENIDA','texto':os.environ['CASO4_TEXTO']}}
print(json.dumps(d))
" | con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" gateway call runbook.progress.decide --params "$(cat)" --timeout 30000 2>/dev/null
}
caso4_accion_relanzar() { # $1 ahora; 0 = P_ACCIONES trae "relanzar|..."
  ( export CORR_AHORA="$1"; parte_calcular "$SIM_ID" >/dev/null 2>&1 \
    && printf '%s\n' "$P_ACCIONES" | grep -q '^relanzar|' )
}
# El detalle POR SESION (P_DETALLE, via parte_calcular) en vez del texto
# agregado de --solo-mensaje: con las sesiones de los casos 1-3 todavia
# vivas, un "ahora" inyectado muy adelante (S+1799/1800) tambien las puede
# ver "calladas" a ELLAS (comparten el mismo reloj artificial) — el texto
# agregado ("un carril lleva..." vs "N carriles llevan...") deja de ser
# discriminante. La linea propia de sim9-t4 en el detalle no tiene ese
# problema: nombra la sesion.
caso4_sesion_callada() { # $1 ahora; 0 = la linea de sim9-t4 dice "callada"
  ( export CORR_AHORA="$1"; parte_calcular "$SIM_ID" >/dev/null 2>&1 \
    && printf '%s\n' "$P_DETALLE" | grep -qE '^sesion sim9-t4 \([^)]*\): callada' )
}
correr_caso4() {
  local dir="$DIR_SIM/trabajo/c4"
  local simulado="sim9-t4 callado 30 min (reloj inyectado en corrida.sh estado); runbook.progress.decide con inmediato DETENIDA sintetico"
  ruta_sin_reloj "trabajo/c4" && mkdir -p "$dir" || {
    escribir_caso 4 "NO FUNCIONA" "no se pudo crear el directorio de trabajo" "" "" "" "" ""; return; }
  printf 'trabajando en la parte 1 de 1\n' > "$dir/pantalla.txt"
  local salida rc=0
  salida="$("$CORRIDA_BIN" lanzar-sesion "$SIM_ID" carril tui-falso "$dir" --nombre sim9-t4 2>&1)" || rc=1
  if [ "$rc" -ne 0 ]; then
    escribir_caso 4 "NO FUNCIONA" "lanzar-sesion no dio rc 0: $salida" "" "" "" "" "$simulado"
    return
  fi
  # "since" se toma solo cuando dos lecturas seguidas, con un respiro entre
  # ellas, coinciden: la primera vez que el vigia ve la sesion usa su propio
  # reloj de actividad (window_activity), que en --ensayo (TICK_SECS=1) puede
  # correr una vuelta mas antes de asentarse en el hash de pantalla estable.
  local tope="$SIM_TOPE_C4" ini=$SECONDS s="" s2=""
  while [ "$((SECONDS-ini))" -lt "$tope" ]; do
    s="$(awk -F= '$1=="since"{print $2}' "$WATCH_STATE_DIR/sim9-t4.state" 2>/dev/null)"
    if [ -n "$s" ]; then
      sleep 2
      s2="$(awk -F= '$1=="since"{print $2}' "$WATCH_STATE_DIR/sim9-t4.state" 2>/dev/null)"
      [ "$s2" = "$s" ] && break
      s=""
    fi
    sleep 1
  done
  local t0_iso; t0_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -z "$s" ]; then
    escribir_caso 4 "NO FUNCIONA" "el vigia nunca asento un since= estable para sim9-t4 en ${tope}s" "$t0_iso" "" "" "" "$simulado"
    return
  fi
  if caso4_sesion_callada "$((s+1799))"; then
    escribir_caso 4 "NO FUNCIONA" "el control negativo (S+1799) ya mostro sim9-t4 callada" "$t0_iso" "" "" "" "$simulado"
    return
  fi
  local pos; pos="$(CORR_AHORA=$((s+1800)) "$CORRIDA_BIN" estado "$SIM_ID" --solo-mensaje 2>&1)"
  if ! printf '%s\n' "$pos" | head -1 | grep -q '^\[DETENIDA\]'; then
    escribir_caso 4 "NO FUNCIONA" "S+1800 no dio [DETENIDA]: $(printf '%s' "$pos" | tr '\n' ' ')" "$t0_iso" "" "" "" "$simulado"
    return
  fi
  if ! caso4_sesion_callada "$((s+1800))"; then
    escribir_caso 4 "NO FUNCIONA" "S+1800 no mostro sim9-t4 callada en el detalle" "$t0_iso" "" "" "" "$simulado"
    return
  fi
  if ! caso4_accion_relanzar "$((s+1800))"; then
    escribir_caso 4 "NO FUNCIONA" "S+1800 no calculo internamente la accion 'relanzar'" "$t0_iso" "" "" "" "$simulado"
    return
  fi
  local decide_json; decide_json="$(caso4_decide "$((s+1800))" "$pos")"
  if ! printf '%s' "$decide_json" | grep -q '"accion":"SEND"' || ! printf '%s' "$decide_json" | grep -q '"tipo":"inmediato"'; then
    escribir_caso 4 "NO FUNCIONA" "runbook.progress.decide no dio SEND inmediato: $decide_json" "$t0_iso" "" "" "" "$simulado"
    return
  fi
  local mensaje; mensaje="$(printf '%s' "$decide_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("mensaje",""))
except Exception: print("")' 2>/dev/null)"
  [ -n "$mensaje" ] || { escribir_caso 4 "NO FUNCIONA" "SEND inmediato sin mensaje" "$t0_iso" "" "" "" "$simulado"; return; }
  local texto="[SIMULACRO] $mensaje" salida_msg rc2=0
  salida_msg="$(con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" message send --channel telegram \
    -t "$(json_campo "$DIR_SIM/registro.json" canal.destino)" --json -m "$texto" 2>&1)" || rc2=1
  if [ "$rc2" -ne 0 ]; then
    escribir_caso 4 "NO FUNCIONA" "message send del inmediato DETENIDA fallo" "$t0_iso" "" "" "" "$simulado"
    return
  fi
  local msg_id; msg_id="$(printf '%s' "$salida_msg" | python3 -c 'import json,sys
t=sys.stdin.read()
try:
  d=json.loads(t[t.index("{"):]); print(d.get("messageId",""))
except Exception:
  print("")' 2>/dev/null)"
  [ -n "$msg_id" ] || { escribir_caso 4 "NO FUNCIONA" "el message send del inmediato no devolvio messageId" "$t0_iso" "" "" "" "$simulado"; return; }
  local hora_msg; hora_msg="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  escribir_caso 4 "FUNCIONA" "" "$t0_iso" "$hora_msg" "$msg_id" \
    "corrida.sh estado --solo-mensaje: S+1799 sin 'sin actividad en su pantalla'; S+1800 [DETENIDA] '...sin actividad en su pantalla' + accion interna relanzar; runbook.progress.decide (modulo puro) SEND inmediato; mandado con message send --json" \
    "$simulado"
}

# ---------- casos 5 y 6: kill-session y relanzamiento ------------------------
entradas_para_dir() { # $1 dir -> cuantas sesiones del registro tienen ese dir
  CORR_REG="$DIR_SIM/registro.json" CORR_DIR="$1" python3 -c "
import json,os
try: d=json.load(open(os.environ['CORR_REG']))
except Exception: d={}
print(sum(1 for s in d.get('sesiones',[]) if isinstance(s,dict) and s.get('dir')==os.environ['CORR_DIR']))
" 2>/dev/null
}
hora_evento_cerrado() { # $1 nombre de sesion -> hora ISO del evento "closed" en eventos.jsonl (o vacio)
  EV="$WATCH_STATE_DIR/eventos.jsonl" NOM="$1" python3 -c "
import json,os,datetime
try: lineas=open(os.environ['EV']).read().splitlines()
except Exception: lineas=[]
patron='%s closed' % os.environ['NOM']
t=None
for l in lineas:
  try: d=json.loads(l)
  except Exception: continue
  if patron in str(d.get('evento','')):
    t=d.get('t')
if t is None:
  print(''); raise SystemExit
try: print(datetime.datetime.utcfromtimestamp(float(t)).strftime('%Y-%m-%dT%H:%M:%SZ'))
except Exception: print('')
" 2>/dev/null
}
correr_relanzo_kill() { # $1 numero de caso, $2 nombre de sesion, $3 rol, $4 tope
  local n="$1" nombre="$2" rol="$3" tope="$4"
  local dir="$DIR_SIM/trabajo/c$n"
  local simulado="kill-session $nombre ($rol, glm, marcada); se espera el relanzamiento real via vigia -> system event -> main"
  ruta_sin_reloj "trabajo/c$n" && mkdir -p "$dir" || {
    escribir_caso "$n" "NO FUNCIONA" "no se pudo crear el directorio de trabajo" "" "" "" "" ""; return; }
  local salida rc=0
  salida="$("$CORRIDA_BIN" lanzar-sesion "$SIM_ID" "$rol" glm "$dir" --nombre "$nombre" 2>&1)" || rc=1
  if [ "$rc" -ne 0 ]; then
    escribir_caso "$n" "NO FUNCIONA" "lanzar-sesion no dio rc 0: $salida" "" "" "" "" "$simulado"
    return
  fi
  local t0_iso; t0_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local antes; antes="$(entradas_para_dir "$dir")"
  # El vigia solo puede avisar "closed" de una sesion que YA vio viva al
  # menos una vez (el barrido compara contra su propio .state); matarla
  # antes de esa primera foto la deja invisible para siempre.
  local ini_vigia=$SECONDS
  while [ ! -f "$WATCH_STATE_DIR/$nombre.state" ] && [ "$((SECONDS-ini_vigia))" -lt 20 ]; do
    sleep 1
  done
  "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null
  local ini=$SECONDS ok=0
  while [ "$((SECONDS-ini))" -lt "$tope" ]; do
    if grep -qF "$nombre closed" "$WATCH_STATE_DIR/eventos.jsonl" 2>/dev/null \
      && "$TMUX_BIN" has-session -t "=$nombre" 2>/dev/null; then
      local marca; marca="$("$TMUX_BIN" show-environment -t "=$nombre" OPENCLAW_WATCH_RUN 2>/dev/null)" || marca=""
      if [ "$marca" = "OPENCLAW_WATCH_RUN=$SIM_ID" ] && [ "$(entradas_para_dir "$dir")" = "$((antes+1))" ]; then
        ok=1; break
      fi
    fi
    sleep 3
  done
  if [ "$ok" -ne 1 ]; then
    escribir_caso "$n" "NO FUNCIONA" "en ${tope}s no se vio 'closed' + sesion nueva marcada + registro con una entrada mas para $dir" \
      "$t0_iso" "" "" "" "$simulado"
    return
  fi
  sleep "$SIM_ESPERA_DOBLE"
  local despues; despues="$(entradas_para_dir "$dir")"
  if [ "$despues" != "$((antes+1))" ]; then
    escribir_caso "$n" "NO FUNCIONA" "hubo un segundo relanzamiento (entradas para $dir: antes=$antes, despues=$despues)" \
      "$t0_iso" "" "" "" "$simulado"
    return
  fi
  local hora_evento; hora_evento="$(hora_evento_cerrado "$nombre")"
  [ -n "$hora_evento" ] || hora_evento="$t0_iso"
  escribir_caso "$n" "FUNCIONA" "" "$hora_evento" "no aplica: sin mensaje por diseno" "no aplica: sin mensaje por diseno" \
    "eventos.jsonl del vigia: '$nombre closed'; sesion nueva $nombre con OPENCLAW_WATCH_RUN=$SIM_ID; registro con exactamente una entrada mas para $dir/; sin segundo relanzamiento en ${SIM_ESPERA_DOBLE}s" \
    "$simulado"
}
correr_caso5() { correr_relanzo_kill 5 sim9-c5 carril "$SIM_TOPE_C5"; }
correr_caso6() { correr_relanzo_kill 6 sim9-lead lead "$SIM_TOPE_C6"; }

# ---------- caso 7: corte de 30 min con reporte-confirmado -------------------
caso7_decide() { # $1 ahora $2 ultimoReporteConfirmado -> JSON de decidirSeguimiento
  local ahora="$1" ultimo="$2"
  CASO7_AHORA="$ahora" CASO7_ULTIMO="$ultimo" python3 -c "
import json,os
d={'modo':'tick','ahora':int(os.environ['CASO7_AHORA']),
'estado':{'schema':'seguimiento-clock.v1','corte':{'kind':'reporte-confirmado','ultimoReporteConfirmado':int(os.environ['CASO7_ULTIMO'])},'ultimoEstado':'','ultimoInmediato':None,'messageId':None,'trabajosActivos':[]},
'inmediato':None}
print(json.dumps(d))
" | con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" gateway call runbook.progress.decide --params "$(cat)" --timeout 30000 2>/dev/null
}
correr_caso7() {
  local simulado="runbook.progress.decide modo:tick, estado sintetico {corte:{kind:reporte-confirmado, ultimoReporteConfirmado: ahora-3600}} (control negativo: ahora-1799); con seguimiento.v2 el latido de 60 min lo cubre el corte de 30"
  local ahora; ahora="$(date +%s)"
  local ahora_iso; ahora_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local neg; neg="$(caso7_decide "$ahora" "$((ahora-1799))")"
  if ! printf '%s' "$neg" | grep -q '"accion":"NO_REPLY"'; then
    escribir_caso 7 "NO FUNCIONA" "el control negativo (ahora-1799) no dio NO_REPLY: $neg" "$ahora_iso" "" "" "" "$simulado"
    return
  fi
  local pos; pos="$(caso7_decide "$ahora" "$((ahora-3600))")"
  if ! printf '%s' "$pos" | grep -q '"accion":"SEND"' || ! printf '%s' "$pos" | grep -q '"tipo":"periodico"'; then
    escribir_caso 7 "NO FUNCIONA" "el positivo (ahora-3600) no dio SEND periodico: $pos" "$ahora_iso" "" "" "" "$simulado"
    return
  fi
  local mensaje; mensaje="$(printf '%s' "$pos" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("mensaje",""))
except Exception: print("")' 2>/dev/null)"
  [ -n "$mensaje" ] || { escribir_caso 7 "NO FUNCIONA" "SEND periodico sin mensaje" "$ahora_iso" "" "" "" "$simulado"; return; }
  local texto="[SIMULACRO] $mensaje" salida rc=0
  salida="$(con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" message send --channel telegram \
    -t "$(json_campo "$DIR_SIM/registro.json" canal.destino)" --json -m "$texto" 2>&1)" || rc=1
  if [ "$rc" -ne 0 ]; then
    escribir_caso 7 "NO FUNCIONA" "message send del periodico fallo" "$ahora_iso" "" "" "" "$simulado"
    return
  fi
  local msg_id; msg_id="$(printf '%s' "$salida" | python3 -c 'import json,sys
t=sys.stdin.read()
try:
  d=json.loads(t[t.index("{"):]); print(d.get("messageId",""))
except Exception:
  print("")' 2>/dev/null)"
  [ -n "$msg_id" ] || { escribir_caso 7 "NO FUNCIONA" "el message send del periodico no devolvio messageId" "$ahora_iso" "" "" "" "$simulado"; return; }
  local hora_msg; hora_msg="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  escribir_caso 7 "FUNCIONA" "" "$ahora_iso" "$hora_msg" "$msg_id" \
    "runbook.progress.decide (modulo puro): control negativo ahora-1799 => NO_REPLY; ahora-3600 => SEND periodico; mandado con message send --json y prefijo" \
    "$simulado"
}

correr_caso1
correr_caso2 &
CASO2_PID=$!
correr_caso3 &
CASO3_PID=$!
wait "$CASO2_PID"
wait "$CASO3_PID"

correr_caso4

correr_caso5 &
CASO5_PID=$!
correr_caso6 &
CASO6_PID=$!
wait "$CASO5_PID"
wait "$CASO6_PID"

correr_caso7

# ============================= observacion extendida (pieza d) =============
# Opcion A de David: en vivo, SIN reloj inyectado (el "reloj corto" de
# --ensayo solo acorta el sondeo propio del arnes — SIM_TOPE_OBS_POLL/
# SIM_TOPE_OBS_VENTANA — nunca el de corrida.sh estado). Solo corre si se
# pidio con --observar-avance.
OBS_NOTA="no pedida"
obs_cron_declarationkey_uuid() { # -> uuid del cron avance-tareas (vacio si no hay o esta ilegible)
  con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" cron list --all --json 2>/dev/null | python3 -c '
import json,sys
t=sys.stdin.read()
try:
  d=json.loads(t[t.index("{"):])
except Exception:
  print(""); raise SystemExit
jobs=[j for j in (d.get("jobs") or d.get("result",{}).get("jobs") or []) if isinstance(j,dict) and j.get("declarationKey")=="avance-tareas"]
print(jobs[0].get("id","") if jobs else "")
' 2>/dev/null
}
obs_scratch_confirmado() { # $1 uuid, $2 epoch minimo -> "SI <messageId>" si
                           # corte.kind=reporte-confirmado, con messageId, Y
                           # ultimoReporteConfirmado >= el epoch minimo; si no, ""
  local uuid="$1" desde="$2"
  [ -n "$uuid" ] || return 1
  con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" cron scratch "$uuid" 2>/dev/null | OBS_DESDE="$desde" python3 -c '
import json,os,sys
t=sys.stdin.read()
try:
  d=json.loads(t[t.index("{"):])
except Exception:
  raise SystemExit
nodo=d
if not (isinstance(nodo,dict) and nodo.get("schema")=="seguimiento-clock.v1"):
  for k in ("result","scratch","data","state"):
    v=nodo.get(k) if isinstance(nodo,dict) else None
    if isinstance(v,dict) and v.get("schema")=="seguimiento-clock.v1":
      nodo=v; break
if not (isinstance(nodo,dict) and nodo.get("schema")=="seguimiento-clock.v1"):
  raise SystemExit
corte=nodo.get("corte") or {}
mid=nodo.get("messageId")
urc=corte.get("ultimoReporteConfirmado")
desde=int(os.environ["OBS_DESDE"])
# Un scratch viejo (de un cron avance-tareas que ya existia de antes, rancio o
# apagado) no puede colarse como si fuera el aviso de ESTA observacion: el
# corte confirmado tiene que ser de al menos cuando se mando el turno a main.
if (corte.get("kind")=="reporte-confirmado" and mid is not None
    and isinstance(urc,(int,float)) and not isinstance(urc,bool) and urc>=desde):
  print("SI %s" % mid)
' 2>/dev/null
}
if [ -n "$OBSERVAR_AVANCE" ]; then
  OBS_NOTA="pedida (--observar-avance $OBSERVAR_AVANCE)"
  OBS_MSGFILE="$(mktemp)"
  {
    printf '[SIMULACRO] Hay una corrida de simulacro abierta: %s\n' "$SIM_ID"
    # Medido 2026-09-25: el parentesis viejo ("no hace falta que crees ningun
    # cron") le decia a main lo contrario de lo que esta observacion mide (que
    # el cron avance-tareas aparezca): main lo obedecio al pie de la letra y el
    # disparo real quedo en "no se vio (a) el cron" en las dos corridas del 24
    # y 25/09. El turno ahora pide seguir la seccion como con cualquier trabajo
    # activo, que incluye crear el aviso que esa seccion manda.
    printf 'Siguela segun tu seccion "Avisos de avance" como con cualquier trabajo activo (incluye crear el aviso que esa seccion manda).\n'
  } > "$OBS_MSGFILE"
  OBS_T0=$SECONDS
  OBS_T0_EPOCH="$(date +%s)"
  OBS_T0_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  OBS_TURNO_OK=0
  if con_tope "$SIM_TOPE_TURNO_MAIN" "$OPENCLAW_BIN" agent --agent main --session-key "agent:main:sim9-$SIM_ID" \
      --message-file "$OBS_MSGFILE" --json >/dev/null 2>&1; then
    OBS_TURNO_OK=1
  fi
  rm -f "$OBS_MSGFILE"
  OBS_A_OK=0 OBS_A_HORA="" OBS_UUID_ENCONTRADO=""
  OBS_B_OK=0 OBS_B_HORA="" OBS_MSG_ID=""
  if [ "$OBS_TURNO_OK" = "1" ]; then
    local_tope_obs=$((OBSERVAR_AVANCE * 60))
    while [ "$((SECONDS-OBS_T0))" -lt "$local_tope_obs" ]; do
      if [ "$OBS_A_OK" = "0" ]; then
        OBS_UUID_ENCONTRADO="$(obs_cron_declarationkey_uuid)"
        if [ -n "$OBS_UUID_ENCONTRADO" ]; then OBS_A_OK=1; OBS_A_HORA="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
      fi
      if [ "$OBS_A_OK" = "1" ] && [ "$OBS_B_OK" = "0" ] && [ "$((SECONDS-OBS_T0))" -ge "$SIM_TOPE_OBS_VENTANA" ]; then
        OBS_RESP="$(obs_scratch_confirmado "$OBS_UUID_ENCONTRADO" "$OBS_T0_EPOCH")"
        if printf '%s' "$OBS_RESP" | grep -q '^SI '; then
          OBS_B_OK=1
          OBS_B_HORA="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          OBS_MSG_ID="${OBS_RESP#SI }"
        fi
      fi
      [ "$OBS_A_OK" = "1" ] && [ "$OBS_B_OK" = "1" ] && break
      sleep "$SIM_TOPE_OBS_POLL"
    done
    # CodeRabbit (PR #153): el while SOLO entra mientras faltan menos de
    # local_tope_obs; el chequeo del scratch SOLO corre cuando ya paso la
    # ventana completa. Si ninguna vuelta cayo con los dos a la vez (topes
    # ajustados, el sondeo salta justo por encima del borde), el bucle
    # terminaba sin comprobar nunca — aunque el reporte ya estuviera
    # confirmado. Una comprobacion final, al salir, cubre exactamente ese
    # borde (basta con que el tope total alcance la ventana).
    if [ "$OBS_A_OK" = "1" ] && [ "$OBS_B_OK" = "0" ] && [ "$local_tope_obs" -ge "$SIM_TOPE_OBS_VENTANA" ]; then
      OBS_RESP="$(obs_scratch_confirmado "$OBS_UUID_ENCONTRADO" "$OBS_T0_EPOCH")"
      if printf '%s' "$OBS_RESP" | grep -q '^SI '; then
        OBS_B_OK=1
        OBS_B_HORA="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        OBS_MSG_ID="${OBS_RESP#SI }"
      fi
    fi
  fi
  if [ "$OBS_A_OK" = "1" ] && [ "$OBS_B_OK" = "1" ]; then
    leer_caso 4; escribir_caso 4 "$CASO_RESULTADO" "observado real: cron avance-tareas a las $OBS_A_HORA, scratch confirmado a las $OBS_B_HORA (messageId $OBS_MSG_ID)" \
      "$CASO_HORA_EVENTO" "$CASO_HORA_MENSAJE" "$CASO_MSG_ID" "$CASO_OBSERVABLE" "$CASO_SIMULADO"
    leer_caso 7; escribir_caso 7 "$CASO_RESULTADO" "observado real: cron avance-tareas a las $OBS_A_HORA, scratch confirmado a las $OBS_B_HORA (messageId $OBS_MSG_ID)" \
      "$CASO_HORA_EVENTO" "$CASO_HORA_MENSAJE" "$CASO_MSG_ID" "$CASO_OBSERVABLE" "$CASO_SIMULADO"
    OBS_NOTA="$OBS_NOTA; turno mandado a las $OBS_T0_ISO; (a) cron avance-tareas visto a las $OBS_A_HORA; (b) scratch reporte-confirmado a las $OBS_B_HORA con messageId $OBS_MSG_ID; casos 4 y 7: FUNCIONA observado real"
  else
    motivo="no se vio (a) el cron"
    [ "$OBS_A_OK" = "1" ] && motivo="se vio el cron (a) a las $OBS_A_HORA pero no (b) su scratch confirmado"
    [ "$OBS_TURNO_OK" != "1" ] && motivo="el turno a main no completo (tope o error; el mensaje pudo haber llegado)"
    leer_caso 4; escribir_caso 4 "$CASO_RESULTADO" "NO OBSERVADO: disparo real ($motivo)" \
      "$CASO_HORA_EVENTO" "$CASO_HORA_MENSAJE" "$CASO_MSG_ID" "$CASO_OBSERVABLE" "$CASO_SIMULADO"
    leer_caso 7; escribir_caso 7 "$CASO_RESULTADO" "NO OBSERVADO: disparo real ($motivo)" \
      "$CASO_HORA_EVENTO" "$CASO_HORA_MENSAJE" "$CASO_MSG_ID" "$CASO_OBSERVABLE" "$CASO_SIMULADO"
    OBS_NOTA="$OBS_NOTA; turno mandado a las $OBS_T0_ISO; NO OBSERVADO: disparo real ($motivo); casos 4 y 7 quedan con su evidencia de reloj inyectado"
  fi
  # Al cerrar, dato (no requisito): si "main" ya retiro el cron. Cierre
  # explicito aqui (idempotente: el trap final ve "cerrada" y no repite
  # nada) para poder mirar UN tick despues del cierre, acotado y corto.
  if [ -n "$OBS_UUID_ENCONTRADO" ]; then
    "$CORRIDA_BIN" cerrar "$SIM_ID" >/dev/null 2>&1
    OBS_RETIRO="sin verificar (no se espero)"
    local_ini_retiro=$SECONDS
    while [ "$((SECONDS-local_ini_retiro))" -lt 120 ]; do
      if [ -z "$(obs_cron_declarationkey_uuid)" ]; then
        OBS_RETIRO="si, main lo retiro tras el cierre"
        break
      fi
      sleep 20
    done
    [ "$OBS_RETIRO" = "sin verificar (no se espero)" ] && OBS_RETIRO="no se vio retirado en 2 min tras el cierre (dato, no bloqueante)"
    OBS_NOTA="$OBS_NOTA; al cerrar, el cron avance-tareas: $OBS_RETIRO"
  fi
fi

# ============================= evidencia ====================================
FECHA_HOY="$(date +%Y-%m-%d)"
[ -n "$SALIDA" ] || SALIDA="$REPO_RAIZ/docs/evidence/fase9-simulacro-$FECHA_HOY.md"

sha_origin_main() { git -C "$REPO_RAIZ" rev-parse --verify -q origin/main 2>/dev/null || echo "sin-resolver"; }

tabla_instalado() {
  local f
  printf '| archivo | blob en origin/main | blob instalado | igual |\n|---|---|---|---|\n'
  for f in corrida.sh cli-modos.tsv agent-tmux.sh agent-tmux-shell.zsh tmux-activity-watch.sh claude-stop-openclaw-event.sh shot.sh; do
    local esp real igual
    esp="$(git -C "$REPO_RAIZ" rev-parse --verify -q "origin/main:scripts/mac/$f" 2>/dev/null || echo "sin-referencia")"
    real="$(git -C "$REPO_RAIZ" hash-object "$HOME/bin/$f" 2>/dev/null || echo "sin-instalar")"
    [ "$esp" = "$real" ] && igual="si" || igual="no"
    printf '| %s | %s | %s | %s |\n' "$f" "$esp" "$real" "$igual"
  done
  for f in "$REPO_RAIZ"/scripts/mac/corrida/*.sh; do
    local b esp real igual
    b="$(basename "$f")"
    esp="$(git -C "$REPO_RAIZ" rev-parse --verify -q "origin/main:scripts/mac/corrida/$b" 2>/dev/null || echo "sin-referencia")"
    real="$(git -C "$REPO_RAIZ" hash-object "$HOME/bin/corrida/$b" 2>/dev/null || echo "sin-instalar")"
    [ "$esp" = "$real" ] && igual="si" || igual="no"
    printf '| corrida/%s | %s | %s | %s |\n' "$b" "$esp" "$real" "$igual"
  done
}

# Escapa SOLO al renderizar (el registro en casos/<n>.txt queda tal cual, sin
# escapar): una barra vertical suelta en un campo (p.ej. la salida cruda de
# un comando fallido) crearia una columna de mas en la tabla Markdown.
markdown_celda() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/|/\\|/g'
}

tabla_casos() {
  printf '| caso | como se provoco | hora del evento | hora del mensaje | id del mensaje | observable | resultado | que se simulo |\n'
  printf '|---|---|---|---|---|---|---|---|\n'
  local i nombre
  IFS='|' read -ra _c <<EOF
$CASOS_NOMBRE
EOF
  local n=${#_c[@]} idx=0
  while [ "$idx" -lt "$n" ]; do
    i="${_c[$idx]}"; nombre="${_c[$((idx+1))]}"
    leer_caso "$i"
    local col_resultado="$CASO_RESULTADO"
    [ -n "$CASO_DETALLE" ] && col_resultado="$CASO_RESULTADO ($CASO_DETALLE)"
    local col_nombre col_hora_evento col_hora_mensaje col_msg_id col_observable col_simulado
    col_nombre="$(markdown_celda "$nombre")"
    col_hora_evento="$(markdown_celda "$CASO_HORA_EVENTO")"
    col_hora_mensaje="$(markdown_celda "$CASO_HORA_MENSAJE")"
    col_msg_id="$(markdown_celda "$CASO_MSG_ID")"
    col_observable="$(markdown_celda "$CASO_OBSERVABLE")"
    col_resultado="$(markdown_celda "$col_resultado")"
    col_simulado="$(markdown_celda "$CASO_SIMULADO")"
    printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$i" "$col_nombre" "$col_hora_evento" "$col_hora_mensaje" "$col_msg_id" "$col_observable" "$col_resultado" "$col_simulado"
    idx=$((idx+2))
  done
}

eventos_vigia_sim9() {
  local f="$WATCH_STATE_DIR/eventos.jsonl"
  [ -f "$f" ] || { echo "(sin $f)"; return 0; }
  grep 'sim9-' "$f" 2>/dev/null || echo "(sin eventos con sim9- todavia)"
}

generar_evidencia() {
  local dir; dir="$(dirname "$SALIDA")"
  mkdir -p "$dir" || return 1
  {
    printf '# Evidencia — simulacro 9.9 (%s)\n\n' "$FECHA_HOY"
    printf 'Corrida de esta pasada: `%s`. Los 7 casos corren de verdad. Los casos 4 y 7 se miden con reloj inyectado; con `--observar-avance` se suben a "observado real" (disparo real de avance-tareas), ver seccion "Observacion extendida".\n\n' "$SIM_ID"
    printf '## Version\n\nSHA de origin/main: `%s`\n\n' "$(sha_origin_main)"
    printf '## Prerrequisitos\n\nTodos pasaron (si no, el arnes hubiera salido NO APTO antes de este punto).\n\n'
    printf '## `instalar-mac.sh --verificar`\n\n```\n%s\n```\n\n' "$(con_tope "$CORR_TOPE_RED" "$REPO_RAIZ/scripts/mac/instalar-mac.sh" --verificar 2>&1)"
    printf '## Instalado (blob en origin/main vs blob instalado)\n\n'
    tabla_instalado
    printf '\n## `runbook.progress.set` de arranque\n\n%s\n\n' \
      "$([ "${SIM_PROGRESS_SET_OK:-0}" = "1" ] && echo "ok" || echo "no confirmado (best-effort, no detiene el arnes)")"
    printf '## Los 7 casos\n\n'
    tabla_casos
    printf '\n## Lo no observado\n\n'
    if [ -n "$OBSERVAR_AVANCE" ]; then
      printf 'Ver el detalle del caso 4 y 7 arriba, y la seccion "Observacion extendida" de abajo.\n\n'
    else
      printf 'Casos 4 y 7: solo con reloj inyectado (no se pidio --observar-avance en esta corrida, asi que no se intento el disparo real).\n\n'
    fi
    printf 'Un caso en NO FUNCIONA queda con su detalle en la fila de arriba, no aqui.\n\n'
    printf '## Observacion extendida\n\n%s\n\n' "$OBS_NOTA"
    printf '## Eventos del vigia filtrados por `sim9-`\n\n```\n%s\n```\n\n' "$(eventos_vigia_sim9)"
    printf '## Lo que quedo en disco\n\n'
    printf -- '- `%s/registro.json`, `%s/decisiones.jsonl`, `%s/mensajes.jsonl`, `%s/eventos-seguimiento.jsonl` (la corrida se cierra antes de salir; se quedan para inspeccion).\n' "$DIR_SIM" "$DIR_SIM" "$DIR_SIM" "$DIR_SIM"
    printf -- '- `%s/trabajo/c1`, `c2`, `c3` (y `c4`-`c7` cuando existan) — nunca se borran de forma recursiva.\n' "$DIR_SIM"
    printf -- '- `%s/cli-modos.tsv` y `%s/bin/sim9-tui-falso` (la tabla generada por el arnes).\n' "$DIR_SIM" "$DIR_SIM"
    printf '\nNunca el destino del canal de mensajes.\n'
  } > "$SALIDA"
}

TOTAL_FUNCIONA=0
for _n in 1 2 3 4 5 6 7; do
  leer_caso "$_n"
  [ "$CASO_RESULTADO" = "FUNCIONA" ] && TOTAL_FUNCIONA=$((TOTAL_FUNCIONA+1))
done

generar_evidencia
echo "evidencia: $SALIDA"
echo "arnes 9.9: $TOTAL_FUNCIONA/7 casos FUNCIONA"
[ "$TOTAL_FUNCIONA" -eq 7 ] && exit 0
exit 1
