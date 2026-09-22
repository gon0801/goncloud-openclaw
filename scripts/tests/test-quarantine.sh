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
PSH="$(command -v powershell.exe || command -v powershell || command -v pwsh || true)"
[ -n "$PSH" ] || fail "(0) sin powershell ni pwsh en PATH"
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
    '.git' 'restore' 'RestoreOnly' 'Write-ReceiptAtomic' '2026.9.5' 'Apply' \
    'recovery.jsonl' 'ReparsePoint'; do
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
printf '@echo off\r\n@if "%%~1"=="--version" echo OpenClaw %%OC_VERSION%% (stub)\r\n@if "%%~1"=="--version" exit /b 0\r\n@echo oc stub: %%* 1>&2\r\n@exit /b 99\r\n' >"$T/fake-bin/openclaw.cmd"
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
restaura() { # $1=tag $2=qdir $3=inv
  local tag="$1" q="$2" inv="$3"
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$QZN" \
    -QuarantineRoot "$(nat "$q")" -RepoRoot "$(nat "$T/repo")" \
    -RuntimeRoot "$(nat "$T/rt")" -ReceiptRoot "$(nat "$T/$tag-rec")" \
    -InventoryPath "$(nat "$inv")" -Mode restore -Apply \
    >"$T/$tag.out" 2>&1
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

# (2h) Restore no confia en inventario manipulado: canoniza rutas, exige
# quarantinePath dentro de la raiz y valida TODO antes del primer
# movimiento; rechaza duplicados, campos desconocidos y reparse points.
mkdir -p "$T/h" "$T/fuera"
printf 'hola-a\n' >"$T/h/a.txt"
printf 'hola-b\n' >"$T/h/b.txt"
corre mh 1 "$(nat "$T/h/a.txt");$(nat "$T/h/b.txt")" \
  || fail "(2h) setup move debio salir 0: $(cat "$T/mh.out")"
"$PYBIN" - "$T/mh-inv.jsonl" "$T" <<'PY' || exit 1
import json, os, shutil, sys
inv, T = sys.argv[1], sys.argv[2]
lines = [json.loads(l) for l in open(inv, encoding="utf-8").read().splitlines() if l.strip()]
assert len(lines) == 2, len(lines)
la = [e for e in lines if e["originalPath"].replace("\\", "/").endswith("h/a.txt")][0]
lb = [e for e in lines if e["originalPath"].replace("\\", "/").endswith("h/b.txt")][0]
fuera = os.path.join(T, "fuera")
shutil.copyfile(la["quarantinePath"], os.path.join(fuera, "secreto.txt"))
def w(name, entries):
    with open(os.path.join(T, name), "w", encoding="utf-8") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")
ea = dict(la)
ea["quarantinePath"] = os.path.join(fuera, "secreto.txt")
ea["originalPath"] = os.path.join(fuera, "devuelto.txt")
w("inv-h-a.jsonl", [ea])
w("inv-h-b.jsonl", [la, la])
ec = dict(la)
ec["extra"] = 1
w("inv-h-c.jsonl", [ec])
ed = dict(la)
ed["quarantinePath"] = os.path.join(T, "mh-d-q", os.path.basename(la["quarantinePath"]))
w("inv-h-d.jsonl", [ed])
ee = dict(la)
ee["quarantinePath"] = os.path.join(T, "mh-e-q", os.path.basename(la["quarantinePath"]))
w("inv-h-e.jsonl", [ee])
ef = [la, dict(lb, quarantinePath=os.path.join(T, "mh-q", "no-existe"))]
w("inv-h-f.jsonl", ef)
PY
cp -R "$T/mh-q" "$T/mh-e-q"
QA_LEAF_E=$(ls "$T/mh-e-q" | grep '^a\.txt-' | head -1)
[ -n "$QA_LEAF_E" ] || fail "(2h) setup no hallo cuarentenado de a.txt"
printf 'x-intruso' >>"$T/mh-e-q/$QA_LEAF_E"
hace_d=0
if cp -R "$T/mh-q" "$T/mh-d-q" 2>/dev/null; then
  QA_LEAF_D=$(ls "$T/mh-d-q" | grep '^a\.txt-' | head -1)
  if [ -n "$QA_LEAF_D" ] && rm -f "$T/mh-d-q/$QA_LEAF_D" \
      && ln -s "$T/fuera/secreto.txt" "$T/mh-d-q/$QA_LEAF_D" 2>/dev/null \
      && [ -L "$T/mh-d-q/$QA_LEAF_D" ]; then
    hace_d=1
  else
    echo "SKIP (2h/d): sin symlinks"
  fi
fi
nada_movido_h() {
  [ -e "$T/h/a.txt" ] && return 1
  [ -e "$T/h/b.txt" ] && return 1
  [ "$(ls "$T/mh-q" | grep -cv '^recovery\.jsonl$')" = "2" ] || return 1
  return 0
}
restaura rsa "$T/mh-q" "$T/inv-h-a.jsonl" \
  && fail "(2h/a) escape debio frenar y salio 0"
[ "$(cat "$T/fuera/secreto.txt")" = "hola-a" ] || fail "(2h/a) toco el archivo fuera de la raiz"
[ -e "$T/fuera/devuelto.txt" ] && fail "(2h/a) creo destino fuera de la raiz"
nada_movido_h || fail "(2h/a) movio algo con inventario manipulado"
restaura rsb "$T/mh-q" "$T/inv-h-b.jsonl" \
  && fail "(2h/b) duplicado debio frenar y salio 0"
nada_movido_h || fail "(2h/b) movio con duplicados"
restaura rsc "$T/mh-q" "$T/inv-h-c.jsonl" \
  && fail "(2h/c) campo extra debio frenar y salio 0"
nada_movido_h || fail "(2h/c) movio con campo desconocido"
if [ "$hace_d" = "1" ]; then
  restaura rsd "$T/mh-d-q" "$T/inv-h-d.jsonl" \
    && fail "(2h/d) reparse debio frenar y salio 0"
  [ -e "$T/h/a.txt" ] && fail "(2h/d) restauro via reparse point"
fi
restaura rse "$T/mh-e-q" "$T/inv-h-e.jsonl" \
  && fail "(2h/e) hash distinto debio frenar y salio 0"
[ -e "$T/h/a.txt" ] && fail "(2h/e) restauro con hash distinto"
restaura rsf "$T/mh-q" "$T/inv-h-f.jsonl" \
  && fail "(2h/f) 2da invalida debio frenar y salio 0"
nada_movido_h || fail "(2h/f) movio la 1ra antes de validar la 2da"
echo "ok (2h): restore rechaza inventario manipulado sin mover nada"
# El recibo de restore liga el inventario consumido por hash.
"$PYBIN" - "$T/rs-rec" "$T/mv2-inv.jsonl" <<'PY' || exit 1
import glob, hashlib, json, sys
recs = glob.glob(sys.argv[1] + "/*.json")
assert len(recs) == 1, recs
d = json.load(open(recs[0], encoding="utf-8"))
want = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
assert any(want in o for o in d["observations"]), d["observations"]
PY
echo "ok (2h): recibo de restore liga inventario por hash"

# (2i) Registro de recuperacion: linea con fsync ANTES de cada movimiento;
# sobrevive kill -9 con inventario ausente y origenes intactos.
mkdir -p "$T/k"
printf 'k1\n' >"$T/k/k1.txt"
printf 'k2\n' >"$T/k/k2.txt"
( trap '' EXIT
  OPENCLAW_QUARANTINE_FAULT=pre-move-crash
  export OPENCLAW_QUARANTINE_FAULT
  exec "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$QZN" \
    -CandidatePaths "$(nat "$T/k/k1.txt");$(nat "$T/k/k2.txt")" \
    -QuarantineRoot "$(nat "$T/kkill-q")" \
    -RepoRoot "$(nat "$T/repo")" -RuntimeRoot "$(nat "$T/rt")" \
    -ReceiptRoot "$(nat "$T/kkill-rec")" -InventoryPath "$(nat "$T/kkill-inv.jsonl")" \
    -ActiveLaunchers "$(nat "$T/fix/launcher.cmd")" \
    -EvidencePaths "$(nat "$T/fix/run-evidence.json")" \
    -Apply >"$T/kkill.out" 2>&1 ) &
KK=$!
for _ in $(seq 1 200); do
  [ -s "$T/kkill-q/recovery.jsonl" ] && break
  kill -0 $KK 2>/dev/null || break
  sleep 0.1
done
[ -s "$T/kkill-q/recovery.jsonl" ] \
  || fail "(2i) sin linea de recuperacion pre-movimiento: $(cat "$T/kkill.out" 2>/dev/null)"
kill -9 $KK 2>/dev/null || true
wait $KK 2>/dev/null || true
kill -0 $KK 2>/dev/null && fail "(2i) pwsh sobrevivio al kill -9"
"$PYBIN" - "$T" <<'PY' || exit 1
import hashlib, json, os, sys
T = sys.argv[1]
def norm(p):
    return os.path.normcase(os.path.normpath(p))
rec = os.path.join(T, "kkill-q", "recovery.jsonl")
lines = [l for l in open(rec, encoding="utf-8").read().splitlines() if l.strip()]
assert len(lines) == 1, len(lines)
e = json.loads(lines[0])
assert set(e) == {"originalPath", "quarantinePath", "kind", "sizeBytes",
                  "sha256", "fileCount", "movedUtc"}, set(e)
assert os.path.realpath(e["originalPath"]) == os.path.realpath(os.path.join(T, "k", "k1.txt")), e
assert norm(e["quarantinePath"]).startswith(norm(os.path.join(T, "kkill-q")) + os.sep), e
assert e["sha256"] == hashlib.sha256(open(os.path.join(T, "k", "k1.txt"), "rb").read()).hexdigest()
assert os.path.isfile(os.path.join(T, "k", "k1.txt"))
assert os.path.isfile(os.path.join(T, "k", "k2.txt"))
assert not os.path.lexists(os.path.join(T, "kkill-inv.jsonl"))
PY
echo "ok (2i): linea de recuperacion con fsync sobrevive kill -9 antes de mover"

# (2j) Move verde: recovery.jsonl trae lo mismo que el inventario y el
# recibo liga el inventario por hash.
mkdir -p "$T/kn"
printf 'n1\n' >"$T/kn/n1.txt"
printf 'n2\n' >"$T/kn/n2.txt"
corre kn 1 "$(nat "$T/kn/n1.txt");$(nat "$T/kn/n2.txt")" \
  || fail "(2j) move debio salir 0: $(cat "$T/kn.out")"
"$PYBIN" - "$T" <<'PY' || exit 1
import glob, hashlib, json, os, sys
T = sys.argv[1]
def entries(p):
    return [json.loads(l) for l in open(p, encoding="utf-8").read().splitlines() if l.strip()]
rec = entries(os.path.join(T, "kn-q", "recovery.jsonl"))
inv = entries(os.path.join(T, "kn-inv.jsonl"))
assert len(rec) == 2 and len(inv) == 2, (len(rec), len(inv))
kr = {(e["quarantinePath"], e["sha256"]) for e in rec}
ki = {(e["quarantinePath"], e["sha256"]) for e in inv}
assert kr == ki, (kr, ki)
recs = glob.glob(os.path.join(T, "kn-rec", "*.json"))
assert len(recs) == 1, recs
d = json.load(open(recs[0], encoding="utf-8"))
want = hashlib.sha256(open(os.path.join(T, "kn-inv.jsonl"), "rb").read()).hexdigest()
assert any(want in o for o in d["observations"]), d["observations"]
PY
echo "ok (2j): recovery iguala inventario; recibo liga hash"

# (3) windows-contract corre ESTE test (pin de cobertura propia).
YAML=.github/workflows/quality.yml
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-quarantine.sh' \
  || fail "(3) windows-contract no corre test-quarantine.sh"
echo "ok (3): windows-contract cubre este test"

echo "TODO VERDE: quarantine"
