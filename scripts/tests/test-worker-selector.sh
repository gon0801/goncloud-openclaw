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

echo "TODO VERDE: selector de workers"
