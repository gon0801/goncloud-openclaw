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
  | grep -qx 'VALID workers.v1 6' || fail "el registro real no valida como 6 workers"

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

echo "TODO VERDE: registro de workers"
