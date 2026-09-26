#!/bin/bash
# Task 4: reserva atomica de carriles (rama + worktree propios, tope 4).
# Remoto bare + repo de trabajo; cinco reservas simultaneas => cuatro
# ganadoras con worktrees canonicos distintos y base == origin/main traido.
# Uso: bash scripts/tests/test-corrida-worktrees.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CORR=scripts/mac/corrida.sh
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export CORRIDA_STATE="$T/corridas" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Remoto bare + semilla con un commit; el clon queda atras a proposito para
# probar que preparar-carril trae (fetch) antes de resolver la base.
git init --bare -q -b main "$T/remoto.git" || fail "no se creo el bare"
git init -q -b main "$T/semilla" || fail "no se creo la semilla"
printf 'uno\n' >"$T/semilla/a.txt"
git -C "$T/semilla" add a.txt && git -C "$T/semilla" commit -qm uno || fail "commit semilla"
git -C "$T/semilla" remote add origin "$T/remoto.git"
git -C "$T/semilla" push -q origin main || fail "push semilla"
git clone -q "$T/remoto.git" "$T/repo" || fail "no se clono"
printf 'dos\n' >"$T/semilla/a.txt"
git -C "$T/semilla" commit -qam dos || fail "commit dos"
git -C "$T/semilla" push -q origin main || fail "push dos"
VIEJO="$(git -C "$T/repo" rev-parse origin/main)"
NUEVO="$(git -C "$T/remoto.git" rev-parse main)"
[ "$VIEJO" != "$NUEVO" ] || fail "el clon no quedo atras"

mkdir -p "$T/corridas/run-w"
python3 - "$T/corridas/run-w/registro.json" <<'PY' || fail "no se escribio el registro"
import json,sys
d={"schema":"corrida.v2","id":"run-w","carriles":{}}
open(sys.argv[1],'w').write(json.dumps(d)+"\n")
PY

# Carrera: cinco reservas simultaneas, cuatro ganadoras.
pids=""
for i in 1 2 3 4 5; do
  bash "$CORR" preparar-carril run-w "lane-$i" "$T/repo" >"$T/gana-$i.out" 2>"$T/gana-$i.err" &
  pids="$pids $!"
done
ganan=0
for p in $pids; do
  if wait "$p"; then ganan=$((ganan+1)); fi
done
[ "$ganan" -eq 4 ] || fail "la carrera dio $ganan ganadoras, deben ser 4"

# Cuatro worktrees canonicos distintos, todos vivos.
veo=0
: >"$T/wts"
for i in 1 2 3 4 5; do
  if [ -s "$T/gana-$i.out" ]; then
    veo=$((veo+1))
    wt="$(cat "$T/gana-$i.out")"
    [ -d "$wt" ] || fail "lane-$i gano pero sin worktree: $wt"
    [ -f "$wt/.git" ] || fail "lane-$i: $wt no es worktree"
    printf '%s\n' "$wt" >>"$T/wts"
  fi
done
[ "$veo" -eq 4 ] || fail "salidas de ganadoras: $veo"
[ "$(sort -u "$T/wts" | wc -l | tr -d ' ')" -eq 4 ] || fail "worktree compartido: $(cat "$T/wts")"

# La base de cada ganadora es el origin/main traido, no el clon atrasado.
TRAIDO="$(git -C "$T/repo" rev-parse origin/main)"
[ "$TRAIDO" = "$NUEVO" ] || fail "preparar-carril no trajo antes de resolver (origin/main=$TRAIDO)"
python3 - "$T/corridas/run-w/registro.json" "$NUEVO" <<'PY' || fail "bases o ramas mal registradas"
import json,sys
d=json.load(open(sys.argv[1]))
cs=d['carriles']
assert len(cs)==4, sorted(cs.keys())
for lane,c in cs.items():
  assert c['base_remote_sha']==sys.argv[2], (lane,c)
  assert c['branch']=='corrida/run-w/%s'%lane, (lane,c)
  assert c['owner']==lane and c['mode']=='write', (lane,c)
  assert c['estado']=='reservado', (lane,c)
PY

# La perdedora dice capacidad agotada (exactamente una).
perd="$(grep -l "capacidad agotada" "$T"/gana-*.err | wc -l | tr -d ' ')"
[ "$perd" -eq 1 ] || fail "perdedoras con capacidad agotada: $perd"

# Solo lectura: mismo aislamiento, modo read-only.
mkdir -p "$T/corridas/run-r"
python3 - "$T/corridas/run-r/registro.json" <<'PY' || fail "no se escribio run-r"
import json,sys
d={"schema":"corrida.v2","id":"run-r","carriles":{}}
open(sys.argv[1],'w').write(json.dumps(d)+"\n")
PY
wtr="$(bash "$CORR" preparar-carril run-r lane-r "$T/repo" --read-only)" \
  || fail "reserva read-only fallo"
[ -d "$wtr" ] && [ -f "$wtr/.git" ] || fail "sin worktree read-only: $wtr"
python3 - "$T/corridas/run-r/registro.json" <<'PY' || fail "lane-r no quedo read-only"
import json,sys
c=json.load(open(sys.argv[1]))['carriles']['lane-r']
assert c['mode']=='read-only', c
PY

# Duplicado: un carril reservado no se reserva dos veces (en una corrida
# con lugar, para que el rechazo sea por duplicado y no por capacidad).
out="$(bash "$CORR" preparar-carril run-r lane-r "$T/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "reserva duplicada de lane-r aceptada"
printf '%s' "$out" | grep -q "reservad" || fail "el duplicado no se reporta: $out"

# git log origin/main..HEAD vacio en cada ganadora.
while IFS= read -r wt; do
  [ -z "$(git -C "$wt" log --format=%H origin/main..HEAD 2>/dev/null)" ] \
    || fail "$wt nacio con historia sobre origin/main"
done <"$T/wts"

echo "TODO VERDE: test-corrida-worktrees"
