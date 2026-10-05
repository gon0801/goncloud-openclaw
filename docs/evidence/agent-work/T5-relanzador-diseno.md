# T5: diseño de la recuperación

Diseño de la recuperación de tareas gestionadas sobre la cola nativa, sin implementar. Repos citados: R `/Users/dn/dev/openclaw-agent-work-integration` @ `96f8e5fadf64ba0a5d473e3e0d968d5f5b4fe32d` (solo lectura) y G `/Users/dn/dev/wt/encargos-b4` @ `a92c5e3b79eded9946dfc5ee327ee435d7c6a976` (`docs/evidence/agent-work/followups.md`, filas B2/T5).

## Elección: (a), con evidencia de la arena

**Elegido: (a) el reintento nativo ES la recuperación.** Se cobra el fondo en el reintento del runner y no se relanza nada por la cola.

Comparación de la arena, candidato por candidato:

| Eje | (a) reintento nativo | (b) relanzo desde el terminal |
|---|---|---|
| Los cuatro candados | Nunca se consultan: el run no re-entra al gateway, al registro ni a la admisión; el reintento es continuación del transcript dentro del run ya admitido (attempt-recovery.ts:435-437) | Necesita pasar los cuatro con el mismo runId: pasa, pero solo después de crear cinco contratos nuevos (ver abajo) |
| Cambios en el gateway | Ninguno | Uno con riesgo real: retirar la entrada de dedupe terminal (`agent-dedupe.ts` nuevo) porque sin ella `replayAgentTurnIfCached` (agent-turn-service.ts:69) reproduce el caché del run muerto y no arranca nada |
| Cambios en el registro | Ninguno | Re-encolar una fila terminal a `queued` con la misma generación (método nuevo), en tensión con la valla de filas retenidas (subagent-registry.ts:416-420, "never revive a retained row") y con carreras de kill/reemplazo que (b) mismo lista como riesgo |
| Superficie nueva total | 2 funciones + 1 variante de unión JSON + mover 1 helper. Líneas netas: negativas | Campo durable `recoveryLaunch`, hook terminal, método de re-encolado, helper de dedupe, gate en attempt-recovery, 2 operaciones de worker, reconciliación de arranque |
| Absorción de blips | Se conserva: el reintento nativo sigue absorviendo cortes breves y 429 sin costo | Se pierde: cada blip de proveedor terminaliza el run y gasta un episodio; con `maxAutomaticRecoveryCalls: 1`, un solo blip mata la tarea |
| Cubrir el caso cross-restart | No lo cubre: si el proceso muere a mitad de reintento, el run cae a su TTL por los caminos existentes | Lo cubre (fila queued durable + reconciliación de arranque) |
| Carrera estructural del punto de partida | Desaparece: la concesión se espera dentro del asentamiento, antes de que `stream.result()` devuelva | Se mueve: el hook vive después de `releaseSwarmRun` (swarm-scheduler.ts:359 borra `runLocations`) |
| "No abras supervisores ni scouts" | Cumplido por construcción: cero componentes nuevos en arranque | La reconciliación de arranque (`listOpenRecoveryEpisodes` + escaneo) es un componente nuevo que corre en cada arranque |

(b) pasa las tres prohibiciones del encargo (lo verificó su corredor: no crea fila en `managed_tasks`, no usa el turno del solicitante, no encola con slot activo) y su camino por los cuatro candados es correcto. Pierde por costo y por alcance: compra cobertura cross-restart que la casilla no pide, pagando con un cambio de comportamiento del gateway (retiro temprano de dedupe terminal), una transición nueva de fila en el registro y la pérdida de la absorción en-turno de blips. (a) logra la casilla con líneas netas negativas y ningún contrato nuevo entre subsistemas.

De (b) se injertan al diseño final tres cosas: la documentación del hueco cross-restart como renuncia declarada (el marcador y la piscina quedan listos para un relanzador futuro sin cambio de esquema), el detalle de que el retiro de dedupe sería el paso crítico de cualquier (b) futuro, y el requisito de que las pruebas E2E usen dedupe real del gateway en proceso.

## Tesis del diseño elegido

La concesión `managedTasks.beginRecovery` se espera dentro del asentamiento del stream caído (reemplazo del `void` en `managed-task.provider-stream.ts:243-249`), de modo que el marcador `recovery:<taskId>` es durable antes de que `stream.result()` devuelva. El reintento que el runner embebido ya ejecuta (`attempt-recovery.ts:375-437`, hasta 8 intentos en 90 s) re-resuelve el binding en cada intento (`attempt-stream-settle.ts:473`) y lo encuentra con `recovery: true`; el mismo run continúa en su propio slot del scheduler. No se relanza nada, no se registra ningún builder, y el fondo de recuperación se cobra una vez por episodio: el marcador es la carga.

**Cerrojo del reintento (delta r2).** El reintento nativo solo es camino de recuperación cuando el asentamiento CONCEDE. Cuando no concede (corrida ya recuperada con `binding.recovery`, rehusa por `already-granted` o `recovery-budget-exhausted`, o tarea `settled`/`cancelled`), el asentamiento marca el mensaje con el diagnóstico `managed_recovery_exhausted` y la decisión de reintento del runner deja de clasificar esa falla como reintentable: la marca gatea el `failureReason` completo derivado del asistente (attempt-recovery.ts:308-319), no solo la rama del diagnóstico de transporte, porque las fallas de transporte reales se clasifican antes por texto o código en la rama `assistantFailure?.kind === "reason"` (:310-311). Cero llamadas al proveedor después de una falla sin concesión. Sin la marca (corridas no gestionadas, o concesión lograda), la decisión es exactamente la de hoy.

## Shape

```ts
// src/agents/tasks/managed-task.recovery.ts (reescrito, queda ~30 líneas)
// Se borran: ManagedTaskRecoveryRelaunch, ManagedRecoveryRelaunchBuilder,
// relaunchBuilder, configureManagedTaskRecoveryRelauncher,
// scheduleManagedTaskRecovery y el import de enqueueSwarmRun.

/** Concede un episodio de recuperación; las rehusas son retorno normal, no error. */
export async function grantManagedTaskRecovery(
  binding: ManagedProviderRunBinding,
): Promise<ManagedTaskRecoveryReceipt> {
  // not implemented: executeOpenClawStateWorker managedTasks.beginRecovery
  // con { taskId, nativeRunId, nativeGeneration } (mismo input que hoy :39-46).
}

/** Recibo durable de falla de transporte después de conceder. */
export async function recordManagedRecoveryIncident(
  binding: ManagedProviderRunBinding,
): Promise<ManagedTaskIncidentReceipt | null> {
  // not implemented: executeOpenClawStateWorker managedTasks.recordRecoveryIncident.
  // null cuando no hay marcador (defensivo; binding.recovery implica marcador).
}
```

```ts
// src/agents/tasks/managed-task.provider-stream.ts
// :97-102 chargesRecoveryFund se BORRA. :141 queda:
//   automaticRecovery: reservations.length > 0,
// (un re-despacho SDK dentro de la misma invocación de stream reclama el fondo;
//  una llamada nueva del run recuperado cobra presupuesto normal).
// :243-249 el void se reemplaza, dentro del settlement que ya se espera en :251
// antes de devolver result:
//
//   if (transportFailed && result.stopReason === "error") {
//     try {
//       if (binding.recovery) {
//         // Segunda falla de una corrida ya recuperada: sin concesión posible.
//         markManagedRecoveryExhausted(result, { taskId: binding.taskId, reason: "already-recovered" });
//         await recordManagedRecoveryIncident(binding);
//       } else {
//         const receipt = await grantManagedTaskRecovery(binding);
//         if (receipt.state === "granted") {
//           // El reintento nativo ES la recuperación: sin marca; attempt-recovery
//           // clasifica transient_retry como hoy.
//         } else if (receipt.state === "refused" && receipt.reason === "already-granted") {
//           // Binding capturado antes de una concesión previa del episodio
//           // (p. ej. compactación, que resuelve el binding una vez y reusa el
//           // stream en su bucle): la falla es post-concesión → recibo.
//           markManagedRecoveryExhausted(result, { taskId: binding.taskId, reason: "already-granted" });
//           await recordManagedRecoveryIncident(binding);
//         } else {
//           // settled / cancelled / recovery-budget-exhausted: sin concesión → sin reintento.
//           markManagedRecoveryExhausted(result, { taskId: binding.taskId, reason: receipt.reason });
//         }
//       }
//     } catch (error) {
//       console.warn(`[managed-task] Failed to finalize recovery for task ${binding.taskId}: ...`);
//       // Fail-open (Tradeoff 5): sin marca, el runner decide como hoy.
//     }
//   }
```

```ts
// src/agents/embedded-agent-runner/run/attempt-retry-gate.ts (nuevo, hoja: solo
// importa los helpers de diagnóstico de packages/ai y los tipos de llm-core, así
// que el runner y tasks/ pueden importarla sin ciclo).
export const MANAGED_RECOVERY_EXHAUSTED_DIAGNOSTIC = "managed_recovery_exhausted";

export function markManagedRecoveryExhausted(
  message: AssistantMessage,
  details: { taskId: string; reason: string },
): void {
  // not implemented: appendAssistantMessageDiagnostic(message,
  //   createAssistantMessageDiagnostic(MANAGED_RECOVERY_EXHAUSTED_DIAGNOSTIC,
  //     new Error(`managed recovery exhausted: ${details.reason}`), details));
}

export function hasManagedRecoveryExhaustedDiagnostic(
  message: { diagnostics?: AssistantMessageDiagnostic[] } | null | undefined,
): boolean {
  // not implemented: Boolean(message?.diagnostics?.some(
  //   (diagnostic) => diagnostic.type === MANAGED_RECOVERY_EXHAUSTED_DIAGNOSTIC));
}

// La excepción en src/agents/embedded-agent-runner/run/attempt-recovery.ts:308-319.
// La marca gatea el failureReason COMPLETO del lado assistant, porque la rama
// `assistantFailure?.kind === "reason"` (:310-311) clasifica las fallas de
// transporte reales antes de llegar a la rama del diagnóstico (:312-318): el
// texto del corte ("terminated", TERMINATED_TRANSPORT_MESSAGE_RE en
// message-patterns.ts:33; "fetch failed" :174; "socket hang up" :175) o el código
// (isTransientNetworkError sobre UND_ERR_SOCKET / ECONN*, retryable-network-errors.ts)
// cae en { kind: "reason", reason: "timeout" } vía classifyFailoverSignal
// (classify-core.ts:188-190), y sin status 4xx no hay downgrade sameModelRetry,
// así que la puerta :394 pasa y maybeRetryTransient acepta "timeout"
// (failover-retry-controller.ts:297-306). Además, para un corte a mitad de
// stream con contenido parcial NI SIQUIERA se agrega provider_transport_failure
// (transport-stream-shared.ts:538 exige content.length === 0), así que la marca
// no puede colgar de ese diagnóstico: por eso se computa aparte y decide antes.
//
//   const managedRecoveryExhausted =
//     hasManagedRecoveryExhaustedDiagnostic(attemptAssistant);
//   const failureReason = promptError
//     ? failoverReasonFromClassification(retryFailure)
//     : managedRecoveryExhausted && !idleTimedOut
//       ? null
//       : assistantFailure?.kind === "reason"
//         ? assistantFailure.reason
//         : idleTimedOut ||
//             (attemptAssistant &&
//               isRetryableAssistantError(attemptAssistant) &&
//               attemptAssistant.diagnostics?.some(
//                 (diagnostic) => diagnostic.type === "provider_transport_failure",
//               ))
//           ? "timeout"
//           : null;
//
// Con marca y sin idle timeout: failureReason null → recoveryReason null en
// :375 → la puerta de maybeRetryTransient (:395-396) no se abre → cero
// reintentos de transporte. idleTimedOut conserva su vía (recuperación por
// timeout, otro mecanismo). Hairline declarado: recoverEmbeddedRunTimeout
// (:360-374) acepta antes de esta puerta sin consultar failureReason; contrived
// (el watchdog suele dejar stopReason "aborted", que no se marca).
```

```ts
// src/agents/tasks/managed-task.types.ts
export type ManagedTaskIncident =
  | { kind: "permission-required"; promptIdentity: string; evidenceRef: string }
  | { kind: "recovery-transport-failure"; episodeId: string };

// En ManagedTaskWorkerOperations se agrega:
"managedTasks.recordRecoveryIncident": {
  input: { taskId: string; nativeRunId: string; nativeGeneration: number };
  output: ManagedTaskIncidentReceipt | null;
};
```

```ts
// src/agents/tasks/managed-task.budget.shared.ts
// countRootRecoveryGrants se MUEVE aquí desde recovery.worker.ts:30-52 y se exporta:
export function countRootRecoveryGrants(
  database: OpenClawStateDatabase,
  rootTaskId: string,
): number; // not implemented (mismo SELECT de hoy: marcadores de raíz e hijos)
```

```ts
// src/agents/tasks/managed-task.budget.worker.ts, reserveModel :481-491
// La condición de recuperación pasa de
//   used.recovery + Number(input.bound.automaticRecovery) > profile.maxAutomaticRecoveryCalls
// a la piscina única:
//   used.recovery + countRootRecoveryGrants(database, rootTaskId)
//     + Number(input.bound.automaticRecovery) > profile.maxAutomaticRecoveryCalls
// (sigue lanzando "Managed model tree budget exhausted").

// readManagedTaskBudgetSummary :398:
//   automaticRecoveryCalls: countRootRecoveryGrants(database, rootTaskId)
//     + sum(charged.recovery)   // la misma piscina, una sola vía.
```

```ts
// src/agents/tasks/managed-task.recovery.worker.ts
export function recordRecoveryIncident(
  input: ManagedTaskWorkerOperations["managedTasks.recordRecoveryIncident"]["input"],
  owner: OpenClawStateDatabase,
): ManagedTaskIncidentReceipt | null {
  // not implemented, transacción:
  // 1. exige fila admitted con native_run_id/native_generation del input
  //    (mismo patrón que resolveManagedProviderRunInWorker :335-347; SIN token
  //    y SIN exigir liveness: el recibo debe poder escribirse aunque el run
  //    acabe de morir).
  // 2. exige marcador recovery:<taskId> (sin episodio no hay recibo que dar).
  // 3. upsert en managed_task_incidents con incident_key = episodio del marcador
  //    y digest = sha256 del JSON estable { kind, episodeId }; digest igual
  //    existente es no-op, distinto es error de conflicto (patrón de
  //    reportIncident :422-444).
}

// El dispatch: BudgetOperation en budget.worker.ts:59/:70 gana el caso
// "managedTasks.recordRecoveryIncident" en executeManagedTaskBudgetCommand
// (:553-575) y la lista de ruteo en openclaw-state-worker-runtime.ts:188-198.
```

```ts
// src/agents/tasks/managed-task.json.ts :100-104
// incident pasa de strictObject único a unión discriminada por kind con los
// dos miembros de ManagedTaskIncident. Las filas viejas permission-required
// siguen parseando; inspect (:464-472) no cambia.
```

Invariante central del dominio: el fondo de recuperación es una piscina por raíz con `maxAutomaticRecoveryCalls` unidades, y cada unidad la consume exactamente uno de dos hechos: un episodio concedido (marcador) o un re-despacho SDK dentro de una invocación de stream (`automaticRecovery: true`). Una sola función (`countRootRecoveryGrants` + `charged`) alimenta las tres consultas: el gate de `beginRecovery` (`rootRecoverySpent`, recovery.worker.ts:21-28), el gate de `reserveModel` y el resumen de inspect. Sobre-concesión imposible: toda consumición pasa por una de esas dos guardas en transacción.

## Respuestas 1-10

**1. Registro y reinicio en caliente.** No queda ningún builder ni hook por registrar: el único sitio de concesión es el asentamiento del stream gestionado (provider-stream.ts:243-249 reemplazo), alcanzado desde cada intento gestionado vía attempt-stream-settle.ts:473-478 y desde compactación vía compaction-session-execution.ts:251. En caliente no hay gateway que reclamar: el reintento vive en el bucle del runner embebido del propio proceso. Tras un reinicio, el bucle muere con el proceso; el restorer llega tarde (subagent-registry.ts:402-404; activación en server-startup-post-attach.ts:1026-1033) y no revive filas retenidas (subagent-registry.ts:416-420); el run caído termina por su TTL y la tarea se asienta por el path de reporte normal. Lo durable que sobrevive: marcador, waits, incidencia y presupuesto (sqlite). Renuncia declarada (Tradeoff 1): sin recuperación cross-restart; el marcador y la piscina quedan listos para un relanzador futuro sin cambio de esquema.

**2. La petición o el reintento: los cuatro candados.** Este diseño no necesita pasarlos porque nunca re-entra a la superficie que custodian. No hay petición nueva al gateway, así que el preflight que exige `swarmLaunchPending === true` o dedupe (agent-request-preflight.ts:154-168) no se consulta; no hay `idempotencyKey` nuevo (preflight:212, dedupe de 5 min en server-constants.ts:16 y agent-dedupe.ts:18) porque no hay request; no hay registro nuevo, así que `swarmLaunchIdempotencyKey === idempotencyKey` (subagent-registry-memory.ts:511-514) y `startQueuedSubagentRun` solo-fila-queued (subagent-registry-run-launch.ts:241-277) no aplican; y no hay segunda admisión: el reintento re-resuelve la MISMA admisión admitted con `native_run_id`/`native_generation` (budget.worker.ts:335-347) y una segunda admisión seguiría lanzando "already has an admission claim" (managed-task.admission.worker.ts:366-376, confirm con otro binding :469-475). El reintento ocurre por debajo de los candados, dentro del run ya admitido: `retry()` (attempt-recovery.ts:435-437) es continuación de transcript, no despacho.

**3. El slot y el scheduler.** Nunca se encola un runId con su slot activo porque el único `enqueueSwarmRun` de tasks/ se borra (managed-task.recovery.ts:50); el scheduler por su parte lanza "swarm scheduler run already exists" si el runId ya está en `runLocations` (swarm-scheduler.ts:346-348, vía reserveSwarmRun :263-278). En gestionadas `schedulerSlotId = runId = childIdem` (subagent-spawn.ts:119, gateway/agent-turn/agent-request-preflight.ts:212, subagent-registry-run-launch.ts:290-291) y el slot solo se libera al terminal (subagent-registry-terminal-effects.ts:127-129): durante la recuperación in-run el slot permanece activo, el carril no ve capacidad nueva y los hermanos esperan su FIFO. Doble gasto imposible: hay un solo camino de concesión (el asentamiento, con guardia `!binding.recovery`) y una sola piscina transaccional (`beginRecovery` rehusa `already-granted`, recovery.worker.ts:87-89, y `recovery-budget-exhausted` :92-94); no existe relanzo que corra en paralelo. Y el gasto post-falla también está cercado (delta r2): una falla de transporte sin concesión llega marcada con `managed_recovery_exhausted`, la decisión del runner (gate del `failureReason` completo en :308-319) no clasifica la falla como reintentable, y ninguna llamada nueva toca el proveedor ni el presupuesto. Sobre la sesión hija tampoco hay carrera: el reintento (que solo ocurre tras concesión) continúa el transcript existente (attempt-recovery.ts:431-433); jamás se crea una segunda sesión o request para el mismo run.

**4. El estado legible.** Mientras la recuperación está en vuelo, `readManagedTaskWait` deriva `waiting: null`: el wait de falla fue cerrado por la concesión (recovery.worker.ts:105-137), los waits prefijados `recovery:` están excluidos (wait.worker.ts:51-52) y `queue-busy` exige fila `queued` con la misma generación (wait.worker.ts:96-108) mientras el run está activo. Es el estado honesto: el run está trabajando (reintentando), no esperando. Si el run recuperado muere por transporte, `recordManagedTransportFailure` (budget.worker.ts:248-294) abrió un wait nuevo que sí se lee (`cause: "transport-unavailable"`) y el recibo aparece en `incidents`. Si la concesión se rehusa por presupuesto, el wait de falla original queda abierto y visible. El registro no revive filas retenidas (subagent-registry.ts:416-420), así que ninguna lectura retrospectiva miente.

**5. El binding después de conceder.** Sí basta la re-resolución por intento (attempt-stream-settle.ts:473). Orden exacto: (i) el intento fallido liquida y espera la concesión dentro de `stream.result` antes de devolver (provider-stream.ts:205-253, `await settlement` en :251); (ii) attempt-recovery clasifica y acepta el reintento (sin marca, attempt-recovery.ts:308-319, :396-427); (iii) el intento nuevo re-resuelve en :473 y el worker ve el marcador (budget.worker.ts:348-361) y devuelve `recovery: true`, con el que :477-478 envuelve. La carrera con el `void` actual desaparece porque el `void` se borra: la concesión es parte del asentamiento esperado. El chequeo existente recovery.test.ts:323-325 (`recovery: true`) se conserva como variante restart; lo nuevo es el orden (marcador durable antes de que devuelva `result`), pineado sin `vi.waitFor`.

**6. El recibo de falla después de conceder.** Kind nuevo en la unión JSON: `{ kind: "recovery-transport-failure", episodeId: "recovery:<taskId>" }` en managed-task.json.ts:100-104 (unión discriminada; las filas viejas `permission-required` siguen parseando en inspect, managed-task.worker.ts:464-472). Ampliar esa unión NO es cambio de esquema (la tabla guarda JSON validado por la app, openclaw-state-schema.sql:1657-1664). La operación de worker que escribe sin token es la nueva `managedTasks.recordRecoveryIncident` (implementada en recovery.worker.ts, despachada por executeManagedTaskBudgetCommand budget.worker.ts:553-575 y ruteada en openclaw-state-worker-runtime.ts:188-198): valida identidad de admisión admitted con `native_run_id`/`native_generation` (patrón de budget.worker.ts:335-347) sin token de productor y sin exigir liveness, exige el marcador y hace upsert con digest estable (patrón de reportIncident :422-444, que sigue siendo el único insert con token, :436). Cierre del hueco de binding añejo: si el asentamiento corre con un binding capturado antes de la concesión (compactación resuelve el binding una vez en compaction-session-execution.ts:243-251 y reusa el stream en su bucle :259/:306), el grant vuelve `already-granted` y la rama del asentamiento continúa a `recordManagedRecoveryIncident`, así que la falla post-concesión deja recibo aunque el binding diga `recovery: false`. Por qué una espera `transport-unavailable` no basta: `readManagedTaskWait` devuelve una sola espera sin liga al marcador ni a la concesión (wait.worker.ts:45-81) y el encargo exige el recibo durable con la causa; además pueden existir varios waits de falla por hash de reserva (budget.worker.ts:268-288) y ninguno dice "esto pasó después de conceder".

**7. Los eventos de capacidad.** No hay bus y este diseño no añade entrada: la recuperación ocurre dentro del ciclo real del slot. El slot del run caído se libera exactamente donde siempre, en el terminal (terminal-effects.ts:127-129), y ese `releaseSwarmRun` es el evento que alimenta la cola: borra `runLocations` (swarm-scheduler.ts:359), publica el cambio de capacidad del carril y llama `pumpLane` (swarm-scheduler.ts:352-364, bombeo :205-226). `onStartFailure` con false sigue reencolando al frente con timer de 1 s (:172-181) para fallos de arranque de filas nuevas; con true libera (:158-161). El feed `run-capacity` hacia el registro queda intacto (bindSwarmRunReservation :281-292, consumido en subagent-registry-run-launch.ts:166-176). "Recuperación sobre la cola nativa": el run caído nunca salió de la contabilidad de la cola (su slot siguió activo), así que la recuperación reusa ese slot en vez de fabricar una segunda entrada; cuando el run termina, el único evento de capacidad de su vida dispara el bombeo para los hermanos.

**8. Con la config apagada.** Con `managedTasks.enabled` ausente o false, `resolveManagedTaskHostCapability` devuelve undefined (managed-task.host.ts:15-18) y solo se pierde la capability del host para tareas nuevas (consumida en run-attempt-dispatch.ts:424). Ni `beginRecovery` ni el binding leen config (budget.worker.ts:296-362 y recovery.worker.ts:54-143 no tocan config, verificado). Una corrida gestionada en vuelo ya tiene su binding; su falla de transporte concede, cobra la piscina y reintenta igual con la config apagada. Regla B4-1 cumplida por construcción: la decisión de gestionada la toma la respuesta del binding/worker durable, jamás la config global. La prueba P8 lo pina con la config explícitamente ausente.

**9. Multi-llamada.** Una sola carga al fondo por episodio y las llamadas siguientes cobran presupuesto normal. Mecánica: el marcador ES la carga del episodio (cuenta en `rootRecoverySpent`, recovery.worker.ts:21-28); las llamadas nuevas del run recuperado dejan de reclamar el fondo (`automaticRecovery: reservations.length > 0`, es decir solo re-despachos SDK dentro de la invocación); la guardia de `reserveModel` se convierte en la piscina única `used.recovery + marcadores + Number(automaticRecovery) > tope` (budget.worker.ts:488-490) y `usage.automaticRecoveryCalls` muestra esa misma piscina. El ruteo alternativo en el worker (cobrar al fondo solo si `used.recovery < tope`, si no cobrar normal) se rechazó: el worker no puede distinguir "segunda llamada nueva del run recuperado" (debe pasar) de "segundo re-despacho SDK" (debe bloquear); ambos llegan como `automaticRecovery: true` con la piscina llena, y el ruteo voltearía los pins vigentes budget.test.ts:332 y provider-stream.test.ts:642. La información que falta (re-despacho vs llamada nueva) vive en el borde del stream (`reservations.length`), así que la decisión se toma ahí y el worker conserva una guarda única en forma de piscina. Cerrojo (delta r2): tras una falla sin concesión, no hay "llamadas siguientes" que cobrar, porque la decisión del runner no reabre el reintento (marca `managed_recovery_exhausted`, gate del `failureReason` completo en :308-319); las llamadas posteriores solo existen dentro del intento concedido. Qué pasa con el pin recovery.test.ts:635-648: el aserto de la reserva manual (`rejects.toThrow("Managed model tree budget exhausted")`) SIGUE igual porque esa reserva es una reclamación explícita del fondo y la piscina está llena (marcador); lo que cambia es que el run recuperado ya no muere en su segunda llamada, que es exactamente lo que la fila B2/T5 (semántica multi-llamada) pide probar. Qué pasa con la fila B2/T5 (gate): las dos vías se unifican en una (marcadores + re-despachos cobrados contra el mismo tope, consultados por la misma función en los tres sitios); nunca sobre-concede porque toda consumición pasa por una guarda transaccional; con perfil 2 caben dos unidades cualesquiera (episodios o re-despachos), comportamiento que la prueba de piscina deja fijado.

**10. Esquema.** No se necesita tabla ni columna nueva y no se sube `PRAGMA user_version` (queda 27, openclaw-state-db-contract.ts:29). Ampliar la unión de incidencias en managed-task.json.ts:100-104 con el kind nuevo NO es cambio de esquema. La operación nueva es código de worker, no DDL. No hay que repetir B4-2.

## Pruebas de aceptación para B4-6

Todas en `src/agents/tasks/managed-task.recovery.test.ts` salvo indicación. Camino de producción: `wrapManagedProviderStream` contra proveedor scriptable con HTTP real (helpers existentes `scriptableProvider`/`admittedRun`); PROHIBIDO `configureManagedTaskRecoveryRelauncher` (la función deja de existir); el único doble es el servidor HTTP del transporte. La acción del "reintento" la hace el test re-resolviendo el binding y llamando el stream de nuevo (lo que el runner hace en attempt-stream-settle.ts:473), y la DECISIÓN de reintento pasa por el camino real del runner: el mensaje asentado alimenta el arnés de `recoverAfterTransportDrop` (attempt-recovery.test-support.ts:57-99) y la aserción mira `recovery.action` (attempt-recovery.test.ts:49-57). `scriptableProvider` sujeta los pasos al último (`steps[Math.min(stepIndex, steps.length - 1)]`, recovery.test.ts:102): toda secuencia que necesite una falla posterior la declara explícitamente en sus steps.

**Preparación común.** `admittedRun()` deja la fila nativa con `execution.status: "queued"` (subagent-registry-run-launch-record.ts:105-109) y no la lanza. Toda prueba que aserte `waiting === null` (estado de producción durante el reintento) debe primero pasar la fila a `running` con un `json_set` de `$.execution.status` (el mismo mecanismo SQL crudo que recovery.test.ts:492-496 usa para congelar a terminal). Con la fila congelada en `queued`, la derivación honesta post-concesión es `queue-busy` (wait.worker.ts:96-108): hay prueba que lo pina (variante de P4).

**TD (decisión del runner ante la marca; delta r2).** En `src/agents/embedded-agent-runner/run/attempt-recovery.test.ts`. it: `"does not transient-retry a transport failure marked managed_recovery_exhausted"`. Tres variantes con el arnés de `recoverAfterTransportDrop` (attempt-recovery.test-support.ts:57-99, campo `scenario.diagnostics` en :74):
(a) CASO PRIMARIO, mensaje clasificable por texto + marca: `errorMessage: "terminated"` (el mensaje real del corte; la clasificación por texto lo manda a `{ kind: "reason", reason: "timeout" }` por la rama :310-311, ver attempt-recovery.test.ts:581-585 donde un texto de transporte reintenta con `diagnostics: []`) y `diagnostics: [{ type: "managed_recovery_exhausted", details: { taskId, reason: "recovery-budget-exhausted" } }]`. Aserción: `recovery.action` toEqual `{ action: "proceed" }` (el precedente del arnés: no reintentable → proceed, attempt-recovery.test.ts:49-57) y sin evento `run_status` con `phase: "retrying"`.
(b) CONTROL, mismo mensaje sin la marca: `recovery.action === "retry"` (el reintento por clasificación de texto, comportamiento de hoy).
(c) Tercera rama: `errorMessage: "WebSocket error"` (no clasificable por texto; sin marca el default del arnés reintenta por el diagnóstico, test-support :73-81) con `diagnostics: [{ type: "provider_transport_failure", ... }, { type: "managed_recovery_exhausted", ... }]` (AMBOS) → desenlace terminal sin reintento (cubre la rama del diagnóstico de transporte, que también queda gateada; con solo la marca la variante sería vacua).
Corrida no gestionada: sin marca, sin cambio (la marca solo la pone el asentamiento gestionado). Mutación: quitar el gate de la marca en attempt-recovery.ts:308-319 (revertir al ternario de hoy, o dejarlo solo en la tercera rama como versión rota): la variante (a) clasifica `"timeout"` por la rama :310-311 y da `action === "retry"`, rojo.

**P1 (orden y durabilidad de la concesión, sin carrera; también cubre el punto 5).** it: `"grants recovery before the failed stream result returns and the marker survives restart"`. Prep: `admittedRun()`, fila pasada a `running`, provider steps `[cut-headers, complete]`, binding inicial `recovery: false`. Acción: stream 1, `drain`, `(await stream.result()).stopReason === "error"`; inmediatamente (sin `vi.waitFor`) consultar `SELECT episode_id FROM managed_task_waits WHERE episode_id = 'recovery:<taskId>'` y re-resolver el binding. Aserciones: fila presente; `await resolveManagedProviderRunBinding(...)` toMatchObject `{ recovery: true }`; luego `closeOpenClawStateDatabaseForTest()`, stream recuperado (complete) da `stopReason === "stop"`, `provider.requests` 2; sonda `grantManagedTaskRecovery(binding2)` devuelve `{ state: "refused", reason: "already-granted" }` y `provider.requests` sigue 2. Mutación canónica: provider-stream.ts:243-249 eliminar la llamada a `grantManagedTaskRecovery`: la aserción de marcador inmediato y el `recovery: true` se ponen rojos. Mutación secundaria (no determinista por timing, solo complementaria): reemplazar el `await` por `void`.

**P2 (los candados no se necesitan; punto 2).** it: `"recovers without a second admission, gateway entry, or queue row"`. Prep: flujo de P1 (fila a `running`); además falla del stream recuperado (steps `[cut-headers, complete, cut-headers]`) para dejar el run con episodio consumido y recibo escrito. Aserciones: `SELECT run_id FROM subagent_runs` sigue `[{ run_id: NATIVE_RUN_ID }]`; `claimManagedTaskAdmission` con admissionKey nueva `rejects.toThrow("already has an admission claim")`; reclamo con la admissionKey original devuelve `{ state: "admitted", nativeRunId: NATIVE_RUN_ID, nativeGeneration: 1 }` (adaptación de recovery.test.ts:655-692); `incidents` contiene exactamente el recibo del episodio. Mutación: permitir la segunda admisión en managed-task.admission.worker.ts:366-376 (la aserción de claim se pone roja). La imposibilidad de re-entrada por cola se pina en P3, único lugar cuyo prep registra el slot.

**P3 (el slot; punto 3).** it: `"holds the crashed run's scheduler slot through its native retry"`. Prep: `enqueueSwarmRun` con `runId: NATIVE_RUN_ID`, `maxConcurrent: 1` (el propio slot del run, registrado en el scheduler) y un hermano en cola tras él; provider `[cut-headers, complete]`. Acción: falla, concesión, stream recuperado completo. Aserciones: `isSwarmRunActive(NATIVE_RUN_ID) === true` justo después del asentamiento fallido (durante la recuperación) y después del stream recuperado; `provider.requests` 2 (solo las llamadas del propio run); el hermano NO arrancó; tras `releaseSwarmRun(NATIVE_RUN_ID)` (terminal simulado) el hermano arranca; y documentación directa del candado: `expect(() => enqueueSwarmRun({ groupId: groupKey(), runId: NATIVE_RUN_ID, maxConcurrent: 1, activeRunIds: [], start: async () => {}, onStartFailure: () => true })).toThrow("swarm scheduler run already exists")` mientras el slot sigue activo. Mutaciones: añadir `releaseSwarmRun(binding.nativeRunId)` en el asentamiento fallido de provider-stream.ts (el reflejo de un relanzo): `isSwarmRunActive` da false y el hermano arranca antes de tiempo, rojo; o quitar el throw de swarm-scheduler.ts:346-348: la aserción del mensaje exacto se pone roja (con el slot activo, `activateSwarmRun` fallaría con otro mensaje, "swarm scheduler reservation missing", swarm-scheduler.ts:320-321).

**P4 (estado legible; punto 4).** it: `"shows no wait while the recovered retry runs, then the transport wait and incident when it dies"`. Prep: flujo P2 con la fila a `running` (preparación común); luego steps `[cut-headers, complete, cut-headers]`. Aserciones: justo tras la concesión `(await inspectManagedTask({ caller, taskId })).waiting === null` (run trabajando, no esperando); tras la falla del stream recuperado, `waiting` toMatchObject `{ cause: "transport-unavailable" }` y `incidents[0]` toMatchObject `{ kind: "recovery-transport-failure", episodeId: "recovery:<taskId>" }`. Variante documentada: con la fila congelada en `queued` (sin la preparación común), la misma derivación da `queue-busy` (wait.worker.ts:96-108), que es el estado honesto de una fila encolada; aserción `waiting` toMatchObject `{ cause: "queue-busy" }`. Mutación: quitar la exclusión `recovery:` en managed-task.wait.worker.ts:51-52: tras conceder, `waiting` pasa a ser el wait-marcador y la aserción `waiting === null` roja.

**P5 (binding tras conceder; punto 5).** Cubierto por P1 (re-resolución con `recovery: true` atada al orden concesión-antes-de-result). recovery.test.ts:323-325 existente se conserva como variante restart y no cuenta como prueba nueva.

**P6 (recibo durable; punto 6).** it: `"persists the post-grant failure receipt across restart"`. Prep: flujo P1 (fila a `running`, steps `[cut-headers, complete, cut-headers]`). Acción y aserciones: tras el stream recuperado completo, la tercera llamada (segunda falla) se asienta con el binding VIEJO (`recovery: false` capturado antes de conceder, la forma real de compactación, compaction-session-execution.ts:243-251/:259/:306): la rama `already-granted` del asentamiento escribe el recibo; `closeOpenClawStateDatabaseForTest()` y reabrir; `inspect` muestra `incidents[0].kind === "recovery-transport-failure"`; exactamente una fila en `SELECT incident_key FROM managed_task_incidents` (dedupe por episodio: repetir el asentamiento añejo no añade fila). Espera declarada: tras la repetición, `waiting` vuelve a `{ cause: "transport-unavailable" }` (el transporte falló de verdad y no hay concesión que cierre el wait nuevo). Por qué el wait no basta: sin la incidencia, la aserción de P4 solo vería una espera sin liga al marcador. Mutación canónica: eliminar SOLO la sub-rama `already-granted` de provider-stream.ts:243-249 (el asentamiento añejo queda en grant no-op): `incidents` queda `[]`, rojo. Mutación secundaria: eliminar `recordManagedRecoveryIncident` completo.

**P7 (eventos de capacidad; punto 7).** Cubierto por P3 (bombeo del hermano solo tras `releaseSwarmRun`). Mutación adicional: quitar el `pumpLane` de swarm-scheduler.ts:352-364: el hermano nunca arranca tras la liberación, rojo.

**P8 (config apagada; punto 8).** it: `"recovers a managed run with managedTasks configuration absent"`. Prep: igual a P1; aserción previa `resolveManagedTaskHostCapability(undefined) === undefined` (y el arnés no configura `managedTasks`, que ya es el default del test). Aserciones: las de P1 (marcador, `recovery: true`, stream recuperado `stop`, piscina 1). Mutación: gatear `grantManagedTaskRecovery` con `if (!config?.managedTasks?.enabled) return { state: "refused", reason: "settled" }`: el marcador nunca aparece, rojo. Pina la regla B4-1 (decisión por binding, no por config).

**P9 (multi-llamada y bloqueo durable; punto 9).** Tres its.
(a) `"finishes a recovered run of two model calls with the fund charged once"`: provider `[cut-headers, complete, complete]`, perfil del arnés (`maxAutomaticRecoveryCalls: 1`); falla, concesión, binding2 `recovery: true`; stream recuperado llamada A `stopReason === "stop"` y llamada B `stopReason === "stop"`; aserciones `provider.requests` 3, `budget.usage.modelCalls === 3`, `budget.usage.automaticRecoveryCalls === 1`, un solo marcador. Mutación (obligatoria del encargo, "volver a cobrar el fondo en cada llamada"): provider-stream.ts:141 volver a `automaticRecovery: binding.recovery || reservations.length > 0`: la reserva de B lanza "Managed model tree budget exhausted", B termina `"error"`, rojo.
(b) `"refuses the recovery episode when charged claims already spent the fund"` (adaptación de :331-393 por el camino de producción): reservar a mano `callKey: "sdk-retry-charge"` con `automaticRecovery: true` (consume la piscina), provider `[cut-headers]`; el asentamiento pide la concesión y recibe `{ state: "refused", reason: "recovery-budget-exhausted" }`, MARCA el mensaje (`diagnostics` contiene `type: "managed_recovery_exhausted"` con `details.reason === "recovery-budget-exhausted"`). Aserciones en dos planos. Plano stream: `provider.requests === 1` y nadie re-invoca el stream después del asentamiento (el conteo es del servidor scriptable; la decisión del runner no despacha HTTP por sí misma). Plano decisión: el mensaje marcado alimenta el arnés de TD (`recovery.action` terminal sin reintento, sin fase `retrying`). `waiting` toMatchObject `{ cause: "transport-unavailable" }` (el wait sobrevive porque no hay concesión que lo cierre). Nota declarada: con el cerrojo de r2, tras la rehusa no hay reintentos del controller en absoluto (antes el runner seguía llamando con presupuesto normal); el test LO PINA por la decisión, no por el contador HTTP. Mutaciones: (i) en recovery.worker.ts:23-25, quitar de `rootRecoverySpent` el término de reservas cobradas: `rootRecoverySpent` da 0, la concesión pasa, aparece el marcador, el wait se cierra y el `waiting` vira a `queue-busy` (fila del arnés en `queued`), rojo; (ii) el asentamiento no marca el mensaje (provider-stream.ts, quitar las ramas `markManagedRecoveryExhausted`): la decisión clasifica `"timeout"` por texto (:310-311) y `recovery.action === "retry"`, rojo.
(c) `"charges the unified pool once per episode with a sibling refused"` en managed-task.recovery.siblings.test.ts: adaptar :166-192 cambiando `scheduleManagedTaskRecovery` por `grantManagedTaskRecovery` (primer hermano `granted`, segundo `{ state: "refused", reason: "recovery-budget-exhausted" }`). Y piscina con perfil 2 (fila B2/T5 gate; perfil construido directo, no vía config: el zod la limita a 0..1): raíz con `maxAutomaticRecoveryCalls: 2`, primer episodio concedido (marcador), aserción de que un SEGUNDO episodio SÍ se concede (`1 + 1 <= 2`) y un tercero se rehusa (`2 + 1 > 2`); aserción `usage.automaticRecoveryCalls === 2` con el resumen unificado (marcadores + cobradas, budget.worker.ts :398). Mutación: duplicar el conteo de marcadores en `countRootRecoveryGrants`: `rootRecoverySpent` pasa a 2+1 > 2, la concesión del segundo episodio VOLTEA a rehusa, rojo.

**E2E de punta a punta con el camino de producción (obligatorio del encargo).** it: `"a managed transport failure recovers on the runner's own retry and charges the fund exactly once"`, en managed-task.recovery.test.ts con el proveedor scriptable (doble permitido: fetch del transporte). PROHIBIDO `configureManagedTaskRecoveryRelauncher` (ya no existe). Sustituye a los bloques builder borrados y a la prueba de carril por relanzamiento (:508-576): preparación `admittedRun()` con `maxAutomaticRecoveryCalls: 1` y fila a `running` (preparación común); pasos `[cut-headers, complete, cut-headers]` (la segunda falla post-concesión necesita su propio step, recovery.test.ts:102 sujeta al último); aserciones: marcador presente al volver de `stream.result()`, stream recuperado `stopReason === "stop"`, `provider.requests === 2` (aserción intermedia, tras el stream recuperado y antes de la segunda falla), `budget.usage.automaticRecoveryCalls === 1`; segunda falla del stream recuperado deja recibo en `incidents` y al cierre `provider.requests === 3`, `automaticRecoveryCalls` sigue 1, sin segunda concesión (`already-granted` en sonda). Cerrojo r2: el mensaje de la segunda falla trae `type: "managed_recovery_exhausted"` con `details.reason === "already-recovered"`; plano decisión: ese mensaje alimenta el arnés de TD y `recovery.action` es el terminal sin reintento (sin fase `retrying`); plano stream: nadie re-invoca el stream tras el asentamiento y `provider.requests` se queda en 3. Mutaciones: la de P1 (eliminar la llamada; secundaria, el `await` por `void`) y la de r2 (el asentamiento no marca: la decisión clasifica `"timeout"` por texto y `recovery.action === "retry"`, rojo).

**Convivencia con lo existente.** Las líneas `configureManagedTaskRecoveryRelauncher(undefined)` de managed-task.recovery.test.ts:181 y managed-task.recovery.siblings.test.ts:55 se borran junto con la función: no hay estado de módulo que limpiar (el singleton `relaunchBuilder` desaparece). Los bloques builder de recovery.test.ts (:284, :352, :430, :479, :532, :591, :727) y siblings (:168-174) se reescriben contra `grantManagedTaskRecovery`. El test `"shows each waiting cause within 120 seconds"` (recovery.test.ts:751-892) se reescribe con semántica declarada: su segmento de transporte (:842-864) ya no ve `transport-unavailable` tras la primera falla porque la concesión ahora es incondicional en ese camino y cierra el wait (recovery.worker.ts:105-137); la visibilidad de `transport-unavailable` de primera falla sobrevive por la vía de rehusa (variante P9b: fondo gastado por reserva manual → concesión rehusada → wait abierto) y la concesión pinnea `queue-busy` con la fila congelada en `queued` (variante de P4) o `waiting === null` con la fila a `running`; el conjunto de causas se conserva (wait.worker.ts:13-18), lo que cambia es la vía de producción de `transport-unavailable` (rehusa en vez de concesión); el ajuste de la lista `measured` de :883-888 refleja ese recorrido. `budget_tree` (budget.test.ts:332-388, sin marcadores, piscina llena por cobro manual) y `recovery_limit` (provider-stream.test.ts:642-693, fondo 0, re-despacho bloqueado antes de HTTP; helper con `maxAutomaticRecoveryCalls: 0` en :81) no cambian de semántica con este diseño y quedan verdes. Delta r2: `attempt-recovery.test.ts` gana TD; sus fixtures existentes no traen la marca (`git grep -i managed` en attempt-recovery.ts y failover-retry-controller.ts sale vacío hoy), así que ninguna prueba de decisión cambia de resultado; TD corre en la batería src (el caso `recovery_queue` sigue siendo recovery.test.ts + siblings).

**Integración.** `LANG=en_US.UTF-8 AGENT_WORK_RUNTIME_SOURCE=<R> bash ~/dev/wt/encargos-b4/scripts/agent-work/test-runtime.sh recovery_queue` corre los dos archivos completos (caso definido en test-runtime.sh:67-71): ambos reescritos en verde. Verificación adicional: `budget_tree` (test-runtime.sh:45-48) y `recovery_limit` (test-runtime.sh:62-65).

## Borrados y adiciones

Borrados exactos (principle-subtract-before-you-add: primero resta, la adición queda más chica que el estado inicial):

- `src/agents/tasks/managed-task.recovery.ts`: se borran el tipo `ManagedTaskRecoveryRelaunch` (:7-14), el tipo `ManagedRecoveryRelaunchBuilder` (:16-18), el singleton `relaunchBuilder` (:20), `configureManagedTaskRecoveryRelauncher` (:22-26), `scheduleManagedTaskRecovery` (:28-58) y el import de `enqueueSwarmRun` (:3). El archivo queda con `grantManagedTaskRecovery` y `recordManagedRecoveryIncident`.
- `src/agents/tasks/managed-task.provider-stream.ts`: se borra `chargesRecoveryFund` (:97-102) y el import de `scheduleManagedTaskRecovery` (:15, reemplazado); :141 pierde la dependencia de `binding.recovery` para cobrar; :243-249 pierde el `void scheduleManagedTaskRecovery(...).catch(...)` y gana la rama esperada concesión/recibo.
- `src/agents/tasks/managed-task.recovery.worker.ts`: se mueve `countRootRecoveryGrants` (:30-52) a budget.shared; `beginRecovery` queda igual.
- `src/agents/tasks/managed-task.recovery.test.ts`: reescritura; se borran los imports de `configureManagedTaskRecoveryRelauncher`/`scheduleManagedTaskRecovery` (:28-31), la línea del afterEach (:181), todos los bloques builder (:284, :352, :430, :479, :532, :591, :727) y la prueba de carril por relanzamiento (:508-576), sustituida por P3/P7; el test `"shows each waiting cause within 120 seconds"` (:751-892) se reescribe con la semántica declarada en Convivencia (concesión incondicional cierra el wait de primera falla; la visibilidad de `transport-unavailable` sobrevive por la vía de rehusa P9b; ajuste de la lista `measured` :883-888).
- `src/agents/tasks/managed-task.recovery.siblings.test.ts`: se borran los imports (:18-19), la línea del afterEach (:55) y el bloque builder (:168-174); `scheduleManagedTaskRecovery` pasa a `grantManagedTaskRecovery` (:183, :188).
- No se borra ningún otro `enqueueSwarmRun` de producción (el del restorer de filas queued, subagent-registry-restore.ts:245, es legítimo y queda).

Adiciones:

- `managed-task.recovery.ts`: `grantManagedTaskRecovery`, `recordManagedRecoveryIncident`.
- `managed-task.recovery.worker.ts`: `recordRecoveryIncident` (transacción, sin token, exige admisión admitted y marcador, upsert con digest estable).
- `managed-task.types.ts`: variante `{ kind: "recovery-transport-failure"; episodeId: string }` en `ManagedTaskIncident` y la operación `"managedTasks.recordRecoveryIncident"` en `ManagedTaskWorkerOperations`.
- `managed-task.json.ts`: unión discriminada de incidencias.
- `managed-task.budget.shared.ts`: `countRootRecoveryGrants` exportado.
- `managed-task.budget.worker.ts`: guardia de `reserveModel` con la piscina única (marcadores + cobrado + reclamación), resumen `automaticRecoveryCalls` unificado, caso nuevo en `executeManagedTaskBudgetCommand` (:553-575) y en la unión `BudgetOperation` (:59, :70).
- `src/state/openclaw-state-worker-runtime.ts`: `"managedTasks.recordRecoveryIncident"` en la lista de ruteo (:188-198).
- `managed-task.run-binding.ts`: solo el comentario del campo `recovery` (:8) cambia de significado: "true cuando la raíz ya consumió su episodio; suprime concesiones posteriores" (el tipo no cambia).
- Sin cambios de esquema ni de `PRAGMA user_version` (respuesta 10).

## Votos del panel (interrogate)

Ronda 1 sobre `diseno.md` completo (solo lectura, citas verificadas contra R `96f8e5f`):

- Revisor A: `panel-glm53` (GLM 5.3). 7 hallazgos (4 warning, 3 nit). Sin critical. **VOTO: APROBADO.**
- Revisor B: `panel-glm52` (GLM 5.2). 5 hallazgos (3 warning, 2 nit). Sin critical. **VOTO: APROBADO.**
- Revisor C: `panel-glm47` (GLM 4.7). 4 hallazgos (1 critical, 2 warning, 1 nit). **VOTO: CAMBIOS.**

Bloqueante (critical clasificado "Act on"): el diseño rompía sin declararlo el pin `"shows each waiting cause within 120 seconds"` (recovery.test.ts:842-864, aserción :861), que el propio caso `recovery_queue` corre completo. Corrección aplicada (ronda única): la reescritura de ese segmento entra al diseño con semántica declarada (visibilidad de `transport-unavailable` por la vía de rehusa P9b; concesión pinnea `queue-busy`/`null` según el estado de la fila), más los arreglos de consenso: preparación común que pasa la fila del arnés a `running` para las aserciones `waiting === null`, aserción de enqueue movida a P3 (única con slot registrado), mutación de P9(b) re-apuntada a `rootRecoverySpent` (recovery.worker.ts:23-25) con it renombrado, rama `already-granted` → recibo en el asentamiento (cierra el hueco de binding añejo de compactación), steps explícitos con la segunda falla (`[cut-headers, complete, cut-headers]`), mutación canónica de P1 por borrado (la de `void`, secundaria) y redacción corregida de la mutación de P9(c).

Ronda 2 sobre el diff de `diseno.md` (diseno.r1.md → diseno.md):

- Revisor A: `panel-glm53` (GLM 5.3). Critical resuelto; 2 nit nuevos. **VOTO: APROBADO.**
- Revisor B: `panel-glm52` (GLM 5.2). Critical resuelto; 1 warning de pin (P6 no aislaba la sub-rama `already-granted`) y 2 nit. **VOTO: APROBADO.**
- Revisor C: `panel-glm47` (GLM 4.7). Su critical resuelto; 1 warning de especificación (mutación de P9c no mataba por la vía declarada) y 1 nit. **VOTO: APROBADO.**

Los warnings de ronda 2 (sin critical, panel cerrado) se incorporan igualmente al diseño: P6 ahora asienta la tercera llamada con el binding VIEJO (forma de compactación) y su mutación canónica borra solo la sub-rama `already-granted`; P9(c) pinea la concesión del segundo episodio con perfil 2 (la mutación por marcadores duplicados la voltea a rehusa); la espera `transport-unavailable` tras la repetición añeja queda declarada; `provider.requests` de la E2E queda marcado como aserción intermedia; la mutación de P9(b) fija `queue-busy` como vire determinista; y la Convivencia aclara que el conjunto de causas se conserva.

## Votos del panel — Delta r2

Ronda 1 sobre el diff del delta (solo lectura, citas verificadas contra R `96f8e5f`):

- Revisor A: `panel-glm53` (GLM 5.3). 1 critical + 2 warning + 3 nit. **VOTO: CAMBIOS.**
- Revisor B: `panel-glm52` (GLM 5.2). 1 critical + 1 warning + 2 nit. **VOTO: CAMBIOS.**
- Revisor C: `panel-glm47` (GLM 4.7). 1 critical + 1 warning + 3 nit. **VOTO: CAMBIOS.**

Bloqueante en consenso 3/3 (clasificado "Act on"): la excepción anti-reintento puesta solo en la tercera rama del ternario (:312-318) era letra muerta para las fallas de transporte reales, que se clasifican por texto/código en la rama `assistantFailure?.kind === "reason"` (:310-311: "terminated", "fetch failed", ECONN* → `{ kind: "reason", reason: "timeout" }`), y para un corte con contenido parcial `provider_transport_failure` ni siquiera se agrega (transport-stream-shared.ts:538 exige `content.length === 0`). El revisor A lo ejecutó contra el transporte real (`cut-headers` → `errorMessage: "terminated"`, `errorCode: "UND_ERR_SOCKET"`, sin diagnóstico). Corrección única: la marca gatea el `failureReason` completo (`managedRecoveryExhausted && !idleTimedOut ? null : <ternario de hoy>`), TD gana la variante clasificable ("terminated") + control sin marca, P9(b)/E2E separan plano stream de plano decisión, residual grant-without-retry re-derivado (replay-unsafe fuera de las causas), compactación re-encuadrada.

Ronda 2 sobre el diff del fix:

- Revisor A: `panel-glm53` (GLM 5.3). Critical resuelto; 1 warning (TD variante (c) sin diagnósticos explícitos) + 2 nit. **VOTO: APROBADO.**
- Revisor B: `panel-glm52` (GLM 5.2). Critical resuelto; 2 warning (cita de la valla de compactación; TD (c) vacua) + 2 nit. **VOTO: APROBADO.**
- Revisor C: `panel-glm47` (GLM 4.7). Critical resuelto; 1 warning (la "valla estructural" de compactación citaba un mecanismo que no aplica; su conclusión de seguridad se sostiene) + 4 nit. **VOTO: APROBADO.**

Sin criticals en ronda 2: panel cerrado. Los warnings y nits de ronda 2 se incorporaron igualmente al documento: TD (c) fija AMBOS diagnósticos, el literal de TD (a) queda pineado (`toEqual({ action: "proceed" })`), el párrafo de compactación re-deriva la valla con el mecanismo real (re-throw del asentamiento; `promptErrorSource: "compaction"` solo abort-shaped), el alcance del `content.length === 0` queda acotado al transporte compartido con el contraejemplo ChatGPT Responses, citas unificadas a `:396-409`, ruta de `thinking.ts` calificada, y el hairline de `recoverEmbeddedRunTimeout` (:360-374) queda declarado.

Diversidad del panel reducida: solo familia GLM. Modelo del lead: opencode (poteto-mode) sobre `zai-coding-plan/glm-5.3-flash`.

## Anexo: rationale de architect

### Problem

Hoy `scheduleManagedTaskRecovery` (managed-task.recovery.ts:28-58) depende de un builder (`relaunchBuilder`, :20-26) que en producción nadie registra: la recuperación automática es inerte. Aunque se registrara, el disparador corre con `void` dentro de `stream.result()` del intento en curso (provider-stream.ts:243-249), mientras la corrida sigue viva y su slot ocupado (se libera solo al terminal, subagent-registry-terminal-effects.ts:127-129); la concesión `beginRecovery` es durable y no atómica con el paso siguiente, así que `enqueueSwarmRun` con el mismo `runId` lanza "swarm scheduler run already exists" (swarm-scheduler.ts:346-348) y el episodio queda quemado con un `console.warn` (hallazgo menor de la fila B2/T5 de followups.md). Además un run recuperado cobra el fondo en la primera carga de cada llamada (`chargesRecoveryFund`, provider-stream.ts:97-102), así que con `maxAutomaticRecoveryCalls: 1` la segunda llamada muere antes de HTTP (budget.worker.ts:488-490; demostrado en recovery.test.ts:635-648): la fila B2/T5 (semántica multi-llamada). Las restricciones que el diseño debe honrar: recuperación sobre la cola nativa y sus eventos de capacidad, sin supervisores ni scouts de lectura; los cuatro candados de re-despacho (preflight agent-request-preflight.ts:154-168, dedupe server-constants.ts:16, registro subagent-registry-memory.ts:511-514, binding budget.worker.ts:335-347); la regla B4-1 (decidir por la respuesta del binding, nunca por config); y sin cambio de esquema.

### Usage (caller's view)

Sitios de llamada reales, en orden de ejecución. Ninguno cambia de firma salvo el asentamiento.

1. Cada intento de un run gestionado, incluidos los reintentos, pasa por `prepareEmbeddedAttemptTransport` (attempt-stream-settle.ts:405). En :473 re-resuelve `resolveManagedProviderRunBinding(attempt.runId, attempt.sessionKey)` y en :477-478 envuelve con `createManagedNativeProviderStream`. Este es el único punto donde el runner toca la recuperación: no llama nada nuevo.
2. El stream gestionado (`wrapManagedProviderStream`, provider-stream.ts:105-255) cobra cada payload antes de HTTP (:129-148) y en `stream.result` (:205-253) liquida reservas. El bloque :243-249, hoy `void scheduleManagedTaskRecovery(binding)`, pasa a esperar la concesión o a escribir el recibo dentro del asentamiento. Cuando `stream.result()` devuelve, el marcador ya es durable.
3. La clasificación del reintento cambia solo con la marca (delta r2): sin marca, `provider_transport_failure` es reintentable como hoy (attempt-recovery.ts:313-318), `maybeRetryTransient` acepta (attempt-recovery.ts:396-427, techo 8 reintentos en 90 s, failover-retry-controller.ts:25-28 y :335-364) y `retry()` continúa el mismo transcript (:431-437). Con la marca `managed_recovery_exhausted` (puesta por el asentamiento gestionado cuando no concede), el `failureReason` completo del lado assistant queda null y no hay reintento. El diagnóstico `provider_transport_failure` nace en packages/ai (transport-stream-shared.ts:536-551 con `createAssistantMessageDiagnostic`, y openai-chatgpt-responses.ts:396-409) y se lee en attempt-recovery.ts:316. En el transporte compartido solo se agrega con contenido vacío (:538 exige `content.length === 0`); el provider ChatGPT Responses lo agrega en su catch de fallback websocket sin chequear contenido (:393-409). La marca del asentamiento no depende de ese diagnóstico en ningún caso: condiciona en `transportFailed`, que el wrapper conoce directamente. `AssistantMessageDiagnostic.type` es `string` plano (packages/llm-core/src/utils/diagnostics.ts:10-15), así que la marca es un valor nuevo del mismo canal sin tocar packages/ai. En compactación la valla es estructural, no la marca: la falla sale como `promptError` con `promptErrorSource: "compaction"` y la puerta de `maybeRetryTransient` la excluye (:391 exige `!promptError || promptErrorSource === "prompt"`).
4. El path de compactación también envuelve con el stream gestionado (compaction-session-execution.ts:251), así que una falla de transporte durante compactación de un run gestionado recibe el mismo tratamiento.
5. Lectores: `inspectManagedTask` no cambia de superficie. Sigue mostrando `waiting` (derivado en managed-task.wait.worker.ts:22-115), `budget.usage.automaticRecoveryCalls` (ahora la piscina unificada) y `incidents` (ahora puede incluir el recibo nuevo).
6. El worker `beginRecovery` (managed-task.recovery.worker.ts:54-143) no cambia: transacción, rehusas `settled`/`cancelled`/`already-granted`/`recovery-budget-exhausted`, marcador `recovery:<taskId>` y cierre del wait de falla abierta.

### Tradeoffs accepted

1. Sin resurrección entre procesos. Si el proceso muere con el run activo a mitad de reintento, nadie lo reencola: el restorer llega tarde (subagent-registry.ts:402-404, activación en server-startup-post-attach.ts:1026-1033) y no revive filas retenidas (subagent-registry.ts:416-420). El run muerto queda a su TTL (`waitForSubagentCompletion` se rearma al restaurar, subagent-registry.ts:395-399) y la tarea se asienta por el path normal de reporte. Este diseño compra simplicidad (cero registro, cero segunda entrada) renunciando a la recuperación cross-restart. Es la diferencia estructural con (b) y se asume; el marcador y la piscina quedan listos para un relanzador futuro sin cambio de esquema.
2. La concesión puede ocurrir sin que siga ningún reintento (stream settle concede, attempt-recovery rechaza el reintento por replay-unsafe o presupuesto de reintentos agotado). El episodio queda consumido y el wait de falla quedó cerrado por beginRecovery (:105-137). Decidido en r2 como residual con su razón (ver Open questions 2); el cerrojo de r2 además estrecha la ventana: la concesión habilita exactamente un reintento (el siguiente intento), y su primera falla de transporte queda marcada sin más reintentos. En ese caso el run muere y el recibo de incidencia NO aplica (binding.recovery era false en ese asentamiento).
3. El recibo de incidencia se escribe por cada falla de transporte post-concesión, aunque un reintento posterior tenga éxito. Es evidencia (fila append-only), no estado: convive con un resultado `produced` igual que `permission-required` convive hoy. Dedupe por episodio del marcador: una fila por episodio.
4. Un re-despacho SDK dentro de un run ya recuperado se bloquea antes de HTTP cuando la piscina está llena (el episodio consumió la unidad). Lectura estricta del tope: nunca sobre-concede, a costa de negar el reintento interno del SDK en ese caso. Los reintentos a nivel intento del controller solo existen tras una concesión (delta r2): la concesión habilita el reintento siguiente, y la primera falla de transporte de ese intento queda marcada sin más reintentos; las llamadas nuevas dentro de ese intento van con presupuesto normal, acotadas por `maxModelCalls`.
5. Falla del worker al conceder es fail-open: warn con identidad de tarea y el reintento sigue sin cobrar fondo (las llamadas nuevas cobran normal por diseño; los re-despachos siguen gateados). Preferible a convertir una falla de transporte recuperable en error duro del resultado.

### Alternatives considered

1. Conceder en attempt-recovery, al aceptar el reintento (en vez del asentamiento). Requeriría que el runner genérico sepa de tareas gestionadas (hoy no sabe, verificado) o un hook nuevo. El asentamiento ya existe, ya tiene el binding y ya está esperado antes de devolver result: sitio correcto con cero acoplamiento nuevo.
2. El ruteo en el worker ("automaticRecovery como autorización, cargo real solo si `used.recovery < tope`, si no cargo normal"). Rechazado: el worker no puede distinguir "segunda llamada nueva del run recuperado" (debe pasar) de "segundo re-despacho cobrado al fondo" (debe bloquear); ambos llegan como `automaticRecovery: true` con la piscina llena. El ruteo voltearía los pins vigentes budget.test.ts:332 y provider-stream.test.ts:642. La información que falta vive en el borde del stream (`reservations.length`), así que la decisión se toma ahí y el worker conserva una guarda única en forma de piscina.
3. (b) Relanzar desde el fin terminal con reintento nativo apagado. Pierde en la arena: exige cinco contratos nuevos (campo durable `recoveryLaunch`, hook terminal en el registro, método de re-encolado misma-generación, helper de retiro de dedupe en el gateway, reconciliación de arranque), un cambio de comportamiento del gateway con riesgo propio (retiro temprano de la entrada de dedupe terminal: sin él, `replayAgentTurnIfCached` en agent-turn-service.ts:69 reproduce el caché del run muerto), una transición terminal→queued en tensión con la valla de filas retenidas (subagent-registry.ts:416-420), y la pérdida de la absorción en-turno de blips (cada corte breve terminaliza y gasta un episodio; con tope 1, un blip mata la tarea). Compra cobertura cross-restart que la casilla no pide.
4. Recibo como wait nuevo con causa extendida. Rechazado: `readManagedTaskWait` devuelve una sola espera (wait.worker.ts:45-81) sin ligar al marcador; el encargo exige causa completa y visibilidad en inspect; la tabla `managed_task_incidents` ya es el lugar del recibo durable.
5. (Delta r2) Cómo cercar el reintento sin concesión. (i) Marca como diagnóstico del mensaje (elegido): el canal ya existe, `type` es `string` plano (packages/llm-core/src/utils/diagnostics.ts:11), la marca viaja con el mensaje como evidencia legible y el runner solo aprende "esta falla de transporte no se reintenta", sin saber de tareas gestionadas. (ii) Campo opcional nuevo en el tipo `AssistantMessage` de packages/ai: rechazado, toca el paquete compartido por una preocupación de src/ para un dato que ya tiene canal. (iii) Propiedad con clave Symbol sobre el mensaje: rechazado, invisible en transcripts y mágica. (iv) Que attempt-recovery consulte un predicado de tasks/: rechazado, invierte el ownership de la decisión de reintento; el gate vive en una hoja (`attempt-retry-gate.ts`) que ambos lados importan sin ciclo.

### Open questions and risks

1. Latencia del asentamiento: la concesión esperada agrega un roundtrip al worker por falla de transporte. Despreciable frente al backoff de reintento de 1 a 30 s.
2. Riesgo resuelto en r2 como residual: episodio concedido y reintento rechazado por el controller. Las causas reales son el presupuesto de reintentos agotado (8/90 s de fallas transitorias previas del mismo run) y `retry_delay_unavailable`; replay-unsafe NO está entre ellas (solo valla fallback/rotación vía `failoverEligible`, attempt-recovery.ts:404-406; el rechazo `replay_unsafe` corre después de la puerta transitoria, :439-445). Con el cerrojo corregido (la marca gatea el `failureReason` completo), la concesión habilita exactamente un reintento y su primera falla de transporte queda marcada sin más: la ventana exige agotar 8/90 s ANTES de la primera concesión del run. Razones para no escribir recibo `grant-without-retry`: (i) ventana estrecha por lo anterior; (ii) desenlace seguro: el run termina con el error de transporte y el requester lo ve por el path terminal normal; (iii) escribir el recibo obligaría al runner genérico a reportar resultados de reintento a la capa managed, el acoplamiento que la arena r1 rechazó; (iv) la contabilidad del fondo es correcta (el marcador cuenta en la piscina). Si algún día hace falta, el lugar barato sin acoplar es el terminal del run: `completeTerminalEffects` (subagent-registry-terminal-effects.ts:53) puede ver "marker abierto + cero reservas posteriores al grant" y pedir el recibo al worker. El episodio queda consumido y el wait de falla quedó cerrado por beginRecovery (:105-137), así que ese caso no deja espera visible: es el precio del residual.
3. Bases existentes con reservas `automaticRecovery: true` de la semántica vieja siguen sumando a la piscina unificada (compatibles, nunca decrementan el tope). Solo conservador.
4. Si el programa alguna vez quiere recuperación cross-restart, este diseño no la da; habría que añadir el relanzador de vuelta. La piscina y el marcador quedan listos para eso sin cambio de esquema.
5. Perfiles con `maxAutomaticRecoveryCalls: 2` (el zod cap es 0..1, zod-schema.managed-tasks.ts): con la piscina única, 2 unidades significan por ejemplo dos episodios o un episodio y un re-despacho. La fila B2/T5 (gate) pide fijar ese comportamiento: la prueba de piscina (P9c) lo deja escrito.
6. (Delta r2) Riesgo residual de compactación: el `continue` interno del bucle (compaction-session-execution.ts:680-693) re-llama al proveedor sin pasar por marca ni decisión del runner; hoy no dispara con cortes de transporte porque `pickFallbackThinkingLevel` solo casa texto de constraint de reasoning (src/agents/embedded-agent-helpers/thinking.ts:26-36, "terminated" no casa). Si un patrón futuro clasificara un corte de transporte como thinking-rejection, ese reintento no tendría valla: declararlo como residual y vigilarlo en la tarea que toque thinking fallback.
7. (Delta r2) La marca queda en el transcript como diagnóstico del mensaje (evidencia legible de por qué no hubo reintento); `details` lleva `taskId` y la razón de la rehusa. Ninguna capa recorta diagnósticos en el camino hasta attempt-recovery (verificado en panel).

### Next implementation step

Borrado primero (principle-subtract-before-you-add): eliminar builder, `configureManagedTaskRecoveryRelauncher`, `scheduleManagedTaskRecovery`, el import de `enqueueSwarmRun` y `chargesRecoveryFund`; compilar y dejar rojos los tests viejos que pinean el relanzador. Después, en orden verificable (principle-sequence-verifiable-units): (1) mover `countRootRecoveryGrants` a budget.shared y unificar la guardia de `reserveModel` y el resumen; (2) cambiar :141 y el bloque :243-249 con `grantManagedTaskRecovery`; (3) unión de incidencias + worker op `recordRecoveryIncident` + ruteo; (4) reescribir managed-task.recovery.test.ts y ajustar siblings; (5) correr `LANG=en_US.UTF-8 AGENT_WORK_RUNTIME_SOURCE=<R> bash ~/dev/wt/encargos-b4/scripts/agent-work/test-runtime.sh recovery_queue` y también `budget_tree` y `recovery_limit`.

### Síntesis de la arena (decisión)

Base: candidato (a) (corredor poteto-agent sobre GLM, directorio artifacts/B4-5-r1/candidato-a-JMaHCe09). Se adopta íntegro: concesión esperada en el asentamiento, borrado del relanzador, piscina única del fondo, recibo `recovery-transport-failure`, pruebas P1-P9. Injertos del candidato (b) (poteto-agent, candidato-b-GVEYtp98): la declaración explícita del hueco cross-restart como renuncia y la nota de compatibilidad futura del marcador/piscina con un relauncher; el hallazgo de `replayAgentTurnIfCached` (agent-turn-service.ts:69) como el paso crítico que cualquier (b) futuro tendría que resolver con retiro de dedupe (requisito de dedupe real del gateway en proceso: aplicable solo a ese futuro (b), porque (a) jamás re-entra al gateway). Rechazo de (b) como base: cinco contratos nuevos entre cuatro subsistemas, cambio de comportamiento del gateway, transición terminal→queued contra la valla de filas retenidas, pérdida de absorción de blips, y un componente de arranque que la casilla prohíbe ("no abras supervisores ni scouts").

## Delta r2

Bloqueante que atiende: el runner decidía `transient_retry` con solo ver la falla clasificada como transporte (attempt-recovery.ts:308-319, techo 8/90 s en failover-retry-controller.ts:25-28), sin ninguna excepción para corridas gestionadas; tras una rehusa (`already-granted`, `recovery-budget-exhausted`) o tras la segunda falla de una corrida ya recuperada, seguía llamando al proveedor hasta 8 veces más con `automaticRecovery: false`, contradiciendo la casilla `recovery_limit` ("el siguiente conserva bloqueo sin otra llamada") y el mínimo del encargo r1. Las pruebas de r1 no lo veían porque ninguna pasaba por la decisión del runner.

**Mecanismo.** El asentamiento del stream gestionado (provider-stream.ts, bloque que reemplaza :243-249) marca el mensaje con el diagnóstico `managed_recovery_exhausted` cuando la falla de transporte NO termina en concesión: corrida ya recuperada (`binding.recovery`, razón `already-recovered`), rehusa `already-granted` (binding añejo; además escribe el recibo, igual que r1), `recovery-budget-exhausted`, `settled` o `cancelled`. La marca usa el canal existente de diagnósticos del mensaje: `type` es `string` plano (packages/llm-core/src/utils/diagnostics.ts:10-15) y los helpers `appendAssistantMessageDiagnostic` (:61-66) y `createAssistantMessageDiagnostic` (:52-58) son genéricos y exportados, así que no hay cambio en packages/ai. El wrapper marca por su propio `transportFailed`, no por el diagnóstico `provider_transport_failure`: en el transporte compartido un corte con contenido parcial no agrega ese diagnóstico (transport-stream-shared.ts:538 exige `content.length === 0`; el provider ChatGPT Responses sí lo agrega en su catch websocket sin chequear contenido, :393-409), así que no puede ser la condición en ningún caso.

La excepción en attempt-recovery.ts gatea el `failureReason` COMPLETO del lado assistant, no solo la rama del diagnóstico de transporte:

```ts
const managedRecoveryExhausted =
  hasManagedRecoveryExhaustedDiagnostic(attemptAssistant);
const failureReason = promptError
  ? failoverReasonFromClassification(retryFailure)
  : managedRecoveryExhausted && !idleTimedOut
    ? null
    : assistantFailure?.kind === "reason"
      ? assistantFailure.reason
      : idleTimedOut ||
          (attemptAssistant &&
            isRetryableAssistantError(attemptAssistant) &&
            attemptAssistant.diagnostics?.some(
              (diagnostic) => diagnostic.type === "provider_transport_failure",
            ))
        ? "timeout"
        : null;
```

Por qué completo: la rama `assistantFailure?.kind === "reason"` (:310-311) clasifica las fallas de transporte reales ANTES de la rama del diagnóstico (:312-318). El texto del corte casa los patrones de timeout (message-patterns.ts: "terminated" en TERMINATED_TRANSPORT_MESSAGE_RE :33, "fetch failed" :174, "socket hang up" :175) y el código undici (`UND_ERR_SOCKET`, ECONN*) cae por `isTransientNetworkError` (retryable-network-errors.ts), ambos vía `classifyFailoverSignal` → `{ kind: "reason", reason: "timeout" }` (classify-core.ts:188-190); sin status 4xx no hay downgrade `sameModelRetry`, la puerta :394 pasa y `maybeRetryTransient` acepta "timeout" (failover-retry-controller.ts:297-306). Una excepción puesta solo en la tercera rama (versión r2.0 de este delta) sería letra muerta para exactamente las fallas que atiende: el panel lo trazó y lo ejecutó contra el transporte real (el mensaje de un `cut-headers` es `errorMessage: "terminated"`, `errorCode: "UND_ERR_SOCKET"`, sin diagnóstico de transporte). Con marca y sin idle timeout: `failureReason` null → `recoveryReason` null (:375) → puerta :395-396 cerrada → cero reintentos. `idleTimedOut` conserva su vía. Corrida no gestionada: sin marca, sin cambio. Falla del worker al marcar: fail-open (mismo tradeoff 5). La concesión NO marca: el reintento habilitado es la recuperación.

**Compactación: valla estructural, no la marca.** Una falla de transporte de compactación nunca llega a attempt-recovery como `failureReason` clasificado del lado assistant: `throw err` en el bucle (:695), el compact falla y emerge como re-throw de la fase de asentamiento; `promptErrorSource: "compaction"` (attempt-stream-settle.ts:228-237) solo se asigna a errores abort-shaped (`isRunnerAbortError`) y `promptErrorSource: "prompt"` etiqueta errores de fase prompt, nunca transporte. La puerta transitoria queda cerrada por ausencia de `recoveryReason`, no por la exclusión de :391. El bucle interno solo reintenta thinking-fallback (:680-693, `pickFallbackThinkingLevel` en src/agents/embedded-agent-helpers/thinking.ts:26-36, "terminated" no casa) y si no hay fallback relanza (:695). La marca en el mensaje de compactación es evidencia, no gate. Residual: si `pickFallbackThinkingLevel` llegara a casar texto de transporte, el `continue` interno re-llamaría al proveedor sin valla (hoy no); queda declarado en Open questions 6.

**grant-without-retry: residual con razón.** Con el gate corregido, la concesión habilita exactamente un reintento y su primera falla de transporte queda marcada sin más. La ventana exige presupuesto de reintentos agotado (8/90 s de fallas previas del mismo run) o `retry_delay_unavailable` ANTES de la primera concesión; replay-unsafe no está entre las causas (solo valla fallback/rotación, :404-406; el rechazo `replay_unsafe` corre después de la puerta transitoria, :439-445). Desenlace seguro (run terminal con el error, visible para el requester), contabilidad correcta (el marcador cuenta en la piscina), y sin acoplar el runner genérico a tasks/ para reportar reintentos. Escape futuro sin acoplar: el terminal del run (subagent-registry-terminal-effects.ts:53) puede detectar "marker abierto + cero reservas posteriores al grant" y pedir el recibo.

**Pruebas nuevas (cada una con su mutación).** TD (decisión, attempt-recovery.test.ts): tres variantes sobre `recoverAfterTransportDrop`. (a) primaria: mensaje clasificable por texto (`errorMessage: "terminated"`) + marca → `recovery.action` terminal sin reintento, pineado con literal; (b) control: mismo mensaje sin marca → `action === "retry"` (reintento por texto, comportamiento de hoy, :581-585); (c) `"WebSocket error"` + marca → terminal sin reintento (cubre la rama del diagnóstico). Mutación: quitar el gate de la marca (o dejarlo solo en la tercera rama) → (a) reintenta por texto, rojo. P9(b) reescrita: tras la rehusa, mensaje marcado; plano stream `provider.requests === 1` y nadie re-invoca el stream; plano decisión `recovery.action` terminal sin reintento; mutación (ii): el asentamiento no marca → la decisión reintenta por texto (`action === "retry"`), rojo. E2E reescrita: tras la segunda falla, marca `already-recovered`, decisión sin reintento, `provider.requests` se queda en 3; mutación de r2: sin marca, `recovery.action === "retry"`, rojo.

**Secciones afectadas:** tesis, Shape (bloques del asentamiento y del gate), respuestas 3 y 9, pruebas (intro, TD, P9(b), E2E, Convivencia), Tradeoffs 2 y 4, Alternatives 5, Open questions 2, 6 y 7. Lo demás del diseño r1 queda como estaba.
