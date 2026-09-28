---
name: saikit-cierre-pr
description: Cierra un PR con la ruta autorizada de la Fase 14: recibo del kit, CI vigente y authorization_ref en alcance.
---

# Cierre de PR

## Kit apagado (desde 2026-09-27)

<!-- candado: test-merge-sin-kit.sh -->
Mientras el SummonAI Kit siga apagado, esta sección reemplaza las dos rutas y el paso 2 del flujo de abajo.
No hay recibo `saikit-entrega.v1` ni entrypoint de merge del kit: no los pidas.
<!-- candado: test-merge-sin-kit.sh -->
Con CI y CodeRabbit aprobados y los bloqueantes resueltos, ejecuta `gh pr merge <PR> --squash --match-head-commit <SHA>` (`docs/runbooks/loop-autopilot.md` §6).
Confirma `MERGED` y el SHA integrado.

El merge automatico de la Fase 14 sigue UNA de dos rutas cerradas:

## Ruta 2 (automatica, Task 7): solo implementer/ingenieria
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->

Lee el registro de corrida (`corrida.v2`) y resuelve su `authorization_ref`
contra la tabla versionada `scripts/mac/corrida/preaprobaciones.v1.json`:
debe existir, estar `Aprobado` y cubrir repo, rama y operacion. Con la
preaprobacion en alcance, el recibo del kit `saikit-entrega.v1` vigente para
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->
el head y el CI de ese mismo SHA en verde, invoca la proyeccion
`corrida.sh compuerta RUN LANE merge --sha SHA --evidence FILE` (Task 6), que
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->
delega al entrypoint de merge del kit instalado. El kit verifica el recibo
vigente, el CI y `headRefOid`, y fija su mutacion de GitHub con
`expectedHeadOid`. Un recibo nunca crea autorizacion por si solo. Sin bypass
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->
GraphQL directo alterno. Registra la intencion antes de delegar y relee
`state`, `mergedAt` y `mergeCommit` tras cada respuesta, incluido
`UNPROCESSABLE`.

## Flujo de cierre

1. Lee el SHA actual del PR, CI y CodeRabbit; corrige los bloqueantes de revision.
2. Con la ruta autorizada y el recibo del kit vigente (con el kit apagado, sigue «Kit apagado»), ejecuta `gh pr merge <PR> --squash --match-head-commit <SHA>` desde el worktree. En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.
3. Comprueba `MERGED` y el SHA integrado. Si la tarea incluye despliegue, sigue el procedimiento del destino y verifica el resultado.

## Ruta 1 (legada): orden fechada del dueno

Si existe una orden fechada del dueno para el cambio, el merge sigue el flujo
normal de GitHub documentado abajo; la orden es la autorizacion.
