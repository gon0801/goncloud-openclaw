#!/bin/bash
# corrida/adaptador.sh (Fase 14, Task 3). Contrato unico de ciclo de vida
# para las seis CLIs nativas: la argv sale de ramas case cerradas
# mas workers.v1.json (placeholders sustituidos en python) y se ejecuta como
# parametros posicionales de tmux new-session (tmux no pasa por shell con
# args separados: medido), jamas concatenada en un texto shell.
# Uso: corrida.sh adaptador <health|start|deliver|inspect|resume|stop> <id> <carril> <worker> <sesion> [...]
corrida_adaptador() {
  [ "$#" -ge 5 ] || { echo "uso: corrida.sh adaptador <accion> <id> <carril> <worker> <sesion> ..." >&2; return 2; }
  local accion="$1" id="$2" carril="$3" worker="$4" sesion="$5"
  shift 5
  case "$accion" in
    health)  adaptador_health "$worker" ;;
    start)   adaptador_start "$id" "$carril" "$worker" "$sesion" "$@" ;;
    deliver) adaptador_deliver "$sesion" "$@" ;;
    inspect) adaptador_inspect "$worker" "$sesion" ;;
    resume)  adaptador_resume "$id" "$carril" "$worker" "$sesion" "$@" ;;
    stop)    adaptador_stop "$sesion" ;;
    *) echo "adaptador: accion invalida: $accion" >&2; return 2 ;;
  esac
}

adaptador_sesion_valida() { # $1 sesion; rc 2 + diagnostico si no pasa
  case "$1" in ''|*[!A-Za-z0-9_-]*)
    echo "adaptador: sesion invalida: $1" >&2; return 2;; esac
  return 0
}

adaptador_rol_de_modo() { # $1 modo persistido; stdout write|review; rc 1 si no
  case "$1" in
    write) printf 'write\n';;
    read-only) printf 'review\n';;
    *) return 1;;
  esac
}

# health(worker) -> available | limited | unauthenticated | broken.
# Corre la argv health del registro con tope; la salida manda sobre el rc
# (una CLI que avisa auth/cuota saliendo 0 sigue sin-auth/limitada; un bloqueo
# avisado saliendo 0 sigue roto: mismo orden y minusculas que corrida-worker.py,
# auth antes que quota, patrones en minuscula).

adaptador_health() {
  local worker="$1" bin rc=0 sal pant estado
  worker_atributo "$worker" binary >/dev/null \
    || { echo "adaptador: worker desconocido: $worker" >&2; return 1; }
  bin="$(resolver_bin_worker "$worker")" || { echo "broken"; return 0; }
  local argvf; argvf="$(mktemp)" || return 1
  worker_argv "$worker" health "" "" "" "" >"$argvf" \
    || { rm -f "$argvf"; echo "broken"; return 0; }
  set --
  while IFS= read -r l; do set -- "$@" "$l"; done <"$argvf"
  rm -f "$argvf"
  sal="$(con_tope "${CORRIDA_ADAPTADOR_TOPE:-15}" "$bin" "$@" 2>&1)" || rc=$?
  pant="$(mktemp)" || return 1
  printf '%s' "$sal" >"$pant"
  estado="$(WREG="$(corrida_workers_registry)" WID="$worker" WPANT="$pant" WRC="$rc" python3 -c "
import json,os
t=open(os.environ['WPANT']).read().lower()
r=json.load(open(os.environ['WREG']))
w=[x for x in r['workers'] if x['id']==os.environ['WID']][0]
def hay(ps): return any(p and p.lower() in t for p in ps)
if hay(w.get('auth_patterns',[])): print('unauthenticated')
elif hay(w.get('quota_patterns',[])): print('limited')
elif hay(w.get('blocked_patterns',[])): print('broken')
elif os.environ['WRC']=='0': print('available')
else: print('broken')

" 2>/dev/null)" || estado=""
  rm -f "$pant"
  [ -n "$estado" ] || { echo "adaptador: no se pudo clasificar la salud de $worker" >&2; return 1; }
  printf '%s\n' "$estado"
}

# Crea la sesion tmux con argv exacta (sin shell de por medio).
# El PATH va embebido via /usr/bin/env (misma lista que lanzar-sesion.sh:
# lanzar_sesion_crear): el server tmux arranca con PATH minimo y el shebang
# de env-node del binario muere sin node a la vista (medido 2026-09-26:
# server con PATH minimo + zcode real => env node ausente; con el PATH
# embebido vive). Cubre start y resume: ambos pasan por aqui. env en
# absoluta porque el server minimo tampoco lo resolveria por PATH.
adaptador_nueva_sesion() { # $1 sesion $2 worktree $3 bin $4 argvf
  local sesion="$1" wt="$2" bin="$3" argvf="$4"
  local camino="$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH"
  set --
  while IFS= read -r l; do set -- "$@" "$l"; done <"$argvf"
  "$TMUX_BIN" new-session -d -s "$sesion" -x 200 -y 50 -c "$wt" /usr/bin/env "PATH=$camino" "$bin" "$@"
}

# Espera la barra de la tabla de modos del registro (token = binario).
# unknown/--/vacia es "sin medir" (misma convencion que preflight y responder):
# buscarla literal quema los 10 s y mata la sesion; se rechaza de inmediato.
adaptador_esperar_barra() { # $1 reg $2 sesion $3 binario; rc 1 + sesion muerta
  local reg="$1" sesion="$2" binario="$3" tabla fila barra pantalla espera=0
  tabla="$(json_campo "$reg" cli_modos)"
  fila="$(tsv_fila "$tabla" "$binario")"
  barra="$(printf '%s' "$fila" | cut -d'|' -f3)"
  case "$barra" in unknown|--)
    echo "adaptador: sin barra medida para $binario" >&2; return 1;; esac
  [ -n "$barra" ] || { echo "adaptador: sin barra para $binario" >&2; return 1; }
  pantalla=""
  while [ "$espera" -lt 10 ]; do
    pantalla="$("$TMUX_BIN" capture-pane -p -t "=$sesion:" 2>/dev/null)" || pantalla=""
    printf '%s' "$pantalla" | grep -qF -- "$barra" && return 0
    sleep 1; espera=$((espera+1))
  done
  return 1
}

# Persiste worker,harness,provider,reported_model,session en el carril,
# bajo lock, antes de la primera entrega.
adaptador_registrar_sesion() { # $1 reg $2 carril $3 worker $4 sesion [$5 brief]
  local reg="$1" carril="$2" worker="$3" sesion="$4" brief="${5:-}"
  local harness provider
  harness="$(worker_atributo "$worker" harness)" || return 1
  provider="$(worker_atributo "$worker" provider)" || return 1
  lock_tomar "$reg" || return 1
  CORR_C="$carril" CORR_W="$worker" CORR_H="$harness" CORR_P="$provider" \
  CORR_S="$sesion" CORR_B="$brief" registro_escribir "$reg" "
c=d.setdefault('carriles',{}).setdefault(os.environ['CORR_C'],{})
c.update({'worker':os.environ['CORR_W'],'harness':os.environ['CORR_H'],
'provider':os.environ['CORR_P'],
'reported_model':c.get('reported_model','unknown'),
'session':os.environ['CORR_S'],'estado':'activo'})
b=os.environ['CORR_B']
if b: c['brief']=b
" || { lock_soltar "$reg"; return 1; }
  lock_soltar "$reg"
}

# El worktree recibido debe ser el reservado del carril (canonicos): un
# llamador que pase el repo principal o el worktree de otro carril obtendria
# una sesion "del carril X" escribiendo en otro sitio. rc 1 si difieren.
adaptador_worktree_de_carril() { # $1 reg $2 carril $3 worktree
  local reg="$1" carril="$2" wt="$3" res dado canon
  res="$(json_campo "$reg" "carriles.$carril.worktree")"
  dado="$(CDPATH= cd -P -- "$wt" 2>/dev/null && pwd)" || dado=""
  canon="$(CDPATH= cd -P -- "$res" 2>/dev/null && pwd)" || canon=""
  [ -n "$canon" ] && [ -n "$dado" ] && [ "$dado" = "$canon" ]
}

# start(run, lane, worktree, brief) -> session. La sesion existente se niega
# (no se pisa); resume es el camino idempotente.
adaptador_start() {
  [ "$#" -ge 5 ] || { echo "adaptador start: faltan argumentos" >&2; return 2; }
  local id="$1" carril="$2" worker="$3" sesion="$4" wt="$5" brief="${6:-}"
  corrida_id_valido "$id" || { echo "adaptador: id invalido: $id" >&2; return 2; }
  corrida_id_valido "$carril" || { echo "adaptador: carril invalido: $carril" >&2; return 2; }
  adaptador_sesion_valida "$sesion" || return 2
  worker_atributo "$worker" binary >/dev/null \
    || { echo "adaptador: worker desconocido: $worker" >&2; return 1; }
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  local rol; rol="$(adaptador_rol_de_modo "$(json_campo "$reg" "carriles.$carril.mode")")" \
    || { echo "adaptador: el carril $carril no trae modo persistido (write|read-only)" >&2; return 1; }
  local bin; bin="$(resolver_bin_worker "$worker")" \
    || { echo "adaptador: sin ejecutable para $worker" >&2; return 1; }
  [ -d "$wt" ] || { echo "adaptador: sin worktree: $wt" >&2; return 1; }
  adaptador_worktree_de_carril "$reg" "$carril" "$wt" \
    || { echo "adaptador: el worktree no es el reservado del carril $carril" >&2; return 1; }
  [ -n "${TMUX_BIN:-}" ] || { echo "adaptador: tmux no disponible" >&2; return 1; }
  "$TMUX_BIN" has-session -t "=$sesion" 2>/dev/null \
    && { echo "adaptador: la sesion ya existe: $sesion" >&2; return 1; }
  local argvf; argvf="$(mktemp)" || return 1
  worker_argv "$worker" "start:$rol" "$wt" "$brief" "$sesion" "$sesion" >"$argvf" \
    || { rm -f "$argvf"; echo "adaptador: sin comando start:$rol para $worker" >&2; return 1; }
  adaptador_nueva_sesion "$sesion" "$wt" "$bin" "$argvf" || {
    rm -f "$argvf"; echo "adaptador: no se pudo crear la sesion $sesion" >&2; return 1; }
  rm -f "$argvf"
  "$TMUX_BIN" has-session -t "=$sesion" 2>/dev/null \
    || { echo "adaptador: la sesion murio al arrancar" >&2; return 1; }
  adaptador_esperar_barra "$reg" "$sesion" "$(worker_atributo "$worker" binary)" \
    || { "$TMUX_BIN" kill-session -t "=$sesion" 2>/dev/null
         echo "adaptador: la barra no aparecio en $sesion" >&2; return 1; }
  adaptador_registrar_sesion "$reg" "$carril" "$worker" "$sesion" "$brief" \
    || { "$TMUX_BIN" kill-session -t "=$sesion" 2>/dev/null
         echo "adaptador: no se pudo registrar la sesion" >&2; return 1; }
  printf '%s\n' "$sesion"
}

# deliver(session, brief) -> accepted | blocked. Un exit 0 de send-keys no
# prueba la entrega: la caja debe vaciarse (reintento unico del Enter, como
# lanzar-sesion). Bloqueada no mata: el llamador decide (relevo en Task 5).
adaptador_deliver() {
  [ "$#" -ge 2 ] || { echo "adaptador deliver: faltan argumentos" >&2; return 2; }
  local sesion="$1" brief="$2"
  adaptador_sesion_valida "$sesion" || return 2
  [ -n "${TMUX_BIN:-}" ] || { echo "adaptador: tmux no disponible" >&2; return 1; }
  [ -f "$brief" ] || { echo "adaptador: sin brief: $brief" >&2; return 1; }
  "$TMUX_BIN" has-session -t "=$sesion" 2>/dev/null || { echo "blocked"; return 0; }
  local texto escrito despues despues2
  texto="$(cat "$brief")"
  "$TMUX_BIN" send-keys -t "=$sesion:" -l -- "$texto" 2>/dev/null || { echo "blocked"; return 0; }
  sleep 1
  escrito="$("$TMUX_BIN" capture-pane -p -t "=$sesion:" 2>/dev/null)" || { echo "blocked"; return 0; }
  "$TMUX_BIN" send-keys -t "=$sesion:" Enter 2>/dev/null || { echo "blocked"; return 0; }
  sleep 2
  despues="$("$TMUX_BIN" capture-pane -p -t "=$sesion:" 2>/dev/null)" || { echo "blocked"; return 0; }
  if [ "$escrito" = "$despues" ]; then
    "$TMUX_BIN" send-keys -t "=$sesion:" Enter 2>/dev/null || { echo "blocked"; return 0; }
    sleep 2
    despues2="$("$TMUX_BIN" capture-pane -p -t "=$sesion:" 2>/dev/null)" || { echo "blocked"; return 0; }
    [ "$escrito" = "$despues2" ] && { echo "blocked"; return 0; }
  fi
  echo "accepted"
}

# inspect(session) -> running | waiting | complete | failed | quota | auth-vencida.
# Lee la pantalla: el silencio es running, jamas complete. Cuota y auth
# vencida salen de los patrones del registro (disparan el relevo de Task 5);
# la sesion muerta es failed.
adaptador_inspect() {
  local worker="$1" sesion="$2"
  adaptador_sesion_valida "$sesion" || return 2
  worker_atributo "$worker" binary >/dev/null \
    || { echo "adaptador: worker desconocido: $worker" >&2; return 1; }
  [ -n "${TMUX_BIN:-}" ] || { echo "adaptador: tmux no disponible" >&2; return 1; }
  local pant; pant="$(mktemp)" || return 1
  if ! "$TMUX_BIN" capture-pane -p -t "=$sesion:" >"$pant" 2>/dev/null; then
    rm -f "$pant"; echo "failed"; return 0
  fi
  local estado
  estado="$(WREG="$(corrida_workers_registry)" WID="$worker" WPANT="$pant" python3 -c "
import json,os
t=open(os.environ['WPANT']).read().lower()
r=json.load(open(os.environ['WREG']))
w=[x for x in r['workers'] if x['id']==os.environ['WID']][0]
def hay(ps): return any(p and p.lower() in t for p in ps)
if hay(w.get('quota_patterns',[])): print('quota')
elif hay(w.get('auth_patterns',[])): print('auth-vencida')
elif 'adaptador-marca: fallo' in t: print('failed')
elif 'adaptador-marca: completo' in t: print('complete')
elif 'adaptador-marca: esperando' in t: print('waiting')
else: print('running')
" 2>/dev/null)" || estado=""
  rm -f "$pant"
  [ -n "$estado" ] || { echo "adaptador: no se pudo inspeccionar $sesion" >&2; return 1; }
  printf '%s\n' "$estado"
}

# Resume que muere tras matar la sesion viva: persiste failed sin borrar el
# historial (worker, sesion y demas campos quedan). Best effort bajo el lock
# del run: si el lock no cede, el llamador igual devuelve unavailable.
# Cierra el hueco CodeRabbit ronda 3 (relanzamiento o barra fallidos tras
# el kill dejaban el carril activo con sesion huerfana).
adaptador_carril_fallar() { # $1 reg $2 carril
  local reg="$1" carril="$2"
  lock_tomar "$reg" 2>/dev/null || return 0
  CORR_C="$carril" registro_escribir "$reg" "
c=d.get('carriles',{}).get(os.environ['CORR_C'])
if c is not None: c['estado']='failed'" 2>/dev/null || true
  lock_soltar "$reg"
}

# resume(session) -> resumed | unavailable. Relanza con la argv resume:<rol>
# del registro; resuelve el binario ANTES de tocar la sesion viva.
adaptador_resume() {
  [ "$#" -ge 6 ] || { echo "adaptador resume: faltan argumentos" >&2; return 2; }
  local id="$1" carril="$2" worker="$3" sesion="$4" wt="$5" sid="$6"
  corrida_id_valido "$id" || { echo "adaptador: id invalido: $id" >&2; return 2; }
  corrida_id_valido "$carril" || { echo "adaptador: carril invalido: $carril" >&2; return 2; }
  adaptador_sesion_valida "$sesion" || return 2
  worker_atributo "$worker" binary >/dev/null \
    || { echo "adaptador: worker desconocido: $worker" >&2; return 1; }
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  local rol; rol="$(adaptador_rol_de_modo "$(json_campo "$reg" "carriles.$carril.mode")")" \
    || { echo "unavailable"; return 0; }
  local bin; bin="$(resolver_bin_worker "$worker")" || { echo "unavailable"; return 0; }
  [ -d "$wt" ] || { echo "unavailable"; return 0; }
  adaptador_worktree_de_carril "$reg" "$carril" "$wt" \
    || { echo "unavailable"; return 0; }
  [ -n "${TMUX_BIN:-}" ] || { echo "adaptador: tmux no disponible" >&2; return 1; }
  local argvf; argvf="$(mktemp)" || return 1
  worker_argv "$worker" "resume:$rol" "$wt" "" "$sid" "$sesion" >"$argvf" \
    || { rm -f "$argvf"; echo "unavailable"; return 0; }
  "$TMUX_BIN" kill-session -t "=$sesion" 2>/dev/null
  adaptador_nueva_sesion "$sesion" "$wt" "$bin" "$argvf" || {
    rm -f "$argvf"; adaptador_carril_fallar "$reg" "$carril"; echo "unavailable"; return 0; }
  rm -f "$argvf"
  adaptador_esperar_barra "$reg" "$sesion" "$(worker_atributo "$worker" binary)" \
    || { "$TMUX_BIN" kill-session -t "=$sesion" 2>/dev/null; adaptador_carril_fallar "$reg" "$carril"; echo "unavailable"; return 0; }
  adaptador_registrar_sesion "$reg" "$carril" "$worker" "$sesion" \
    || { "$TMUX_BIN" kill-session -t "=$sesion" 2>/dev/null; adaptador_carril_fallar "$reg" "$carril"; echo "unavailable"; return 0; }

  echo "resumed"
}

# stop(session) -> stopped | already_stopped. Repetir converge.
adaptador_stop() {
  local sesion="$1"
  adaptador_sesion_valida "$sesion" || return 2
  [ -n "${TMUX_BIN:-}" ] || { echo "adaptador: tmux no disponible" >&2; return 1; }
  if "$TMUX_BIN" has-session -t "=$sesion" 2>/dev/null; then
    "$TMUX_BIN" kill-session -t "=$sesion" 2>/dev/null
    echo "stopped"
  else
    echo "already_stopped"
  fi
}
