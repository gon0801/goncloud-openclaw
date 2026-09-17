#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
lib=summa-gate/lib.ts
[ -f "$lib" ] || { echo "FALLO: falta $lib"; exit 1; }
allow=$(python3 - <<'PY'
import re, sys
text = open("summa-gate/lib.ts", encoding="utf-8").read()
if re.search(r"MERGE_AGENT_ALLOWLIST\.add\s*\(", text):
    sys.exit("MERGE_AGENT_ALLOWLIST.add extra")
sets = re.findall(r"(MERGE_AGENT_\w+)\s*=\s*new Set\(", text)
if sets != ["MERGE_AGENT_ALLOWLIST"]:
    sys.exit("sets extra: " + ",".join(sets))
has_on = re.findall(r"(\w+)\.has\(\s*normalized\(\s*agentId", text)
if not has_on or any(n != "MERGE_AGENT_ALLOWLIST" for n in has_on):
    sys.exit("has() no usa MERGE_AGENT_ALLOWLIST")
m = re.search(r"MERGE_AGENT_ALLOWLIST\s*=\s*new Set\(\[([^\]]*)\]\)", text)
if not m:
    sys.exit("no MERGE_AGENT_ALLOWLIST")
inner = m.group(1)
rest = re.sub(r"""['"][^'"]*['"]""", "", inner)
rest = re.sub(r"[\s,]", "", rest)
if rest:
    sys.exit("allowlist no es un literal plano: " + rest)
ids = re.findall(r"""['"]([^'"]+)['"]""", inner)
if not ids:
    sys.exit("allowlist vacia")
print("\n".join(ids))
PY
) || { echo "FALLO: no pude leer MERGE_AGENT_ALLOWLIST de $lib"; exit 1; }
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
