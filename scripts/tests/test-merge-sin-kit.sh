#!/usr/bin/env bash
# Con el SummonAI Kit apagado, el cierre de PR sigue loop-autopilot.md §6 y
# post-merge-closure no vuelve a desplegar el hook.
# Uso: bash scripts/tests/test-merge-sin-kit.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
grep -qF 'esta sección reemplaza la orden fechada del dueño y el paso 2 del flujo de abajo' agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (implementer): la seccion Kit apagado no reemplaza el paso 2 del flujo'
grep -qF 'ejecuta `python3 scripts/agent-work/merge.py mergear <PR> --sha <head>` (`docs/runbooks/loop-autopilot.md` §6)' agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (implementer): sin la instruccion de merge de §6'
grep -qF 'Solo el coordinador comenta, descarta' agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (implementer): falta la regla que reserva comentario y descarte al coordinador'
grep -qF '§6). En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.' agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (implementer): la via sin kit pierde el PATH del nodo Mac'
grep -qF 'esta sección reemplaza la orden fechada del dueño y el paso 2 del flujo de abajo' agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (ingenieria): la seccion Kit apagado no reemplaza el paso 2 del flujo'
grep -qF 'ejecuta `python3 scripts/agent-work/merge.py mergear <PR> --sha <head>` (`docs/runbooks/loop-autopilot.md` §6)' agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (ingenieria): sin la instruccion de merge de §6'
grep -qF 'Solo el coordinador comenta, descarta' agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (ingenieria): falta la regla que reserva comentario y descarte al coordinador'
grep -qF '§6). En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.' agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (ingenieria): la via sin kit pierde el PATH del nodo Mac'
grep -qF 'Con el kit apagado, lo anterior no aplica: `main` encarga el cierre' agents/main/agent/workshop-skills/saikit-merge-route/SKILL.md \
  || fail 'saikit-merge-route no manda al cierre sin kit'
grep -qF 'The kit is off since 2026-09-27, so skip steps 3 to 5' agents/main/agent/workshop-skills/post-merge-closure/SKILL.md \
  || fail 'post-merge-closure todavia despliega el hook'
grep -qF 'cualquier agente Claw o CLI ejecuta `python3 scripts/agent-work/merge.py mergear <PR> --sha <head>`' docs/runbooks/loop-autopilot.md \
  || fail 'loop-autopilot.md §6 ya no tiene la regla a la que apuntan las skills'
echo 'PASS: cierre de PR sin el kit'
