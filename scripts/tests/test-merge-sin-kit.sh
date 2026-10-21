#!/usr/bin/env bash
# Con el SummonAI Kit apagado, el cierre de PR sigue loop-autopilot.md §6 y
# post-merge-closure no vuelve a desplegar el hook. Desde el bloque H el merge
# y el despliegue los hace el motor (`motor entrega`), no merge.py ni un agente.
# Uso: bash scripts/tests/test-merge-sin-kit.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
grep -qF 'esta sección reemplaza la orden fechada del dueño y el paso 2 del flujo de abajo' agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (implementer): la seccion Kit apagado no reemplaza el paso 2 del flujo'
grep -qF 'el cierre del PR lo hace el motor: lo que cambia código va por `motor entrega` (skill `motor`); ningún agente mergea ni despliega a mano (`docs/runbooks/loop-autopilot.md` §6)' agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (implementer): sin la ruta del motor de §6'
grep -qF 'Solo el coordinador comenta, descarta' agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (implementer): falta la regla que reserva comentario y descarte al coordinador'
grep -qF 'En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.' agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (implementer): la via sin kit pierde el PATH del nodo Mac'
grep -qF 'esta sección reemplaza la orden fechada del dueño y el paso 2 del flujo de abajo' agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (ingenieria): la seccion Kit apagado no reemplaza el paso 2 del flujo'
grep -qF 'el cierre del PR lo hace el motor: lo que cambia código va por `motor entrega` (skill `motor`); ningún agente mergea ni despliega a mano (`docs/runbooks/loop-autopilot.md` §6)' agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (ingenieria): sin la ruta del motor de §6'
grep -qF 'Solo el coordinador comenta, descarta' agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (ingenieria): falta la regla que reserva comentario y descarte al coordinador'
grep -qF 'En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.' agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md \
  || fail 'saikit-cierre-pr (ingenieria): la via sin kit pierde el PATH del nodo Mac'
grep -qF 'Con el kit apagado, lo anterior no cambia: no hay recibo `saikit-entrega.v1` que pedir ni closer al que encargar el cierre' agents/main/agent/workshop-skills/saikit-merge-route/SKILL.md \
  || fail 'saikit-merge-route no manda el cierre al motor sin kit'
grep -qF 'The kit is off since 2026-09-27, so skip steps 3 to 5' agents/main/agent/workshop-skills/post-merge-closure/SKILL.md \
  || fail 'post-merge-closure todavia despliega el hook'
grep -qF 'El merge y el despliegue los hace el motor: lo que cambia código va por `motor entrega` (skill `motor`); ningún agente mergea ni despliega a mano' docs/runbooks/loop-autopilot.md \
  || fail 'loop-autopilot.md §6 ya no tiene la regla del motor a la que apuntan las skills'
echo 'PASS: cierre de PR sin el kit'
