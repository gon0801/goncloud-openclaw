#!/bin/bash
# Contrato del nodo Windows aislado (Task 6 / 16.5).
#
# Estado en dir dedicado con ACL restringida, sin copia SQLite del gateway,
# config minima exacta, allowlist local sin comodines ni shells (argv exacto
# o argPattern anclado con casos), paring unico en primer plano con codigo
# redactado, superficie exacta de 8 comandos, install sin --pair bajo el
# mismo estado, duplicada exportada antes de borrar, oficial habilitada con
# logon trigger y estado aislado tras cerrar la terminal, reinicio + espera
# por condicion con connected + 2026.9.5. Nota dev: scenarios con exec corren
# en POSIX; CI ubuntu es autoritativo.
#
# Uso: bash scripts/tests/test-node-isolation.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
ND=scripts/runtime-separation/Set-OpenClawNode.ps1

for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

# (0) El script existe y parsea limpio.
[ -f "$ND" ] || fail "(0) falta $ND"
PSH="$(command -v powershell.exe || command -v powershell || command -v pwsh || true)"
[ -n "$PSH" ] || fail "(0) sin powershell ni pwsh en PATH"
"$PSH" -NoProfile -NonInteractive -Command "
\$e=\$null; \$t=\$null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '$ND'), [ref]\$t, [ref]\$e)
if (\$e -and \$e.Count -gt 0) { \$e | ForEach-Object { \$_.ToString() }; exit 1 }
exit 0
" || fail "(0) ParseFile reporto errores en $ND"
echo "ok (0): Set-OpenClawNode.ps1 existe y parsea"

# (1) Anclas: estado, allowlist, pairing, superficie, tareas.
for a in '.openclaw-node' 'icacls' 'argPattern' 'x-cases' 'node run' '--pair' \
    'nodes pending' 'nodes approve' 'approvals set' 'approvals get' 'node identity' \
    'node install' 'OpenClaw Node' 'OpenClaw CUA Node' '/delete' 'LogonTrigger' \
    'Enabled' 'nodes status' 'Write-ReceiptAtomic' 'OPENCLAW_STATE_DIR' \
    '2026.9.5' 'Apply'; do
  grep -qF -- "$a" "$ND" || fail "(1) falta ancla: $a"
done
for c in 'browser.proxy' 'browser.proxy.upload.v1' 'computer.act' 'screen.snapshot' \
    'system.run' 'system.run.prepare' 'system.which' 'fs.listDir'; do
  grep -qF "$c" "$ND" || fail "(1) falta comando: $c"
done
echo "ok (1): estado, allowlist, pairing y superficie anclados"

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
NDN=$(nat "$ND")
PYBIN=$(command -v python3 || command -v python) || fail "(2) sin python3 ni python"
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
mkdir -p "$T/fake-bin"
export OC_VERSION="2026.9.5" OC_LOG="$(mp "$T/oc.log")" OC_STATE="$(mp "$T/oc-config.json")"
export OC_CAPTURE="$(mp "$T/uploaded.json")" OC_STATUS_MODE="ok"
: >"$OC_LOG"
: >"$OC_STATE"
cat >"$T/fake-bin/oc-stub.py" <<'PY'
import json, os, shutil, sys, time
log = os.environ["OC_LOG"]
ver = os.environ["OC_VERSION"]
args = sys.argv[1:]
def w(s):
    with open(log, "a") as fh:
        fh.write(s + "\n")
if args[:1] == ["--version"]:
    print(f"OpenClaw {ver} (stub)")
elif args[:2] == ["config", "set"]:
    w(f"openclaw config set {args[2]} {args[3]}")
    d = json.load(open(os.environ["OC_STATE"])) if os.path.getsize(os.environ["OC_STATE"]) else {}
    d[args[2]] = args[3]
    json.dump(d, open(os.environ["OC_STATE"], "w"))
    print("ok")
elif args[:2] == ["config", "get"]:
    d = json.load(open(os.environ["OC_STATE"])) if os.path.getsize(os.environ["OC_STATE"]) else {}
    print(d.get(args[2], "null"))
elif args[:2] == ["config", "validate"]:
    print(json.dumps({"ok": True}))
elif args[:2] == ["nodes", "pending"]:
    w("openclaw nodes pending")
    print(json.dumps([{"requestId": "req-1", "displayName": "Windows CUA"}]))
elif args[:2] == ["nodes", "approve"]:
    w(f"openclaw nodes approve {args[2]}")
    print(json.dumps({"nodeId": os.environ.get("OC_APPROVE_ID", "node-1")}))
elif args[:2] == ["approvals", "set"]:
    src = args[args.index("--file") + 1]
    w(f"openclaw approvals set --file {src} node={args[args.index('--node') + 1]}")
    shutil.copyfile(src, os.environ["OC_CAPTURE"])
    print(json.dumps({"ok": True}))
elif args[:2] == ["approvals", "get"]:
    w("openclaw approvals get")
    up = json.load(open(os.environ["OC_CAPTURE"]))
    print(json.dumps({"file": {"version": 1, "agents": up.get("agents", {})}}))
elif args[:2] == ["node", "identity"]:
    w(f"openclaw node identity state={os.environ.get('OPENCLAW_STATE_DIR', '')}")
    print(json.dumps({"deviceId": "node-1"}))
elif args[:2] == ["node", "run"]:
    assert "--pair" in args, "run sin --pair"
    w(f"openclaw node run state={os.environ.get('OPENCLAW_STATE_DIR', '')} PAIR_USED=1")
    time.sleep(300)
elif args[:2] == ["node", "install"]:
    assert "--pair" not in args, "install con --pair PROHIBIDO"
    w(f"openclaw node install state={os.environ.get('OPENCLAW_STATE_DIR', '')} args={' '.join(args[2:])}")
    print(json.dumps({"ok": True}))
elif args[:2] == ["nodes", "status"]:
    w("openclaw nodes status")
    mode = os.environ.get("OC_STATUS_MODE", "ok")
    cmds = ["browser.proxy", "browser.proxy.upload.v1", "computer.act",
            "screen.snapshot", "system.run", "system.run.prepare",
            "system.which", "fs.listDir"]
    if mode == "extra-cmd":
        cmds = cmds + ["file.write"]
    conn = mode != "disconnected"
    print(json.dumps({"nodes": [{"nodeId": "node-1", "displayName": "Windows CUA",
        "connected": conn, "version": "2026.9.5", "commands": cmds}]}))
else:
    print(f"oc stub: args inesperados: {args}", file=sys.stderr)
    sys.exit(99)
PY
mkshim openclaw oc-stub.py
export NODE_STATE_DIR="$(nat "$T/nstate")" ST_DIR="$(mp "$T")"
mkdir -p "$T"
cat >"$T/fake-bin/schtasks-stub.py" <<'PY'
import os, sys
log = os.environ["OC_LOG"]
st = os.environ["ST_DIR"]
args = sys.argv[1:]
with open(log, "a") as fh:
    fh.write("schtasks " + " ".join(args) + "\n")
op = args[0] if args else ""
if op == "/query":
    name = ""
    prev = ""
    for a in args:
        if prev == "/tn":
            name = a
        prev = a
    if name == "OpenClaw CUA Node":
        if os.environ.get("OC_CUA_MODE", "present") == "absent" or \
                os.path.exists(os.path.join(st, "cua-deleted")):
            print("ERROR: no existe", file=sys.stderr)
            sys.exit(1)
        print('<Task version="1.2"><RegistrationInfo><URI>\\OpenClaw CUA Node</URI></RegistrationInfo></Task>')
    else:
        if os.environ.get("OC_NODE_MODE", "present") == "absent":
            print("ERROR: no existe", file=sys.stderr)
            sys.exit(1)
        print('<Task version="1.2"><RegistrationInfo><URI>\\OpenClaw Node</URI></RegistrationInfo>'
              "<Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>"
              "<Settings><Enabled>true</Enabled></Settings><Actions><Exec><Command>openclaw.exe</Command>"
              "<Arguments>node run --state %s</Arguments></Exec></Actions></Task>"
              % os.environ["NODE_STATE_DIR"])
elif op == "/delete":
    open(os.path.join(st, "cua-deleted"), "w").close()
elif op == "/run":
    pass
else:
    print(f"schtasks stub: {' '.join(args)}", file=sys.stderr)
    sys.exit(99)
PY
mkshim schtasks schtasks-stub.py
cat >"$T/fake-bin/icacls-stub.py" <<'PY'
import sys
args = sys.argv[1:]
for a in args:
    if a == "/inheritance:r":
        sys.exit(0)
d = args[0] if args else ""
print("%s NT AUTHORITY\\SYSTEM:(OI)(CI)(F)" % d)
print("%s testuser:(OI)(CI)(F)" % d)
PY
mkshim icacls icacls-stub.py
export PATH="$T/fake-bin:$PATH"

# --- approvals valido ---
cat >"$T/approvals.json" <<'JSON'
{"version": 1, "agents": {"main": {"allowlist": [
  {"pattern": "C:\\Tools\\snap.exe",
   "argPattern": "^--out C:\\\\fixed\\\\a\\.png$"},
  {"pattern": "C:\\Tools\\probe.exe",
   "argPattern": "^--level (1|2|3)$"}
]}},
 "x-cases": [
  {"pattern": "C:\\Tools\\snap.exe", "argPattern": "^--out C:\\\\fixed\\\\a\\.png$",
   "allow": ["--out C:\\fixed\\a.png"], "deny": ["--out C:\\fixed\\b.png", "--out C:\\other\\a.png"]},
  {"pattern": "C:\\Tools\\probe.exe", "argPattern": "^--level (1|2|3)$",
   "allow": ["--level 2"], "deny": ["--level 9", "--level 2 --extra"]}
 ]}
JSON

corre() { # $1=tag $2=apply(0/1) resto=extra
  local tag="$1" apply="$2"; shift 2
  local aflag=()
  [ "$apply" = "1" ] && aflag=(-Apply)
  : >"$OC_LOG"
  : >"$OC_STATE"
  rm -f "$OC_CAPTURE" "$T/cua-deleted"
  export NODE_STATE_DIR="$(nat "$T/$tag-nstate")"
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$NDN" \
    -NodeStateDir "$(nat "$T/$tag-nstate")" -NodeDisplayName "Windows CUA" \
    -GatewayHost "10.0.0.9" -GatewayPort 18789 -NodeUser "testuser" \
    -ApprovalsPath "$(nat "$T/approvals.json")" \
    -NodeConfigSets 'browser.proxy.skillPublish=false;inference.local.enabled=false' \
    -PairingCode "pair-CODE-$tag-9Z" -ReceiptRoot "$(nat "$T/$tag-rec")" \
    -PollIntervalSec 1 -PairTimeoutSec 20 -StatusTimeoutSec 20 \
    "${aflag[@]}" "$@" >"$T/$tag.out" 2>&1
  return $?
}

# (2a) Report-only: valida, no escribe; invalido frena en seco.
corre ro 0 || fail "(2a) report-only debio salir 0: $(cat "$T/ro.out")"
[ -e "$T/ro-nstate" ] && fail "(2a) report-only creo estado"
[ -e "$T/ro-rec" ] && fail "(2a) report-only escribio recibo"
grep -q 'node run' "$T/ro.out" || fail "(2a) sin plan en stdout"
printf '{"version":1,"agents":{"main":{"allowlist":[{"pattern":"C:\\Tools\\x.exe"}]}}}' >"$T/bad-approvals.json"
"$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$NDN" \
  -NodeStateDir "$(nat "$T/robad-nstate")" -NodeDisplayName "Windows CUA" \
  -GatewayHost "10.0.0.9" -ApprovalsPath "$(nat "$T/bad-approvals.json")" \
  -NodeConfigSets 'a.b=false' -ReceiptRoot "$(nat "$T/robad-rec")" \
  >"$T/robad.out" 2>&1 && fail "(2a) report-only invalido debio frenar y salio 0"
echo "ok (2a): report-only valida sin escribir"

# (2b) Apply verde.
corre ok 1 || fail "(2b) apply debio salir 0: $(cat "$T/ok.out")"
[ -d "$T/ok-nstate" ] || fail "(2b) sin dir de estado"
[ "$(grep -c 'openclaw config set' "$OC_LOG")" = 2 ] || fail "(2b) sets != 2"
[ "$(find "$T/ok-nstate" -name '*.sqlite' | wc -l | tr -d ' ')" = 0 ] || fail "(2b) sqlite en estado"
grep -q 'PAIR_USED=1' "$OC_LOG" || fail "(2b) sin node run --pair"
grep -q 'node install' "$OC_LOG" || fail "(2b) sin node install"
grep -q -- '--pair' "$OC_LOG" && fail "(2b) codigo o flag --pair en log"
[ "$(grep -n 'PAIR_USED=1' "$OC_LOG" | cut -d: -f1)" -lt "$(grep -n 'node install' "$OC_LOG" | cut -d: -f1)" ] \
  || fail "(2b) install antes que run"
grep -q 'approvals set' "$OC_LOG" || fail "(2b) sin approvals set"
[ "$(grep -n 'approvals set' "$OC_LOG" | cut -d: -f1)" -lt "$(grep -n 'PAIR_USED=1' "$OC_LOG" | cut -d: -f1)" ] \
  || fail "(2b) pairing arranco antes de approvals set"
[ "$(grep -n 'approvals get' "$OC_LOG" | cut -d: -f1)" -lt "$(grep -n 'PAIR_USED=1' "$OC_LOG" | cut -d: -f1)" ] \
  || fail "(2b) pairing arranco antes de approvals readback"
"$PYBIN" - "$OC_CAPTURE" <<'PY' || exit 1
import json, sys
up = json.load(open(sys.argv[1], encoding="utf-8"))
assert "x-cases" not in up, "x-cases subido!"
assert up["agents"]["main"]["allowlist"][0]["pattern"].endswith("snap.exe")
PY
grep -q 'schtasks /delete' "$OC_LOG" || fail "(2b) sin borrar duplicada"
cua_xml=$(find "$T" -name '*.xml' | head -1)
[ -n "$cua_xml" ] || fail "(2b) sin XML exportada de la duplicada"
grep -q 'OpenClaw CUA Node' "$cua_xml" || fail "(2b) XML no es de la duplicada"
grep -q 'schtasks /run' "$OC_LOG" || fail "(2b) sin reinicio de tarea"
grep -qrF "pair-CODE-ok-9Z" "$T" 2>/dev/null && fail "(2b) codigo de pairing en disco"
"$PYBIN" - "$T/ok-rec" <<'PY' || exit 1
import glob, json, sys
recs = glob.glob(sys.argv[1] + "/*.json")
assert len(recs) == 1, recs
d = json.load(open(recs[0], encoding="utf-8"))
assert d["result"] == "passed", d["result"]
PY
echo "ok (2b): apply verde con pairing, superficie y tareas"

# (2c) Allowlist estricta: 8 variantes invalidas frenan en seco sin estado.
mkbad() { # $1=nombre $2=entry-json $3=cases-json
  "$PYBIN" - "$T/bad-$1.json" "$2" "$3" <<'PY'
import json, sys
doc = {"version": 1,
       "agents": {"main": {"allowlist": [json.loads(sys.argv[2])]}},
       "x-cases": [json.loads(sys.argv[3])] if sys.argv[3] != "null" else []}
json.dump(doc, open(sys.argv[1], "w"))
PY
}
mkbad wildcard '{"pattern": "C:\\\\Tools\\\\*.exe", "argPattern": "^a$"}' \
  '{"pattern": "C:\\\\Tools\\\\*.exe", "argPattern": "^a$", "allow": ["a"], "deny": ["b"]}'
mkbad pathonly '{"pattern": "C:\\\\Tools\\\\x.exe"}' 'null'
mkbad unanchored '{"pattern": "C:\\\\Tools\\\\x.exe", "argPattern": "--level [123]"}' \
  '{"pattern": "C:\\\\Tools\\\\x.exe", "argPattern": "--level [123]", "allow": ["--level 2"], "deny": ["--level 9"]}'
mkbad nested '{"pattern": "C:\\\\Tools\\\\x.exe", "argPattern": "^(ab*)*$"}' \
  '{"pattern": "C:\\\\Tools\\\\x.exe", "argPattern": "^(ab*)*$", "allow": ["ab"], "deny": ["z"]}'
mkbad cmd '{"pattern": "C:\\\\Windows\\\\System32\\\\cmd.exe", "argPattern": "^/c echo$"}' \
  '{"pattern": "C:\\\\Windows\\\\System32\\\\cmd.exe", "argPattern": "^/c echo$", "allow": ["/c echo"], "deny": ["/c del"]}'
mkbad sh '{"pattern": "/bin/sh", "argPattern": "^-c id$"}' \
  '{"pattern": "/bin/sh", "argPattern": "^-c id$", "allow": ["-c id"], "deny": ["-c rm"]}'
mkbad allowfail '{"pattern": "C:\\\\Tools\\\\x.exe", "argPattern": "^a$"}' \
  '{"pattern": "C:\\\\Tools\\\\x.exe", "argPattern": "^a$", "allow": ["b"], "deny": ["c"]}'
mkbad denypass '{"pattern": "C:\\\\Tools\\\\x.exe", "argPattern": "^.*$"}' \
  '{"pattern": "C:\\\\Tools\\\\x.exe", "argPattern": "^.*$", "allow": ["a"], "deny": ["evil"]}'
for v in wildcard pathonly unanchored nested cmd sh allowfail denypass; do
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$NDN" \
    -NodeStateDir "$(nat "$T/c-$v-nstate")" -NodeDisplayName "Windows CUA" \
    -GatewayHost "10.0.0.9" -ApprovalsPath "$(nat "$T/bad-$v.json")" \
    -NodeConfigSets 'a.b=false' -ReceiptRoot "$(nat "$T/c-$v-rec")" \
    >"$T/c-$v.out" 2>&1 && fail "(2c) $v debio frenar y salio 0"
  [ -e "$T/c-$v-nstate" ] && fail "(2c) $v creo estado"
done
echo "ok (2c): 8 variantes invalidas frenan sin estado"

# (2d) Superficie con extra: frena nombrando el comando.
OC_STATUS_MODE="extra-cmd" corre xsurf 1 \
  && fail "(2d) superficie extra debio frenar y salio 0"
grep -q 'file.write' "$T/xsurf.out" || fail "(2d) no nombra el comando extra"
echo "ok (2d): superficie distinta frena nombrando el extra"

# (2e) Nodo que nunca conecta: frena por timeout.
OC_STATUS_MODE="disconnected" corre noconn 1 \
  && fail "(2e) sin conexion debio frenar y salio 0"
echo "ok (2e): sin conexion frena por timeout"

# (2f) Duplicada ausente: idempotente; oficial ausente: frena.
OC_CUA_MODE="absent" corre nocua 1 \
  || fail "(2f) duplicada ausente debio salir 0: $(cat "$T/nocua.out")"
OC_NODE_MODE="absent" corre nonode 1 \
  && fail "(2f) oficial ausente debio frenar y salio 0"
echo "ok (2f): duplicada idempotente, oficial obligatoria"

# (2g) Approve ajeno al pre-aprobado: frena.
OC_APPROVE_ID="node-2" corre wrongdev 1 \
  && fail "(2g) approve ajeno debio frenar y salio 0"
grep -q 'aprobado ajeno' "$T/wrongdev.out" || fail "(2g) no nombra el desajuste"
echo "ok (2g): approve ajeno al pre-aprobado frena"

# (2h) Version vieja: report-only avisa, apply frena.
OC_VERSION="2026.9.4" corre vw 0 || fail "(2h) report-only viejo debio salir 0"
OC_VERSION="2026.9.4" corre va 1 && fail "(2h) apply viejo debio frenar y salio 0"
echo "ok (2h): version vieja avisa en seco y frena en apply"

# (3) windows-contract corre ESTE test (pin de cobertura propia).
YAML=.github/workflows/quality.yml
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-node-isolation.sh' \
  || fail "(3) windows-contract no corre test-node-isolation.sh"
echo "ok (3): windows-contract cubre este test"

echo "TODO VERDE: node-isolation"
