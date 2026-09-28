#!/usr/bin/env bash
# Con el SummonAI Kit apagado, el cierre de PR sigue loop-autopilot.md §6 y
# post-merge-closure no vuelve a desplegar el hook.
# Uso: bash scripts/tests/test-merge-sin-kit.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
grep -qF 'la Ruta 2 no puede completarse' agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (implementer) sin la seccion Kit apagado'
grep -qF 'la Ruta 2 no puede completarse' agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (ingenieria) sin la seccion Kit apagado'
grep -qF 'Con el kit apagado no hay ruta del kit que pasar' agents/main/agent/workshop-skills/saikit-merge-route/SKILL.md \
  || fail 'saikit-merge-route no manda al cierre sin kit'
grep -qF 'The kit is off since 2026-09-27' agents/main/agent/workshop-skills/post-merge-closure/SKILL.md \
  || fail 'post-merge-closure todavia despliega el hook'
grep -qF 'Cualquier agente Claw o CLI puede ejecutar `gh pr merge <PR> --squash --match-head-commit <SHA>`' docs/runbooks/loop-autopilot.md \
  || fail 'loop-autopilot.md §6 ya no tiene la regla a la que apuntan las skills'
echo 'PASS: cierre de PR sin el kit'
