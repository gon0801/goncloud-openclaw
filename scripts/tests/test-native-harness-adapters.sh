#!/bin/bash
# Task 3: contrato table-driven del adaptador sobre las CLIs nativas del registro.
# Cada worker se dobla con fake-native-cli.sh bajo tmux propio (-L);
# CORRIDA_WORKER_BIN_<ID> apunta al doble. La argv esperada sale del
# registro versionado (oraculo independiente), no del adaptador.
# Uso: bash scripts/tests/test-native-harness-adapters.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CORR=scripts/mac/corrida.sh
REG=scripts/mac/workers.v1.json
TM_REAL="$(command -v tmux 2>/dev/null || true)"
[ -z "$TM_REAL" ] && [ -x /opt/homebrew/bin/tmux ] && TM_REAL=/opt/homebrew/bin/tmux
[ -n "$TM_REAL" ] || fail "sin tmux no hay prueba del adaptador"

T=$(mktemp -d) || exit 1
L="adapta$$"
trap '"$TM_REAL" -L "$L" kill-server 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/wt" "$T/wt-r" "$T/corridas/run-1" "$T/argv"

FAKE=scripts/tests/fixtures/harness/fake-native-cli.sh
[ -f "$FAKE" ] || fail "falta $FAKE"
for b in claude codex zcode kimi grok; do
  cp "$FAKE" "$T/bin/$b" || fail "no se pudo copiar el doble $b"
done
chmod +x "$T/bin/"*
for b in claude codex zcode kimi grok; do
  [ -x "$T/bin/$b" ] || fail "el doble $b no quedo ejecutable"
done

for b in claude codex zcode kimi grok; do
  printf '%s\t%s\t--fake-9\tFAKE-BARRA-9\t--\t--\t--\n' "$b" "$b" >>"$T/modos.tsv"
done
printf 'haz lo pedido y termina\n' >"$T/brief.txt"

# Shim tmux: servidor propio + bitacora; SWALLOW=1 traga los primeros
# SWALLOW_N Enter de SWALLOW_SES (mismo contrato que test-corrida-nucleo.sh).
TMUX_LOG="$T/tmux.log"
cat >"$T/bin/tmux-shim" <<STUB
#!/bin/sh
printf '%s\n' "TMUX \$*" >> "$TMUX_LOG"
if [ "\${SWALLOW:-0}" != "0" ]; then
  case "\$*" in
    "send-keys -t =\${SWALLOW_SES:-}: Enter")
      n=\$(cat "$T/tragado" 2>/dev/null || echo 0)
      [ "\$n" -lt "\${SWALLOW_N:-1}" ] && { echo \$((n + 1)) > "$T/tragado"; exit 0; }
      ;;
  esac
fi
exec $TM_REAL -L $L "\$@"
STUB
chmod +x "$T/bin/tmux-shim"

# Doble de openclaw: la prueba jamas habla con el gateway real. Con
# FAKE_TABLERO_DOC, runbook.progress.get devuelve ese documento y set guarda
# lo publicado en FAKE_TABLERO_SET; sin el, get no trae documento.
cat >"$T/bin/openclaw" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${FAKE_OPENCLAW_LOG:-/dev/null}"
case "$*" in
  *"runbook.progress.get"*)
    [ -n "${FAKE_TABLERO_DOC:-}" ] || { printf '{"ok":false,"razon":"desconocida"}\n'; exit 0; }
    printf 'aviso de config\n{"ok":true,"doc":%s}\n' "$(cat "$FAKE_TABLERO_DOC")";;
  *"runbook.progress.set"*)
    while [ $# -gt 0 ]; do [ "$1" = "--params" ] && printf '%s' "$2" >"$FAKE_TABLERO_SET"; shift; done
    printf '{"ok":true}\n';;
esac
exit 0
STUB
chmod +x "$T/bin/openclaw"
export OPENCLAW_BIN="$T/bin/openclaw" FAKE_OPENCLAW_LOG="$T/openclaw.log"
export PATH="$T/bin:$PATH" CORRIDA_STATE="$T/corridas" TMUX_BIN="$T/bin/tmux-shim"
export FAKE_ARGV_DIR="$T/argv" FAKE_BAR="FAKE-BARRA-9"
export CORRIDA_WORKER_BIN_CLAUDE_FABLE="$T/bin/claude" CORRIDA_WORKER_BIN_CLAUDE_OPUS="$T/bin/claude" \
  CORRIDA_WORKER_BIN_CODEX="$T/bin/codex" CORRIDA_WORKER_BIN_ZCODE="$T/bin/zcode" \
  CORRIDA_WORKER_BIN_KIMI_K3="$T/bin/kimi" CORRIDA_WORKER_BIN_KIMI_CODING="$T/bin/kimi" \
  CORRIDA_WORKER_BIN_GROK="$T/bin/grok"

# Registro minimo de la prueba: carriles escritos a mano como reservas
# completas en lanes (el adaptador los lee; preparar-carril los escribe).
python3 - "$T/corridas/run-1/registro.json" "$T/modos.tsv" "$T/wt" "$T/wt-r" <<'PY' || fail "no se escribio el registro"
import json,sys
d={"schema":"corrida.v2","id":"run-1","estado":"abierta","cli_modos":sys.argv[2],
   "lanes":[{"id":"lane-1","branch":"corrida/run-1/lane-1","worktree":sys.argv[3],
     "base_remote_sha":"0"*40,"owner":"lane-1","mode":"write","role":"write",
     "estado":"reservado","token":"9-init"},
    {"id":"lane-r","branch":"corrida/run-1/lane-r","worktree":sys.argv[4],
     "base_remote_sha":"0"*40,"owner":"lane-r","mode":"read-only","role":"review",
     "estado":"reservado","token":"9-init-r"}]}
open(sys.argv[1],'w').write(json.dumps(d)+"\n")
PY

# Reserva fresca por escenario: cada start independiente parte de un carril
# reservado (el flujo real es un start por reserva; registrar ya no pisa la
# sesion viva). Resume reusa la misma sesion y no necesita reset.
reserva_lane() { # $1 lane $2 mode $3 worktree
  python3 - "$T/corridas/run-1/registro.json" "$1" "$2" "$3" <<'PYR' || fail "no se reseteo $1"
import json,sys
r,lane,modo,wt=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
d=json.load(open(r))
lanes=[e for e in d.get("lanes",[]) if e.get("id")!=lane]
lanes.append({"id":lane,"branch":"corrida/run-1/"+lane,"worktree":wt,
 "base_remote_sha":"0"*40,"owner":lane,"mode":modo,
 "role":("write" if modo=="write" else "review"),
 "estado":"reservado","token":"9-reset"})
d["lanes"]=lanes
json.dump(d,open(r,"w"),indent=1)
PYR
}
lane_apunta() { # $1 lane $2 sesion: el carril vuelve a activo con su sesion
  # viva (el bloque inspect deja otra sesion anotada; registrar ya no la pisa).
  python3 - "$T/corridas/run-1/registro.json" "$1" "$2" <<'PYA' || fail "no se apunto $1"
import json,sys
r,lane,ses=sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(r))
for e in d.get("lanes",[]):
  if e.get("id")==lane:
    e["estado"]="activo"; e["session"]=ses
json.dump(d,open(r,"w"),indent=1)
PYA
}
ad_start() { # <id> <carril> <worker> <sesion> [wt] [brief]: resetea y arranca
  case "$2" in
    lane-1) reserva_lane lane-1 write "$T/wt";;
    lane-r) reserva_lane lane-r read-only "$T/wt-r";;
    *) fail "ad_start: carril sin reserva conocida: $2";;
  esac
  bash "$CORR" adaptador start "$@"
}

# argv_esperada <worker> <clave> <sesion>: resto de la argv (sin binario)
# desde el registro versionado, con placeholders sustituidos como el adaptador.
argv_esperada() {
  REG="$REG" W="$1" K="$2" WT="$T/wt" BRIEF="$T/brief.txt" SES="$3" python3 -c "
import json,os
r=json.load(open(os.environ['REG']))
w=[x for x in r['workers'] if x['id']==os.environ['W']][0]
a=list(w['commands'][os.environ['K']])
s={'{worktree}':os.environ['WT'],'{brief}':os.environ['BRIEF'],
   '{session_id}':os.environ['SES'],'{session_name}':os.environ['SES']}
e=w.get('effort') or ''
print(' '.join(s.get(x,x).replace('{effort}',e) for x in a[1:]))
"
}
bin_de() {
  # 14.13: ids partidos por modelo; el binario (token de cli-modos.tsv) no cambia.
  case "$1" in
    claude_fable|claude_opus) printf 'claude';;
    kimi_k3|kimi_coding) printf 'kimi';;
    *) printf '%s' "$1";;
  esac
}

# El doble corre bajo el servidor tmux, que fija el entorno al arrancar:
# el modo de cada arranque se publica en el entorno global del servidor de
# la prueba (los health van por exec directa y usan prefijo normal). El
# keeper mantiene vivo al servidor: sin sesiones, set-environment no publica.
modo_fake() {
  "$TM_REAL" -L "$L" has-session -t "=zz-keeper" 2>/dev/null \
    || "$TM_REAL" -L "$L" new-session -d -s zz-keeper -x 80 -y 24 /bin/sleep 300 2>/dev/null
  "$TM_REAL" -L "$L" set-environment -g FAKE_HARNESS_MODE "$1"
}

# Los ids salen del registro: el contrato cubre a todo worker seleccionable.
for w in $(python3 -c 'import json,sys; print(" ".join(x["id"] for x in json.load(open(sys.argv[1]))["workers"]))' "$REG"); do
  b="$(bin_de "$w")"
  # health: los cuatro estados normalizados.
  [ "$(bash "$CORR" adaptador health run-1 lane-1 "$w" ses-h)" = "available" ] \
    || fail "$w: health ok no dio available"
  [ "$(FAKE_HARNESS_MODE=quota bash "$CORR" adaptador health run-1 lane-1 "$w" ses-h)" = "limited" ] \
    || fail "$w: health con cuota no dio limited"
  [ "$(FAKE_HARNESS_MODE=auth bash "$CORR" adaptador health run-1 lane-1 "$w" ses-h)" = "unauthenticated" ] \
    || fail "$w: health sin auth no dio unauthenticated"
  [ "$(FAKE_HARNESS_MODE=broken bash "$CORR" adaptador health run-1 lane-1 "$w" ses-h)" = "broken" ] \
    || fail "$w: health roto no dio broken"
  # blocked avisa saliendo 0 y sigue roto: paridad con corrida-worker.py,
  # que mapea blocked_patterns antes del rc (L3 ai-review).
  [ "$(FAKE_HARNESS_MODE=blocked bash "$CORR" adaptador health run-1 lane-1 "$w" ses-h)" = "broken" ] \
    || fail "$w: health bloqueado no dio broken"
  # Mayuscula (repro reviewer r4): Permission denied capital sale 0 y sigue
  # roto; sin .lower() el adaptador diria available y el probe broken.
  [ "$(FAKE_HARNESS_MODE=blocked-cap bash "$CORR" adaptador health run-1 lane-1 "$w" ses-h)" = "broken" ] \
    || fail "$w: health bloqueado en mayuscula no dio broken"


  # start write + review: sesion viva y argv exacta del registro.
  s="ses-$w"
  got="$(ad_start run-1 lane-1 "$w" "$s" "$T/wt" "$T/brief.txt")" \
    || fail "$w: start write fallo"
  [ "$got" = "$s" ] || fail "$w: start devolvio $got"
  "$TM_REAL" -L "$L" has-session -t "=$s" 2>/dev/null || fail "$w: la sesion no vive"
  [ "$(tail -n1 "$T/argv/$b.argv")" = "$(argv_esperada "$w" start:write "$s")" ] \
    || fail "$w: argv write distinta: $(tail -n1 "$T/argv/$b.argv")"
  # B2: lo que el carril registra (y el tablero muestra) es lo que la argv
  # lleva: modelo y effort de la entrada; sin effort declarado queda null.
  python3 - "$T/corridas/run-1/registro.json" "$REG" "$w" "$(tail -n1 "$T/argv/$b.argv")" <<'PYE' || fail "$w: el carril no registra modelo y effort de su argv"
import json,sys
c=next(e for e in json.load(open(sys.argv[1]))["lanes"] if e.get("id")=="lane-1")
w=next(x for x in json.load(open(sys.argv[2]))["workers"] if x["id"]==sys.argv[3])
assert c["model"]==w["model"] and c["effort"]==w.get("effort"), (c.get("model"), c.get("effort"))
if w.get("effort"):
    assert w["effort"] in sys.argv[4].split() or "model_reasoning_effort="+w["effort"] in sys.argv[4].split(), sys.argv[4]
PYE
  sr="ses-$w-r"
  ad_start run-1 lane-r "$w" "$sr" "$T/wt-r" "$T/brief.txt" >/dev/null \
    || fail "$w: start review fallo"
  [ "$(tail -n1 "$T/argv/$b.argv")" = "$(argv_esperada "$w" start:review "$sr")" ] \
    || fail "$w: argv review distinta: $(tail -n1 "$T/argv/$b.argv")"

  # deliver aceptada + Enter tragado con reintento exacto.
  [ "$(bash "$CORR" adaptador deliver run-1 lane-1 "$w" "$s" "$T/brief.txt")" = "accepted" ] \
    || fail "$w: deliver no fue aceptada"
  : >"$TMUX_LOG"; rm -f "$T/tragado"
  [ "$(SWALLOW=1 SWALLOW_SES="$s" bash "$CORR" adaptador deliver run-1 lane-1 "$w" "$s" "$T/brief.txt")" = "accepted" ] \
    || fail "$w: deliver con Enter tragado no reintento"
  n=$(grep -c "send-keys -t =$s: Enter" "$TMUX_LOG")
  [ "$n" -eq 2 ] || fail "$w: Enter tragado sin reintento exacto (n=$n)"

  # inspect: cada modo del doble da su estado normalizado.
  for m in running waiting complete quota auth; do
    sm="ses-$w-$m"
    modo_fake "$m"
    ad_start run-1 lane-1 "$w" "$sm" "$T/wt" "$T/brief.txt" >/dev/null \
      || fail "$w: start para inspect $m fallo"
    [ "$m" = running ] && sleep 2
    gotm="$(bash "$CORR" adaptador inspect run-1 lane-1 "$w" "$sm")" || fail "$w: inspect $m fallo"
    want="$m"; [ "$m" = auth ] && want="auth-vencida"
    [ "$gotm" = "$want" ] || fail "$w: inspect $m dio $gotm"
    bash "$CORR" adaptador stop run-1 lane-1 "$w" "$sm" >/dev/null
  done
  # 14.17: con las dos marcas en pantalla gana auth (mismo orden que health y
  # que probe_worker: auth antes que quota; el relevo correcto es el de auth).
  modo_fake cuota-auth
  ad_start run-1 lane-1 "$w" "ses-$w-ca" "$T/wt" "$T/brief.txt" >/dev/null \
    || fail "$w: start para inspect cuota+auth fallo"
  [ "$(bash "$CORR" adaptador inspect run-1 lane-1 "$w" "ses-$w-ca")" = "auth-vencida" ] \
    || fail "$w: inspect con cuota y auth no dio auth-vencida"
  [ "$(FAKE_HARNESS_MODE=cuota-auth bash "$CORR" adaptador health run-1 lane-1 "$w" ses-h)" = "unauthenticated" ] \
    || fail "$w: health con cuota y auth no dio unauthenticated"
  bash "$CORR" adaptador stop run-1 lane-1 "$w" "ses-$w-ca" >/dev/null
  # failed: el doble muere tras la barra; el inspect lo ve caido.
  modo_fake failed
  ad_start run-1 lane-1 "$w" "ses-$w-f" "$T/wt" "$T/brief.txt" >/dev/null \
    || fail "$w: start para inspect failed fallo"
  for _i in 1 2 3 4 5; do
    "$TM_REAL" -L "$L" has-session -t "=ses-$w-f" 2>/dev/null || break
    sleep 1
  done
  [ "$(bash "$CORR" adaptador inspect run-1 lane-1 "$w" "ses-$w-f")" = "failed" ] \
    || fail "$w: inspect failed no dio failed"
  # silencio jamas => complete: sesion idle sin marcadores sigue corriendo.
  modo_fake silence
  ad_start run-1 lane-1 "$w" "ses-$w-s" "$T/wt" "$T/brief.txt" >/dev/null \
    || fail "$w: start silencio fallo"
  sleep 2
  got="$(bash "$CORR" adaptador inspect run-1 lane-1 "$w" "ses-$w-s")"
  [ "$got" = "running" ] || fail "$w: el silencio dio $got, jamas complete"
  bash "$CORR" adaptador stop run-1 lane-1 "$w" "ses-$w-s" >/dev/null
  modo_fake ""

  # resume write + review: relanza con la argv de reanudacion del registro.
  # B5: sin id de la CLI (reconciliar no tiene uno real) cada worker retoma
  # la conversacion mas reciente de su worktree; el nombre tmux jamas viaja.
  lane_apunta lane-1 "$s"
  got="$(bash "$CORR" adaptador resume run-1 lane-1 "$w" "$s" "$T/wt")" \
    || fail "$w: resume write fallo"
  [ "$got" = "resumed" ] || fail "$w: resume write sin id de la CLI dio $got"
  [ "$(tail -n1 "$T/argv/$b.argv")" = "$(argv_esperada "$w" resume:write "")" ] \
    || fail "$w: argv resume write distinta: $(tail -n1 "$T/argv/$b.argv")"
  case " $(tail -n1 "$T/argv/$b.argv") " in *" $s "*) fail "$w: el resume recibio el nombre tmux como id";; esac
  got="$(bash "$CORR" adaptador resume run-1 lane-r "$w" "$sr" "$T/wt-r")" \
    || fail "$w: resume review fallo"
  [ "$got" = "resumed" ] || fail "$w: resume review sin id de la CLI dio $got"
  [ "$(tail -n1 "$T/argv/$b.argv")" = "$(argv_esperada "$w" resume:review "")" ] \
    || fail "$w: argv resume review distinta: $(tail -n1 "$T/argv/$b.argv")"

  # stop: detenida y ya-detenida.
  [ "$(bash "$CORR" adaptador stop run-1 lane-1 "$w" "$s")" = "stopped" ] \
    || fail "$w: stop no dio stopped"
  [ "$(bash "$CORR" adaptador stop run-1 lane-1 "$w" "$s")" = "already_stopped" ] \
    || fail "$w: segundo stop no dio already_stopped"
  bash "$CORR" adaptador stop run-1 lane-r "$w" "$sr" >/dev/null
done

# --- casos globales (una vez, no por worker) ---
# deliver bloqueada: la caja nunca se vacia; la sesion sigue viva.
ad_start run-1 lane-1 claude_fable ses-bloq "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "start para deliver bloqueada fallo"
rm -f "$T/tragado"
[ "$(SWALLOW=1 SWALLOW_N=2 SWALLOW_SES=ses-bloq bash "$CORR" adaptador deliver run-1 lane-1 claude_fable ses-bloq "$T/brief.txt")" = "blocked" ] \
  || fail "deliver con caja congelada no dio blocked"
"$TM_REAL" -L "$L" has-session -t "=ses-bloq" 2>/dev/null \
  || fail "deliver bloqueada mato la sesion"
bash "$CORR" adaptador stop run-1 lane-1 claude_fable ses-bloq >/dev/null

# 14.29 D2: deliver ordena la marca en la misma linea del encargo. La pantalla
# muestra lo tecleado; un doble que nunca imprime marca debe seguir running
# tras la entrega (la orden no puede traer la marca literal).
ORDEN="$(. scripts/mac/corrida/adaptador.sh && printf '%s' "$ADAPTADOR_ORDEN_MARCA")"
[ -n "$ORDEN" ] || fail "adaptador.sh no define ADAPTADOR_ORDEN_MARCA"
ad_start run-1 lane-1 claude_fable ses-orden "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "start para la orden de la marca fallo"
[ "$(bash "$CORR" adaptador deliver run-1 lane-1 claude_fable ses-orden "$T/brief.txt")" = "accepted" ] \
  || fail "deliver con la orden de la marca no fue aceptada"
"$TM_REAL" -L "$L" capture-pane -p -J -t "=ses-orden:" | grep -qF -- "RECIBIDO: haz lo pedido y termina $ORDEN" \
  || fail "la pantalla no muestra la orden de la marca en la linea del encargo:
$("$TM_REAL" -L "$L" capture-pane -p -J -t "=ses-orden:")"
got="$(bash "$CORR" adaptador inspect run-1 lane-1 claude_fable ses-orden)"
[ "$got" = "running" ] || fail "la orden tecleada se marco sola: inspect dio $got tras deliver sin marca del CLI"
bash "$CORR" adaptador stop run-1 lane-1 claude_fable ses-orden >/dev/null

# resume sin binario: unavailable y la sesion viva no se toca.
ad_start run-1 lane-1 codex ses-nobin "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "start para resume unavailable fallo"
got="$(CORRIDA_WORKER_BIN_CODEX=/no-existe-codex-9 bash "$CORR" adaptador resume run-1 lane-1 codex ses-nobin "$T/wt")"
[ "$got" = "unavailable" ] || fail "resume sin binario dio $got"
"$TM_REAL" -L "$L" has-session -t "=ses-nobin" 2>/dev/null \
  || fail "resume unavailable toco la sesion viva"
bash "$CORR" adaptador stop run-1 lane-1 codex ses-nobin >/dev/null

# B5: una argv con {session_id} y sin id real de la CLI no se lanza con un
# argumento vacio ni con el nombre tmux: unavailable (el relevo decide) y la
# sesion viva no se toca. Con id real, el id viaja tal cual.
python3 - "$REG" "$T/reg-sid.json" <<'PYS' || fail "no se armo el registro con {session_id}"
import json,sys
d=json.load(open(sys.argv[1]))
for w in d["workers"]:
    if w["id"]=="codex":
        for k in ("resume:write","resume:review"):
            w["commands"][k]=[x if x!="--last" else "{session_id}" for x in w["commands"][k]]
json.dump(d,open(sys.argv[2],"w"))
PYS
ad_start run-1 lane-1 codex ses-sid "$T/wt" "$T/brief.txt" >/dev/null || fail "start para resume sin id fallo"
got="$(CORRIDA_WORKERS_REGISTRY="$T/reg-sid.json" bash "$CORR" adaptador resume run-1 lane-1 codex ses-sid "$T/wt")"
[ "$got" = "unavailable" ] || fail "resume con {session_id} y sin id dio $got"
"$TM_REAL" -L "$L" has-session -t "=ses-sid" 2>/dev/null || fail "resume sin id toco la sesion viva"
got="$(CORRIDA_WORKERS_REGISTRY="$T/reg-sid.json" bash "$CORR" adaptador resume run-1 lane-1 codex ses-sid "$T/wt" 0199-uuid-real)"
[ "$got" = "resumed" ] || fail "resume con id real dio $got"
tail -n1 "$T/argv/codex.argv" | grep -q '^resume 0199-uuid-real ' || fail "el id real no viajo: $(tail -n1 "$T/argv/codex.argv")"
bash "$CORR" adaptador stop run-1 lane-1 codex ses-sid >/dev/null

# B4: al arrancar, el tablero de la corrida recibe el worker del carril con el
# modelo y el effort de su argv y el porque de la seleccion en una nota. Sin
# effort declarado queda null y la nota dice que corre el de la CLI. El
# documento publicado sigue pasando el validador del plugin.
python3 - "$T/tablero.json" <<'PYT' || fail "no se armo el documento del tablero"
import json,sys
car = lambda i: {"id":i,"nombre":i,"repo":"gon0801/goncloud-openclaw","rama":None,"tareas":["14.13"],
  "estado":"implementando","paso_loop":1,"pr":None,"head":None,"approve_lead":None,"ci":"sin-ci",
  "coderabbit":"pendiente","residuales":[],"detenido_por":None,"ultimo_evento":None}
doc={"schema":"runbook-progress.v1","runbook":"docs/runbooks/x.md","fase":"14.13","corrida":"run-1",
  "titulo":"prueba","lead":{"agente":"claude","inicio":"2026-09-29T10:00:00Z","actualizado":"2026-09-29T10:00:00Z"},
  "atencion_requerida":{"necesaria":False,"motivo":None,"desde":None},"siguiente_paso":"probar",
  "carriles":[car("lane-1"),car("lane-r")],"cola":[],"notas":["nota del lead"],"eventos":[],
  "cierre":{"at":None,"telegram_message_id":None,"resumen":None}}
json.dump(doc,open(sys.argv[1],"w"))
PYT
printf '{"role":"write","task_type":"general","denied_harnesses":["claude-code"]}\n' >"$T/req.json"
printf '{"health":{"claude_fable":"available","claude_opus":"available","kimi_k3":"available","kimi_coding":"available","codex":"available","zcode":"available","grok":"limited"},"exhausted":[]}\n' >"$T/st.json"
reserva_lane lane-1 write "$T/wt"
bash "$CORR" seleccionar run-1 lane-1 --request "$T/req.json" --state "$T/st.json" >"$T/sel.json" \
  || fail "seleccionar fallo: $(cat "$T/sel.json")"
ganador="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['winner'])" "$T/sel.json")"
[ "$ganador" = "kimi_k3" ] || fail "el selector eligio $ganador, se esperaba kimi_k3"
FAKE_TABLERO_DOC="$T/tablero.json" FAKE_TABLERO_SET="$T/tablero-set.json" \
  bash "$CORR" adaptador start run-1 lane-1 kimi_k3 ses-tab "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "start con tablero fallo"
[ -s "$T/tablero-set.json" ] || fail "el arranque no publico el carril en el tablero"
python3 - "$T/tablero-set.json" <<'PYT' || fail "el tablero publicado no trae worker, effort y porque: $(cat "$T/tablero-set.json")"
import json,sys
d=json.load(open(sys.argv[1]))
c=next(x for x in d["carriles"] if x["id"]=="lane-1")
assert c["worker"]=={"id":"kimi_k3","harness":"kimi-code","provider":"kimi","model":"kimi-code/k3",
  "effort":None,"reported_model":None,"health":"available"}, c["worker"]
nota=[n for n in d["notas"] if n.startswith("lane-1 seleccion: ")]
assert len(nota)==1 and "effort el de la CLI" in nota[0] and "puntaje 85" in nota[0], d["notas"]
assert "empate con" in nota[0] and "claude_fable (repo-denied)" in nota[0], nota[0]
assert "nota del lead" in d["notas"], d["notas"]
assert d["eventos"][-1]["carril"]=="lane-1" and "kimi_k3" in d["eventos"][-1]["que"], d["eventos"]
assert next(x for x in d["carriles"] if x["id"]=="lane-r").get("worker") is None
PYT
node --experimental-strip-types --input-type=module - "$T/tablero-set.json" <<'JS' || fail "el tablero publicado no pasa el validador del plugin"
import fs from "node:fs";
import { validarProgreso } from "./tablero-runbook/contrato.ts";
const r = validarProgreso(JSON.parse(fs.readFileSync(process.argv[2], "utf8")));
if (!r.ok) { console.error(r.razones.join("\n")); process.exit(1); }
JS
bash "$CORR" adaptador stop run-1 lane-1 kimi_k3 ses-tab >/dev/null
# Con effort declarado el bloque lo lleva tal cual (lo que va en la argv).
reserva_lane lane-1 write "$T/wt"
FAKE_TABLERO_DOC="$T/tablero.json" FAKE_TABLERO_SET="$T/tablero-set2.json" \
  bash "$CORR" adaptador start run-1 lane-1 codex ses-tab2 "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "start codex con tablero fallo"
python3 - "$T/tablero-set2.json" "$REG" <<'PYT' || fail "el effort del tablero no es el de la argv"
import json,sys
c=next(x for x in json.load(open(sys.argv[1]))["carriles"] if x["id"]=="lane-1")
w=next(x for x in json.load(open(sys.argv[2]))["workers"] if x["id"]=="codex")
assert w["effort"] and c["worker"]["effort"]==w["effort"], (c["worker"], w.get("effort"))
PYT
grep -q "model_reasoning_effort=$(python3 -c "import json,sys; print(next(x for x in json.load(open(sys.argv[1]))['workers'] if x['id']=='codex')['effort'])" "$REG")" "$T/argv/codex.argv" \
  || fail "la argv de codex no lleva el effort que el tablero muestra"
bash "$CORR" adaptador stop run-1 lane-1 codex ses-tab2 >/dev/null
grep -q 'gateway call' "$T/openclaw.log" || fail "el doble de openclaw no recibio las llamadas del tablero"

# health sin binario: broken (el override manda, sin caida a PATH).
got="$(CORRIDA_WORKER_BIN_GROK=/no-existe-grok-9 bash "$CORR" adaptador health run-1 lane-1 grok ses-h)"
[ "$got" = "broken" ] || fail "health sin binario dio $got"

# start sin barra: falla cerrado y no deja sesion huerfana.
modo_fake nobar
ad_start run-1 lane-1 kimi ses-nobar "$T/wt" "$T/brief.txt" >/dev/null 2>&1 \
  && fail "start sin barra debio fallar"
modo_fake ""
"$TM_REAL" -L "$L" has-session -t "=ses-nobar" 2>/dev/null \
  && fail "start sin barra dejo la sesion viva"

# start sobre una sesion existente: se niega, no la pisa.
ad_start run-1 lane-1 zcode ses-doble "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "primer start para sesion doble fallo"
bash "$CORR" adaptador start run-1 lane-1 zcode ses-doble "$T/wt" "$T/brief.txt" >/dev/null 2>&1 \
  && fail "start sobre sesion existente debio negarse"
bash "$CORR" adaptador stop run-1 lane-1 zcode ses-doble >/dev/null

# start fuera del worktree reservado: se niega sin dejar sesion.
ad_start run-1 lane-1 claude_fable ses-fuera "$T/wt-r" "$T/brief.txt" >/dev/null 2>&1 \
  && fail "start fuera del worktree reservado aceptado"
"$TM_REAL" -L "$L" has-session -t "=ses-fuera" 2>/dev/null \
  && fail "start fuera del worktree dejo la sesion viva"

# resume fuera del worktree: unavailable y la sesion viva no se toca.
ad_start run-1 lane-1 codex ses-recasa "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "start para resume en casa fallo"
got="$(bash "$CORR" adaptador resume run-1 lane-1 codex ses-recasa "$T/wt-r")"
[ "$got" = "unavailable" ] || fail "resume fuera del worktree dio $got"
"$TM_REAL" -L "$L" has-session -t "=ses-recasa" 2>/dev/null \
  || fail "resume unavailable toco la sesion viva"
bash "$CORR" adaptador stop run-1 lane-1 codex ses-recasa >/dev/null
# resume que muere tras matar la sesion: unavailable y el carril en failed.
# Sin el marcado, el carril quedaba activo con sesion huerfana (CodeRabbit
# ronda 3: relanzamiento o barra fallidos despues del kill).
ad_start run-1 lane-1 claude_fable ses-resume-f "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "start para resume failed fallo"
modo_fake nobar
got="$(bash "$CORR" adaptador resume run-1 lane-1 claude_fable ses-resume-f "$T/wt")"
[ "$got" = "unavailable" ] || fail "resume sin barra dio $got"
modo_fake ""
"$TM_REAL" -L "$L" has-session -t "=ses-resume-f" 2>/dev/null \
  && fail "resume fallido dejo la sesion viva"
python3 - "$T/corridas/run-1/registro.json" <<PY || fail "resume fallido no marco failed"
import json,sys
c=next(e for e in json.load(open(sys.argv[1]))["lanes"] if e.get("id")=="lane-1")
assert c["estado"]=="failed", c
PY
bash "$CORR" adaptador stop run-1 lane-1 claude_fable ses-resume-f >/dev/null 2>&1 || true

# Dialogo de confianza de carpeta (2026-09-28): se acepta solo si muestra el
# worktree reservado del carril. La ruta pintada es la canonica (cd -P), como
# la imprimen las CLIs reales; el carril guarda la de mktemp.
WT_CANON="$(cd -P "$T/wt" && pwd)"
for par in claude_fable:claude codex:codex kimi_k3:kimi; do
  w="${par%%:*}"; b="${par#*:}"
  "$TM_REAL" -L "$L" set-environment -g FAKE_CONFIANZA_RUTA "$WT_CANON"
  modo_fake "confianza-$b"
  ad_start run-1 lane-1 "$w" "ses-conf-$b" "$T/wt" "$T/brief.txt" >"$T/conf.out" 2>"$T/conf.err" \
    || fail "$b: dialogo con el worktree del carril no se respondio: $(cat "$T/conf.err")
$("$TM_REAL" -L "$L" capture-pane -p -t "=ses-conf-$b:" 2>/dev/null)"
  grep -q "pidio confianza para el worktree del carril" "$T/conf.err" \
    || fail "$b: respondio sin dejar la linea en stderr"
  bash "$CORR" adaptador stop run-1 lane-1 "$w" "ses-conf-$b" >/dev/null

  "$TM_REAL" -L "$L" set-environment -g FAKE_CONFIANZA_RUTA "$(cd -P "$T/wt-r" && pwd)"
  : >"$TMUX_LOG"
  ad_start run-1 lane-1 "$w" "ses-ajena-$b" "$T/wt" "$T/brief.txt" >/dev/null 2>"$T/conf.err" \
    && fail "$b: dialogo con una ruta ajena se respondio"
  grep -q "la barra no aparecio" "$T/conf.err" \
    || fail "$b: ruta ajena sin el fallo de hoy: $(cat "$T/conf.err")"
  grep -q "send-keys -t =ses-ajena-$b:" "$TMUX_LOG" \
    && fail "$b: se enviaron teclas a un dialogo con ruta ajena"
  "$TM_REAL" -L "$L" has-session -t "=ses-ajena-$b" 2>/dev/null \
    && fail "$b: ruta ajena dejo la sesion viva"

  # 14.30: el dialogo pide el padre y el worktree sale solo en otra linea.
  "$TM_REAL" -L "$L" set-environment -g FAKE_CONFIANZA_RUTA "$(dirname "$WT_CANON")"
  "$TM_REAL" -L "$L" set-environment -g FAKE_CONFIANZA_PREVIA "$WT_CANON"
  : >"$TMUX_LOG"
  ad_start run-1 lane-1 "$w" "ses-padre-$b" "$T/wt" "$T/brief.txt" >/dev/null 2>"$T/conf.err" \
    && fail "$b: dialogo que pide el padre se respondio porque el worktree salia en otra linea"
  grep -q "send-keys -t =ses-padre-$b:" "$TMUX_LOG" \
    && fail "$b: se enviaron teclas a un dialogo que pide el padre"
  "$TM_REAL" -L "$L" set-environment -gu FAKE_CONFIANZA_PREVIA
done
modo_fake ""

# accion invalida y worker desconocido: error cerrado, nunca un estado.
out="$(bash "$CORR" adaptador volar run-1 lane-1 claude_fable ses-x 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "accion invalida no dio rc 2"
printf '%s' "$out" | grep -q "accion invalida" || fail "accion invalida sin diagnostico"
bash "$CORR" adaptador health run-1 lane-1 nosuch ses-x >/dev/null 2>&1 \
  && fail "worker desconocido no fallo"

# Tabla real contra las barras medidas (F2): las seleccionables del registro pasan la
# guarda cuando la sesion muestra su barra (texto real de pantalla 2026-09-27,
# comun a la argv start:write/start:review del registro y al sondeo). El
# rechazo "sin barra medida" sigue cerrado, ahora contra una tabla sintetica
# con unknown: el contrato no depende de que la tabla real tenga unknowns.
. scripts/mac/corrida/lib.sh
. scripts/mac/corrida/adaptador.sh
printf 'claude\tclaude\t--x\tunknown\t--\t--\t--\ncodex\tcodex\t--x\tunknown\t--\t--\t--\ngrok\tgrok\t--x\tunknown\t--\t--\t--\n' >"$T/modos-unknown.tsv"
python3 - "$T/registro-unknown.json" "$T/modos-unknown.tsv" <<'PY2' || fail "no se escribio el registro sintetico"
import json,sys
json.dump({"schema":"corrida.v2","id":"run-r","cli_modos":sys.argv[2]},open(sys.argv[1],'w'))
PY2
python3 - "$T/registro-real.json" "$PWD/scripts/mac/cli-modos.tsv" <<'PY2' || fail "no se escribio el registro real"
import json,sys
json.dump({"schema":"corrida.v2","id":"run-r","cli_modos":sys.argv[2]},open(sys.argv[1],'w'))
PY2
inicio="$SECONDS"
for b in claude codex grok; do
  out="$(adaptador_esperar_barra "$T/registro-unknown.json" "ses-irreal-9" "$b" 2>&1)" \
    && fail "$b: barra unknown aceptada contra la tabla sintetica"
  printf '%s' "$out" | grep -q "sin barra medida" || fail "$b: rechazo sin diagnostico: $out"
done
[ "$((SECONDS-inicio))" -lt 10 ] || fail "el rechazo sin barra no fue rapido"
for par in \
  "claude|(shift+tab to cycle)" \
  "codex|Ask Codex to do anything" \
  "zcode|zai/glm" \
  "kimi|thinking:" \
  "grok|[stable]"; do
  b="${par%%|*}"; texto="${par#*|}"
  ses="ses-barra-$b"
  "$TM_REAL" -L "$L" new-session -d -s "$ses" -x 80 -y 24 "printf '%s\n' \"$texto\"; sleep 60" 2>/dev/null \
    || fail "no se creo la sesion de barra de $b"
  adaptador_esperar_barra "$T/registro-real.json" "$ses" "$b" >/dev/null 2>&1 \
    || fail "$b (barra medida) no paso contra la tabla real"
  "$TM_REAL" -L "$L" kill-session -t "=$ses" 2>/dev/null
done

echo "TODO VERDE: test-native-harness-adapters"
