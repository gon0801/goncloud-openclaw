#!/bin/bash
# corrida/reconciliar.sh (Fase 14, Task 5). reconciliar <id> [--observations F]:
# propone con corrida-worker.py (que no ejecuta nada), ejecuta UN efecto
# cerrado, registra el resultado y re-invoca hasta converger o al tope.
# Sin --observations construye tmux/worktree/remoto/PR/merge reales; la
# evidencia fina, el canary y los candidatos los provee el director.
# El lock se sostiene solo para leer y reducir, nunca durante un efecto
# externo (los adaptadores toman su propio lock en su subproceso). Un solo
# director reconcilia cada corrida: dos reconciliar concurrentes podrian
# proponer el mismo efecto externo antes de que el otro registre su intent.
# Uso: corrida.sh reconciliar <id> [--observations FILE]
corrida_reconciliar() {
  [ "$#" -ge 1 ] || { echo "uso: corrida.sh reconciliar <id> [--observations FILE]" >&2; return 2; }
  local id="$1"; shift
  local obs_given=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --observations) [ $# -ge 2 ] || { echo "reconciliar: --observations sin valor" >&2; return 2; }
        obs_given="$2"; shift 2;;
      *) echo "reconciliar: flag desconocido $1" >&2; return 2;;
    esac
  done
  corrida_id_valido "$id" || { echo "reconciliar: id invalido: $id" >&2; return 2; }
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  [ "$(json_campo "$reg" estado)" = "abierta" ] \
    || { echo "reconciliar: la corrida $id no esta abierta" >&2; return 1; }
  local pw="$AQUI/corrida-worker.py"
  [ -f "$pw" ] || { echo "reconciliar: sin plano de control: $pw" >&2; return 1; }
  local obs="$obs_given"
  if [ -z "$obs" ]; then
    obs="$(reconciliar_observar "$id" "$reg")" || return 1
  fi
  [ -f "$obs" ] || { echo "reconciliar: sin observaciones: $obs" >&2; return 1; }
  local pasada=0 ejecutados=0 out op lane args errf
  errf="$(mktemp)" || return 1
  while [ "$pasada" -lt 8 ]; do
    pasada=$((pasada+1))
    lock_tomar "$reg" || { rm -f "$errf"; echo "reconciliar: lock del registro de $id no cede" >&2; return 1; }
    if ! out="$(python3 "$pw" reconcile --record "$reg" --observations "$obs" 2>"$errf")"; then
      lock_soltar "$reg"
      echo "reconciliar: $(cat "$errf" 2>/dev/null)" >&2
      rm -f "$errf"
      return 1
    fi
    op="$(printf '%s' "$out" | python3 -c "import json,sys; e=json.load(sys.stdin)['effects']; print(e[0]['op'] if e else '')")"
    if [ -z "$op" ]; then
      lock_soltar "$reg"
      rm -f "$errf"
      printf 'CONVERGED %s\n' "$ejecutados"
      return 0
    fi
    lane="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['effects'][0]['lane'])")"
    args="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['effects'][0].get('args') or {}))")"
    if ! reconciliar_ejecutar "$id" "$reg" "$pw" "$op" "$lane" "$args"; then
      lock_soltar "$reg"
      rm -f "$errf"
      echo "reconciliar: no se pudo ejecutar $op $lane" >&2
      return 1
    fi
    lock_soltar "$reg"
    ejecutados=$((ejecutados+1))
    printf 'EXECUTED %s %s\n' "$op" "$lane"
  done
  rm -f "$errf"
  echo "reconciliar: sin converger tras 8 pasadas; el mundo cambio bajo los pies" >&2
  return 1
}

# Reduce un evento con sello de tiempo. BAJO LOCK del llamador.
reconciliar_reducir() { # $1 reg $2 pw $3 lane $4 kind $5 args-json
  local reg="$1" pw="$2" lane="$3" kind="$4" args="$5" evf at
  evf="$(mktemp)" || return 1
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)"
  CORR_LANE="$lane" CORR_KIND="$kind" CORR_ARGS="$args" CORR_AT="$at" CORR_EVF="$evf" python3 -c "
import json,os
ev=[{'lane':os.environ['CORR_LANE'],'kind':os.environ['CORR_KIND'],
'payload':json.loads(os.environ['CORR_ARGS'] or '{}'),'at':os.environ['CORR_AT']}]
open(os.environ['CORR_EVF'],'w').write(json.dumps(ev))
" || { rm -f "$evf"; return 1; }
  python3 "$pw" state reduce --record "$reg" --events "$evf" >/dev/null 2>&1
  local rc=$?
  rm -f "$evf"
  return "$rc"
}

# Ejecuta un efecto cerrado. Corre BAJO LOCK para los puros (record, handoff,
# mark); para los externos suelta el lock, ejecuta y re-toma para registrar.
# Devuelve 0 aunque el efecto externo falle: el fallo queda registrado y la
# siguiente pasada decide (reintento o relevo), no esta.
reconciliar_ejecutar() { # $1 id $2 reg $3 pw $4 op $5 lane $6 args-json
  local id="$1" reg="$2" pw="$3" op="$4" lane="$5" args="$6"
  case "$op" in
    record_observed)
      local kind payload
      kind="$(printf '%s' "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('kind',''))")"
      payload="$(printf '%s' "$args" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('payload') or {}))")"
      reconciliar_reducir "$reg" "$pw" "$lane" "observed.$kind" "$payload" || return 1
      ;;
    handoff_lane)
      reconciliar_reducir "$reg" "$pw" "$lane" "intent.handoff_lane" "$args" || return 1
      ;;
    mark_lane_stopped)
      reconciliar_reducir "$reg" "$pw" "$lane" "intent.mark_lane_stopped" "$args" || return 1
      reconciliar_reducir "$reg" "$pw" "$lane" "observed.lane.stopped" "$args" || return 1
      ;;
    resume_lane|stop_lane|launch_successor)
      lock_soltar "$reg"
      reconciliar_externo "$id" "$reg" "$pw" "$op" "$lane" "$args"
      local rc=$?
      lock_tomar "$reg" || return 1
      return "$rc"
      ;;
    *) echo "reconciliar: efecto desconocido: $op" >&2; return 1;;
  esac
  return 0
}

# Efecto con mundo exterior. SIN LOCK: los adaptadores toman el suyo.
reconciliar_externo() { # $1 id $2 reg $3 pw $4 op $5 lane $6 args-json
  local id="$1" reg="$2" pw="$3" op="$4" lane="$5" args="$6"
  local sesion worker wt brief res rc=0
  case "$op" in
    resume_lane)
      reconciliar_reducir_con_lock "$reg" "$pw" "$lane" "intent.resume_lane" "$args" || return 1
      sesion="$(printf '%s' "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session',''))")"
      worker="$(lane_campo "$reg" "$lane" worker)"
      wt="$(lane_campo "$reg" "$lane" worktree)"
      res="$(bash "$AQUI/corrida.sh" adaptador resume "$id" "$lane" "$worker" "$sesion" "$wt" "$sesion" 2>/dev/null)" || rc=$?
      if [ "$res" != "resumed" ]; then
        reconciliar_reducir_con_lock "$reg" "$pw" "$lane" "observed.handoff.blocked" \
          '{"reason":"resume-unavailable"}' || true
      fi
      ;;
    stop_lane)
      reconciliar_reducir_con_lock "$reg" "$pw" "$lane" "intent.stop_lane" "$args" || return 1
      sesion="$(printf '%s' "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session',''))")"
      bash "$AQUI/corrida.sh" adaptador stop "$id" "$lane" x "$sesion" >/dev/null 2>&1 || true
      ;;
    launch_successor)
      reconciliar_reducir_con_lock "$reg" "$pw" "$lane" "intent.launch_successor" "$args" || return 1
      worker="$(printf '%s' "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('worker',''))")"
      sesion="$(printf '%s' "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session',''))")"
      wt="$(lane_campo "$reg" "$lane" worktree)"
      brief="$(lane_campo "$reg" "$lane" brief)"
      reconciliar_reabrir_reserva "$reg" "$lane" || return 1
      if res="$(bash "$AQUI/corrida.sh" adaptador start "$id" "$lane" "$worker" "$sesion" "$wt" "$brief" 2>/dev/null)"; then
        reconciliar_reducir_con_lock "$reg" "$pw" "$lane" "observed.launched" \
          "$(printf '{"worker":"%s","session":"%s"}' "$worker" "$sesion")" || true
      else
        reconciliar_reducir_con_lock "$reg" "$pw" "$lane" "observed.handoff.blocked" \
          '{"reason":"launch-failed"}' || true
      fi
      ;;
  esac
  return 0
}

# Reduce tomando y soltando el lock (para los efectos externos, que corren
# sin lock). Falla si el lock no cede: no se escribe sin dueno.
reconciliar_reducir_con_lock() { # $1 reg $2 pw $3 lane $4 kind $5 args-json
  lock_tomar "$1" || return 1
  reconciliar_reducir "$1" "$2" "$3" "$4" "$5"
  local rc=$?
  lock_soltar "$1"
  return "$rc"
}

# Reabre la reserva del carril para el sucesor: conserva rama, worktree,
# base, dueno, modo, eventos, evidencia y delivery; suelta la ocupacion del
# predecesor (worker, sesion, estado). Toma y suelta el lock.
reconciliar_reabrir_reserva() { # $1 reg $2 lane
  lock_tomar "$1" || return 1
  CORR_C="$2" registro_escribir "$1" "
import sys
cs=d.get('lanes') or []
c=None
for e in cs:
  if isinstance(e,dict) and e.get('id')==os.environ['CORR_C']: c=e; break
if not isinstance(c,dict): sys.exit(1)
for k in ('branch','worktree','base_remote_sha','owner','mode'):
  if not c.get(k): sys.exit(1)
c['estado']='reservado'
for k in ('worker','harness','provider','reported_model','session'):
  c.pop(k,None)
" 2>/dev/null
  local rc=$?
  lock_soltar "$1"
  return "$rc"
}

# Observaciones reales de solo lectura. Imprime la ruta del JSON. Lo que no
# se puede observar (red, gh) queda null: desconocido, no falso.
reconciliar_observar() { # $1 id $2 reg; stdout ruta
  local id="$1" reg="$2" out
  out="$(mktemp)" || return 1
  unset GIT_DIR GIT_WORK_TREE GIT_NAMESPACE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
  CORR_ID="$id" CORR_REG="$reg" CORR_OUT="$out" CORR_TMUX="${TMUX_BIN:-}" \
  CORR_WREG="$(corrida_workers_registry)" CORR_TOPE="$CORR_TOPE_RED" python3 - <<'PY' || { rm -f "$out"; return 1; }
import json,os,subprocess
reg=json.load(open(os.environ["CORR_REG"]))
wreg=json.load(open(os.environ["CORR_WREG"]))
obs={"registry":{"workers":[w["id"] for w in wreg.get("workers",[])]},
"tmux":{"sessions":[]},"lanes":{},"candidates":{"exhausted":[],"next":None}}
tmux=os.environ.get("CORR_TMUX") or ""
if tmux:
    try:
        p=subprocess.run([tmux,"ls","-F","#{session_name}"],
        capture_output=True,text=True,timeout=10)
        if p.returncode==0:
            obs["tmux"]["sessions"]=[l for l in p.stdout.splitlines() if l]
    except Exception:
        pass
def git(wt,*a,timeout=20):
    try:
        p=subprocess.run(["git","-C",wt,*a],capture_output=True,text=True,timeout=timeout)
        return p.stdout.strip() if p.returncode==0 else None
    except Exception:
        return None
for c in reg.get("lanes") or []:
    if not isinstance(c,dict) or not c.get("id"): continue
    lane=c["id"]; wt=c.get("worktree") or ""; o={}
    o["worktree_exists"]=bool(wt) and os.path.isdir(wt)
    o["head"]=git(wt,"rev-parse","HEAD") if o["worktree_exists"] else None
    st=git(wt,"status","--porcelain") if o["worktree_exists"] else None
    o["dirty"]=bool(st) if st is not None else None
    base=c.get("base_remote_sha") or ""
    ahead=git(wt,"rev-list","--count",base+"..HEAD") if o["worktree_exists"] and base else None
    try: o["commits_ahead"]=int(ahead) if ahead is not None else None
    except ValueError: o["commits_ahead"]=None
    br=c.get("branch") or ""
    o["remote_branch"]=None
    if br:
        try:
            p=subprocess.run(["git","-C",wt or ".","ls-remote","--heads","origin",br],
            capture_output=True,text=True,timeout=int(os.environ.get("CORR_TOPE") or 30))
            o["remote_branch"]=bool(p.returncode==0 and p.stdout.strip()) if p.returncode==0 else None
        except Exception:
            o["remote_branch"]=None
    o["session_alive"]=(c.get("session") or "") in obs["tmux"]["sessions"]
    # Desconocido en modo automatico (null, no False): solo el director, que
    # ve al predecesor y a sus hijos, puede afirmarlo via --observations.
    o["predecessor_alive"]=None; o["children_writing"]=None
    pr=None; merge=None
    try:
        p=subprocess.run(["gh","pr","list","--head",br,"--json","number,headRefOid,mergedAt,mergeCommit",
        "--jq",".[0]"],capture_output=True,text=True,timeout=30,cwd=wt or None)
        if p.returncode==0 and p.stdout.strip() and p.stdout.strip()!="null":
            pr=json.loads(p.stdout)
    except Exception:
        pr=None
    if isinstance(pr,dict) and pr.get("number"):
        o["pr"]={"number":pr["number"],"head":pr.get("headRefOid")}
        if pr.get("mergedAt") and isinstance(pr.get("mergeCommit"),dict):
            merge={"merged":True,"merge_commit":pr["mergeCommit"].get("oid")}
    o["merge"]=merge
    o["deployed"]=None; o["canary"]=None
    obs["lanes"][lane]=o
json.dump(obs,open(os.environ["CORR_OUT"],"w"),sort_keys=True)
PY
  printf '%s\n' "$out"
}
