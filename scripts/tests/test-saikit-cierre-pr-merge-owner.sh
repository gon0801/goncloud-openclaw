#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.." || exit 1
for role in implementer ingenieria; do
  skill="agents/$role/agent/workshop-skills/saikit-cierre-pr/SKILL.md"
  [ -f "$skill" ] || { echo "FAIL: falta $skill"; exit 1; }
  grep -qF 'Cualquier agente Claw o CLI' "$skill" || { echo "FAIL: $role no admite todos los agentes"; exit 1; }
  grep -qF 'saikit-merge.sh --auto' "$skill" || { echo "FAIL: $role no usa el gate autónomo"; exit 1; }
  grep -qF 'CodeRabbit' "$skill" || { echo "FAIL: $role omite CodeRabbit"; exit 1; }
  [ ! -e "agents/$role/agent/workshop-skills/saikit-cierre-pr/MERGE-POR-ORDEN.md" ] || { echo "FAIL: $role conserva la ruta directa vieja"; exit 1; }
done
echo 'PASS test-saikit-cierre-pr-merge-owner'
