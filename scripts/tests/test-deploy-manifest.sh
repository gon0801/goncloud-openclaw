#!/bin/bash
# Contrato del manifiesto de despliegue (Task 2 / 16.2).
#
# Semantica (fijada aqui y en Test-DeployPathClassification del modulo):
#   1. Seguridad de ruta primero: absoluta, .., :, control, dispositivo
#      reservado, reparse/symlink -> rejected:safety:*.
#   2. Deny siempre gana: si iguala un patron denied -> rejected:deny.
#   3. Si iguala un allow y ningun deny -> deployable.
#   4. Si no iguala nada -> SIN CLASIFICAR y este test falla: un archivo
#      nuevo sin decision explicita no viaja ni se ignora en silencio.
# Las listas son disjuntas por construccion: (3) tambien falla si una ruta
# trackeada iguala allow y deny a la vez.
#
# Uso: bash scripts/tests/test-deploy-manifest.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
MANIFIESTO=config/runtime-deploy.v1.json
MODULO=scripts/runtime-separation/RuntimeSeparation.psm1
YAML=.github/workflows/quality.yml

# (0) El manifiesto existe, es JSON y declara schema y raices canonicas.
[ -f "$MANIFIESTO" ] || fail "(0) falta $MANIFIESTO"
PYBIN=$(command -v python3 || command -v python) || fail "(0) sin python3 ni python en PATH"
"$PYBIN" - "$MANIFIESTO" <<'PY' || exit 1
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m.get("schema") == "runtime-deploy.v1", "ROJO: (0) schema distinto de runtime-deploy.v1"
assert m.get("sourceRoot") == "C:\\Users\\ehven\\src\\goncloud-openclaw", "ROJO: (0) sourceRoot no canonica"
assert m.get("runtimeRoot") == "C:\\Users\\ehven\\.openclaw", "ROJO: (0) runtimeRoot no canonica"
assert isinstance(m.get("allowed"), list) and m["allowed"], "ROJO: (0) allowed vacio"
assert isinstance(m.get("denied"), list) and m["denied"], "ROJO: (0) denied vacio"
for lado in ("allowed", "denied"):
    for e in m[lado]:
        assert e.get("reason"), f"ROJO: (0) entrada {lado} sin reason: {e}"
PY
echo "ok (0): manifiesto parseable, schema v1, raices canonicas y razones"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# --- espejo portable del clasificador ---
cat >"$T/clasifica.py" <<'PY'
import json, re, sys

manifiesto = json.load(open(sys.argv[1], encoding="utf-8"))

def a_regex(patron):
    if patron.endswith("/"):
        return re.compile("(?i)^" + re.escape(patron)), "dir"
    if "*" in patron or "?" in patron:
        i, n, out = 0, len(patron), ""
        while i < n:
            c = patron[i]
            if c == "*":
                if i + 1 < n and patron[i + 1] == "*":
                    if i + 2 < n and patron[i + 2] == "/":
                        out += "(.*/)?"; i += 3
                    else:
                        out += ".*"; i += 2
                else:
                    out += "[^/]*"; i += 1
            elif c == "?":
                out += "[^/]"; i += 1
            else:
                out += re.escape(c); i += 1
        return re.compile("(?i)^" + out + "$"), "glob"
    return re.compile("(?i)^" + re.escape(patron) + "$"), "exact"

ALLOW = [(a_regex(e["path"]), e) for e in manifiesto["allowed"]]
DENY = [(a_regex(e["pattern"]), e) for e in manifiesto["denied"]]
RESERVADO = re.compile(r"(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$")

def seguridad(ruta):
    p = ruta.replace("\\", "/")
    if re.match(r"(?i)^[a-z]:[\\/]", ruta) or p.startswith("/") or p.startswith("//"):
        return "absoluta"
    if ":" in p:
        return "dos-puntos-stream"
    if re.search(r"[\x00-\x1f\x7f]", p):
        return "control"
    segs = p.split("/")
    if any(s == "" for s in segs):
        return "segmento-vacio"
    if any(s == ".." for s in segs):
        return "dotdot"
    for s in segs:
        if RESERVADO.match(s):
            return f"reservado:{s}"
        if s != s.rstrip(". "):
            return f"cola-punto-espacio:{s}"
    return None

def veredicto(ruta):
    motivo = seguridad(ruta)
    if motivo:
        return ("rejected", f"safety:{motivo}")
    p = ruta.replace("\\", "/")
    niega = [e for (rx, _k), e in DENY if rx.search(p)]
    if niega:
        pats = sorted(e["pattern"] for e in niega)
        return ("rejected", f"deny:{pats[0]}")
    permite = [e for (rx, _k), e in ALLOW if rx.search(p)]
    if permite:
        return ("deployable", "allow")
    return ("unclassified", "sin-lista")

if __name__ == "__main__":
    # Uso: clasifica.py MANIFIESTO [--solo RUTA... | --tracked]
    # Imprime "veredicto<TAB>motivo<TAB>ruta" por linea; exit 0 siempre
    # (el llamador decide que es rojo).
    rutas = []
    if len(sys.argv) > 2 and sys.argv[2] == "--tracked":
        import subprocess
        rutas = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True,
                               text=True).stdout.split("\0")
        rutas = [r for r in rutas if r]
    else:
        rutas = sys.argv[3:] if len(sys.argv) > 3 else []
    for r in rutas:
        v, m = veredicto(r)
        print(f"{v}\t{m}\t{r}")
PY

# (1) Toda ruta trackeada clasifica; cero sin-clasificar.
"$PYBIN" "$T/clasifica.py" "$MANIFIESTO" --tracked >"$T/veredictos.tsv" \
  || fail "(1) el espejo no pudo clasificar el arbol"
if grep -q '^unclassified' "$T/veredictos.tsv"; then
  grep '^unclassified' "$T/veredictos.tsv" | head -n 10 | sed 's/^/  /' >&2
  fail "(1) hay rutas trackeadas sin decision explicita (las de arriba)"
fi
n_dep=$(grep -c '^deployable' "$T/veredictos.tsv" || true)
n_den=$(grep -c '^rejected' "$T/veredictos.tsv" || true)
echo "ok (1): arbol clasificado ($n_dep deployable, $n_den rejected, 0 sin-clasificar)"

# (1b) Anclas de veredicto: lo que debe viajar viaja, lo que no, no.
tiene() { # $1=veredicto $2=ruta
  grep -E "^$1	[^	]*	$2\$" "$T/veredictos.tsv" >/dev/null \
    || fail "(1b) $2 no tiene veredicto $1"
}
tiene deployable 'gateway-watchdog.ps1'
tiene deployable 'summa-gate/index.ts'
tiene deployable 'tablero-runbook/lib.ts'
tiene deployable 'agents/main/agent/workshop-skills/agent-dispatch/SKILL.md'
tiene rejected 'scripts/sync-repos.ps1'
tiene rejected 'Plans.md'
tiene rejected 'docs/spec/00-project-spec.md'
tiene rejected 'tls/bin/lego.exe'
tiene rejected 'config/runtime-deploy.v1.json'
echo "ok (1b): veredictos ancla correctos"

# (2) Seguridad de ruta: sintesis hostil, toda rechazada por safety.
"$PYBIN" "$T/clasifica.py" "$MANIFIESTO" --solo \
  'C:\Windows\Temp\x.ps1' 'C:/Windows/x' '//servidor/x' '/etc/passwd' \
  'a/../../b' '..' 'a:b' 'a/b:stream' 'CON' 'aux.txt' 'd/COM1' 'lpt9.log' \
  'NUL.json' 'a//b' 'trailing. ' >"$T/hostil.tsv" || fail "(2) el espejo fallo"
while IFS=$(printf '\t') read -r v m r; do
  case "$v:$m" in
    rejected:safety:*) ;;
    *) fail "(2) ruta hostil no rechazada por safety: $v $m $r" ;;
  esac
done <"$T/hostil.tsv"
echo "ok (2): 15 rutas hostiles rechazadas por safety"

# (3) Disjuncion: ninguna trackeada iguala allow y deny a la vez.
"$PYBIN" - "$T/clasifica.py" "$MANIFIESTO" <<'PY' || exit 1
import runpy, subprocess, sys
ruta = sys.argv[1]
sys.argv = [sys.argv[0], sys.argv[2]]
mod = runpy.run_path(ruta, run_name="clasifica_mod")
rutas = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True,
                       text=True).stdout.split("\0")
mal = []
for r in rutas:
    if not r:
        continue
    p = r.replace("\\", "/")
    da = any(rx.search(p) for (rx, _k), _e in mod["ALLOW"])
    dn = any(rx.search(p) for (rx, _k), _e in mod["DENY"])
    if da and dn:
        mal.append(r)
if mal:
    print("ROJO: (3) rutas que igualan allow y deny a la vez:")
    for r in mal[:10]:
        print(f"  {r}")
    sys.exit(1)
PY
echo "ok (3): allow y denied disjuntos sobre el arbol"

# (4) El hard-deny del plan existe, patron por patron.
while IFS= read -r patron; do
  [ -n "$patron" ] || continue
  "$PYBIN" - "$MANIFIESTO" "$patron" <<'PY' || exit 1
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
pats = [e["pattern"] for e in m["denied"]]
assert sys.argv[2] in pats, f"ROJO: (4) denied no trae {sys.argv[2]}"
PY
done <<'PATRONES'
**/*.sqlite*
**/*.wal
**/*.shm
**/.git/**
**/.env*
**/openclaw.json*
**/credentials/**
**/sessions/**
**/logs/**
**/tools/**
**/models/**
**/cache/**
**/*.pem
**/*.key
**/*.pfx
**/*.p12
**/*.exe
**/*.zip
**/*.dll
**/*.bak*
**/gateway.cmd
**/gateway.vbs
**/node.cmd
**/node.vbs
**/*:*
tls/lego-data/**
workspace/
workspace-ingenieria/
workspace-operaciones/
workspace-adversary/
workspace-implementer/
workspace-reviewer/
workspace-verifier/
summa-gate/node_modules/**
summa-gate/state/**
summa-gate/*.log
summa-gate/*.jsonl
tablero-runbook/node_modules/**
tablero-runbook/*.log
tablero-runbook/*.jsonl
PATRONES
echo "ok (4): hard-deny completo (40 patrones)"

# (5) Acuerdo espejo-modulo en fixtures (motor PowerShell si hay; en Windows
# obligatorio). El modulo trae Test-DeployPathClassification con la misma
# semantica; 16 rutas deben dar el mismo veredicto en ambos.
en_windows=0
[ "${OS:-}" = "Windows_NT" ] && en_windows=1
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) en_windows=1;; esac
PSH="$(command -v powershell.exe || command -v powershell || command -v pwsh || true)"
if [ "$en_windows" -eq 1 ] && [ -z "$PSH" ]; then
  fail "(5) en Windows powershell.exe debe existir"
fi
if [ -n "$PSH" ]; then
  grep -qF 'function Test-DeployPathClassification' "$MODULO" \
    || fail "(5) el modulo no trae Test-DeployPathClassification"
  cat >"$T/fixtures.txt" <<'FIX'
gateway-watchdog.ps1
summa-gate/index.ts
summa-gate/node_modules/x/index.js
summa-gate/rendiciones.jsonl
tablero-runbook/lib.ts
agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
agents/main/agent.md
Plans.md
scripts/sync-repos.ps1
docs/spec/00-project-spec.md
tls/bin/lego.exe
openclaw.json
a/../../b
C:\Windows\x.ps1
CON
summa-gate/x.SQLITE-shm
FIX
  "$PYBIN" "$T/clasifica.py" "$MANIFIESTO" --solo $(cat "$T/fixtures.txt") \
    | cut -f1 >"$T/esp.txt" || fail "(5) el espejo fallo en fixtures"
  cat >"$T/acuerdo.ps1" <<'PS1'
param([Parameter(Mandatory = $true)][string]$ModulePath,
      [Parameter(Mandatory = $true)][string]$ManifestPath,
      [Parameter(Mandatory = $true)][string]$FixturesPath)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
foreach ($f in (Get-Content -LiteralPath $FixturesPath)) {
  if ($f -eq '') { continue }
  Write-Output (Test-DeployPathClassification -RelativePath $f -ManifestPath $ManifestPath)
}
PS1
  # Absolutas antes de cygpath: Import-Module 5.1 no resuelve rutas
  # relativas y cygpath -w deja una relativa sin unidad (CI4).
  if [ "$en_windows" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then
    MODN=$(cygpath -w "$PWD/$MODULO"); MANN=$(cygpath -w "$PWD/$MANIFIESTO")
  else
    MODN="$PWD/$MODULO"; MANN="$PWD/$MANIFIESTO"
  fi
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$T/acuerdo.ps1" \
    -ModulePath "$MODN" -ManifestPath "$MANN" -FixturesPath "$T/fixtures.txt" >"$T/got.txt" 2>"$T/acuerdo.err" \
    || fail "(5) acuerdo PS fallo: $(cat "$T/acuerdo.err")"
  # powershell.exe emite CRLF y el espejo LF: sin strip, veredictos
  # identicos discrepan por el CR (CI5).
  tr -d '\r' <"$T/got.txt" >"$T/got.lf" && mv "$T/got.lf" "$T/got.txt"
  [ "$(wc -l <"$T/got.txt" | tr -d ' ')" -eq 16 ] \
    || fail "(5) el modulo devolvio lineas de mas o de menos: $(cat "$T/got.txt")"
  paste -d'|' "$T/fixtures.txt" "$T/esp.txt" "$T/got.txt" >"$T/cmp.tsv"
  while IFS='|' read -r f esp got; do
    [ "$esp" = "$got" ] || fail "(5) desacuerdo en $f: espejo=$esp modulo=$got"
  done <"$T/cmp.tsv"
  echo "ok (5): espejo y modulo acuerdan 16/16 fixtures"
else
  echo "SKIP (5): sin motor PowerShell; windows-contract cubre el acuerdo espejo-modulo"
fi

# (6) windows-contract corre ESTE test (pin de cobertura propia).
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-deploy-manifest.sh' \
  || fail "(6) windows-contract no corre test-deploy-manifest.sh"
echo "ok (6): windows-contract cubre este test"

echo "TODO VERDE: deploy-manifest"
