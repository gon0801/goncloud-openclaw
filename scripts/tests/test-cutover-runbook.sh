#!/bin/bash
# Contrato del runbook de cutover (F7/F9): orden seguro en sync y ejemplos completos.
# §4 cambia la accion de GoncloudRepoSync al checkout dedicado, hace read-back y
# RECIEN ENTONCES habilita; la ausencia de .git se comprueba DESPUES de moverlo
# (§5). §3 backup trae -LauncherPaths; §7 nodo trae -NodeConfigSets y
# -PairingCode y no empareja a mano antes (el script exige estado fresco).
# Uso: bash scripts/tests/test-cutover-runbook.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
RB=docs/runbooks/openclaw-runtime-cutover.md

# (0) El runbook existe.
[ -f "$RB" ] || fail "(0) falta $RB"
echo "ok (0): runbook de cutover existe"

sec() { # $1=ini $2=fin -> bloque de seccion
  sed -n "/^## $1\\./,/^## $2\\./p" "$RB"
}

# (1) §4: cambiar accion -> read-back -> habilitar, en ese orden.
S4=$(sec 4 5)
echo "$S4" | grep -qF '/tr ' || fail "(1) §4 no cambia la accion (/tr) al checkout dedicado"
echo "$S4" | grep -qF '/query /tn "GoncloudRepoSync"' || fail "(1) §4 sin read-back de la accion"
echo "$S4" | grep -qF '/enable' || fail "(1) §4 sin enable"
la=$(printf '%s\n' "$S4" | grep -n -m1 -F '/tr ' | cut -d: -f1)
lb=$(printf '%s\n' "$S4" | grep -n -m1 -F '/query /tn "GoncloudRepoSync"' | cut -d: -f1)
lc=$(printf '%s\n' "$S4" | grep -n -m1 -F '/enable' | cut -d: -f1)
[ "$la" -lt "$lb" ] && [ "$lb" -lt "$lc" ] \
  || fail "(1) orden §4 distinto de accion->read-back->enable"
echo "ok (1): §4 cambia accion, relee y recien habilita"

# (2) La ausencia de .git se comprueba DESPUES de moverlo (§5, no §4).
S5=$(sec 5 6)
echo "$S4" | grep -q 'SIN el `.git`' && fail "(2) §4 exige ausencia de .git antes de moverlo"
echo "$S5" | grep -qF 'Move-OpenClawQuarantine.ps1' || fail "(2) §5 sin ejemplo de mudanza"
echo "$S5" | grep -q 'SIN el `.git`' || fail "(2) §5 no verifica ausencia de .git tras moverlo"
lm=$(printf '%s\n' "$S5" | grep -n -m1 -F 'Move-OpenClawQuarantine.ps1' | cut -d: -f1)
ln=$(printf '%s\n' "$S5" | grep -n -m1 'SIN el `.git`' | cut -d: -f1)
[ "$lm" -lt "$ln" ] || fail "(2) §5 verifica ausencia antes de mover"
echo "ok (2): ausencia de .git se comprueba despues de moverlo"

# (3) §3: el ejemplo de backup trae -LauncherPaths.
S3=$(sec 3 4)
echo "$S3" | grep -qF -- '-LauncherPaths' || fail "(3) ejemplo backup sin -LauncherPaths"
echo "ok (3): backup trae -LauncherPaths"

# (4) §7: el ejemplo de nodo trae sets + pairing y no empareja a mano.
S7=$(sec 7 8)
echo "$S7" | grep -qF -- '-NodeConfigSets' || fail "(4) ejemplo nodo sin -NodeConfigSets"
echo "$S7" | grep -qF -- '-PairingCode' || fail "(4) ejemplo nodo sin -PairingCode"
echo "$S7" | grep -qF 'openclaw node run --pair' \
  && fail "(4) §7 empareja a mano antes del script (el script exige estado fresco)"
echo "$S7" | grep -qi 'fresco' || fail "(4) §7 no advierte estado fresco"
echo "ok (4): nodo trae sets+pairing y no empareja a mano"

echo "TODO VERDE: cutover-runbook"
