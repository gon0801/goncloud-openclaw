#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
lib=summa-gate/lib.ts
[ -f "$lib" ] || { echo "FALLO: falta $lib"; exit 1; }
allow=$(python3 -c "
import re, sys
text = open('summa-gate/lib.ts', encoding='utf-8').read()
m = re.search(r'MERGE_AGENT_ALLOWLIST\s*=\s*new Set\(\[([^\]]*)\]\)', text)
if not m:
    sys.exit('no MERGE_AGENT_ALLOWLIST')
ids = re.findall(r'\"([^\"]+)\"', m.group(1))
if not ids:
    sys.exit('allowlist vacia')
print('\n'.join(ids))
") || { echo "FALLO: no pude leer MERGE_AGENT_ALLOWLIST de $lib"; exit 1; }
while IFS= read -r agent; do
  [ -n "$agent" ] || continue
  skill="agents/${agent}/agent/workshop-skills/saikit-cierre-pr/SKILL.md"
  if [ ! -f "$skill" ]; then
    echo "FALLO: $agent esta en la allowlist y no tiene $skill"
    fails=$((fails+1))
    continue
  fi
  grep -qF 'orden textual de David con fecha' "$skill" || {
    echo "FALLO: $skill no declara la precondicion de la orden del dueno"
    fails=$((fails+1))
  }
done <<EOF
$allow
EOF
if [ $fails -gt 0 ]; then echo "ROJO: $fails fallos en allowlist vs saikit-cierre-pr"; exit 1; fi
echo "VERDE: cada agente de la allowlist tiene saikit-cierre-pr"
