#!/usr/bin/env bash
# Uso: empaquetar-r.sh <repo-git> <sha> <dir-salida-vacio>
# Crea un worktree aislado en <sha>, construye, empaqueta con prepareNpmPackageBundle de upstream
# (saltando solo update:compat:check) e instala en un prefijo temporal. Imprime la duración de cada paso.
set -euo pipefail
REPO=$1 SHA=$2 OUT=$3
TOOLS=$(cd "$(dirname "$0")" && pwd)
NODE_BIN=${NODE_BIN:-$HOME/.openclaw/tools/node/bin}
export PATH="$NODE_BIN:$PATH"
step() { local name=$1; shift; local t0=$SECONDS; echo "== $name: $*"; "$@"; echo "== $name: exit=0 duration=$((SECONDS - t0))s"; }

WT="$(mktemp -d)/r"
step worktree git -C "$REPO" worktree add --detach "$WT" "$SHA"
cd "$WT"
step install pnpm install --frozen-lockfile
step build env OPENCLAW_CONTROL_UI_RELEASE_BUILD=1 pnpm build
[[ -f dist/control-ui/index.html ]] || step ui-build env OPENCLAW_CONTROL_UI_RELEASE_BUILD=1 pnpm ui:build
step pack node "$TOOLS/pack-r.mjs" "$WT" "$OUT" --skip-update-compat-check
test -z "$(git status --porcelain)" && echo "== worktree limpio tras empaquetar"

PREFIX=$(mktemp -d) H=$(mktemp -d)
step npm-install env HOME="$H" npm install -g --prefix "$PREFIX" \
  --allow-scripts="$OUT/openclaw-$(node -p 'require("./package.json").version').tgz" \
  "$OUT"/openclaw-ai-*.tgz "$OUT/openclaw-$(node -p 'require("./package.json").version').tgz"
step smoke env HOME="$H" "$PREFIX/bin/openclaw" --version
echo "WORKTREE=$WT PREFIX=$PREFIX HOME_TMP=$H"
