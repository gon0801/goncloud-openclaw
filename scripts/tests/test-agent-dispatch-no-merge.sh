#!/bin/bash
# 6.5a (Fase 6): agent-dispatch de main ya no despacha merges ni menciona la accion; trae
# los dos tipos de go/no-go y "regresion vuelve al brief" que consume el mapa 6.4.
# Uso: bash scripts/tests/test-agent-dispatch-no-merge.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
F=agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
[ -f "$F" ] || fail "falta $F"
if grep -qi 'merge' "$F"; then
  grep -in 'merge' "$F" | head -5
  fail "$F: la palabra merge sigue presente (seccion o clausulas viejas)"
fi
grep -qF 'go/no-go' "$F" || fail "$F: falta el go/no-go"
grep -qF 'openclaw and the workspaces' "$F" || fail "$F: falta go/no-go unificado para openclaw y workspaces"
grep -qF 'Orbit and accounting' "$F" || fail "$F: falta go/no-go separado para Orbit y accounting"
grep -qF 'saikit-cierre-pr' "$F" || fail "$F: falta el reenvio de la orden al agente que la ejecuta"
grep -qF 'regression' "$F" || fail "$F: falta 'regression back to the brief'"
echo "PASS test-agent-dispatch-no-merge"
