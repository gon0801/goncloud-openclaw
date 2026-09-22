#!/bin/bash
# Contrato del checkout fuente dedicado (Task 3 / 16.3, Step 1).
#
# El checkout en src/ termina en main, exactamente en origin/main, limpio y
# sin commits locales. Sucio o adelantado = alto sin mutar. Solo
# agents/*/agent/workshop-skills/** entra a worktrees/ramas/PRs temporales;
# main jamas se empuja. El runtime (.openclaw) no es repo: el orquestador
# nunca corre git dentro de el (los fixtures lo prueban: runtime sin .git).
#
# Uso: bash scripts/tests/test-source-checkout.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
ORQ=scripts/runtime-separation/Sync-OpenClawRuntime.ps1
YAML=.github/workflows/quality.yml

# Higiene de entorno git (heredada de test-sync-pull-identity.sh).
for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

# (0) El orquestador existe.
[ -f "$ORQ" ] || fail "(0) falta $ORQ"
echo "ok (0): el orquestador existe"

# (1) Anclas: main nunca se empuja, captura solo-skills, sin atajos sucios.
while IFS= read -r linea; do
  case "$linea" in *main*) fail "(1) linea de push menciona main: $linea";; esac
done < <(grep -n 'git push' "$ORQ" | cut -d: -f2-)
[ -n "$(grep -n 'git push' "$ORQ")" ] || fail "(1) sin lineas git push (el capture empuja ramas)"
grep -q "auto/skills/" "$ORQ" || fail "(1) sin ramas auto/skills/"
grep -q 'worktree add' "$ORQ" || fail "(1) sin worktree temporal"
grep -q 'origin/main' "$ORQ" || fail "(1) sin base origin/main"
grep -q 'workshop-skills' "$ORQ" || fail "(1) sin filtro workshop-skills"
grep -q '\-c user\.name=' "$ORQ" || fail "(1) commits sin identidad inline"
grep -q 'add -A' "$ORQ" && fail "(1) trae git add -A: la captura usa rutas explicitas"
grep -q 'reset --hard' "$ORQ" && fail "(1) trae reset --hard"
grep -q 'stash' "$ORQ" && fail "(1) trae stash"
echo "ok (1): push solo-ramas, captura solo-skills, sin add -A/reset/stash"

# --- motor PowerShell: obligatorio en Windows, oportunista fuera ---
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
  ORQN=$(nat "$ORQ")

  # gh que falla fuerte si lo llaman: en estos escenarios no hay capturas.
  mkdir -p "$T/fake-bin"
  printf '#!/bin/bash\necho "gh llamado sin captura pendiente" >&2\nexit 99\n' >"$T/fake-bin/gh"
  chmod +x "$T/fake-bin/gh"
  printf '@echo gh llamado sin captura pendiente 1>&2\r\n@exit 99\r\n' >"$T/fake-bin/gh.cmd"
  export PATH="$T/fake-bin:$PATH"

  semilla() { # $1=origin-bare: crea origin con main + skill v1 + agent.md
    git init -q -b main --bare "$1" || return 1
    W="$T/w"; rm -rf "$W"; git clone -q "$1" "$W" 2>/dev/null || return 1
    ( cd "$W" && git checkout -q -b main \
      && mkdir -p agents/main/agent/workshop-skills/s \
      && printf 'v1\n' > agents/main/agent/workshop-skills/s/SKILL.md \
      && printf '# agente\n' > agents/main/agent.md \
      && git add -A && git -c user.name=t -c user.email=t@t commit -qm base \
      && git push -q origin main ) || return 1
    rm -rf "$W"
  }
  clona() { # $1=origin $2=destino
    git clone -q "$1" "$2" 2>/dev/null || return 1
    ( cd "$2" && git config user.name t && git config user.email t@t ) || return 1
  }
  runtime_conv() { # $1=dir: runtime convergente (sin .git a proposito)
    mkdir -p "$1/agents/main/agent/workshop-skills/s"
    printf 'v1\n' >"$1/agents/main/agent/workshop-skills/s/SKILL.md"
    printf '# agente\n' >"$1/agents/main/agent.md"
    printf '{"ok":true}\n' >"$1/openclaw.json"
    printf '$httpTimeoutSec = 90\n' >"$1/gateway-watchdog.ps1"
  }
  manifiesto() { # $1=destino
    cat >"$1" <<'JSON'
{"schema": "runtime-deploy.v1", "sourceRoot": "C:\\F\\src", "runtimeRoot": "C:\\F\\rt",
 "allowed": [{"path": "gateway-watchdog.ps1", "kind": "file", "reason": "t"},
             {"path": "agents/*/agent/workshop-skills/**", "kind": "glob", "reason": "t"}],
 "denied": [{"pattern": "**/*.secret", "reason": "t"}]}
JSON
  }
  corre() { # $1=src $2=rt $3=tag ; resto via vars; exit en $?
    "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ORQN" \
      -SourceRoot "$(nat "$1")" -RuntimeRoot "$(nat "$2")" \
      -ReceiptRoot "$(nat "$T/$3-rec")" -LedgerPath "$(nat "$T/$3-ledger.json")" \
      -JournalPath "$(nat "$T/$3-journal.jsonl")" -LogPath "$(nat "$T/$3.log")" \
      -ManifestPath "$(nat "$T/man.json")" >"$T/$3.out" 2>&1
    return $?
  }
  manifiesto "$T/man.json"

  semilla "$T/origin.git" || fail "(2) no pude sembrar origin"

  # (2a) Atrasado converge: termina en main, en origin/main, limpio, sin locales.
  clona "$T/origin.git" "$T/a-src" || fail "(2a) clone"
  ( cd "$T/a-src" && git checkout -q -b tmp-x && git checkout -q main ) || fail "(2a) ramas"
  W="$T/w"; git clone -q "$T/origin.git" "$W" 2>/dev/null \
    && ( cd "$W" && git checkout -q main && printf 'v2\n' > agents/main/agent/workshop-skills/s/SKILL.md \
      && git -c user.name=t -c user.email=t@t commit -qam v2 && git push -q origin main ) \
    || fail "(2a) avance de origin"
  rm -rf "$W"
  MAIN1=$(git --git-dir="$T/origin.git" rev-parse main)
  runtime_conv "$T/a-rt"
  printf 'v2\n' >"$T/a-rt/agents/main/agent/workshop-skills/s/SKILL.md"
  corre "$T/a-src" "$T/a-rt" a || fail "(2a) ciclo convergente debio salir 0: $(cat "$T/a.out")"
  [ "$(cd "$T/a-src" && git branch --show-current)" = main ] || fail "(2a) no termino en main"
  [ "$(cd "$T/a-src" && git rev-parse HEAD)" = "$(cd "$T/a-src" && git rev-parse origin/main)" ] \
    || fail "(2a) HEAD distinto de origin/main"
  [ -z "$(cd "$T/a-src" && git status --porcelain)" ] || fail "(2a) arbol sucio al terminar"
  [ "$(cd "$T/a-src" && git rev-list --count origin/main..HEAD)" = 0 ] \
    || fail "(2a) quedaron commits locales"
  echo "ok (2a): atrasado converge a main@origin/main limpio y sin locales"

  # (2b) Sucio = alto sin mutar.
  clona "$T/origin.git" "$T/b-src" || fail "(2b) clone"
  runtime_conv "$T/b-rt"
  printf 'sucio-local\n' >>"$T/b-src/agents/main/agent.md"
  [ -n "$(cd "$T/b-src" && git status --porcelain)" ] \
    || fail "(2b) fixture no quedo sucio (HEAD colgante?)"
  SHA_B=$(cd "$T/b-src" && git rev-parse HEAD)
  if corre "$T/b-src" "$T/b-rt" b; then fail "(2b) fuente sucia debio fallar y salio 0"; fi
  grep -q 'sucio-local' "$T/b-src/agents/main/agent.md" || fail "(2b) el alto altero bytes sucios"
  [ "$(cd "$T/b-src" && git rev-parse HEAD)" = "$SHA_B" ] || fail "(2b) el alto movio HEAD"
  echo "ok (2b): sucio frena sin mutar bytes ni refs"

  # (2c) Adelantado = alto; el commit local sobrevive.
  clona "$T/origin.git" "$T/c-src" || fail "(2c) clone"
  runtime_conv "$T/c-rt"
  ( cd "$T/c-src" && printf 'x\n' > agents/main/agent/workshop-skills/s/LOCAL.md \
    && git add agents/main/agent/workshop-skills/s/LOCAL.md \
    && git -c user.name=t -c user.email=t@t commit -qm local ) || fail "(2c) commit local"
  if corre "$T/c-src" "$T/c-rt" c; then fail "(2c) fuente adelantada debio fallar y salio 0"; fi
  [ "$(cd "$T/c-src" && git rev-list --count origin/main..HEAD)" = 1 ] \
    || fail "(2c) el alto perdio el commit local"
  echo "ok (2c): adelantado frena y preserva el commit local"

  # (2d) Rama ajena limpia converge a main; sucia frena en su rama.
  clona "$T/origin.git" "$T/d-src" || fail "(2d) clone"
  runtime_conv "$T/d-rt"
  ( cd "$T/d-src" && git checkout -q -b feature-x ) || fail "(2d) branch"
  corre "$T/d-src" "$T/d-rt" d || fail "(2d) rama limpia debio converger: $(cat "$T/d.out")"
  [ "$(cd "$T/d-src" && git branch --show-current)" = main ] || fail "(2d) no volvio a main"
  clona "$T/origin.git" "$T/e-src" || fail "(2d) clone2"
  runtime_conv "$T/e-rt"
  ( cd "$T/e-src" && git checkout -q -b feature-y && printf 's\n' >> agents/main/agent.md ) \
    || fail "(2d) branch2"
  if corre "$T/e-src" "$T/e-rt" e; then fail "(2d) rama sucia debio fallar y salio 0"; fi
  [ "$(cd "$T/e-src" && git branch --show-current)" = feature-y ] \
    || fail "(2d) el alto cambio de rama"
  echo "ok (2d): rama limpia converge, rama sucia frena en su sitio"

  # (2e) main del origin intacto tras los ciclos (nadie lo empuja).
  [ "$(git --git-dir="$T/origin.git" rev-parse main)" = "$MAIN1" ] \
    || fail "(2e) un ciclo movio main del origin"
  echo "ok (2e): main del origin intacto"
else
  echo "SKIP (2): sin motor PowerShell; windows-contract cubre el humo de checkout"
fi

# (3) windows-contract corre ESTE test (pin de cobertura propia).
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-source-checkout.sh' \
  || fail "(3) windows-contract no corre test-source-checkout.sh"
echo "ok (3): windows-contract cubre este test"

echo "TODO VERDE: source-checkout"
