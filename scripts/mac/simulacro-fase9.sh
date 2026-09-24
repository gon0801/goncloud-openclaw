#!/bin/bash
# scripts/mac/simulacro-fase9.sh — arnes del simulacro 9.9 (Fase 9). PIEZA (a):
# esqueleto probado de punta a punta. Prerrequisitos, arranque, limpieza,
# --limpiar y el generador de evidencia estan completos; los 7 casos vivos
# (piezas b-e, siguientes) hoy quedan como placeholder "NO OBSERVADO:
# pendiente de implementar". Este archivo no simula NADA todavia: solo prueba
# que abrir y cerrar una corrida de mentira, y escribir su evidencia, funciona
# de punta a punta antes de sumarle los casos.
#
# Uso:
#   simulacro-fase9.sh [--ensayo] [--salida <md>] [--tope-pared <s>]
#                       [--observar-avance <min>]
#   simulacro-fase9.sh --limpiar <id>
#
# Salida: 0 solo con 7/7 FUNCIONA (hoy, nunca — no hay casos implementados);
# 1 si algun caso NO FUNCIONA o NO OBSERVADO (hoy, siempre); 2 NO APTO (no se
# lanzo nada: ni registro, ni sesion, ni tabla).
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
SALIDA=""
TOPE_PARED=570
OBSERVAR_AVANCE=""
LIMPIAR_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ensayo) ENSAYO=1; shift;;
    --salida) [ "$#" -ge 2 ] || { echo "simulacro-fase9: --salida sin valor" >&2; exit 2; }; SALIDA="$2"; shift 2;;
    --tope-pared) [ "$#" -ge 2 ] || { echo "simulacro-fase9: --tope-pared sin valor" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "simulacro-fase9: --tope-pared no es un numero de segundos: $2" >&2; exit 2;; esac
      TOPE_PARED="$2"; shift 2;;
    --observar-avance) [ "$#" -ge 2 ] || { echo "simulacro-fase9: --observar-avance sin valor" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "simulacro-fase9: --observar-avance no es un numero de minutos: $2" >&2; exit 2;; esac
      OBSERVAR_AVANCE="$2"; shift 2;;
    --limpiar) [ "$#" -ge 2 ] || { echo "simulacro-fase9: --limpiar sin valor" >&2; exit 2; }; LIMPIAR_ID="$2"; shift 2;;
    *) echo "simulacro-fase9: flag desconocido: $1" >&2; exit 2;;
  esac
done

# --- lib.sh de la corrida que se va a usar (checkout o instalada) ----------
CORRIDA_DIR="$(cd "$(dirname "$CORRIDA_BIN")" 2>/dev/null && pwd)/corrida"
[ -f "$CORRIDA_DIR/lib.sh" ] || { echo "simulacro-fase9: no encuentro $CORRIDA_DIR/lib.sh (CORRIDA_BIN=$CORRIDA_BIN)" >&2; exit 2; }
. "$CORRIDA_DIR/lib.sh"

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
# nuevo) y antes de arrancar nada mas.
LIMPIEZA_LOG="$(mktemp)" || { echo "simulacro-fase9: sin mktemp para el log de limpieza" >&2; exit 2; }
limpiar_corrida() { # $1 id; nunca falla el script: todo es best-effort y anotado
  local id="$1"
  corrida_id_valido "$id" || return 0
  local reg; reg="$(registro_de "$id")"
  local habia_registro=0
  if [ -f "$reg" ]; then
    habia_registro=1
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
  # kill-session de TODA sesion marcada con este id, por nombre o por dueno
  # publicado — sin depender de que el registro siga legible.
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
limpieza_exit() {
  local rc=$?
  [ "$LIMPIEZA_HECHA" = "1" ] && exit "$rc"
  LIMPIEZA_HECHA=1
  limpiar_corrida "$SIM_ID"
  if [ "$ENSAYO" = "1" ] && [ -n "$VIGIA_PID" ]; then
    kill "$VIGIA_PID" 2>/dev/null
    wait "$VIGIA_PID" 2>/dev/null
  fi
  exit "$rc"
}
trap limpieza_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
if [ "$ENSAYO" = "1" ]; then
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

  pgrep -f "$VIGIA_PATRON" >/dev/null 2>&1 || razon "el vigia no esta vivo ($VIGIA_PATRON)"

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
  touch "$DIR_SIM/responder.on" || { ARR_RAZON="no se pudo encender responder.on"; return 1; }
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

# ============================= casos (PIEZA a: pendientes) =================
# Las piezas b-e llenan esta tabla con la corrida real de cada caso. Aqui
# solo se deja la fila con su forma final para que el generador de evidencia
# ya tenga algo que imprimir de punta a punta.
CASOS_NOMBRE="1|contrato LISTO 0000000 y recoger|2|dialogo de confianza aceptado por politica|3|comando que escala y NECESITA TU RESPUESTA|4|reloj inyectado: 30 min sin actividad|5|kill-session de un carril y relanzamiento|6|kill-session del lead y relanzamiento|7|corte de 30 min con reporte-confirmado"
resultado_caso() { # $1 numero de caso -> linea "resultado|detalle"
  printf 'NO OBSERVADO|pendiente de implementar (pieza b-e)\n'
}

# ============================= observacion extendida (PIEZA a: sin correr) =
OBS_NOTA="no pedida"
if [ -n "$OBSERVAR_AVANCE" ]; then
  OBS_NOTA="pedida (--observar-avance $OBSERVAR_AVANCE); la pieza (a) todavia no la corre: queda para una pieza siguiente"
fi

# ============================= evidencia ====================================
FECHA_HOY="$(date +%Y-%m-%d)"
[ -n "$SALIDA" ] || SALIDA="$REPO_RAIZ/docs/evidence/fase9-simulacro-$FECHA_HOY.md"

sha_origin_main() { git -C "$REPO_RAIZ" rev-parse origin/main 2>/dev/null || echo "sin-resolver"; }

tabla_instalado() {
  local f
  printf '| archivo | blob en origin/main | blob instalado | igual |\n|---|---|---|---|\n'
  for f in corrida.sh cli-modos.tsv agent-tmux.sh agent-tmux-shell.zsh tmux-activity-watch.sh claude-stop-openclaw-event.sh shot.sh; do
    local esp real igual
    esp="$(git -C "$REPO_RAIZ" rev-parse "origin/main:scripts/mac/$f" 2>/dev/null || echo "sin-referencia")"
    real="$(git -C "$REPO_RAIZ" hash-object "$HOME/bin/$f" 2>/dev/null || echo "sin-instalar")"
    [ "$esp" = "$real" ] && igual="si" || igual="no"
    printf '| %s | %s | %s | %s |\n' "$f" "$esp" "$real" "$igual"
  done
  for f in "$REPO_RAIZ"/scripts/mac/corrida/*.sh; do
    local b esp real igual
    b="$(basename "$f")"
    esp="$(git -C "$REPO_RAIZ" rev-parse "origin/main:scripts/mac/corrida/$b" 2>/dev/null || echo "sin-referencia")"
    real="$(git -C "$REPO_RAIZ" hash-object "$HOME/bin/corrida/$b" 2>/dev/null || echo "sin-instalar")"
    [ "$esp" = "$real" ] && igual="si" || igual="no"
    printf '| corrida/%s | %s | %s | %s |\n' "$b" "$esp" "$real" "$igual"
  done
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
    local linea; linea="$(resultado_caso "$i")"
    local resultado="${linea%%|*}" detalle="${linea#*|}"
    printf '| %s | %s | pendiente | pendiente | pendiente | pendiente | %s | %s |\n' \
      "$i" "$nombre" "$resultado" "$detalle"
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
    printf 'Corrida de esta pasada: `%s`. Pieza (a): esqueleto probado de punta a punta; los 7 casos son placeholder.\n\n' "$SIM_ID"
    printf '## Version\n\nSHA de origin/main: `%s`\n\n' "$(sha_origin_main)"
    printf '## Prerrequisitos\n\nTodos pasaron (si no, el arnes hubiera salido NO APTO antes de este punto).\n\n'
    printf '## `instalar-mac.sh --verificar`\n\n```\n%s\n```\n\n' "$(con_tope "$CORR_TOPE_RED" "$REPO_RAIZ/scripts/mac/instalar-mac.sh" --verificar 2>&1)"
    printf '## Instalado (blob en origin/main vs blob instalado)\n\n'
    tabla_instalado
    printf '\n## `runbook.progress.set` de arranque\n\n%s\n\n' \
      "$([ "${SIM_PROGRESS_SET_OK:-0}" = "1" ] && echo "ok" || echo "no confirmado (best-effort, no detiene el arnes)")"
    printf '## Los 7 casos\n\n'
    tabla_casos
    printf '\n## Lo no observado\n\nNinguno de los 7 casos corre todavia: esta es la pieza (a) del arnes '
    printf '(el esqueleto). Las piezas siguientes implementan cada caso.\n\n'
    printf '## Observacion extendida\n\n%s\n\n' "$OBS_NOTA"
    printf '## Eventos del vigia filtrados por `sim9-`\n\n```\n%s\n```\n\n' "$(eventos_vigia_sim9)"
    printf '## Lo que quedo en disco\n\n'
    printf '- `%s/registro.json` (la corrida se cierra antes de salir; el registro y `%s/trabajo/` — si los hubiera — se quedan para inspeccion).\n' "$DIR_SIM" "$DIR_SIM"
    printf '- `%s/cli-modos.tsv` y `%s/bin/sim9-tui-falso` (la tabla generada por el arnes).\n' "$DIR_SIM" "$DIR_SIM"
    printf '\nNunca el destino del canal de mensajes.\n'
  } > "$SALIDA"
}

generar_evidencia
echo "evidencia: $SALIDA"
echo "arnes 9.9 (pieza a): esqueleto OK; 0/7 casos implementados todavia"
exit 1
