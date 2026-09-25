#!/bin/bash
# Doble de OPENCLAW_BIN para --ensayo (9.9, piezas a-d). Contesta lo que el
# arnes necesita: cron list (destino falso, o --all para la observacion
# extendida), gateway call runbook.progress.list/set/status, gateway call
# runbook.progress.decide (corre el MODULO PURO real via decide-puro.mjs, no
# una respuesta inventada), message send (con preambulo antes del JSON, como
# un CLI real que imprime avisos), browser tabs (mecanismo del navegador que
# preflight prueba), system event (el vigia doblado; "X closed" hace de
# "main falso": relanza esa sesion desde su propio registro), agent (el
# turno que la observacion extendida le manda a "main": tambien hace de
# "main falso" y crea un cron avance-tareas con su scratch confirmado, para
# poder ejercitar el sondeo con topes cortos), cron scratch (lee ese mismo
# cron falso). Cualquier otra cosa sale 0 sin texto: nunca se cuelga.
#
# Env:
#   SIM9_LLAMADAS    si esta puesto, cada invocacion se anota ahi (para
#                    pruebas que necesiten confirmar que algo se llamo)
#   SIM9_DESTINO     destino falso que "cron list" resuelve para
#                    cuotas-proveedores (def. DESTINO-FALSO-SIM9)
#   SIM9_MSG_ID      id que "message send" devuelve (def. 9001); vacio =
#                    responde sin messageId (para probar la fila NO FUNCIONA)
#   SIM9_OBS_MSG_ID  id que el scratch del cron falso trae ya confirmado
#                    (def. 9101); vacio = el cron aparece pero SIN
#                    confirmar (para probar que el aviso real "no aplica")
#   SIM_MAIN=mudo    "main" no hace nada: ni relanza sesiones cerradas
#                    ("system event ... closed") ni crea el cron falso al
#                    recibir el turno de la observacion extendida. Por
#                    defecto "main" SI actua en los dos casos.
#   SIM9_NODE_BIN    el node (>=22, con type stripping nativo) que corre
#                    decide-puro.mjs -- lo elige quien invoca este fixture
#                    (test-simulacro-fase9.sh, con la misma receta de
#                    scripts/run-checks.sh); sin el, cae al "node" ambiental.
set -u
DESTINO="${SIM9_DESTINO:-DESTINO-FALSO-SIM9}"
MSGID="${SIM9_MSG_ID-9001}"
OBS_UUID="sim9-avance-tareas-fake"
OBS_DIR="${CORRIDA_STATE:-}/.sim9-obs-cron"
AQUI="$(cd "$(dirname "$0")" && pwd)"
[ -n "${SIM9_LLAMADAS:-}" ] && printf '%s\n' "openclaw $*" >> "$SIM9_LLAMADAS"

TEXT=""
PARAMS=""
prev=""
for a in "$@"; do
  case "$prev" in
    --text) TEXT="$a";;
    --params) PARAMS="$a";;
  esac
  prev="$a"
done

# "main falso": una sesion marcada que se cerro (evento "tmux: <ses> closed")
# se relanza con el mismo rol/cli/dir que traia en el registro que la reclama
# — igual que main haria al recibir el mismo evento. En segundo plano: la
# llamada a "system event" tiene que volver rapido, como la real.
main_falso_relanzar() { # $1 nombre de sesion
  local nombre="$1" info id rol cli dir
  info="$(SIM9_CS="$CORRIDA_STATE" SIM9_NOM="$nombre" python3 -c "
import json,glob,os
for p in sorted(glob.glob(os.path.join(os.environ['SIM9_CS'],'*','registro.json'))):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if d.get('estado') != 'abierta':
        continue
    for s in d.get('sesiones', []):
        if isinstance(s, dict) and s.get('nombre') == os.environ['SIM9_NOM']:
            print('%s\t%s\t%s\t%s' % (d.get('id',''), s.get('rol',''), s.get('cli',''), s.get('dir','')))
            raise SystemExit
" 2>/dev/null)"
  [ -n "$info" ] || return 0
  IFS="$(printf '\t')" read -r id rol cli dir <<EOF2
$info
EOF2
  [ -n "$id" ] && [ -n "$rol" ] && [ -n "$cli" ] && [ -n "$dir" ] || return 0
  [ -x "${CORRIDA_BIN:-}" ] || return 0
  "$CORRIDA_BIN" lanzar-sesion "$id" "$rol" "$cli" "$dir" --nombre "$nombre" >/dev/null 2>&1
}

case "$*" in
  *"cron list --all"*)
    if [ -f "$OBS_DIR/job.json" ]; then
      printf '{"jobs":[%s]}' "$(cat "$OBS_DIR/job.json")"
    else
      printf '{"jobs":[]}'
    fi
    ;;
  *"cron list"*)
    printf '{"jobs":[{"name":"cuotas-proveedores","delivery":{"to":"%s"}}]}' "$DESTINO"
    ;;
  *"cron scratch "*)
    todo="$*"
    uuid="${todo##* }"
    if [ "$uuid" = "$OBS_UUID" ] && [ -f "$OBS_DIR/$OBS_UUID.scratch.json" ]; then
      cat "$OBS_DIR/$OBS_UUID.scratch.json"
    else
      printf '{}'
    fi
    ;;
  *"agent --agent main"*)
    if [ "${SIM_MAIN:-}" != "mudo" ] && [ -n "$OBS_DIR" ]; then
      mkdir -p "$OBS_DIR" 2>/dev/null
      printf '{"id":"%s","name":"avance-tareas","declarationKey":"avance-tareas","enabled":true}' \
        "$OBS_UUID" > "$OBS_DIR/job.json"
      OBSMID="${SIM9_OBS_MSG_ID-9101}"
      if [ -n "$OBSMID" ]; then
        printf '{"schema":"seguimiento-clock.v1","corte":{"kind":"reporte-confirmado","ultimoReporteConfirmado":%s},"ultimoEstado":"","ultimoInmediato":null,"messageId":%s,"trabajosActivos":["corrida:sim9-obs"]}' \
          "$(date +%s)" "$OBSMID" > "$OBS_DIR/$OBS_UUID.scratch.json"
      else
        printf '{"schema":"seguimiento-clock.v1","corte":{"kind":"esperando-primer-reporte","inicioVentana":%s},"ultimoEstado":"","ultimoInmediato":null,"messageId":null,"trabajosActivos":[]}' \
          "$(date +%s)" > "$OBS_DIR/$OBS_UUID.scratch.json"
      fi
    fi
    printf '{"ok":true}'
    ;;
  *"gateway call runbook.progress.list"*)
    printf '{"ok":true,"result":{"documentos":[]}}'
    ;;
  *"gateway call runbook.progress.set"*)
    printf '{"ok":true}'
    ;;
  *"gateway call runbook.progress.decide"*)
    printf '%s' "$PARAMS" | "${SIM9_NODE_BIN:-node}" "$AQUI/decide-puro.mjs" 2>>"${SIM9_LLAMADAS:-/dev/null}"
    ;;
  *"gateway call status"*)
    printf '{"ok":true}'
    ;;
  *"message send"*)
    printf 'aviso de arranque del CLI de mentira\n'
    if [ -n "$MSGID" ]; then
      printf '{"ok":true,"messageId":%s}' "$MSGID"
    else
      printf '{"ok":true}'
    fi
    ;;
  *"browser tabs --profile claw"*)
    printf '{"ok":false,"config":".openclaw-claw/openclaw.json"}'
    ;;
  *"browser tabs --browser-profile claw"*)
    printf '{"ok":true,"config":".openclaw/openclaw.json"}'
    ;;
  *"system event"*)
    case "$TEXT" in
      "tmux: "*" closed"*)
        if [ "${SIM_MAIN:-}" != "mudo" ]; then
          nombre="${TEXT#tmux: }"; nombre="${nombre%% closed*}"
          case "$nombre" in
            sim9-*) ( main_falso_relanzar "$nombre" ) & ;;
          esac
        fi
        ;;
    esac
    ;;
  *) ;;
esac
exit 0
