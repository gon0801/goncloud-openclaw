#!/usr/bin/env bash
# 14.4: contrato del cierre. Las dos copias de saikit-cierre-pr son
# byte-identicas y fijan la ruta del motor (bloque H: merge.py se retiro);
# main no ejecuta el merge (saikit-merge-route).
set -eu
cd "$(dirname "$0")/../.."
a=agents/implementer/agent/workshop-skills/saikit-cierre-pr
b=agents/ingenieria/agent/workshop-skills/saikit-cierre-pr
diff -r "$a" "$b"
grep -qF 'el cierre del PR lo hace el motor: lo que cambia código va por `motor entrega` (skill `motor`); ningún agente mergea ni despliega a mano' "$a/SKILL.md"
grep -qF 'PATH=/opt/homebrew/bin:$PATH' "$a/SKILL.md"
if grep -qF 'merge.py' "$a/SKILL.md"; then
  echo 'FAIL: merge.py sigue presente en saikit-cierre-pr (se retiro en el bloque H)' >&2
  exit 1
fi
grep -qF 'Solo el closer invoca la ruta' agents/main/agent/workshop-skills/saikit-merge-route/SKILL.md
echo 'PASS: cierre de PR con la ruta del motor'
