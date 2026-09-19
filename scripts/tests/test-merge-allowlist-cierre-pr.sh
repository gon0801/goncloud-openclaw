#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.." || exit 1

# Una skill es la CARPETA, no un archivo suelto (medido el 2026-09-19: el corte de
# saikit-cierre-pr en dos .md desde el gateway puso este candado rojo sin perder una
# sola palabra). Los saltos de linea tampoco son el contrato.
skill_texto() { cat "$1"/*.md 2>/dev/null | tr '\n' ' ' | tr -s ' '; }
tiene() { printf '%s' "$1" | grep -qF "$(printf '%s' "$2" | tr '\n' ' ' | tr -s ' ')"; }
fails=0
lib=summa-gate/lib.ts
[ -f "$lib" ] || { echo "FALLO: falta $lib"; exit 1; }
tmp_allow=$(mktemp)
cat > "$tmp_allow" <<'PY'
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
allow=$(python3 "$tmp_allow")
rc_allow=$?
rm -f "$tmp_allow"
[ "$rc_allow" -eq 0 ] || { echo "FALLO: no pude leer MERGE_AGENT_ALLOWLIST de $lib"; exit 1; }
while IFS= read -r agent; do
  [ -n "$agent" ] || continue
  skill="agents/${agent}/agent/workshop-skills/saikit-cierre-pr"
  if [ ! -d "$skill" ]; then
    echo "FALLO: $agent esta en la allowlist y no tiene $skill"
    fails=$((fails+1))
    continue
  fi
  texto=$(skill_texto "$skill")
  tiene "$texto" 'orden textual de David con fecha' || {
    echo "FALLO: $skill no declara la precondicion de la orden del dueno"
    fails=$((fails+1))
  }
done <<EOF
$allow
EOF
if [ $fails -gt 0 ]; then echo "ROJO: $fails fallos en allowlist vs saikit-cierre-pr"; exit 1; fi
echo "VERDE: cada agente de la allowlist tiene saikit-cierre-pr"
