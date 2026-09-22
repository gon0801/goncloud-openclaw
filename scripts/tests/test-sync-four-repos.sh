#!/bin/bash
# Contrato de ciclo de cuatro repos (Task 3 / 16.3, Step 3).
#
# sync-repos.ps1 conserva el loop de cuatro repos pero delega main al
# orquestador; los workspaces conservan su conducta. Un fallo en main no
# salta workspaces: registra cuatro outcomes, escribe `---- ciclo terminado`
# y sale distinto de cero. Misma regla si el mutex esta ocupado.
#
# Uso: bash scripts/tests/test-sync-four-repos.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
SYNC=scripts/sync-repos.ps1
ORQ=scripts/runtime-separation/Sync-OpenClawRuntime.ps1
YAML=.github/workflows/quality.yml

for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

# (0) Ambos scripts existen y main delega.
[ -f "$SYNC" ] || fail "(0) falta $SYNC"
[ -f "$ORQ" ] || fail "(0) falta $ORQ"
grep -q 'Sync-OpenClawRuntime.ps1' "$SYNC" || fail "(0) sync no delega main al orquestador"
grep -q '# >>> main-delegate' "$SYNC" || fail "(0) sin marcas main-delegate"
grep -q '# >>> workspace-sync' "$SYNC" || fail "(0) sin marcas workspace-sync"
grep -q 'SYNC-REPO ' "$SYNC" || fail "(0) sin outcomes por repo"
grep -q -- '---- ciclo terminado' "$SYNC" || fail "(0) sin marcador final"
echo "ok (0): loop de cuatro con delegacion y outcomes"

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
  SYNCN=$(nat "$SYNC")

  # gh fail-loud: estos escenarios no capturan.
  mkdir -p "$T/fake-bin"
  printf '#!/bin/bash\necho "gh inesperado" >&2\nexit 99\n' >"$T/fake-bin/gh"
  chmod +x "$T/fake-bin/gh"
  printf '@echo gh inesperado 1>&2\r\n@exit 99\r\n' >"$T/fake-bin/gh.cmd"
  export PATH="$T/fake-bin:$PATH"

  semilla_ws() { # $1=bare $2=nombre
    git init -q -b main --bare "$1" || return 1
    W="$T/w"; rm -rf "$W"; git clone -q "$1" "$W" 2>/dev/null || return 1
    ( cd "$W" && git checkout -q -b main && printf 'ws1\n' > NOTAS.md \
      && git add -A && git -c user.name=t -c user.email=t@t commit -qm base \
      && git push -q origin main ) || return 1
    rm -rf "$W"
  }
  semilla_main() {
    git init -q -b main --bare "$T/m-origin.git" || return 1
    W="$T/w"; rm -rf "$W"; git clone -q "$T/m-origin.git" "$W" 2>/dev/null || return 1
    ( cd "$W" && git checkout -q -b main \
      && mkdir -p agents/main/agent/workshop-skills/s \
      && printf 'v1\n' > agents/main/agent/workshop-skills/s/SKILL.md \
      && git add -A && git -c user.name=t -c user.email=t@t commit -qm base \
      && git push -q origin main ) || return 1
    rm -rf "$W"
  }
  semilla_main || fail "(1) semilla main"
  for w in workspace workspace-ingenieria workspace-operaciones; do
    semilla_ws "$T/$w.git" "$w" || fail "(1) semilla $w"
  done
  git clone -q "$T/m-origin.git" "$T/src" 2>/dev/null || fail "(1) clone src"
  ( cd "$T/src" && git config user.name t && git config user.email t@t ) || fail "(1) id src"
  mkdir -p "$T/rt/agents/main/agent/workshop-skills/s"
  printf 'v1\n' >"$T/rt/agents/main/agent/workshop-skills/s/SKILL.md"
  printf '{"ok":true}\n' >"$T/rt/openclaw.json"
  printf '$httpTimeoutSec = 90\n' >"$T/rt/gateway-watchdog.ps1"
  for w in workspace workspace-ingenieria workspace-operaciones; do
    mkdir -p "$T/rt/$w"
    git clone -q "$T/$w.git" "$T/rt/$w" 2>/dev/null || fail "(1) clone $w"
    ( cd "$T/rt/$w" && git config user.name t && git config user.email t@t ) \
      || fail "(1) id $w"
  done
  cat >"$T/man.json" <<'JSON'
{"schema": "runtime-deploy.v1", "sourceRoot": "C:\\F\\src", "runtimeRoot": "C:\\F\\rt",
 "allowed": [{"path": "gateway-watchdog.ps1", "kind": "file", "reason": "t"},
             {"path": "agents/*/agent/workshop-skills/**", "kind": "glob", "reason": "t"}],
 "denied": [{"pattern": "**/*.secret", "reason": "t"}]}
JSON
  cat >"$T/driver.ps1" <<'PS1'
param($Sync, $Log, $Src, $Rt, $Rec, $Man, $Mutex, $W1, $W2, $W3)
& $Sync -LogPath $Log -SourceRoot $Src -RuntimeRoot $Rt -ReceiptRoot $Rec `
  -ManifestPath $Man -MutexName $Mutex -WorkspaceRoots @($W1, $W2, $W3)
exit $LASTEXITCODE
PS1
  corre() { # $1=tag $2=mutex
    "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$T/driver.ps1" \
      -Sync "$SYNCN" -Log "$(nat "$T/$1.log")" -Src "$(nat "$T/src")" \
      -Rt "$(nat "$T/rt")" -Rec "$(nat "$T/rec")" -Man "$(nat "$T/man.json")" \
      -Mutex "$2" -W1 "$(nat "$T/rt/workspace")" -W2 "$(nat "$T/rt/workspace-ingenieria")" \
      -W3 "$(nat "$T/rt/workspace-operaciones")" >"$T/$1.out" 2>&1
    return $?
  }
  MUTEX_TEST="f16-test-mutex-$RANDOM"

  # (1a) Todo verde: cuatro ok, marcador, exit 0; atrasados se jalan.
  for w in workspace workspace-ingenieria workspace-operaciones; do
    W="$T/w"; git clone -q "$T/$w.git" "$W" 2>/dev/null \
      && ( cd "$W" && git checkout -q main && printf 'ws2\n' >> NOTAS.md \
        && git -c user.name=t -c user.email=t@t commit -qam v2 && git push -q origin main ) \
      || fail "(1a) avance $w"
    rm -rf "$W"
  done
  corre a "$MUTEX_TEST" || fail "(1a) ciclo verde debio salir 0: $(cat "$T/a.out")"
  [ "$(grep -c 'SYNC-REPO .* ok$' "$T/a.log")" = 4 ] \
    || fail "(1a) sin 4 outcomes ok: $(cat "$T/a.log")"
  grep -q -- '---- ciclo terminado' "$T/a.log" || fail "(1a) sin marcador final"
  for w in workspace workspace-ingenieria workspace-operaciones; do
    grep -q 'ws2' "$T/rt/$w/NOTAS.md" || fail "(1a) $w no se jalo"
  done
  echo "ok (1a): ciclo verde con 4 ok y pull de workspaces"

  # (1b) Main sucio: cuatro outcomes, workspaces procesados, exit != 0.
  printf 'sucio\n' >>"$T/src/agents/main/agent/workshop-skills/s/SKILL.md"
  for w in workspace workspace-ingenieria workspace-operaciones; do
    W="$T/w"; git clone -q "$T/$w.git" "$W" 2>/dev/null \
      && ( cd "$W" && git checkout -q main && printf 'ws3\n' >> NOTAS.md \
        && git -c user.name=t -c user.email=t@t commit -qam v3 && git push -q origin main ) \
      || fail "(1b) avance $w"
    rm -rf "$W"
  done
  if corre b "$MUTEX_TEST"; then fail "(1b) main sucio debio salir != 0"; fi
  grep -q 'SYNC-REPO main FALLO' "$T/b.log" || fail "(1b) sin outcome main FALLO"
  [ "$(grep -c 'SYNC-REPO .* ok$' "$T/b.log")" = 3 ] \
    || fail "(1b) sin 3 ok de workspaces: $(cat "$T/b.log")"
  grep -q -- '---- ciclo terminado' "$T/b.log" || fail "(1b) sin marcador final"
  for w in workspace workspace-ingenieria workspace-operaciones; do
    grep -q 'ws3' "$T/rt/$w/NOTAS.md" || fail "(1b) $w no se proceso tras fallo de main"
  done
  grep -q 'sucio' "$T/src/agents/main/agent/workshop-skills/s/SKILL.md" \
    || fail "(1b) el ciclo altero la fuente sucia"
  echo "ok (1b): fallo de main no salta workspaces; 4 outcomes y exit != 0"

  # (1c) Mutex ocupado: main FALLO(busy), workspaces ok, exit != 0.
  ( cd "$T/src" && git checkout -q -- agents/main/agent/workshop-skills/s/SKILL.md ) \
    || fail "(1c) limpieza"
  cat >"$T/holder.ps1" <<'PS1'
param($Mutex, $LedgerDir, $Signal)
if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
  $m = New-Object Threading.Mutex($false, $Mutex)
  [void]$m.WaitOne()
} else {
  if (-not (Test-Path -LiteralPath $LedgerDir)) {
    [void](New-Item -ItemType Directory -Path $LedgerDir -Force)
  }
  $fs = [IO.File]::Open((Join-Path $LedgerDir 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
}
[IO.File]::WriteAllText($Signal, 'held')
Start-Sleep -Seconds 60
PS1
  if [ "$en_windows" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then
    LEDN=$(cygpath -w "$T/rt/.ledger"); SIGN=$(cygpath -w "$T/held")
  else
    LEDN="$T/rt/.ledger"; SIGN="$T/held"
  fi
  "$PSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$T/holder.ps1" \
    -Mutex "$MUTEX_TEST" -LedgerDir "$LEDN" -Signal "$SIGN" >"$T/holder.log" 2>&1 &
  HOLDER_PID=$!
  trap 'kill $HOLDER_PID 2>/dev/null; rm -rf "$T"' EXIT
  i=0
  while [ ! -f "$T/held" ]; do
    i=$((i + 1))
    [ "$i" -lt 150 ] || { kill $HOLDER_PID 2>/dev/null; fail "(1c) el holder no adquirio"; }
    sleep 0.2
  done
  if corre c "$MUTEX_TEST"; then kill $HOLDER_PID 2>/dev/null; fail "(1c) mutex ocupado debio salir != 0"; fi
  kill $HOLDER_PID 2>/dev/null || true
  grep -q 'SYNC-REPO main FALLO' "$T/c.log" || fail "(1c) sin outcome main FALLO"
  grep -qi 'busy\|ocupado' "$T/c.log" || fail "(1c) sin motivo busy: $(cat "$T/c.log")"
  [ "$(grep -c 'SYNC-REPO .* ok$' "$T/c.log")" = 3 ] || fail "(1c) sin 3 ok"
  grep -q -- '---- ciclo terminado' "$T/c.log" || fail "(1c) sin marcador final"
  echo "ok (1c): mutex ocupado registra busy sin saltar workspaces"
else
  echo "SKIP (1): sin motor PowerShell; windows-contract cubre cuatro repos"
fi

# (2) windows-contract corre ESTE test (pin de cobertura propia).
SEC_W=$(awk '/^  windows-contract:/{f=1} f && !/^  windows-contract:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$YAML" | grep -vE '^[[:space:]]*#')
printf '%s\n' "$SEC_W" | grep -qF 'test-sync-four-repos.sh' \
  || fail "(2) windows-contract no corre test-sync-four-repos.sh"
echo "ok (2): windows-contract cubre este test"

echo "TODO VERDE: sync-four-repos"
