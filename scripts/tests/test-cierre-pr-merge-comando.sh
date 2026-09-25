#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/../.."
a=agents/implementer/agent/workshop-skills/saikit-cierre-pr
b=agents/ingenieria/agent/workshop-skills/saikit-cierre-pr
diff -r "$a" "$b"
grep -qF 'gh pr merge <PR> --squash --match-head-commit <SHA>' "$a/SKILL.md"
grep -qF 'PATH=/opt/homebrew/bin:$PATH' "$a/SKILL.md"
if grep -qiE 'NUNCA intentes|orden textual de David con fecha|solo.*implementer/ingenieria' "$a"/*.md; then
  echo 'FAIL: reaparecio una restriccion de merge'; exit 1
fi
echo 'PASS: cierre normal de PR sin orden adicional'
