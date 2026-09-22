#!/bin/bash
# Contrato de idempotencia del ciclo (Task 3 / 16.3, Step 3).
#
# Dos ciclos sin cambios no alteran archivos ni PRs: sin commits nuevos,
# sin creates en gh, sin recibos, sin ledger ni journal, bytes vivos
# identicos. Solo crecen las lineas de log del ciclo. (El fetch mueve
# FETCH_HEAD dentro de .git: metadata esperada, no estado.)
#
# Uso: bash scripts/tests/test-sync-idempotent.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
ORQ=scripts/runtime-separation/Sync-OpenClawRuntime.ps1
YAML=.github/workflows/quality.yml

for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

# (0) El orquestador existe y nombra el ciclo sin cambios.
[ -f "$ORQ" ] || fail "(0) falta $ORQ"
grep -qi 'sin cambios' "$ORQ" || fail "(0) sin ruta de ciclo sin cambios"
echo "ok (0): ciclo sin cambios anclado"

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
  export PATH="$T/fake-bin:$PATH"

  git init -q --bare "$T/origin.git" || fail "(1) bare"
  W="$T/w"; git clone -q "$T/origin.git" "$W" 2>/dev/null || fail "(1) seed"
  ( cd "$W" && git checkout -q -b main \
    && mkdir -p agents/main/agent/workshop-skills/s \
    && printf 'v1\n' > agents/main/agent/workshop-skills/s/SKILL.md \
    && printf '# agente\n' > agents/main/agent.md \
    && printf '$httpTimeoutSec = 90\n' > gateway-watchdog.ps1 \
    && git add -A && git -c user.name=t -c user.email=t@t commit -qm base \
    && git push -q origin main ) || fail "(1) seed"
  rm -rf "$W"
  git clone -q "$T/origin.git" "$T/src" 2>/dev/null || fail "(1) clone"
  ( cd "$T/src" && git config user.name t && git config user.email t@t ) || fail "(1) id"
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
  corre() {
    "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ORQN" \
      -SourceRoot "$(nat "$T/src")" -RuntimeRoot "$(nat "$T/rt")" \
      -ReceiptRoot "$(nat "$T/rec")" -LedgerPath "$(nat "$T/ledger.json")" \
      -JournalPath "$(nat "$T/journal.jsonl")" -LogPath "$(nat "$T/sync.log")" \
      -ManifestPath "$(nat "$T/man.json")" >"$T/$1.out" 2>&1
    return $?
  }
  arbol_hash() { # hash estable del arbol vivo (rutas + bytes)
    ( cd "$1" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 2>/dev/null \
      || ( cd "$1" && find . -type f | LC_ALL=C sort | xargs sha256sum ) )
  }

  HASH0=$(arbol_hash "$T/rt")
  OBJ0=$(cd "$T/src" && git rev-list --all --count)
  corre a || fail "(1) primer ciclo debio salir 0: $(cat "$T/a.out")"
  corre b || fail "(1) segundo ciclo debio salir 0: $(cat "$T/b.out")"
  [ "$(cd "$T/src" && git rev-list --all --count)" = "$OBJ0" ] \
    || fail "(1) objetos git cambiaron"
  [ -z "$(cd "$T/src" && git status --porcelain)" ] || fail "(1) fuente sucia"
  [ -s "$GH_LOG" ] && fail "(1) gh llamado: $(cat "$GH_LOG")"
  [ -e "$T/rec" ] && fail "(1) raiz de recibos creada sin cambios"
  [ -e "$T/ledger.json" ] && fail "(1) ledger creado sin nada que registrar"
  [ -e "$T/journal.jsonl" ] && fail "(1) journal tocado sin mutaciones"
  [ "$(arbol_hash "$T/rt")" = "$HASH0" ] || fail "(1) bytes vivos cambiaron"
  [ "$(grep -ci 'sin cambios' "$T/sync.log")" = 2 ] \
    || fail "(1) sin 2 lineas de ciclo sin cambios: $(cat "$T/sync.log")"
  echo "ok (1): dos ciclos sin cambios no alteran nada (solo log)"
else
  echo "SKIP (1): sin motor PowerShell; windows-contract cubre idempotencia"
fi

# (2) windows-contract corre ESTE test (pin de cobertura propia).
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-sync-idempotent.sh' \
  || fail "(2) windows-contract no corre test-sync-idempotent.sh"
echo "ok (2): windows-contract cubre este test"

echo "TODO VERDE: sync-idempotent"
