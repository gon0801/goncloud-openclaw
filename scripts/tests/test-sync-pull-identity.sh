#!/bin/bash
# Prueba del bug 2026-09-10/11: el sync del gateway fallaba en `git pull --rebase` con
# "Committer identity unknown" (user.name/user.email sin configurar en Windows) y el log
# solo decia CONFLICTO. Reproduce la situacion (commits de los dos lados, sin identidad
# global) y verifica: (1) el pull SIN -c falla -> (2) el pull CON la identidad inline pasa,
# (3) sync-repos.ps1 pasa la identidad en su linea de pull. Sin (1) la prueba no discrimina.
# Uso: bash scripts/tests/test-sync-pull-identity.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PS1FILE=scripts/sync-repos.ps1

# Git exporta variables locales (por ejemplo GIT_DIR/GIT_INDEX_FILE) al ejecutar hooks.
# Si llegan a los repos de prueba, sus comandos apuntan al repo padre: `checkout -b
# master` falla contra una rama ajena y `git add -A` puede contaminar su indice. Limpiar
# exactamente el conjunto que Git declara local mantiene el fixture aislado tanto al
# correrlo directo como desde pre-commit.
for git_local_var in $(git rev-parse --local-env-vars 2>/dev/null); do
  unset "$git_local_var"
done

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
# Sin identidad de ningun tipo: ni global ni de sistema (como la cuenta ehven del gateway).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
ID=(-c user.name=openclaw-auto -c user.email=ehventasmx@gmail.com)
fail() { echo "FAIL: $1"; exit 1; }

git init -q -b master --bare "$T/origin.git" || fail "init bare"
git clone -q "$T/origin.git" "$T/mac" 2>/dev/null || fail "clone mac"
( cd "$T/mac" && git checkout -q -b master && echo base > AGENTS.md && git add -A \
  && git "${ID[@]}" commit -q -m base && git push -q origin master ) || fail "seed"
git clone -q "$T/origin.git" "$T/gateway" 2>/dev/null || fail "clone gateway"
# Lado Mac: edita AGENTS.md y publica (como los PRs docs(agents)).
( cd "$T/mac" && echo regla >> AGENTS.md && git "${ID[@]}" commit -q -am "docs(agents): regla" && git push -q origin master ) || fail "mac push"
# Lado gateway: snapshot local en OTRO archivo (como memory/*.md), commit con -c igual que el script.
( cd "$T/gateway" && mkdir -p memory && echo nota > memory/2026-09-10.md && git add -A \
  && git "${ID[@]}" commit -q -m "auto: snapshot" ) || fail "gateway snapshot"

# En una Mac git se inventa una identidad con usuario@host, asi que la ausencia de config no
# basta para reproducir; user.useConfigOnly=true modela la maquina Windows del gateway, donde
# git no logra auto-detectar un mail valido ("ehven@Openclaw.(none)") y se niega a rebasar.
NOAUTO=(-c user.useConfigOnly=true)
# (1) ROJO esperado: el pull tal como estaba (sin -c identidad) debe fallar por identidad, no por conflicto.
out=$(cd "$T/gateway" && git "${NOAUTO[@]}" pull --rebase origin master 2>&1); rc=$?
if [ $rc -eq 0 ]; then fail "el pull sin identidad NO fallo: la prueba no discrimina (git $(git --version | cut -d' ' -f3))"; fi
echo "$out" | grep -qi "identity\|tell me who you are" || fail "el pull sin identidad fallo por otra cosa: $out"
( cd "$T/gateway" && git rebase --abort 2>/dev/null; git status --porcelain | grep -q . && fail "abort dejo el arbol sucio" ) ; true
echo "ok (1): sin -c falla con 'Committer identity unknown' (el CONFLICTO fantasma)"

# (2) VERDE: con la identidad inline el mismo pull pasa y deja AGENTS.md de origin + snapshot local.
out=$(cd "$T/gateway" && git "${NOAUTO[@]}" "${ID[@]}" pull --rebase origin master 2>&1) || fail "pull con -c fallo: $out"
( cd "$T/gateway" && grep -q regla AGENTS.md && [ -f memory/2026-09-10.md ] \
  && [ "$(git rev-list --count origin/master..HEAD)" = 1 ] ) || fail "estado post-rebase inesperado"
echo "ok (2): con -c el rebase pasa (AGENTS.md de origin + snapshot local encima)"

# (3) El script del gateway lleva la identidad en la linea del pull (guarda contra regresion).
grep -Eq 'git -c user\.name="[^"]+" -c user\.email="[^"]+" pull --rebase origin \$branch' "$PS1FILE" \
  || fail "$PS1FILE: la linea de pull no pasa -c user.name/user.email"
grep -q 'CONFLICTO en pull - se deja como estaba, revisar a mano: \$why' "$PS1FILE" \
  || fail "$PS1FILE: el log de CONFLICTO no incluye el motivo (\$why)"
echo "ok (3): sync-repos.ps1 pasa identidad en el pull y loguea el motivo"

# (4) Bug 2026-09-11: un repo git anidado SIN commits (workspace-scout/) hace abortar `git add -A`
# entero -> nada staged -> arbol sucio -> el pull se niega. Rojo: add -A falla y no deja nada
# staged. Verde: `git add -u` (el fallback del script) si deja los tracked modificados.
( cd "$T/gateway" && echo cambio >> AGENTS.md && mkdir -p workspace-scout && git -C workspace-scout init -q ) || fail "setup anidado"
out=$(cd "$T/gateway" && git add -A 2>&1); rc=$?
[ $rc -ne 0 ] || fail "add -A con repo anidado sin commits NO fallo: la prueba no discrimina"
echo "$out" | grep -q "does not have a commit checked out" || fail "add -A fallo por otra cosa: $out"
[ -z "$(cd "$T/gateway" && git diff --cached --name-only)" ] || fail "add -A dejo algo staged pese al fatal"
( cd "$T/gateway" && git add -u 2>&1 && [ "$(git diff --cached --name-only)" = "AGENTS.md" ] ) || fail "add -u no dejo staged el tracked modificado"
echo "ok (4): add -A aborta entero con un repo anidado sin commits; add -u si avanza"
grep -q 'add -A FALLO (cayendo a add -u)' "$PS1FILE" || fail "$PS1FILE: falta el fallback a add -u con log"
grep -qx 'workspace-scout/' .gitignore || fail ".gitignore: falta workspace-scout/"
echo "ok (5): el script cae a add -u con log y .gitignore ignora workspace-scout/"
# (6) Reorientacion Fase 16: el pull con rebase vive en el camino de
# workspaces; el camino main delega y no jala nada.
n_w0=$(grep -n '# >>> workspace-sync' "$PS1FILE" | head -1 | cut -d: -f1)
n_w1=$(grep -n '# <<< workspace-sync' "$PS1FILE" | head -1 | cut -d: -f1)
n_pull=$(grep -n 'pull --rebase origin \$branch' "$PS1FILE" | head -1 | cut -d: -f1)
[ -n "$n_w0" ] && [ -n "$n_w1" ] && [ -n "$n_pull" ] \
  || fail "(6) sin marcas workspace o sin pull: w0=$n_w0 w1=$n_w1 pull=$n_pull"
[ "$n_pull" -gt "$n_w0" ] && [ "$n_pull" -lt "$n_w1" ] \
  || fail "(6) el pull (linea $n_pull) fuera del camino workspace ($n_w0-$n_w1)"
python3 - "$PS1FILE" "$T/main.ps1" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
a = next(i for i, l in enumerate(lines) if "# >>> main-delegate" in l)
b = next(i for i, l in enumerate(lines) if "# <<< main-delegate" in l)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines[a + 1:b]))
PY
grep -Eq 'git (pull|push|fetch)' "$T/main.ps1" \
  && fail "(6) el camino main trae git pull/push/fetch: el orquestador es dueno de src/"
echo "ok (6): pull con rebase en workspaces; main delega sin pull/push/fetch"
echo "PASS test-sync-pull-identity"
