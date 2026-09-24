#!/bin/sh
# Doble de OPENCLAW_BIN para --ensayo (9.9, pieza a). Contesta lo que la
# pieza (a) del arnes necesita: cron list (destino falso), gateway call
# runbook.progress.list/set, gateway call status, message send (con
# preambulo antes del JSON, como un CLI real que imprime avisos), browser
# tabs (mecanismo del navegador que preflight prueba), system event (el
# vigia doblado). Cualquier otra cosa sale 0 sin texto: nunca se cuelga.
#
# Env:
#   SIM9_LLAMADAS   si esta puesto, cada invocacion se anota ahi (para
#                   pruebas que necesiten confirmar que algo se llamo)
#   SIM9_DESTINO    destino falso que "cron list" resuelve para
#                   cuotas-proveedores (def. DESTINO-FALSO-SIM9)
#   SIM9_MSG_ID     id que "message send" devuelve (def. 9001); vacio =
#                   responde sin messageId (para probar la fila NO FUNCIONA)
set -u
DESTINO="${SIM9_DESTINO:-DESTINO-FALSO-SIM9}"
MSGID="${SIM9_MSG_ID-9001}"
[ -n "${SIM9_LLAMADAS:-}" ] && printf '%s\n' "openclaw $*" >> "$SIM9_LLAMADAS"

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
    ;;
  *) ;;
esac
exit 0
