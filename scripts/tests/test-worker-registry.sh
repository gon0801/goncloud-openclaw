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

echo "TODO VERDE: registro de workers"
