#!/bin/bash
# Las copias de la skill de cierre son byte-identicas; main documenta que elige
# quien cierra y no ejecuta el merge.
# Uso: bash scripts/tests/test-saikit-cierre-pr-merge-owner.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

A=agents/implementer/agent/workshop-skills/saikit-cierre-pr
B=agents/ingenieria/agent/workshop-skills/saikit-cierre-pr
ROUTE=agents/main/agent/workshop-skills/saikit-merge-route

diff -r "$A" "$B" || fail "las copias de saikit-cierre-pr difieren"
grep -qE 'main' "$ROUTE/SKILL.md" || fail "saikit-merge-route vacio"
grep -qF 'Solo el closer invoca la ruta' "$ROUTE/SKILL.md" \
  || fail "saikit-merge-route sin la frase de main"
echo "PASS: copias identicas y main no ejecuta el merge"
