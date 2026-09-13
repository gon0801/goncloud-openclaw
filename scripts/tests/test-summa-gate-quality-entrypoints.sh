#!/bin/bash
# Contrato de entrypoints de calidad de summa-gate (Fase 5 / 5.2).
# Verifica: (1) el script `check` de summa-gate/package.json cubre los cuatro
# .ts fuente; (2) scripts/run-checks.sh invoca `npm run check`; (3) CI alcanza
# la bateria una sola vez via pre-commit, sin invocacion directa duplicada.
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

# (3) CI llega a la bateria via pre-commit, sin paso directo duplicado.
grep -q 'pre-commit/action' .github/workflows/quality.yml \
  || fail "quality.yml no usa pre-commit/action"
if grep -q 'run: bash scripts/run-checks.sh' .github/workflows/quality.yml; then
  fail "quality.yml invoca scripts/run-checks.sh directamente ademas de pre-commit (doble entrypoint)"
fi
echo "ok (3): CI alcanza la bateria una vez via pre-commit"
echo "PASS test-summa-gate-quality-entrypoints"
