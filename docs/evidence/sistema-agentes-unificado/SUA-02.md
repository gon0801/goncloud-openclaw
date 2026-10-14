# SUA-02, recibo del bloque: el controlador y la autoridad

Bloque SUA-02 del
[plan](../../superpowers/plans/2026-10-05-sistema-agentes-unificado.md), hecho según su
[diseño](../../superpowers/specs/2026-10-14-sua-02-controlador-design.md). Fecha: 2026-10-14
(UTC). R es el checkout de integración de OpenClaw (`feat/agent-work-integration`). G es este
repo.

## Qué entregó

R decide una raíz con una función pura, `decideRoot`, y `reconcileManagedRoot` lee la raíz, decide,
hace commit y admite. El modelo de `main` solo aporta lo que R no puede saber: el plan escrito desde
las palabras de David, el brief de cada unidad, lo que comprobó y las respuestas de David. Las trece
clases de excepción viven en R y en el contrato. Una excepción se levanta en el mismo commit que la
causa, se avisa con un reaviso por hora y por raíz y toma una sola respuesta del dueño. La autoridad
de una raíz solo se estrecha, y una concesión de David autoriza un efecto y nada más. Seis
herramientas `managed_roots_*` llevan todo eso a `main`, solo si `managedTasks.rootRequesters` lo
nombra. Sin la llave, `main` ve exactamente lo de hoy.

## Las rebanadas

| Rebanada | SHA | Qué hace | Veredicto |
|---|---|---|---|
| Diseño | G `3d603040` (PR #298) | El diseño y M-11 | APROBADO, Kimi (`VEREDICTO-SUA02-DISENO-r1`) |
| R0 | R `65432d099d07` | Línea base: la compuerta verde de la rebanada 14 de SUA-01, mismo SHA | Reutilizada |
| R1 | R `c4d5d96f6638` | Una lectura de autoridad y una admisión | APROBADO, Kimi (`VEREDICTO-SUA02-T1-r1`) |
| R2 | R `6b36d96bd82d` | Residuales de SUA-01 | APROBADO, Kimi (`VEREDICTO-SUA02-T1-r1`) |
| G1 | G `b0738f93` (PR #299) | Las clases de excepción en el contrato | APROBADO, Kimi (`VEREDICTO-SUA02-T1-r1`) |
| R3 | R `b4d47f605e11` | `decide` puro | APROBADO, Kimi (`VEREDICTO-SUA02-T1-r1`) |
| R4 | R `ee6a4d76ff94` | Esquema: las dos tablas perezosas | APROBADO, Kimi (`VEREDICTO-SUA02-T2-r1`) |
| R5 | R `ca430340d53d` | Foto ampliada | APROBADO, Kimi (`VEREDICTO-SUA02-T2-r1`) |
| R6 | R `fffe309e4757` | Excepciones | APROBADO, Kimi (`VEREDICTO-SUA02-T2-r1`) |
| R7 | R `4249d6b36e96` | Restringir | CAMBIOS a la tanda T3, Kimi (`VEREDICTO-SUA02-T3-r1`); sin hallazgo en R7 |
| R8 | R `29d87bd27e17` | Controlador y residual 1 de SUA-01 | CAMBIOS a la tanda T3: su bloqueante, una guarda sin prueba, es de R8 |
| R9 | R `568409a22823` | Las seis herramientas y la llave | CAMBIOS a la tanda T3; sin hallazgo en R9 |
| R10 | R `7b3db54226bf` | La prueba que pinea la guarda de R8 y la línea base de configuración | APROBADO, Kimi (`VEREDICTO-SUA02-T3-r2`, B1 cerrado) |
| G2 | este PR | Skill `raiz` e importador de `Plans.md` | APROBADO, Kimi (`VEREDICTO-SUA02-G23-r1`) |
| G3 | este PR | Casos en G, la sombra y este recibo | APROBADO, Kimi (`VEREDICTO-SUA02-G23-r1`) |

Los veredictos están en `~/.local/state/encargos-loop/VEREDICTO-SUA02-*`. GLM no tuvo cuota en
todo el bloque: Kimi revisó como relevo. Cada rebanada de R pasó la compuerta del diseño (sección
6) sobre su propio SHA y con su propio build: lint con los mismos 8 errores heredados, los trece
casos de siempre y los siete `root_*` de `test-runtime.sh` con su `candidateSha`.

## M-11

Un `system event --mode now` espera detrás de un turno de `main` en vuelo también cuando ese turno
es de otro agente (tres de tres, de 39,1 a 40,7 s). Por el criterio del plan, el controlador vive
en `main`. Está en
[SUA-00-mediciones](SUA-00-mediciones.md), "Mediciones vivas del 2026-10-14 (SUA-02)".

## Ensayo de reversa

Rebanada R4. El código que corre en la Mini, R `65432d099d07`, con su SHA fijado en el script,
abre, usa y deja intacta una base 27 con las trece tablas, una raíz, una excepción, una restricción
y un intento. El código de R4 vuelve a abrirla igual. Con la versión en 28, el código anterior se
niega a abrir. Contra otro árbol, el ensayo no corre y sale con 2. Resultado: PASA. Script y salida
en `~/.local/state/encargos-loop/artifacts/SUA02-T2-r1/ensayo-reversa.{sh,salida.txt}`.

## La sombra

`scripts/sistema_agentes/sombra.mjs` calcula, con el `decideLooseTask` de R `568409a22823` (R10
no lo toca) y los hechos anteriores a la decisión de `main`, qué habría propuesto el controlador
para cada encargo suelto. El extracto de solo lectura de la Mini se queda fuera del repo:
`~/.local/state/sua-loop/sombra/extracto-20261014T185907Z.json`, sha256
`6b84e9e1988af6d7a586c3267980cb8eff395d6d4fc25ebd1acb5dad9ed98ba8`, 27 tareas.

Resultado: de 27 tareas, 25 coinciden y 2 no. Ninguna se quedó sin decisión de `main`. La tabla
completa está en [SUA-02-sombra](SUA-02-sombra.md). Las dos que no coinciden son cancelaciones sin
ningún hecho en R: ni resultado ni incidencia. En una, la entrega se perdió en un diálogo de
opencode. En la otra, David la canceló porque no había host para ese modelo. Las dos cosas las vio
una persona fuera de R, así que la sombra propone esperar. Como dice el diseño (4.11, conflicto 1),
la sombra de un encargo suelto discrimina poco: `main` solo elige entre aceptar, corregir y
cancelar. Una propuesta `reintentar` cuenta como coincidencia cuando `main` canceló: el extracto no
dice si después encargó lo mismo otra vez.

## Casos en G

`scripts/agent-work/test-runtime.sh` ganó tres casos. Cada uno corre sus archivos de R:

| Caso | Archivos de R |
|---|---|
| `root_controller` | `managed-root.controller.test.ts`, `managed-roots-tool.test.ts`, `managed-root.native-registry.test.ts` y `managed-root.decide.test.ts` |
| `root_exceptions` | `managed-root.exception.test.ts`, `managed-root.exceptions.test.ts` y `managed-root.view.test.ts`. Exporta `AGENT_WORK_G_ROOT`, y falla si uno de los tres casos de contrato con nombre no pasa, también si se saltó |
| `root_authority` | `managed-root.authority.test.ts` |

`runtime-map.json` nombra `rootDecide`, `rootController` y `rootTools`.

`raiz_controlador` (`scripts/tests/test-agent-work-e2e.sh`) corre una raíz por el Gateway real de R
con el proveedor de guion. El turno que abre la raíz termina. El resultado de una unidad despierta a
`main`, el guion llama `managed_roots_reconcile` una vez con los hechos de esa unidad, y R acepta la
unidad y liga y admite la siguiente sin ningún turno de persona. Los tres planes del contrato y una
fila importada de `Plans.md` abren y ligan sus unidades listas.

Corridas del 2026-10-14 desde este checkout contra R `7b3db54226bf` (rebanada R10) con
`AGENT_WORK_RUNTIME_SOURCE`, cada caso con ese `candidateSha`:

| Caso | Pruebas |
|---|---|
| `root_contract` | 9 pasan. Las demás quedan fuera del filtro de nombre |
| `root_fan_in` | 58 pasan, 1 saltada (el caso de contrato, que corre en `root_contract`) |
| `root_recovery` | 17 pasan |
| `root_control` | 37 pasan, 1 saltada (el caso de contrato) |
| `root_effects` | 18 pasan |
| `root_capacity` | 13 pasan |
| `root_redaction` | 4 pasan |
| `root_controller` | 62 pasan |
| `root_exceptions` | 22 pasan, con sus tres casos de contrato |
| `root_authority` | 14 pasan |

Sin `AGENT_WORK_G_ROOT`, `root_exceptions` sale rojo: el caso de contrato falla en vez de saltarse.

`raiz_controlador`: 2 pasan, en 88 s. El caso de la raíz A→B hizo 2 peticiones al proveedor tras el
despertar, una de ellas con `managed_roots_reconcile`, y dejó `a` aceptada y `b` admitida. Los tres
planes del contrato y la fila importada ligaron sus unidades listas: `pedido-chico` y
`fila-importada` `unit-a`, `pedido-compuesto` `unit-a` y `unit-b`, la importada `7.2`.

## Segunda parte: instalación en la Mini

Una sola instalación, el 2026-10-14, con la T3 aprobada en su segunda ronda (R10). Antes, la T11-c
sobre una base sembrada por el árbol de R10, que nace con las trece tablas: el paquete instalado de
`65432d0` (lo que corría en la Mini) y el de `4acb881` (antes de SUA-01) arrancan su gateway sobre
ella, contestan y la dejan en 27, trece tablas e integridad `ok`
(`~/.local/state/sua-loop/t11c/t11c-sua02-*.log`).

Con `ANTERIOR=65432d0 t12-actualizar-sua01.sh 7b3db54226bf… --fuera-de-ventana`. Antes: R `65432d0`,
29 crons, ninguno corriendo ni en los próximos 150 s, 0 turnos de agentes y 0 encargos en vuelo, 0
tablas `managed_root%`. El gateway estuvo abajo de 20:50:53Z a 20:51:27Z. Después: `build-info` con
el commit `7b3db54226bf`, esquema 27, 0 tablas `managed_root%`, `managedTasks.root.read` con
`no-existe` contestó `null` y siguió habiendo 0 tablas, `managedTasks` como estaba y los mismos 29
crons. Resultado: `ACTUALIZADO OK`. Foto previa: `~/.openclaw/respaldos/pre-7b3db54-20261014-1350`.
La reversa es reinstalar el paquete de `65432d0`. Log:
`~/.local/state/encargos-loop/artifacts/T12/actualizar-7b3db54-20261014T205044Z.log`.

Canario: tarea `b54d9fac-a649-4b1a-a49b-e237404556ab` con `kimi-code-plan-cn/k3`, `acknowledged` con
`AbsenceVerified`, sin incidencias y con `result_digest` en R. `main` usó `read`, `exec`,
`tool_describe`, `tool_call`, `managed_tasks_submit` y `managed_tasks_admit`, ninguna herramienta
`managed_roots_*`: sin la llave `managedTasks.rootRequesters` no las ve. Evidencia en
`~/.local/state/encargos-loop/B22/corte/sua02-7b3db54.*`.

`artifact-manifest.json` apunta a `paquete-7b3db54`.
