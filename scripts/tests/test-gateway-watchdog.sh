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

echo "PASS test-gateway-watchdog"
