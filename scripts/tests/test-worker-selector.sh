#!/bin/bash
# 14.1 Task 2: salud determinista y selección de workers.
# Uso: bash scripts/tests/test-worker-selector.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

REG=scripts/tests/fixtures/workers/selection.json
REQ=scripts/tests/fixtures/workers/request-review.json
ST=scripts/tests/fixtures/workers/selection-state.json
CLI="python3 scripts/mac/corrida-worker.py"

jget() { # $1 expr python sobre stdin JSON
  python3 -c "import json,sys; print($1)"
}

decision=$($CLI select --registry "$REG" --request "$REQ" --state "$ST") \
  || fail "select fallo con el fixture"
[ "$(printf '%s' "$decision" | jget 'json.load(sys.stdin)["winner"]')" = "codex" ] \
  || fail "unstable winner: $decision"
printf '%s' "$decision" | grep -q 'unauthenticated' || fail "auth discard not recorded"
# Empate codex/zcode a 90 resuelto por orden del registro; la entrada abierta no puntúa.
[ "$(printf '%s' "$decision" | jget 'json.load(sys.stdin)["score"]')" = "90" ] \
  || fail "puntaje del ganador distinto de 90: $decision"
[ "$(printf '%s' "$decision" | jget '[c["score"] for c in json.load(sys.stdin)["candidates"] if c["worker"]=="zcode"][0]')" = "90" ] \
  || fail "zcode no empata a 90 (historia abierta contada?): $decision"
# limited es fallback registrado, no fallo global.
[ "$(printf '%s' "$decision" | jget '[c["parts"]["availability"] for c in json.load(sys.stdin)["candidates"] if c["worker"]=="cursor"][0]')" = "5" ] \
  || fail "cursor limited sin availability 5: $decision"
# Descartes duros del fixture base.
[ "$(printf '%s' "$decision" | jget 'sorted([d["worker"] for d in json.load(sys.stdin)["discarded"]])')" = "['claude', 'grok', 'kimi']" ] \
  || fail "descartados inesperados: $decision"
printf '%s' "$decision" | grep -q 'missing-executable' || fail "ejecutable ausente no registrado"
printf '%s' "$decision" | grep -q 'missing-capability' || fail "capacidad faltante no registrada"
printf '%s' "$decision" | grep -q 'repo-denied' || fail "prohibicion del repo no registrada"

# 20 corridas del mismo fixture, byte-idénticas.
esperado=$(printf '%s' "$decision" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest())')
i=1
while [ "$i" -le 20 ]; do
  otra=$($CLI select --registry "$REG" --request "$REQ" --state "$ST") \
    || fail "corrida $i fallo"
  actual=$(printf '%s' "$otra" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest())')
  [ "$actual" = "$esperado" ] || fail "corrida $i difiere byte a byte"
  i=$((i+1))
done

# Variantes derivadas del fixture: capacidad, worktree, autor, revisor previo, cuota.
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
python3 - "$ST" "$T" <<'PY'
import json, sys
src, tmp = sys.argv[1], sys.argv[2]
state = json.load(open(src))
def dump(name, mut):
    import copy
    s = copy.deepcopy(state)
    mut(s)
    json.dump(s, open(f"{tmp}/{name}", "w"), sort_keys=True)
dump("cap.json", lambda s: s.update(active=[
    {"worker": "codex", "worktree": "worktrees/a", "mode": "write", "session": "s1"},
    {"worker": "zcode", "worktree": "worktrees/b", "mode": "write", "session": "s2"},
    {"worker": "cursor", "worktree": "worktrees/c", "mode": "write", "session": "s3"},
    {"worker": "claude", "worktree": "worktrees/d", "mode": "write", "session": "s4"}]))
dump("ocupado.json", lambda s: s.update(active=[
    {"worker": "zcode", "worktree": "worktrees/carril-revision", "mode": "write", "session": "s1"}]))
dump("previo.json", lambda s: s.update(previous_reviewer="codex"))
dump("cuota.json", lambda s: s.update(exhausted=["codex"]))
PY
python3 - "$REQ" "$T/autor.json" <<'PY'
import json, sys
req = json.load(open(sys.argv[1]))
req["implemented_by"] = "codex"
json.dump(req, open(sys.argv[2], "w"), sort_keys=True)
PY

cap=$($CLI select --registry "$REG" --request "$REQ" --state "$T/cap.json") \
  || fail "select con 4 activas fallo"
[ "$(printf '%s' "$cap" | jget 'json.load(sys.stdin)["status"]')" = "no-compatible-worker" ] \
  || fail "4 sesiones activas debieron cerrar la capacidad: $cap"
[ "$(printf '%s' "$cap" | jget 'json.load(sys.stdin)["winner"]')" = "None" ] \
  || fail "sin capacidad no hay ganador: $cap"

ocupado=$($CLI select --registry "$REG" --request "$REQ" --state "$T/ocupado.json") \
  || fail "select con worktree ocupado fallo"
[ "$(printf '%s' "$ocupado" | jget 'json.load(sys.stdin)["winner"]')" = "zcode" ] \
  || fail "el dueño del worktree debio ganar: $ocupado"
printf '%s' "$ocupado" | grep -q 'worktree-occupied' || fail "worktree ocupado no registrado"

autor=$($CLI select --registry "$REG" --request "$T/autor.json" --state "$ST") \
  || fail "select con autor implementador fallo"
[ "$(printf '%s' "$autor" | jget 'json.load(sys.stdin)["winner"]')" = "zcode" ] \
  || fail "el implementador no puede ser unico revisor: $autor"
printf '%s' "$autor" | grep -q 'author-excluded' || fail "autor excluido no registrado"

previo=$($CLI select --registry "$REG" --request "$REQ" --state "$T/previo.json") \
  || fail "select con revisor previo fallo"
[ "$(printf '%s' "$previo" | jget 'json.load(sys.stdin)["winner"]')" = "zcode" ] \
  || fail "la diversidad debio preferir a zcode: $previo"

cuota=$($CLI select --registry "$REG" --request "$REQ" --state "$T/cuota.json") \
  || fail "select con cuota agotada fallo"
[ "$(printf '%s' "$cuota" | jget 'json.load(sys.stdin)["winner"]')" = "zcode" ] \
  || fail "la cuota agotada no debe reciclarse: $cuota"
printf '%s' "$cuota" | grep -q 'quota-exhausted' || fail "cuota agotada no registrada"

# 14.13/13a: relevo por quota_group. Cuota agotada en claude_fable: el relevo
# NO elige claude_opus (misma cuenta: una entrada sin quota_group deriva su
# grupo del provider); salta a codex. La decision registra modelo y effort.
relay=$($CLI select --registry scripts/tests/fixtures/workers/selection-quota-group.json \
  --request "$REQ" --state scripts/tests/fixtures/workers/selection-quota-state.json) \
  || fail "select del relevo fallo"
[ "$(printf '%s' "$relay" | jget 'json.load(sys.stdin)["winner"]')" = "codex" ] \
  || fail "el relevo eligio el mismo quota_group: $relay"
printf '%s' "$relay" | grep -q 'quota-group' \
  || fail "el descarte de grupo no quedo registrado: $relay"
printf '%s' "$relay" | grep -q '"model"' || fail "la decision no registra el modelo: $relay"
printf '%s' "$relay" | grep -q '"effort"' || fail "la decision no registra el effort: $relay"

# Sondas acotadas: CLIs de mentira vía override, sin tocar PATH ni la red.
mkdir -p "$T/bin"
cat >"$T/bin/fake-ok" <<'CLI'
#!/bin/sh
echo "fake-cli 1.0"
CLI
cat >"$T/bin/fake-auth" <<'CLI'
#!/bin/sh
echo "login required" >&2
exit 1
CLI
cat >"$T/bin/fake-quota" <<'CLI'
#!/bin/sh
echo "rate limit, retry later"
exit 0
CLI
cat >"$T/bin/fake-lento" <<'CLI'
#!/bin/sh
sleep 30
CLI
chmod +x "$T/bin"/fake-*
FIXREG=scripts/tests/fixtures/workers/valid.json
case "$($CLI health probe --registry "$FIXREG" --worker claude --format status)" in
  available|limited|unauthenticated|broken) ;;
  *) fail "probe sin override dio un estado desconocido" ;;
esac
out=$(CORRIDA_WORKER_BIN_CLAUDE="$T/bin/fake-ok" $CLI health probe --registry "$FIXREG" --worker claude --format status) \
  || fail "probe ok fallo"
[ "$out" = "available" ] || fail "probe ok dio $out"
out=$(CORRIDA_WORKER_BIN_CLAUDE="$T/bin/fake-auth" $CLI health probe --registry "$FIXREG" --worker claude --format status) \
  || fail "probe auth fallo"
[ "$out" = "unauthenticated" ] || fail "probe auth dio $out"
out=$(CORRIDA_WORKER_BIN_CLAUDE="$T/bin/fake-quota" $CLI health probe --registry "$FIXREG" --worker claude --format status) \
  || fail "probe quota fallo"
[ "$out" = "limited" ] || fail "probe quota dio $out"
out=$(CORRIDA_WORKER_BIN_CLAUDE="$T/bin/fake-lento" $CLI health probe --registry "$FIXREG" --worker claude --format status --timeout 1) \
  || fail "probe con tope fallo"
[ "$out" = "broken" ] || fail "probe sin tope habria colgado; dio $out"
[ -e "$T/INYECTADO-14x" ] && fail "la sonda ejecuto codigo fuera del argv"
out=$(CORRIDA_WORKER_BIN_CLAUDE="$T/bin/no-existe" $CLI health probe --registry "$FIXREG" --worker claude --format status) \
  || fail "probe con override ausente fallo"
[ "$out" = "broken" ] || fail "override ausente dio $out"

# 14.20 (2): cmd_select valida los tipos del estado antes de pasarselos al
# selector; un estado mal tipado da el diagnostico limpio, nunca un traceback.
estado_malo() { # $1 mutacion python sobre el state, $2 descripcion
  python3 - scripts/tests/fixtures/workers/selection-state.json "$T/malo.json" "$1" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(state, open(sys.argv[2], "w"), indent=1, sort_keys=True)
PY
  if out=$($CLI select --registry "$REG" --request "$REQ" --state "$T/malo.json" 2>&1); then
    fail "select acepto un estado con $2"
  fi
  printf '%s\n' "$out" | grep -q 'ERROR invalid selection input' \
    || fail "select con $2 revento sin diagnostico limpio: $(printf '%s\n' "$out" | head -2)"
}
estado_malo 'state["installed"] = []' "installed lista"
estado_malo 'state["exhausted"] = "claude"' "exhausted cadena"
estado_malo 'state["previous_reviewer"] = 17' "previous_reviewer numero"
estado_malo 'state["history"] = ["x"]' "history con una cadena"

# 14.20 (6): al vencer el tope se mata el GRUPO (killpg), no solo el PID: un
# binario que deja un hijo vivo no puede sobrevivir a la sonda.
cat >"$T/bin/fake-hijo" <<CLI
#!/bin/sh
sh -c 'echo \$\$ > "$T/hijo.pid"; while :; do sleep 1; done' >/dev/null 2>&1 &
exec sleep 30
CLI
chmod +x "$T/bin/fake-hijo"
rm -f "$T/hijo.pid"
out=$(CORRIDA_WORKER_BIN_CLAUDE="$T/bin/fake-hijo" $CLI health probe --registry "$FIXREG" --worker claude --format status --timeout 1) \
  || fail "probe de un binario con hijo fallo"
[ "$out" = "broken" ] || fail "probe de un binario con hijo dio $out"
[ -s "$T/hijo.pid" ] || fail "el hijo nunca escribio su pid"
muerto=0
i=0
while [ "$i" -lt 20 ]; do
  estado_hijo="$(ps -o stat= -p "$(cat "$T/hijo.pid")" 2>/dev/null || true)"
  case "$estado_hijo" in ""|Z*) muerto=1; break;; esac
  sleep 0.1
  i=$((i+1))
done
[ "$muerto" -eq 1 ] || fail "el hijo sobrevivio al tope de la sonda (se mato solo el PID)"

# 14.20 r2 (B1): un hijo separado con setsid escapa al killpg y retiene
# stdout/stderr heredados; la sonda no puede esperar esas pipes sin tope: tiene
# que regresar dentro del tope de la prueba (el mismo repro del bloqueante).
cat >"$T/bin/fake-daemon" <<CLI
#!/bin/sh
python3 -c 'import os, time
p = "$T/daemon.pid"
open(p, "w").write(str(os.getpid()))
os.setsid()
time.sleep(40)' >/dev/null &
exec sleep 30
CLI
chmod +x "$T/bin/fake-daemon"
rm -f "$T/daemon.pid" "$T/daemon.out"
CORRIDA_WORKER_BIN_CLAUDE="$T/bin/fake-daemon" $CLI health probe --registry "$FIXREG" --worker claude --format status --timeout 1 \
  >"$T/daemon.out" 2>&1 &
probe_pid=$!
regreso=0
i=0
while [ "$i" -lt 50 ]; do
  kill -0 "$probe_pid" 2>/dev/null || { regreso=1; break; }
  sleep 0.1
  i=$((i+1))
done
[ "$regreso" -eq 1 ] || fail "la sonda no regreso en 5 s con un hijo setsid que hereda la salida (B1)"
out=$(cat "$T/daemon.out")
[ "$out" = "broken" ] || fail "la sonda del daemon dio $out"
kill -9 "$(cat "$T/daemon.pid" 2>/dev/null)" 2>/dev/null
rm -f "$T/daemon.pid"

# 14.20 (8): la salida del worker es dato: bytes que no son UTF-8 se decodifican
# con errors="replace" y no revientan la sonda.
cat >"$T/bin/fake-utf8" <<'CLI'
#!/bin/sh
printf 'fake \xff\xfe basura\n'
exit 0
CLI
chmod +x "$T/bin/fake-utf8"
out=$(CORRIDA_WORKER_BIN_CLAUDE="$T/bin/fake-utf8" $CLI health probe --registry "$FIXREG" --worker claude --format status 2>&1) \
  || fail "probe con salida no-utf8 revento: $out"
[ "$out" = "available" ] || fail "probe con salida no-utf8 dio $out"

echo "TODO VERDE: selector de workers"
