---
name: saikit-cierre-pr
description: Prepara el cierre de un PR con CI y revisión vigentes para el head; el merge y el despliegue los hace el motor.
---

# Cierre de PR

## Kit apagado (desde 2026-09-27)

<!-- candado: test-merge-sin-kit.sh -->
Mientras el SummonAI Kit siga apagado, esta sección reemplaza la orden fechada del dueño y el paso 2 del flujo de abajo.
No hay recibo `saikit-entrega.v1` ni entrypoint de merge del kit: no los pidas.
<!-- candado: test-merge-sin-kit.sh -->
Con CI verde, la revisión del bot ai-review (DeepSeek) sobre el head sin bloqueantes abiertos y, si CodeRabbit comentó, sus hilos Major/Critical adjudicados, el cierre del PR lo hace el motor: lo que cambia código va por `motor entrega` (skill `motor`); ningún agente mergea ni despliega a mano (`docs/runbooks/loop-autopilot.md` §6). En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.
El motor confirma `MERGED` y el SHA integrado.

<!-- candado: test-merge-sin-kit.sh -->
Solo el coordinador comenta, descarta (`ai-review: descartar F<n>`) y adjudica hallazgos en el PR; tú nunca lo haces.

## Flujo de cierre

1. Lee el SHA actual del PR y CI, y la revisión del bot ai-review (DeepSeek) sobre el head; si CodeRabbit comentó, lee sus hilos. Corrige los bloqueantes de revision.
2. Con la orden fechada del dueno y el recibo del kit vigente (con el kit apagado, sigue «Kit apagado»), el merge lo hace el motor por `motor entrega` (§6 de `docs/runbooks/loop-autopilot.md`): ningún agente ejecuta el merge a mano. En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.
3. El motor comprueba `MERGED` y el SHA integrado. Si la tarea incluye despliegue, va en el mismo plan del motor, que lo ejecuta y verifica el resultado.

## Orden fechada del dueno

Si existe una orden fechada del dueno para el cambio, el merge sigue la ruta del
motor documentada arriba (Flujo de cierre); la orden es la autorizacion.
