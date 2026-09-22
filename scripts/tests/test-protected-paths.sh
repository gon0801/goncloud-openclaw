#!/bin/bash
# Contrato de rutas protegidas (Task 3 / 16.3, Step 2).
#
# Borrado/renombre -> tombstone + git rm en el PR, ausente mientras pendiente,
# reconciliado solo tras merge. Cambio no-capturable -> alerta + bytes
# intactos. Falta config/watchdog -> tombstone + CONFLICTO, sin commit hasta
# que el dueno resuelva. Rutas a log pasan por Protect-LogToken (sin CRLF).
#
# Uso: bash scripts/tests/test-protected-paths.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
ORQ=scripts/runtime-separation/Sync-OpenClawRuntime.ps1
MODULO=scripts/runtime-separation/RuntimeSeparation.psm1
YAML=.github/workflows/quality.yml
PUERTO_FAKE=18797

for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

# (0) El orquestador existe.
[ -f "$ORQ" ] || fail "(0) falta $ORQ"
echo "ok (0): el orquestador existe"

# (1) Anclas de proteccion.
grep -qi 'tombstone' "$ORQ" || fail "(1) sin tombstones"
grep -q 'CONFLICTO' "$ORQ" || fail "(1) sin CONFLICTO"
grep -q 'ALERTA' "$ORQ" || fail "(1) sin ALERTA"
grep -q 'Protect-LogToken' "$ORQ" || fail "(1) sin sanitizacion de rutas a log"
grep -q 'ExcludePaths' "$ORQ" || fail "(1) sin exclusiones al deploy"
grep -qF 'function Protect-LogToken' "$MODULO" || fail "(1) Protect-LogToken no esta en el modulo"
echo "ok (1): tombstones, CONFLICTO, ALERTA, sanitizacion y exclusiones anclados"

# --- motor PowerShell ---
en_windows=0
[ "${OS:-}" = "Windows_NT" ] && en_windows=1
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) en_windows=1;; esac
PSH="$(command -v powershell.exe || command -v powershell || command -v pwsh || true)"
if [ "$en_windows" -eq 1 ] && [ -z "$PSH" ]; then
  fail "(2) en Windows powershell.exe debe existir"
fi
PYBIN=$(command -v python3 || command -v python) || fail "(2) sin python3 ni python en PATH"

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
  # Absolutas: Import-Module 5.1 no resuelve rutas relativas (CI4).
  ORQN=$(nat "$PWD/$ORQ"); MODN=$(nat "$PWD/$MODULO")

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
    [ "$i" -lt 50 ] || { kill $GW_PID 2>/dev/null; fail "(2) gateway falso no levanto"; }
    sleep 0.2
  done

  git init -q -b main --bare "$T/origin.git" || fail "(2) bare"
  W="$T/w"; git clone -q "$T/origin.git" "$W" 2>/dev/null || fail "(2) seed clone"
  ( cd "$W" && git checkout -q -b main \
    && mkdir -p agents/main/agent/workshop-skills/s agents/main/agent/workshop-skills/r-old \
    && printf 'v1\n' > agents/main/agent/workshop-skills/s/SKILL.md \
    && printf 'cuerpo\n' > agents/main/agent/workshop-skills/r-old/SKILL.md \
    && printf '# agente\n' > agents/main/agent.md \
    && printf '$httpTimeoutSec = 90\n' > gateway-watchdog.ps1 \
    && git add -A && git -c user.name=t -c user.email=t@t commit -qm base \
    && git push -q origin main ) || fail "(2) seed"
  rm -rf "$W"
  git clone -q "$T/origin.git" "$T/src" 2>/dev/null || fail "(2) clone src"
  ( cd "$T/src" && git config user.name t && git config user.email t@t ) || fail "(2) identidad"
  mkdir -p "$T/rt/agents/main/agent/workshop-skills/s" "$T/rt/agents/main/agent/workshop-skills/r-old"
  printf 'v1\n' >"$T/rt/agents/main/agent/workshop-skills/s/SKILL.md"
  printf 'cuerpo\n' >"$T/rt/agents/main/agent/workshop-skills/r-old/SKILL.md"
  printf '# agente\n' >"$T/rt/agents/main/agent.md"
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
      -ManifestPath "$(nat "$T/man.json")" -HealthUrl "http://127.0.0.1:$PUERTO_FAKE" \
      -OpenClawVersion 2026.9.5 >"$T/$1.out" 2>&1
    return $?
  }

  # (2a) Borrado vivo -> PR con git rm + tombstone; sigue ausente.
  rm "$T/rt/agents/main/agent/workshop-skills/s/SKILL.md"
  corre a || fail "(2a) ciclo borrado debio salir 0: $(cat "$T/a.out")"
  [ "$(grep -c '^create ' "$GH_LOG")" = 1 ] || fail "(2a) sin PR de borrado"
  RAMA1=$(grep '^create ' "$GH_LOG" | head -1 | sed 's/.*head=//')
  ( cd "$T/src" && git fetch -q origin "$RAMA1" 2>/dev/null \
    && [ -z "$(git ls-tree -r --name-only FETCH_HEAD -- agents/main/agent/workshop-skills/s/)" ] ) \
    || fail "(2a) la rama no trae el rm"
  "$PYBIN" - "$T/ledger.json" <<'PY' || fail "(2a) sin tombstone de s"
import json, sys
t = json.load(open(sys.argv[1]))["tombstones"]
assert "agents/main/agent/workshop-skills/s/SKILL.md" in t, t.keys()
PY
  [ -e "$T/rt/agents/main/agent/workshop-skills/s/SKILL.md" ] && fail "(2a) reaparecio s"
  echo "ok (2a): borrado captura rm + tombstone, sigue ausente"

  # (2b) Renombre -> un PR con rm+add, tombstone del viejo.
  mkdir -p "$T/rt/agents/main/agent/workshop-skills/r-new"
  mv "$T/rt/agents/main/agent/workshop-skills/r-old/SKILL.md" \
     "$T/rt/agents/main/agent/workshop-skills/r-new/SKILL.md"
  corre b || fail "(2b) ciclo renombre debio salir 0: $(cat "$T/b.out")"
  [ "$(grep -c '^create ' "$GH_LOG")" = 2 ] || fail "(2b) sin PR de renombre"
  RAMA2=$(grep '^create ' "$GH_LOG" | tail -1 | sed 's/.*head=//')
  ( cd "$T/src" && git fetch -q origin "$RAMA2" 2>/dev/null \
    && [ -z "$(git ls-tree -r --name-only FETCH_HEAD -- agents/main/agent/workshop-skills/r-old/)" ] \
    && [ "$(git show "FETCH_HEAD:agents/main/agent/workshop-skills/r-new/SKILL.md")" = "cuerpo" ] ) \
    || fail "(2b) la rama no trae rm+add del renombre"
  "$PYBIN" - "$T/ledger.json" <<'PY' || fail "(2b) sin tombstone de r-old"
import json, sys
t = json.load(open(sys.argv[1]))["tombstones"]
assert "agents/main/agent/workshop-skills/r-old/SKILL.md" in t, t.keys()
PY
  echo "ok (2b): renombre captura rm+add con tombstone del viejo"

  # (2c) Cambio no-capturable -> ALERTA, bytes intactos, fuera de PRs.
  printf '# agente EDITADO\n' >"$T/rt/agents/main/agent.md"
  corre c || fail "(2c) ciclo alerta debio salir 0: $(cat "$T/c.out")"
  grep -q 'ALERTA .*agents/main/agent.md' "$T/sync.log" || fail "(2c) sin ALERTA"
  [ "$(grep -c '^create ' "$GH_LOG")" = 2 ] || fail "(2c) el cambio no-capturable abrio PR"
  [ "$(cat "$T/rt/agents/main/agent.md")" = '# agente EDITADO' ] || fail "(2c) bytes alterados"
  echo "ok (2c): no-capturable alerta, preserva y no entra a PRs"

  # (2d) Falta watchdog -> CONFLICTO + tombstone; el deploy no lo recrea.
  rm "$T/rt/gateway-watchdog.ps1"
  corre d1 || fail "(2d) ciclo falta-watchdog debio salir 0: $(cat "$T/d1.out")"
  grep -q 'CONFLICTO' "$T/sync.log" || fail "(2d) sin CONFLICTO"
  # Merge del PR1 (borrado s) y deploy: s se reconcilia, watchdog sigue ausente.
  W="$T/w"; git clone -q "$T/origin.git" "$W" 2>/dev/null \
    && ( cd "$W" && git checkout -q main && git fetch -q origin "$RAMA1" \
      && git -c user.name=t -c user.email=t@t merge -q --no-ff FETCH_HEAD -m merge1 \
      && git push -q origin main ) || fail "(2d) merge1"
  rm -rf "$W"
  HEAD1=$(cd "$T/src" && git ls-remote "$T/origin.git" "$RAMA1" | cut -f1)
  "$PYBIN" - "$GH_STATE" "$RAMA1" "$HEAD1" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
st["1"] = {"state": "MERGED", "mergedAt": "2026-09-22T11:00:00Z",
           "headRefOid": sys.argv[3], "headRefName": sys.argv[2]}
json.dump(st, open(sys.argv[1], "w"))
PY
  NREC0=$(ls "$T/rec/"*.json 2>/dev/null | wc -l | tr -d ' ')
  corre d2 || fail "(2d) ciclo deploy debio salir 0: $(cat "$T/d2.out")"
  [ "$(ls "$T/rec/"*.json 2>/dev/null | wc -l | tr -d ' ')" -gt "$NREC0" ] \
    || fail "(2d) sin recibo de deploy"
  grep -q 'SKILLS_DEPLOYED ' "$T/sync.log" || fail "(2d) sin SKILLS_DEPLOYED"
  [ -e "$T/rt/gateway-watchdog.ps1" ] && fail "(2d) el deploy recreo el watchdog"
  [ -e "$T/rt/agents/main/agent/workshop-skills/s/SKILL.md" ] \
    && fail "(2d) el deploy recreo s borrada"
  "$PYBIN" - "$T/ledger.json" <<'PY' || fail "(2d) tombstone s no se limpio"
import json, sys
t = json.load(open(sys.argv[1]))["tombstones"]
assert "agents/main/agent/workshop-skills/s/SKILL.md" not in t, t.keys()
assert "gateway-watchdog.ps1" in t, t.keys()
PY
  echo "ok (2d): merge reconcilia s; watchdog ausente protegido del deploy"

  # (2e) Falta config -> CONFLICTO + tombstone; jamas entra a un commit.
  rm "$T/rt/openclaw.json"
  corre e || fail "(2e) ciclo falta-config debio salir 0: $(cat "$T/e.out")"
  grep -q 'CONFLICTO' "$T/sync.log" || fail "(2e) sin CONFLICTO"
  for r in "$RAMA1" "$RAMA2" $(grep '^create ' "$GH_LOG" | sed 's/.*head=//'); do
    ( cd "$T/src" && git fetch -q origin "$r" 2>/dev/null \
      && git diff --name-only "origin/main...FETCH_HEAD" | grep -qx 'openclaw.json' ) \
      && fail "(2e) openclaw.json entro al PR $r"
  done
  echo "ok (2e): falta config conflicta sin commitearse"

  # (2f) Protect-LogToken: una linea, <=200, sin controles.
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "
Import-Module '$MODN' -Force
\$maldita = 'a/b' + [char]10 + 'SKILLS_PR 9' + [char]13 + ('x' * 300)
\$sana = Protect-LogToken -Text \$maldita
if (\$sana -match '[\r\n]') { Write-Output 'TOK-FAIL: controles'; exit 1 }
if (\$sana.Length -gt 200) { Write-Output 'TOK-FAIL: largo'; exit 1 }
if (-not \$sana.StartsWith('a/b ')) { Write-Output 'TOK-FAIL: prefijo'; exit 1 }
Write-Output 'TOK-OK'
" >"$T/tok.out" 2>&1 || fail "(2f) sanitize: $(cat "$T/tok.out")"
  grep -q 'TOK-OK' "$T/tok.out" || fail "(2f) sin confirmacion"
  echo "ok (2f): Protect-LogToken aplana y acota"
  kill $GW_PID 2>/dev/null || true
else
  echo "SKIP (2): sin motor PowerShell; windows-contract cubre el humo de proteccion"
fi

# (3) windows-contract corre ESTE test (pin de cobertura propia).
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-protected-paths.sh' \
  || fail "(3) windows-contract no corre test-protected-paths.sh"
echo "ok (3): windows-contract cubre este test"

echo "TODO VERDE: protected-paths"
