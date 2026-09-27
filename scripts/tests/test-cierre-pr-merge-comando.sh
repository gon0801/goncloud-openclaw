#!/usr/bin/env bash
# 14.4: contrato del cierre con la ruta autorizada (Task 7). Las dos copias de
# saikit-cierre-pr son byte-identicas y traen la ruta de autoridad; main
# solo pasa la ruta verificada (saikit-merge-route), nunca la ejecuta.
set -eu
cd "$(dirname "$0")/../.."
a=agents/implementer/agent/workshop-skills/saikit-cierre-pr
b=agents/ingenieria/agent/workshop-skills/saikit-cierre-pr
diff -r "$a" "$b"
grep -qF 'gh pr merge <PR> --squash --match-head-commit <SHA>' "$a/SKILL.md"
grep -qF 'PATH=/opt/homebrew/bin:$PATH' "$a/SKILL.md"
grep -qF 'authorization_ref' "$a/SKILL.md"
grep -qF 'saikit-entrega.v1' "$a/SKILL.md"
grep -qF 'compuerta' "$a/SKILL.md"
grep -qF 'solo implementer/ingenieria' "$a/SKILL.md"
grep -qF 'Solo el closer invoca la ruta' agents/main/agent/workshop-skills/saikit-merge-route/SKILL.md
grep -qF 'La allowlist dura no incluye a' agents/main/agent/workshop-skills/saikit-merge-route/SKILL.md
echo 'PASS: cierre de PR con la ruta autorizada (Task 7)'
