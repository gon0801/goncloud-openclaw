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

echo "PASS test-gateway-watchdog"
