#!/bin/bash
# 6.5b (Fase 6): la seccion "Merge por orden del dueno" vive en saikit-cierre-pr,
# movida verbatim desde agent-dispatch, con la orden textual del dueno con fecha y el bypass
# declarado del guard (query=@archivo).
# Uso: bash scripts/tests/test-saikit-cierre-pr-merge-owner.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
F=agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md
[ -f "$F" ] || fail "falta $F"
grep -qF 'Merge por orden del dueño' "$F" || fail "$F: falta la seccion 'Merge por orden del dueño'"
grep -qF 'expectedHeadOid' "$F" || fail "$F: falta expectedHeadOid (texto movido verbatim)"
grep -qF 'UNPROCESSABLE' "$F" || fail "$F: falta la carrera UNPROCESSABLE"
grep -qF 'stacked PRs' "$F" || fail "$F: falta el orden de PRs apilados"
grep -qF 're-targeting' "$F" || fail "$F: falta el re-target"
grep -qF 'query=@archivo' "$F" || fail "$F: falta el bypass declarado del guard"
grep -qF 'orden textual de David con fecha' "$F" || fail "$F: falta la precondicion de la orden del dueno"
grep -qF 'implementer/ingenieria' "$F" || fail "$F: falta la allowlist declarada"
echo "PASS test-saikit-cierre-pr-merge-owner"
