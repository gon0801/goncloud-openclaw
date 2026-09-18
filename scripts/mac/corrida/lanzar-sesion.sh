#!/bin/bash
# corrida/lanzar-sesion.sh (9.2).
# lanzar-sesion <id> <rol> <token> <dir> [--nombre <s>] [--encargo <archivo>]
# Marca ANTES del primer send-keys; comprueba has-session y barra; Enter verificado.
corrida_lanzar_sesion() {
  local id="$1" rol="$2" token="$3" dir="$4"; shift 4
  local nombre="$token-$id" encargo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --nombre) nombre="$2"; shift 2;;
      --encargo) encargo="$2"; shift 2;;
      *) echo "lanzar-sesion: flag desconocido $1" >&2; return 2;;
    esac
  done
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  local tabla; tabla="$(json_campo "$reg" cli_modos)"
  local fila; fila="$(tsv_fila "$tabla" "$token")"
  [ -n "$fila" ] || { echo "sin fila de modos para $token" >&2; return 1; }
  local binario flag barra
  binario="$(printf '%s' "$fila" | cut -d'|' -f1)"
  flag="$(printf '%s' "$fila" | cut -d'|' -f2)"
  barra="$(printf '%s' "$fila" | cut -d'|' -f3)"
  local bin
  bin="$(bash -c "PATH=$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:\$PATH; command -v $binario" 2>/dev/null)" \
    || { echo "binario no arranca: $binario" >&2; return 1; }
  [ -d "$dir" ] || { echo "sin directorio: $dir" >&2; return 1; }
  "$TMUX_BIN" has-session -t "$nombre" 2>/dev/null && { echo "la sesion ya existe: $nombre" >&2; return 1; }
  local embebido="PATH=$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH"
  "$TMUX_BIN" new-session -d -s "$nombre" -x 200 -y 50 -c "$dir" "$embebido $bin $flag" >&2 || return 1
  "$TMUX_BIN" has-session -t "$nombre" 2>/dev/null || { echo "la sesion murio al arrancar" >&2; return 1; }
  # La marca ocurre ANTES del primer send-keys (el orden lo vigila la prueba con el log del shim).
  "$TMUX_BIN" set-environment -t "$nombre" OPENCLAW_WATCH 1 || return 1
  sleep 2
  local pantalla
  pantalla="$("$TMUX_BIN" capture-pane -p -t "$nombre" 2>/dev/null)" || return 1
  printf '%s' "$pantalla" | grep -qF "$barra" || { echo "la barra no trae $barra" >&2; return 1; }
  if [ -n "$encargo" ]; then
    [ -f "$encargo" ] || { echo "sin encargo: $encargo" >&2; return 1; }
    local texto; texto="$(cat "$encargo")"
    local escrito despues
    "$TMUX_BIN" send-keys -t "$nombre" -l "$texto" || return 1
    sleep 1
    escrito="$("$TMUX_BIN" capture-pane -p -t "$nombre" 2>/dev/null)"
    "$TMUX_BIN" send-keys -t "$nombre" Enter || return 1
    sleep 2
    despues="$("$TMUX_BIN" capture-pane -p -t "$nombre" 2>/dev/null)"
    if [ "$escrito" = "$despues" ]; then
      # La caja no se vacio: el Enter se trago; un reintento antes de declarar.
      "$TMUX_BIN" send-keys -t "$nombre" Enter || return 1
      sleep 2
    fi
  fi
  CORR_SES_NOMBRE="$nombre" CORR_SES_ROL="$rol" CORR_SES_CLI="$token" CORR_SES_DIR="$dir" CORR_REG="$reg" python3 -c "
import json,os
r=os.environ['CORR_REG']
d=json.load(open(r))
d['sesiones'].append({'nombre':os.environ['CORR_SES_NOMBRE'],'rol':os.environ['CORR_SES_ROL'],
'cli':os.environ['CORR_SES_CLI'],'dueno':'lead','dir':os.environ['CORR_SES_DIR']})
open(r,'w').write(json.dumps(d,indent=1)+chr(10))
" || return 1
  echo "$nombre"
}
