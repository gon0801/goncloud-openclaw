#!/bin/bash
# Contrato del ledger de PRs de skills (Task 3 / 16.3, Step 2).
#
# El ledger registra por ruta: hash vivo, hash capturado, rama, commit, PR y
# estado. Mismo hash = sin duplicado; edicion nueva + PR escribible = misma
# rama; rama cerrada = sucesor enlazado; merge + hashes de acuerdo = deploy;
# cerrado-sin-merge = protegido + conflicto. El gh de estos escenarios es un
# stub con estado (contrato en .saikit/scratch/M/tdd.md); el git es real
# contra remotos bare locales.
#
# Uso: bash scripts/tests/test-skills-pr-ledger.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
SCHEMA=scripts/runtime-separation/skills-pr-ledger.v1.schema.json
RECIBO=docs/spec/runtime-separation-receipt.v1.schema.json
ORQ=scripts/runtime-separation/Sync-OpenClawRuntime.ps1
YAML=.github/workflows/quality.yml
PUERTO_FAKE=18798

for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

# (0) El schema existe y fija las cuatro claves.
[ -f "$SCHEMA" ] || fail "(0) falta $SCHEMA"
PYBIN=$(command -v python3 || command -v python) || fail "(0) sin python3 ni python en PATH"
"$PYBIN" - "$SCHEMA" <<'PY' || exit 1
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
assert s.get("schema") == "skills-pr-ledger.v1", "ROJO: (0) schema distinto"
assert set(s.get("required", [])) == {"schema", "updatedUtc", "entries", "tombstones"}, \
    "ROJO: (0) required[] distinto"
assert s.get("additionalProperties") is False, "ROJO: (0) ledger no cerrado"
PY
echo "ok (0): schema de ledger v1 cerrado"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# --- espejo portable del validador de ledger ---
cat >"$T/valida-ledger.py" <<'PY'
import json, re, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
rec = json.load(open(sys.argv[2], encoding="utf-8"))
rx_val = re.compile(rec["x-secretValuePattern"])
UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")
H64 = re.compile(r"^[0-9a-f]{64}$")
H40 = re.compile(r"^[0-9a-f]{40}$")
RAMA = re.compile(r"^auto/skills/\d{8}T\d{6}Z-[A-Za-z0-9_.-]+$")
SKILL = re.compile(r"^agents/[A-Za-z0-9_.-]+/agent/workshop-skills/\S+$")
bad = []
if set(doc) != {"schema", "updatedUtc", "entries", "tombstones"}:
    bad.append("claves superiores exactas")
if doc.get("schema") != "skills-pr-ledger.v1":
    bad.append("schema")
if not isinstance(doc.get("updatedUtc"), str) or not UTC.match(doc["updatedUtc"]):
    bad.append("updatedUtc")
for rel, e in (doc.get("entries") or {}).items():
    if not SKILL.match(rel) or re.search(r"[\x00-\x1f\x7f]", rel):
        bad.append(f"entry path fuera de skills: {rel}")
        continue
    if set(e) != {"liveHash", "capturedHash", "branch", "commit", "pr", "status", "previousPr", "updatedUtc"}:
        bad.append(f"entry {rel}: claves"); continue
    if not H64.match(e["liveHash"] or "") or not H64.match(e["capturedHash"] or ""):
        bad.append(f"entry {rel}: hashes")
    if not RAMA.match(e["branch"] or ""):
        bad.append(f"entry {rel}: rama")
    if not H40.match(e["commit"] or ""):
        bad.append(f"entry {rel}: commit")
    if not isinstance(e["pr"], int) or e["pr"] < 0 or not isinstance(e["previousPr"], int) or e["previousPr"] < 0:
        bad.append(f"entry {rel}: pr/previousPr")
    if e["status"] not in ("open", "merged", "closed-unmerged", "deployed"):
        bad.append(f"entry {rel}: status")
    if not UTC.match(e["updatedUtc"] or ""):
        bad.append(f"entry {rel}: updatedUtc")
for rel, t in (doc.get("tombstones") or {}).items():
    ok = SKILL.match(rel) or rel in ("openclaw.json", "gateway-watchdog.ps1")
    if not ok or re.search(r"[\x00-\x1f\x7f]", rel):
        bad.append(f"tombstone path invalido: {rel}")
        continue
    if set(t) != {"reason", "createdUtc", "pr"}:
        bad.append(f"tombstone {rel}: claves"); continue
    if not isinstance(t["reason"], str) or not t["reason"] or len(t["reason"]) > 300:
        bad.append(f"tombstone {rel}: reason")
    if rx_val.search(t["reason"]):
        bad.append(f"tombstone {rel}: reason con forma de secreto")
    if not UTC.match(t["createdUtc"] or ""):
        bad.append(f"tombstone {rel}: createdUtc")
    if not isinstance(t["pr"], int) or t["pr"] < 0:
        bad.append(f"tombstone {rel}: pr")
if bad:
    print("rechazado:")
    for b in bad:
        print(f"  - {b}")
    sys.exit(1)
print("ok")
PY

buen_ledger() { # $1=destino
  cat >"$1" <<'JSON'
{"schema": "skills-pr-ledger.v1", "updatedUtc": "2026-09-22T10:00:00Z",
 "entries": {"agents/main/agent/workshop-skills/s/SKILL.md":
   {"liveHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "capturedHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "branch": "auto/skills/20260922T100000Z-main", "commit": "0123456789abcdef0123456789abcdef01234567",
    "pr": 7, "status": "open", "previousPr": 0, "updatedUtc": "2026-09-22T10:00:00Z"}},
 "tombstones": {"agents/main/agent/workshop-skills/vieja/SKILL.md":
   {"reason": "deleted-live pending pr 5", "createdUtc": "2026-09-22T09:00:00Z", "pr": 5}}}
JSON
}

# (1) El bueno pasa; cada defecto se rechaza.
buen_ledger "$T/good.json"
"$PYBIN" "$T/valida-ledger.py" "$T/good.json" "$RECIBO" >/dev/null \
  || fail "(1) el ledger bueno fue rechazado"
muta() { # $1=nombre $2=programa-python (lee good, escribe mal)
  "$PYBIN" - "$T/good.json" "$T/$1" <<PY
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
$2
json.dump(doc, open(sys.argv[2], "w", encoding="utf-8"))
PY
  "$PYBIN" "$T/valida-ledger.py" "$T/$1" "$RECIBO" >/dev/null 2>&1 \
    && fail "(1) $1 debio rechazarse y paso"
}
E='doc["entries"]["agents/main/agent/workshop-skills/s/SKILL.md"]'
muta mal-status.py "$E['status'] = 'pendiente'"
muta mal-hash.py "$E['liveHash'] = 'zzz'"
muta mal-rama.py "$E['branch'] = 'main'"
muta mal-commit.py "$E['commit'] = 'abc'"
muta mal-pr.py "$E['pr'] = -1"
muta mal-clave.py "del $E['pr']"
muta mal-extra.py "doc['otro'] = 1"
muta mal-path.py "doc['entries']['agents/main/agent.md'] = doc['entries'].pop('agents/main/agent/workshop-skills/s/SKILL.md')"
muta mal-tomb.py "doc['tombstones']['x/y.md'] = {'reason': 'r', 'createdUtc': '2026-09-22T10:00:00Z', 'pr': 0}"
muta mal-secreto.py "doc['tombstones']['agents/main/agent/workshop-skills/vieja/SKILL.md']['reason'] = 'token ghp_abcdefghijklmnopqrstuvwxyza1B2'"
echo "ok (1): ledger bueno pasa, 11 defectos rechazan"

# --- motor PowerShell ---
en_windows=0
[ "${OS:-}" = "Windows_NT" ] && en_windows=1
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) en_windows=1;; esac
PSH="$(command -v powershell.exe || command -v powershell || command -v pwsh || true)"
if [ "$en_windows" -eq 1 ] && [ -z "$PSH" ]; then
  fail "(2) en Windows powershell.exe debe existir"
fi

if [ -n "$PSH" ]; then
  [ -f "$ORQ" ] || fail "(2) falta $ORQ"
  nat() {
    if [ "$en_windows" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then
      cygpath -w "$1"
    else
      case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$PWD" "$1";; esac
    fi
  }
  ORQN=$(nat "$ORQ")

  # gh stub con estado (contrato fijo).
  mkdir -p "$T/fake-bin"
  export GH_LOG="$T/gh.log" GH_CTR="$T/gh-ctr" GH_STATE="$T/gh-state.json"
  echo 1 >"$GH_CTR"; echo '{}' >"$GH_STATE"; : >"$GH_LOG"
  cat >"$T/fake-bin/gh-stub.py" <<'PY'
import json, os, re, sys
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
    out = [{"number": int(k), **v} for k, v in st.items() if v.get("headRefName") == h]
    print(json.dumps(out))
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

  # Gateway falso (el deploy del escenario merge lo necesita).
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

  semilla() {
    git init -q -b main --bare "$T/origin.git" || return 1
    W="$T/w"; rm -rf "$W"; git clone -q "$T/origin.git" "$W" 2>/dev/null || return 1
    ( cd "$W" && git checkout -q -b main \
      && mkdir -p agents/main/agent/workshop-skills/s \
      && printf 'v1\n' > agents/main/agent/workshop-skills/s/SKILL.md \
      && printf '# agente\n' > agents/main/agent.md \
      && printf '$httpTimeoutSec = 90\n' > gateway-watchdog.ps1 \
      && git add -A && git -c user.name=t -c user.email=t@t commit -qm base \
      && git push -q origin main ) || return 1
    rm -rf "$W"
  }
  semilla || fail "(2) semilla"
  git clone -q "$T/origin.git" "$T/src" 2>/dev/null || fail "(2) clone src"
  ( cd "$T/src" && git config user.name t && git config user.email t@t ) || fail "(2) identidad"
  mkdir -p "$T/rt/agents/main/agent/workshop-skills/s"
  printf 'v1\n' >"$T/rt/agents/main/agent/workshop-skills/s/SKILL.md"
  printf '# agente\n' >"$T/rt/agents/main/agent.md"
  printf '$httpTimeoutSec = 90\n' >"$T/rt/gateway-watchdog.ps1"
  printf '{"ok":true}\n' >"$T/rt/openclaw.json"
  cat >"$T/man.json" <<'JSON'
{"schema": "runtime-deploy.v1", "sourceRoot": "C:\\F\\src", "runtimeRoot": "C:\\F\\rt",
 "allowed": [{"path": "gateway-watchdog.ps1", "kind": "file", "reason": "t"},
             {"path": "agents/*/agent/workshop-skills/**", "kind": "glob", "reason": "t"}],
 "denied": [{"pattern": "**/*.secret", "reason": "t"}]}
JSON
  corre() { # $1=tag
    "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ORQN" \
      -SourceRoot "$(nat "$T/src")" -RuntimeRoot "$(nat "$T/rt")" \
      -ReceiptRoot "$(nat "$T/rec")" -LedgerPath "$(nat "$T/ledger.json")" \
      -JournalPath "$(nat "$T/journal.jsonl")" -LogPath "$(nat "$T/sync.log")" \
      -ManifestPath "$(nat "$T/man.json")" -HealthUrl "http://127.0.0.1:$PUERTO_FAKE" \
      -OpenClawVersion 2026.9.5 >"$T/$1.out" 2>&1
    return $?
  }
  MAIN0=$(git --git-dir="$T/origin.git" rev-parse main)

  # (2a) Edicion viva -> un PR, ledger open, SKILLS_PR una vez.
  printf 'v2\n' >"$T/rt/agents/main/agent/workshop-skills/s/SKILL.md"
  corre a || fail "(2a) ciclo capture debio salir 0: $(cat "$T/a.out")"
  [ "$(grep -c '^create ' "$GH_LOG")" = 1 ] || fail "(2a) se esperaba 1 create: $(cat "$GH_LOG")"
  RAMA=$(grep '^create ' "$GH_LOG" | head -1 | sed 's/.*head=//')
  case "$RAMA" in auto/skills/*) ;; *) fail "(2a) rama fuera de forma: $RAMA";; esac
  DIF=$(cd "$T/src" && git fetch -q origin "$RAMA" 2>/dev/null && git diff --name-only "origin/main...FETCH_HEAD")
  [ "$DIF" = "agents/main/agent/workshop-skills/s/SKILL.md" ] \
    || fail "(2a) el PR toca fuera de skills: $DIF"
  "$PYBIN" "$T/valida-ledger.py" "$T/ledger.json" "$RECIBO" >/dev/null \
    || fail "(2a) ledger invalido tras capture"
  [ "$(grep -c 'SKILLS_PR ' "$T/sync.log")" = 1 ] \
    || fail "(2a) SKILLS_PR != 1: $(cat "$T/sync.log")"
  grep -q 'SKILLS_PR 1 ' "$T/sync.log" || fail "(2a) sin numero de PR en SKILLS_PR"
  [ "$(git --git-dir="$T/origin.git" rev-parse main)" = "$MAIN0" ] \
    || fail "(2a) main del origin se movio"
  echo "ok (2a): capture crea 1 PR solo-skills, ledger open, SKILLS_PR 1"

  # (2b) Repetir sin cambios no duplica.
  corre b || fail "(2b) re-ciclo debio salir 0: $(cat "$T/b.out")"
  [ "$(grep -c '^create ' "$GH_LOG")" = 1 ] || fail "(2b) duplico PR"
  echo "ok (2b): hash repetido no duplica PR"

  # (2c) Edicion nueva + PR abierto = misma rama, UPDATE (no segundo SKILLS_PR).
  printf 'v3\n' >"$T/rt/agents/main/agent/workshop-skills/s/SKILL.md"
  corre c || fail "(2c) ciclo update debio salir 0: $(cat "$T/c.out")"
  [ "$(grep -c '^create ' "$GH_LOG")" = 1 ] || fail "(2c) abrio PR de mas"
  ( cd "$T/src" && git fetch -q origin "$RAMA" 2>/dev/null \
    && [ "$(git show "FETCH_HEAD:agents/main/agent/workshop-skills/s/SKILL.md")" = "v3" ] ) \
    || fail "(2c) la rama no trae v3"
  [ "$(grep -c 'SKILLS_PR ' "$T/sync.log")" = 1 ] || fail "(2c) SKILLS_PR repetido"
  grep -q 'SKILLS_PR_UPDATE 1 ' "$T/sync.log" || fail "(2c) sin SKILLS_PR_UPDATE 1"
  echo "ok (2c): edicion nueva actualiza la misma rama sin duplicar"

  # (2d-neg) Merge declarado pero vivo se movio: sucesor, sin deploy.
  HEAD1=$(cd "$T/src" && git fetch -q origin "$RAMA" 2>/dev/null && git rev-parse FETCH_HEAD)
  "$PYBIN" - "$GH_STATE" "$RAMA" "$HEAD1" <<'PY'
import json, sys
st = {1: {"state": "MERGED", "mergedAt": "2026-09-22T11:00:00Z",
          "headRefOid": sys.argv[3], "headRefName": sys.argv[2]}}
json.dump(st, open(sys.argv[1], "w"))
PY
  printf 'v4\n' >"$T/rt/agents/main/agent/workshop-skills/s/SKILL.md"
  corre dneg || fail "(2d-neg) ciclo sucesor debio salir 0: $(cat "$T/dneg.out")"
  [ "$(grep -c '^create ' "$GH_LOG")" = 2 ] || fail "(2d-neg) sin PR sucesor"
  grep -q 'SKILLS_DEPLOYED' "$T/sync.log" && fail "(2d-neg) deployo con vivo movido"
  "$PYBIN" - "$T/ledger.json" <<'PY' || fail "(2d-neg) sin previousPr=1"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]["agents/main/agent/workshop-skills/s/SKILL.md"]
assert e["previousPr"] == 1 and e["pr"] == 2, e
PY
  echo "ok (2d-neg): vivo movido abre sucesor enlazado sin deployar"

  # (2d) Merge real + hashes de acuerdo: deploya, SKILLS_DEPLOYED, deployed.
  RAMA2=$(grep '^create ' "$GH_LOG" | tail -1 | sed 's/.*head=//')
  W="$T/w"; git clone -q "$T/origin.git" "$W" 2>/dev/null \
    && ( cd "$W" && git checkout -q main && git fetch -q origin "$RAMA2" \
      && git -c user.name=t -c user.email=t@t merge -q --no-ff FETCH_HEAD -m "merge pr2" \
      && git push -q origin main ) || fail "(2d) merge fixture"
  rm -rf "$W"
  HEAD2=$(cd "$T/src" && git ls-remote "$T/origin.git" main | cut -f1)
  BHEAD2=$(cd "$T/src" && git ls-remote "$T/origin.git" "$RAMA2" | cut -f1)
  "$PYBIN" - "$GH_STATE" "$RAMA" "$HEAD1" "$RAMA2" "$BHEAD2" <<'PY'
import json, sys
st = {1: {"state": "MERGED", "mergedAt": "2026-09-22T11:00:00Z", "headRefOid": sys.argv[3], "headRefName": sys.argv[2]},
      2: {"state": "MERGED", "mergedAt": "2026-09-22T12:00:00Z", "headRefOid": sys.argv[5], "headRefName": sys.argv[4]}}
json.dump(st, open(sys.argv[1], "w"))
PY
  NREC_D0=$(ls "$T/rec/"*.json 2>/dev/null | wc -l | tr -d ' ')
  corre d || fail "(2d) ciclo deploy debio salir 0: $(cat "$T/d.out")"
  grep -q "SKILLS_DEPLOYED $HEAD2 " "$T/sync.log" \
    || fail "(2d) sin SKILLS_DEPLOYED con sha mergeado: $(cat "$T/sync.log")"
  [ "$(cat "$T/rt/agents/main/agent/workshop-skills/s/SKILL.md")" = "v4" ] \
    || fail "(2d) runtime sin v4"
  [ "$(ls "$T/rec/"*.json 2>/dev/null | wc -l | tr -d ' ')" -gt "$NREC_D0" ] \
    || fail "(2d) sin recibo nuevo de deploy"
  "$PYBIN" - "$T/ledger.json" <<'PY' || fail "(2d) entry no deployed"
import json, sys
e = json.load(open(sys.argv[1]))["entries"]["agents/main/agent/workshop-skills/s/SKILL.md"]
assert e["status"] == "deployed", e
PY
  echo "ok (2d): merge + acuerdo deploya y marca deployed"

  # (2e) Cerrado-sin-merge: protegido + conflicto, bytes vivos intactos.
  mkdir -p "$T/rt/agents/main/agent/workshop-skills/t"
  printf 't1\n' >"$T/rt/agents/main/agent/workshop-skills/t/SKILL.md"
  corre e1 || fail "(2e) capture t debio salir 0: $(cat "$T/e1.out")"
  "$PYBIN" - "$GH_STATE" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
st["3"] = {"state": "CLOSED", "mergedAt": None, "headRefOid": "0" * 40, "headRefName": "auto/skills/x"}
json.dump(st, open(sys.argv[1], "w"))
PY
  W="$T/w"; git clone -q "$T/origin.git" "$W" 2>/dev/null \
    && ( cd "$W" && git checkout -q main && printf '# agente v2\n' > agents/main/agent.md \
      && git -c user.name=t -c user.email=t@t commit -qam bump && git push -q origin main ) \
    || fail "(2e) avance ajeno"
  rm -rf "$W"
  NREC_ANTES=$(ls "$T/rec/"*.json 2>/dev/null | wc -l | tr -d ' ')
  corre e2 || fail "(2e) ciclo cerrado debio salir 0: $(cat "$T/e2.out")"
  grep -q 'CONFLICTO' "$T/sync.log" || fail "(2e) sin CONFLICTO"
  [ "$(cat "$T/rt/agents/main/agent/workshop-skills/t/SKILL.md")" = "t1" ] \
    || fail "(2e) bytes vivos de t alterados"
  [ "$(ls "$T/rec/"*.json 2>/dev/null | wc -l | tr -d ' ')" = "$NREC_ANTES" ] \
    || fail "(2e) deployo con PR cerrado"
  "$PYBIN" "$T/valida-ledger.py" "$T/ledger.json" "$RECIBO" >/dev/null \
    || fail "(2e) ledger invalido al final"
  echo "ok (2e): cerrado-sin-merge protege, conflicta y preserva"
  kill $GW_PID 2>/dev/null || true
else
  echo "SKIP (2): sin motor PowerShell; windows-contract cubre el humo de ledger"
fi

# (3) windows-contract corre ESTE test (pin de cobertura propia).
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-skills-pr-ledger.sh' \
  || fail "(3) windows-contract no corre test-skills-pr-ledger.sh"
echo "ok (3): windows-contract cubre este test"

echo "TODO VERDE: skills-pr-ledger"
