#!/bin/bash
# Task 7: las skills de cierre llevan la ruta autorizada y las copias son
# byte-identicas; main documenta que solo pasa la ruta, no la ejecuta.
# Uso: bash scripts/tests/test-saikit-cierre-pr-merge-owner.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

A=agents/implementer/agent/workshop-skills/saikit-cierre-pr
B=agents/ingenieria/agent/workshop-skills/saikit-cierre-pr
ROUTE=agents/main/agent/workshop-skills/saikit-merge-route

diff -r "$A" "$B" || fail "las copias de saikit-cierre-pr difieren"
grep -q 'authorization_ref' "$A/SKILL.md" || fail "SKILL.md sin la ruta de authorization_ref"
grep -q 'saikit-entrega.v1' "$A/SKILL.md" || fail "SKILL.md sin el recibo saikit-entrega.v1"
grep -q 'compuerta' "$A/SKILL.md" || fail "SKILL.md sin la proyeccion de compuerta"
grep -q 'expectedHeadOid' "$A/SKILL.md" || fail "SKILL.md sin expectedHeadOid"
grep -q 'solo implementer/ingenieria' "$A/SKILL.md" \
  || fail "SKILL.md sin la restriccion de roles"
grep -qE 'main' "$ROUTE/SKILL.md" || fail "saikit-merge-route vacio"
grep -qF 'Solo el closer invoca la ruta' "$ROUTE/SKILL.md" \
  || fail "saikit-merge-route sin la frase de main"
echo "PASS: skills con la ruta autorizada y copias identicas"
