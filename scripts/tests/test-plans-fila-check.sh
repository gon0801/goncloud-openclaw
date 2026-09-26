#!/bin/bash
# Candado de scripts/plans-fila-check.sh: el doc-check de quality.yml revisa
# las 5 columnas tambien en filas con letra (14.13a), que antes se saltaba.
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
chk=scripts/plans-fila-check.sh

printf '%s\n' '| 14.1 | a | b | c | cc:TODO |' | bash "$chk" 2>/dev/null \
  || fail "rechazo una fila numerica valida"
printf '%s\n' '| 14.13a | a | b | c | cc:TODO |' | bash "$chk" 2>/dev/null \
  || fail "rechazo una fila con letra valida"
if printf '%s\n' '| 14.1 | a | b | cc:TODO |' | bash "$chk" 2>/dev/null; then
  fail "acepto una fila numerica con 4 columnas"
fi
if printf '%s\n' '| 14.13a | a | b | cc:TODO |' | bash "$chk" 2>/dev/null; then
  fail "acepto una fila con letra y 4 columnas"
fi
printf '%s\n' '| Etapa | x |' | bash "$chk" 2>/dev/null \
  || fail "reviso una fila que no es del ledger"
grep -qF 'scripts/plans-fila-check.sh' .github/workflows/quality.yml \
  || fail "quality.yml no usa scripts/plans-fila-check.sh"
echo "VERDE: plans-fila-check"
