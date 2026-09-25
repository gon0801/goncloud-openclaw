#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.." || exit 1
if grep -q 'MERGE_AGENT_ALLOWLIST = new Set' summa-gate/lib.ts; then
  echo 'FAIL: queda allowlist de merge directo'; exit 1
fi
for role in implementer ingenieria verifier reviewer adversary; do
  if [ "$role" = implementer ] || [ "$role" = ingenieria ]; then
    skill="agents/$role/agent/workshop-skills/saikit-cierre-pr/SKILL.md"
  else
    skill="workspace-$role/AGENTS.md"
  fi
  grep -qF 'saikit-merge.sh --auto' "$skill" || { echo "FAIL: $role no tiene ruta autónoma"; exit 1; }
done
node --test summa-gate/merge-guard.test.ts >/dev/null || exit 1
echo 'PASS test-merge-allowlist-cierre-pr'
