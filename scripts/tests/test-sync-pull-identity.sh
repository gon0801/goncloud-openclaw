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
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
# Sin identidad de ningun tipo: ni global ni de sistema (como la cuenta ehven del gateway).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
ID=(-c user.name=openclaw-auto -c user.email=ehventasmx@gmail.com)
fail() { echo "FAIL: $1"; exit 1; }

git init -q --bare "$T/origin.git" || fail "init bare"
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
echo "PASS test-sync-pull-identity"
