# SUA-01, recibo del bloque: la frontera durable en OpenClaw

Bloque SUA-01 del
[plan](../../superpowers/plans/2026-10-05-sistema-agentes-unificado.md), hecho
según su [diseño](../../superpowers/specs/2026-10-13-sua-01-frontera-durable-design.md).
Fechas: del 2026-10-13 al 2026-10-14 (UTC). R es el checkout de integración de
OpenClaw (`feat/agent-work-integration`, respaldado en el repo privado
`gon0801/openclaw-agent-work-integration`). G es este repo.

## Qué entregó

La raíz es una entidad propia de R, con once tablas `managed_root*` que nacen
la primera vez que alguien abre una raíz. La base sigue en la versión 27. Una
raíz abre su plan, liga sus unidades a tareas nativas, consume resultados en un
commit (fan-in A+B→C), se pausa, se reanuda y se cancela por época, da un solo
permiso de inicio por efecto, respeta el cupo del gateway y sus escritores,
revisa su plan y recupera a su solicitante después de `/new`. El operador la lee
y la controla por el gateway (`managedTasks.root.read`, `managedTasks.root.control`,
con `operator.admin`). Una tarea suelta hace lo mismo que antes del bloque.

## Las rebanadas de R

La rebanada 0 es la línea base: no tiene commit. Cada rebanada pasó la
compuerta del diseño (sección 6) sobre su propio SHA, con su propio build y con
G en `2c817ce7769c`. Lint de R tiene 8 errores heredados de la base, los mismos
en todos los SHA; ninguna rebanada agregó uno.

| N.º | SHA de R | Qué hace | Veredicto |
|---|---|---|---|
| 0 | `4acb881e015a` | Línea base, sin cambios | Compuerta verde, `ruta_viva` sin saltos |
| 1 | `22225cefcdd7` | Tipos, parsers y máquinas puras | APROBADO, GLM 5.3 |
| 2 | `5f6af7713437` | Un solo punto de acceso (`resolveTaskAccess`) | APROBADO, GLM 5.3 |
| 3 | `6669121d7efa` | El árbol de presupuesto como tipo | APROBADO, GLM 5.3 |
| 4 | `a37ff7f55710` | Esquema: once tablas perezosas | APROBADO, GLM 5.3 |
| 5 | `50de978812f6` | Abrir y leer una raíz | APROBADO, GLM 5.3 |
| 6 | `5de8d0db911f` | Commit: ligar unidades | APROBADO, Kimi (relevo) |
| 7 | `073e2e5bbbc4` | Admitir una tarea de raíz | APROBADO, Kimi (relevo) |
| 8 | `4311b6982815` | Commit: consumir, acreditar y terminar | APROBADO, Kimi (relevo) |
| 9 | `959b06d8b8dc` | Control: pausa, reanudación y cancelación | APROBADO, Kimi (relevo) |
| 10 | `8ddbe6fec434` | Efectos | APROBADO, Kimi (relevo) |
| 11 | `9dbd6191777d` | Cupo del gateway, escritores y contadores | APROBADO, Kimi (relevo) |
| 12 | `198337f22c2e` | Revisión de plan | APROBADO, Kimi (relevo) |
| 13 | `6cc2b97ddb5d` | Recuperar al solicitante | APROBADO, Kimi (relevo) |
| 14 | `65432d099d07` | Entrada del gateway y redacción | APROBADO (Kimi, `VEREDICTO-SUA01-R1415-r1`) |
| 15 | este PR de G | Casos en G, contrato y este recibo | Pendiente de revisión |

GLM revisó de la 1 a la 5. Agotó su cuota el 2026-10-14 a las 04:35Z y David
eligió a Kimi como revisor de relevo para lo que siguió. Los veredictos están en
`~/.local/state/encargos-loop/VEREDICTO-SUA01-R{123,45,67,810,1113}-r1`, y las
compuertas en `~/.local/state/sua-loop/compuertas/`.

Decisiones del operador que el bloque dejó con un valor: el cupo del gateway es
de 4 plazas cuando falta `managedTasks.capacity`, y solo el dueño de una raíz
(mismo `principal`, `agentId` y `sessionKey`) la sigue.

## Ensayo de reversa

Rebanada 4, 2026-10-14. El código de `4acb881e` abre y usa una base 27 que ya
tiene las once tablas, una raíz y un intento. Después, el código de la rebanada
4 vuelve a abrirla. La base queda en 27, con 11 tablas, 1 raíz y 1 tarea. El
control lo confirma: con la versión en 28, el código de `4acb881e` se niega a
abrir. Resultado: PASA. Salida en
`~/.local/state/encargos-loop/artifacts/SUA01-R45-r1/ensayo-reversa.salida.txt`.

## T11-c con el paquete instalado

El paquete de `4acb881` que corría en la Mini (sha256 `adc2588d…`) arranca su
gateway sobre una base 27 con las once tablas, una raíz y un intento sembrados.
Contesta `health` y `managedTasks.projections.list`. Después, y otra vez tras
detenerlo: versión 27, 11 tablas, 1 raíz, 1 intento, 1 tarea, integridad `ok`.
Resultado: PASA, primero con el árbol de la rebanada 5
(`t11c-sua01-20261014T020309Z.log`) y otra vez con el de la 7
(`t11c-sua01-r67-20261014T044801Z.log`). Script y logs en
`~/.local/state/sua-loop/t11c/`.

## Primera instalación en la Mini

R `073e2e5bbbc4` (rebanada 7), 2026-10-14 de 04:50:32Z a 04:51:27Z, con
`t12-actualizar-sua01.sh --fuera-de-ventana`. Antes: 30 crons, 0 encargos en
vuelo, 0 tablas `managed_root%`. El gateway estuvo abajo de 04:50:41Z a
04:51:27Z. Después: `build-info` con el commit `073e2e5bbbc4`, esquema 27, 0
tablas `managed_root%`, `managedTasks` como estaba y los mismos 30 crons.
Resultado: `ACTUALIZADO OK`. Foto previa en la Mini:
`~/.openclaw/respaldos/pre-073e2e5-20261013-2150`. La reversa es reinstalar el
paquete de `4acb881`. Log:
`~/.local/state/encargos-loop/artifacts/T12/actualizar-073e2e5-20261014T045032Z.log`.

## Canario real

Después de instalar, `main` encargó una tarea por CLI con
`kimi-code-plan-cn/k3`: `5589e361-97a2-4290-9ea0-62af837e957f`. Cerró
`acknowledged` con `AbsenceVerified`, con suscripción, sin permisos negados y sin
incidencias. La admisión quedó `admitted` y el resultado tiene su `result_digest`
en R. Evidencia en `~/.local/state/encargos-loop/B22/corte/sua01-073e2e5b.*`.

## Segunda instalación en la Mini

Se hizo el 2026-10-14 con la rebanada 14 aprobada (VEREDICTO-SUA01-R1415-r1,
Kimi), con `ANTERIOR=073e2e5 t12-actualizar-sua01.sh 65432d099d07…
--fuera-de-ventana`. Antes de instalar, la T11-c con el paquete instalado de
`4acb881` sobre la base del worktree de la rebanada 14 volvió a pasar
(`~/.local/state/sua-loop/t11c/t11c-sua01-r14-*.log`).

Antes: R `073e2e5`, 30 crons, ninguno corriendo ni en los próximos 150 s, 0
turnos de agentes y 0 encargos en vuelo, 0 tablas `managed_root%`. El gateway
estuvo abajo de 10:15:01Z a 10:15:33Z. Después: `build-info` con el commit
`65432d099d07`, esquema 27, 0 tablas `managed_root%`, `managedTasks` como estaba
y los mismos 30 crons. `managedTasks.root.read` con `{"rootId":"no-existe"}`
contestó `null` y siguió habiendo 0 tablas. Resultado: `ACTUALIZADO OK`. Foto
previa: `~/.openclaw/respaldos/pre-65432d0-20261014-0315`. La reversa es
reinstalar el paquete de `073e2e5` (o el de `4acb881`, que la T11-c probó sobre
una base con las tablas). Log:
`~/.local/state/encargos-loop/artifacts/T12/actualizar-65432d0-20261014T101452Z.log`.

Canario después de instalar: tarea `13d5e4d0-6a42-4ead-b892-d1b64716f08d` con
`kimi-code-plan-cn/k3`, `acknowledged` con `AbsenceVerified`, sin incidencias y
con `result_digest` en R. Evidencia en
`~/.local/state/encargos-loop/B22/corte/sua01-65432d0.*`.

`artifact-manifest.json` apunta a `paquete-65432d0` (`artifact.py verify`: `artifact
OK: openclaw 2026.9.7 from 65432d099d0771f48331069fcc2bf044b2c6b873`).

## Casos de G contra R

`scripts/agent-work/test-runtime.sh` ganó siete casos. Cada uno corre su
archivo de R:

| Caso | Archivos de R |
|---|---|
| `root_contract` | `managed-root.{machine,store,decision,control}.test.ts`, solo los casos contra `sistema-agentes.v1`. Exporta `AGENT_WORK_G_ROOT`, así que R valida con el `contrato.py` de este checkout los documentos que `readManagedRoot` emitió. El caso falla si alguno de sus nueve casos con nombre no pasa, también si se saltó |
| `root_fan_in` | `managed-root.commit.test.ts`, `managed-root.decision.test.ts` |
| `root_recovery` | `managed-root.requester.test.ts`, `managed-root.recovery.test.ts` |
| `root_control` | `managed-root.control.test.ts`, `managed-root.plan.test.ts`, `src/gateway/server-methods/managed-tasks-root.test.ts`. Pide el build de R |
| `root_effects` | `managed-root.effect.test.ts` |
| `root_capacity` | `managed-root.capacity.test.ts` |
| `root_redaction` | `managed-root.redaction.test.ts` y la prueba de tabla de `managed-tasks-tool.test.ts` |

`runtime-map.json` nombra las rutas nuevas de R (`rootDomain`, `rootStore`,
`rootWorker`, `rootSchema`, `rootGatewayMethods`). `test-runtime.sh` comprueba
que existan en el checkout que prueba.

Corrida del 2026-10-14, de 09:41Z a 09:46Z, desde este checkout de G en
`267c91cf` contra R `65432d099d07` (rebanada 14), con
`AGENT_WORK_RUNTIME_SOURCE`. Cada caso imprimió ese `candidateSha`.

| Caso | Pruebas |
|---|---|
| `root_contract` | 9 pasan. Las demás quedan fuera del filtro de nombre |
| `root_fan_in` | 58 pasan, 1 saltada: el caso de contrato, que corre en `root_contract` |
| `root_recovery` | 16 pasan |
| `root_control` | 37 pasan, 1 saltada: el caso de contrato, que corre en `root_contract` |
| `root_effects` | 18 pasan |
| `root_capacity` | 13 pasan |
| `root_redaction` | 3 pasan |

Los trece casos de antes (`registration_identity`, `result_receipt`,
`admission_restart`, `handling_atomic`, `handling_unresolved`,
`resource_release`, `budget_tree`, `budget_context`, `budget_evasion`,
`waiting_reason`, `recovery_limit`, `recovery_queue`, `delegation_bypass`)
salen verdes con el mismo `candidateSha`, desde este checkout y desde G
`2c817ce7`. `ruta_viva` no corrió en esta rebanada: la corre el coordinador.

Que `root_contract` discrimina: con `controlEpoch` de una unidad pedido desde 99
en `contrato.py`, el caso sale rojo (los documentos de unidad ya no pasan). Sin
`AGENT_WORK_G_ROOT`, sus 9 casos se saltan y el caso sale rojo por la guarda de
nombres. Sin la variable y sin la guarda, sale verde con todo saltado: la guarda
es lo que lo impide.

## Contrato

`docs/spec/sistema-agentes.v1.md` gana la frase del conflicto 2 del diseño: el
`controlEpoch` de una unidad es la época con la que se admitió y, antes de
admitir, la época vigente de la raíz. No cambia el esquema, `contrato.py` ni los
fixtures.
