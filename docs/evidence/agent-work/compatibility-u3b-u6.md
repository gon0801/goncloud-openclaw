# Compatibilidad de encargos con U3b, U4, U5 y U6

Revisión del plan de encargos T0–T12 contra los planes vigentes de Fase 20, Fase 17 y U6. Es un control de integración, no una aceptación de esas fases. La prueba `bash scripts/tests/test-agent-work-integration.sh director_handling` pasó 14 casos con uno omitido en el árbol de G; acredita el límite actual del director, no una futura fusión con U3b.

| Fase | Frontera y posible choque | Condición antes de implementarla o integrarla |
|---|---|---|
| U3b | Fase 20.1 y 20.5–20.8 modifican `corrida_worker/reconcile.py`, `corrida/reconciliar.sh`, adaptador, avisos y cierre que T8–T9 ya modificaron. El diseño original permitía cinco rondas y relevo hasta diez, además de supervisión con modelo. El plan y las dos especificaciones ya subordinan las rondas a quality-kit y excluyen esa supervisión para encargos gestionados. | Partir del SHA integrado de encargos; conservar `reconcile()` como único decisor de ingeniería y al runtime nativo como dueño de admisión/consumo. Conservar la regla de quality-kit ya incorporada: el mismo bloqueante reproducible en dos rondas consecutivas detiene el bloque, y un hallazgo no bloqueante no abre otra ronda. Probar `director_handling`, proyección, avisos y reconciliación tras cada edición compartida. Las tablas separan explícitamente modo gestionado y legacy. Coordinar 20.10 con drenaje y generación T11–T12; un cron compartido solo se elimina cuando todas sus entradas estén migradas. Las filas gestionadas posteriores requieren Continue bajo la misma raíz, con prueba antes de habilitarlas. |
| U4 | Fase 17.1/17.4 define identidad, seguimiento, presupuesto y recuperación que T1–T7 ya poseen para encargos; Fase 17.2 también toca `corrida` y progreso. | El centro proyecta tareas, recibos y recursos; no crea otro registro de workers, marca autoritativa de consumo, reserva de presupuesto ni reloj. Mantiene separados resultado recibido, manejo nativo, recurso cerrado y unidad de producto aceptada. El centro y su aviso principal comparten porcentaje de unidades verificadas. El tablero legacy conserva su porcentaje de avance declarado y lo identifica como tal; son contratos distintos definidos en `docs/spec/runbook-progress.v2.md` y en el seguimiento de corrida. |
| U5 | El almacén, scheduler y RPC mapeados aquí son de OpenClaw. Fase 17.3 exige funcionar en Hermes sin ejecutable ni gateway OpenClaw. | Compartir contrato portable, pruebas y forma de proyección; Hermes aporta su propia autoridad/adaptador y recibo por host. Nunca usar la prueba OpenClaw para declarar Hermes aceptado. |
| U6 | La asignación nativa actual no tiene `goal_id`, `plan_revision`, pausa/reanudación ni criterios agregados. Su esquema es estricto; `complete` solo cierra el manejo de un encargo. | El plan U6.0 fija un vínculo versionado entre meta/unidad/revisión y tarea/root/generación; una sola raíz por meta y unidades como hijos o continuaciones. Si falta API nativa recuperable, U6.1 debe extenderla antes de integrar, sin repetir submit para cada unidad. U6 selecciona dependencias y criterios; el runtime conserva admisión, hijos, cancelación y presupuesto. Pausa y reanudación deben cercar los efectos nativos, no solo `corrida`. Un resultado `Approved` no da 100% sin aceptación de los criterios vigentes. Hermes conserva recibo independiente. |

Fuentes: `Plans.md` Fase 20 y Fase U6; `docs/superpowers/plans/2026-09-29-director-corrida.md` (20.1, 20.4–20.10); `docs/superpowers/plans/2026-09-22-centro-tareas.md` (17.1–17.8); `docs/superpowers/plans/2026-09-24-u6-metas-autonomas.md` (U6.0–U6.6); este plan (T1–T12); `scripts/mac/corrida_worker/reconcile.py`; `scripts/agent-work/progress_bridge.py`; y `R/src/agents/tasks/managed-task.types.ts`. No se probó todavía la integración de U3b, U4, U5 o U6 con el runtime nuevo. Estas condiciones se revisan de nuevo contra los SHA reales al comenzar cada fase.

## Riesgos corregidos en la base

- G `82d3817` trata la sesión preexistente entregada a `claim_cli_once` como `UserAdopted`. La regresión falló con `AbsenceVerified` antes del arreglo; claim, replay y dos cierres ahora conservan la sesión, revocan una vez y no llaman a stop. Pasaron 32 pruebas focalizadas. Ausencia de nonce no acredita propiedad.
- R `e6abc6fa19` impide en la transacción de registro que un worker gestionado cree una raíz y presupuesto independientes. Las tres regresiones fallaron antes del arreglo. Activo, cancelado y recuperado se rechazan sin nuevas filas; un run ordinario posterior al fin nativo sí puede crear raíz. Pasaron 30 pruebas focalizadas y después 9 del archivo ampliado.

Las correcciones y los contratos alineados permiten preparar las fases siguientes contra el perímetro integrado y probado. No certifican rutas CLI/Hermes no ensayadas ni una ejecución futura de U3b–U6. La aceptación viva requiere cobertura y recibo del host utilizado.

## Verificación del conjunto corregido

R `9f99e2264c012dd4cf5bd9dbac10bc7e534ffc05` pasó `pnpm tsgo:core` y
`pnpm build`. Los dos sellos de build y `build-info.json` registran ese SHA
con entradas limpias. G `3d377ed` integra el consumidor `--device-auth` y el
ensayo `bash scripts/tests/test-agent-work-e2e.sh cli_gateway`, ejecutado con
`AGENT_WORK_RUNTIME_SOURCE=/Users/dn/dev/openclaw-agent-work-integration`.
Pasó 1/1: `submit=1 admit=1 delivery=1 report=1 blocked=1`. El replay no
duplicó entrega y el cierre conservó la sesión adoptada. Los archivos del
consumidor y del E2E integrado son idénticos a los probados en G `3d377ed` (equivalente integrado de `270b2faa`, que vive solo en `feat/agent-work-t9-e2e`).
La integración conservó además `prove_absent` en el doble de la regresión de
propiedad; esa prueba pasó otra vez tras resolver el conflicto. No quedaron
procesos propios del Gateway de ensayo ni del ejecutor E2E.

Los candados de commit pasaron. Los checks focalizados cubrieron apertura de
Fase 17 por eventos, selección vigente de pruebas de cola, estructura del
ledger, enlaces locales, localización de runbooks y reglas de entorno. La
batería completa y la aceptación productiva de T0–T12 permanecen pendientes;
no se cerró ningún bloque ni se habilitó una fila de cobertura con este recibo.
