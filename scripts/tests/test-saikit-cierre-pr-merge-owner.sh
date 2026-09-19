#!/bin/bash
# 6.5b (Fase 6): la seccion "Merge por orden del dueno" vive en saikit-cierre-pr,
# movida verbatim desde agent-dispatch, con la orden textual del dueno con fecha y el bypass
# declarado del guard (query=@archivo).
# Uso: bash scripts/tests/test-saikit-cierre-pr-merge-owner.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# Una skill es la CARPETA, no un archivo suelto. Medido el 2026-09-19: un agente
# repartio saikit-cierre-pr en SKILL.md + MERGE-POR-ORDEN.md desde el gateway, el
# sync lo trajo a main y estos candados se pusieron rojos sin que se perdiera una
# sola palabra. El candado afirma que la regla esta EN LA SKILL; en que .md quedo
# y donde cortan los renglones no es el contrato.
skill_texto() { cat "$1"/*.md 2>/dev/null | tr '\n' ' ' | tr -s ' '; }
tiene() { printf '%s' "$1" | grep -qF "$(printf '%s' "$2" | tr '\n' ' ' | tr -s ' ')"; }

D=agents/implementer/agent/workshop-skills/saikit-cierre-pr
[ -d "$D" ] || fail "falta la skill $D"
T=$(skill_texto "$D")
[ -n "$T" ] || fail "$D: no tiene ningun .md"
tiene "$T" 'Merge por orden del dueño' || fail "$D: falta la seccion 'Merge por orden del dueño'"
tiene "$T" 'expectedHeadOid' || fail "$D: falta expectedHeadOid (texto movido verbatim)"
tiene "$T" 'UNPROCESSABLE' || fail "$D: falta la carrera UNPROCESSABLE"
tiene "$T" 'stacked PRs' || fail "$D: falta el orden de PRs apilados"
tiene "$T" 're-targeting' || fail "$D: falta el re-target"
tiene "$T" 'query=@archivo' || fail "$D: falta el bypass declarado del guard"
tiene "$T" 'orden textual de David con fecha' || fail "$D: falta la precondicion de la orden del dueno"
tiene "$T" 'implementer/ingenieria' || fail "$D: falta la allowlist declarada"
echo "PASS test-saikit-cierre-pr-merge-owner"
