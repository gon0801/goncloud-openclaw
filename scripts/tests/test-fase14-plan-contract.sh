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

grep -qF 'preaprobación versionada' "$ROOT" \
  || fail "el contrato superior no representa la autoridad autonoma aprobada"
grep -qF 'authorization_ref' "$PLAN" \
  || fail "Task 7 no enlaza la corrida con la preaprobacion del dueño"

RUNBOOK=${RUNBOOK:-docs/runbooks/autopilot-fase14.md}
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
