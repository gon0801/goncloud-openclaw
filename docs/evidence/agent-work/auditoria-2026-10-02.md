# Auditoría B0-1: casillas marcadas del plan de encargos (2026-10-02)

Auditoría del bloque 0 (encargo `B0-1-r1`): una fila por cada casilla marcada `[x]` del plan
[`2026-09-30-encargos-agentes.md`](../../superpowers/plans/2026-09-30-encargos-agentes.md), con el
comando focalizado re-corrido sobre los heads actuales. El plan tiene 33 casillas marcadas y 54
abiertas; las 33 se sostienen y ninguna se desmarcó.

Heads de la auditoría:

- G: rama `encargos/b0` en `f734f2a` (merge de `feat/agent-work-b1` `e151f80` con `origin/main` `8e2dde0`; único conflicto `Plans.md`, resuelto como unión).
- R: `feat/agent-work-integration` en `9f99e2264c`, árbol limpio (`candidateDiffSha256` `e3b0c442…`, el digest sha256 del árbol vacío).

Los logs de cada re-corrida viven en [`auditoria-2026-10-02/`](auditoria-2026-10-02/) con `G_HEAD`,
`R_HEAD`, fecha UTC y `EXIT=` finales. Los `rerun-*.log` son de esta ronda; los `t*.log` restantes
son de la emisión previa descartada, correos sobre los mismos heads, y se conservan como
complemento (incluido `t1t2-requester_queue.log`, verde en 420.81 s, que respalda la casilla
abierta de T2 sin cerrarla).

## Decisiones de commits sueltos (punto 2 del encargo)

| Commit | Decisión | Equivalente | Evidencia |
|---|---|---|---|
| G `270b2fa` (`feat/agent-work-t9-e2e`) | Ya integrado, sin cherry-pick | `3d377ed`, con el delta entrado por `82d3817`; ambos ancestros de `encargos/b0` | `git cherry HEAD feat/agent-work-t9-e2e` da `+` por patch-id distinto; el diff por archivo contra HEAD deja solo `scripts/tests/test-agent-work-integration.py` con 3 líneas extra (HEAD es superconjunto); `git log -S UserAdopted` atribuye el delta a `82d3817` |
| R `0baf899` (`feat/agent-work-b1`) | Ya integrado, sin cherry-pick | `8ac6d1b308`, ancestro de `9f99e2264c` | Mismo asunto y mismos 5 archivos (273+/6- contra 275+/6-); commits posteriores refactorizaron `managedTaskId` y el test-support; el despertar persistente sigue en el head |
| R `d714430` (`fix/agent-work-b1-idle`) | Ya integrado, sin cherry-pick | `0ac300b4d9`, ancestro de `9f99e2264c` | Mismo asunto, mismo archivo, mismo stat 15+/61- |

Decisiones re-verificadas en esta ronda con `git cherry`, `git range-diff` y diffs por archivo;
bitácora append-only en
[`auditoria-2026-10-02/decisions-b0-1-r1.tsv`](auditoria-2026-10-02/decisions-b0-1-r1.tsv).

## Tabla de auditoría (33 casillas marcadas)

El par de SHA de las re-corridas es uniforme: G `f734f2a`, R `9f99e2264c`. Los pares históricos de
cada recibo quedan en su `T<n>.md`. Resultado `VERDE` significa `EXIT=0` con las aserciones del
caso; el log citado lleva la salida completa.

### T0 (8 casillas)

Comando `bash scripts/agent-work/test-runtime.sh baseline`, log `rerun-baseline.log`: shard de
Vitest verde en 9.31 s y reproducción de la limitación con `duplicateAdmitted: true` (llamadas
marcadas al proveedor 2 antes del reinicio, 3 después). Complemento del mapa:
`rerun-projection_gateway.log` (1 passed, 7 skipped).

| Casilla | Recibo | Re-corrida | Resultado |
|---|---|---|---|
| Metadatos de artefactos instalados inspeccionados sin modificarlos | `T0.md` | `baseline` | VERDE |
| Checkout de fuente trazable con SHA completo registrado | `runtime-map.json`, `T0.md` | `baseline` (`candidateSha 9f99e2264c` en el log) | VERDE |
| Mapa de rutas, build, pruebas, migraciones y compatibilidad | `runtime-map.json` | `baseline` + `projection_gateway` | VERDE |
| Bases iniciales y ramas B0-B5 en `block-bases.json` | `block-bases.json` | `baseline` | VERDE |
| Perfil aislado con directorios, puertos y sockets propios y proveedor simulado | `T0.md`, `capabilities.md` | `baseline` (source apunta al checkout de R) | VERDE |
| Pérdida de deduplicación tras reinicio reproducida como limitación de la base | `T0.md` | `baseline` (`duplicateAdmitted: true`) | VERDE |
| Capacidades de identidad, consulta, presupuesto y cierre clasificadas con evidencia | `capabilities.md` | `baseline` | VERDE |
| Agentes, destinos, CLI, hosts y delegación en `coverage.json` | `coverage.json` | `baseline` | VERDE |

### T1 (5 casillas)

Comandos `bash scripts/agent-work/test-runtime.sh registration_identity` (2 passed, 7 skipped) y
`bash scripts/agent-work/test-runtime.sh result_receipt` (4 passed, 5 skipped), logs
`rerun-registration_identity.log` y `rerun-result_receipt.log`.

| Casilla | Recibo | Re-corrida | Resultado |
|---|---|---|---|
| `registration_identity`: misma clave y contenido devuelve el mismo ID, conflicto con otro contenido, sin colisión entre solicitantes | `T1.md` | `registration_identity` | VERDE |
| `result_receipt`: productor ajeno, generación antigua, digest incorrecto y revisión equivocada no avanzan; `review.v1` valida el payload | `T1.md` | `result_receipt` | VERDE |
| Ambos casos ejecutados con aserciones rojas conservadas | `T1.md` (`T1-wrapper-red.txt`) | rojo histórico citado en el recibo; verde re-corrido hoy | VERDE |
| Transacciones y migración versionada; resultado, pendiente y `ProjectionPending` antes del ACK | `T1.md` | `result_receipt` | VERDE |
| Repetición con reinicio entre escrituras y recibos recuperados | `T1.md` | ambos casos (incluyen reinicio) | VERDE |

### T2 (5 casillas marcadas)

Comando `bash scripts/agent-work/test-runtime.sh admission_restart` (shard verde en 7.61 s), log
`rerun-admission_restart.log`.

| Casilla | Recibo | Re-corrida | Resultado |
|---|---|---|---|
| `admission_restart`: dos emisores y reinicio antes o después de admitir generan una sola admisión lógica | `T2.md` | `admission_restart` | VERDE |
| Revocación de permiso entre registro y admisión rechaza sin ejecutar herramientas | `T2.md` | `admission_restart` | VERDE |
| Pruebas en rojo | `T2.md` (`T2-wrapper-red.txt`) | rojo histórico citado en el recibo; verde re-corrido hoy | VERDE |
| Reclamación exclusiva, cola persistente y exclusión durable; el timeout no se traduce a `NeverStarted` | `T2.md` | `admission_restart` | VERDE |
| Solicitud retrasada que llega después de una consulta de ausencia | `T2.md` | `admission_restart` | VERDE |

La casilla abierta de T2 (`requester_queue`) no se audita aquí; su re-corrida sobre estos mismos
heads quedó verde (`t1t2-requester_queue.log`, 420.81 s) y B1 la cierra con su recibo.

### T3 (5 casillas marcadas)

Comandos `bash scripts/agent-work/test-runtime.sh handling_atomic` (3 passed, 9 skipped) y
`bash scripts/agent-work/test-runtime.sh handling_unresolved` (4 passed, 8 skipped), logs
`rerun-handling_atomic.log` y `rerun-handling_unresolved.log`.

| Casilla | Recibo | Re-corrida | Resultado |
|---|---|---|---|
| `handling_atomic`: decisión, hijos y recibo aparecen juntos incluso con dos consumidores | `T3.md` | `handling_atomic` | VERDE |
| `handling_unresolved`: `agent_end` sin `resolve` conserva el resultado pendiente | `T3.md` | `handling_unresolved` | VERDE |
| Cancelación concurrente, callback tardío y herramienta externa con efecto incierto; evidencia conservada y ningún reenvío ciego | `T3.md` | `handling_unresolved` | VERDE |
| Implementa consumo, cancelación y recuperación; captura antes de eliminar hijos | `T3.md` | `handling_atomic` | VERDE |
| Pérdida del ACK de consumo recupera los mismos hijos sin nueva revisión | `T3.md` | `handling_atomic` | VERDE |

### T4 (3 casillas marcadas)

Comandos `bash scripts/agent-work/test-runtime.sh budget_tree` (3 passed, 6 skipped) y
`bash scripts/agent-work/test-runtime.sh budget_context` (3 passed, 6 skipped), logs
`rerun-budget_tree.log` y `rerun-budget_context.log`.

| Casilla | Recibo | Re-corrida | Resultado |
|---|---|---|---|
| `budget_tree`: hijos concurrentes, reintentos y turno del padre conservan el límite agregado | `T4.md` | `budget_tree` | VERDE |
| `budget_context`: sistema, historial, herramientas, adjuntos, salida y caché sin doble suma | `T4.md` | `budget_context` | VERDE |
| Ausencia de métricas y proveedor sin límite de salida: reserva conservadora o rechazo | `T4.md` | `budget_tree` + `budget_context` | VERDE |

### T6 (4 casillas marcadas)

Comandos `bash scripts/tests/test-agent-work-host.sh host_receipts` (13 tests OK en 6.757 s) y
`bash scripts/tests/test-native-harness-adapters.sh` (TODO VERDE), logs `rerun-host_receipts.log` y
`rerun-native-harness-adapters.log`.

| Casilla | Recibo | Re-corrida | Resultado |
|---|---|---|---|
| `host_receipts`: registro antes de entrega, ACK vinculado al encargo y un solo encargo activo por instancia | `T6.md` | `host_receipts` | VERDE |
| Informe parcial, credencial ajena, versión antigua y salida cero sin informe no acreditan entrega | `T6.md` | `host_receipts` | VERDE |
| Implementa entrega por referencia, escritura atómica y spool hasta recibo durable con `hostId` explícito | `T6.md` | `host_receipts` | VERDE |
| Cien repeticiones del informe con ACK perdido: un resultado y el mismo recibo | `T6.md` | `host_receipts` | VERDE |

### T9 (2 casillas marcadas)

Comandos `bash scripts/agent-work/test-runtime.sh delegation_bypass` (shard verde en 5.66 s) y
`bash scripts/tests/test-agent-work-integration.sh hook_is_observation` (TODO VERDE de
`test-corrida-avisos` U1+U3 y `tmux-activity-watch`), logs `rerun-delegation_bypass.log` y
`rerun-hook_is_observation.log`.

| Casilla | Recibo | Re-corrida | Resultado |
|---|---|---|---|
| `delegation_bypass`: una ruta gestionada sin contrato es rechazada sin eludir la política de permisos | `T9.md` | `delegation_bypass` | VERDE |
| `hook_is_observation`: Stop o quietud sin informe no despierta un modelo | `T9.md` | `hook_is_observation` | VERDE |

### T10 (1 casilla marcada)

Comando `bash scripts/tests/test-agent-work-e2e.sh delivery_latency`, log
`rerun-delivery_latency.log`: escritura durable a detección 4.999 s y detección a recibo durable
0.25 s, contra topes de 5 s y 5 s, mediciones separadas.

| Casilla | Recibo | Re-corrida | Resultado |
|---|---|---|---|
| `delivery_latency` con reloj controlado y ambas mediciones guardadas por separado | `T10-delivery-latency.md` | `delivery_latency` | VERDE |

## SHAs citados (punto 5 del encargo)

Barrido de 129 tokens hexadecimales (7 a 40 caracteres) en `docs/evidence/agent-work/*.md`,
`docs/evidence/agent-work/*.json` y el plan. Clasificación con `rev-parse` y `merge-base --is-ancestor`:

- 37 son ancestros de `encargos/b0` en G.
- 84 son commits de R alcanzables desde el bundle `~/respaldos/openclaw-agent-work/r-2026-10-02.bundle` (16 refs de rama más la base exigida `c074824a27…`).
- 7 resuelven en G sin ser ancestros y quedaron anotados con su equivalente integrado (tabla abajo).
- 1 no resuelve: `e3b0c442`, prefijo del digest sha256 del árbol vacío que registran los runners; no es un commit.

Reemplazos aplicados en esta ronda (el original queda como historia, siempre acompañado del
equivalente):

| Original (rama lateral) | Equivalente integrado (ancestro) | Archivos corregidos |
|---|---|---|
| `e81162e` | `f235b9e` | `T6-T7-prep.md` |
| `4851bad` | `68075f6` | `T6-T7-prep.md` |
| `a718f0e` | `6ff64fa` | `T6-T7-prep.md` |
| `c925363` | `02bf825` | `T6-T7-prep.md`, `status.md` |
| `b7974d3` | `218b834` | `T6-T7-prep.md`, `status.md` |
| `1394a2b` | `759a51c` | `T6-T7-prep.md` |
| `270b2faa` | `3d377ed` | `compatibility-u3b-u6.md` |

Equivalencias probadas con `git cherry HEAD feat/agent-work-b3-prep` (los seis dan `-`, patch-id
idéntico) y por asunto y stat en el caso de `270b2faa`/`3d377ed`.

## Seguridad de merge a main (punto 6 del encargo)

- `coverage.json` mantiene las 7 parejas con `certified: false` (0 habilitadas): los cambios de
  `scripts/mac/` y `agents/*` no activan ninguna ruta viva.
- Suites focalizadas de los archivos tocados, todas con `EXIT=0` (logs `rerun-suite-*.log`):
  `test-corrida-avisos`, `test-tmux-activity-watch`, `test-adaptador-reserva`,
  `test-corrida-nucleo`, `test-corrida-gates`, `test-corrida-reconcile`,
  `test-fase17-progress-event-atomic`, `test-instalar-mac`, `test-agent-dispatch-spawn` y
  `test-native-harness-adapters`.
- Único rojo: `test-cli-modos` por drift del host. El inventario declara claude `2.1.285`, la Mac
  tiene `2.1.287` y `main` declara `2.1.284`, así que ambos árboles salen rojos hoy en esta Mac; en
  CI la entrada se salta al no haber CLI de host (comentario 19.4 dentro de la prueba: el registro
  manda para el ruteo). No es un fallo del diff; quedó en `followups.md`.
- Saltos visibles de las pruebas que necesitan R: `test-agent-work-e2e.sh` sale con código 2 y
  motivo en stderr sin `AGENT_WORK_RUNTIME_SOURCE` ("review_tail_restart requiere
  AGENT_WORK_RUNTIME_SOURCE con R construido"); el runner
  `test_agent_work_review_tail_restart.py` hace `skipTest("set AGENT_WORK_RUNTIME_SOURCE to the
  built R source checkout")`; `test-runtime.sh` vive fuera de `scripts/tests/` precisamente para
  que la batería de G no lo incluya, y el job nativo lo invoca de forma explícita. No fallan ni
  pasan sin correr.

## Casillas abiertas por bloque (bloques 1 a 5)

43 casillas abiertas en los bloques del PROMPT; T12 conserva sus 11 fuera de este loop.

- B1 (T2, T3): 2.
  - T2: revalidar `requester_queue` en la entrega gestionada actual (sesión ocupada recibe su
    continuación tras reiniciar; sesión eliminada produce bloqueo). La re-corrida de esta
    auditoría ya salió verde sobre los heads actuales.
  - T3: ejecutar los casos en rojo.
- B2 (T4, T5): 9.
  - T4: ejecutar las pruebas en rojo; implementar reserva previa, liquidación y perfiles finitos
    (concurrencia, profundidad, hijos y llamadas); eludir el límite con hijo nuevo, sesión nueva y
    recuperación nativa, incluido `managed_tasks_submit` desde un run hijo activo, cancelado y
    recuperado.
  - T5: `idle_72h`; `recovery_limit`; `waiting_reason`; rojos; implementación sobre la cola nativa
    sin supervisores; contador externo del proveedor y ausencia de rutas que lo evadan.
- B3 (T6, T7): 7.
  - T6: ejecutar las pruebas en rojo con socket tmux y directorios de ensayo.
  - T7: `resource_identity`; `resource_close`; rojos; implementación de captura, contención,
    detención y verificación; turno del padre y host inaccesible; `resource_100_cycles`.
- B4 (T8, T9, T10): 18.
  - T8: `projection_crash`; pérdida del ACK de transferencia y tablero caído; `director_handling`;
    rojos; implementación de los puentes; transiciones de revisión `Changes`/`Approved`; transiciones
    mínimas si el director U3b no existe aún.
  - T9: `agents_routing`; rojos; migración de cada entrada del inventario; perímetro gestionado y
    reparador que recree el vigía antiguo.
  - T10: `review_tail_restart`; fronteras de caída con contador externo; rojos; matriz de
    aceptación; focalizadas y hallazgos del bloque; artefacto nativo con baterías; PRs con
    dependencias y limitaciones.
- B5 (solo T11): 7.
  - Manifiesto con versiones, SHA, hashes y migraciones; comandos reales de instalación y
    recuperación; perfil productivo finito en `limits.json`; `cutover_fencing` en rojo; adopción sin
    reiniciar sesiones; reversa de binario y configuración; fallos del propio rollback.
