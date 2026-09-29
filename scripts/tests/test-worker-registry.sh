#!/bin/bash
# 14.1 Task 1: registro versionado de workers y validación estricta.
# Uso: bash scripts/tests/test-worker-registry.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

python3 scripts/mac/corrida-worker.py registry validate --registry scripts/tests/fixtures/workers/valid.json \
  | grep -qx 'VALID workers.v1 1' || fail "valid.json no valida como 1 worker"
if out=$(python3 scripts/mac/corrida-worker.py registry validate --registry scripts/tests/fixtures/workers/invalid-command.json 2>&1); then
  fail "accepted a shell-bearing binary"
fi
printf '%s\n' "$out" | grep -qx 'ERROR invalid command' || fail "wrong invalid-command diagnostic: $out"
if out=$(python3 scripts/mac/corrida-worker.py registry validate --registry scripts/tests/fixtures/workers/invalid-pattern.json 2>&1); then
  fail "accepted an empty or control-bearing pattern"
fi
printf '%s\n' "$out" | grep -qx 'ERROR invalid pattern' || fail "wrong invalid-pattern diagnostic: $out"

python3 scripts/mac/corrida-worker.py registry validate --registry scripts/mac/workers.v1.json \
  | grep -qx 'VALID workers.v1 8' || fail "el registro real no valida como 8 workers (14.13e)"

python3 scripts/mac/corrida-worker.py record validate --record scripts/tests/fixtures/corrida/v2-existing-without-workers.json \
  | grep -qx 'VALID corrida.v2 legacy' || fail "el fixture legado no valida"
python3 scripts/mac/corrida-worker.py record validate --record scripts/tests/fixtures/corrida/v2-native-workers.json \
  | grep -qx 'VALID corrida.v2 native-workers' || fail "el fixture nativo no valida"

# 14.16: un solo contrato de carril. El fixture enriquecido pasa el validador
# del shell y, quitando a un carril cualquiera de los campos de la reserva,
# LOS DOS validadores lo rechazan nombrando el mismo campo.
. scripts/mac/corrida/lib.sh
validar_registro scripts/tests/fixtures/corrida/v2-native-workers.json >/dev/null 2>&1 \
  || fail "el fixture nativo no pasa validar_registro: $(validar_registro scripts/tests/fixtures/corrida/v2-native-workers.json 2>&1)"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
for campo in branch worktree base_remote_sha owner mode; do
  python3 - "scripts/tests/fixtures/corrida/v2-native-workers.json" "$T/sin-$campo.json" "$campo" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
rec["lanes"][0].pop(sys.argv[3], None)
json.dump(rec, open(sys.argv[2], "w"), indent=1, sort_keys=True)
PY
  if validar_registro "$T/sin-$campo.json" >/dev/null 2>&1; then
    fail "validar_registro acepto un carril sin $campo"
  fi
  validar_registro "$T/sin-$campo.json" 2>&1 | grep -q "carril sin $campo" \
    || fail "validar_registro no nombro la razon (carril sin $campo)"
  if python3 scripts/mac/corrida-worker.py record validate --record "$T/sin-$campo.json" >/dev/null 2>&1; then
    fail "record validate acepto un carril sin $campo"
  fi
  python3 scripts/mac/corrida-worker.py record validate --record "$T/sin-$campo.json" 2>&1 | grep -q "without $campo" \
    || fail "record validate no nombro la razon (lane without $campo)"
done

# 14.25 R1: las demas reglas de carril de validar_registro (id repetido,
# worktree compartido, estado fuera del conjunto, visibilidad sin forma)
# tambien las rechaza record validate.
dos_carriles() { # $1 caso $2 expresion python sobre rec
  python3 - "scripts/tests/fixtures/corrida/v2-native-workers.json" "$T/$1.json" "$2" <<'PY2'
import copy, json, sys
rec = json.load(open(sys.argv[1]))
otro = copy.deepcopy(rec["lanes"][0])
otro.update(id="web", owner="web", branch="fase14/web", worktree="worktrees/carril-web")
rec["lanes"].append(otro)
exec(sys.argv[3])
json.dump(rec, open(sys.argv[2], "w"), indent=1, sort_keys=True)
PY2
}
carril_malo() { # $1 caso $2 expresion python sobre rec $3 razon shell $4 razon python
  dos_carriles "$1" "$2"
  validar_registro "$T/$1.json" 2>&1 | grep -q "$3" \
    || fail "validar_registro no rechazo $1 con '$3'"
  if python3 scripts/mac/corrida-worker.py record validate --record "$T/$1.json" >/dev/null 2>&1; then
    fail "record validate acepto $1"
  fi
  python3 scripts/mac/corrida-worker.py record validate --record "$T/$1.json" 2>&1 | grep -q "$4" \
    || fail "record validate no nombro la razon de $1 ($4)"
}
dos_carriles dos-sanos 'pass'
validar_registro "$T/dos-sanos.json" >/dev/null 2>&1 || fail "dos carriles sanos no pasan validar_registro"
python3 scripts/mac/corrida-worker.py record validate --record "$T/dos-sanos.json" | grep -qx 'VALID corrida.v2 native-workers' \
  || fail "dos carriles sanos no validan"
carril_malo id-repetido 'rec["lanes"][1]["id"] = "api"' 'carril duplicado' 'duplicate lane'
carril_malo wt-compartido 'rec["lanes"][1]["worktree"] = rec["lanes"][0]["worktree"]' 'worktree compartido' 'shared worktree'
carril_malo estado-raro 'rec["lanes"][1]["estado"] = "zombi"' 'estado de carril fuera del conjunto' 'lane estado outside the set'
carril_malo vis-sin-forma 'rec["lanes"][1]["visibility"] = {"state": "visible"}' 'visibilidad sin forma' 'lane visibility without shape'

# 14.20 (1) y (3): capabilities con elementos de tipo basura dan el diagnostico
# limpio del registro (no un TypeError de unhashable) y el esquema del
# transcript es cerrado (solo kind y path).
mutar_registro() { # $1 destino, $2 expresion python sobre rec
  python3 - "$1" "$2" <<'PY'
import json, sys
rec = json.load(open("scripts/tests/fixtures/workers/valid.json"))
exec(sys.argv[2])
json.dump(rec, open(sys.argv[1], "w"), indent=1, sort_keys=True)
PY
}
mutar_registro "$T/caps-basura.json" 'rec["workers"][0]["capabilities"] = ["read", {"malicia": 1}]'
if out=$(python3 scripts/mac/corrida-worker.py registry validate --registry "$T/caps-basura.json" 2>&1); then
  fail "capabilities con un dict debio fallar"
fi
printf '%s\n' "$out" | grep -q 'ERROR invalid registry' \
  || fail "capabilities con un dict dio traceback y no el diagnostico limpio: $(printf '%s\n' "$out" | head -2)"
mutar_registro "$T/transcript-rara.json" 'rec["workers"][0]["transcript"] = {"kind": "tmux-pane", "cualquier": "cosa"}'
if out=$(python3 scripts/mac/corrida-worker.py registry validate --registry "$T/transcript-rara.json" 2>&1); then
  fail "un transcript con clave desconocida debio fallar"
fi
printf '%s\n' "$out" | grep -q 'ERROR invalid transcript' \
  || fail "el esquema del transcript acepto una clave desconocida: $out"

# 14.13: esquema cerrado con effort y quota_group. effort sin marcador
# {effort} en start/resume, o marcador sin effort, da ERROR invalid effort en
# ambas direcciones (fixtures de la enmienda), y los ids solo admiten
# [a-z0-9_]: punto o guion rompen tmux y el override CORRIDA_WORKER_BIN_<ID>.
if out=$(python3 scripts/mac/corrida-worker.py registry validate --registry scripts/tests/fixtures/workers/invalid-effort.json 2>&1); then
  fail "acepto un effort sin argv que lo reciba"
fi
printf '%s\n' "$out" | grep -qx 'ERROR invalid effort' || fail "wrong invalid-effort diagnostic: $out"
if out=$(python3 scripts/mac/corrida-worker.py registry validate --registry scripts/tests/fixtures/workers/invalid-effort-argv.json 2>&1); then
  fail "acepto un marcador de effort sin campo effort"
fi
printf '%s\n' "$out" | grep -qx 'ERROR invalid effort' || fail "wrong invalid-effort diagnostic: $out"
mutar_registro "$T/id-punto.json" 'rec["workers"][0]["id"] = "claude.fable"'
if out=$(python3 scripts/mac/corrida-worker.py registry validate --registry "$T/id-punto.json" 2>&1); then
  fail "acepto un id con punto"
fi
printf '%s\n' "$out" | grep -qx 'ERROR invalid id' || fail "id con punto sin diagnostico de id: $out"
mutar_registro "$T/id-guion.json" 'rec["workers"][0]["id"] = "claude-fable"'
python3 scripts/mac/corrida-worker.py registry validate --registry "$T/id-guion.json" >/dev/null 2>&1 \
  && fail "acepto un id con guion"

# 14.13 r2 (B1): los ids de modelo son los MEDIDOS en cada CLI, no los del
# ejemplo de la fila. Cada --model y el campo model de una entrada kimi deben
# existir entre los models del config.toml (fixture versionado, sin secretos).
KMODELS=scripts/tests/fixtures/workers/kimi-models.txt
[ -s "$KMODELS" ] || fail "falta el fixture de models de kimi"
python3 - scripts/mac/workers.v1.json "$KMODELS" <<'PY' || fail "un model de kimi no esta entre los medidos del config.toml"
import json, sys
reg = json.load(open(sys.argv[1]))
validos = {l.strip() for l in open(sys.argv[2]) if l.strip() and not l.startswith("#")}
malos = []
for w in reg["workers"]:
    if not w["id"].startswith("kimi"):
        continue
    if w.get("model") not in validos:
        malos.append(f"{w['id']}: model {w.get('model')!r} no medido")
    for clave, argv in w["commands"].items():
        if "--model" in argv:
            slug = argv[argv.index("--model") + 1]
            if slug not in validos:
                malos.append(f"{w['id']}/{clave}: --model {slug!r} no medido")
        elif clave in ("start:write", "start:review", "resume:write", "resume:review"):
            malos.append(f"{w['id']}/{clave}: sin --model")
assert not malos, malos
PY

echo "TODO VERDE: registro de workers"
