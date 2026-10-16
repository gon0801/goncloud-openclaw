#!/usr/bin/env bash
# 14.4: contrato del cierre. Las dos copias de saikit-cierre-pr son
# byte-identicas y traen el comando de merge; main elige quien cierra
# (saikit-merge-route), nunca ejecuta el merge.
set -eu
cd "$(dirname "$0")/../.."
a=agents/implementer/agent/workshop-skills/saikit-cierre-pr
b=agents/ingenieria/agent/workshop-skills/saikit-cierre-pr
diff -r "$a" "$b"
grep -qF 'python3 scripts/agent-work/merge.py mergear <PR> --sha <head>' "$a/SKILL.md"
grep -qF 'PATH=/opt/homebrew/bin:$PATH' "$a/SKILL.md"
grep -qF 'Solo el closer invoca la ruta' agents/main/agent/workshop-skills/saikit-merge-route/SKILL.md
echo 'PASS: cierre de PR con el comando de merge'
