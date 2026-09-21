#!/bin/bash
# Contrato de entrypoints de calidad de summa-gate (Fase 5 / 5.2).
# Verifica: (1) el script `check` de summa-gate/package.json cubre los cuatro
# .ts fuente; (2) scripts/run-checks.sh invoca `npm run check`; (3) CI alcanza
# la bateria una sola vez de forma directa y pre-commit no la corre localmente.
# Uso: bash scripts/tests/test-summa-gate-quality-entrypoints.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# Mismo fallback que scripts/run-checks.sh (elegir_node): el node del PATH
# puede no existir o ser viejo; Node 24 suele vivir fuera del PATH
# ($HOME/.openclaw/tools/...). Un `node` pelado rompe este test en esas
# maquinas aunque la bateria corra bien.
elegir_node() {
  local c
  for c in "$(command -v node 2>/dev/null)" \
           "$HOME/.openclaw/tools/node-v24.19.0/bin/node" \
           /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    local v; v=$("$c" --version 2>/dev/null | sed 's/^v//;s/\..*//')
    [ -n "$v" ] && [ "$v" -ge 22 ] 2>/dev/null && { echo "$c"; return 0; }
  done
  return 1
}
NODE=$(elegir_node) || fail "no hay un node >= 22 disponible (mismo fallback que run-checks.sh)"

# (1) El script check cubre los cuatro fuentes.
[ -f summa-gate/package.json ] || fail "falta summa-gate/package.json"
check=$("$NODE" -e "console.log(require('./summa-gate/package.json').scripts?.check ?? '')" 2>/dev/null) \
  || fail "no se pudo leer scripts.check de summa-gate/package.json"
[ -n "$check" ] || fail "summa-gate/package.json no tiene script check"
for f in index.ts lib.ts observer.ts diagnostic-guard.ts; do
  printf '%s' "$check" | grep -qF "$f" || fail "scripts.check no nombra $f (check=$check)"
done
echo "ok (1): scripts.check cubre index.ts, lib.ts, observer.ts y diagnostic-guard.ts"

# (2) El runner invoca el chequeo de sintaxis.
grep -q 'npm run check' scripts/run-checks.sh \
  || fail "scripts/run-checks.sh no invoca npm run check"
echo "ok (2): scripts/run-checks.sh invoca npm run check"

# (3) La bateria completa pertenece a CI, no al commit local. Un hook pesado aca
# hizo que un cambio de una linea en progress/ tardara minutos y ademas dejara
# artefactos al interrumpirse. Los hooks genericos de pre-commit siguen corriendo.
grep -q 'pre-commit/action' .github/workflows/quality.yml \
  || fail "quality.yml no usa pre-commit/action"
if grep -qE '^[[:space:]]*(- id: run-checks|entry: .*scripts/run-checks\.sh)' .pre-commit-config.yaml; then
  fail "pre-commit todavia conecta la bateria completa: los commits locales deben ser rapidos"
fi
entradas_ci=$(grep -cE '^[[:space:]]*run: bash scripts/run-checks\.sh[[:space:]]*$' .github/workflows/quality.yml || true)
[ "$entradas_ci" -eq 1 ] \
  || fail "CI debe invocar scripts/run-checks.sh exactamente una vez (llega: $entradas_ci)"
echo "ok (3): pre-commit es rapido y CI corre la bateria completa exactamente una vez"

# (4) tablero-runbook (Fase 7 / 7.3): los mismos contratos de entrypoint, incluida la
# preaprobacion del dueño (package.json con check y SIN dependencies).
[ -f tablero-runbook/package.json ] || fail "falta tablero-runbook/package.json"
tr_check=$("$NODE" -e "console.log(require('./tablero-runbook/package.json').scripts?.check ?? '')" 2>/dev/null) \
  || fail "no se pudo leer scripts.check de tablero-runbook/package.json"
tr_test=$("$NODE" -e "console.log(require('./tablero-runbook/package.json').scripts?.test ?? '')" 2>/dev/null)
tr_deps=$("$NODE" -e "const d=require('./tablero-runbook/package.json').dependencies; console.log(d?Object.keys(d).length:0)" 2>/dev/null)
[ -n "$tr_check" ] || fail "tablero-runbook/package.json no tiene script check"
[ "$tr_test" = "node --test" ] || fail "tablero-runbook: scripts.test debe ser 'node --test' (llega: $tr_test)"
[ "$tr_deps" = "0" ] || fail "tablero-runbook/package.json declara dependencies: instalar dependencias esta NEGADO (preaprobaciones Fase 7)"
# El check cubre cada .ts fuente presente (excluye *.test.ts): obliga a actualizar
# scripts.check en el mismo commit que agrega una fuente nueva.
for f in $(cd tablero-runbook && ls *.ts 2>/dev/null | grep -v '\.test\.ts$'); do
  printf '%s' "$tr_check" | grep -qF "$f" || fail "tablero-runbook scripts.check no nombra $f (check=$tr_check)"
done
echo "ok (4): tablero-runbook/package.json con check completo, node --test y sin dependencies"

# (5) el runner corre la bateria de tablero-runbook CON guard de conteo: la medicion de
# Plans 7.3 es que `node --test` en un directorio sin pruebas sale 0, asi que sin el
# guard un arbol sin pruebas pasaria en verde.
grep -q 'tablero-runbook' scripts/run-checks.sh \
  || fail "scripts/run-checks.sh no corre la bateria de tablero-runbook"
grep -q '0 pass' scripts/run-checks.sh \
  || fail "scripts/run-checks.sh no tiene el guard de conteo (0 pass = FALLA) para tablero-runbook"
echo "ok (5): run-checks.sh corre tablero-runbook con guard de conteo"
echo "PASS test-summa-gate-quality-entrypoints"
