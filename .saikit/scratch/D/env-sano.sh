#!/bin/bash
# Entorno sano para correr los candados desde un sandbox restringido.
#
# Medido 2026-09-17 en wt-f7-D: cuatro fallos de run-checks.sh sin tocar nada
# del repo, los cuatro ambientales y pre-existentes (verificados con el arbol
# en stash, solo BRIEF.md untracked):
#  1. test-merge-allowlist-cierre-pr.sh: bash 3.2 no parsea el heredoc dentro
#     de $() con ')' en la misma linea (linea 7); con bash 5 sale VERDE.
#  2. bateria summa-gate (1 fail): diagnostic-guard-finalize escribe estado en
#     $HOME/.openclaw/summa-gate/state; $HOME no escribible -> fail-open ->
#     assert rojo. Con HOME escribible + OPENCLAW_NODE_MODULES: 17/17.
#  3-4. test-mac-tmux-control.sh y test-tmux-activity-watch.sh: tmux necesita
#     unix sockets y el sandbox los bloquea (bind -> EPERM, medido con
#     socket.bind en python). TMUX_TMPDIR no alcanza. Estos dos NO pasan aqui;
#     pasan en CI y en una Mac normal. Fuera del alcance del carril D.
#
# Este script prepara el espejo y ejecuta lo que reciba. No saltea nada: los
# candados corren completos; solo les da el entorno que CI ya tiene.
#
# Uso: bash .saikit/scratch/D/env-sano.sh bash scripts/run-checks.sh
#      bash .saikit/scratch/D/env-sano.sh git commit -m '...'
set -u

rm -rf /tmp/fakehome /tmp/faketmux
mkdir -p /tmp/fakehome/.openclaw/summa-gate/state \
         /tmp/fakehome/.claude/skills/autopilot-runbook \
         /tmp/faketmux
ln -s /Users/dn/.openclaw/tools /tmp/fakehome/.openclaw/tools
cp /Users/dn/.claude/skills/autopilot-runbook/SKILL.md \
   /tmp/fakehome/.claude/skills/autopilot-runbook/SKILL.md
chmod 700 /tmp/faketmux
if [ ! -d /tmp/pc-cache ]; then
  cp -r /Users/dn/.cache/pre-commit /tmp/pc-cache
fi

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME=/tmp/fakehome
export TMUX_TMPDIR=/tmp/faketmux
export PRE_COMMIT_HOME=/tmp/pc-cache
export OPENCLAW_NODE_MODULES=/Users/dn/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw
export OPENCLAW_BIN=/Users/dn/.openclaw/bin/openclaw

exec "$@"
