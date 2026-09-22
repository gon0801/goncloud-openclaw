#!/bin/bash
# Contrato de cuarentena (Task 6 / 16.5).
#
# Todo candidato se hashea e inventaria ANTES de moverlo fuera de las raices
# de despliegue. Se rechazan bases de datos, WAL/SHM, credenciales,
# sesiones, launchers activos, evidencia, handles abiertos y worktrees sin
# cerrar. No existe comando de borrado. Restore devuelve por ruta/hash
# registrados. Nota dev: el caso de handle abierto usa flock(1); sin flock
# se salta (CI ubuntu lo cubre).
#
# Uso: bash scripts/tests/test-quarantine.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
QZ=scripts/runtime-separation/Move-OpenClawQuarantine.ps1

for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

# (0) El script existe y parsea limpio.
[ -f "$QZ" ] || fail "(0) falta $QZ"
PSH="$(command -v pwsh || true)"
[ -n "$PSH" ] || fail "(0) sin pwsh en PATH"
"$PSH" -NoProfile -NonInteractive -Command "
\$e=\$null; \$t=\$null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '$QZ'), [ref]\$t, [ref]\$e)
if (\$e -and \$e.Count -gt 0) { \$e | ForEach-Object { \$_.ToString() }; exit 1 }
exit 0
" || fail "(0) ParseFile reporto errores en $QZ"
echo "ok (0): Move-OpenClawQuarantine.ps1 existe y parsea"

# (1) Anclas: mover, inventario, clases de rechazo, restore, sin borrado.
for a in 'Move-Item' 'QuarantineRoot' 'Test-RootsIsolated' 'originalPath' \
    'quarantinePath' 'sizeBytes' 'sha256' 'movedUtc' '.sqlite' '-wal' \
    'credential' 'sessions' 'ActiveLaunchers' 'EvidencePaths' 'worktree' \
    '.git' 'restore' 'RestoreOnly' 'Write-ReceiptAtomic' '2026.9.5' 'Apply'; do
  grep -qF -- "$a" "$QZ" || fail "(1) falta ancla: $a"
done
[ "$(grep -c 'Remove-Item' "$QZ")" = 0 ] || fail "(1) trae Remove-Item (prohibido)"
echo "ok (1): mover, inventario y rechazos anclados; sin borrado"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
en_windows=0
[ "${OS:-}" = "Windows_NT" ] && en_windows=1
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) en_windows=1;; esac
nat() {
  if [ "$en_windows" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$PWD" "$1";; esac
  fi
}
QZN=$(nat "$QZ")
PYBIN=$(command -v python3 || command -v python) || fail "(2) sin python3 ni python"

# --- stubs minimos ---
mkdir -p "$T/fake-bin"
export OC_VERSION="2026.9.5"
cat >"$T/fake-bin/openclaw" <<'SH'
#!/bin/bash
if [ "$1" = "--version" ]; then
  echo "OpenClaw $OC_VERSION (stub)"
  exit 0
fi
echo "oc stub: $*" >&2
exit 99
SH
chmod +x "$T/fake-bin/openclaw"
export PATH="$T/fake-bin:$PATH"

mkdir -p "$T/rt" "$T/repo"
printf 'repo\n' >"$T/repo/f.txt"

# --- fixtures por clase ---
mkdir -p "$T/fix"
printf 'log-viejo\n' >"$T/fix/old.log"
mkdir -p "$T/fix/old-dir/sub"
printf 'a\n' >"$T/fix/old-dir/a.txt"
printf 'b\n' >"$T/fix/old-dir/sub/b.txt"
printf 'DB' >"$T/fix/data.sqlite"
printf 'WAL' >"$T/fix/data.sqlite-wal"
printf 'SHM' >"$T/fix/x.db-shm"
printf '{}' >"$T/fix/credentials.json"
mkdir -p "$T/fix/agents/main/sessions/s1"
printf 's' >"$T/fix/agents/main/sessions/s1/log.jsonl"
printf 'launch\n' >"$T/fix/launcher.cmd"
printf 'evidencia\n' >"$T/fix/run-evidence.json"
mkdir -p "$T/fix/wt-checkout"
printf 'gitdir: /elsewhere/worktrees/wt-checkout\n' >"$T/fix/wt-checkout/.git"
printf 'keep\n' >"$T/fix/wt-checkout/file.txt"

corre() { # $1=tag $2=apply(0/1) $3=candidates $4+=extra
  local tag="$1" apply="$2" cands="$3"; shift 3
  local aflag=()
  [ "$apply" = "1" ] && aflag=(-Apply)
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$QZN" \
    -CandidatePaths "$cands" -QuarantineRoot "$(nat "$T/$tag-q")" \
    -RepoRoot "$(nat "$T/repo")" -RuntimeRoot "$(nat "$T/rt")" \
    -ReceiptRoot "$(nat "$T/$tag-rec")" -InventoryPath "$(nat "$T/$tag-inv.jsonl")" \
    -ActiveLaunchers "$(nat "$T/fix/launcher.cmd")" \
    -EvidencePaths "$(nat "$T/fix/run-evidence.json")" \
    "${aflag[@]}" "$@" >"$T/$tag.out" 2>&1
  return $?
}

# (2a) Report-only: valida sin mover; invalido frena en seco.
corre ro 0 "$(nat "$T/fix/old.log")" \
  || fail "(2a) report-only debio salir 0: $(cat "$T/ro.out")"
[ -f "$T/fix/old.log" ] || fail "(2a) report-only movio"
[ -e "$T/ro-q" ] && fail "(2a) report-only creo cuarentena"
corre robad 0 "$(nat "$T/fix/data.sqlite")" \
  && fail "(2a) report-only invalido debio frenar y salio 0"
echo "ok (2a): report-only valida sin mover"

# (2b) Move verde: archivo + dir, hashes, inventario, recibo.
corre ok 1 "$(nat "$T/fix/old.log");$(nat "$T/fix/old-dir")" \
  || fail "(2b) move debio salir 0: $(cat "$T/ok.out")"
[ -e "$T/fix/old.log" ] && fail "(2b) origen archivo no se movio"
[ -e "$T/fix/old-dir" ] && fail "(2b) origen dir no se movio"
"$PYBIN" - "$T/ok-inv.jsonl" <<'PY' || exit 1
import hashlib, json, os, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
assert len(lines) == 2, len(lines)
for ln in lines:
    e = json.loads(ln)
    assert set(e) == {"originalPath", "quarantinePath", "kind", "sizeBytes",
                      "sha256", "fileCount", "movedUtc"}, set(e)
    assert os.path.exists(e["quarantinePath"]), e
    assert not os.path.lexists(e["originalPath"]), e
PY
"$PYBIN" - "$T/ok-rec" <<'PY' || exit 1
import glob, json, sys
recs = glob.glob(sys.argv[1] + "/*.json")
assert len(recs) == 1, recs
d = json.load(open(recs[0], encoding="utf-8"))
assert d["result"] == "passed", d["result"]
assert d["rollback"]["artifact"], d["rollback"]
PY
echo "ok (2b): move verde con inventario y recibo"

# Re-sembrar lo movido para los siguientes escenarios.
printf 'log-viejo\n' >"$T/fix/old.log"
mkdir -p "$T/fix/old-dir/sub"
printf 'a\n' >"$T/fix/old-dir/a.txt"
printf 'b\n' >"$T/fix/old-dir/sub/b.txt"

# (2c) Clases de rechazo: nada se mueve.
for c in data.sqlite data.sqlite-wal x.db-shm credentials.json \
    agents/main/sessions/s1/log.jsonl launcher.cmd run-evidence.json wt-checkout; do
  tag="rj-$(echo "$c" | tr '/.' '--')"
  corre "$tag" 1 "$(nat "$T/fix/$c")" \
    && fail "(2c) $c debio frenar y salio 0"
  [ -e "$T/fix/$c" ] || fail "(2c) $c se movio pese al rechazo"
done
echo "ok (2c): 8 clases rechazadas sin mover"

# (2d) Handle abierto: frena (flock) o SKIP sin flock.
if command -v flock >/dev/null 2>&1; then
  printf 'busy\n' >"$T/fix/busy.txt"
  flock "$T/fix/busy.txt" sleep 30 &
  FLOCK_PID=$!
  sleep 0.5
  corre busy 1 "$(nat "$T/fix/busy.txt")" \
    && { kill $FLOCK_PID 2>/dev/null; fail "(2d) handle abierto debio frenar y salio 0"; }
  kill $FLOCK_PID 2>/dev/null || true
  wait $FLOCK_PID 2>/dev/null || true
  [ -f "$T/fix/busy.txt" ] || fail "(2d) se movio con handle abierto"
  echo "ok (2d): handle abierto frena"
else
  echo "SKIP (2d): sin flock(1); CI ubuntu lo cubre"
fi

# (2e) Ancestro de raiz: frena.
corre anc 1 "$(nat "$T/rt")" \
  && fail "(2e) ancestro debio frenar y salio 0"
echo "ok (2e): ancestro de raiz frena"

# (2f) Restore: devuelve por ruta/hash; ocupado frena.
corre mv2 1 "$(nat "$T/fix/old.log")" \
  || fail "(2f) setup move debio salir 0: $(cat "$T/mv2.out")"
"$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$QZN" \
  -QuarantineRoot "$(nat "$T/mv2-q")" -RepoRoot "$(nat "$T/repo")" \
  -RuntimeRoot "$(nat "$T/rt")" -ReceiptRoot "$(nat "$T/rs-rec")" \
  -InventoryPath "$(nat "$T/mv2-inv.jsonl")" -Mode restore -Apply \
  >"$T/rs.out" 2>&1 || fail "(2f) restore debio salir 0: $(cat "$T/rs.out")"
[ "$(cat "$T/fix/old.log")" = "log-viejo" ] || fail "(2f) contenido distinto al volver"
[ -f "$T/mv2-inv.jsonl" ] || fail "(2f) inventario no se conservo"
# Ocupado: mover otra vez, re-crear origen, restore debe frenar.
corre mv3 1 "$(nat "$T/fix/old.log")" \
  || fail "(2f) setup2 debio salir 0: $(cat "$T/mv3.out")"
printf 'nuevo\n' >"$T/fix/old.log"
"$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$QZN" \
  -QuarantineRoot "$(nat "$T/mv3-q")" -RepoRoot "$(nat "$T/repo")" \
  -RuntimeRoot "$(nat "$T/rt")" -ReceiptRoot "$(nat "$T/rs2-rec")" \
  -InventoryPath "$(nat "$T/mv3-inv.jsonl")" -Mode restore -Apply \
  >"$T/rs2.out" 2>&1 && fail "(2f) restore ocupado debio frenar y salio 0"
[ -d "$T/mv3-q" ] || fail "(2f) cuarentena se toco en restore fallido"
echo "ok (2f): restore devuelve; ocupado frena"

# (2g) Version vieja: report-only avisa, apply frena.
OC_VERSION="2026.9.4" corre vw 0 "$(nat "$T/fix/old.log")" \
  || fail "(2g) report-only viejo debio salir 0"
OC_VERSION="2026.9.4" corre va 1 "$(nat "$T/fix/old.log")" \
  && fail "(2g) apply viejo debio frenar y salio 0"
echo "ok (2g): version vieja avisa en seco y frena en apply"

echo "TODO VERDE: quarantine"
