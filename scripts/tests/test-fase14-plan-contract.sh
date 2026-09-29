#!/bin/bash
# Contrato focalizado de la planificación de Fase 14. Evita que ejemplos
# ejecutables y fuentes de autoridad vuelvan a contradecirse entre sí.
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

PLAN=docs/superpowers/plans/2026-09-19-native-harness-orchestration.md
SPEC=docs/superpowers/specs/2026-09-19-native-harness-orchestration-design.md
ROOT=docs/spec/00-project-spec.md

for f in "$PLAN" "$SPEC" "$ROOT"; do
  [ -r "$f" ] || fail "falta $f"
done

grep -qF 'Delivery-without-seal A/B/C' "$PLAN" \
  || fail "la tabla de dependencias omite uno de los bloques A/B/C"

grep -qF -- '--registry scripts/tests/fixtures/workers/selection.json' "$PLAN" \
  || fail "Task 2 reutiliza el registro unitario de un solo worker"
grep -qF 'Create: `scripts/tests/fixtures/workers/request-review.json`' "$PLAN" \
  || fail "Task 2 usa request-review.json sin declararlo"

grep -qF "grep -qx 'ERROR invalid command'" "$PLAN" \
  || fail "la prueba de invalid-command no comprueba el diagnostico"
grep -qF "grep -qx 'ERROR invalid pattern'" "$PLAN" \
  || fail "la prueba de invalid-pattern no comprueba el diagnostico"

grep -qF 'Python 3.10+' "$PLAN" \
  || fail "el plan usa anotaciones 3.10 sin fijar version minima"

grep -qF 'Cursor Agent conserva `--auto-review`, `--sandbox` y `--workspace`' "$SPEC" \
  || fail "la spec manda a Cursor crear otro worktree"

grep -qF 'Cualquier agente Claw o CLI puede mergear y desplegar sin autorización adicional por operación.' "$ROOT" \
  || fail "el contrato superior no representa la autoridad autonoma aprobada"
grep -qF 'authorization_ref' "$PLAN" \
  || fail "Task 7 no enlaza la corrida con la preaprobacion del dueño"
grep -qF 'Create: `scripts/tests/fixtures/corrida/v2-existing-without-workers.json`' "$PLAN" \
  || fail "Task 1 no declara el fixture corrida.v2 legado"
grep -qF 'Create: `scripts/tests/fixtures/corrida/v2-native-workers.json`' "$PLAN" \
  || fail "Task 1 no declara el fixture corrida.v2 enriquecido"
grep -qF 'corrida-worker.py record validate --record scripts/tests/fixtures/corrida/v2-existing-without-workers.json' "$PLAN" \
  || fail "Task 1 no valida por comando el fixture corrida.v2 legado"
grep -qF 'corrida-worker.py record validate --record scripts/tests/fixtures/corrida/v2-native-workers.json' "$PLAN" \
  || fail "Task 1 no valida por comando el fixture corrida.v2 enriquecido"
grep -qF '`authorization_ref` válido y en alcance' Plans.md \
  || fail "la DoD 14.4 omite authorization_ref"

# Enmienda 14.13 (r1): effort, quota_group y {effort} en plan, spec y runbook.
FILA=Plans.md
PROGRESS=docs/spec/runbook-progress.v2.md
RUNBOOK=${RUNBOOK:-docs/runbooks/autopilot-fase14.md}
for f in "$FILA" "$PROGRESS"; do
  [ -r "$f" ] || fail "falta $f"
done

N_REAL=$(python3 -c 'import json; print(len(json.load(open("scripts/mac/workers.v1.json"))["workers"]))')
grep -qF "VALID workers.v1 $N_REAL" "$PLAN" \
  || fail "el plan no fija el N=$N_REAL del registro real (14.13e)"
grep -qF 'claude_fable' "$PLAN" || fail "el plan no enumera claude_fable (14.13)"
grep -qF 'claude_opus' "$PLAN" || fail "el plan no enumera claude_opus (14.13)"
grep -qF 'kimi_k3' "$PLAN" || fail "el plan no enumera kimi_k3 (14.13)"
grep -qF 'kimi_coding' "$PLAN" || fail "el plan no enumera kimi_coding (14.13)"
grep -qF '{effort}' "$PLAN" \
  || fail "el plan no declara el marcador {effort} (14.13)"
grep -qF 'derives its quota group from its `provider`' "$PLAN" \
  || fail "el plan no fija la derivacion provider->quota_group (14.13a)"
grep -qF 'Create: `scripts/tests/fixtures/workers/selection-quota-group.json`' "$PLAN" \
  || fail "el plan no declara el fixture del relevo por quota_group (14.13a)"
grep -qF 'ERROR invalid effort' "$PLAN" \
  || fail "el plan no fija el ERROR de {effort} sin effort (14.13c)"
grep -qF 'Create: `scripts/tests/fixtures/workers/invalid-effort.json`' "$PLAN" \
  || fail "el plan no declara el fixture effort sin argv (14.13c)"
grep -qF 'Create: `scripts/tests/fixtures/workers/invalid-effort-argv.json`' "$PLAN" \
  || fail "el plan no declara el fixture argv sin effort (14.13c)"
grep -qF 'Persist `worker`, `harness`, `provider`, `effort`, `reported_model`, and `session`' "$PLAN" \
  || fail "Task 3 no persiste effort junto a reported_model (14.13d)"
grep -qF 'effort: string | null;' "$PLAN" \
  || fail "WorkerView no tiene effort (14.13d)"

grep -qF 'ocho entradas' "$SPEC" \
  || fail "la spec no fija las ocho entradas del registro (14.13)"
grep -qF 'descarte por `quota_group`' "$SPEC" \
  || fail "la spec sigue descartando un trabajador a la vez (14.13b)"
grep -qF 'lo deriva de su `provider`' "$SPEC" \
  || fail "la spec no fija la derivacion provider->quota_group (14.13a)"

grep -qF 'Descartar el `quota_group` del candidato' "$RUNBOOK" \
  || fail "la fila de recuperacion sigue descartando un solo candidato (14.13b)"
grep -qF 'enmienda 14.13' "$RUNBOOK" \
  || fail "el bloque B1 no nombra la implementacion de la enmienda (14.13)"

grep -qF 'carriles[].worker.effort' "$PROGRESS" \
  || fail "runbook-progress.v2 no documenta effort (14.13d)"
grep -qF 'reported_model' "$PROGRESS" \
  || fail "runbook-progress.v2 no distingue model de reported_model (14.13d)"

grep -qF '6 mientras la enmienda de 14.13 no esté integrada' "$FILA" \
  || fail "la fila 14.1 perdio la condicion explicita del N (14.13e)"
grep -qF 'claude_opus' "$FILA" || fail "la fila 14.13 no nombra claude_opus (14.13)"
grep -qF 'toma como grupo su `provider`' "$FILA" \
  || fail "la fila 14.13a perdio la derivacion provider->quota_group"
grep -qF 'test-instalar-mac.sh:73' "$FILA" \
  || fail "la fila 14.21 perdio el residual del instalador"

QG=scripts/tests/fixtures/workers/selection-quota-group.json
QS=scripts/tests/fixtures/workers/selection-quota-state.json
for f in "$QG" "$QS" \
  scripts/tests/fixtures/workers/invalid-effort.json \
  scripts/tests/fixtures/workers/invalid-effort-argv.json; do
  [ -r "$f" ] || fail "falta el fixture $f (14.13)"
done
python3 scripts/mac/corrida-worker.py registry validate --registry "$QG" \
  | grep -qx 'VALID workers.v1 3' || fail "el fixture del relevo no valida como 3 workers"
python3 - "$QG" "$QS" <<'PY' || fail "los fixtures de la enmienda no tienen la forma fijada"
import json, sys
reg = json.load(open(sys.argv[1]))
workers = {w["id"]: w for w in reg["workers"]}
assert sorted(workers) == ["claude_fable", "claude_opus", "codex"], sorted(workers)
assert "quota_group" not in workers["claude_fable"], "claude_fable debe ir sin quota_group"
assert "quota_group" not in workers["claude_opus"], "claude_opus debe ir sin quota_group"
assert workers["claude_fable"]["provider"] == workers["claude_opus"]["provider"], "deben compartir provider"
state = json.load(open(sys.argv[2]))
assert state["exhausted"] == ["claude_fable"], state["exhausted"]
invalid_effort = json.load(open("scripts/tests/fixtures/workers/invalid-effort.json"))["workers"][0]
assert "effort" in invalid_effort, "invalid-effort debe declarar effort"
argvs = (invalid_effort["commands"]["start:write"], invalid_effort["commands"]["resume:write"])
assert not any("{effort}" in a for a in argvs), "invalid-effort no debe recibir {effort}"
invalid_argv = json.load(open("scripts/tests/fixtures/workers/invalid-effort-argv.json"))["workers"][0]
assert "effort" not in invalid_argv, "invalid-effort-argv no debe declarar effort"
assert any("{effort}" in a for a in invalid_argv["commands"].values()), "invalid-effort-argv debe traer {effort}"
PY
python3 - <<'PY' || fail "el registro real y test-worker-registry.sh no acuerdan el N"
import json, re
real = len(json.load(open("scripts/mac/workers.v1.json"))["workers"])
pinned = re.findall(r"VALID workers\.v1 (\d+)", open("scripts/tests/test-worker-registry.sh").read())
assert pinned and int(pinned[-1]) == real, (pinned, real)
PY

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
awk '
  /^\/usr\/bin\/python3 - <<'"'"'PY'"'"'$/ { inside=1; next }
  inside && /^PY$/ { exit }
  inside { print }
' "$RUNBOOK" > "$TMP/genera.py"
[ -s "$TMP/genera.py" ] || fail "no pude extraer el generador del nacimiento"
PROGRESS_PATH="$TMP/14.json" /usr/bin/python3 "$TMP/genera.py" \
  || fail "el generador del nacimiento no ejecuta"
node --experimental-strip-types --input-type=module - "$TMP/14.json" <<'JS' \
  || fail "el tablero rechaza el JSON inicial de Fase 14"
import fs from "node:fs";
import { validarProgreso } from "./tablero-runbook/contrato.ts";
const doc = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const result = validarProgreso(doc);
if (!result.ok) {
  console.error(result.razones.join("\n"));
  process.exit(1);
}
JS

echo "TODO VERDE: contrato documental de Fase 14"
