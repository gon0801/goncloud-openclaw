#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.." || exit 1
skill=agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
grep -qF 'saikit-merge.sh --auto' "$skill" || { echo 'FAIL: main no conoce el gate autónomo'; exit 1; }
grep -qF 'Runtime deployment is a separate step' "$skill" || { echo 'FAIL: falta separación de deploy'; exit 1; }
grep -qF 'regression back to the brief' "$skill" || { echo 'FAIL: falta ruta de regresión'; exit 1; }
echo 'PASS test-agent-dispatch-no-merge'
