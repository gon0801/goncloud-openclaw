#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.." || exit 1
a=agents/implementer/agent/workshop-skills/saikit-cierre-pr
b=agents/ingenieria/agent/workshop-skills/saikit-cierre-pr
diff -r "$a" "$b" >/dev/null || { echo 'FAIL: skills de cierre difieren'; exit 1; }
for skill in "$a/SKILL.md" "$b/SKILL.md"; do
  grep -qF 'bash /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh --auto' "$skill" || { echo "FAIL: falta comando de kit en $skill"; exit 1; }
  grep -qF 'no uses GraphQL, REST ni `gh pr merge`' "$skill" || { echo "FAIL: falta bloqueo de bypass en $skill"; exit 1; }
done
echo 'PASS test-cierre-pr-merge-comando'
