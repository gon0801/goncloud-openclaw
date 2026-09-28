#!/usr/bin/env bash
# Con el SummonAI Kit apagado, el cierre de PR sigue loop-autopilot.md §6 y
# post-merge-closure no vuelve a desplegar el hook.
# Uso: bash scripts/tests/test-merge-sin-kit.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
grep -qF 'esta sección reemplaza las dos rutas y el paso 2 del flujo de abajo' agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (implementer): la seccion Kit apagado no reemplaza la Ruta 2'
grep -qF 'ejecuta `gh pr merge <PR> --squash --match-head-commit <SHA>` (`docs/runbooks/loop-autopilot.md` §6)' agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (implementer): sin la instruccion de merge de §6'
grep -qF 'esta sección reemplaza las dos rutas y el paso 2 del flujo de abajo' agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (ingenieria): la seccion Kit apagado no reemplaza la Ruta 2'
grep -qF 'ejecuta `gh pr merge <PR> --squash --match-head-commit <SHA>` (`docs/runbooks/loop-autopilot.md` §6)' agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (ingenieria): sin la instruccion de merge de §6'
grep -qF 'Con el kit apagado, lo anterior no aplica: `main` encarga el cierre' agents/main/agent/workshop-skills/saikit-merge-route/SKILL.md \
  || fail 'saikit-merge-route no manda al cierre sin kit'
grep -qF 'The kit is off since 2026-09-27, so skip steps 3 to 5' agents/main/agent/workshop-skills/post-merge-closure/SKILL.md \
  || fail 'post-merge-closure todavia despliega el hook'
grep -qF 'Cualquier agente Claw o CLI puede ejecutar `gh pr merge <PR> --squash --match-head-commit <SHA>`' docs/runbooks/loop-autopilot.md \
  || fail 'loop-autopilot.md §6 ya no tiene la regla a la que apuntan las skills'
echo 'PASS: cierre de PR sin el kit'
