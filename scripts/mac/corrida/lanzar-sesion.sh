#!/bin/bash
# corrida/lanzar-sesion.sh (9.2, Fase 14 Task 3).
# lanzar-sesion <id> <rol> <token> <dir> [--nombre <s>] [--encargo <archivo>]
#               [--carril <lane> --worker <id>]
# Tres fases: crear (sesion tmux), marcar-registrar (marcas + barra, y en un
# carril worker/harness/provider/reported_model/session ANTES del primer
# send-keys), entregar (encargo con Enter verificado). Si la entrega falla en
# un carril, persiste failed y detiene la sesion sin borrar su historial.
# Sin --carril, el comportamiento legacy queda intacto.
corrida_lanzar_sesion() {
  local id="$1" rol="$2" token="$3" dir="$4"; shift 4
  corrida_id_valido "$id" || { echo "lanzar-sesion: id invalido: $id" >&2; return 2; }
  local nombre="$token-$id" encargo="" carril="" worker=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --nombre|--encargo|--carril|--worker)
        [ $# -ge 2 ] || { echo "lanzar-sesion: $1 sin valor" >&2; return 2; };; esac
    case "$1" in
      --nombre) nombre="$2"; shift 2;;
      --encargo) encargo="$2"; shift 2;;
      --carril) carril="$2"; shift 2;;
      --worker) worker="$2"; shift 2;;
      *) echo "lanzar-sesion: flag desconocido $1" >&2; return 2;;
    esac
  done
  case "$nombre" in ''|*[!A-Za-z0-9_-]*)
    echo "lanzar-sesion: nombre invalido (solo letras, numeros, - y _): $nombre" >&2; return 2;; esac
  case "$rol" in lead|carril) ;; *)
    echo "lanzar-sesion: rol fuera del conjunto (lead o carril): $rol" >&2; return 2;; esac
  if [ -n "$carril" ] || [ -n "$worker" ]; then
    corrida_id_valido "$carril" || { echo "lanzar-sesion: carril invalido: $carril" >&2; return 2; }
    [ -n "$worker" ] || { echo "lanzar-sesion: --carril requiere --worker" >&2; return 2; }
    worker_atributo "$worker" binary >/dev/null \
      || { echo "lanzar-sesion: worker desconocido: $worker" >&2; return 2; }
  fi
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
  # Fail-fast del carril (M1 ai-review): reserva y worktree se verifican
  # ANTES de crear la sesion; la CLI no spawnea en un directorio no
  # autorizado. Al exito el lock queda retenido: se suelta aqui; la
  # validacion autoritativa vive en lanzar_sesion_marcar.
  if [ -n "$carril" ]; then
    lanzar_sesion_validar_carril "$reg" "$carril" "$dir" "$id" || return 1
    lock_soltar "$reg"
  fi
  marcas_lock_tomar \
    || { echo "lanzar-sesion: lock global de marcas no cede" >&2; return 1; }

  lanzar_sesion_crear "$nombre" "$dir" "$bin" "$flag" \
    || { marcas_lock_soltar; return 1; }
  lanzar_sesion_marcar "$id" "$nombre" "$reg" "$carril" "$worker" "$barra" \
    || { marcas_lock_soltar; return 1; }
  if [ -n "$encargo" ]; then
    lanzar_sesion_entregar "$nombre" "$encargo" \
      || { [ -n "$carril" ] && lanzar_sesion_fallar "$reg" "$carril"
           "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; marcas_lock_soltar; return 1; }
  else
    marcas_lock_refrescar
  fi
  # Anotar bajo lock con el estado RE-verificado: si la corrida se cerro mientras
  # esta sesion nacia, no entra a un registro muerto — se desmarca y se mata.
  if ! lock_tomar "$reg"; then
    echo "lanzar-sesion: lock del registro de $id no cede; la sesion $nombre se retira" >&2
    [ -n "$carril" ] && lanzar_sesion_fallar "$reg" "$carril"
    "$TMUX_BIN" set-environment -t "=$nombre" -u OPENCLAW_WATCH 2>/dev/null
    "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null
    marcas_lock_soltar
    return 1
  fi
  if [ "$(json_campo "$reg" estado)" != "abierta" ]; then
    lock_soltar "$reg"
    echo "lanzar-sesion: la corrida $id se cerro mientras se lanzaba; la sesion $nombre se retira" >&2
    [ -n "$carril" ] && lanzar_sesion_fallar "$reg" "$carril"
    "$TMUX_BIN" set-environment -t "=$nombre" -u OPENCLAW_WATCH 2>/dev/null
    "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null
    marcas_lock_soltar
    return 1
  fi
  CORR_SES_NOMBRE="$nombre" CORR_SES_ROL="$rol" CORR_SES_CLI="$token" CORR_SES_DIR="$dir" \
    registro_escribir "$reg" "d['sesiones'].append({'nombre':os.environ['CORR_SES_NOMBRE'],
'rol':os.environ['CORR_SES_ROL'],'cli':os.environ['CORR_SES_CLI'],'dueno':'lead',
'dir':os.environ['CORR_SES_DIR']})" \
    || { lock_soltar "$reg"
         echo "no se pudo anotar la sesion en el registro" >&2
         [ -n "$carril" ] && lanzar_sesion_fallar "$reg" "$carril"
         "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; marcas_lock_soltar; return 1; }
  lock_soltar "$reg"
  marcas_lock_soltar
  echo "$nombre"
}

# Fase crear: sesion tmux con la CLI de la tabla. Todo fallo a partir de
# aqui mata la sesion: cerrar solo desmarca lo que registro.
lanzar_sesion_crear() { # $1 nombre $2 dir $3 bin $4 flag
  local nombre="$1" dir="$2" bin="$3" flag="$4"
  local embebido="PATH=\"$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH\""
  "$TMUX_BIN" new-session -d -s "$nombre" -x 200 -y 50 -c "$dir" "$embebido $bin $flag" >&2 \
    || return 1
  "$TMUX_BIN" has-session -t "=$nombre" 2>/dev/null \
    || { echo "la sesion murio al arrancar" >&2; return 1; }
}

# Validacion del carril para lanzar-sesion (M1 ai-review): reserva completa
# (los 5 campos), estado reservado y dir == worktree reservado (canonicos).
# Sin escritura y sin matar sesiones. Contrato de lock: al EXITO devuelve
# con el lock del registro RETENIDO (el llamador escribe y suelta); al
# fallo lo suelta y devuelve 1 con el diagnostico ya impreso.
lanzar_sesion_validar_carril() { # $1 reg $2 carril $3 dir $4 id
  local reg="$1" carril="$2" dir="$3" id="$4"
  lock_tomar "$reg" \
    || { echo "lanzar-sesion: lock del registro de $id no cede" >&2; return 1; }
  # El carril lo prepara preparar-carril (reserva completa); lanzar jamas lo
  # crea: un carril inexistente o sin los 5 campos del validador es error duro
  # sin escritura parcial. Solo un reservado acepta sesion
  # (un activo ya tiene la suya; un failed ya conto su historia).
  CORR_C="$carril" CORR_REG="$reg" python3 -c "
import json,os,sys
d=json.load(open(os.environ['CORR_REG']))
c=None
for e in d.get('lanes') or []:
  if isinstance(e,dict) and e.get('id')==os.environ['CORR_C']: c=e; break
if not isinstance(c,dict): sys.exit(1)
for k in ('branch','worktree','base_remote_sha','owner','mode'):
  if not c.get(k): sys.exit(1)
if c.get('estado')!='reservado': sys.exit(2)
" 2>/dev/null; prc=$?
  if [ "$prc" -eq 2 ]; then
    lock_soltar "$reg"
    echo "lanzar-sesion: el carril $carril no esta reservado (estado distinto)" >&2
    return 1
  fi
  [ "$prc" -eq 0 ] \
    || { lock_soltar "$reg"
         echo "lanzar-sesion: el carril $carril no esta preparado (falta o sin reserva completa)" >&2; return 1; }
  # La sesion nace DENTRO del worktree reservado: el dir canonico debe ser
  # el worktree del carril. El repo principal o el worktree de otro carril
  # es error duro: el registro seguiria afirmando un aislamiento falso.
  local dir_canon wt_res wt_canon
  dir_canon="$(CDPATH= cd -P -- "$dir" 2>/dev/null && pwd)" || dir_canon=""
  wt_res="$(lane_campo "$reg" "$carril" worktree)"
  wt_canon="$(CDPATH= cd -P -- "$wt_res" 2>/dev/null && pwd)" || wt_canon=""
  if [ -z "$wt_canon" ] || [ "$dir_canon" != "$wt_canon" ]; then
    lock_soltar "$reg"
    echo "lanzar-sesion: $dir no es el worktree reservado del carril $carril" >&2
    return 1
  fi
}

# Fase marcar-registrar: dueno, marca ANTES del primer send-keys (el orden

# lo vigila la prueba con el log del shim), barra, y en un carril los datos
# del worker antes de entregar nada.
lanzar_sesion_marcar() { # $1 id $2 nombre $3 reg $4 carril $5 worker $6 barra
  local id="$1" nombre="$2" reg="$3" carril="$4" worker="$5" barra="$6"
  # Publicar el dueno antes de la marca cierra la ventana en que una reconciliacion
  # podria confundir este nombre reutilizado con una sesion de una corrida cerrada.
  "$TMUX_BIN" set-environment -t "=$nombre" OPENCLAW_WATCH_RUN "$id" \
    || { echo "no se pudo publicar el dueno de la sesion" >&2; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
  # La marca ocurre ANTES del primer send-keys (el orden lo vigila la prueba con el log del shim).
  "$TMUX_BIN" set-environment -t "=$nombre" OPENCLAW_WATCH 1 \
    || { echo "no se pudo marcar la sesion" >&2; "$TMUX_BIN" set-environment -t "=$nombre" -u OPENCLAW_WATCH_RUN 2>/dev/null; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
  local pantalla espera=0
  pantalla=""
  while [ "$espera" -lt 10 ]; do
    pantalla="$("$TMUX_BIN" capture-pane -p -t "=$nombre:" 2>/dev/null)"
    printf '%s' "$pantalla" | grep -qF -- "$barra" && break
    sleep 1; espera=$((espera+1))
  done
  marcas_lock_refrescar
  printf '%s' "$pantalla" | grep -qF -- "$barra" \
    || { echo "la barra no trae $barra" >&2; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
  if [ -n "$carril" ]; then
    local harness provider
    harness="$(worker_atributo "$worker" harness)"
    provider="$(worker_atributo "$worker" provider)"
    # Validacion autoritativa bajo el lock (lo retiene al exito): cierra el
    # TOCTOU entre el fail-fast y este registro. Al fallo, sesion muerta.
    lanzar_sesion_validar_carril "$reg" "$carril" "$dir" "$id" \
      || { "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }

    CORR_C="$carril" CORR_W="$worker" CORR_H="$harness" CORR_P="$provider" CORR_S="$nombre" \
      registro_escribir "$reg" "
c=None
for e in d.get('lanes') or []:
  if isinstance(e,dict) and e.get('id')==os.environ['CORR_C']: c=e; break
c.update({'worker':os.environ['CORR_W'],'harness':os.environ['CORR_H'],
'provider':os.environ['CORR_P'],
'reported_model':c.get('reported_model','unknown'),
'session':os.environ['CORR_S'],'estado':'activo'})" \
      || { lock_soltar "$reg"
           echo "lanzar-sesion: no se pudo registrar el carril" >&2; "$TMUX_BIN" kill-session -t "=$nombre" 2>/dev/null; return 1; }
    lock_soltar "$reg"
  fi
}

# Fase entregar: encargo con Enter verificado. No mata: el llamador decide
# (en un carril, persiste failed primero). Diagnosticos identicos al legacy.
lanzar_sesion_entregar() { # $1 nombre $2 encargo; 0 = entregado
  local nombre="$1" encargo="$2"
  [ -f "$encargo" ] || { echo "sin encargo: $encargo" >&2; return 1; }
  local texto escrito despues despues2
  texto="$(cat "$encargo")"
  "$TMUX_BIN" send-keys -t "=$nombre:" -l -- "$texto" \
    || { echo "no se pudo escribir el encargo" >&2; return 1; }
  sleep 1
  escrito="$("$TMUX_BIN" capture-pane -p -t "=$nombre:" 2>/dev/null)"
  "$TMUX_BIN" send-keys -t "=$nombre:" Enter \
    || { echo "no se pudo mandar el Enter" >&2; return 1; }
  sleep 2
  despues="$("$TMUX_BIN" capture-pane -p -t "=$nombre:" 2>/dev/null)"
  if [ "$escrito" = "$despues" ]; then
    # La caja no se vacio: el Enter se trago; UN reintento, re-verificado, antes de declarar.
    "$TMUX_BIN" send-keys -t "=$nombre:" Enter \
      || { echo "no se pudo reintentar el Enter" >&2; return 1; }
    sleep 2
    despues2="$("$TMUX_BIN" capture-pane -p -t "=$nombre:" 2>/dev/null)"
    [ "$escrito" = "$despues2" ] \
      && { echo "la caja no se vacio tras reintentar el Enter" >&2; return 1; }
  fi
  marcas_lock_refrescar
}

# Entrega fallida en un carril: persiste failed sin borrar el historial
# (worker, sesion y demas campos quedan). Best effort: el llamador igual
# detiene la sesion y devuelve 1.
lanzar_sesion_fallar() { # $1 reg $2 carril
  local reg="$1" carril="$2"
  lock_tomar "$reg" 2>/dev/null || return 0
  CORR_C="$carril" registro_escribir "$reg" "
for e in d.get('lanes') or []:
  if isinstance(e,dict) and e.get('id')==os.environ['CORR_C']: e['estado']='failed'; break" 2>/dev/null || true
  lock_soltar "$reg"
}
