#!/bin/bash
# corrida/mostrar-terminal.sh (Fase 14, Task 4). Abre Terminal sobre la
# sesion tmux del carril con un programa AppleScript fijo: la sesion
# validada viaja como unico argv, jamas interpolada (ni briefs, rutas,
# transcripts o respuestas del worker llegan al programa). La negacion de
# automatizacion es visibilidad degraded con el attach exacto, nunca fallo
# del worker.
# Uso: corrida.sh mostrar-terminal <id> <carril>
corrida_mostrar_terminal() {
  [ "$#" -eq 2 ] || { echo "uso: corrida.sh mostrar-terminal <id> <carril>" >&2; return 2; }
  local id="$1" carril="$2"
  corrida_id_valido "$id" || { echo "mostrar-terminal: id invalido: $id" >&2; return 2; }
  corrida_id_valido "$carril" || { echo "mostrar-terminal: carril invalido: $carril" >&2; return 2; }
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  local sesion; sesion="$(json_campo "$reg" "carriles.$carril.session")"
  case "$sesion" in ''|*[!A-Za-z0-9_-]*)
    echo "mostrar-terminal: el carril $carril no trae sesion valida" >&2; return 1;; esac
  # El binario es el resuelto por lib.sh (TMUX_BIN), no uno fijo: instalado y
  # repo comparten codigo pero no la ruta. La sesion validada sigue viajando
  # como unico argv, jamas interpolada en el programa.
  local tmx="${TMUX_BIN:-/opt/homebrew/bin/tmux}"
  local attach="$tmx attach -t =$sesion"
  local osa="${OSASCRIPT_BIN:-/usr/bin/osascript}"
  local programa='on run argv
tell application "Terminal"
activate
do script "'"$tmx"' attach -t =" & (item 1 of argv)
end tell
end run'
  local estado="visible"
  "$osa" -e "$programa" "$sesion" >/dev/null 2>&1 || estado="degraded"
  if ! lock_tomar "$reg"; then
    echo "mostrar-terminal: lock del registro de $id no cede" >&2; return 1
  fi
  CORR_C="$carril" CORR_E="$estado" CORR_A="$attach" registro_escribir "$reg" "
d['carriles'][os.environ['CORR_C']]['visibility']={'state':os.environ['CORR_E'],
'attach_command':os.environ['CORR_A']}" \
    || { lock_soltar "$reg"; echo "mostrar-terminal: no se pudo guardar visibilidad" >&2; return 1; }
  lock_soltar "$reg"
  printf '%s\n' "$estado"
}
