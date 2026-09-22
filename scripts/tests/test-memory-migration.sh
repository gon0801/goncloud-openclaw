#!/bin/bash
# Contrato de memoria Ollama + rollback (Task 5 / 16.4).
#
# La politica config/ollama-runtime.v1.json fija version, URL inmutable,
# SHA-256 del instalador, publisher/cadena Authenticode, hash/firma de
# binarios, loopback:11434, digest de nomic-embed-text y el triple exacto
# ollama/nomic-embed-text/none. El instalador se compara ANTES de ejecutar;
# sin pipe-to-shell. Rollback: con prueba de no-escrituras + switch puede
# restaurar snapshots; si no, diagnostico + none/none + rebuild lexico.
# Nunca local ni llama.cpp. Nota dev: scenarios con exec corren en POSIX;
# CI ubuntu es autoritativo (windows-contract no corre este test).
#
# Uso: bash scripts/tests/test-memory-migration.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
MM=scripts/runtime-separation/Set-OpenClawMemory.ps1
POL=config/ollama-runtime.v1.json

for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

# (0) El script existe y parsea limpio.
[ -f "$MM" ] || fail "(0) falta $MM"
PSH="$(command -v powershell.exe || command -v powershell || command -v pwsh || true)"
[ -n "$PSH" ] || fail "(0) sin powershell ni pwsh en PATH"
"$PSH" -NoProfile -NonInteractive -Command "
\$e=\$null; \$t=\$null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '$MM'), [ref]\$t, [ref]\$e)
if (\$e -and \$e.Count -gt 0) { \$e | ForEach-Object { \$_.ToString() }; exit 1 }
exit 0
" || fail "(0) ParseFile reporto errores en $MM"
echo "ok (0): Set-OpenClawMemory.ps1 existe y parsea"

# (1) Anclas: politica, compuertas, triple exacto, snapshots, rollback.
for a in 'ollama-runtime' 'curl' 'Authenticode' 'netstat' 'ollama pull' \
    'manifestDigest' '/api/embed' 'memory.search' 'sqlite create' 'sqlite verify' \
    'memory index' 'memory search' 'wevtutil' '3033' '3077' 'daemon stop' \
    'daemon start' 'sqlite restore' 'AllowSnapshotRestore' 'Write-ReceiptAtomic' \
    '2026.9.5' 'Apply' 'nomic-embed-text' 'snapshotHash' 'ReparsePoint'; do
  grep -qF "$a" "$MM" || fail "(1) falta ancla: $a"
done
grep -q "'local'" "$MM" || fail "(1) sin regla de rechazo a local"
for b in '| iex' 'Invoke-Expression' 'DownloadString' 'FromBase64String' '| sh'; do
  grep -qF "$b" "$MM" && fail "(1) trae pipe-to-shell: $b"
done
echo "ok (1): compuertas, triple, snapshots y rollback anclados; sin pipe-to-shell"

PYBIN=$(command -v python3 || command -v python) || fail "(2) sin python3 ni python"

# (2) La politica fija todos los pines + revision.
[ -f "$POL" ] || fail "(2) falta $POL"
"$PYBIN" - "$POL" <<'PY' || exit 1
import json, re, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p.get("schema") == "ollama-runtime.v1", "schema"
assert re.fullmatch(r"\d+\.\d+\.\d+", p.get("ollamaVersion", "")), "ollamaVersion"
ins = p["installer"]
assert ins["url"].startswith("https://github.com/ollama/ollama/releases/download/") or \
    ins["url"].startswith("https://ollama.com/"), "url oficial"
assert re.fullmatch(r"[0-9a-f]{64}", ins.get("sha256", "")), "installer sha256"
assert isinstance(ins.get("sizeBytes"), int) and ins["sizeBytes"] > 10**9, "sizeBytes"
assert isinstance(ins.get("args"), list) and len(ins["args"]) > 0, "installer args"
au = p["authenticode"]
for k in ("subjectCN", "issuerCN", "rootCN"):
    assert isinstance(au.get(k), str) and au[k], k
assert au.get("status") == "Valid", "authenticode status"
b0 = p["installedBinaries"][0]
assert b0["name"].endswith(".exe"), "binary name"
assert re.fullmatch(r"[0-9a-f]{64}", b0.get("sha256", "")), "binary sha256"
assert p["service"]["host"] == "127.0.0.1" and p["service"]["port"] == 11434, "loopback"
assert p["model"]["name"] == "nomic-embed-text", "model"
assert re.fullmatch(r"sha256:[0-9a-f]{64}", p["model"].get("manifestDigest", "")), "digest"
assert p["memorySearch"] == {"provider": "ollama", "model": "nomic-embed-text",
                             "fallback": "none"}, "triple exacto"
assert isinstance(p.get("reviewedBy"), str) and p["reviewedBy"], "reviewedBy"
assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", p.get("reviewedUtc", "")), "reviewedUtc"
assert isinstance(p.get("reviewNote"), str) and p["reviewNote"], "reviewNote"
PY
echo "ok (2): politica con pines, triple exacto y revision"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
DBS="$T/rt/dbs"
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
MMN=$(nat "$PWD/$MM")
mp() { # ruta legible por hijos nativos y por bash (mixta en Windows)
  if [ "$en_windows" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}
mkshim() { # $1=nombre $2=script.py -> lanzadores bash + .cmd hacia python
  printf '#!/bin/bash\nexec "%s" "$(dirname "$0")/%s" "$@"\n' "$PYBIN" "$2" >"$T/fake-bin/$1"
  chmod +x "$T/fake-bin/$1"
  printf '@python "%%~dp0%s" %%*\r\n@exit /b %%errorlevel%%\r\n' "$2" >"$T/fake-bin/$1.cmd"
}

# --- stubs ---
mkdir -p "$T/fake-bin" "$DBS"
printf 'DB-MAIN-V1' >"$DBS/main.sqlite"
printf 'DB-VER-V1' >"$DBS/verifier.sqlite"
export OC_VERSION="2026.9.5" OC_LOG="$(mp "$T/oc.log")" OC_STATE="$(mp "$T/oc-config.json")"
export OC_DBDIR="$(mp "$DBS")" OC_SEARCH_MODE="semantic" OC_DAEMON_FAIL="0"
: >"$OC_LOG"
printf '{"provider":"openai","model":"text-embedding-3-small","fallback":"lexical"}' >"$OC_STATE"
cat >"$T/fake-bin/oc-stub.py" <<'PY'
import json, os, sys
log = os.environ["OC_LOG"]
ver = os.environ["OC_VERSION"]
state = os.environ["OC_STATE"]
dbdir = os.environ["OC_DBDIR"]
args = sys.argv[1:]
with open(log, "a") as fh:
    fh.write("openclaw " + " ".join(args) + "\n")
if args[:1] == ["--version"]:
    print(f"OpenClaw {ver} (stub)")
elif args[:2] == ["config", "get"]:
    print(json.dumps(json.load(open(state))))
elif args[:2] == ["config", "set"]:
    d = json.load(open(state))
    d[args[2].split(".")[-1]] = args[3]
    json.dump(d, open(state, "w"))
    print("ok")
elif args[:2] == ["config", "validate"]:
    print(json.dumps({"ok": os.environ.get("OC_INVALID", "0") != "1"}))
elif args[:2] == ["memory", "status"]:
    print(json.dumps([
        {"agentId": "main", "dbPath": os.path.join(dbdir, "main.sqlite"),
         "provider": "openai", "model": "text-embedding-3-small"},
        {"agentId": "verifier", "dbPath": os.path.join(dbdir, "verifier.sqlite"),
         "provider": "openai", "model": "text-embedding-3-small"}]))
elif args[:2] == ["memory", "index"]:
    print("indexed")
elif args[:2] == ["memory", "search"]:
    m = os.environ.get("OC_SEARCH_MODE", "semantic")
    if m == "empty":
        print(json.dumps({"results": []}))
    elif m == "lexical":
        print(json.dumps({"results": [{"score": 0.2, "snippet": "lexical hit"}]}))
    else:
        print(json.dumps({"results": [{"score": 0.9,
            "snippet": "respuesta conceptual sin la frase literal"}]}))
elif args[:3] == ["backup", "sqlite", "create"]:
    repo = args[args.index("--repository") + 1]
    ag = args[args.index("--agent") + 1] if "--agent" in args else "shared"
    os.makedirs(repo, exist_ok=True)
    sp = os.path.join(repo, f"snap-{ag}.db")
    open(sp, "wb").write(b"SNAP-" + ag.encode())
    print(json.dumps({"snapshot": sp}))
elif args[:3] == ["backup", "sqlite", "verify"]:
    print(json.dumps({"ok": True}))
elif args[:3] == ["backup", "sqlite", "restore"]:
    tgt = args[args.index("--target") + 1]
    open(tgt, "wb").write(open(args[3], "rb").read())
    print(json.dumps({"ok": True, "target": tgt}))
elif args[:2] == ["backup", "create"]:
    out = args[args.index("--output") + 1] if "--output" in args else "."
    os.makedirs(out, exist_ok=True)
    ap = os.path.join(out, "diag-backup.tar.gz")
    open(ap, "wb").write(b"DIAG-ARCHIVE")
    print(json.dumps({"archivePath": ap, "verified": True}))
elif args[:2] == ["daemon", "stop"] or args[:2] == ["daemon", "start"]:
    sys.exit(1 if os.environ.get("OC_DAEMON_FAIL") == "1" else 0)
else:
    print(f"oc stub: args inesperados: {args}", file=sys.stderr)
    sys.exit(99)
PY
mkshim openclaw oc-stub.py
cat >"$T/fake-bin/ollama-stub.py" <<'PY'
import os, sys
log = os.environ["OC_LOG"]
args = sys.argv[1:]
with open(log, "a") as fh:
    fh.write("ollama " + " ".join(args) + "\n")
if args[:1] == ["--version"]:
    print("ollama version 0.34.2")
elif args[:1] == ["list"]:
    print("NAME\tID\nnomic-embed-text:latest\t0a109f422b47")
elif args[:1] == ["pull"]:
    sys.exit(0 if args[1:2] == ["nomic-embed-text"] else 1)
else:
    print(f"ollama stub: {' '.join(args)}", file=sys.stderr)
    sys.exit(99)
PY
mkshim ollama ollama-stub.py
cat >"$T/fake-bin/curl-stub.py" <<'PY'
# curl -sSL --fail -o <dest> <url> -> escribe bytes fixture
import os, sys
args = sys.argv[1:]
dest = ""
prev = ""
for a in args:
    if prev == "-o":
        dest = a
    prev = a
if not dest:
    sys.exit(1)
with open(dest, "w", newline="\n") as fh:
    fh.write('#!/bin/bash\necho INSTALADOR-EJECUTADO >>"%s"\nexit 0\n' % os.environ["OC_LOG"])
try:
    os.chmod(dest, 0o755)
except OSError:
    pass
PY
mkshim curl curl-stub.py
cat >"$T/fake-bin/netstat-stub.py" <<'PY'
import os, sys
with open(os.environ["OC_LOG"], "a") as fh:
    fh.write("netstat " + " ".join(sys.argv[1:]) + "\n")
if os.environ.get("OC_NETSTAT_MODE", "loopback") == "loopback":
    print("TCP    127.0.0.1:11434    0.0.0.0:0    LISTENING")
else:
    print("TCP    0.0.0.0:11434    0.0.0.0:0    LISTENING")
PY
mkshim netstat netstat-stub.py
cat >"$T/fake-bin/wevtutil-stub.py" <<'PY'
import os, sys
args = sys.argv[1:]
with open(os.environ["OC_LOG"], "a") as fh:
    fh.write("wevtutil " + " ".join(args) + "\n")
if "3033" in " ".join(args):
    # consulta de eventos: limpio = vacio
    if os.environ.get("OC_EVENTS_MODE", "clean") != "clean":
        print("EventID: 3033 Source: llama-server RecordID: 101")
else:
    print("EventRecordID: 100")  # bookmark
PY
mkshim wevtutil wevtutil-stub.py
cat >"$T/fake-bin/sigchecker-stub.py" <<'PY'
import os, sys
with open(os.environ["OC_LOG"], "a") as fh:
    fh.write("sigchecker " + " ".join(sys.argv[1:]) + "\n")
if os.environ.get("OC_SIG_MODE", "valid") == "valid":
    print("Valid|CN=Ollama Inc.|CN=DigiCert G5 CS ECC SHA384 2021 CA1")
else:
    print("NotSigned||")
PY
mkshim sigchecker sigchecker-stub.py
export PATH="$T/fake-bin:$PATH"

# --- politica fixture (hashes de bytes fixture) ---
"$T/fake-bin/curl" -sSL --fail -o "$T/probe.exe" "http://example.invalid/x" \
  || fail "(2) stub curl no produjo fixture"
INST_SHA=$(shasum -a 256 "$T/probe.exe" 2>/dev/null | cut -d' ' -f1)
[ -n "$INST_SHA" ] || INST_SHA=$(sha256sum "$T/probe.exe" | cut -d' ' -f1)
INST_SIZE=$(wc -c <"$T/probe.exe" | tr -d ' ')
mkdir -p "$T/models/manifests/registry.ollama.ai/library/nomic-embed-text"
printf '{"schemaVersion":2,"config":{"digest":"sha256:aaaa"}}' >"$T/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest"
MAN_SHA=$(shasum -a 256 "$T/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest" 2>/dev/null | cut -d' ' -f1)
[ -n "$MAN_SHA" ] || MAN_SHA=$(sha256sum "$T/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest" | cut -d' ' -f1)
mkdir -p "$T/ollama-bin"
printf 'OLLAMA-EXE-FIXTURE' >"$T/ollama-bin/ollama.exe"
BIN_SHA=$(shasum -a 256 "$T/ollama-bin/ollama.exe" 2>/dev/null | cut -d' ' -f1)
[ -n "$BIN_SHA" ] || BIN_SHA=$(sha256sum "$T/ollama-bin/ollama.exe" | cut -d' ' -f1)
"$PYBIN" - "$T/pol.json" "$INST_SHA" "$MAN_SHA" "$BIN_SHA" "$INST_SIZE" <<'PY'
import json, sys
pol = {"schema": "ollama-runtime.v1", "ollamaVersion": "0.34.2",
 "installer": {"url": "https://github.com/ollama/ollama/releases/download/v0.34.2/OllamaSetup.exe",
   "sha256": sys.argv[2], "sizeBytes": int(sys.argv[5]),
   "args": ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"]},
 "authenticode": {"subjectCN": "Ollama Inc.",
   "issuerCN": "DigiCert G5 CS ECC SHA384 2021 CA1",
   "rootCN": "DigiCert CS ECC P384 Root G5", "status": "Valid"},
 "installedBinaries": [{"name": "ollama.exe", "sha256": sys.argv[4],
   "subjectCN": "Ollama Inc."}],
 "service": {"host": "127.0.0.1", "port": 11434},
 "model": {"name": "nomic-embed-text", "manifestDigest": "sha256:" + sys.argv[3]},
 "memorySearch": {"provider": "ollama", "model": "nomic-embed-text", "fallback": "none"},
 "reviewedBy": "fixture", "reviewedUtc": "2026-09-22", "reviewNote": "test"}
json.dump(pol, open(sys.argv[1], "w"))
PY

# --- API embed falsa (modo bueno/vacio) ---
printf 'good' >"$T/embed-mode"
cat >"$T/fake-embed.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, os, sys
MODE_FILE = os.environ["OC_EMBED_MODE_FILE"]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        assert body.get("model") == "nomic-embed-text", body
        assert body.get("input"), body
        mode = open(MODE_FILE).read().strip()
        if mode == "good":
            payload = {"embeddings": [[0.1] * 8]}
        else:
            payload = {"embeddings": []}
        raw = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
export OC_EMBED_MODE_FILE="$(mp "$T/embed-mode")"
"$PYBIN" "$T/fake-embed.py" 11434 >"$T/embed.log" 2>&1 &
EMB_PID=$!
trap 'kill $EMB_PID 2>/dev/null; rm -rf "$T"' EXIT
i=0
while ! "$PYBIN" -c "import socket; socket.create_connection(('127.0.0.1', 11434), 1).close()" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || fail "(3) embed falso no levanto"
  sleep 0.2
done

corre() { # $1=tag $2=mode $3=apply(0/1) resto=extra
  local tag="$1" mode="$2" apply="$3"; shift 3
  local aflag=()
  [ "$apply" = "1" ] && aflag=(-Apply)
  : >"$OC_LOG"
  printf '{"provider":"openai","model":"text-embedding-3-small","fallback":"lexical"}' >"$OC_STATE"
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$MMN" \
    -RuntimeRoot "$(nat "$T/rt")" -PolicyPath "$(nat "$T/pol.json")" \
    -ReceiptRoot "$(nat "$T/$tag-rec")" -SnapshotRepo "$(nat "$T/$tag-snap")" \
    -OllamaModelsDir "$(nat "$T/models")" -OllamaInstallDir "$(nat "$T/ollama-bin")" \
    -SignatureChecker "$(nat "$T/fake-bin/sigchecker")" \
    -HealthUrl "http://127.0.0.1:9" -Mode "$mode" -VerifyQuery "concepto sin literal" \
    "${aflag[@]}" "$@" >"$T/$tag.out" 2>&1
  return $?
}

# (3a) Migrate report-only: exit 0 sin mutar nada.
mkdir -p "$T/rt"
corre mro migrate 0 || fail "(3a) report-only debio salir 0: $(cat "$T/mro.out")"
grep -q 'config set' "$OC_LOG" && fail "(3a) report-only toco config"
grep -q 'ollama pull' "$OC_LOG" && fail "(3a) report-only hizo pull"
[ -e "$T/mro-snap" ] && fail "(3a) report-only creo snapshots"
[ -e "$T/mro-rec" ] && fail "(3a) report-only escribio recibo"
echo "ok (3a): migrate report-only no muta"

# (3b) Migrate verde (POSIX: ejecuta instalador fixture).
if [ "$en_windows" -eq 1 ]; then
  echo "SKIP (3b): instalador fixture POSIX; CI ubuntu lo cubre"
else
  corre mok migrate 1 || fail "(3b) migrate debio salir 0: $(cat "$T/mok.out")"
  grep -q 'INSTALADOR-EJECUTADO' "$OC_LOG" || fail "(3b) no ejecuto instalador"
  [ "$(grep -c 'openclaw config set' "$OC_LOG")" = 3 ] || fail "(3b) sets != 3: $(cat "$OC_LOG")"
  grep -q 'config set memory.search.provider ollama' "$OC_LOG" || fail "(3b) sin set provider"
  grep -q 'config set memory.search.model nomic-embed-text' "$OC_LOG" || fail "(3b) sin set model"
  grep -q 'config set memory.search.fallback none' "$OC_LOG" || fail "(3b) sin set fallback"
  [ "$(grep -c 'memory index' "$OC_LOG")" = 2 ] || fail "(3b) index != 2 agentes"
  [ "$(grep -c 'sqlite create' "$OC_LOG")" = 2 ] || fail "(3b) snapshots != 2"
  grep -q 'wevtutil' "$OC_LOG" || fail "(3b) sin chequeo de eventos"
  "$PYBIN" - "$T/mok-rec" <<'PY' || exit 1
import glob, json, sys
recs = glob.glob(sys.argv[1] + "/*.json")
assert len(recs) == 1, recs
d = json.load(open(recs[0], encoding="utf-8"))
assert d["result"] == "passed", d["result"]
obs = " ".join(d["observations"])
assert "main" in obs and "verifier" in obs, obs
assert "openai" in obs, obs
PY
  "$PYBIN" - "$T/mok-snap/migration.json" "$DBS/main.sqlite" "$DBS/verifier.sqlite" "$T/mok-snap" <<'PY' || exit 1
import hashlib, json, os, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["schema"] == "memory-migration.v1", m.get("schema")
assert m["globalPrior"] == {"provider": "openai", "model": "text-embedding-3-small",
                            "fallback": "lexical"}, m["globalPrior"]
by = {a["agent"]: a for a in m["agents"]}
assert set(by) == {"main", "verifier"}, set(by)
for ag, db in (("main", sys.argv[2]), ("verifier", sys.argv[3])):
    want = hashlib.sha256(open(db, "rb").read()).hexdigest()
    assert by[ag]["dbHash"] == want, ag
    assert by[ag]["snapshot"].endswith(f"snap-{ag}.db"), by[ag]
    swant = hashlib.sha256(open(os.path.join(sys.argv[4], f"snap-{ag}.db"), "rb").read()).hexdigest()
    assert by[ag]["snapshotHash"] == swant, ag
PY
  echo "ok (3b): migrate verde con snapshots, triple, indices y recibo"
fi

# (3c) SHA distinto: frena ANTES de ejecutar.
"$PYBIN" - "$T/pol.json" "$T/pol-badsha.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["installer"]["sha256"] = "0" * 64
json.dump(p, open(sys.argv[2], "w"))
PY
: >"$OC_LOG"
"$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$MMN" \
  -RuntimeRoot "$(nat "$T/rt")" -PolicyPath "$(nat "$T/pol-badsha.json")" \
  -ReceiptRoot "$(nat "$T/badsha-rec")" -SnapshotRepo "$(nat "$T/badsha-snap")" \
  -OllamaModelsDir "$(nat "$T/models")" -OllamaInstallDir "$(nat "$T/ollama-bin")" \
  -SignatureChecker "$(nat "$T/fake-bin/sigchecker")" \
  -HealthUrl "http://127.0.0.1:9" -Mode migrate -VerifyQuery "x" -Apply \
  >"$T/badsha.out" 2>&1 && fail "(3c) SHA distinto debio frenar y salio 0"
grep -q 'INSTALADOR-EJECUTADO' "$OC_LOG" && fail "(3c) ejecuto con SHA distinto"
echo "ok (3c): SHA distinto frena antes de ejecutar"

# (3d) Firma invalida: frena sin ejecutar.
OC_SIG_MODE="invalid" corre badsig migrate 1 && fail "(3d) firma invalida debio frenar y salio 0"
grep -q 'INSTALADOR-EJECUTADO' "$OC_LOG" && fail "(3d) ejecuto con firma invalida"
echo "ok (3d): firma invalida frena sin ejecutar"

# (3e) Digest distinto: frena sin tocar config.
printf '{"schemaVersion":2,"config":{"digest":"sha256:bbbb"}}' >"$T/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest"
corre baddigest migrate 1 && fail "(3e) digest distinto debio frenar y salio 0"
grep -q 'config set' "$OC_LOG" && fail "(3e) toco config con digest distinto"
printf '{"schemaVersion":2,"config":{"digest":"sha256:aaaa"}}' >"$T/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest"
echo "ok (3e): digest distinto frena sin tocar config"

# (3f) Embed vacio: frena sin tocar config.
printf 'empty' >"$T/embed-mode"
corre badempty migrate 1 && fail "(3f) embed vacio debio frenar y salio 0"
grep -q 'config set' "$OC_LOG" && fail "(3f) toco config con embed vacio"
printf 'good' >"$T/embed-mode"
echo "ok (3f): embed vacio frena sin tocar config"

# (3g) Puerto no-loopback: frena.
OC_NETSTAT_MODE="open" corre badloop migrate 1 && fail "(3g) puerto abierto debio frenar y salio 0"
echo "ok (3g): endpoint no-loopback frena"

# (3h) Version vieja: report-only avisa, apply frena.
OC_VERSION="2026.9.4" corre vw migrate 0 || fail "(3h) report-only viejo debio salir 0"
OC_VERSION="2026.9.4" corre va migrate 1 && fail "(3h) apply viejo debio frenar y salio 0"
echo "ok (3h): version vieja avisa en seco y frena en apply"

# (3i) Puerto fuera de politica: frena.
corre badport migrate 1 -OllamaPort 11435 && fail "(3i) puerto distinto debio frenar y salio 0"
echo "ok (3i): puerto fuera de politica frena"

# (3j) Eventos 3033/3077 nuevos: frena.
if [ "$en_windows" -eq 1 ]; then
  echo "SKIP (3j): instalador fixture POSIX; CI ubuntu lo cubre"
else
  OC_EVENTS_MODE="dirty" corre badev migrate 1 && fail "(3j) eventos nuevos debio frenar y salio 0"
  echo "ok (3j): eventos 3033/3077 nuevos frenan"
fi

# (3k) DB fuera de RuntimeRoot: frena antes de snapshots y config.
if [ "$en_windows" -eq 1 ]; then
  echo "SKIP (3k): instalador fixture POSIX; CI ubuntu lo cubre"
else
  mkdir -p "$T/fuera"
  printf 'DB-FUERA' >"$T/fuera/main.sqlite"
  printf 'DB-FUERA' >"$T/fuera/verifier.sqlite"
  OC_DBDIR="$T/fuera" corre badrt migrate 1 \
    && fail "(3k) db fuera debio frenar y salio 0"
  grep -q 'sqlite create' "$OC_LOG" && fail "(3k) snapshot con db fuera de runtime"
  grep -q 'config set' "$OC_LOG" && fail "(3k) toco config con db fuera de runtime"
  echo "ok (3k): db fuera de runtime frena antes de snapshots"
fi

kill $EMB_PID 2>/dev/null || true

# --- rollback: fixture migration.json ---
mk_migration() { # $1=dest $2=prior-provider (openai|local)
  "$PYBIN" - "$1" "$2" "$DBS/main.sqlite" "$DBS/verifier.sqlite" "$T/rb-snap" <<'PY'
import hashlib, json, sys
def h(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()
m = {"schema": "memory-migration.v1", "createdUtc": "2026-09-22T10:00:00Z",
 "agents": [
   {"agent": "main", "snapshot": sys.argv[5] + "/snap-main.db",
    "snapshotHash": h(sys.argv[5] + "/snap-main.db"),
    "dbHash": h(sys.argv[3]), "dbPath": sys.argv[3],
    "priorProvider": sys.argv[2], "priorModel": "text-embedding-3-small"},
   {"agent": "verifier", "snapshot": sys.argv[5] + "/snap-verifier.db",
    "snapshotHash": h(sys.argv[5] + "/snap-verifier.db"),
    "dbHash": h(sys.argv[4]), "dbPath": sys.argv[4],
    "priorProvider": sys.argv[2], "priorModel": "text-embedding-3-small"}],
 "globalPrior": {"provider": sys.argv[2], "model": "text-embedding-3-small",
                 "fallback": "lexical"},
 "policyDigest": "sha256:" + "0" * 64}
json.dump(m, open(sys.argv[1], "w"))
PY
}
mkdir -p "$T/rb-snap"
printf 'SNAP-MAIN' >"$T/rb-snap/snap-main.db"
printf 'SNAP-VER' >"$T/rb-snap/snap-verifier.db"
mk_migration "$T/mig-ok.json" "openai"

corre_rb() { # $1=tag $2=migration $3+=extra
  local tag="$1" mig="$2"; shift 2
  : >"$OC_LOG"
  printf '{"provider":"ollama","model":"nomic-embed-text","fallback":"none"}' >"$OC_STATE"
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$MMN" \
    -RuntimeRoot "$(nat "$T/rt")" -PolicyPath "$(nat "$T/pol.json")" \
    -ReceiptRoot "$(nat "$T/$tag-rec")" -SnapshotRepo "$(nat "$T/rb-snap")" \
    -MigrationPath "$(nat "$mig")" -HealthUrl "http://127.0.0.1:9" \
    -Mode rollback -Apply "$@" >"$T/$tag.out" 2>&1
  return $?
}

# (4a) Sin escrituras + switch: restaura snapshots y revierte config.
corre_rb rbsnap "$T/mig-ok.json" -AllowSnapshotRestore \
  || fail "(4a) rollback snapshot debio salir 0: $(cat "$T/rbsnap.out")"
[ "$(grep -c 'sqlite restore' "$OC_LOG")" = 2 ] || fail "(4a) restore != 2"
grep -q 'config set memory.search.provider openai' "$OC_LOG" || fail "(4a) sin revertir provider"
grep -q 'daemon start' "$OC_LOG" || fail "(4a) sin reinicio"
"$PYBIN" - "$T/rbsnap-rec" <<'PY' || exit 1
import glob, json, sys
recs = glob.glob(sys.argv[1] + "/*.json")
assert len(recs) == 1, recs
d = json.load(open(recs[0], encoding="utf-8"))
assert d["result"] == "passed", d["result"]
assert "snapshot" in " ".join(d["observations"]), d["observations"]
PY
# (4a) restaura de verdad: re-sembrar DBs para los siguientes escenarios.
printf 'DB-MAIN-V1' >"$DBS/main.sqlite"
printf 'DB-VER-V1' >"$DBS/verifier.sqlite"
echo "ok (4a): sin escrituras + switch restaura snapshots"

# (4b) Con escrituras: diagnostico + none/none, jamas restore.
printf 'DB-MAIN-V2' >"$DBS/main.sqlite"
corre_rb rbdiag "$T/mig-ok.json" -AllowSnapshotRestore \
  || fail "(4b) rollback diagnostico debio salir 0: $(cat "$T/rbdiag.out")"
grep -q 'sqlite restore' "$OC_LOG" && fail "(4b) restauro con escrituras encima"
grep -q 'backup create' "$OC_LOG" || fail "(4b) sin backup diagnostico"
grep -q 'config set memory.search.provider none' "$OC_LOG" || fail "(4b) sin provider none"
grep -q 'config set memory.search.fallback none' "$OC_LOG" || fail "(4b) sin fallback none"
grep -qi 'config set memory.search.provider local' "$OC_LOG" && fail "(4b) selecciono local"
[ "$(grep -c 'memory index' "$OC_LOG")" = 2 ] || fail "(4b) sin rebuild lexico x2"
"$PYBIN" - "$T/rbdiag-rec" <<'PY' || exit 1
import glob, json, sys
d = json.load(open(glob.glob(sys.argv[1] + "/*.json")[0], encoding="utf-8"))
assert d["result"] == "passed", d["result"]
assert "diagnostic" in " ".join(d["observations"]), d["observations"]
PY
printf 'DB-MAIN-V1' >"$DBS/main.sqlite"
echo "ok (4b): con escrituras va a diagnostico + none/none"

# (4c) Sin switch aunque coincidan hashes: diagnostico.
corre_rb rbnosw "$T/mig-ok.json" \
  || fail "(4c) rollback sin switch debio salir 0: $(cat "$T/rbnosw.out")"
grep -q 'sqlite restore' "$OC_LOG" && fail "(4c) restauro sin switch"
grep -q 'backup create' "$OC_LOG" || fail "(4c) sin diagnostico sin switch"
echo "ok (4c): sin switch no restaura aunque coincidan"

# (4d) Gateway que no se detiene: frena sin mutar.
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
  [ "$i" -lt 50 ] || fail "(4d) gateway falso no levanto"
  sleep 0.2
done
: >"$OC_LOG"
OC_DAEMON_FAIL="1" "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$MMN" \
  -RuntimeRoot "$(nat "$T/rt")" -PolicyPath "$(nat "$T/pol.json")" \
  -ReceiptRoot "$(nat "$T/rbdown-rec")" -SnapshotRepo "$(nat "$T/rb-snap")" \
  -MigrationPath "$(nat "$T/mig-ok.json")" -HealthUrl "http://127.0.0.1:18789" \
  -Mode rollback -Apply -AllowSnapshotRestore >"$T/rbdown.out" 2>&1 \
  && fail "(4d) gateway vivo sin stop debio frenar y salio 0"
grep -q 'config set' "$OC_LOG" && fail "(4d) muto sin detener gateway"
grep -q 'sqlite restore' "$OC_LOG" && fail "(4d) restauro sin detener gateway"
echo "ok (4d): gateway que no para frena sin mutar"

# (4g) Rollback report-only: decide sin mutar.
: >"$OC_LOG"
"$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$MMN" \
  -RuntimeRoot "$(nat "$T/rt")" -PolicyPath "$(nat "$T/pol.json")" \
  -ReceiptRoot "$(nat "$T/rbro-rec")" -SnapshotRepo "$(nat "$T/rb-snap")" \
  -MigrationPath "$(nat "$T/mig-ok.json")" -HealthUrl "http://127.0.0.1:9" \
  -Mode rollback -AllowSnapshotRestore >"$T/rbro.out" 2>&1 \
  || fail "(4g) rollback report-only debio salir 0: $(cat "$T/rbro.out")"
grep -q 'snapshot-restore' "$T/rbro.out" || fail "(4g) sin decision en plan"
grep -q 'config set' "$OC_LOG" && fail "(4g) report-only muto config"
grep -q 'sqlite restore' "$OC_LOG" && fail "(4g) report-only restauro"
[ -e "$T/rbro-rec" ] && fail "(4g) report-only escribio recibo"
echo "ok (4g): rollback report-only decide sin mutar"

# (4e) Prior local: se rehusa aunque coincidan hashes + switch.
mk_migration "$T/mig-local.json" "local"
corre_rb rblocal "$T/mig-local.json" -AllowSnapshotRestore \
  && fail "(4e) prior local debio frenar y salio 0"
grep -q 'sqlite restore' "$OC_LOG" && fail "(4e) restauro con prior local"
echo "ok (4e): prior local jamas se restaura"

# (4f) Gateway en marcha + stop OK: procede y verifica salud al final.
corre_rb_up() {
  : >"$OC_LOG"
  printf '{"provider":"ollama","model":"nomic-embed-text","fallback":"none"}' >"$OC_STATE"
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$MMN" \
    -RuntimeRoot "$(nat "$T/rt")" -PolicyPath "$(nat "$T/pol.json")" \
    -ReceiptRoot "$(nat "$T/rbup-rec")" -SnapshotRepo "$(nat "$T/rb-snap")" \
    -MigrationPath "$(nat "$T/mig-ok.json")" -HealthUrl "http://127.0.0.1:18789" \
    -Mode rollback -Apply -AllowSnapshotRestore >"$T/rbup.out" 2>&1
  return $?
}
corre_rb_up || fail "(4f) rollback con stop OK debio salir 0: $(cat "$T/rbup.out")"
grep -q 'daemon stop' "$OC_LOG" || fail "(4f) sin daemon stop"
"$PYBIN" - "$T/rbup-rec" <<'PY' || exit 1
import glob, json, sys
d = json.load(open(glob.glob(sys.argv[1] + "/*.json")[0], encoding="utf-8"))
assert d["result"] == "passed", d["result"]
assert d["health"]["startupz"] == 200 and d["health"]["readyz"] == 200, d["health"]
PY
kill $GW_PID 2>/dev/null || true
echo "ok (4f): stop OK procede y salud 200 al final"

# (4h) Rollback no confia en registro manipulado: canoniza, confina
# db dentro de RuntimeRoot y snapshot dentro de SnapshotRepo, verifica
# hashes y rechaza reparse points, duplicados y campos desconocidos.
printf 'DB-MAIN-V1' >"$DBS/main.sqlite"
printf 'DB-VER-V1' >"$DBS/verifier.sqlite"
mkdir -p "$T/fuera"
printf 'VICTIMA' >"$T/fuera/victima.sqlite"
printf 'SNAP-FUERA' >"$T/fuera/snap-fuera.db"
printf 'SNAP-FUERA2' >"$T/fuera/snap2.db"
"$PYBIN" - "$T" "$DBS" <<'PY' || exit 1
import hashlib, json, os, sys
T, DBS = sys.argv[1], sys.argv[2]
def h(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()
def base():
    snap = os.path.join(T, "rb-snap")
    return {"schema": "memory-migration.v1", "createdUtc": "2026-09-22T10:00:00Z",
     "agents": [
       {"agent": "main", "snapshot": os.path.join(snap, "snap-main.db"),
        "snapshotHash": h(os.path.join(snap, "snap-main.db")),
        "dbHash": h(os.path.join(DBS, "main.sqlite")),
        "dbPath": os.path.join(DBS, "main.sqlite"),
        "priorProvider": "openai", "priorModel": "text-embedding-3-small"},
       {"agent": "verifier", "snapshot": os.path.join(snap, "snap-verifier.db"),
        "snapshotHash": h(os.path.join(snap, "snap-verifier.db")),
        "dbHash": h(os.path.join(DBS, "verifier.sqlite")),
        "dbPath": os.path.join(DBS, "verifier.sqlite"),
        "priorProvider": "openai", "priorModel": "text-embedding-3-small"}],
     "globalPrior": {"provider": "openai", "model": "text-embedding-3-small",
                     "fallback": "lexical"},
     "policyDigest": "sha256:" + "0" * 64}
def w(name, m):
    json.dump(m, open(os.path.join(T, name), "w"))
m = base()
m["agents"][0]["dbPath"] = os.path.join(T, "fuera", "victima.sqlite")
m["agents"][0]["dbHash"] = h(os.path.join(T, "fuera", "victima.sqlite"))
w("mig-h-a.json", m)
m = base()
m["agents"][0]["snapshot"] = os.path.join(T, "fuera", "snap-fuera.db")
m["agents"][0]["snapshotHash"] = h(os.path.join(T, "fuera", "snap-fuera.db"))
w("mig-h-b.json", m)
w("mig-h-c.json", base())
m = base()
m["agents"][1] = dict(m["agents"][0], agent="main")
w("mig-h-d.json", m)
m = base()
m["agents"][0]["extra"] = 1
w("mig-h-e.json", m)
m = base()
m["agents"][0]["dbPath"] = os.path.join(DBS, "evil.sqlite")
m["agents"][0]["dbHash"] = h(os.path.join(T, "fuera", "victima.sqlite"))
w("mig-h-f.json", m)
m = base()
m["agents"][0]["snapshot"] = os.path.join(T, "rb-snap", "snap-evil.db")
m["agents"][0]["snapshotHash"] = h(os.path.join(T, "fuera", "snap2.db"))
w("mig-h-g.json", m)
PY
corre_rb rbha "$T/mig-h-a.json" -AllowSnapshotRestore \
  && fail "(4h/a) db escape debio frenar y salio 0"
[ "$(cat "$T/fuera/victima.sqlite")" = "VICTIMA" ] || fail "(4h/a) toco db fuera de runtime"
grep -q 'sqlite restore' "$OC_LOG" && fail "(4h/a) intento restore con escape"
corre_rb rbhb "$T/mig-h-b.json" -AllowSnapshotRestore \
  && fail "(4h/b) snapshot escape debio frenar y salio 0"
[ "$(cat "$DBS/main.sqlite")" = "DB-MAIN-V1" ] || fail "(4h/b) restauro desde snapshot fuera de repo"
grep -q 'sqlite restore' "$OC_LOG" && fail "(4h/b) intento restore con escape"
corre_rb rbhd "$T/mig-h-d.json" -AllowSnapshotRestore \
  && fail "(4h/d) duplicado debio frenar y salio 0"
grep -q 'sqlite restore' "$OC_LOG" && fail "(4h/d) restauro con duplicados"
corre_rb rbhe "$T/mig-h-e.json" -AllowSnapshotRestore \
  && fail "(4h/e) campo extra debio frenar y salio 0"
grep -q 'sqlite restore' "$OC_LOG" && fail "(4h/e) restauro con campo desconocido"
if ln -s "$T/fuera/victima.sqlite" "$DBS/evil.sqlite" 2>/dev/null \
    && [ -L "$DBS/evil.sqlite" ]; then
  corre_rb rbhf "$T/mig-h-f.json" -AllowSnapshotRestore \
    && fail "(4h/f) reparse db debio frenar y salio 0"
  [ "$(cat "$T/fuera/victima.sqlite")" = "VICTIMA" ] || fail "(4h/f) toco via reparse"
  grep -q 'sqlite restore' "$OC_LOG" && fail "(4h/f) restauro via reparse"
else
  echo "SKIP (4h/f): sin symlinks"
fi
if ln -s "$T/fuera/snap2.db" "$T/rb-snap/snap-evil.db" 2>/dev/null \
    && [ -L "$T/rb-snap/snap-evil.db" ]; then
  corre_rb rbhg "$T/mig-h-g.json" -AllowSnapshotRestore \
    && fail "(4h/g) reparse snapshot debio frenar y salio 0"
  [ "$(cat "$DBS/main.sqlite")" = "DB-MAIN-V1" ] || fail "(4h/g) restauro via reparse"
  grep -q 'sqlite restore' "$OC_LOG" && fail "(4h/g) restauro via reparse"
else
  echo "SKIP (4h/g): sin symlinks"
fi
printf 'x-intruso' >>"$T/rb-snap/snap-main.db"
corre_rb rbhc "$T/mig-h-c.json" -AllowSnapshotRestore \
  || fail "(4h/c) snapshot distinto debio ir a diagnostico: $(cat "$T/rbhc.out")"
grep -q 'sqlite restore' "$OC_LOG" && fail "(4h/c) restauro con snapshot distinto"
grep -q 'backup create' "$OC_LOG" || fail "(4h/c) sin diagnostico con snapshot distinto"
echo "ok (4h): rollback rechaza registro manipulado; snapshot distinto va a diagnostico"
"$PYBIN" - "$T/rbsnap-rec" "$T/mig-ok.json" <<'PY' || exit 1
import glob, hashlib, json, sys
d = json.load(open(glob.glob(sys.argv[1] + "/*.json")[0], encoding="utf-8"))
want = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
assert any(want in o for o in d["observations"]), d["observations"]
PY
echo "ok (4h): recibo de rollback liga migration por hash"

# (5) windows-contract corre ESTE test (pin de cobertura propia).
YAML=.github/workflows/quality.yml
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-memory-migration.sh' \
  || fail "(5) windows-contract no corre test-memory-migration.sh"
echo "ok (5): windows-contract cubre este test"

echo "TODO VERDE: memory-migration"
