#!/bin/bash
# Regression for the 2026-09-21 outage: the gateway can keep its port open
# while its event loop is busy. The watchdog must test HTTP readiness without
# killing recoverable SQLite/runtime stalls observed at up to 74 seconds.
set -u
cd "$(dirname "$0")/../.." || exit 1
watchdog=gateway-watchdog.ps1

fail() {
  echo "FAIL: $1"
  exit 1
}

git ls-files --error-unmatch "$watchdog" >/dev/null 2>&1 \
  || fail "$watchdog is not tracked"

while IFS= read -r anchor; do
  [ -n "$anchor" ] || continue
  grep -qF -- "$anchor" "$watchdog" \
    || fail "$watchdog is missing: $anchor"
done <<'ANCHORS'
$gatewayPort = 18789
Get-NetTCPConnection -State Listen -LocalPort $gatewayPort
Invoke-WebRequest -Uri "http://127.0.0.1:$gatewayPort/"
$httpTimeoutSec = 90
bootGraceSeconds
StartTime
taskkill.exe
/T
Start-ScheduledTask -TaskName $gatewayTask
gateway-watchdog.log
WEDGED
ANCHORS

grep -qF 'OwningProcess' "$watchdog" \
  || fail "$watchdog does not identify the listener owner"
grep -qF 'CommandLine -like' "$watchdog" \
  || fail "$watchdog does not filter supervisors by command line"
grep -qE 'taskkill[^#]*($|.*)/IM( |$)' "$watchdog" \
  && fail "$watchdog kills every process by image name"

# Compuerta httpTimeoutSec (Task 2 / 16.2): la asignacion EFECTIVA es
# exactamente un entero >= 90. 89, duplicada, decimal, negativa y texto
# fallan; 90 y 120 pasan sin importar espacios. Misma regla en el espejo
# portable y en Test-EffectiveHttpTimeout del modulo (el deploy la aplica
# contra staging en cada ciclo).
modulo=scripts/runtime-separation/RuntimeSeparation.psm1
PYBIN=$(command -v python3 || command -v python) || fail "sin python3 ni python en PATH"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
cat >"$T/espejo.py" <<'PY'
import re, sys
asigna = re.compile(r"^\s*\$httpTimeoutSec\s*=\s*(.+?)\s*(#.*)?$")
vals = []
for linea in open(sys.argv[1], encoding="utf-8"):
    m = asigna.match(linea.rstrip("\n"))
    if m:
        vals.append(m.group(1))
if len(vals) != 1:
    print("rechazado: se esperaban 1 asignacion, hay %d" % len(vals))
    sys.exit(1)
if not re.fullmatch(r"\d+", vals[0]):
    print(f"rechazado: no es entero: {vals[0]}")
    sys.exit(1)
if int(vals[0]) < 90:
    print(f"rechazado: menor que 90: {vals[0]}")
    sys.exit(1)
print("ok")
PY
"$PYBIN" "$T/espejo.py" "$watchdog" >/dev/null \
  || fail "el watchdog vivo no pasa su propia compuerta timeout"
echo "ok (t0): watchdog vivo con timeout efectivo >= 90"
printf '$httpTimeoutSec = 89\n' >"$T/t89.ps1"
printf '$httpTimeoutSec = 90\n$httpTimeoutSec = 120\n' >"$T/tdup.ps1"
printf '$httpTimeoutSec = 90.0\n' >"$T/tdec.ps1"
printf '$httpTimeoutSec = -5\n' >"$T/tneg.ps1"
printf '$httpTimeoutSec = "90"\n' >"$T/ttxt.ps1"
printf '$httpTimeoutSec = 90\n' >"$T/t90.ps1"
printf '$httpTimeoutSec=120\n' >"$T/t120.ps1"
printf '\t$httpTimeoutSec\t=\t90  # prod\n' >"$T/ttab.ps1"
for f in t89 tdup tdec tneg ttxt; do
  "$PYBIN" "$T/espejo.py" "$T/$f.ps1" >/dev/null 2>&1 \
    && fail "el espejo acepto $f y debio rechazar"
done
for f in t90 t120 ttab; do
  "$PYBIN" "$T/espejo.py" "$T/$f.ps1" >/dev/null 2>&1 \
    || fail "el espejo rechazo $f y debio aceptar"
done
echo "ok (t1): espejo 8/8 fixtures timeout"
grep -qF 'function Test-EffectiveHttpTimeout' "$modulo" \
  || fail "el modulo no trae Test-EffectiveHttpTimeout"
echo "ok (t2): Test-EffectiveHttpTimeout existe en el modulo (su conducta la prueba test-deploy-atomic.sh en windows-contract)"

# (t3) Stand-down de cutover (Task 7 / 16.6): con lease valido para una
# generacion no terminal, el watchdog se aparta antes de tocar nada. El
# modulo se importa desde el checkout FUENTE (scripts/ no se despliega a
# runtime: manifiesto runtime-deploy.v1): una ruta relativa a $PSScriptRoot
# apuntaria a runtime y el stand-down seria codigo muerto en prod.
while IFS= read -r anchor; do
  [ -n "$anchor" ] || continue
  grep -qF -- "$anchor" "$watchdog" \
    || fail "(t3) $watchdog sin stand-down: $anchor"
done <<'ANCHORS'
C:\Users\ehven\src\goncloud-openclaw\scripts\runtime-separation\RuntimeSeparation.psm1
Get-CutoverStandDownGeneration
stand-down
cutover $standGen vigente
ANCHORS
echo "ok (t3a): stand-down anclado con modulo desde fuente"
grep -q 'PSScriptRoot.*[Rr]untime[Ss]eparation' "$watchdog" \
  && fail "(t3) el watchdog busca el modulo relativo a runtime (scripts/ no viaja ahi)"
grep -qF 'function Get-CutoverStandDownGeneration' "$modulo" \
  || fail "(t3) el modulo no trae Get-CutoverStandDownGeneration"
echo "ok (t3b): modulo desde fuente y funcion existe (conducta en test-runtime-cutover-transaction.sh)"
l_stand=$(grep -n -F 'cutover $standGen vigente' "$watchdog" | head -1 | cut -d: -f1)
l_port=$(grep -n 'Get-NetTCPConnection -State Listen' "$watchdog" | head -1 | cut -d: -f1)
[ -n "$l_stand" ] && [ -n "$l_port" ] && [ "$l_stand" -lt "$l_port" ] \
  || fail "(t3) el stand-down no precede a la primera sonda (lineas $l_stand vs $l_port)"
echo "ok (t3c): stand-down precede a toda accion"

# (t4) Stand-down real (F10): ejecuta gateway-watchdog.ps1 de verdad con
# modulo falso. Lease vigente => stand-down (exit 0, generacion en log,
# sin sonda). Lease vacio o modulo ausente => procede (sin stand-down).
# Una inversion de la condicion (-ne por -eq) debe poner este bloque rojo.
PSH="$(command -v pwsh || true)"
[ -n "$PSH" ] || fail "(t4) sin pwsh en PATH"
mkdir -p "$T/wd"
cat >"$T/wd/stub.psm1" <<'PSM'
function Get-CutoverStandDownGeneration {
  return $env:OC_STAND_GEN
}
Export-ModuleMember -Function Get-CutoverStandDownGeneration
PSM
corre_wd() { # $1=tag $2=gen -> exit; log en $T/wd/$1.log
  local tag="$1" gen="$2"
  OC_STAND_GEN="$gen" OPENCLAW_CUTOVER_MODULE="$T/wd/stub.psm1" \
    OPENCLAW_WATCHDOG_LOG="$T/wd/$tag.log" \
    "$PSH" -NoProfile -NonInteractive -File "$watchdog" >"$T/wd/$tag.out" 2>&1
  return $?
}
corre_wd gen "20260922T120000Z-abcdef12" \
  || fail "(t4) stand-down debio salir 0: $(cat "$T/wd/gen.out")"
grep -q 'stand-down' "$T/wd/gen.log" || fail "(t4) sin stand-down con lease vigente"
grep -q 'cutover 20260922T120000Z-abcdef12 vigente' "$T/wd/gen.log" \
  || fail "(t4) sin generacion en el log"
grep -q 'no listener' "$T/wd/gen.log" && fail "(t4) sondo pese al stand-down"
corre_wd vacio "" \
  || fail "(t4) sin lease debio salir 0: $(cat "$T/wd/vacio.out")"
grep -q 'stand-down' "$T/wd/vacio.log" && fail "(t4) stand-down sin lease"
OPENCLAW_CUTOVER_MODULE="$T/wd/no-existe.psm1" OPENCLAW_WATCHDOG_LOG="$T/wd/ausente.log" \
  "$PSH" -NoProfile -NonInteractive -File "$watchdog" >"$T/wd/ausente.out" 2>&1 \
  || fail "(t4) modulo ausente debio salir 0: $(cat "$T/wd/ausente.out")"
[ -f "$T/wd/ausente.log" ] && grep -q 'stand-down' "$T/wd/ausente.log" \
  && fail "(t4) stand-down sin modulo"
echo "ok (t4): stand-down real con lease; sin lease procede"

echo "PASS test-gateway-watchdog"
