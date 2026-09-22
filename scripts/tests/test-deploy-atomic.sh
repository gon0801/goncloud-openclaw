#!/bin/bash
# Contrato atomico del deploy (Task 2 / 16.2).
#
# Invoke-OpenClawDeploy.ps1 por defecto NO toca runtime (report-only); con
# -Apply exige las cuatro raices, valida staging, respalda solo reemplazos,
# reemplaza atomico por archivo, re-lee por hash, sondea salud y revierte el
# conjunto del recibo ante cualquier fallo. Sin `git reset --hard` jamas.
# El humo corre el script de verdad contra temp dirs y un gateway falso.
#
# Uso: bash scripts/tests/test-deploy-atomic.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
DEPLOY=scripts/runtime-separation/Invoke-OpenClawDeploy.ps1
MODULO=scripts/runtime-separation/RuntimeSeparation.psm1
YAML=.github/workflows/quality.yml
PUERTO_FAKE=18799

# (0) El script existe.
[ -f "$DEPLOY" ] || fail "(0) falta $DEPLOY"
echo "ok (0): el script de deploy existe"

# (1) Anclas estructurales.
grep -qF '[switch]$Apply' "$DEPLOY" || fail "(1) sin switch -Apply"
grep -qF 'Write-ReceiptAtomic' "$DEPLOY" || fail "(1) no escribe recibo atomico"
grep -qF 'Test-EffectiveHttpTimeout' "$DEPLOY" || fail "(1) sin compuerta httpTimeoutSec"
grep -qF 'Test-DeployPathClassification' "$DEPLOY" || fail "(1) sin clasificacion por manifiesto"
grep -qF 'Test-HashEqual' "$DEPLOY" || fail "(1) sin re-lectura por hash"
grep -qF 'Test-RootsIsolated' "$DEPLOY" || fail "(1) sin aislamiento de raices"
grep -qF '/startupz' "$DEPLOY" || fail "(1) sin sonda startupz"
grep -qF '/readyz' "$DEPLOY" || fail "(1) sin sonda readyz"
grep -qF 'Move-Item' "$DEPLOY" || fail "(1) sin reemplazo atomico"
grep -qF 'journal' "$DEPLOY" || fail "(1) sin journal"
grep -qF 'config-validate' "$DEPLOY" || fail "(1) sin compuerta config-validate"
grep -qF 'OPENCLAW_DEPLOY_FAULT' "$DEPLOY" || fail "(1) sin inyeccion de fallos"
grep -qF 'reset --hard' "$DEPLOY" && fail "(1) trae git reset --hard: prohibido en runtime"
grep -E 'Remove-Item.*-Recurse' "$DEPLOY" 2>/dev/null | grep -q 'Runtime' \
  && fail "(1) borrado recursivo sobre runtime"
echo "ok (1): estructura anclada y sin reset --hard"

# --- motor PowerShell: obligatorio en Windows, oportunista fuera ---
en_windows=0
[ "${OS:-}" = "Windows_NT" ] && en_windows=1
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) en_windows=1;; esac
PSH="$(command -v powershell.exe || command -v powershell || command -v pwsh || true)"
if [ "$en_windows" -eq 1 ] && [ -z "$PSH" ]; then
  fail "(2) en Windows powershell.exe debe existir"
fi
PYBIN=$(command -v python3 || command -v python) || fail "(2) sin python3 ni python en PATH"

if [ -n "$PSH" ]; then
  for f in Test-DeployPathClassification Test-EffectiveHttpTimeout Test-HashEqual Test-RootsIsolated; do
    grep -qF "function $f" "$MODULO" || fail "(2) el modulo no trae $f"
  done
  T=$(mktemp -d) || exit 1
  trap 'rm -rf "$T"' EXIT
  nat() {
    if [ "$en_windows" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then
      cygpath -w "$1"
    else
      case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$PWD" "$1";; esac
    fi
  }
  # Absolutas: Import-Module 5.1 no resuelve rutas relativas (CI4).
  DEPN=$(nat "$PWD/$DEPLOY"); MODN=$(nat "$PWD/$MODULO")

  arbol() { # $1=dir $2=timeout-watchdog $3=contenido-app
    mkdir -p "$1"
    printf '$httpTimeoutSec = %s\nWrite-Output hola\n' "$2" >"$1/watchdog.ps1"
    printf '%s' "$3" >"$1/app.txt"
  }
  manifiesto() { # $1=destino
    cat >"$1" <<'JSON'
{"schema": "runtime-deploy.v1",
 "sourceRoot": "C:\\Fixtures\\src", "runtimeRoot": "C:\\Fixtures\\rt",
 "allowed": [{"path": "watchdog.ps1", "kind": "file", "reason": "t"},
             {"path": "app.txt", "kind": "file", "reason": "t"},
             {"path": "nuevo.txt", "kind": "file", "reason": "t"}],
 "denied": [{"pattern": "**/*.secret", "reason": "t"}]}
JSON
  }
  SHA40=0123456789abcdef0123456789abcdef01234567

  # openclaw falso: `config validate` dice Config valid salvo OC_VALIDATE=fail.
  mkdir -p "$T/fake-bin"
  cat >"$T/fake-bin/openclaw" <<'SH'
#!/bin/bash
if [ "${OC_VALIDATE:-ok}" = "fail" ]; then echo "Config INVALID (stub)"; exit 1; fi
echo "Config valid (stub)"
SH
  chmod +x "$T/fake-bin/openclaw"
  printf '@if "%%OC_VALIDATE%%"=="fail" goto :invalid\r\n@echo Config valid (stub)\r\n@exit /b 0\r\n:invalid\r\n@echo Config INVALID (stub)\r\n@exit /b 1\r\n' >"$T/fake-bin/openclaw.cmd"
  export PATH="$T/fake-bin:$PATH"

  arbol_sha() { # $1=dir -> sha de (relpath,bytes) ordenado
    "$PYBIN" - "$1" <<'PY'
import hashlib, os, sys
h = hashlib.sha256()
for dp, dn, fn in os.walk(sys.argv[1]):
    for f in sorted(fn):
        p = os.path.join(dp, f)
        h.update(os.path.relpath(p, sys.argv[1]).encode())
        h.update(open(p, "rb").read())
print(h.hexdigest())
PY
  }

  # (2) WhatIf por defecto: cero escrituras en runtime y sin recibo.
  arbol "$T/w-src" 90 'v2-app'
  arbol "$T/w-rt" 90 'v1-app'
  manifiesto "$T/w-man.json"
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$DEPN" \
    -SourceRoot "$(nat "$T/w-src")" -ManifestPath "$(nat "$T/w-man.json")" \
    -StagingRoot "$(nat "$T/w-st")" -ReceiptRoot "$(nat "$T/w-rec")" \
    -OpenClawVersion 2026.9.5 \
    -SourceSha "$SHA40" >"$T/w.out" 2>&1 \
    || fail "(2) WhatIf debio salir 0: $(cat "$T/w.out")"
  [ -e "$T/w-rec" ] && fail "(2) WhatIf creo raiz de recibos"
  [ "$(cat "$T/w-rt/app.txt")" = 'v1-app' ] || fail "(2) WhatIf toco runtime"
  [ -n "$(ls -A "$T/w-rt")" ] || fail "(2) WhatIf vacio runtime"
  echo "ok (2): WhatIf no toca runtime ni escribe recibo"

  # Gateway falso para el camino de exito.
  cat >"$T/fake-gw.py" <<PY
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
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
    [ "$i" -lt 50 ] || { kill $GW_PID 2>/dev/null; fail "(3) el gateway falso no levanto"; }
    sleep 0.2
  done

  # (3) Apply con exito: bytes iguales, recibo passed, respaldo de originales.
  arbol "$T/s-src" 90 'v2-app'
  printf 'nuevo' >"$T/s-src/nuevo.txt"
  arbol "$T/s-rt" 90 'v1-app'
  printf 'igual' >"$T/s-src/igual.txt"
  printf 'igual' >"$T/s-rt/igual.txt"
  manifiesto "$T/s-man.json"
  "$PYBIN" - "$T/s-man.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
m["allowed"].append({"path": "igual.txt", "kind": "file", "reason": "t"})
json.dump(m, open(sys.argv[1], "w", encoding="utf-8"))
PY
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$DEPN" \
    -SourceRoot "$(nat "$T/s-src")" -RuntimeRoot "$(nat "$T/s-rt")" \
    -StagingRoot "$(nat "$T/s-st")" -ReceiptRoot "$(nat "$T/s-rec")" \
    -ManifestPath "$(nat "$T/s-man.json")" -HealthUrl "http://127.0.0.1:$PUERTO_FAKE" \
    -OpenClawVersion 2026.9.5 -SourceSha "$SHA40" -Apply >"$T/s.out" 2>&1 \
    || fail "(3) Apply debio salir 0: $(cat "$T/s.out")"
  # got visible: en Windows el fallo no se puede reproducir en Mac (CI6).
  got_app=$(cat "$T/s-rt/app.txt" 2>/dev/null); got_nuevo=$(cat "$T/s-rt/nuevo.txt" 2>/dev/null)
  got_bak=$(cat "$T/s-st/backup/app.txt" 2>/dev/null)
  dump() { printf '%s' "$1" | od -An -c | tr -d ' \n'; }
  [ "$got_app" = 'v2-app' ] || fail "(3) app.txt no se publico (got [$(dump "$got_app")])"
  [ "$got_nuevo" = 'nuevo' ] || fail "(3) nuevo.txt no se publico (got [$(dump "$got_nuevo")])"
  [ "$got_bak" = 'v1-app' ] \
    || fail "(3) el respaldo no guarda el original de app.txt (got [$(dump "$got_bak")])"
  [ -e "$T/s-st/backup/igual.txt" ] && fail "(3) respaldo incluye igual.txt sin cambios"
  [ -e "$T/s-st/backup/nuevo.txt" ] && fail "(3) respaldo incluye nuevo.txt sin original"
  [ -f "$T/s-st/journal.jsonl" ] || fail "(3) falta journal.jsonl"
  nrec=$(ls "$T/s-rec/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$nrec" -eq 1 ] || fail "(3) se esperaba 1 recibo, hay $nrec"
  REC=$(ls "$T/s-rec/"*.json)
  "$PYBIN" - "$REC" <<'PY' || fail "(3) recibo success malformado"
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["result"] == "passed", r["result"]
assert r["health"] == {"startupz": 200, "readyz": 200}, r["health"]
assert r["schema"] == "runtime-separation-receipt.v1"
PY
  echo "ok (3): Apply publica, respalda originales, recibe passed"

  # (4) Fallo de validacion (timeout 89): cero escrituras, recibo failed.
  arbol "$T/f-src" 89 'v2-app'
  arbol "$T/f-rt" 90 'v1-app'
  manifiesto "$T/f-man.json"
  if "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$DEPN" \
    -SourceRoot "$(nat "$T/f-src")" -RuntimeRoot "$(nat "$T/f-rt")" \
    -StagingRoot "$(nat "$T/f-st")" -ReceiptRoot "$(nat "$T/f-rec")" \
    -ManifestPath "$(nat "$T/f-man.json")" -HealthUrl "http://127.0.0.1:$PUERTO_FAKE" \
    -OpenClawVersion 2026.9.5 -SourceSha "$SHA40" -Apply >"$T/f.out" 2>&1; then
    fail "(4) timeout 89 debio fallar y salio 0"
  fi
  [ "$(cat "$T/f-rt/app.txt")" = 'v1-app' ] || fail "(4) validacion fallida toco runtime"
  [ "$(cat "$T/f-rt/watchdog.ps1" | head -n 1)" = '$httpTimeoutSec = 90' ] \
    || fail "(4) validacion fallida toco watchdog vivo"
  nrec=$(ls "$T/f-rec/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$nrec" -eq 1 ] || fail "(4) se esperaba 1 recibo failed, hay $nrec"
  "$PYBIN" - "$(ls "$T/f-rec/"*.json)" <<'PY' || fail "(4) recibo failed malformado"
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["result"] == "failed", r["result"]
PY
  echo "ok (4): validacion fallida escribe nada y recibe failed"

  # (4b) config validate falla: runtime byte por byte intacto + failed.
  arbol "$T/c-src" 90 'v2-app'
  arbol "$T/c-rt" 90 'v1-app'
  printf 'nuevo' >"$T/c-src/nuevo.txt"
  manifiesto "$T/c-man.json"
  ANTES_C=$(arbol_sha "$T/c-rt")
  if OC_VALIDATE=fail "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$DEPN" \
    -SourceRoot "$(nat "$T/c-src")" -RuntimeRoot "$(nat "$T/c-rt")" \
    -StagingRoot "$(nat "$T/c-st")" -ReceiptRoot "$(nat "$T/c-rec")" \
    -ManifestPath "$(nat "$T/c-man.json")" -HealthUrl "http://127.0.0.1:$PUERTO_FAKE" \
    -OpenClawVersion 2026.9.5 -SourceSha "$SHA40" -Apply >"$T/c.out" 2>&1; then
    fail "(4b) config invalido debio fallar y salio 0"
  fi
  [ "$(arbol_sha "$T/c-rt")" = "$ANTES_C" ] \
    || fail "(4b) config invalido toco runtime"
  "$PYBIN" - "$(ls "$T/c-rec/"*.json)" <<'PY' || fail "(4b) recibo failed malformado"
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["result"] == "failed", r["result"]
assert any(c["name"] == "config-validate" and c["exit"] == 1 for c in r["commands"]), r["commands"]
PY
  echo "ok (4b): config invalido deja runtime intacto byte por byte"

  # (5) Fallo tras reemplazos parciales: revierte SOLO lo listado. El deploy
  # procesa en orden alfabetico (documentado): app.txt y nuevo.txt se
  # publican y watchdog.ps1 falla porque en runtime es un DIRECTORIO (el
  # deploy jamas mueve dentro de un directorio inesperado: falla cerrado).
  arbol "$T/r-src" 90 'v2-app'
  printf 'nuevo' >"$T/r-src/nuevo.txt"
  arbol "$T/r-rt" 90 'v1-app'
  rm "$T/r-rt/watchdog.ps1"
  mkdir -p "$T/r-rt/watchdog.ps1"
  printf 'ajeno' >"$T/r-rt/extra.txt"
  manifiesto "$T/r-man.json"
  if "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$DEPN" \
    -SourceRoot "$(nat "$T/r-src")" -RuntimeRoot "$(nat "$T/r-rt")" \
    -StagingRoot "$(nat "$T/r-st")" -ReceiptRoot "$(nat "$T/r-rec")" \
    -ManifestPath "$(nat "$T/r-man.json")" -HealthUrl "http://127.0.0.1:$PUERTO_FAKE" \
    -OpenClawVersion 2026.9.5 -SourceSha "$SHA40" -Apply >"$T/r.out" 2>&1; then
    fail "(5) reemplazo bloqueado debio fallar y salio 0"
  fi
  [ "$(cat "$T/r-rt/app.txt")" = 'v1-app' ] \
    || fail "(5) rollback no restauro app.txt: $(cat "$T/r-rt/app.txt")"
  [ -e "$T/r-rt/nuevo.txt" ] && fail "(5) rollback no elimino nuevo.txt agregado"
  [ "$(cat "$T/r-rt/extra.txt")" = 'ajeno' ] || fail "(5) rollback toco extra.txt ajeno"
  [ -z "$(ls -A "$T/r-rt/watchdog.ps1")" ] \
    || fail "(5) el deploy metio algo dentro del directorio bloqueante"
  "$PYBIN" - "$(ls "$T/r-rec/"*.json)" <<'PY' || fail "(5) recibo rolled_back malformado"
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["result"] == "rolled_back", r["result"]
PY
  echo "ok (5): rollback restaura lo listado, elimina lo agregado, respeta lo ajeno"

  # (5b) Falla inyectada tras reemplazar (read-back o journal): el archivo
  # ya publicado esta en el conjunto de rollback y vuelve byte por byte.
  for flt in readback journal; do
    arbol "$T/fi-$flt-src" 90 'v2-app'
    printf 'nuevo' >"$T/fi-$flt-src/nuevo.txt"
    arbol "$T/fi-$flt-rt" 90 'v1-app'
    manifiesto "$T/fi-$flt-man.json"
    ANTES_F=$(arbol_sha "$T/fi-$flt-rt")
    if OPENCLAW_DEPLOY_FAULT=$flt "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$DEPN" \
      -SourceRoot "$(nat "$T/fi-$flt-src")" -RuntimeRoot "$(nat "$T/fi-$flt-rt")" \
      -StagingRoot "$(nat "$T/fi-$flt-st")" -ReceiptRoot "$(nat "$T/fi-$flt-rec")" \
      -ManifestPath "$(nat "$T/fi-$flt-man.json")" -HealthUrl "http://127.0.0.1:$PUERTO_FAKE" \
      -OpenClawVersion 2026.9.5 -SourceSha "$SHA40" -Apply >"$T/fi-$flt.out" 2>&1; then
      fail "(5b/$flt) falla inyectada debio fallar y salio 0"
    fi
    grep -q 'falla inyectada' "$T/fi-$flt.out" \
      || fail "(5b/$flt) sin diagnostico: $(cat "$T/fi-$flt.out")"
    [ "$(arbol_sha "$T/fi-$flt-rt")" = "$ANTES_F" ] \
      || fail "(5b/$flt) rollback incompleto: runtime difiere"
    "$PYBIN" - "$(ls "$T/fi-$flt-rec/"*.json)" <<'PY' || fail "(5b/$flt) recibo rolled_back malformado"
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["result"] == "rolled_back", r["result"]
PY
  done
  echo "ok (5b): read-back y journal fallidos revierten lo publicado"

  # (6) Raices traslapadas: staging dentro de fuente se rechaza sin escribir.
  arbol "$T/o-src" 90 'v2-app'
  arbol "$T/o-rt" 90 'v1-app'
  manifiesto "$T/o-man.json"
  if "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$DEPN" \
    -SourceRoot "$(nat "$T/o-src")" -RuntimeRoot "$(nat "$T/o-rt")" \
    -StagingRoot "$(nat "$T/o-src/st")" -ReceiptRoot "$(nat "$T/o-rec")" \
    -ManifestPath "$(nat "$T/o-man.json")" -HealthUrl "http://127.0.0.1:$PUERTO_FAKE" \
    -OpenClawVersion 2026.9.5 -SourceSha "$SHA40" -Apply >"$T/o.out" 2>&1; then
    fail "(6) staging anidado debio fallar y salio 0"
  fi
  [ "$(cat "$T/o-rt/app.txt")" = 'v1-app' ] || fail "(6) raices traslapadas tocaron runtime"
  echo "ok (6): raices traslapadas se rechazan sin escribir"

  # (7) Compuerta httpTimeoutSec: 89/duplicado/decimal/negativo/texto fallan;
  # 90/120 pasan sin importar espacios. Fixtures escritos por bash (sin
  # interpolacion), veredicto por el modulo.
  printf '$httpTimeoutSec = 89\n' >"$T/t89.ps1"
  printf '$httpTimeoutSec = 90\n$httpTimeoutSec = 120\n' >"$T/tdup.ps1"
  printf '$httpTimeoutSec = 90.0\n' >"$T/tdec.ps1"
  printf '$httpTimeoutSec = -5\n' >"$T/tneg.ps1"
  printf '$httpTimeoutSec = "90"\n' >"$T/ttxt.ps1"
  printf '$httpTimeoutSec = 90\n' >"$T/t90.ps1"
  printf '$httpTimeoutSec=120\n' >"$T/t120.ps1"
  printf '\t$httpTimeoutSec\t=\t90  # prod\n' >"$T/ttab.ps1"
  cat >"$T/timeout.ps1" <<'PS1'
param([Parameter(Mandatory = $true)][string]$ModulePath,
      [Parameter(Mandatory = $true)][string]$Dir)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
$casos = @(
  @('t89', $false), @('tdup', $false), @('tdec', $false),
  @('tneg', $false), @('ttxt', $false), @('t90', $true),
  @('t120', $true), @('ttab', $true)
)
foreach ($c in $casos) {
  $r = Test-EffectiveHttpTimeout -Path (Join-Path $Dir ($c[0] + '.ps1'))
  if ($r -ne $c[1]) { Write-Output ('TIMEOUT-FAIL: ' + $c[0]); exit 1 }
  Write-Output ('TIMEOUT-OK: ' + $c[0])
}
PS1
  if [ "$en_windows" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then
    TDN=$(cygpath -w "$T")
  else
    TDN="$T"
  fi
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$T/timeout.ps1" \
    -ModulePath "$MODN" -Dir "$TDN" >"$T/timeout.out" 2>&1 \
    || fail "(7) compuerta timeout: $(cat "$T/timeout.out")"
  [ "$(grep -c 'TIMEOUT-OK' "$T/timeout.out")" -eq 8 ] \
    || fail "(7) faltan casos timeout: $(cat "$T/timeout.out")"
  echo "ok (7): compuerta timeout 8/8"

  # (8) Test-HashEqual y Test-RootsIsolated conductuales.
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "
Import-Module '$MODN' -Force
\$f = Join-Path '$T' 'hash.txt'
[IO.File]::WriteAllText(\$f, 'abc')
\$h = (Get-FileHash -LiteralPath \$f -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not (Test-HashEqual -Path \$f -ExpectedSha256 \$h)) { Write-Output 'HASH-FAIL: igual'; exit 1 }
if (Test-HashEqual -Path \$f -ExpectedSha256 ('0' * 64)) { Write-Output 'HASH-FAIL: distinto'; exit 1 }
if (-not (Test-RootsIsolated -Roots @('C:\s', 'C:\r', 'C:\t'))) { Write-Output 'ROOTS-FAIL: aisladas'; exit 1 }
if (Test-RootsIsolated -Roots @('C:\s', 'C:\s\sub')) { Write-Output 'ROOTS-FAIL: anidadas'; exit 1 }
if (Test-RootsIsolated -Roots @('rel', 'C:\r')) { Write-Output 'ROOTS-FAIL: relativa'; exit 1 }
Write-Output 'HASH-ROOTS-OK'
" >"$T/hr.out" 2>&1 || fail "(8) hash/roots: $(cat "$T/hr.out")"
  grep -q 'HASH-ROOTS-OK' "$T/hr.out" || fail "(8) sin confirmacion: $(cat "$T/hr.out")"
  echo "ok (8): hash y raices conductuales"

  kill $GW_PID 2>/dev/null || true
else
  echo "SKIP (2-8): sin motor PowerShell; windows-contract cubre el humo de deploy"
fi

# (9) windows-contract corre ESTE test (pin de cobertura propia).
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-deploy-atomic.sh' \
  || fail "(9) windows-contract no corre test-deploy-atomic.sh"
echo "ok (9): windows-contract cubre este test"

echo "TODO VERDE: deploy-atomic"
