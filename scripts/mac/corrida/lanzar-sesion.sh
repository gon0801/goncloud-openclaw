#!/bin/bash
# corrida/lanzar-sesion.sh (9.2).
# lanzar-sesion <id> <rol> <token> <dir> [--nombre <s>] [--encargo <archivo>]
# Marca ANTES del primer send-keys; comprueba has-session y barra (sondeo hasta 10 s);
# Enter verificado: si la caja no se vacio tras el reintento, falla y mata la sesion.
corrida_lanzar_sesion() {
  local id="$1" rol="$2" token="$3" dir="$4"; shift 4
  corrida_id_valido "$id" || { echo "lanzar-sesion: id invalido: $id" >&2; return 2; }
  local nombre="$token-$id" encargo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --nombre|--encargo)
        [ $# -ge 2 ] || { echo "lanzar-sesion: $1 sin valor" >&2; return 2; };; esac
    case "$1" in
      --nombre) nombre="$2"; shift 2;;
      --encargo) encargo="$2"; shift 2;;
      *) echo "lanzar-sesion: flag desconocido $1" >&2; return 2;;
    esac
  done
  case "$nombre" in ''|*[!A-Za-z0-9_-]*)
    echo "lanzar-sesion: nombre invalido (solo letras, numeros, - y _): $nombre" >&2; return 2;; esac
  case "$rol" in lead|carril) ;; *)
    echo "lanzar-sesion: rol fuera del conjunto (lead o carril): $rol" >&2; return 2;; esac
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  local estado; estado="$(json_campo "$reg" estado)"
  [ "$estado" = "abierta" ] || { echo "lanzar-sesion: la corrida $id no esta abierta (estado: $estado)" >&2; return 1; }
  local tabla; tabla="$(json_campo "$reg" cli_modos)"
  local fila; fila="$(tsv_fila "$tabla" "$token")"
  [ -n "$fila" ] || { echo "sin fila de modos para $token" >&2; return 1; }
  local binario flag barra
  binario="$(printf '%s' "$fila" | cut -d'|' -f1)"
  flag="$(printf '%s' "$fila" | cut -d'|' -f2)"
  barra="$(printf '%s' "$fila" | cut -d'|' -f3)"
  [ -n "$barra" ] || { echo "barra vacia en la tabla para $token" >&2; return 1; }
  flag_de_tabla "$flag" || return 1
  local bin
  bin="$(bin_de_tabla "$binario")" || return 1
  [ -d "$dir" ] || { echo "sin directorio: $dir" >&2; return 1; }
  "$TMUX_BIN" has-session -t "=$nombre" 2>/dev/null && { echo "la sesion ya existe: $nombre" >&2; return 1; }
  local embebido="PATH=\"$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH\""
  "$TMUX_BIN" new-session -d -s "$nombre" -x 200 -y 50 -c "$dir" "$embebido $bin $flag" >&2 || return 1
  "$TMUX_BIN" has-session -t "=$nombre" 2>/dev/null || { echo "la sesion murio al arrancar" >&2; return 1; }
  # La marca ocurre ANTES del primer send-keys (el orden lo vigila la prueba con el log del shim).
  "$TMUX_BIN" set-environment -t "=$nombre" OPENCLAW_WATCH 1 \
    || { echo "no se pudo marcar la sesion" >&2; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
  # Todo fallo a partir de aqui mata la sesion: cerrar solo desmarca lo que registro.
  local pantalla espera=0
  pantalla=""
  while [ "$espera" -lt 10 ]; do
    pantalla="$("$TMUX_BIN" capture-pane -p -t "=$nombre:" 2>/dev/null)"
    printf '%s' "$pantalla" | grep -qF -- "$barra" && break
    sleep 1; espera=$((espera+1))
  done
  printf '%s' "$pantalla" | grep -qF -- "$barra" \
    || { echo "la barra no trae $barra" >&2; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
  if [ -n "$encargo" ]; then
    [ -f "$encargo" ] || { echo "sin encargo: $encargo" >&2; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
    local texto escrito despues despues2
    texto="$(cat "$encargo")"
    "$TMUX_BIN" send-keys -t "=$nombre:" -l -- "$texto" \
      || { echo "no se pudo escribir el encargo" >&2; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
    sleep 1
    escrito="$("$TMUX_BIN" capture-pane -p -t "=$nombre:" 2>/dev/null)"
    "$TMUX_BIN" send-keys -t "=$nombre:" Enter \
      || { echo "no se pudo mandar el Enter" >&2; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
    sleep 2
    despues="$("$TMUX_BIN" capture-pane -p -t "=$nombre:" 2>/dev/null)"
    if [ "$escrito" = "$despues" ]; then
      # La caja no se vacio: el Enter se trago; UN reintento, re-verificado, antes de declarar.
      "$TMUX_BIN" send-keys -t "=$nombre:" Enter \
        || { echo "no se pudo reintentar el Enter" >&2; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
      sleep 2
      despues2="$("$TMUX_BIN" capture-pane -p -t "=$nombre:" 2>/dev/null)"
      [ "$escrito" = "$despues2" ] \
        && { echo "la caja no se vacio tras reintentar el Enter" >&2; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
    fi
  fi
  # Anotar bajo lock con el estado RE-verificado: si la corrida se cerro mientras
  # esta sesion nacia, no entra a un registro muerto — se desmarca y se mata.
  if ! lock_tomar "$reg"; then
    echo "lanzar-sesion: lock del registro de $id no cede; la sesion $nombre se retira" >&2
    "$TMUX_BIN" set-environment -t "=$nombre" -u OPENCLAW_WATCH 2>/dev/null
    "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null
    return 1
  fi
  if [ "$(json_campo "$reg" estado)" != "abierta" ]; then
    lock_soltar "$reg"
    echo "lanzar-sesion: la corrida $id se cerro mientras se lanzaba; la sesion $nombre se retira" >&2
    "$TMUX_BIN" set-environment -t "=$nombre" -u OPENCLAW_WATCH 2>/dev/null
    "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null
    return 1
  fi
  CORR_SES_NOMBRE="$nombre" CORR_SES_ROL="$rol" CORR_SES_CLI="$token" CORR_SES_DIR="$dir" \
    registro_escribir "$reg" "d['sesiones'].append({'nombre':os.environ['CORR_SES_NOMBRE'],
'rol':os.environ['CORR_SES_ROL'],'cli':os.environ['CORR_SES_CLI'],'dueno':'lead',
'dir':os.environ['CORR_SES_DIR']})" \
    || { lock_soltar "$reg"
         echo "no se pudo anotar la sesion en el registro" >&2; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
  lock_soltar "$reg"
  echo "$nombre"
}
