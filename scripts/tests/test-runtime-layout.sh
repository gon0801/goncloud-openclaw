#!/bin/bash
# Contrato de disposicion: raices canonicas, modulo PowerShell y CI (Task 1).
#
# Raices canonicas (diseno, seccion "Disposicion de directorios"):
#   fuente  C:\Users\ehven\src\goncloud-openclaw   checkout dedicado
#   runtime C:\Users\ehven\.openclaw               estado vivo del gateway
#   nodo    C:\Users\ehven\.openclaw-node          estado aislado del nodo
# Las tres son distintas y ninguna anida a otra. Los repos de workspace
# (workspace, workspace-ingenieria, workspace-operaciones) quedan excluidos
# del despliegue de goncloud-openclaw durante esta migracion.
#
# Este test fija en Linux lo portable (anclas + distincion lexico) y corre la
# conducta real del modulo SOLO donde hay un motor PowerShell: en Windows es
# obligatorio con powershell.exe 5.1 (el job windows-contract); fuera de
# Windows corre si hay motor y si no avisa fuerte que windows-contract cubre.
#
# Uso: bash scripts/tests/test-runtime-layout.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
MODULO=scripts/runtime-separation/RuntimeSeparation.psm1
SCHEMA=docs/spec/runtime-separation-receipt.v1.schema.json
YAML=.github/workflows/quality.yml

# (0) El modulo existe.
[ -f "$MODULO" ] || fail "(0) falta $MODULO"
echo "ok (0): el modulo existe"

# (1) Anclas: las cinco funciones, las tres raices, la exportacion y los
# tres workspaces excluidos.
while IFS= read -r anchor; do
  [ -n "$anchor" ] || continue
  grep -qF -- "$anchor" "$MODULO" || fail "(1) $MODULO no trae: $anchor"
done <<'ANCHORS'
function Get-RuntimeCanonicalRoots
function Test-RuntimeLayout
function Test-WorkspaceExcluded
function Test-ReceiptObject
function Write-ReceiptAtomic
C:\Users\ehven\src\goncloud-openclaw
C:\Users\ehven\.openclaw
C:\Users\ehven\.openclaw-node
Export-ModuleMember
workspace-ingenieria
workspace-operaciones
ANCHORS
# La exportacion nombra las cinco (una funcion sin exportar no existe para el deploy).
for f in Get-RuntimeCanonicalRoots Test-RuntimeLayout Test-WorkspaceExcluded Test-ReceiptObject Write-ReceiptAtomic; do
  grep -E '^Export-ModuleMember' "$MODULO" | grep -qF "$f" \
    || fail "(1) Export-ModuleMember no nombra $f"
done
echo "ok (1): funciones, raices, exportacion y workspaces anclados"

# (5) Las tres raices son distintas y ninguna anida a otra. Portable: opera
# sobre los literales del modulo, sin motor PowerShell.
PYBIN=$(command -v python3 || command -v python) || fail "(5) sin python3 ni python en PATH"
"$PYBIN" - "$MODULO" <<'PY' || exit 1
import re, sys
cuerpo = open(sys.argv[1], encoding="utf-8").read()
raices = sorted(set(re.findall(r"C:\\Users\\ehven\\[^\s'\"]*", cuerpo)))
canon = [r for r in raices if re.fullmatch(r"C:\\Users\\ehven\\(src\\goncloud-openclaw|\.openclaw|\.openclaw-node)", r)]
if len(canon) != 3:
    print(f"ROJO: (5) se esperaban las 3 raices canonicas literales, halladas: {canon}")
    sys.exit(1)
bajas = [r.lower() for r in canon]
if len(set(bajas)) != 3:
    print("ROJO: (5) dos raices colisionan sin importar mayusculas")
    sys.exit(1)
for a in bajas:
    for b in bajas:
        if a != b and (b.startswith(a + "\\") or b.startswith(a + "/")):
            print(f"ROJO: (5) {b} anida dentro de {a}")
            sys.exit(1)
PY
echo "ok (5): las tres raices son distintas y no se anidan"

# (6) Paridad 5.1/PS7: ConvertFrom-Json sin -Depth usa default 2 en 5.1 y
# amplio en PS7; un JSON de 3+ niveles lanza en 5.1 y todo valida $false
# (CI2: los receipt-* que esperan $true fallaron solo en 5.1).
# Toda llamada en codigo que corre en 5.1 lleva -Depth explicito.
SIN_DEPTH=$(grep -hn 'ConvertFrom-Json' scripts/runtime-separation/RuntimeSeparation.psm1 scripts/runtime-separation/*.ps1 \
  | grep -vE '^\s*[0-9]+:\s*#' | grep -vF -- '-Depth' || true)
[ -z "$SIN_DEPTH" ] || fail "(6) ConvertFrom-Json sin -Depth (5.1 default 2): $SIN_DEPTH"
echo "ok (6): todo ConvertFrom-Json lleva -Depth explicito"

# --- motor PowerShell: obligatorio en Windows, oportunista fuera ---
en_windows=0
[ "${OS:-}" = "Windows_NT" ] && en_windows=1
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) en_windows=1;; esac
PS51="$(command -v powershell.exe || command -v powershell || true)"
PSH_ANY="${PS51:-$(command -v pwsh || true)}"
if [ "$en_windows" -eq 1 ]; then
  [ -n "$PS51" ] || fail "(2) en Windows powershell.exe 5.1 debe existir (parseo autoritativo)"
  PSH="$PS51"
  echo "ok (2w): motor Windows PowerShell 5.1 presente"
elif [ -n "$PSH_ANY" ]; then
  PSH="$PSH_ANY"
  echo "nota (2): motor disponible fuera de Windows: $PSH (el parseo autoritativo 5.1 lo corre windows-contract)"
else
  echo "SKIP (2)(3): sin motor PowerShell en esta maquina; el job windows-contract cubre el parseo 5.1 y la conducta del modulo"
  PSH=""
fi

nat() { # ruta absoluta nativa para el motor
  if [ "$en_windows" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$PWD" "$1";; esac
  fi
}

if [ -n "$PSH" ]; then
  # (2) El modulo parsea sin errores de sintaxis.
  # Absolutas: Import-Module 5.1 no resuelve rutas relativas sin .\ como ruta.
  MODNAT=$(nat "$PWD/$MODULO")
  if ! out=$("$PSH" -NoProfile -NonInteractive -Command "
\$errs = \$null
[void][System.Management.Automation.Language.Parser]::ParseFile('$MODNAT', [ref]\$null, [ref]\$errs)
if (\$errs.Count -gt 0) { \$errs | ForEach-Object { \$_.Message }; exit 1 }
" 2>&1); then
    fail "(2) $MODULO no parsea: $out"
  fi
  echo "ok (2): el modulo parsea sin errores"

  # (3) Humo conductual contra el modulo real.
  T=$(mktemp -d) || exit 1
  trap 'rm -rf "$T"' EXIT
  cat >"$T/smoke.ps1" <<'PS1'
param([Parameter(Mandatory = $true)][string]$ModulePath,
      [Parameter(Mandatory = $true)][string]$SchemaPath)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
$script:fails = @()
function Check([string]$n, [bool]$c) {
  if (-not $c) { $script:fails += $n; Write-Output "SMOKE-FAIL: $n" }
  else { Write-Output "SMOKE-OK: $n" }
}
$roots = Get-RuntimeCanonicalRoots
Check 'roots-source' ($roots.Source -eq 'C:\Users\ehven\src\goncloud-openclaw')
Check 'roots-runtime' ($roots.Runtime -eq 'C:\Users\ehven\.openclaw')
Check 'roots-node' ($roots.Node -eq 'C:\Users\ehven\.openclaw-node')
Check 'layout-canonical' ((Test-RuntimeLayout -SourceRoot $roots.Source -RuntimeRoot $roots.Runtime -NodeRoot $roots.Node) -eq $true)
Check 'layout-overlap' ((Test-RuntimeLayout -SourceRoot $roots.Source -RuntimeRoot $roots.Runtime -NodeRoot $roots.Runtime) -eq $false)
Check 'layout-nested' ((Test-RuntimeLayout -SourceRoot $roots.Source -RuntimeRoot 'C:\Users\ehven\.openclaw' -NodeRoot 'C:\Users\ehven\.openclaw\nested') -eq $false)
Check 'layout-relative' ((Test-RuntimeLayout -SourceRoot 'src\repo' -RuntimeRoot $roots.Runtime -NodeRoot $roots.Node) -eq $false)
Check 'layout-case-inside' ((Test-RuntimeLayout -SourceRoot $roots.Source -RuntimeRoot $roots.Runtime -NodeRoot 'C:\USERS\EHVEN\.OPENCLAW') -eq $false)
Check 'ws-inside' ((Test-WorkspaceExcluded -Path 'C:\Users\ehven\.openclaw\workspace\NOTAS.md') -eq $true)
Check 'ws-ingenieria' ((Test-WorkspaceExcluded -Path 'C:\Users\ehven\.openclaw\workspace-ingenieria\a\b.txt') -eq $true)
Check 'ws-operaciones' ((Test-WorkspaceExcluded -Path 'C:\Users\ehven\.openclaw\workspace-operaciones\a\b.txt') -eq $true)
Check 'ws-outside' ((Test-WorkspaceExcluded -Path 'C:\Users\ehven\src\goncloud-openclaw\scripts\x.ps1') -eq $false)
Check 'ws-runtime-root' ((Test-WorkspaceExcluded -Path 'C:\Users\ehven\.openclaw\openclaw.json') -eq $false)
$good = '{"schema": "runtime-separation-receipt.v1", "phase": "16", "startedAt": "2026-09-22T10:00:00Z", "endedAt": "2026-09-22T10:04:31Z", "sourceSha": "0123456789abcdef0123456789abcdef01234567", "host": "ehven-pc", "openclawVersion": "2026.9.5", "commands": [{"name": "config validate", "exit": 0}], "inputs": {}, "observations": ["staging con 3 archivos"], "health": {"startupz": 200, "readyz": 200}, "result": "passed", "rollback": {"artifact": "staging-20260922T1000", "deadlineUtc": "2026-09-29T10:00:00Z"}}'
$bad = $good.Replace('"passed"', '"casi"')
$secretObs = 'token usado: ghp_abcdefghijklmnopqrstuvwxyza1B2'
$secret = $good.Replace('staging con 3 archivos', $secretObs)
$shortObs = 'nota: bearer de corta vida'
$short = $good.Replace('staging con 3 archivos', $shortObs)
Check 'receipt-good' ((Test-ReceiptObject -ReceiptJson $good -SchemaPath $SchemaPath) -eq $true)
Check 'receipt-bad' ((Test-ReceiptObject -ReceiptJson $bad -SchemaPath $SchemaPath) -eq $false)
Check 'receipt-secret' ((Test-ReceiptObject -ReceiptJson $secret -SchemaPath $SchemaPath) -eq $false)
Check 'receipt-short-bearer' ((Test-ReceiptObject -ReceiptJson $short -SchemaPath $SchemaPath) -eq $true)
$tmpdir = Join-Path ([IO.Path]::GetTempPath()) ('rsmoke-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpdir)
$dest = Join-Path $tmpdir 'receipt.json'
Write-ReceiptAtomic -ReceiptJson $good -Path $dest -SchemaPath $SchemaPath
Check 'atomic-exists' (Test-Path -LiteralPath $dest)
$round = Get-Content -Raw -LiteralPath $dest
Check 'atomic-roundtrip' ($round -eq $good)
Check 'atomic-no-temp' (@(Get-ChildItem -LiteralPath $tmpdir -Filter '*.tmp-*').Count -eq 0)
$threw = $false
try { Write-ReceiptAtomic -ReceiptJson $bad -Path (Join-Path $tmpdir 'bad.json') -SchemaPath $SchemaPath } catch { $threw = $true }
Check 'atomic-invalid-throws' ($threw -eq $true)
Check 'atomic-invalid-no-file' ((-not (Test-Path -LiteralPath (Join-Path $tmpdir 'bad.json'))) -eq $true)
Remove-Item -Recurse -Force -LiteralPath $tmpdir
if ($script:fails.Count -gt 0) { exit 1 }
PS1
  SCHNAT=$(nat "$PWD/$SCHEMA")
  if ! out=$("$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$T/smoke.ps1" -ModulePath "$MODNAT" -SchemaPath "$SCHNAT" 2>&1); then
    fail "(3) humo del modulo en rojo: $out"
  fi
  printf '%s\n' "$out" | grep -q 'SMOKE-OK: atomic-roundtrip' \
    || fail "(3) el humo no llego al final: $out"
  n=$(printf '%s\n' "$out" | grep -c 'SMOKE-OK:') || n=0
  [ "$n" -eq 22 ] || fail "(3) se esperaban 22 SMOKE-OK, llegaron $n: $out"
  echo "ok (3): humo conductual del modulo en verde (22/22)"
fi

# (4) CI: instala 2026.9.5, job windows-contract acotado y gate que depende de el.
grep -qF 'openclaw@2026.9.5' "$YAML" || fail "(4) CI no instala openclaw@2026.9.5"
grep -qF 'openclaw@2026.9.4' "$YAML" && fail "(4) CI todavia instala openclaw@2026.9.4"
seccion() { # $1=job -> texto de su seccion (anclada por clave, sin comentarios)
  awk -v job="$1" '
    $0 == "  " job ":" {f=1; next}
    f && /^  [A-Za-z_][A-Za-z0-9_-]*:/ {f=0}
    f {print}
  ' "$YAML" | grep -vE '^[[:space:]]*#'
}
SEC_W=$(seccion windows-contract)
[ -n "$SEC_W" ] || fail "(4) falta el job windows-contract"
printf '%s\n' "$SEC_W" | grep -qF 'runs-on: windows-latest' \
  || fail "(4) windows-contract no corre en windows-latest"
printf '%s\n' "$SEC_W" | grep -qF 'clasificador' \
  || fail "(4) windows-contract no depende del clasificador"
printf '%s\n' "$SEC_W" | grep -qF "carril != 'fast'" \
  || fail "(4) windows-contract no se omite solo con fast exacto"
printf '%s\n' "$SEC_W" | grep -qF 'test-runtime-receipt.sh' \
  || fail "(4) windows-contract no corre test-runtime-receipt.sh"
printf '%s\n' "$SEC_W" | grep -qF 'test-runtime-layout.sh' \
  || fail "(4) windows-contract no corre test-runtime-layout.sh"
printf '%s\n' "$SEC_W" | grep -qF 'run-checks.sh' \
  && fail "(4) windows-contract corre la bateria: debe correr SOLO los tests de contrato Windows"
printf '%s\n' "$SEC_W" | grep -qF 'persist-credentials: false' \
  || fail "(4) windows-contract no declara persist-credentials: false"
SEC_G=$(seccion gate)
[ -n "$SEC_G" ] || fail "(4) falta la seccion gate"
printf '%s\n' "$SEC_G" | grep -E '^[[:space:]]{4}needs:' | grep -qF 'windows-contract' \
  || fail "(4) el gate no depende de windows-contract"
printf '%s\n' "$SEC_G" | grep -qF 'needs.windows-contract.result' \
  || fail "(4) el gate no lee el resultado de windows-contract"
printf '%s\n' "$SEC_G" | grep -qF 'windows=$R_WINDOWS' \
  || fail "(4) el gate no audita el par windows con la regla de pares"
echo "ok (4): CI instala 2026.9.5, windows-contract acotado y gate dependiente"

echo "TODO VERDE: runtime-layout"
