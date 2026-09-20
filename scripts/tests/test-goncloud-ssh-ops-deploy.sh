#!/usr/bin/env bash
# 6.4b: deploy uniforme en goncloud-ssh-ops (rojo primero contra origin/main).
# Anclas: backup app.bak-predeploy-<timestamp> en AMBAS ramas (archive de Orbit
# y git pull de accounting), smoke con codigo HTTP, linea de cierre "Live <SHA>".
set -u
cd "$(dirname "$0")/../.." || exit 1
SKILL=agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md
REF=${TEST_REF:-WORKTREE}
if [ "$REF" = "WORKTREE" ]; then
  f=$(cat "$SKILL" 2>/dev/null) || { echo "FALLO: skill no existe"; exit 1; }
else
  f=$(git show "$REF:$SKILL" 2>/dev/null) || { echo "FALLO: skill no existe en $REF"; exit 1; }
fi
fails=0
printf '%s\n' "$f" | grep -q "app.bak-predeploy-" || { echo "FALLO: sin backup app.bak-predeploy-<timestamp>"; fails=$((fails+1)); }
# rama archive (Orbit): el comando archive lleva el backup inline
printf '%s\n' "$f" | grep -q "cp -a app app.bak-predeploy-\$(date +%Y%m%d-%H%M)" || { echo "FALLO: sin backup con timestamp en rama archive"; fails=$((fails+1)); }
# rama git pull (accounting): backup antes del pull
printf '%s\n' "$f" | grep -q "back up \`cp -a app app.bak-predeploy-" || { echo "FALLO: sin backup antes del pull en rama git pull"; fails=$((fails+1)); }
# smoke con codigo HTTP
printf '%s\n' "$f" | grep -q '%{http_code}' || { echo "FALLO: sin smoke con codigo HTTP"; fails=$((fails+1)); }
printf '%s\n' "$f" | grep -q 'http_code' || { echo "FALLO: sin http_code"; fails=$((fails+1)); }
# precondicion declarada
printf '%s\n' "$f" | grep -qi "Precondition for BOTH branches" || { echo "FALLO: sin precondicion SHA ya en rama de deploy declarada"; fails=$((fails+1)); }
# cierre Live <SHA>
printf '%s\n' "$f" | grep -q 'Live <SHA> en <URL>' || { echo "FALLO: sin linea de cierre Live <SHA> en <URL>"; fails=$((fails+1)); }
if [ $fails -gt 0 ]; then echo "ROJO: $fails fallo(s) en deploy uniforme goncloud-ssh-ops"; exit 1; fi
echo "VERDE: deploy uniforme goncloud-ssh-ops cumple la DoD de 6.4b"
