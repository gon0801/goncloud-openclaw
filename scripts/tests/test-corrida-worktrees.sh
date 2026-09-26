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
# Higiene como en produccion: la ubicacion del repo la manda el argumento,
# nunca el entorno heredado (preparar-carril suelta estas mismas).
unset GIT_DIR GIT_WORK_TREE GIT_NAMESPACE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
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

# Entorno git heredado: un GIT_DIR/GIT_WORK_TREE ajeno no desvia el fetch,
# la base ni el worktree (repro del reviewer).
mkdir -p "$T/corridas/run-g"
python3 - "$T/corridas/run-g/registro.json" <<'PY' || fail "no se escribio run-g"
import json,sys
open(sys.argv[1],'w').write(json.dumps({"schema":"corrida.v2","id":"run-g","carriles":{}})+"\n")
PY
wtg="$(GIT_DIR=/no-existe-9 GIT_WORK_TREE=/no-existe-9 GIT_NAMESPACE=x-9 bash "$CORR" preparar-carril run-g lane-g "$T/repo" 2>"$T/gana-g.err")" \
  || fail "preparar con GIT heredado fallo: $(cat "$T/gana-g.err")"
[ -d "$wtg" ] && [ -f "$wtg/.git" ] || fail "sin worktree con GIT heredado: $wtg"
[ "$(git -C "$wtg" log --format=%H origin/main..HEAD 2>/dev/null)" = "" ] \
  || fail "lane-g nacio sobre base ajena con GIT heredado"

# Barrido: dos reservas huerfanas (dueno muerto + sin worktree) llenan la
# corrida a 4; la siguiente reserva las barre y entra (sin el barrido seria
# "capacidad agotada" para siempre). La reserva con worktree presente y la
# viva no se tocan.
mkdir -p "$T/wt-viva-9"
python3 - "$T/corridas/run-r/registro.json" "$T/wt-viva-9" <<'PY' || fail "no se plantaron fantasmas"
import json,sys
r=sys.argv[1]
d=json.load(open(r))
def fantasma(lane,wt,tok):
  return {'branch':'carril/'+lane,'worktree':wt,'base_remote_sha':'0'*40,
    'owner':lane,'mode':'write','estado':'reservado','token':tok}
d['carriles']['lane-f1']=fantasma('lane-f1','/no-existe-9-f1','9999999999-1')
d['carriles']['lane-f2']=fantasma('lane-f2','/no-existe-9-f2','9999999999-1')
d['carriles']['lane-viva']=fantasma('lane-viva',sys.argv[2],'9999999999-2')
json.dump(d,open(r,'w'),indent=1)
PY
wtn="$(bash "$CORR" preparar-carril run-r lane-nueva "$T/repo" 2>"$T/gana-n.err")" \
  || fail "el barrido no libero cupo: $(cat "$T/gana-n.err")"
[ -d "$wtn" ] || fail "lane-nueva sin worktree tras el barrido"
python3 - "$T/corridas/run-r/registro.json" <<'PY' || fail "barrido barro de mas o de menos"
import json,sys
cs=json.load(open(sys.argv[1]))['carriles']
assert 'lane-f1' not in cs and 'lane-f2' not in cs, 'huerfanas vivas'
assert cs['lane-viva']['estado']=='reservado', 'viva con worktree barrida'
assert cs['lane-r']['estado']=='reservado', 'reserva viva barrida'
assert cs['lane-nueva']['estado']=='reservado', 'nueva sin reserva'
PY
# Cupo desde el registro versionado (M4 ai-review): con max_external_sessions=1
# la segunda reserva dice capacidad agotada; con el literal duplicado entraria.
mkdir -p "$T/corridas/run-c"
python3 - "$T/corridas/run-c/registro.json" <<PY || fail "no se escribio run-c"
import json,sys
open(sys.argv[1],"w").write(json.dumps({"schema":"corrida.v2","id":"run-c","carriles":{}})+chr(10))
PY
python3 - "$PWD/scripts/mac/workers.v1.json" "$T/workers-cupo.json" <<PY || fail "no se escribio el registro de cupo"
import json,sys
d=json.load(open(sys.argv[1])); d["max_external_sessions"]=1
open(sys.argv[2],"w").write(json.dumps(d)+chr(10))
PY
CORRIDA_WORKERS_REGISTRY="$T/workers-cupo.json" bash "$CORR" preparar-carril run-c lane-c1 "$T/repo" >/dev/null \
  || fail "primera reserva con cupo=1 fallo"
out="$(CORRIDA_WORKERS_REGISTRY="$T/workers-cupo.json" bash "$CORR" preparar-carril run-c lane-c2 "$T/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "con cupo=1 la segunda reserva entro (literal duplicado)"
printf "%s" "$out" | grep -q "capacidad agotada" || fail "el tope del registro no se reporta: $out"


echo "TODO VERDE: test-corrida-worktrees"
