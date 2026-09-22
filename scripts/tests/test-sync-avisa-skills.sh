#!/usr/bin/env bash
# El sync avisa captures pendientes, no commits (Fase 16.3).
#
# Antes (13.2a): commitear skills locales escribia `SKILLS <agente> N
# archivo(s)`. Ahora el repo main no commitea en vivo: captura a un PR y
# escribe `SKILLS_PR <pr>`, y tras merge+deploy `SKILLS_DEPLOYED <sha>`.
# Este test rechaza el texto anterior cuando el PR sigue abierto (diseno,
# "Contrato del log y del vigia") y exige los tokens nuevos. El helper
# viejo se elimino con su camino; ParseFile sigue cuidando el .ps1.
#
# Uso: bash scripts/tests/test-sync-avisa-skills.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }

PS1FILE=scripts/sync-repos.ps1
ORQ=scripts/runtime-separation/Sync-OpenClawRuntime.ps1
YAML=.github/workflows/quality.yml
[ -f "$PS1FILE" ] || fail "falta $PS1FILE"

for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

PWSH="${PWSH:-}"
if [ -z "$PWSH" ]; then
  for c in /Users/dn/.local/bin/pwsh "$(command -v pwsh 2>/dev/null)" /usr/bin/pwsh; do
    [ -n "$c" ] && [ -x "$c" ] && PWSH=$c && break
  done
fi

# (0) El flujo viejo murio: sin helper, sin marcas, sin formato anterior.
grep -q 'Get-OpenclawSkillsCambiadasStaged' "$PS1FILE" \
  && fail "(0) el helper de SKILLS sigue en $PS1FILE (codigo muerto)"
grep -q 'skills-cambiadas' "$PS1FILE" \
  && fail "(0) las marcas skills-cambiadas siguen en $PS1FILE"
grep -q 'SKILLS {1} {2} archivo(s)' "$PS1FILE" \
  && fail "(0) el formato viejo SKILLS sigue en $PS1FILE"
echo "ok (0): flujo SKILLS-por-commit eliminado"

# (1) ParseFile cero errores (conservado de 13.2a).
if [ -n "${PWSH:-}" ] && [ -x "$PWSH" ]; then
  "$PWSH" -NoProfile -Command "
\$e=\$null; \$t=\$null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '$PS1FILE'), [ref]\$t, [ref]\$e)
if (\$e -and \$e.Count -gt 0) { \$e | ForEach-Object { \$_.ToString() }; exit 1 }
exit 0
" || fail "(1) ParseFile reporto errores en $PS1FILE"
  echo "ok (1): ParseFile sin errores"
else
  echo "SKIP (1): sin pwsh; windows-contract cubre ParseFile"
fi

# --- comportamiento: PR abierto = SKILLS_PR y nada del texto viejo ---
en_windows=0
[ "${OS:-}" = "Windows_NT" ] && en_windows=1
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) en_windows=1;; esac
PSH="$(command -v powershell.exe || command -v powershell || command -v pwsh || true)"
if [ "$en_windows" -eq 1 ] && [ -z "$PSH" ]; then
  fail "(2) en Windows powershell.exe debe existir"
fi
PYBIN=$(command -v python3 || command -v python) || fail "(2) sin python3 ni python en PATH"

if [ -n "$PSH" ]; then
  [ -f "$ORQ" ] || fail "(2) falta $ORQ"
  T=$(mktemp -d) || exit 1
  trap 'rm -rf "$T"' EXIT
  nat() {
    if [ "$en_windows" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then
      cygpath -w "$1"
    else
      case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$PWD" "$1";; esac
    fi
  }
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

  git init -q --bare "$T/origin.git" || fail "(2) bare"
  W="$T/w"; git clone -q "$T/origin.git" "$W" 2>/dev/null || fail "(2) seed"
  ( cd "$W" && git checkout -q -b main \
    && mkdir -p agents/main/agent/workshop-skills/s \
    && printf 'v1\n' > agents/main/agent/workshop-skills/s/SKILL.md \
    && git add -A && git -c user.name=t -c user.email=t@t commit -qm base \
    && git push -q origin main ) || fail "(2) seed"
  rm -rf "$W"
  git clone -q "$T/origin.git" "$T/src" 2>/dev/null || fail "(2) clone"
  ( cd "$T/src" && git config user.name t && git config user.email t@t ) || fail "(2) id"
  mkdir -p "$T/rt/agents/main/agent/workshop-skills/s"
  printf 'v2\n' >"$T/rt/agents/main/agent/workshop-skills/s/SKILL.md"
  printf '{"ok":true}\n' >"$T/rt/openclaw.json"
  printf '$httpTimeoutSec = 90\n' >"$T/rt/gateway-watchdog.ps1"
  cat >"$T/man.json" <<'JSON'
{"schema": "runtime-deploy.v1", "sourceRoot": "C:\\F\\src", "runtimeRoot": "C:\\F\\rt",
 "allowed": [{"path": "gateway-watchdog.ps1", "kind": "file", "reason": "t"},
             {"path": "agents/*/agent/workshop-skills/**", "kind": "glob", "reason": "t"}],
 "denied": [{"pattern": "**/*.secret", "reason": "t"}]}
JSON
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(nat "$ORQ")" \
    -SourceRoot "$(nat "$T/src")" -RuntimeRoot "$(nat "$T/rt")" \
    -ReceiptRoot "$(nat "$T/rec")" -LedgerPath "$(nat "$T/ledger.json")" \
    -JournalPath "$(nat "$T/journal.jsonl")" -LogPath "$(nat "$T/sync.log")" \
    -ManifestPath "$(nat "$T/man.json")" -OpenClawVersion 2026.9.5 \
    >"$T/run.out" 2>&1 || fail "(2) ciclo capture fallo: $(cat "$T/run.out")"
  grep -q 'SKILLS_PR 1 ' "$T/sync.log" || fail "(2) sin SKILLS_PR 1"
  grep -Eq 'SKILLS [A-Za-z]+ [0-9]+ archivo\(s\)' "$T/sync.log" \
    && fail "(2) texto viejo SKILLS con PR abierto: $(grep -Eo 'SKILLS [A-Za-z]+ [0-9]+ archivo\(s\)' "$T/sync.log")"
  echo "ok (2): PR abierto emite SKILLS_PR y jamas el texto viejo"
else
  echo "SKIP (2): sin motor PowerShell; windows-contract cubre tokens"
fi

# (3) windows-contract corre ESTE test (pin de cobertura propia).
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-sync-avisa-skills.sh' \
  || fail "(3) windows-contract no corre test-sync-avisa-skills.sh"
echo "ok (3): windows-contract cubre este test"

echo "TODO VERDE: sync-avisa-skills"
