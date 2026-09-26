#!/bin/bash
# Task 3: contrato table-driven del adaptador sobre las seis CLIs nativas.
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
for b in claude codex zcode kimi cursor-agent grok; do
  cp "$FAKE" "$T/bin/$b" || fail "no se pudo copiar el doble $b"
done
chmod +x "$T/bin/"*
for b in claude codex zcode kimi cursor-agent grok; do
  [ -x "$T/bin/$b" ] || fail "el doble $b no quedo ejecutable"
done

for b in claude codex zcode kimi cursor-agent grok; do
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

export PATH="$T/bin:$PATH" CORRIDA_STATE="$T/corridas" TMUX_BIN="$T/bin/tmux-shim"
export FAKE_ARGV_DIR="$T/argv" FAKE_BAR="FAKE-BARRA-9"
export CORRIDA_WORKER_BIN_CLAUDE="$T/bin/claude" CORRIDA_WORKER_BIN_CODEX="$T/bin/codex" \
  CORRIDA_WORKER_BIN_ZCODE="$T/bin/zcode" CORRIDA_WORKER_BIN_KIMI="$T/bin/kimi" \
  CORRIDA_WORKER_BIN_CURSOR="$T/bin/cursor-agent" CORRIDA_WORKER_BIN_GROK="$T/bin/grok"

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
print(' '.join(s.get(x,x) for x in a[1:]))
"
}
bin_de() {
  case "$1" in cursor) printf 'cursor-agent';; *) printf '%s' "$1";; esac
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

for w in claude codex zcode kimi cursor grok; do
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
  lane_apunta lane-1 "$s"
  got="$(bash "$CORR" adaptador resume run-1 lane-1 "$w" "$s" "$T/wt" "SESID-9")" \
    || fail "$w: resume write fallo"
  [ "$got" = "resumed" ] || fail "$w: resume write dio $got"
  [ "$(tail -n1 "$T/argv/$b.argv")" = "$(argv_esperada "$w" resume:write SESID-9)" ] \
    || fail "$w: argv resume write distinta: $(tail -n1 "$T/argv/$b.argv")"
  got="$(bash "$CORR" adaptador resume run-1 lane-r "$w" "$sr" "$T/wt-r" "SESID-9")" \
    || fail "$w: resume review fallo"
  [ "$got" = "resumed" ] || fail "$w: resume review dio $got"
  [ "$(tail -n1 "$T/argv/$b.argv")" = "$(argv_esperada "$w" resume:review SESID-9)" ] \
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
ad_start run-1 lane-1 claude ses-bloq "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "start para deliver bloqueada fallo"
rm -f "$T/tragado"
[ "$(SWALLOW=1 SWALLOW_N=2 SWALLOW_SES=ses-bloq bash "$CORR" adaptador deliver run-1 lane-1 claude ses-bloq "$T/brief.txt")" = "blocked" ] \
  || fail "deliver con caja congelada no dio blocked"
"$TM_REAL" -L "$L" has-session -t "=ses-bloq" 2>/dev/null \
  || fail "deliver bloqueada mato la sesion"
bash "$CORR" adaptador stop run-1 lane-1 claude ses-bloq >/dev/null

# resume sin binario: unavailable y la sesion viva no se toca.
ad_start run-1 lane-1 codex ses-nobin "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "start para resume unavailable fallo"
got="$(CORRIDA_WORKER_BIN_CODEX=/no-existe-codex-9 bash "$CORR" adaptador resume run-1 lane-1 codex ses-nobin "$T/wt" SESID-9)"
[ "$got" = "unavailable" ] || fail "resume sin binario dio $got"
"$TM_REAL" -L "$L" has-session -t "=ses-nobin" 2>/dev/null \
  || fail "resume unavailable toco la sesion viva"
bash "$CORR" adaptador stop run-1 lane-1 codex ses-nobin >/dev/null

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
ad_start run-1 lane-1 claude ses-fuera "$T/wt-r" "$T/brief.txt" >/dev/null 2>&1 \
  && fail "start fuera del worktree reservado aceptado"
"$TM_REAL" -L "$L" has-session -t "=ses-fuera" 2>/dev/null \
  && fail "start fuera del worktree dejo la sesion viva"

# resume fuera del worktree: unavailable y la sesion viva no se toca.
ad_start run-1 lane-1 codex ses-recasa "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "start para resume en casa fallo"
got="$(bash "$CORR" adaptador resume run-1 lane-1 codex ses-recasa "$T/wt-r" SESID-9)"
[ "$got" = "unavailable" ] || fail "resume fuera del worktree dio $got"
"$TM_REAL" -L "$L" has-session -t "=ses-recasa" 2>/dev/null \
  || fail "resume unavailable toco la sesion viva"
bash "$CORR" adaptador stop run-1 lane-1 codex ses-recasa >/dev/null
# resume que muere tras matar la sesion: unavailable y el carril en failed.
# Sin el marcado, el carril quedaba activo con sesion huerfana (CodeRabbit
# ronda 3: relanzamiento o barra fallidos despues del kill).
ad_start run-1 lane-1 claude ses-resume-f "$T/wt" "$T/brief.txt" >/dev/null \
  || fail "start para resume failed fallo"
modo_fake nobar
got="$(bash "$CORR" adaptador resume run-1 lane-1 claude ses-resume-f "$T/wt" SESID-9)"
[ "$got" = "unavailable" ] || fail "resume sin barra dio $got"
modo_fake ""
"$TM_REAL" -L "$L" has-session -t "=ses-resume-f" 2>/dev/null \
  && fail "resume fallido dejo la sesion viva"
python3 - "$T/corridas/run-1/registro.json" <<PY || fail "resume fallido no marco failed"
import json,sys
c=next(e for e in json.load(open(sys.argv[1]))["lanes"] if e.get("id")=="lane-1")
assert c["estado"]=="failed", c
PY
bash "$CORR" adaptador stop run-1 lane-1 claude ses-resume-f >/dev/null 2>&1 || true


# accion invalida y worker desconocido: error cerrado, nunca un estado.
out="$(bash "$CORR" adaptador volar run-1 lane-1 claude ses-x 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "accion invalida no dio rc 2"
printf '%s' "$out" | grep -q "accion invalida" || fail "accion invalida sin diagnostico"
bash "$CORR" adaptador health run-1 lane-1 nosuch ses-x >/dev/null 2>&1 \
  && fail "worker desconocido no fallo"

# Tabla real (no la sintetica): los workers sin barra medida se rechazan
# rapido y con diagnostico, sin quemar el sondeo; los medidos pasan la
# guarda y el sondeo los ve (repro del reviewer: 4 de 6 en unknown).
. scripts/mac/corrida/lib.sh
. scripts/mac/corrida/adaptador.sh
python3 - "$T/registro-real.json" "$PWD/scripts/mac/cli-modos.tsv" <<'PY2' || fail "no se escribio el registro real"
import json,sys
json.dump({"schema":"corrida.v2","id":"run-r","cli_modos":sys.argv[2]},open(sys.argv[1],'w'))
PY2
inicio="$SECONDS"
for b in claude codex cursor-agent grok; do
  out="$(adaptador_esperar_barra "$T/registro-real.json" "ses-irreal-9" "$b" 2>&1)" \
    && fail "$b: barra unknown aceptada contra la tabla real"
  printf '%s' "$out" | grep -q "sin barra medida" || fail "$b: rechazo sin diagnostico: $out"
done
[ "$((SECONDS-inicio))" -lt 10 ] || fail "el rechazo sin barra no fue rapido"
"$TM_REAL" -L "$L" new-session -d -s ses-barra-yolo -x 80 -y 24 "printf 'yolo\n'; sleep 60" 2>/dev/null \
  || fail "no se creo la sesion de barra"
"$TM_REAL" -L "$L" new-session -d -s ses-barra-auto -x 80 -y 24 "printf 'auto\n'; sleep 60" 2>/dev/null \
  || fail "no se creo la sesion de barra auto"
adaptador_esperar_barra "$T/registro-real.json" ses-barra-yolo zcode >/dev/null 2>&1 \
  || fail "zcode (barra medida yolo) no paso contra la tabla real"
adaptador_esperar_barra "$T/registro-real.json" ses-barra-auto kimi >/dev/null 2>&1 \
  || fail "kimi (barra medida auto) no paso contra la tabla real"
"$TM_REAL" -L "$L" kill-session -t "=ses-barra-yolo" 2>/dev/null
"$TM_REAL" -L "$L" kill-session -t "=ses-barra-auto" 2>/dev/null

echo "TODO VERDE: test-native-harness-adapters"
