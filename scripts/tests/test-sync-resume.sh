#!/bin/bash
# Contrato de reanudacion tras crash (Task 3 / 16.3, Step 3).
#
# Sin ganchos de prueba en prod: los estados de crash se pre-siembran
# (equivalentes a matar el proceso tras cada punto, porque cada reemplazo
# es atomico y cada fase es re-ejecutable) y el reintento converge:
# ledger-sin-PR + rama empujada = adopta sin duplicar; journal trunco =
# reanuda; staging rancio se reconstruye; deploy parcial converge.
#
# Uso: bash scripts/tests/test-sync-resume.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
ORQ=scripts/runtime-separation/Sync-OpenClawRuntime.ps1
YAML=.github/workflows/quality.yml
PUERTO_FAKE=18796

for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

# (0) El orquestador existe y habla de resume.
[ -f "$ORQ" ] || fail "(0) falta $ORQ"
grep -qi 'reanud' "$ORQ" || fail "(0) sin ruta de reanudacion"
grep -q 'worktree prune' "$ORQ" || fail "(0) sin poda de worktrees huerfanos"
grep -q 'pr list' "$ORQ" || fail "(0) sin adopcion por pr list"
echo "ok (0): reanudacion anclada"

# --- motor PowerShell ---
en_windows=0
[ "${OS:-}" = "Windows_NT" ] && en_windows=1
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) en_windows=1;; esac
PSH="$(command -v powershell.exe || command -v powershell || command -v pwsh || true)"
if [ "$en_windows" -eq 1 ] && [ -z "$PSH" ]; then
  fail "(1) en Windows powershell.exe debe existir"
fi
PYBIN=$(command -v python3 || command -v python) || fail "(1) sin python3 ni python en PATH"

if [ -n "$PSH" ]; then
  T=$(mktemp -d) || exit 1
  trap 'rm -rf "$T"' EXIT
  nat() {
    if [ "$en_windows" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then
      cygpath -w "$1"
    else
      case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$PWD" "$1";; esac
    fi
  }
  ORQN=$(nat "$ORQ")

  mkdir -p "$T/fake-bin"
  export GH_LOG="$T/gh.log" GH_CTR="$T/gh-ctr" GH_STATE="$T/gh-state.json"
  echo 1 >"$GH_CTR"; echo '{}' >"$GH_STATE"; : >"$GH_LOG"
  cat >"$T/fake-bin/gh-stub.py" <<'PY'
import json, os, sys
log, ctr, state = os.environ["GH_LOG"], os.environ["GH_CTR"], os.environ["GH_STATE"]
args = sys.argv[1:]
def head_of(a):
    for i, x in enumerate(a):
        if x == "--head" and i + 1 < len(a):
            return a[i + 1]
    return None
if args[:2] == ["pr", "create"]:
    n = int(open(ctr).read().strip())
    open(ctr, "w").write(str(n + 1))
    with open(log, "a") as fh:
        fh.write(f"create head={head_of(args)}\n")
    if "--json" in args:
        print(json.dumps({"number": n, "url": f"https://example.invalid/pull/{n}"}))
    else:
        print(f"https://example.invalid/pull/{n}")
elif args[:2] == ["pr", "view"]:
    st = json.load(open(state))
    print(json.dumps(st.get(str(args[2]), {})))
elif args[:2] == ["pr", "list"]:
    st = json.load(open(state))
    h = head_of(args)
    print(json.dumps([{"number": int(k), **v} for k, v in st.items() if v.get("headRefName") == h]))
else:
    print(f"gh stub: args inesperados: {args}", file=sys.stderr)
    sys.exit(99)
PY
  printf '#!/bin/bash\nexec python3 "$(dirname "$0")/gh-stub.py" "$@"\n' >"$T/fake-bin/gh"
  chmod +x "$T/fake-bin/gh"
  printf '@python "%%~dp0gh-stub.py" %%*\r\n' >"$T/fake-bin/gh.cmd"
  printf '#!/bin/bash\necho "Config valid (stub)"\n' >"$T/fake-bin/openclaw"
  chmod +x "$T/fake-bin/openclaw"
  printf '@echo Config valid (stub)\r\n' >"$T/fake-bin/openclaw.cmd"
  export PATH="$T/fake-bin:$PATH"

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
    [ "$i" -lt 50 ] || { kill $GW_PID 2>/dev/null; fail "(1) gateway falso no levanto"; }
    sleep 0.2
  done

  git init -q --bare "$T/origin.git" || fail "(1) bare"
  W="$T/w"; git clone -q "$T/origin.git" "$W" 2>/dev/null || fail "(1) seed"
  ( cd "$W" && git checkout -q -b main \
    && mkdir -p agents/main/agent/workshop-skills/s \
    && printf 'v1\n' > agents/main/agent/workshop-skills/s/SKILL.md \
    && printf '$httpTimeoutSec = 90\n' > gateway-watchdog.ps1 \
    && git add -A && git -c user.name=t -c user.email=t@t commit -qm base \
    && git push -q origin main ) || fail "(1) seed"
  rm -rf "$W"
  git clone -q "$T/origin.git" "$T/src" 2>/dev/null || fail "(1) clone"
  ( cd "$T/src" && git config user.name t && git config user.email t@t ) || fail "(1) id"
  mkdir -p "$T/rt/agents/main/agent/workshop-skills/s"
  printf 'v2\n' >"$T/rt/agents/main/agent/workshop-skills/s/SKILL.md"
  printf '$httpTimeoutSec = 90\n' >"$T/rt/gateway-watchdog.ps1"
  printf '{"ok":true}\n' >"$T/rt/openclaw.json"
  cat >"$T/man.json" <<'JSON'
{"schema": "runtime-deploy.v1", "sourceRoot": "C:\\F\\src", "runtimeRoot": "C:\\F\\rt",
 "allowed": [{"path": "gateway-watchdog.ps1", "kind": "file", "reason": "t"},
             {"path": "agents/*/agent/workshop-skills/**", "kind": "glob", "reason": "t"}],
 "denied": [{"pattern": "**/*.secret", "reason": "t"}]}
JSON
  corre() {
    "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ORQN" \
      -SourceRoot "$(nat "$T/src")" -RuntimeRoot "$(nat "$T/rt")" \
      -ReceiptRoot "$(nat "$T/rec")" -LedgerPath "$(nat "$T/ledger.json")" \
      -JournalPath "$(nat "$T/journal.jsonl")" -LogPath "$(nat "$T/sync.log")" \
      -ManifestPath "$(nat "$T/man.json")" -StagingRoot "$(nat "$T/staging")" \
      -HealthUrl "http://127.0.0.1:$PUERTO_FAKE" \
      -OpenClawVersion 2026.9.5 >"$T/$1.out" 2>&1
    return $?
  }

  # (1a) Crash tras push pre-ledger: rama empujada + PR existente + ledger
  # con pr 0 -> adopta el 7 sin crear.
  RAMA=auto/skills/20260922T100000Z-main
  W="$T/w"; git clone -q "$T/origin.git" "$W" 2>/dev/null \
    && ( cd "$W" && git checkout -q -b "$RAMA" origin/main \
      && printf 'v2\n' > agents/main/agent/workshop-skills/s/SKILL.md \
      && git -c user.name=t -c user.email=t@t commit -qam v2 \
      && git push -q origin "$RAMA" ) || fail "(1a) rama huesfana"
  rm -rf "$W"
  HEADB=$(cd "$T/src" && git ls-remote "$T/origin.git" "$RAMA" | cut -f1)
  "$PYBIN" - "$GH_STATE" "$RAMA" "$HEADB" <<'PY'
import json, sys
json.dump({"7": {"state": "OPEN", "mergedAt": None, "headRefOid": sys.argv[3], "headRefName": sys.argv[2]}},
          open(sys.argv[1], "w"))
PY
  V2SHA=$(printf 'v2\n' | shasum -a 256 2>/dev/null | cut -d' ' -f1)
  [ -n "$V2SHA" ] || V2SHA=$(printf 'v2\n' | sha256sum | cut -d' ' -f1)
  "$PYBIN" - "$T/ledger.json" "$RAMA" "$V2SHA" <<'PY'
import json, sys
doc = {"schema": "skills-pr-ledger.v1", "updatedUtc": "2026-09-22T10:00:00Z",
       "entries": {"agents/main/agent/workshop-skills/s/SKILL.md":
        {"liveHash": sys.argv[3], "capturedHash": sys.argv[3], "branch": sys.argv[2],
         "commit": "0" * 40, "pr": 0, "status": "open", "previousPr": 0,
         "updatedUtc": "2026-09-22T10:00:00Z"}}, "tombstones": {}}
json.dump(doc, open(sys.argv[1], "w"))
PY
  corre a || fail "(1a) adopcion debio salir 0: $(cat "$T/a.out")"
  [ -s "$GH_LOG" ] && fail "(1a) creo PR teniendo el 7: $(cat "$GH_LOG")"
  "$PYBIN" - "$T/ledger.json" <<'PY' || fail "(1a) sin adopcion del 7"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]["agents/main/agent/workshop-skills/s/SKILL.md"]
assert e["pr"] == 7 and e["commit"] != "0" * 40, e
PY
  grep -q 'SKILLS_PR 7 ' "$T/sync.log" || fail "(1a) sin SKILLS_PR 7 adoptado"
  echo "ok (1a): rama huerfana + PR existente se adopta sin duplicar"

  # (1b) Journal trunco + deploy parcial + staging rancio convergen.
  printf '{"op":"cycle-start","ts":"2026-09-22T10:00:00Z"}\n' >"$T/journal.jsonl"
  mkdir -p "$T/staging"
  printf 'basura\n' >"$T/staging/garbage.txt"
  W="$T/w"; git clone -q "$T/origin.git" "$W" 2>/dev/null \
    && ( cd "$W" && git checkout -q main && git fetch -q origin "$RAMA" \
      && git -c user.name=t -c user.email=t@t merge -q --no-ff FETCH_HEAD -m m7 \
      && git push -q origin main ) || fail "(1b) merge7"
  rm -rf "$W"
  "$PYBIN" - "$GH_STATE" "$RAMA" "$HEADB" <<'PY'
import json, sys
json.dump({"7": {"state": "MERGED", "mergedAt": "2026-09-22T11:00:00Z",
                 "headRefOid": sys.argv[3], "headRefName": sys.argv[2]}},
          open(sys.argv[1], "w"))
PY
  corre b || fail "(1b) reintento debio salir 0: $(cat "$T/b.out")"
  grep -qi 'reanud' "$T/sync.log" || fail "(1b) sin nota de reanudacion"
  [ -e "$T/staging/garbage.txt" ] && fail "(1b) staging rancio sobrevivio"
  grep -q 'SKILLS_DEPLOYED ' "$T/sync.log" || fail "(1b) sin SKILLS_DEPLOYED"
  [ "$(cat "$T/rt/agents/main/agent/workshop-skills/s/SKILL.md")" = "v2" ] \
    || fail "(1b) runtime sin v2"
  echo "ok (1b): journal trunco + staging rancio convergen a deployed"

  # (1c) Ledger completo + crash = re-ciclo sin duplicar ni empujar de mas.
  ANTES_C=$(grep -c '^create ' "$GH_LOG" || true)
  corre c || fail "(1c) re-ciclo debio salir 0: $(cat "$T/c.out")"
  [ "$(grep -c '^create ' "$GH_LOG" || true)" = "$ANTES_C" ] || fail "(1c) duplico PR"
  echo "ok (1c): ledger completo re-ejecuta sin duplicar"
  kill $GW_PID 2>/dev/null || true
else
  echo "SKIP (1): sin motor PowerShell; windows-contract cubre resume"
fi

# (2) windows-contract corre ESTE test (pin de cobertura propia).
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-sync-resume.sh' \
  || fail "(2) windows-contract no corre test-sync-resume.sh"
echo "ok (2): windows-contract cubre este test"

echo "TODO VERDE: sync-resume"
