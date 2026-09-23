#!/bin/bash
# Contrato del runbook de cutover (F7/F9): orden seguro en sync y ejemplos completos.
# §4 cambia la accion de GoncloudRepoSync al checkout dedicado, hace read-back y
# RECIEN ENTONCES habilita; la ausencia de .git se comprueba DESPUES de moverlo
# (§5). §3 backup trae -LauncherPaths; §7 nodo trae -NodeConfigSets y
# -PairingCode y no empareja a mano antes (el script exige estado fresco).
# §6 memoria migra con -Apply como payload de la transaccion separada (sin
# -Apply Set-OpenClawMemory.ps1 solo imprime el plan y sale 0; con -Apply
# exige gateway detenido, que solo la transaccion detiene y rearranca).
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

# (5) §1: version de PowerShell con forma valida.
S1=$(sec 1 2)
echo "$S1" | grep -qF 'PSVersion.ToString()' || fail "(5) §1 sin PSVersion.ToString()"
echo "$S1" | grep -qF 'PSValue' && fail "(5) §1 trae PSValue inexistente"
echo "ok (5): preflight pide la version con forma valida"

bloques() { # $1=seccion -> un bloque ``` por linea, en orden (saltos como <LF>)
  printf '%s\n' "$1" | awk '
    /^```/ {
      en = !en
      if (en) buf = ""
      else if (buf != "") { gsub(/\n/, "<LF>", buf); print buf }
      next
    }
    en { buf = buf $0 "\n" }
  '
}

# (6) §6: la migracion que muta lleva -Apply DENTRO de un payload de la
# transaccion separada (patron §3). El ejemplo directo sin -Apply solo
# imprime el plan y sale 0: no migra; y un -Apply suelto frena en
# "gateway en marcha" porque nadie detuvo el gateway.
S6=$(sec 6 7)
B6=$(bloques "$S6")
[ -n "$B6" ] || fail "(6) §6 sin bloques de codigo"
plan=$(printf '%s\n' "$B6" | grep -F 'powershell -NoProfile -File' | grep -F 'Set-OpenClawMemory.ps1')
[ -n "$plan" ] || fail "(6) §6 sin reporte en seco del script de memoria"
printf '%s' "$plan" | grep -qF -- '-Apply' \
  && fail "(6) el reporte en seco de §6 lleva -Apply: dejaria de ser reporte"
payload=$(printf '%s\n' "$B6" | grep -F 'Set-OpenClawMemory.ps1' | grep -F -- '-Apply')
[ -n "$payload" ] || fail "(6) §6 sin payload wrapper de memoria con -Apply: el ejemplo no migra"
printf '%s' "$payload" | grep -qF 'exit $LASTEXITCODE' \
  || fail "(6) payload sin exit explicito (contrato de payload de la transaccion)"
printf '%s' "$payload" | grep -qF -- '-VerifyQuery' \
  || fail "(6) payload sin -VerifyQuery (migrate con -Apply lo exige)"
desp=$(printf '%s\n' "$B6" | grep -F 'Invoke-OpenClawCutover.ps1')
[ -n "$desp" ] || fail "(6) §6 no despacha la migracion por la transaccion separada"
printf '%s' "$desp" | grep -qF -- '-Dispatch' || fail "(6) dispatch sin -Dispatch"
printf '%s' "$desp" | grep -qF -- '-PayloadScript' || fail "(6) dispatch sin -PayloadScript"
i_plan=$(printf '%s\n' "$B6" | grep -nF 'powershell -NoProfile -File' | grep -F 'Set-OpenClawMemory.ps1' | head -1 | cut -d: -f1)
i_payload=$(printf '%s\n' "$B6" | grep -nF 'Set-OpenClawMemory.ps1' | grep -F -- '-Apply' | head -1 | cut -d: -f1)
i_desp=$(printf '%s\n' "$B6" | grep -nF 'Invoke-OpenClawCutover.ps1' | head -1 | cut -d: -f1)
[ "$i_plan" -lt "$i_payload" ] && [ "$i_payload" -lt "$i_desp" ] \
  || fail "(6) orden §6 distinto de reporte -> payload -Apply -> dispatch"
echo "ok (6): §6 migra con -Apply como payload de la transaccion, tras el reporte"

# (7) §6: la transaccion es quien detiene y rearranca el gateway (nadie a
# mano), el exito es terminal=DONE (que ya implica salud 200/200) y el
# rollback por -MigrationPath sigue vigente.
echo "$S6" | grep -q 'transaccion' || fail "(7) §6 no nombra la transaccion separada"
echo "$S6" | grep -qE 'rearranca|reinicia' \
  || fail "(7) §6 no explica quien rearranca el gateway tras el payload"
echo "$S6" | grep -qF 'terminal=DONE' || fail "(7) §6 sin criterio de exito terminal=DONE"
echo "$S6" | grep -qF -- '-Mode rollback' || fail "(7) §6 sin rollback"
echo "$S6" | grep -qF -- '-MigrationPath' || fail "(7) §6 sin -MigrationPath en el rollback"
echo "ok (7): §6 explica detencion/recuperacion del gateway y rollback intacto"

echo "TODO VERDE: cutover-runbook"
