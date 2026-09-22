#!/bin/bash
# Contrato del backup del runtime (Task 5 / 16.4).
#
# Exito exige: `openclaw backup create --verify` con gateway detenido,
# restauracion a staging fresco fuera de repo/runtime con ACL restringida,
# manifiesto legible que cubra estado compartido, bases de agentes,
# credenciales y workspaces declarados, `git bundle` valido de la fuente,
# XML de las cinco tareas, launchers con hash, prueba de espacio libre e
# inventario con hash. La evidencia guarda solo ruta, tamano, hash,
# timestamp y pass/fail. Sin -Apply es report-only y no escribe nada.
#
# Uso: bash scripts/tests/test-runtime-backup.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
BK=scripts/runtime-separation/Backup-OpenClawRuntime.ps1
RECIBO=docs/spec/runtime-separation-receipt.v1.schema.json

for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

# (0) El script existe y parsea limpio.
[ -f "$BK" ] || fail "(0) falta $BK"
PSH="$(command -v pwsh || true)"
[ -n "$PSH" ] || fail "(0) sin pwsh en PATH"
"$PSH" -NoProfile -NonInteractive -Command "
\$e=\$null; \$t=\$null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '$BK'), [ref]\$t, [ref]\$e)
if (\$e -and \$e.Count -gt 0) { \$e | ForEach-Object { \$_.ToString() }; exit 1 }
exit 0
" || fail "(0) ParseFile reporto errores en $BK"
echo "ok (0): Backup-OpenClawRuntime.ps1 existe y parsea"

# (1) Anclas: comandos reales, cinco tareas, ACL, manifiesto, evidencia minima.
for a in 'backup create' '--verify' 'backup restore' 'backup verify' \
    'git bundle' 'bundle verify' 'schtasks' 'icacls' 'MinFreeBytes' \
    'manifest' 'Write-ReceiptAtomic' 'Test-RootsIsolated' '2026.9.5' 'Apply'; do
  grep -qF -- "$a" "$BK" || fail "(1) falta ancla: $a"
done
for t in 'OpenClaw Gateway' 'OpenClaw Gateway Watchdog' 'OpenClaw Node' 'OpenClaw CUA Node' 'GoncloudRepoSync'; do
  grep -qF "$t" "$BK" || fail "(1) falta tarea: $t"
done
for k in 'archivePath' 'sizeBytes' 'sha256' 'createdUtc' 'passed'; do
  grep -qF "$k" "$BK" || fail "(1) falta clave de evidencia: $k"
done
echo "ok (1): comandos, tareas, ACL, manifiesto y evidencia anclados"

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
BKN=$(nat "$BK")
PYBIN=$(command -v python3 || command -v python) || fail "(2) sin python3 ni python"

# --- stubs ---
mkdir -p "$T/fake-bin"
export OC_VERSION="2026.9.5" OC_LOG="$T/oc.log" OC_MODE="full" OC_FAIL_VERIFY=""
: >"$OC_LOG"
cat >"$T/fake-bin/oc-stub.py" <<'PY'
import json, os, sys
log = os.environ["OC_LOG"]
ver = os.environ["OC_VERSION"]
mode = os.environ.get("OC_MODE", "full")
args = sys.argv[1:]
with open(log, "a") as fh:
    fh.write(" ".join(args) + "\n")
if args[:1] == ["--version"]:
    print(f"OpenClaw {ver} (stub)")
elif args[:2] == ["backup", "create"]:
    out = args[args.index("--output") + 1] if "--output" in args else "."
    assert "--verify" in args, "create sin --verify"
    os.makedirs(out, exist_ok=True)
    ap = os.path.join(out, "fake-backup.tar.gz")
    open(ap, "wb").write(b"FAKE-ARCHIVE-BYTES")
    print(json.dumps({"archivePath": ap, "verified": True}))
elif args[:2] == ["backup", "verify"]:
    if os.environ.get("OC_FAIL_VERIFY") == "1":
        print(json.dumps({"ok": False}))
        sys.exit(1)
    print(json.dumps({"ok": True}))
elif args[:2] == ["backup", "restore"]:
    tgt = args[args.index("--target") + 1]
    os.makedirs(tgt, exist_ok=True)
    man = {"assets": [{"kind": "state"}, {"kind": "workspace"}],
           "agentRoots": [{"agentId": "main"}, {"agentId": "verifier"}]}
    if mode == "full":
        man["credentialsIncluded"] = True
        open(os.path.join(tgt, "credentials.json"), "w").write("{}")
    else:
        man["credentialsIncluded"] = False
    json.dump(man, open(os.path.join(tgt, "manifest.json"), "w"))
    os.makedirs(os.path.join(tgt, "state", "agents", "main"), exist_ok=True)
    os.makedirs(os.path.join(tgt, "state", "agents", "verifier"), exist_ok=True)
    open(os.path.join(tgt, "state", "openclaw.sqlite"), "wb").write(b"SQLITE-SHARED")
    open(os.path.join(tgt, "state", "agents", "main", "openclaw-agent.sqlite"), "wb").write(b"SQLITE-MAIN")
    open(os.path.join(tgt, "state", "agents", "verifier", "openclaw-agent.sqlite"), "wb").write(b"SQLITE-VER")
    for w in ("workspace", "workspace-ingenieria", "workspace-operaciones"):
        os.makedirs(os.path.join(tgt, w), exist_ok=True)
    print(json.dumps({"ok": True, "target": tgt}))
elif args[:2] == ["memory", "status"]:
    print(json.dumps([{"agentId": "main"}, {"agentId": "verifier"}]))
else:
    print(f"oc stub: args inesperados: {args}", file=sys.stderr)
    sys.exit(99)
PY
printf '#!/bin/bash\nexec python3 "$(dirname "$0")/oc-stub.py" "$@"\n' >"$T/fake-bin/openclaw"
chmod +x "$T/fake-bin/openclaw"
cat >"$T/fake-bin/schtasks" <<'SH'
#!/bin/bash
# schtasks /query /tn <name> /xml -> XML en stdout
name=""
prev=""
for a in "$@"; do
  if [ "$prev" = "/tn" ]; then name="$a"; fi
  prev="$a"
done
if [ "x$OC_SCHTASKS_MISSING" = "x$name" ]; then
  echo "ERROR: no existe" >&2
  exit 1
fi
printf '<Task version="1.2"><RegistrationInfo><URI>\\%s</URI></RegistrationInfo></Task>\n' "$name"
SH
chmod +x "$T/fake-bin/schtasks"
cat >"$T/fake-bin/icacls" <<'SH'
#!/bin/bash
# lockdown (con /inheritance) -> exit 0; lectura -> ACL en stdout
for a in "$@"; do
  if [ "$a" = "/inheritance:r" ]; then exit 0; fi
done
if [ "${OC_ACL_MODE:-locked}" = "locked" ]; then
  printf '%s NT AUTHORITY\\SYSTEM:(OI)(CI)(F)\n%s *S-1-5-32-544:(OI)(CI)(F)\n' "$1" "$1"
else
  printf '%s BUILTIN\\Users:(OI)(CI)(F)\n' "$1"
fi
SH
chmod +x "$T/fake-bin/icacls"
export PATH="$T/fake-bin:$PATH"

# --- fixtures reales: repo fuente + runtime + launchers ---
git init -q "$T/live-repo" || fail "(2) init repo"
( cd "$T/live-repo" && git config user.name t && git config user.email t@t \
  && git checkout -q -b main && printf 'x\n' > f.txt && git add -A \
  && git -c user.name=t -c user.email=t@t commit -qm base ) || fail "(2) seed repo"
mkdir -p "$T/rt"
printf 'launcher-bytes\n' >"$T/launcher1.cmd"
printf 'watchdog-bytes\n' >"$T/launcher2.ps1"

corre() { # $1=tag $2=apply(0/1) $3+=extra args
  local tag="$1" apply="$2"; shift 2
  local aflag=()
  [ "$apply" = "1" ] && aflag=(-Apply)
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$BKN" \
    -RuntimeRoot "$(nat "$T/rt")" -RepoRoot "$(nat "$T/live-repo")" \
    -BackupDir "$(nat "$T/$tag-bk")" -StagingRoot "$(nat "$T/$tag-staging")" \
    -EvidencePath "$(nat "$T/$tag-evidence.json")" \
    -ReceiptRoot "$(nat "$T/$tag-rec")" \
    -LauncherPaths "$(nat "$T/launcher1.cmd");$(nat "$T/launcher2.ps1")" \
    "${aflag[@]}" "$@" >"$T/$tag.out" 2>&1
  return $?
}

# (2a) Report-only: exit 0 sin escribir nada.
corre ro 0 || fail "(2a) report-only debio salir 0: $(cat "$T/ro.out")"
[ -e "$T/ro-bk" ] && fail "(2a) report-only creo BackupDir"
[ -e "$T/ro-staging" ] && fail "(2a) report-only creo staging"
[ -e "$T/ro-evidence.json" ] && fail "(2a) report-only escribio evidencia"
[ -e "$T/ro-rec" ] && fail "(2a) report-only escribio recibo"
grep -q 'backup create' "$T/ro.out" || fail "(2a) sin plan en stdout"
echo "ok (2a): report-only no escribe, imprime plan"

# (2b) Apply verde: artefactos, cobertura, evidencia minima, recibo.
corre ok 1 || fail "(2b) apply debio salir 0: $(cat "$T/ok.out")"
[ -f "$T/ok-bk/fake-backup.tar.gz" ] || fail "(2b) sin archive"
git bundle verify "$T/ok-bk/"*.bundle >/dev/null 2>&1 || fail "(2b) bundle invalido"
for t in 'OpenClaw Gateway' 'OpenClaw Gateway Watchdog' 'OpenClaw Node' 'OpenClaw CUA Node' 'GoncloudRepoSync'; do
  f=$(grep -rlF "$t" "$T/ok-bk/"*.xml 2>/dev/null | head -1)
  [ -n "$f" ] || fail "(2b) sin XML de $t"
done
grep -rl '<Task ' "$T/ok-bk/"*.xml >/dev/null || fail "(2b) XML sin <Task"
ls "$T/ok-bk/"*.jsonl >/dev/null 2>&1 || fail "(2b) sin inventario"
"$PYBIN" - "$T/ok-bk" <<'PY' || exit 1
import glob, hashlib, json, os, sys
inv = glob.glob(os.path.join(sys.argv[1], "*.jsonl"))
assert len(inv) == 1, inv
n = 0
for line in open(inv[0], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    e = json.loads(line)
    assert set(e) == {"path", "sizeBytes", "sha256"}, set(e)
    raw = open(e["path"], "rb").read()
    assert e["sizeBytes"] == len(raw), e["path"]
    assert e["sha256"] == hashlib.sha256(raw).hexdigest(), e["path"]
    n += 1
assert n >= 8, n  # archive + bundle + 5 xml + 2 launchers
PY
[ -e "$T/ok-staging" ] && fail "(2b) staging quedo sin limpiar tras exito"
"$PYBIN" - "$T/ok-evidence.json" "$T/ok-bk/fake-backup.tar.gz" "$RECIBO" <<'PY' || exit 1
import hashlib, json, re, sys
ev = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(ev) == {"archivePath", "sizeBytes", "sha256", "createdUtc", "passed"}, set(ev)
assert ev["passed"] is True, ev
raw = open(sys.argv[2], "rb").read()
assert ev["sizeBytes"] == len(raw), ev
assert ev["sha256"] == hashlib.sha256(raw).hexdigest(), ev
rec = json.load(open(sys.argv[3], encoding="utf-8"))
rx = re.compile(rec["x-secretValuePattern"])
for v in ev.values():
    assert not rx.search(str(v)), v
PY
"$PYBIN" - "$T/ok-rec" <<'PY' || exit 1
import glob, json, sys
recs = glob.glob(sys.argv[1] + "/*.json")
assert len(recs) == 1, recs
d = json.load(open(recs[0], encoding="utf-8"))
assert d["result"] == "passed", d["result"]
assert d["rollback"]["artifact"].endswith("fake-backup.tar.gz"), d["rollback"]
PY
echo "ok (2b): apply verde con artefactos, cobertura y evidencia minima"

# (2c) Manifiesto sin credenciales: frena, evidencia passed=false, recibo failed.
OC_MODE="nocreds" corre nc 1 && fail "(2c) sin credenciales debio fallar y salio 0"
[ -f "$T/nc-evidence.json" ] || fail "(2c) sin evidencia de fallo"
"$PYBIN" - "$T/nc-evidence.json" <<'PY' || exit 1
import json, sys
ev = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(ev) == {"archivePath", "sizeBytes", "sha256", "createdUtc", "passed"}, set(ev)
assert ev["passed"] is False, ev
PY
[ -e "$T/nc-staging" ] || fail "(2c) staging de fallo no se conservo"
"$PYBIN" - "$T/nc-rec" <<'PY' || exit 1
import glob, json, sys
recs = glob.glob(sys.argv[1] + "/*.json")
assert len(recs) == 1, recs
d = json.load(open(recs[0], encoding="utf-8"))
assert d["result"] == "failed", d["result"]
PY
echo "ok (2c): cobertura incompleta frena con evidencia failed"

# (2d) Tarea faltante: frena cerrado.
OC_SCHTASKS_MISSING="OpenClaw CUA Node" corre st 1 && fail "(2d) tarea faltante debio fallar y salio 0"
echo "ok (2d): XML faltante frena cerrado"

# (2e) Staging dentro del runtime: se rehusa ANTES de crear el archive.
"$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$BKN" \
  -RuntimeRoot "$(nat "$T/rt")" -RepoRoot "$(nat "$T/live-repo")" \
  -BackupDir "$(nat "$T/in-bk")" -StagingRoot "$(nat "$T/rt/staging")" \
  -EvidencePath "$(nat "$T/in-evidence.json")" \
  -ReceiptRoot "$(nat "$T/in-rec")" \
  -LauncherPaths "$(nat "$T/launcher1.cmd")" -Apply >"$T/in.out" 2>&1 \
  && fail "(2e) staging interno debio fallar y salio 0"
[ -e "$T/in-bk/fake-backup.tar.gz" ] && fail "(2e) creo archive antes de validar staging"
echo "ok (2e): staging interno se rehusa antes de mutar"

# (2f) Espacio insuficiente: frena cerrado sin archive.
corre sp 1 -MinFreeBytes 999999999999999 && fail "(2f) sin espacio debio fallar y salio 0"
[ -e "$T/sp-bk/fake-backup.tar.gz" ] && fail "(2f) creo archive sin espacio"
echo "ok (2f): espacio insuficiente frena cerrado"

# (2g) Gateway en marcha: se exige detenido.
cat >"$T/fake-gw.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"status":"ok"}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
"$PYBIN" "$T/fake-gw.py" 18789 >"$T/gw.log" 2>&1 &
GW_PID=$!
trap 'kill $GW_PID 2>/dev/null; rm -rf "$T"' EXIT
i=0
while ! "$PYBIN" -c "import socket; socket.create_connection(('127.0.0.1', 18789), 1).close()" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || fail "(2g) gateway falso no levanto"
  sleep 0.2
done
corre gw 1 -HealthUrl "http://127.0.0.1:18789" && fail "(2g) gateway en marcha debio frenar y salio 0"
[ -e "$T/gw-bk/fake-backup.tar.gz" ] && fail "(2g) creo archive con gateway en marcha"
kill $GW_PID 2>/dev/null || true
echo "ok (2g): gateway en marcha frena (se exige detenido)"

# (2h) Version vieja: report-only avisa, apply frena.
OC_VERSION="2026.9.4" corre vw 0 || fail "(2h) report-only con version vieja debio salir 0"
grep -q '2026.9.5' "$T/vw.out" || fail "(2h) report-only no advierte version"
OC_VERSION="2026.9.4" corre va 1 && fail "(2h) apply con version vieja debio fallar y salio 0"
echo "ok (2h): version vieja avisa en seco y frena en apply"

echo "TODO VERDE: runtime-backup"
