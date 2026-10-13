# Explorador C: código real (R, G B4, G producción) vs lo que SUA planea

Bases: R 6e3d428 (HEAD local de feat/agent-work-integration, sin push; único remoto upstream openclaw/openclaw). G B4 209a008. G producción origin/main 77fafb0. SUA G e5cae2d (head PR #247). Orbit 25cebe7. Durante la exploración encargos/b4 avanzó a 82f26f4 ("send host incidents from the pump").

## R (6e3d428), dueño nativo, src/agents/tasks/
- managed-task.types.ts: ManagedTaskCaller agent|director (1-16); ManagedTaskAssignment con target agente/CLI, continuation requester/director, progressBinding corrida/carril/intento/ronda (22-37); ManagedTaskHandlingDecision continue|complete|blocked|cancelled (98-101); ManagedTaskHostIncident 4 tipos (permission-required, deadline-missed, transport-unavailable, invalid-result), ManagedTaskIncident + recovery-transport-failure (116-124); ManagedTaskWaitCause (132-136); ManagedTaskRecoveryReceipt con recovery-budget-exhausted (145-156); ManagedBudgetProfile (198-209); ManagedTaskAdmissionReceipt (237-253); operaciones del worker (266-451).
- Schema src/state/openclaw-state-schema.sql:1593-1712: 11 tablas managed_task_*; schemaVersions.state 27.
- managed-task.worker.ts: register rechaza raíces creadas por workers (107-117); report valida, guarda result_json, encola despertar del solicitante (200-398); inspect (465-533).
- handling.worker.ts Continue (50-179): ID hijo = hash(parent, result_digest, slot); managed_task_children.child_task_id UNIQUE; cancel en cascada terminal (181-257).
- admission.worker.ts: claim (319-400), query con valla fenced/never-started (402-439), confirm nativo (441-534), confirmHost (216-303), claimHostAssignment (28-150).
- Presupuesto: budget.shared.ts countRootRecoveryGrants (100-125), charged (146-163); budget.worker.ts maxConcurrentTasks por raíz, assertManagedChildBudgetCapacity, reserveModel con un solo fondo de recuperación (282-287).
- Recuperación: recovery.worker.ts beginRecovery (marcador recovery:<taskId>) y recordRecoveryIncident; attempt-retry-gate.ts MANAGED_RECOVERY_EXHAUSTED_DIAGNOSTIC.
- Incidencias de host: host-incident.worker.ts (clave host:<gen>:<kind>:<id>; despierta al solicitante solo si la fila es nueva, continuación requester, sin cancelación ni resultado); store.ts recordManagedTaskIncidentFromHost.
- Despertar: delivery.ts systemEvent con contextKey task:<id>, managedTaskDelivery, expectedSessionId, clave idempotente; server-restart-sentinel.ts lo difiere hasta un turno admitido, si la sesión cambió → dead-letter; heartbeat-runner-run.ts corre el turno.
- turn.ts:42-44 rechaza cron isolated como solicitante (33f4e47).
- RPC server-methods/managed-tasks.ts: managedTasks.resolve (solo director), host.admit/.claim/.brief/.close/.incident/.report, projections.list/.ack; todos operator.admin y assertHostDevice.
- Herramientas: managed_tasks_submit/_admit/_resolve/_cancel/_inspect/_artifact_read.
- Ya existe "goal" en R: SessionGoal, comando /goal (packages/gateway-protocol/src/schema/sessions-goal.ts:6-31; estados active|paused|blocked|usage_limited|budget_limited|complete; tokenBudget; src/config/sessions/goals*.ts). SUA propone src/agents/goals/ nuevo.

## G B4 (209a008), host CLI
- host.py: Host.apply (spool → host.admit → entrega; si falla, uncertain sin reintento); report/collect/flush; flush_closures; record_incident/flush_incidents; TmuxTransport, ShellAdapterTransport.
- spool.py: SQLite host.sqlite; operations registered→attempted→delivered→reported→acknowledged; un activo por instancia; tablas incidents y closure_sends; incident_identity espejo del parser de R.
- routing.py:15-16: AGENT_ROUTES {(ingenieria, adversary), (operaciones, ingenieria)}; CLI_ROUTES {(ingenieria, windows-remote), (main, mac-local)} (la segunda la agregó B4 f385f21); resultContract solo review.v1|ready.v1.
- native_gateway.py: GatewayProjectionClient con --device-auth; claim_cli_once; pump_once (flush resultados, cierres, claim, proyecciones); watch_pump cada ≤5 s.
- resources.py ResourceManager (TaskCreated|UserAdopted|IntentionalPool, boot_id, nonce, capacity=1, CleanupPending|AbsenceVerified|ReleasedAdopted, TmuxBackend).
- cutover.py: ensayo offline prepare/apply/rollback (generación +1, admisión congelada, cron suspendido, un solo emisor).
- progress_bridge.py: proyección hacia la cola de progreso.
- corrida_worker/task_handoffs.py: decisiones de director (evento de intento → resolve_via_gateway → managedTasks.resolve); B4 agregó failed/executor-cancelled → continue al solicitante.
- coverage.json: status inventory-only; hostAdapterCoverage todo deshabilitado; modelWakes 13 entradas (crons *-vigia de encargos, jev-ads-01/02, acos, orbit-fase-d, revisor-loop, u3-loop, u3a-cierre, u3a-loop, u3b; latido.sh; tmux-activity-watch; hook Stop).

## G producción (77fafb0)
corrida.sh → corrida/<sub>.sh; corrida_worker/{reconcile,gates,selector,registry,state,task_handoffs}.py; gates.py:402 stop2; registry.py:15 MAX_EXTERNAL_SESSIONS=4; selector.py:132 capacity-full por trabajador, sin par atómico; autoridad-merge.sh y preaprobaciones.v1.json; despertar U3a: claude-stop-openclaw-event.sh y tmux-activity-watch.sh → openclaw system event --mode now a agent:main:vigia-mac. loop-autopilot.md. Plans.md:36-40.

## Flujo
Hoy en vivo: claw (main) lanza lead y trabajadores con corrida.sh; CLIs escriben LISTO <sha> o VEREDICTO; crons vigía con modelo cada 5 min, latido.sh, hook Stop y vigilante tmux (system event inmediato, U3a). corrida_worker decide compuertas por SHA. Las tareas gestionadas de R NO están instaladas (Encargos sin adopción, T12 0/12).
Tareas gestionadas (código no adoptado): submit → captureManagedTaskTurn → registerManagedTask → createBudget → reserveAdmissionBudget → claimAdmission. Nativa: spawn + confirmAdmission. CLI: host.claim + host.brief → Host.apply → host.admit → begin_delivery → entrega tmux (delivered o uncertain). CLI escribe agent-work.result.v1. pump_once → host.flush → managedTasks.host.report → R guarda result_json y encola systemEvent task:<id>. Heartbeat corre turno del solicitante → inspect → resolve (continue crea hijos; complete/blocked/cancelled). projections → progress_bridge → tablero.
Incidencias: G record_incident pendiente; en 209a008 nada la envía; 82f26f4 agrega G1b. R despierta una vez.
Recuperación: fallo de transporte → beginRecovery; fondo agotado → refused + managed_recovery_exhausted. Relanzador borrado (adfc245).
Futuro SUA: controlador en R open/control/reconcile/read → decide puro → host.commit atómico; reemplaza la decisión de corrida_worker y resolve suelto.

## SUA vs lo que existe por bloque
- SUA-00: runtime-map.json existe; spec y fixtures nuevos no existen. Inventario de despertares ya existe en coverage.json.modelWakes (B4-8, solo en 209a008). Medición de despertar se solapa con hook_is_observation y main_cli_loop (B4).
- SUA-01: nombres reales distintos (.handling.worker.ts, .admission.worker.ts, .spawn-admission.ts, .budget.{shared,store,worker}.ts, .recovery.ts, .recovery.worker.ts, server-methods/managed-tasks.ts, core-descriptors.ts). No existe managed-task.handling.ts ni .admission.ts.
- SUA-02: src/agents/goals/ nuevo choca con SessionGoal; corrida_worker/*, corrida.sh, skill native-harness-orchestration existen; B4 cambió task_handoffs.py.
- SUA-03: workers.v1.json, registry.py, selector.py, lib.sh existen; "adaptadores CLI" = host.py, spool.py, native_gateway.py, routing.py, que B4 cambió.
- SUA-05: gates.py, ci-fast-allowlist.txt, run-checks.sh, test-ci-coverage-contract.sh existen.
- SUA-06: progress_bridge.py y proyección de R existen (solo review/ready con destino de corrida).
- SUA-08: deploy-goncloud.sh no existe.
- SUA-09: T11 0/7, T12 0/12; solo cutover.py offline.

Archivos de R que tocan a la vez SUA-01 y B4 (3c1c748..6e3d428): managed-task.store.ts, .store.test.ts, .types.ts, .budget.shared.ts, .budget.worker.ts, .recovery.ts, .recovery.worker.ts, .recovery.test.ts, .recovery.siblings.test.ts, server-methods/managed-tasks.ts, .test.ts, core-descriptors.ts, server-methods-list.test.ts, server.managed-task-requester.e2e.test.ts. Más los que una migración casi seguro toca y B4 tocó: worker.ts, json.ts, delivery.ts, turn.ts, provider-stream.ts, run-binding.ts, state-db-maintenance, additive-columns, secret-state-tables, state-worker-runtime, git-backup-codec, package.json schemaVersions, Swift OpenClawNativeStateSQLite, vitest database-worker paths.

## Conceptos SUA que ya existen con otro nombre
- Exception ≈ ManagedTaskIncident/HostIncident + RPC host.incident + despertar único + tabla incidents del spool + ManagedTaskWaitCause. Falta: opciones válidas, respuesta única autenticada, reaviso cada hora. Las "11 clases antiguas" solo existen en documentos; no hay código que migrar.
- CorrectionBudget: no hay contador de ciclos en R; presupuesto de R es de tokens/llamadas/recuperación. Análogo: gates.py:402 + ronda de progressBinding.
- reconcile ≈ corrida_worker/reconcile.py + task_handoffs + pump_once/watch_pump + despertar task:<id>.
- Effect ≈ spool registered→attempted→delivered|uncertain (begin_delivery = permiso único de inicio); admisión claimed→admitted, fenced/never-started; reservas reserved|settled|uncertain. Ninguno serializado con pausa o época.
- Rutas ≈ AGENT_ROUTES/CLI_ROUTES + coverage.json + workers.v1.json + selector.
- UnitBinding: hoy por padre (hash(parent, resultDigest, slot)), no por unidad.
- ProcessIdentity ≈ ResourceManager.
- Control: Cancel existe (cascada terminal); Pause no existe para tareas gestionadas (solo en SessionGoal); sin época.
- CAS de generación ≈ cutover.py.
- "Un hijo no crea otra raíz" ya existe.

## SUA da por existente y no existe, o cita mal
1. Mecanismos T11-T12 no implementados.
2. director_handling: existe como DirectorHandlingTest en test-agent-work-integration.sh desde 77fafb0.
3. test-worker-model-binding.sh solo existe en e5cae2d (PR #247 sin mergear).
4. Bug --model\nwrong: e5cae2d ya rechaza caracteres de control (registry.py _check_argv_element) y tiene su prueba; residuo no especificado (hipótesis: worker_argv en lib.sh sustituye {brief},{worktree},{session_id},{session_name} sin validar).
5. "Continue ya instalado en fuente": en rama local sin push y no instalada.
6. R no tiene: fan-in (child_task_id UNIQUE = un solo padre); hijos iniciales sin resultado padre; recuperar capacidad del solicitante tras /new (dead-letter hoy); RPC para que el director registre raíces; contratos no-ingeniería (fijo a review.v1|ready.v1); generation siempre 1.
7. Cupo global por par no existe; maxConcurrentTasks es por raíz.

## Entre e5cae2d y 209a008 (lo que SUA no vio)
e5cae2d no es ancestro de 209a008; ambos salen de 77fafb0. SUA vio R 6e3d428 pero no los 17 commits G de B4: incidencias en spool + IncidentRejected; ruta main→mac-local y skill agent-dispatch; claim_cli_once exige generación ≥1; closure_rows; failed → continue; coverage.json.modelWakes; pruebas main_cli_loop e2e, agents_routing, IncidentFlushTest; T5-relanzador-diseno.md, evidencia T8/T9. Ningún documento SUA menciona incidencias, host.incident, pump_once, CLI_ROUTES, coverage.json, modelWakes, cli_silent_failure, cli_delivery_acceptance, main_cli_loop, B4 ni SessionGoal.

## Límites
Ningún archivo de código lo cambian a la vez e5cae2d y B4. Pero flota-poteto tiene cambios sin commit en el plan de encargos, donde B4 marcó casillas: conflicto seguro. Encargos no está en las 39 filas de SUA; SUA absorbe T1-T12 "por perímetro" y se pisa con T9-T12 vivos en B4.

## No evidente
Agregar tabla/columna managed_task_* arrastra ~8 archivos (estado, respaldos, Swift, doctor), lo que tuvieron que arreglar B4-1..B4-3. src/agents/goals/ choca con SessionGoal y /goal. task_handoffs mantiene registro propio de intentos; SUA prohíbe registro operativo fuera del dueño nativo → debe migrar.

## Preguntas abiertas
Residuo de argv/modelo del PR #247; si SUA-01 reemplaza o extiende las incidencias de R y cómo convive con B4-G2 y 82f26f4; quién mergea primero (B4 o PR #247) y cómo se rebasan los docs de encargos.
