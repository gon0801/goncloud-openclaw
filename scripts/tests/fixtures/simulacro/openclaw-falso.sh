#!/bin/bash
# Doble de OPENCLAW_BIN para --ensayo (9.9, piezas a-c). Contesta lo que el
# arnes necesita: cron list (destino falso), gateway call
# runbook.progress.list/set/status, gateway call runbook.progress.decide
# (corre el MODULO PURO real via decide-puro.mjs, no una respuesta
# inventada), message send (con preambulo antes del JSON, como un CLI real
# que imprime avisos), browser tabs (mecanismo del navegador que preflight
# prueba), system event (el vigia doblado; "X closed" hace de "main falso":
# relanza esa sesion desde su propio registro, igual que main lo haria de
# verdad al recibir el mismo evento). Cualquier otra cosa sale 0 sin texto:
# nunca se cuelga.
#
# Env:
#   SIM9_LLAMADAS   si esta puesto, cada invocacion se anota ahi (para
#                   pruebas que necesiten confirmar que algo se llamo)
#   SIM9_DESTINO    destino falso que "cron list" resuelve para
#                   cuotas-proveedores (def. DESTINO-FALSO-SIM9)
#   SIM9_MSG_ID     id que "message send" devuelve (def. 9001); vacio =
#                   responde sin messageId (para probar la fila NO FUNCIONA)
#   SIM9_SIN_MAIN=1 no relanza nada en "system event ... closed" (para medir
#                   el caso 5/6 sin relanzamiento real, si algun dia hace
#                   falta); por defecto SI relanza.
set -u
DESTINO="${SIM9_DESTINO:-DESTINO-FALSO-SIM9}"
MSGID="${SIM9_MSG_ID-9001}"
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
  *"cron list"*)
    printf '{"jobs":[{"name":"cuotas-proveedores","delivery":{"to":"%s"}}]}' "$DESTINO"
    ;;
  *"gateway call runbook.progress.list"*)
    printf '{"ok":true,"result":{"documentos":[]}}'
    ;;
  *"gateway call runbook.progress.set"*)
    printf '{"ok":true}'
    ;;
  *"gateway call runbook.progress.decide"*)
    printf '%s' "$PARAMS" | node "$AQUI/decide-puro.mjs" 2>>"${SIM9_LLAMADAS:-/dev/null}"
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
        if [ "${SIM9_SIN_MAIN:-0}" != "1" ]; then
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
