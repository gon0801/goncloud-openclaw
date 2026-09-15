#!/usr/bin/env bash
# 6.2 (.sh): los 4 workspace-*/AGENTS.md completan el bloque "## Contrato de dispatch"
# con los campos "nunca" y "reporta a". Rojo primero contra origin/main.
set -u
cd "$(dirname "$0")/../.." || exit 1
REF=${TEST_REF:-WORKTREE}
fails=0
for ws in workspace-implementer workspace-verifier workspace-reviewer workspace-adversary; do
  if [ "$REF" = "WORKTREE" ]; then
    f=$(cat "$ws/AGENTS.md" 2>/dev/null) || { echo "FALLO: $ws/AGENTS.md no existe en el working tree"; fails=$((fails+1)); continue; }
  else
    f=$(git show "$REF:$ws/AGENTS.md" 2>/dev/null) || { echo "FALLO: $ws/AGENTS.md no existe en $REF"; fails=$((fails+1)); continue; }
  fi
  bloque=$(printf '%s\n' "$f" | awk '/^## Contrato de dispatch/{flag=1;next} /^## /{flag=0} flag')
  if [ -z "$bloque" ]; then echo "FALLO: $ws no tiene bloque '## Contrato de dispatch'"; fails=$((falls+1)); continue; fi
  printf '%s\n' "$bloque" | grep -qi "Nunca:" || { echo "FALLO: $ws contrato sin campo 'Nunca:'"; fails=$((fails+1)); }
  printf '%s\n' "$bloque" | grep -qi "Reporta" || { echo "FALLO: $ws contrato sin campo 'Reporta'"; fails=$((fails+1)); }
  printf '%s\n' "$bloque" | grep -q "main" || { echo "FALLO: $ws contrato no nombra a main como destinatario"; fails=$((fails+1)); }
done
if [ $fails -gt 0 ]; then echo "ROJO: $fails fallos en contratos de dispatch"; exit 1; fi
echo "VERDE: los 4 contratos de dispatch tienen 'nunca' y 'reporta a main'"
