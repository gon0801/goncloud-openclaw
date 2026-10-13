---
name: saikit-cierre-pr
description: Cierra un PR con CI y revisión vigentes para el head, merge por GitHub y comprobación del resultado.
---

# Cierre de PR

## Kit apagado (desde 2026-09-27)

<!-- candado: test-merge-sin-kit.sh -->
Mientras el SummonAI Kit siga apagado, esta sección reemplaza la orden fechada del dueño y el paso 2 del flujo de abajo.
No hay recibo `saikit-entrega.v1` ni entrypoint de merge del kit: no los pidas.
<!-- candado: test-merge-sin-kit.sh -->
Con CI y CodeRabbit aprobados y los bloqueantes resueltos, ejecuta `gh pr merge <PR> --squash --match-head-commit <SHA>` (`docs/runbooks/loop-autopilot.md` §6). En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.
Confirma `MERGED` y el SHA integrado.

## Flujo de cierre

1. Lee el SHA actual del PR, CI y CodeRabbit; corrige los bloqueantes de revision.
2. Con la orden fechada del dueno y el recibo del kit vigente (con el kit apagado, sigue «Kit apagado»), ejecuta `gh pr merge <PR> --squash --match-head-commit <SHA>` desde el worktree. En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.
3. Comprueba `MERGED` y el SHA integrado. Si la tarea incluye despliegue, sigue el procedimiento del destino y verifica el resultado.

## Orden fechada del dueno

Si existe una orden fechada del dueno para el cambio, el merge sigue el flujo
normal de GitHub documentado arriba (Flujo de cierre); la orden es la autorizacion.
