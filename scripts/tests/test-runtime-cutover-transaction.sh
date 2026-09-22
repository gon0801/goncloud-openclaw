#!/bin/bash
# Transaccion separada del cutover (Task 7 / 16.6).
#
# Invoke-OpenClawCutover.ps1 corre SEPARADO del gateway: el controlador
# despacha una vez (-Dispatch crea lease + estado + tarea one-shot + tarea
# dead-man) y despues solo lee el recibo; nunca espera otro turno mediado
# por el gateway mientras esta caido. -Run ejecuta stop -> payload ->
# restart -> finalize con reanudacion idempotente, tiempos duros por fase
# y globales, y try/finally que recupera servicio. El exito escribe DONE
# terminal y cancela el dead-man; la muerte del proceso deja IN_PROGRESS
# para que -DeadMan recupere y escriba ROLLED_BACK. El watchdog honra el
# lease solo mientras es valido (Test-CutoverLease del modulo) y con estado
# no terminal. Nota dev: CI ubuntu es autoritativo (windows-contract no
# corre este test); los stubs fingen schtasks/icacls y un gateway falso
# sirve /startupz + /readyz.
#
# Uso: bash scripts/tests/test-runtime-cutover-transaction.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
CUT=scripts/runtime-separation/Invoke-OpenClawCutover.ps1
MODULO=scripts/runtime-separation/RuntimeSeparation.psm1
LEASE_SCHEMA=scripts/runtime-separation/cutover-lease.v1.schema.json
STATE_SCHEMA=scripts/runtime-separation/cutover-state.v1.schema.json
RECIBO_SCHEMA=docs/spec/runtime-separation-receipt.v1.schema.json
PUERTO_FAKE=18797

# (0) Archivos, parseo limpio y motor PowerShell.
[ -f "$CUT" ] || fail "(0) falta $CUT"
[ -f "$LEASE_SCHEMA" ] || fail "(0) falta $LEASE_SCHEMA"
[ -f "$STATE_SCHEMA" ] || fail "(0) falta $STATE_SCHEMA"
PSH="$(command -v pwsh || true)"
[ -n "$PSH" ] || fail "(0) sin pwsh en PATH"
"$PSH" -NoProfile -NonInteractive -Command "
\$e=\$null; \$t=\$null
foreach (\$f in @('$CUT', '$MODULO', 'gateway-watchdog.ps1', 'scripts/restart-openclaw-gateway.ps1')) {
  \$e=\$null; \$t=\$null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path \$f), [ref]\$t, [ref]\$e)
  if (\$e -and \$e.Count -gt 0) { Write-Output (\"errores en \$f\"); \$e | ForEach-Object { \$_.ToString() }; exit 1 }
}
exit 0
" || fail "(0) ParseFile reporto errores"
PYBIN=$(command -v python3 || command -v python) || fail "(0) sin python3 ni python en PATH"
for f in Test-CutoverLease Test-CutoverLeaseObject Test-CutoverStateObject Test-CutoverAcl Get-CutoverStateRoot Get-CutoverStandDownGeneration Remove-SecretValue; do
  grep -qF "function $f" "$MODULO" || fail "(0) el modulo no trae $f"
done
echo "ok (0): archivos, parseo limpio y superficie del modulo"

# (1) Anclas estructurales del script.
while IFS= read -r anchor; do
  [ -n "$anchor" ] || continue
  grep -qF -- "$anchor" "$CUT" || fail "(1) $CUT: falta: $anchor"
done <<'ANCHORS'
[switch]$Dispatch
[switch]$Run
[switch]$DeadMan
se exige exactamente un modo
PSCommandPath
schtasks
/create
/delete
icacls
/inheritance:r
Remove-SecretValue
deadManFireTimeUtc
ANCHORS
echo "ok (1a): modos, tareas, lease y redaccion anclados"
# Los anclas propias de -Run (fases, jobs, sondas, DONE, /change,
# Test-CutoverLease) y -DeadMan (lock, ROLLED_BACK, terminales) viven
# en sus secciones (4) y (6).
grep -q 'Start-ScheduledTask\|Stop-ScheduledTask\|Get-ScheduledTask' "$CUT" \
  && fail "(1) usa cmdlets ScheduledTask: debe usar schtasks CLI fingeable"
echo "ok (1b): schtasks CLI sin cmdlets ScheduledTask"

# --- arnes: stubs icacls/schtasks + fechas ---
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fake-bin"
cat >"$T/fake-bin/icacls" <<'SH'
#!/bin/bash
: "${OC_LOG:=/dev/null}"
echo "icacls $*" >>"$OC_LOG"
for a in "$@"; do
  if [ "$a" = "/inheritance:r" ]; then exit 0; fi
done
if [ "${OC_ACL_MODE:-restricted}" = "open" ]; then
  printf '%s BUILTIN\\Users:(OI)(CI)(RX)\n' "$1"
else
  printf '%s NT AUTHORITY\\SYSTEM:(OI)(CI)(F)\n%s BUILTIN\\Administrators:(OI)(CI)(F)\n' "$1" "$1"
fi
SH
chmod +x "$T/fake-bin/icacls"
export PATH="$T/fake-bin:$PATH"
MODN="$PWD/$MODULO"
GEN_FIJO=20260922T120000Z-abcdef12
AHORA=$("$PYBIN" -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
FUTURO=$("$PYBIN" -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
DMMAS=$("$PYBIN" -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(minutes=90)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
PASADO=$("$PYBIN" -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
PASADO_DM=$("$PYBIN" -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

arma_lease() { # $1=dir $2=gen $3=creado $4=expira [$5=extra-json [$6=deadman-utc]]
  local d="$1" g="$2" c="$3" e="$4" x="${5:-}" dm="${6:-$DMMAS}"
  mkdir -p "$d"
  cat >"$d/lease.json" <<JSON
{"schema": "cutover-lease.v1", "generation": "$g", "createdAt": "$c",
 "expiresAt": "$e", "statePath": "$d/state.json",
 "taskName": "OpenClaw Cutover", "deadManTaskName": "OpenClaw Cutover DeadMan",
 "deadManFireTimeUtc": "$dm", "issuedBy": "test-host"$x}
JSON
}
arma_estado() { # $1=dir $2=gen $3=status [$4=fases-json]
  local d="$1" g="$2" s="$3" f="${4:-[]}"
  mkdir -p "$d"
  cat >"$d/state.json" <<JSON
{"schema": "cutover-state.v1", "generation": "$g", "status": "$s",
 "completedPhases": $f, "updatedAt": "$AHORA", "attempts": 1}
JSON
}
veredicto() { # $1=dir [$2=generacion-esperada] -> True|False en stdout
  local d="$1" g="${2:-}"
  local gx=()
  [ -n "$g" ] && gx=(-ExpectedGeneration "$g")
  "$PSH" -NoProfile -NonInteractive -Command "
Import-Module '$MODN' -Force
\$v = Test-CutoverLease -StateRoot '$d' ${gx[*]}
if (\$v -eq \$true) { 'VEREDICTO-True' } else { 'VEREDICTO-False' }
" 2>"$T/verr.log" | grep -a 'VEREDICTO-' || {
    echo "pwsh fallo: $(cat "$T/verr.log")"; return 99
  }
}

# (2) Matriz del lease: valido, expirado, malformado, ACL abierta,
# ausente, generacion ajena y terminales.
arma_lease "$T/l-ok" "$GEN_FIJO" "$AHORA" "$FUTURO"
arma_estado "$T/l-ok" "$GEN_FIJO" IN_PROGRESS
[ "$(veredicto "$T/l-ok" "$GEN_FIJO")" = "VEREDICTO-True" ] \
  || fail "(2a) lease valido debio dar True"
[ "$(veredicto "$T/l-ok")" = "VEREDICTO-True" ] \
  || fail "(2a) lease valido sin generacion esperada debio dar True"
echo "ok (2a): valido honra la generacion, con o sin ExpectedGeneration"

arma_lease "$T/l-exp" "$GEN_FIJO" "$PASADO_DM" "$PASADO" "" "$PASADO_DM"
arma_estado "$T/l-exp" "$GEN_FIJO" IN_PROGRESS
[ "$(veredicto "$T/l-exp" "$GEN_FIJO")" = "VEREDICTO-False" ] \
  || fail "(2b) lease expirado debio dar False"
echo "ok (2b): expirado no se honra"

arma_lease "$T/l-mal" "$GEN_FIJO" "$AHORA" "$FUTURO"
printf '{no es json' >"$T/l-mal/lease.json"
arma_estado "$T/l-mal" "$GEN_FIJO" IN_PROGRESS
[ "$(veredicto "$T/l-mal" "$GEN_FIJO")" = "VEREDICTO-False" ] \
  || fail "(2c) lease malformado debio dar False"
mkdir -p "$T/l-sinkey"
printf '{"schema": "cutover-lease.v1", "generation": "%s"}' "$GEN_FIJO" >"$T/l-sinkey/lease.json"
arma_estado "$T/l-sinkey" "$GEN_FIJO" IN_PROGRESS
[ "$(veredicto "$T/l-sinkey" "$GEN_FIJO")" = "VEREDICTO-False" ] \
  || fail "(2c) lease sin claves debio dar False"
arma_lease "$T/l-extra" "$GEN_FIJO" "$AHORA" "$FUTURO" ', "otra": 1'
arma_estado "$T/l-extra" "$GEN_FIJO" IN_PROGRESS
[ "$(veredicto "$T/l-extra" "$GEN_FIJO")" = "VEREDICTO-False" ] \
  || fail "(2c) lease con clave extra debio dar False"
echo "ok (2c): malformado, incompleto y con extra no se honran"

arma_lease "$T/l-acl" "$GEN_FIJO" "$AHORA" "$FUTURO"
arma_estado "$T/l-acl" "$GEN_FIJO" IN_PROGRESS
[ "$(OC_ACL_MODE=open veredicto "$T/l-acl" "$GEN_FIJO")" = "VEREDICTO-False" ] \
  || fail "(2d) lease con ACL abierta debio dar False"
[ "$(veredicto "$T/l-acl" "$GEN_FIJO")" = "VEREDICTO-True" ] \
  || fail "(2d) el mismo lease con ACL restringida debio dar True"
echo "ok (2d): ACL abierta rechaza, restringida acepta"

mkdir -p "$T/l-aus"
[ "$(veredicto "$T/l-aus" "$GEN_FIJO")" = "VEREDICTO-False" ] \
  || fail "(2e) lease ausente debio dar False"
echo "ok (2e): ausente no se honra"

[ "$(veredicto "$T/l-ok" "20260922T120000Z-00000000")" = "VEREDICTO-False" ] \
  || fail "(2f) generacion ajena debio dar False"
arma_lease "$T/l-otragen" "$GEN_FIJO" "$AHORA" "$FUTURO"
arma_estado "$T/l-otragen" "20260922T120000Z-00000000" IN_PROGRESS
[ "$(veredicto "$T/l-otragen" "$GEN_FIJO")" = "VEREDICTO-False" ] \
  || fail "(2f) estado de otra generacion debio dar False"
echo "ok (2f): solo esa generacion se honra"

arma_lease "$T/l-done" "$GEN_FIJO" "$AHORA" "$FUTURO"
arma_estado "$T/l-done" "$GEN_FIJO" DONE '["stop", "payload", "restart", "finalize"]'
[ "$(veredicto "$T/l-done" "$GEN_FIJO")" = "VEREDICTO-False" ] \
  || fail "(2g) lease con estado DONE debio dar False"
arma_lease "$T/l-rb" "$GEN_FIJO" "$AHORA" "$FUTURO"
arma_estado "$T/l-rb" "$GEN_FIJO" ROLLED_BACK '["stop"]'
[ "$(veredicto "$T/l-rb" "$GEN_FIJO")" = "VEREDICTO-False" ] \
  || fail "(2g) lease con estado ROLLED_BACK debio dar False"
echo "ok (2g): terminal en estado termina el stand-down aunque el lease siga vigente"

# (2j) Matriz de prefijos exactos: solo prefijos ordenados pasan,
# DONE exige las 4 fases, IN_PROGRESS nunca trae finalize.
"$PSH" -NoProfile -NonInteractive -Command "
Import-Module '$MODN' -Force
\$cases = @(
  @{ s = 'IN_PROGRESS'; c = @('payload'); ok = \$false },
  @{ s = 'IN_PROGRESS'; c = @('stop', 'restart'); ok = \$false },
  @{ s = 'IN_PROGRESS'; c = @('stop', 'stop'); ok = \$false },
  @{ s = 'IN_PROGRESS'; c = @('stop', 'payload', 'restart', 'finalize'); ok = \$false },
  @{ s = 'DONE'; c = @('stop', 'payload', 'restart'); ok = \$false },
  @{ s = 'DONE'; c = @('stop', 'payload', 'restart', 'finalize', 'stop'); ok = \$false },
  @{ s = 'IN_PROGRESS'; c = 'stop'; ok = \$false },
  @{ s = 'IN_PROGRESS'; c = @('stop', 'payload'); ok = \$true },
  @{ s = 'DONE'; c = @('stop', 'payload', 'restart', 'finalize'); ok = \$true },
  @{ s = 'ROLLED_BACK'; c = @('stop'); ok = \$true }
)
foreach (\$t in \$cases) {
  \$doc = [ordered]@{ schema = 'cutover-state.v1'; generation = '$GEN_FIJO';
    status = \$t.s; completedPhases = \$t.c; updatedAt = '$AHORA'; attempts = 1 }
  \$got = Test-CutoverStateObject -StateJson (\$doc | ConvertTo-Json -Depth 4 -Compress)
  if (\$got -cne \$t.ok) { throw ('(2j/matrix) status={0} esperaba {1}, obtuvo {2}' -f \$t.s, \$t.ok, \$got) }
}
'2j-matriz-ok'" 2>"$T/verr.log" | grep -aq '2j-matriz-ok' \
  || fail "(2j) matriz de prefijos: $(cat "$T/verr.log")"
echo "ok (2j): solo prefijos ordenados exactos, DONE exige todo"

# (2i) Stand-down: generacion honrada o vacio, nunca lanza.
standdown() { # $1=dir -> gen o vacio
  "$PSH" -NoProfile -NonInteractive -Command "
Import-Module '$MODN' -Force
'SD:' + (Get-CutoverStandDownGeneration -StateRoot '$1')
" 2>/dev/null | grep -a '^SD:'
}
[ "$(standdown "$T/l-ok")" = "SD:$GEN_FIJO" ] \
  || fail "(2i) lease valido debio devolver la generacion"
[ "$(standdown "$T/l-exp")" = "SD:" ] \
  || fail "(2i) lease expirado debio devolver vacio"
[ "$(standdown "$T/l-aus")" = "SD:" ] \
  || fail "(2i) lease ausente debio devolver vacio"
[ "$(OC_ACL_MODE=open standdown "$T/l-acl")" = "SD:" ] \
  || fail "(2i) ACL abierta debio devolver vacio"
echo "ok (2i): stand-down devuelve gen honrada o vacio"

# (2h) Paridad modulo <-> schemas: los literales que el modulo valida
# son los que traen los archivos de schema (misma regla que x-secret*).
"$PYBIN" - "$LEASE_SCHEMA" "$STATE_SCHEMA" "$MODULO" <<'PY' || exit 1
import json, re, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))
state = json.load(open(sys.argv[2], encoding="utf-8"))
mod = open(sys.argv[3], encoding="utf-8").read()
for want in [lease["properties"]["schema"]["const"],
             lease["properties"]["generation"]["pattern"],
             state["properties"]["schema"]["const"],
             state["properties"]["generation"]["pattern"]]:
    assert want in mod, f"el modulo no trae el literal: {want}"
for lit in ["IN_PROGRESS", "DONE", "ROLLED_BACK",
            "stop", "payload", "restart", "finalize"]:
    assert lit in mod, f"el modulo no trae: {lit}"
assert set(lease["required"]) == {"schema", "generation", "createdAt",
    "expiresAt", "statePath", "taskName", "deadManTaskName",
    "deadManFireTimeUtc", "issuedBy"}, lease["required"]
assert set(state["required"]) == {"schema", "generation", "status",
    "completedPhases", "updatedAt", "attempts"}, state["required"]
assert lease.get("additionalProperties") is False
assert state.get("additionalProperties") is False
print("ok (2h): modulo y schemas dicen lo mismo", file=sys.stderr)
PY
# --- stub schtasks con estado + gateway falso por bandera ---
OC_LOG="$T/schtasks.log"
ST_DIR="$T"
GW_TASK="OpenClaw Gateway"
WD_TASK="OpenClaw Gateway Watchdog"
export OC_LOG ST_DIR GW_TASK WD_TASK
: >"$OC_LOG"
mkdir -p "$T/taskdb"
san() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
resetea_taskdb() { # solo gateway corriendo + watchdog listo (transaccion previa recogida)
  rm -f "$T"/taskdb/*
  printf 'Running' >"$T/taskdb/$(san "$GW_TASK")"
  printf 'Ready' >"$T/taskdb/$(san "$WD_TASK")"
  rm -f "$T/gw-down" "$T/gw-unhealthy"
}
resetea_taskdb
cat >"$T/fake-bin/schtasks" <<'SH'
#!/bin/bash
echo "schtasks $*" >>"$OC_LOG"
op="$1"; shift || true
tn=""; prev=""
for a in "$@"; do
  if [ "$prev" = "/tn" ]; then tn="$a"; fi
  prev="$a"
done
slot="$ST_DIR/taskdb/$(printf '%s' "$tn" | tr -c 'A-Za-z0-9' '_' )"
case "$op" in
  /query)
    if [ -f "$slot" ]; then
      printf 'HostName:      FAKE\nTaskName:      \\%s\nNext Run Time: 9/22/2026 12:00:00 PM\nStatus:        %s\n' "$tn" "$(cat "$slot")"
    else
      echo "ERROR: no existe" >&2; exit 1
    fi
    ;;
  /create)
    if [ "${OC_SCHTASKS_FAIL_CREATE:-0}" = "1" ]; then echo "ERROR: create" >&2; exit 1; fi
    if [ -n "${OC_SCHTASKS_FAIL_CREATE_TN:-}" ] && [ "$tn" = "$OC_SCHTASKS_FAIL_CREATE_TN" ]; then
      echo "ERROR: create $tn" >&2; exit 1
    fi
    printf 'Ready' >"$slot"
    ;;
  /delete)
    if [ "${OC_SCHTASKS_FAIL_DELETE:-0}" = "1" ]; then echo "ERROR: delete" >&2; exit 1; fi
    rm -f "$slot"
    ;;
  /run)
    if [ "${OC_SCHTASKS_FAIL_RUN:-0}" = "1" ]; then echo "ERROR: run" >&2; exit 1; fi
    printf 'Running' >"$slot"
    if [ "$tn" = "$GW_TASK" ]; then
      rm -f "$ST_DIR/gw-down"
      if [ "${OC_GW_UNHEALTHY_AFTER_RUN:-0}" = "1" ]; then : >"$ST_DIR/gw-unhealthy"; fi
    fi
    ;;
  /end)
    if [ "${OC_SCHTASKS_FAIL_END:-0}" = "1" ]; then echo "ERROR: end" >&2; exit 1; fi
    printf 'Ready' >"$slot"
    if [ "$tn" = "$GW_TASK" ] && [ "${OC_SCHTASKS_END_NODOWN:-0}" != "1" ]; then
      : >"$ST_DIR/gw-down"
    fi
    ;;
  /change)
    if [ "${OC_SCHTASKS_FAIL_CHANGE:-0}" = "1" ]; then echo "ERROR: change" >&2; exit 1; fi
    case "$*" in
      */disable)
        if [ "${OC_SCHTASKS_FAIL_DISABLE:-0}" = "1" ]; then echo "ERROR: disable" >&2; exit 1; fi
        ;;
      */enable)
        if [ "${OC_SCHTASKS_FAIL_ENABLE:-0}" = "1" ]; then echo "ERROR: enable" >&2; exit 1; fi
        ;;
    esac
    echo "change $tn $*" >>"$ST_DIR/change.log"
    ;;
  *) echo "schtasks stub: op $op" >&2; exit 99 ;;
esac
SH
chmod +x "$T/fake-bin/schtasks"

# (3) Dispatch: valida, crea lease+estado+tareas, arranca el one-shot.
CUTN="$PWD/$CUT"
SHA40=0123456789abcdef0123456789abcdef01234567
printf 'Write-Output "payload ok"\n' >"$T/payload-ok.ps1"
despacha() { # $1=tag $2=stateroot; overrides D_SHA D_DM D_PAY D_VER D_URL; out en $T/$1.out
  local tag="$1" sr="$2"; shift 2
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$CUTN" \
    -Dispatch -PayloadScript "${D_PAY:-$T/payload-ok.ps1}" -StateRoot "$sr" \
    -GatewayTask "$GW_TASK" -WatchdogTask "$WD_TASK" \
    -HealthUrl "${D_URL:-http://127.0.0.1:$PUERTO_FAKE}" \
    -LeaseMinutes 120 -DeadManAfterMinutes "${D_DM:-90}" \
    -OpenClawVersion "${D_VER:-2026.9.5}" -SourceSha "${D_SHA:-$SHA40}" \
    "$@" >"$T/$tag.out" 2>&1
  return $?
}

: >"$OC_LOG"
despacha d-ok "$T/d-ok" || fail "(3a) dispatch debio salir 0: $(cat "$T/d-ok.out")"
GEN_OK=$(grep -a '^generation=' "$T/d-ok.out" | cut -d= -f2)
printf '%s' "$GEN_OK" | grep -qE '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' \
  || fail "(3a) generation con forma rara: $GEN_OK"
grep -q -a "^receipt=$T/d-ok/receipts/cutover-$GEN_OK.json" "$T/d-ok.out" \
  || fail "(3a) sin ruta de recibo determinista: $(cat "$T/d-ok.out")"
grep -q -a "^state=$T/d-ok/state.json" "$T/d-ok.out" \
  || fail "(3a) sin ruta de estado: $(cat "$T/d-ok.out")"
[ -f "$T/d-ok/lease.json" ] || fail "(3a) falta lease.json"
[ -f "$T/d-ok/state.json" ] || fail "(3a) falta state.json"
echo "ok (3a): dispatch imprime generation, receipt y state"

"$PYBIN" - "$LEASE_SCHEMA" "$STATE_SCHEMA" "$T/d-ok/lease.json" "$T/d-ok/state.json" <<'PY' || exit 1
import json, re, sys
def checa(schema_p, doc_p):
    s = json.load(open(schema_p, encoding="utf-8"))
    d = json.load(open(doc_p, encoding="utf-8"))
    assert set(d.keys()) == set(s["required"]), (doc_p, sorted(d.keys()))
    for k, spec in s["properties"].items():
        v = d[k]
        if "const" in spec:
            assert v == spec["const"], (k, v)
        if "pattern" in spec:
            assert isinstance(v, str) and re.fullmatch(spec["pattern"], v), (k, v)
        if "enum" in spec:
            assert v in spec["enum"], (k, v)
        if spec.get("type") == "array":
            assert isinstance(v, list), (k, v)
            for e in v:
                assert e in spec["items"]["enum"], (k, e)
            assert len(set(v)) == len(v), (k, v)
        if "minLength" in spec:
            assert isinstance(v, str) and len(v) >= spec["minLength"], (k, v)
        if "maxLength" in spec:
            assert len(v) <= spec["maxLength"], (k, v)
        if spec.get("type") == "integer":
            assert isinstance(v, int) and v >= spec.get("minimum", 0), (k, v)
checa(sys.argv[1], sys.argv[3])
checa(sys.argv[2], sys.argv[4])
st = json.load(open(sys.argv[4], encoding="utf-8"))
assert st["status"] == "IN_PROGRESS" and st["completedPhases"] == [], st
print("ok (3b): lease+estado conformes a los schemas", file=sys.stderr)
PY
"$PSH" -NoProfile -NonInteractive -Command "
Import-Module '$MODN' -Force
\$lr = Get-Content -Raw -LiteralPath '$T/d-ok/lease.json'
\$sr = Get-Content -Raw -LiteralPath '$T/d-ok/state.json'
if (-not (Test-CutoverLeaseObject -LeaseJson \$lr)) { exit 11 }
if (-not (Test-CutoverStateObject -StateJson \$sr)) { exit 12 }
if (-not (Test-CutoverLease -StateRoot '$T/d-ok' -ExpectedGeneration '$GEN_OK')) { exit 13 }
Write-Output 'ROUNDTRIP-OK'
" 2>&1 | grep -q 'ROUNDTRIP-OK' || fail "(3b) el modulo no acepta lo que dispatch escribio"
echo "ok (3b): lease+estado conformes a schemas y al modulo"

[ "$(grep -a -c 'schtasks /create' "$OC_LOG")" -eq 2 ] \
  || fail "(3c) se esperaban 2 /create: $(cat "$OC_LOG")"
ONESHOT=$(grep -a 'schtasks /create /tn OpenClaw Cutover /tr ' "$OC_LOG")
DEADMAN=$(grep -a 'schtasks /create /tn OpenClaw Cutover DeadMan /tr ' "$OC_LOG")
[ -n "$ONESHOT" ] && [ -n "$DEADMAN" ] \
  || fail "(3c) faltan /create one-shot o dead-man: $(cat "$OC_LOG")"
for linea in "$ONESHOT" "$DEADMAN"; do
  printf '%s' "$linea" | grep -q -a -F -- "$CUTN" \
    || fail "(3c) /create sin ruta absoluta al script: $linea"
  printf '%s' "$linea" | grep -q -a -F -- "$GEN_OK" \
    || fail "(3c) /create sin generacion: $linea"
  printf '%s' "$linea" | grep -q -a -E '/sc once /st [0-9]{2}:[0-9]{2} /sd [0-9]{2}/[0-9]{2}/[0-9]{4}' \
    || fail "(3c) /create sin one-shot con deadline: $linea"
done
printf '%s' "$ONESHOT" | grep -q -a -E -- '-Run( |$)' \
  || fail "(3c) one-shot sin -Run"
printf '%s' "$ONESHOT" | grep -q -a -E -- '-DeadMan( |$)' \
  && fail "(3c) one-shot lleva -DeadMan (modos cruzados)"
printf '%s' "$DEADMAN" | grep -q -a -E -- '-DeadMan( |$)' \
  || fail "(3c) dead-man sin -DeadMan"
printf '%s' "$DEADMAN" | grep -q -a -E -- '-Run( |$)' \
  && fail "(3c) dead-man lleva -Run (modos cruzados)"
grep -a -q "schtasks /run /tn $GW_TASK" "$OC_LOG" \
  && fail "(3c) dispatch arranco el gateway"
grep -a -q 'schtasks /run /tn OpenClaw Cutover DeadMan' "$OC_LOG" \
  && fail "(3c) dispatch arranco el dead-man (solo dispara por deadline)"
grep -a -q 'schtasks /run /tn OpenClaw Cutover$' "$OC_LOG" \
  || fail "(3c) dispatch no arranco el one-shot"
grep -a -q 'icacls .* /inheritance:r' "$OC_LOG" \
  || fail "(3c) dispatch no bloqueo la ACL antes de escribir"
echo "ok (3c): dos /create one-shot con ruta absoluta, /run al one-shot, ACL primero"

resetea_taskdb
despacha d-ok2 "$T/d-ok2" || fail "(3d) segundo dispatch debio salir 0: $(cat "$T/d-ok2.out")"
GEN_OK2=$(grep -a '^generation=' "$T/d-ok2.out" | cut -d= -f2)
[ -n "$GEN_OK2" ] && [ "$GEN_OK2" != "$GEN_OK" ] \
  || fail "(3d) generacion repetida: $GEN_OK2 vs $GEN_OK"
echo "ok (3d): cada dispatch crea una generacion unica"

# (3e) Validacion previa: cero mutaciones ante args invalidos.
printf 'no es powershell\n' >"$T/payload.txt"
for caso in sha plazo relativo ausente version salud ext; do
  : >"$OC_LOG"
  unset D_SHA D_DM D_PAY D_VER D_URL
  case "$caso" in
    sha)      D_SHA="zzz" ;;
    plazo)    D_DM=130 ;;
    relativo) D_PAY="relativo.ps1" ;;
    ausente)  D_PAY="$T/no-existe.ps1" ;;
    version)  D_VER="ayer" ;;
    salud)    D_URL="http://example.com:9" ;;
    ext)      D_PAY="$T/payload.txt" ;;
  esac
  if despacha "d-$caso" "$T/d-$caso"; then
    fail "(3e/$caso) args invalidos salieron 0"
  fi
  unset D_SHA D_DM D_PAY D_VER D_URL
  grep -a -q 'schtasks /create' "$OC_LOG" && fail "(3e/$caso) creo tareas con args invalidos"
  [ -e "$T/d-$caso/lease.json" ] && fail "(3e/$caso) escribio lease con args invalidos"
done
echo "ok (3e): validacion previa sin mutaciones (sha, plazo, payload, version)"

# (3f) Tareas previas sin cancelar: se niega, no se pisa.
resetea_taskdb
: >"$OC_LOG"
printf 'Ready' >"$T/taskdb/$(san 'OpenClaw Cutover')"
despacha d-prev "$T/d-prev" >/dev/null 2>&1 \
  && fail "(3f) piso una tarea one-shot previa"
[ -e "$T/d-prev/lease.json" ] && fail "(3f) escribio lease con tarea previa"
rm -f "$T/taskdb/$(san 'OpenClaw Cutover')"
printf 'Ready' >"$T/taskdb/$(san 'OpenClaw Cutover DeadMan')"
despacha d-prev2 "$T/d-prev2" >/dev/null 2>&1 \
  && fail "(3f) piso una tarea dead-man previa"
rm -f "$T/taskdb/$(san 'OpenClaw Cutover DeadMan')"
echo "ok (3f): tarea previa sin cancelar bloquea el dispatch"

# (3g) ACL abierta al despachar: falla antes de crear tareas.
resetea_taskdb
: >"$OC_LOG"
if OC_ACL_MODE=open despacha d-acl "$T/d-acl" >/dev/null 2>&1; then
  fail "(3g) dispatch con ACL abierta salio 0"
fi
[ -e "$T/d-acl/lease.json" ] && fail "(3g) escribio lease con ACL abierta"
grep -a -q 'schtasks /create' "$OC_LOG" && fail "(3g) creo tareas con ACL abierta"
echo "ok (3g): ACL abierta falla cerrado antes de crear nada"

# (3h) Si el segundo /create falla, limpia la primera tarea creada.
resetea_taskdb
: >"$OC_LOG"
if OC_SCHTASKS_FAIL_CREATE_TN='OpenClaw Cutover DeadMan' despacha d-limpia "$T/d-limpia" >/dev/null 2>&1; then
  fail "(3h) dispatch con /create fallido salio 0"
fi
[ -e "$T/d-limpia/lease.json" ] && fail "(3h) escribio lease con /create fallido"
[ "$(grep -a -c 'schtasks /delete' "$OC_LOG")" -eq 2 ] \
  || fail "(3h) no intento limpiar las 2 tareas: $(cat "$OC_LOG")"
[ -e "$T/taskdb/$(san 'OpenClaw Cutover')" ] \
  && fail "(3h) la primera tarea creada quedo huerfana"
echo "ok (3h): fallo parcial de /create limpia lo creado"

# (3i) Si /run falla, avisa y sigue: el backstop /st dispara el one-shot.
resetea_taskdb
: >"$OC_LOG"
OC_SCHTASKS_FAIL_RUN=1 despacha d-run "$T/d-run" >/dev/null 2>&1 \
  || fail "(3i) dispatch con /run fallido debio salir 0 (backstop cubre)"
grep -a -q 'aviso: /run del one-shot fallo' "$T/d-run.out" \
  || fail "(3i) sin aviso de /run fallido: $(cat "$T/d-run.out")"
[ -f "$T/d-run/lease.json" ] || fail "(3i) sin lease tras /run fallido"
echo "ok (3i): /run fallido avisa y sigue por backstop"

# (4a) Anclas propias de -Run (literales de codigo, no de comentarios).
while IFS= read -r anchor; do
  [ -n "$anchor" ] || continue
  grep -qF -- "$anchor" "$CUT" || fail "(4a) $CUT: falta: $anchor"
done <<'ANCHORS'
Test-CutoverLease -StateRoot
/change
completedPhases
[IO.FileShare]::None
Start-Job
Wait-Job
Stop-Job
Write-ReceiptAtomic
/startupz
/readyz
} finally {
'DONE'
'ROLLED_BACK'
'IN_PROGRESS'
myAttempt
HeartbeatStaleSec
ANCHORS
echo "ok (4a): fases, lock, jobs, sondas, terminales y latido anclados"

# --- gateway falso dirigido por banderas ---
cat >"$T/fake-gw.py" <<PY
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
ST = os.environ["ST_DIR"]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if os.path.exists(ST + "/gw-down"):
            try:
                self.connection.shutdown(2)
            except OSError:
                pass
            self.close_connection = True
            return
        if os.path.exists(ST + "/gw-unhealthy"):
            body = b'{"status":"unhealthy"}'
            self.send_response(500)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path in ("/startupz", "/readyz"):
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", $PUERTO_FAKE), H).serve_forever()
PY
"$PYBIN" "$T/fake-gw.py" >"$T/gw.log" 2>&1 &
GW_PID=$!
trap 'kill $GW_PID 2>/dev/null; rm -rf "$T"' EXIT
i=0
while ! "$PYBIN" -c "import socket; socket.create_connection(('127.0.0.1', $PUERTO_FAKE), 1).close()" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || { kill $GW_PID 2>/dev/null; fail "(4) el gateway falso no levanto"; }
  sleep 0.2
done

PAY_OK_SHA=$(shasum -a 256 "$T/payload-ok.ps1" | cut -d' ' -f1)
cat >"$T/payload-mark.ps1" <<'PS1'
[IO.File]::WriteAllText($env:PAY_MARKER, 'ran')
Write-Output 'payload marco'
PS1
PAY_MARK_SHA=$(shasum -a 256 "$T/payload-mark.ps1" | cut -d' ' -f1)
CANARY='sk-TestCanaryCutover7'
cat >"$T/payload-canary.ps1" <<PS1
Write-Output "fuga $CANARY por stdout"
PS1
cat >"$T/payload-fail.ps1" <<'PS1'
Write-Output 'payload fallo'
exit 3
PS1
PAY_FAIL_SHA=$(shasum -a 256 "$T/payload-fail.ps1" | cut -d' ' -f1)
cat >"$T/payload-duerme.ps1" <<'PS1'
Start-Sleep -Seconds 30
PS1
PAY_SLEEP_SHA=$(shasum -a 256 "$T/payload-duerme.ps1" | cut -d' ' -f1)

corre() { # $1=tag $2=stateroot $3=generation $4=payload $5=sha; overrides C_PHASE C_GLOBAL C_REC
  local tag="$1" sr="$2" g="$3" pay="$4" sha="$5"; shift 5
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$CUTN" \
    -Run -Generation "$g" -StateRoot "$sr" \
    -GatewayTask "$GW_TASK" -WatchdogTask "$WD_TASK" \
    -HealthUrl "http://127.0.0.1:$PUERTO_FAKE" \
    -PhaseTimeoutSec "${C_PHASE:-30}" -GlobalTimeoutSec "${C_GLOBAL:-120}" -ProbeTimeoutSec 2 \
    -LockTimeoutSec 5 -RecoverTimeoutSec "${C_REC:-30}" -PayloadScript "$pay" -PayloadSha256 "$sha" \
    -OpenClawVersion 2026.9.5 -SourceSha "$SHA40" "$@" >"$T/$tag.out" 2>&1
  return $?
}
valida_recibo() { # $1=ruta -> exige Test-ReceiptObject del modulo
  "$PSH" -NoProfile -NonInteractive -Command "
Import-Module '$MODN' -Force
\$r = Get-Content -Raw -LiteralPath '$1'
if (Test-ReceiptObject -ReceiptJson \$r -SchemaPath '$PWD/$RECIBO_SCHEMA') { 'RECIBO-OK' } else { 'RECIBO-MAL' }
" 2>"$T/recerr.log" | grep -q 'RECIBO-OK' \
    || fail "(recibo) $1 no pasa Test-ReceiptObject: $(cat "$T/recerr.log")"
}

# (4b) Exito: stop -> payload -> restart -> finalize, DONE y recibo passed.
resetea_taskdb
: >"$OC_LOG"
D_PAY="$T/payload-mark.ps1" despacha r-disp "$T/r-ok" \
  || fail "(4b) dispatch debio salir 0: $(cat "$T/r-disp.out")"
unset D_PAY
GEN_RUN=$(grep -a '^generation=' "$T/r-disp.out" | cut -d= -f2)
REC_RUN=$(grep -a '^receipt=' "$T/r-disp.out" | cut -d= -f2)
export PAY_MARKER="$T/r-ok-marker"
: >"$OC_LOG"
corre r-ok "$T/r-ok" "$GEN_RUN" "$T/payload-mark.ps1" "$PAY_MARK_SHA" \
  || fail "(4b) run debio salir 0: $(cat "$T/r-ok.out")"
grep -a -q "terminal=DONE generation=$GEN_RUN" "$T/r-ok.out" \
  || fail "(4b) sin linea terminal DONE: $(cat "$T/r-ok.out")"
[ "$(cat "$PAY_MARKER" 2>/dev/null)" = "ran" ] || fail "(4b) el payload no marco"
grep -a -q "schtasks /change /tn $WD_TASK /disable" "$OC_LOG" \
  || fail "(4b) sin /disable del watchdog"
grep -a -q "schtasks /end /tn $GW_TASK" "$OC_LOG" \
  || fail "(4b) sin /end del gateway"
grep -a -q "schtasks /run /tn $GW_TASK" "$OC_LOG" \
  || fail "(4b) sin /run del gateway"
grep -a -q "schtasks /change /tn $WD_TASK /enable" "$OC_LOG" \
  || fail "(4b) sin re-enable del watchdog"
grep -a -q 'schtasks /delete /tn OpenClaw Cutover DeadMan /f' "$OC_LOG" \
  || fail "(4b) sin cancelacion del dead-man"
"$PYBIN" - "$T/r-ok/state.json" <<'PY' || exit 1
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
assert st["status"] == "DONE", st
assert st["completedPhases"] == ["stop", "payload", "restart", "finalize"], st
assert st["attempts"] == 1, st
print("ok (4b): estado DONE con las 4 fases", file=sys.stderr)
PY
[ -f "$REC_RUN" ] || fail "(4b) recibo fuera de la ruta impresa por dispatch"
valida_recibo "$REC_RUN"
"$PYBIN" - "$REC_RUN" "$T/r-ok/lease.json" "$PAY_MARK_SHA" <<'PY' || exit 1
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
lease = json.load(open(sys.argv[2], encoding="utf-8"))
assert r["result"] == "passed", r["result"]
assert r["health"] == {"startupz": 200, "readyz": 200}, r["health"]
assert r["inputs"]["payloadScript"] == {"algo": "sha256", "sha256": sys.argv[3]}, r["inputs"]
assert r["rollback"]["deadlineUtc"] == lease["deadManFireTimeUtc"], r["rollback"]
assert len(r["commands"]) >= 4, r["commands"]
assert len(r["observations"]) <= 20, r["observations"]
print("ok (4b): recibo passed ligado a payload y lease", file=sys.stderr)
PY
LOG_RUN="$T/r-ok/logs/cutover-$GEN_RUN.log"
[ -f "$LOG_RUN" ] || fail "(4b) falta log durable del run"
echo "ok (4b): exito punta a punta con DONE, recibo y log"

# (4c) Reanudacion: stop ya hecha se salta sin repetir /end ni /disable.
resetea_taskdb
: >"$OC_LOG"
D_PAY="$T/payload-mark.ps1" despacha r-disp2 "$T/r-res" \
  || fail "(4c) dispatch debio salir 0"
unset D_PAY
GEN_RES=$(grep -a '^generation=' "$T/r-disp2.out" | cut -d= -f2)
"$PYBIN" - "$T/r-res/state.json" <<'PY' || exit 1
import json, sys
p = sys.argv[1]
st = json.load(open(p, encoding="utf-8"))
st["completedPhases"] = ["stop"]
st["attempts"] = 2
json.dump(st, open(p, "w", encoding="utf-8"))
print("ok (4c): estado armado con stop hecha", file=sys.stderr)
PY
printf 'Ready' >"$T/taskdb/$(san "$GW_TASK")"
: >"$ST_DIR/gw-down"
export PAY_MARKER="$T/r-res-marker"
rm -f "$PAY_MARKER"
: >"$OC_LOG"
corre r-res "$T/r-res" "$GEN_RES" "$T/payload-mark.ps1" "$PAY_MARK_SHA" \
  || fail "(4c) reanudacion debio salir 0: $(cat "$T/r-res.out")"
grep -a -q "terminal=DONE generation=$GEN_RES" "$T/r-res.out" \
  || fail "(4c) sin DONE en reanudacion"
grep -a -q "schtasks /end /tn $GW_TASK" "$OC_LOG" \
  && fail "(4c) repitio /end con stop ya hecha"
grep -a -q "schtasks /change /tn $WD_TASK /disable" "$OC_LOG" \
  && fail "(4c) repitio /disable con stop ya hecha"
[ "$(cat "$PAY_MARKER" 2>/dev/null)" = "ran" ] || fail "(4c) el payload no corrio al reanudar"
"$PYBIN" - "$T/r-res/state.json" <<'PY' || exit 1
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
assert st["status"] == "DONE", st
assert st["attempts"] == 3, st
print("ok (4c): reanudacion completa y attempts suma", file=sys.stderr)
PY
echo "ok (4c): reanudacion idempotente salta lo hecho"

# (4d) Re-correr tras DONE: noop con exito, cero llamadas, bytes identicos.
SHA_ANTES=$(shasum -a 256 "$T/r-ok/state.json" | cut -d' ' -f1)
REC_ANTES=$(shasum -a 256 "$REC_RUN" | cut -d' ' -f1)
: >"$OC_LOG"
corre r-noop "$T/r-ok" "$GEN_RUN" "$T/payload-mark.ps1" "$PAY_MARK_SHA" \
  || fail "(4d) noop tras DONE debio salir 0: $(cat "$T/r-noop.out")"
grep -a -q "terminal=DONE generation=$GEN_RUN" "$T/r-noop.out" \
  || fail "(4d) sin DONE en noop"
[ -s "$OC_LOG" ] && fail "(4d) noop llamo a schtasks: $(cat "$OC_LOG")"
[ "$(shasum -a 256 "$T/r-ok/state.json" | cut -d' ' -f1)" = "$SHA_ANTES" ] \
  || fail "(4d) noop modifico el estado"
[ "$(shasum -a 256 "$REC_RUN" | cut -d' ' -f1)" = "$REC_ANTES" ] \
  || fail "(4d) noop modifico el recibo"
echo "ok (4d): DONE es idempotente sin mutacion"

# (4e) Payload cambiado desde dispatch: se niega antes de mutar nada.
resetea_taskdb
D_PAY="$T/payload-ok.ps1" despacha r-disp3 "$T/r-swap" >/dev/null 2>&1 \
  || fail "(4e) dispatch debio salir 0"
unset D_PAY
GEN_SWAP=$(grep -a '^generation=' "$T/r-disp3.out" | cut -d= -f2)
printf 'Write-Output "payload SUPLANTADO"\n' >"$T/payload-ok.ps1"
PAY_OK_SHA=$(shasum -a 256 "$T/payload-ok.ps1" | cut -d' ' -f1)
SHA_ESTADO=$(shasum -a 256 "$T/r-swap/state.json" | cut -d' ' -f1)
: >"$OC_LOG"
if corre r-swap "$T/r-swap" "$GEN_SWAP" "$T/payload-ok.ps1" "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"; then
  fail "(4e) payload suplantado salio 0"
fi
grep -a -q 'payload cambio desde dispatch' "$T/r-swap.out" \
  || fail "(4e) sin diagnostico de swap: $(cat "$T/r-swap.out")"
grep -a -E -q 'schtasks /(end|run|change)' "$OC_LOG" \
  && fail "(4e) muto antes de verificar hash: $(cat "$OC_LOG")"
[ "$(shasum -a 256 "$T/r-swap/state.json" | cut -d' ' -f1)" = "$SHA_ESTADO" ] \
  || fail "(4e) toco el estado al negar swap"
echo "ok (4e): swap de payload se niega sin mutar"

# (4f) Lease invalido o generacion ajena: se niega sin mutar.
resetea_taskdb
mkdir -p "$T/r-exp"
arma_lease "$T/r-exp" "$GEN_FIJO" "$PASADO_DM" "$PASADO" "" "$PASADO_DM"
arma_estado "$T/r-exp" "$GEN_FIJO" IN_PROGRESS
: >"$OC_LOG"
if corre r-exp "$T/r-exp" "$GEN_FIJO" "$T/payload-mark.ps1" "$PAY_MARK_SHA"; then
  fail "(4f) lease expirado salio 0"
fi
grep -a -E -q 'schtasks /(end|run|change)' "$OC_LOG" \
  && fail "(4f) muto con lease expirado"
resetea_taskdb
D_PAY="$T/payload-mark.ps1" despacha r-disp4 "$T/r-ajena" >/dev/null 2>&1 \
  || fail "(4f) dispatch debio salir 0"
unset D_PAY
: >"$OC_LOG"
if corre r-ajena "$T/r-ajena" "20260922T120000Z-00000000" "$T/payload-mark.ps1" "$PAY_MARK_SHA"; then
  fail "(4f) generacion ajena salio 0"
fi
grep -a -E -q 'schtasks /(end|run|change)' "$OC_LOG" \
  && fail "(4f) muto con generacion ajena"
echo "ok (4f): lease invalido y generacion ajena se niegan"

# (4g) /change /disable falla: ROLLED_BACK sin haber detenido nada.
resetea_taskdb
: >"$OC_LOG"
D_PAY="$T/payload-mark.ps1" despacha r-disp5 "$T/r-chg" >/dev/null 2>&1 \
  || fail "(4g) dispatch debio salir 0"
unset D_PAY
GEN_CHG=$(grep -a '^generation=' "$T/r-disp5.out" | cut -d= -f2)
REC_CHG="$T/r-chg/receipts/cutover-$GEN_CHG.json"
: >"$OC_LOG"
if OC_SCHTASKS_FAIL_CHANGE=1 corre r-chg "$T/r-chg" "$GEN_CHG" "$T/payload-mark.ps1" "$PAY_MARK_SHA"; then
  fail "(4g) /change fallido salio 0"
fi
grep -a -q "schtasks /end /tn $GW_TASK" "$OC_LOG" \
  && fail "(4g) detuvo el gateway tras /change fallido"
grep -a -q "terminal=ROLLED_BACK generation=$GEN_CHG" "$T/r-chg.out" \
  || fail "(4g) sin terminal ROLLED_BACK: $(cat "$T/r-chg.out")"
"$PYBIN" - "$T/r-chg/state.json" <<'PY' || exit 1
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
assert st["status"] == "ROLLED_BACK", st
assert st["completedPhases"] == [], st
print("ok (4g): ROLLED_BACK sin fases", file=sys.stderr)
PY
valida_recibo "$REC_CHG"
"$PYBIN" - "$REC_CHG" <<'PY' || exit 1
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["result"] == "rolled_back", r["result"]
assert r["health"] == {"startupz": 200, "readyz": 200}, r["health"]
print("ok (4g): recibo rolled_back con servicio sano", file=sys.stderr)
PY
echo "ok (4g): fallo previo a mutar revierte a ROLLED_BACK"

# (5a) Payload con exit != 0: finally rearranca, ROLLED_BACK con stop hecha.
resetea_taskdb
D_PAY="$T/payload-fail.ps1" despacha r-disp6 "$T/r-fail" >/dev/null 2>&1 \
  || fail "(5a) dispatch debio salir 0"
unset D_PAY
GEN_FAIL=$(grep -a '^generation=' "$T/r-disp6.out" | cut -d= -f2)
REC_FAIL="$T/r-fail/receipts/cutover-$GEN_FAIL.json"
: >"$OC_LOG"
if corre r-fail "$T/r-fail" "$GEN_FAIL" "$T/payload-fail.ps1" "$PAY_FAIL_SHA"; then
  fail "(5a) payload fallido salio 0"
fi
grep -a -q "terminal=ROLLED_BACK generation=$GEN_FAIL" "$T/r-fail.out" \
  || fail "(5a) sin terminal ROLLED_BACK: $(cat "$T/r-fail.out")"
grep -a -q "schtasks /end /tn $GW_TASK" "$OC_LOG" \
  || fail "(5a) stop no detuvo antes del payload"
grep -a -q "schtasks /run /tn $GW_TASK" "$OC_LOG" \
  || fail "(5a) finally no rearranco el gateway"
"$PYBIN" - "$T/r-fail/state.json" <<'PY' || exit 1
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
assert st["status"] == "ROLLED_BACK", st
assert st["completedPhases"] == ["stop"], st
print("ok (5a): ROLLED_BACK conserva stop hecha", file=sys.stderr)
PY
valida_recibo "$REC_FAIL"
"$PYBIN" - "$REC_FAIL" <<'PY' || exit 1
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["result"] == "rolled_back", r["result"]
assert r["health"] == {"startupz": 200, "readyz": 200}, r["health"]
assert any("payload" in o for o in r["observations"]), r["observations"]
assert {"name": "payload", "exit": 3} in r["commands"], r["commands"]
print("ok (5a): recibo rolled_back sano con rastro del payload", file=sys.stderr)
PY
echo "ok (5a): payload fallido revierte con servicio recuperado"

# (5b) Lo que el payload imprime se redacta en recibo y log.
PAY_CANARY_SHA=$(shasum -a 256 "$T/payload-canary.ps1" | cut -d' ' -f1)
resetea_taskdb
D_PAY="$T/payload-canary.ps1" despacha r-disp7 "$T/r-can" >/dev/null 2>&1 \
  || fail "(5b) dispatch debio salir 0"
unset D_PAY
GEN_CAN=$(grep -a '^generation=' "$T/r-disp7.out" | cut -d= -f2)
REC_CAN="$T/r-can/receipts/cutover-$GEN_CAN.json"
LOG_CAN="$T/r-can/logs/cutover-$GEN_CAN.log"
corre r-can "$T/r-can" "$GEN_CAN" "$T/payload-canary.ps1" "$PAY_CANARY_SHA" \
  || fail "(5b) run debio salir 0: $(cat "$T/r-can.out")"
grep -a -q -F "$CANARY" "$REC_CAN" && fail "(5b) el recibo fugo el canario"
grep -a -q -F '[REDACTED]' "$REC_CAN" || fail "(5b) el recibo no trae marca de redaccion"
grep -a -q -F "$CANARY" "$LOG_CAN" && fail "(5b) el log fugo el canario"
grep -a -q -F '[REDACTED]' "$LOG_CAN" || fail "(5b) el log no trae marca de redaccion"
valida_recibo "$REC_CAN"
echo "ok (5b): recibo y log redactan formas de secreto"

# (5c) Stop hecha + re-enable fallido: failed SIN terminal (humano/dead-man).
resetea_taskdb
D_PAY="$T/payload-fail.ps1" despacha r-disp8 "$T/r-enf" >/dev/null 2>&1 \
  || fail "(5c) dispatch debio salir 0"
unset D_PAY
GEN_ENF=$(grep -a '^generation=' "$T/r-disp8.out" | cut -d= -f2)
REC_ENF="$T/r-enf/receipts/cutover-$GEN_ENF.json"
if OC_SCHTASKS_FAIL_ENABLE=1 corre r-enf "$T/r-enf" "$GEN_ENF" "$T/payload-fail.ps1" "$PAY_FAIL_SHA"; then
  fail "(5c) re-enable fallido salio 0"
fi
grep -a -q "terminal=FAILED SIN TERMINAL generation=$GEN_ENF" "$T/r-enf.out" \
  || fail "(5c) sin terminal FAILED SIN TERMINAL: $(cat "$T/r-enf.out")"
"$PYBIN" - "$T/r-enf/state.json" <<'PY' || exit 1
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
assert st["status"] == "IN_PROGRESS", st
print("ok (5c): estado queda no terminal", file=sys.stderr)
PY
valida_recibo "$REC_ENF"
"$PYBIN" - "$REC_ENF" <<'PY' || exit 1
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["result"] == "failed", r["result"]
assert r["health"] == {"startupz": 200, "readyz": 200}, r["health"]
print("ok (5c): recibo failed con gateway sano pero sin proteccion", file=sys.stderr)
PY
echo "ok (5c): servicio sin proteccion no declara ROLLED_BACK"

# (6a) Anclas propias de -DeadMan.
while IFS= read -r anchor; do
  [ -n "$anchor" ] || continue
  grep -qF -- "$anchor" "$CUT" || fail "(6a) $CUT: falta: $anchor"
done <<'ANCHORS'
AddSeconds($DeadManWaitSec)
AddSeconds($RecoverTimeoutSec)
run vivo, esperando
run colgado terminado
$dl.taskName
HeartbeatStaleSec
ANCHORS
echo "ok (6a): espera, recuperacion y colgado anclados"

muerto() { # $1=tag $2=stateroot $3=generation; overrides M_WAIT M_STALE M_REC
  local tag="$1" sr="$2" g="$3"; shift 3
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$CUTN" \
    -DeadMan -Generation "$g" -StateRoot "$sr" \
    -GatewayTask "$GW_TASK" -WatchdogTask "$WD_TASK" \
    -HealthUrl "http://127.0.0.1:$PUERTO_FAKE" \
    -ProbeTimeoutSec 2 -LockTimeoutSec 5 -RecoverTimeoutSec "${M_REC:-30}" \
    -DeadManWaitSec "${M_WAIT:-8}" -HeartbeatStaleSec "${M_STALE:-4}" \
    -OpenClawVersion 2026.9.5 -SourceSha "$SHA40" "$@" >"$T/$tag.out" 2>&1
  return $?
}
arma_crash() { # $1=root $2=fases-json -> dispatch + estado rancio IN_PROGRESS
  local sr="$1" fases="$2"
  local tag="disp-$(basename "$sr")"
  resetea_taskdb
  D_PAY="$T/payload-mark.ps1" despacha "$tag" "$sr" >/dev/null 2>&1 \
    || { echo "dispatch para $sr fallo"; return 1; }
  unset D_PAY
  GEN_CRASH=$(grep -a '^generation=' "$T/$tag.out" | cut -d= -f2)
  "$PYBIN" - "$sr/state.json" "$fases" "$PASADO" <<'PY' || return 1
import json, sys
p, fases, viejo = sys.argv[1], sys.argv[2], sys.argv[3]
st = json.load(open(p, encoding="utf-8"))
st["completedPhases"] = json.loads(fases)
st["attempts"] = 1
st["updatedAt"] = viejo
json.dump(st, open(p, "w", encoding="utf-8"))
PY
}

# (6b) Muerte tras stop: recupera servicio y escribe ROLLED_BACK.
arma_crash "$T/dm-stop" '["stop"]' || fail "(6b) no se armo el crash"
GEN_DM_STOP=$GEN_CRASH
REC_DM_STOP="$T/dm-stop/receipts/cutover-$GEN_DM_STOP.json"
printf 'Ready' >"$T/taskdb/$(san "$GW_TASK")"
: >"$ST_DIR/gw-down"
: >"$OC_LOG"
muerto dm-stop "$T/dm-stop" "$GEN_DM_STOP" \
  || fail "(6b) deadman debio salir 0: $(cat "$T/dm-stop.out")"
grep -a -q "terminal=ROLLED_BACK generation=$GEN_DM_STOP" "$T/dm-stop.out" \
  || fail "(6b) sin terminal ROLLED_BACK"
grep -a -q "schtasks /run /tn $GW_TASK" "$OC_LOG" \
  || fail "(6b) no rearranco el gateway caido"
grep -a -q "schtasks /change /tn $WD_TASK /enable" "$OC_LOG" \
  || fail "(6b) no re-habilito el watchdog"
"$PYBIN" - "$T/dm-stop/state.json" <<'PY' || exit 1
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
assert st["status"] == "ROLLED_BACK", st
print("ok (6b): estado ROLLED_BACK", file=sys.stderr)
PY
valida_recibo "$REC_DM_STOP"
"$PYBIN" - "$REC_DM_STOP" <<'PY' || exit 1
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["result"] == "rolled_back", r["result"]
assert r["health"] == {"startupz": 200, "readyz": 200}, r["health"]
assert "payloadScript" not in r["inputs"] and "lease" in r["inputs"], r["inputs"]
assert len(r["commands"]) >= 2, r["commands"]
print("ok (6b): recibo rolled_back del dead-man", file=sys.stderr)
PY
echo "ok (6b): muerte tras stop recupera y revierte"

# (6c) Muerte tras restart (antes de DONE): verifica y revierte sin rebotar.
arma_crash "$T/dm-rest" '["stop", "payload", "restart"]' || fail "(6c) no se armo el crash"
GEN_DM_REST=$GEN_CRASH
REC_DM_REST="$T/dm-rest/receipts/cutover-$GEN_DM_REST.json"
: >"$OC_LOG"
muerto dm-rest "$T/dm-rest" "$GEN_DM_REST" \
  || fail "(6c) deadman debio salir 0: $(cat "$T/dm-rest.out")"
grep -a -q "terminal=ROLLED_BACK generation=$GEN_DM_REST" "$T/dm-rest.out" \
  || fail "(6c) sin terminal ROLLED_BACK"
grep -a -q "schtasks /run /tn $GW_TASK" "$OC_LOG" \
  && fail "(6c) reboto un gateway que ya estaba sano"
grep -a -q "schtasks /change /tn $WD_TASK /enable" "$OC_LOG" \
  || fail "(6c) no re-habilito el watchdog"
valida_recibo "$REC_DM_REST"
echo "ok (6c): muerte tras restart verifica y revierte"

# (6d) DONE + dead-man pendiente: sale sin mutar nada.
SHA_DM_DONE=$(shasum -a 256 "$T/r-ok/state.json" | cut -d' ' -f1)
REC_DM_DONE=$(shasum -a 256 "$REC_RUN" | cut -d' ' -f1)
: >"$OC_LOG"
muerto dm-done "$T/r-ok" "$GEN_RUN" \
  || fail "(6d) deadman ante DONE debio salir 0: $(cat "$T/dm-done.out")"
grep -a -q "terminal=DONE generation=$GEN_RUN" "$T/dm-done.out" \
  || fail "(6d) sin terminal DONE"
[ -s "$OC_LOG" ] && fail "(6d) deadman ante DONE llamo a schtasks: $(cat "$OC_LOG")"
[ "$(shasum -a 256 "$T/r-ok/state.json" | cut -d' ' -f1)" = "$SHA_DM_DONE" ] \
  || fail "(6d) deadman ante DONE toco el estado"
[ "$(shasum -a 256 "$REC_RUN" | cut -d' ' -f1)" = "$REC_DM_DONE" ] \
  || fail "(6d) deadman ante DONE toco el recibo"
echo "ok (6d): DONE no se revierte ni se toca"

# (6e) ROLLED_BACK terminal + gateway caido: no recupera, no sobrescribe.
arma_crash "$T/dm-rb" '["stop"]' || fail "(6e) no se armo el crash"
GEN_DM_RB=$GEN_CRASH
"$PYBIN" - "$T/dm-rb/state.json" <<'PY' || exit 1
import json, sys
p = sys.argv[1]
st = json.load(open(p, encoding="utf-8"))
st["status"] = "ROLLED_BACK"
json.dump(st, open(p, "w", encoding="utf-8"))
PY
printf 'Ready' >"$T/taskdb/$(san "$GW_TASK")"
: >"$ST_DIR/gw-down"
SHA_DM_RB=$(shasum -a 256 "$T/dm-rb/state.json" | cut -d' ' -f1)
: >"$OC_LOG"
muerto dm-rb "$T/dm-rb" "$GEN_DM_RB" \
  || fail "(6e) deadman ante ROLLED_BACK debio salir 0: $(cat "$T/dm-rb.out")"
grep -a -q "schtasks /run /tn $GW_TASK" "$OC_LOG" \
  && fail "(6e) recupero ante un terminal"
[ "$(shasum -a 256 "$T/dm-rb/state.json" | cut -d' ' -f1)" = "$SHA_DM_RB" ] \
  || fail "(6e) sobrescribio un terminal"
echo "ok (6e): terminal nunca se sobrescribe"

# (6f) Generacion ajena o plazos insanos: sin accion ni mutacion.
arma_crash "$T/dm-aj" '[]' || fail "(6f) no se armo el crash"
SHA_DM_AJ=$(shasum -a 256 "$T/dm-aj/state.json" | cut -d' ' -f1)
: >"$OC_LOG"
muerto dm-aj "$T/dm-aj" "20260922T120000Z-00000000" \
  || fail "(6f) generacion ajena debio salir 0: $(cat "$T/dm-aj.out")"
grep -a -q 'generacion ajena' "$T/dm-aj.out" \
  || fail "(6f) sin diagnostico de generacion ajena"
[ -s "$OC_LOG" ] && fail "(6f) generacion ajena llamo a schtasks"
[ "$(shasum -a 256 "$T/dm-aj/state.json" | cut -d' ' -f1)" = "$SHA_DM_AJ" ] \
  || fail "(6f) generacion ajena toco el estado"
if M_WAIT=0 muerto dm-plazo "$T/dm-aj" "$GEN_CRASH"; then
  fail "(6f) plazo insano salio 0"
fi
grep -a -q 'plazos positivos' "$T/dm-plazo.out" \
  || fail "(6f) sin diagnostico de plazo insano: $(cat "$T/dm-plazo.out")"
echo "ok (6f): generacion ajena y plazos insanos sin mutacion"

# (6g) Estado malformado: falla cerrado sin mutar.
arma_crash "$T/dm-mal" '[]' || fail "(6g) no se armo el crash"
printf '{basura' >"$T/dm-mal/state.json"
printf 'Ready' >"$T/taskdb/$(san "$GW_TASK")"
: >"$ST_DIR/gw-down"
: >"$OC_LOG"
if muerto dm-mal "$T/dm-mal" "$GEN_CRASH"; then
  fail "(6g) estado malformado salio 0"
fi
grep -a -E -q 'schtasks /(run|end|change)' "$OC_LOG" \
  && fail "(6g) muto con estado malformado"
echo "ok (6g): malformado falla cerrado"

# (7a) Run vivo: el dead-man espera y recupera cuando muere.
arma_crash "$T/dm-wait" '["stop"]' || fail "(7a) no se armo el crash"
GEN_WAIT=$GEN_CRASH
REC_WAIT="$T/dm-wait/receipts/cutover-$GEN_WAIT.json"
printf 'Ready' >"$T/taskdb/$(san "$GW_TASK")"
: >"$ST_DIR/gw-down"
cat >"$T/latido.py" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone
p = sys.argv[1]
vueltas = int(sys.argv[2])
i = 0
while vueltas == 0 or i < vueltas:
    st = json.load(open(p, encoding="utf-8"))
    st["updatedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    tmp = p + ".tmp-hb"
    json.dump(st, open(tmp, "w", encoding="utf-8"))
    os.replace(tmp, p)
    i += 1
    time.sleep(1)
PY
"$PYBIN" "$T/latido.py" "$T/dm-wait/state.json" 9 &
LAT_PID=$!
: >"$OC_LOG"
INI=$SECONDS
if ! M_WAIT=30 M_STALE=4 muerto dm-wait "$T/dm-wait" "$GEN_WAIT"; then
  kill $LAT_PID 2>/dev/null
  fail "(7a) deadman debio salir 0: $(cat "$T/dm-wait.out")"
fi
ELAP=$((SECONDS - INI))
wait $LAT_PID 2>/dev/null || true
grep -a -q 'run vivo, esperando' "$T/dm-wait.out" \
  || fail "(7a) sin aviso de espera: $(cat "$T/dm-wait.out")"
grep -a -q "terminal=ROLLED_BACK generation=$GEN_WAIT" "$T/dm-wait.out" \
  || fail "(7a) sin ROLLED_BACK tras la espera"
[ "$ELAP" -ge 9 ] || fail "(7a) no espero al run (tardo ${ELAP}s)"
grep -a -q "schtasks /run /tn $GW_TASK" "$OC_LOG" \
  || fail "(7a) no recupero tras morir el run"
valida_recibo "$REC_WAIT"
echo "ok (7a): espera al run vivo y recupera al morir (${ELAP}s)"

# (7b) Run colgado que sobrevive a /end: failed sin terminal, sin pisar.
arma_crash "$T/dm-colg" '["stop"]' || fail "(7b) no se armo el crash"
GEN_COLG=$GEN_CRASH
REC_COLG="$T/dm-colg/receipts/cutover-$GEN_COLG.json"
printf 'Ready' >"$T/taskdb/$(san "$GW_TASK")"
: >"$ST_DIR/gw-down"
"$PYBIN" "$T/latido.py" "$T/dm-colg/state.json" 0 &
LAT_INF=$!
: >"$OC_LOG"
if M_WAIT=6 M_STALE=4 muerto dm-colg "$T/dm-colg" "$GEN_COLG"; then
  kill $LAT_INF 2>/dev/null
  fail "(7b) colgado vivo debio salir 1"
fi
kill $LAT_INF 2>/dev/null
wait $LAT_INF 2>/dev/null || true
grep -a -q 'schtasks /end /tn OpenClaw Cutover$' "$OC_LOG" \
  || fail "(7b) no termino el one-shot colgado: $(cat "$OC_LOG")"
grep -a -q "terminal=FAILED SIN TERMINAL generation=$GEN_COLG" "$T/dm-colg.out" \
  || fail "(7b) sin terminal FAILED SIN TERMINAL: $(cat "$T/dm-colg.out")"
"$PYBIN" - "$T/dm-colg/state.json" <<'PY' || exit 1
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
assert st["status"] == "IN_PROGRESS", st
print("ok (7b): estado intacto no terminal", file=sys.stderr)
PY
[ -f "$REC_COLG" ] || fail "(7b) recibo fuera de la ruta determinista"
valida_recibo "$REC_COLG"
"$PYBIN" - "$REC_COLG" <<'PY' || exit 1
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["result"] == "failed", r["result"]
print("ok (7b): recibo failed del colgado", file=sys.stderr)
PY
echo "ok (7b): colgado vivo se rinde sin pisar"

# (7c) Run colgado que muere tras /end: lo termina y recupera.
arma_crash "$T/dm-colm" '["stop"]' || fail "(7c) no se armo el crash"
GEN_COLM=$GEN_CRASH
REC_COLM="$T/dm-colm/receipts/cutover-$GEN_COLM.json"
printf 'Ready' >"$T/taskdb/$(san "$GW_TASK")"
: >"$ST_DIR/gw-down"
"$PYBIN" "$T/latido.py" "$T/dm-colm/state.json" 6 &
LAT_MUERE=$!
: >"$OC_LOG"
if ! M_WAIT=6 M_STALE=4 muerto dm-colm "$T/dm-colm" "$GEN_COLM"; then
  kill $LAT_MUERE 2>/dev/null
  fail "(7c) deadman debio salir 0: $(cat "$T/dm-colm.out")"
fi
wait $LAT_MUERE 2>/dev/null || true
grep -a -q 'run colgado terminado' "$T/dm-colm.out" \
  || fail "(7c) sin marca de colgado terminado: $(cat "$T/dm-colm.out")"
grep -a -q "terminal=ROLLED_BACK generation=$GEN_COLM" "$T/dm-colm.out" \
  || fail "(7c) sin ROLLED_BACK"
grep -a -q "schtasks /run /tn $GW_TASK" "$OC_LOG" \
  || fail "(7c) no recupero tras terminar el colgado"
valida_recibo "$REC_COLM"
echo "ok (7c): colgado muerto se termina y recupera"

# (7d) Lock ocupado: falla cerrado sin mutar.
arma_crash "$T/dm-lock" '["stop"]' || fail "(7d) no se armo el crash"
SHA_DM_LOCK=$(shasum -a 256 "$T/dm-lock/state.json" | cut -d' ' -f1)
rm -f "$T/lock-ready"
"$PSH" -NoProfile -NonInteractive -Command "
\$fs = [IO.File]::Open('$T/dm-lock/state.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
[IO.File]::WriteAllText('$T/lock-ready', 'listo')
Start-Sleep -Seconds 12
\$fs.Close()
" & LOCK_PID=$!
i=0
while [ ! -f "$T/lock-ready" ]; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || { kill $LOCK_PID 2>/dev/null; fail "(7d) el tenedor no tomo el lock"; }
  sleep 0.2
done
: >"$OC_LOG"
if muerto dm-lock "$T/dm-lock" "$GEN_CRASH"; then
  kill $LOCK_PID 2>/dev/null
  fail "(7d) lock ocupado salio 0"
fi
wait $LOCK_PID 2>/dev/null || true
grep -a -q 'lock ocupado' "$T/dm-lock.out" \
  || fail "(7d) sin diagnostico de lock: $(cat "$T/dm-lock.out")"
[ -s "$OC_LOG" ] && fail "(7d) lock ocupado llamo a schtasks: $(cat "$OC_LOG")"
[ "$(shasum -a 256 "$T/dm-lock/state.json" | cut -d' ' -f1)" = "$SHA_DM_LOCK" ] \
  || fail "(7d) lock ocupado toco el estado"
echo "ok (7d): lock ocupado falla cerrado"

# (8a) Payload excede la fase: se mata (124) y revierte sin esperar el sleep.
resetea_taskdb
D_PAY="$T/payload-duerme.ps1" despacha r-disp9 "$T/r-tph" >/dev/null 2>&1 \
  || fail "(8a) dispatch debio salir 0"
unset D_PAY
GEN_TPH=$(grep -a '^generation=' "$T/r-disp9.out" | cut -d= -f2)
REC_TPH="$T/r-tph/receipts/cutover-$GEN_TPH.json"
: >"$OC_LOG"
INI=$SECONDS
if C_PHASE=3 C_GLOBAL=120 C_REC=10 corre r-tph "$T/r-tph" "$GEN_TPH" "$T/payload-duerme.ps1" "$PAY_SLEEP_SHA"; then
  fail "(8a) payload excedido salio 0"
fi
ELAP=$((SECONDS - INI))
grep -a -q "terminal=ROLLED_BACK generation=$GEN_TPH" "$T/r-tph.out" \
  || fail "(8a) sin ROLLED_BACK: $(cat "$T/r-tph.out")"
[ "$ELAP" -lt 25 ] || fail "(8a) espero el sleep completo (${ELAP}s)"
"$PYBIN" - "$REC_TPH" <<'PY' || exit 1
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["result"] == "rolled_back", r["result"]
assert {"name": "payload", "exit": 124} in r["commands"], r["commands"]
print("ok (8a): payload 124 y rolled_back", file=sys.stderr)
PY
valida_recibo "$REC_TPH"
echo "ok (8a): fase dura mata payload y revierte (${ELAP}s)"

# (8b) Plazo global dentro del payload: aborta con diagnostico.
resetea_taskdb
D_PAY="$T/payload-duerme.ps1" despacha r-disp10 "$T/r-tgl" >/dev/null 2>&1 \
  || fail "(8b) dispatch debio salir 0"
unset D_PAY
GEN_TGL=$(grep -a '^generation=' "$T/r-disp10.out" | cut -d= -f2)
: >"$OC_LOG"
if C_PHASE=60 C_GLOBAL=6 C_REC=10 corre r-tgl "$T/r-tgl" "$GEN_TGL" "$T/payload-duerme.ps1" "$PAY_SLEEP_SHA"; then
  fail "(8b) plazo global salio 0"
fi
grep -a -q 'plazo global excedido' "$T/r-tgl.out" \
  || fail "(8b) sin diagnostico global: $(cat "$T/r-tgl.out")"
grep -a -q "terminal=ROLLED_BACK generation=$GEN_TGL" "$T/r-tgl.out" \
  || fail "(8b) sin ROLLED_BACK"
echo "ok (8b): plazo global aborta dentro del payload"

# (8c) Stop sin bajar: agota la fase y revierte sin fases.
resetea_taskdb
D_PAY="$T/payload-mark.ps1" despacha r-disp11 "$T/r-tst" >/dev/null 2>&1 \
  || fail "(8c) dispatch debio salir 0"
unset D_PAY
GEN_TST=$(grep -a '^generation=' "$T/r-disp11.out" | cut -d= -f2)
: >"$OC_LOG"
if OC_SCHTASKS_END_NODOWN=1 C_PHASE=4 C_GLOBAL=120 C_REC=10 corre r-tst "$T/r-tst" "$GEN_TST" "$T/payload-mark.ps1" "$PAY_MARK_SHA"; then
  fail "(8c) stop colgado salio 0"
fi
grep -a -q 'sigue sirviendo tras fase' "$T/r-tst.out" \
  || fail "(8c) sin diagnostico de stop: $(cat "$T/r-tst.out")"
grep -a -q "terminal=ROLLED_BACK generation=$GEN_TST" "$T/r-tst.out" \
  || fail "(8c) sin ROLLED_BACK"
"$PYBIN" - "$T/r-tst/state.json" <<'PY' || exit 1
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
assert st["status"] == "ROLLED_BACK", st
assert st["completedPhases"] == [], st
print("ok (8c): ROLLED_BACK sin fases", file=sys.stderr)
PY
echo "ok (8c): stop colgado agota fase y revierte"

# (8d) Restart sin verde (500): failed sin terminal, 500 no vale como caido.
resetea_taskdb
D_PAY="$T/payload-mark.ps1" despacha r-disp12 "$T/r-tre" >/dev/null 2>&1 \
  || fail "(8d) dispatch debio salir 0"
unset D_PAY
GEN_TRE=$(grep -a '^generation=' "$T/r-disp12.out" | cut -d= -f2)
REC_TRE="$T/r-tre/receipts/cutover-$GEN_TRE.json"
: >"$OC_LOG"
if OC_GW_UNHEALTHY_AFTER_RUN=1 C_PHASE=4 C_GLOBAL=120 C_REC=8 corre r-tre "$T/r-tre" "$GEN_TRE" "$T/payload-mark.ps1" "$PAY_MARK_SHA"; then
  fail "(8d) restart enfermo salio 0"
fi
grep -a -q 'salud sin verde tras fase' "$T/r-tre.out" \
  || fail "(8d) sin diagnostico de restart: $(cat "$T/r-tre.out")"
grep -a -q "terminal=FAILED SIN TERMINAL generation=$GEN_TRE" "$T/r-tre.out" \
  || fail "(8d) sin FAILED SIN TERMINAL"
"$PYBIN" - "$T/r-tre/state.json" "$REC_TRE" <<'PY' || exit 1
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
r = json.load(open(sys.argv[2], encoding="utf-8"))
assert st["status"] == "IN_PROGRESS", st
assert st["completedPhases"] == ["stop", "payload"], st
assert r["result"] == "failed", r["result"]
assert r["health"] == {"startupz": 500, "readyz": 500}, r["health"]
print("ok (8d): failed con 500 reales y fases parciales", file=sys.stderr)
PY
valida_recibo "$REC_TRE"
echo "ok (8d): restart enfermo no declara recuperacion"

# (8e) Stop con 500 (colgado que responde): no vale como detenido.
resetea_taskdb
: >"$ST_DIR/gw-unhealthy"
D_PAY="$T/payload-mark.ps1" despacha r-disp13 "$T/r-t500" >/dev/null 2>&1 \
  || fail "(8e) dispatch debio salir 0"
unset D_PAY
GEN_T500=$(grep -a '^generation=' "$T/r-disp13.out" | cut -d= -f2)
: >"$OC_LOG"
if OC_SCHTASKS_END_NODOWN=1 C_PHASE=4 C_GLOBAL=120 C_REC=8 corre r-t500 "$T/r-t500" "$GEN_T500" "$T/payload-mark.ps1" "$PAY_MARK_SHA"; then
  fail "(8e) stop con 500 salio 0"
fi
grep -a -q 'sigue sirviendo tras fase' "$T/r-t500.out" \
  || fail "(8e) trato 500 como detenido: $(cat "$T/r-t500.out")"
grep -a -q "terminal=FAILED SIN TERMINAL generation=$GEN_T500" "$T/r-t500.out" \
  || fail "(8e) sin FAILED SIN TERMINAL"
rm -f "$ST_DIR/gw-unhealthy"
echo "ok (8e): 500 no es detenido"

echo "TODO VERDE: cutover-transaction"
