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
grep -qF 'The gateway hook blocks direct GitHub merge commands and API mutations for every OpenClaw role; standalone CLIs must follow the kit route.' agents/main/agent/workshop-skills/git-commit-push/SKILL.md || { echo 'FAIL: git-commit-push conserva bypass de merge'; exit 1; }
grep -qF 'the OpenClaw gateway hook blocks direct GitHub API and GraphQL merges for every role; standalone CLIs must follow the kit route.' agents/ingenieria/agent/workshop-skills/mac-node-ops/SKILL.md || { echo 'FAIL: mac-node-ops conserva bypass de merge'; exit 1; }
grep -qF '**Sin cuota de CodeRabbit el PR espera**' docs/runbooks/loop-autopilot.md || { echo 'FAIL: runbook omite espera de CodeRabbit'; exit 1; }
grep -qF 'sin revisión completada y estado verde del SHA actual, el merge espera' docs/runbooks/loop-autopilot.md || { echo 'FAIL: tabla de roles permite merge sin CodeRabbit'; exit 1; }
grep -qF 'Puede mergear PRs revisados mediante `saikit-merge.sh --auto`' docs/runbooks/base-openclaw.md || { echo 'FAIL: runbook base prohibe merge a claw'; exit 1; }
grep -qF 'El merge usa la política permanente' docs/runbooks/camino-feliz-producto.md || { echo 'FAIL: camino feliz exige go/no-go por PR'; exit 1; }
awk -F'|' '$2 ~ /^ *7 *$/ { if ($3 !~ /Merge autónomo/) exit 1; found=1 } END { if (!found) exit 1 }' docs/runbooks/camino-feliz-producto.md || { echo 'FAIL: merge debe preceder autorización del SHA integrado'; exit 1; }
echo 'PASS test-cierre-pr-merge-comando'
