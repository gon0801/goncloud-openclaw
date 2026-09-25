#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.." || exit 1
a=agents/implementer/agent/workshop-skills/saikit-cierre-pr
b=agents/ingenieria/agent/workshop-skills/saikit-cierre-pr
diff -r "$a" "$b" >/dev/null || { echo 'FAIL: skills de cierre difieren'; exit 1; }
for skill in "$a/SKILL.md" "$b/SKILL.md"; do
  grep -qF 'PATH=/opt/homebrew/bin:$PATH bash /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh --auto' "$skill" || { echo "FAIL: falta comando de kit con PATH en $skill"; exit 1; }
  grep -qF 'no uses GraphQL, REST ni `gh pr merge`' "$skill" || { echo "FAIL: falta bloqueo de bypass en $skill"; exit 1; }
done
grep -qF 'Direct GitHub merge commands and API mutations remain blocked for every role.' agents/main/agent/workshop-skills/git-commit-push/SKILL.md || { echo 'FAIL: git-commit-push conserva bypass de merge'; exit 1; }
grep -qF 'direct GitHub API and GraphQL merges remain blocked for every role.' agents/ingenieria/agent/workshop-skills/mac-node-ops/SKILL.md || { echo 'FAIL: mac-node-ops conserva bypass de merge'; exit 1; }
grep -qF '**Sin cuota de CodeRabbit el PR espera**' docs/runbooks/loop-autopilot.md || { echo 'FAIL: runbook omite espera de CodeRabbit'; exit 1; }
echo 'PASS test-cierre-pr-merge-comando'
