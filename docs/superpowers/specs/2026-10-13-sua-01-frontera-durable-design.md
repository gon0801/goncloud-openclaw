# SUA-01, frontera durable de OpenClaw: diseño y corte en rebanadas

Fecha: 2026-10-13. Estado: diseño propuesto, sin código. Lo escribió el diseñador del bloque. Lo revisa el revisor asignado antes de implementar.

Bases leídas: G `origin/main` `232399c0` al leer y `2c817ce7` al cerrar, que es donde entró el e2e `ruta_viva` (PR #295). R `/Users/dn/dev/openclaw-agent-work-integration`, rama `feat/agent-work-integration`, HEAD `4acb881e015a`. Ningún comando de este documento se corrió contra la Mac mini. Tampoco se corrió ninguna prueba de R: lo que dice de R sale de leer el código.

Documentos que manda este diseño y que no cambia:
- El bloque "SUA-01" del [plan](../plans/2026-10-05-sistema-agentes-unificado.md).
- El [contrato](../../spec/sistema-agentes.v1.md) `sistema-agentes.v1`.
- El [diseño del sistema](2026-10-05-sistema-agentes-unificado-design.md), secciones "Interfaz propuesta" y "Transacciones, control y recuperación".

Palabras que este documento usa con un solo sentido:

| Palabra | Sentido |
|---|---|
| tarea | Una fila de `managed_tasks`. |
| tarea suelta | Una tarea sin raíz. Hoy todas lo son, y la ruta viva solo crea tareas sueltas. |
| raíz | La meta de un pedido (`root` en los campos). Tiene plan, autoridad, presupuesto y control. |
| unidad | Un elemento del plan de una raíz (`unitId`). |
| intento | Una unidad ligada a una tarea. Su clave es `(rootId, unitId, attempt)`. |
| tarea de raíz | La tarea de un intento. |
| época | La época de control de la raíz (`controlEpoch`). Sube con cada orden aceptada. |
| efecto | Una acción externa con permiso de inicio: push, merge, deploy, envío. |
| solicitante | El agente y la sesión durable que abrieron la raíz. |

## 1. Lo que existe hoy

Todo vive en `src/agents/tasks/` de R. Son 46 archivos y 11 tablas `managed_task_*` (`src/state/openclaw-state-schema.sql:1593-1727`). La versión del esquema de estado es 27 (`OPENCLAW_STATE_SCHEMA_VERSION`, `src/state/openclaw-state-db-contract.ts:29`).

### Ciclo de vida de una tarea

1. **Registro.** `register` (`managed-task.worker.ts:94`) inserta la fila en `managed_tasks`. La clave lógica es `UNIQUE (requester_scope, task_key)`. El mismo par con el mismo `assignment_digest` devuelve el mismo recibo. Con otro digest contesta `Managed task registration conflict`. Un trabajador gestionado no puede crear una tarea propia (`resolveManagedProviderRunInWorker`, misma función).
2. **Presupuesto.** `createBudget` (`managed-task.budget.worker.ts:164`) guarda el perfil de diez llaves en `managed_task_budgets`, con la tarea raíz del árbol como clave. El perfil sale de la configuración (`ManagedTasksConfigSchema`, `src/config/zod-schema.managed-tasks.ts`).
3. **Admisión.** `reserveAdmission` (`managed-task.budget.worker.ts:209`) crea la reserva. `claim` (`managed-task.admission.worker.ts:319`) inserta la admisión en estado `claimed`. Un índice único parcial impide dos admisiones activas de una tarea (`idx_managed_task_active_admission`).
4. **Permiso de inicio.** Para un destino CLI, el host llama `managedTasks.host.claim`, que ata la admisión a su instancia (`claimHostAssignment`, `:28`), y después `managedTasks.host.admit`, que la pasa a `admitted` (`confirmHost`, `:216`). El host lanza el proceso después de ese recibo (`scripts/agent-work/host.py`, `apply`: `admit` y luego `begin_delivery`). Para un destino agente, el pipeline de spawn hace `claim`, comprueba la admisión antes de despachar (`query`, `:402`, vía `assertManagedTaskAdmissionCurrent`) y confirma con la corrida nativa (`confirm`, `:441`; orden en `src/agents/spawn-pipeline.ts:66-140`).
5. **Resultado.** `report` (`managed-task.worker.ts:204`) guarda `result_json` una vez. El mismo digest devuelve el mismo recibo. Otro digest contesta `Managed task result conflict`. En la misma transacción encola el despertar del solicitante (`prepareManagedTaskResultDelivery`, `managed-task.delivery.ts:51`).
6. **Decisión.** `resolveManagedTaskHandling` (`managed-task.handling.worker.ts:50`) guarda una fila en `managed_task_handlings`, una por tarea. `continue` crea hijos con id determinista, `hash([padre, result_digest, slot])`, y los liga en `managed_task_children`. `cancelManagedTaskInWorker` (`:181`) cancela la tarea y sus descendientes.
7. **Cierre del host.** `closeManagedTaskHostInWorker` (`managed-task.host-closure.worker.ts:172`) guarda `CleanupPending`, `AbsenceVerified` o `ReleasedAdopted`. Un cierre terminal exige resultado o cancelación.

El estado no se guarda en una columna. Las tablas guardan hechos con clave primaria y el estado se deriva al leer. `inspect` (`managed-task.worker.ts:469`) calcula `handlingState` a partir de la cancelación, la decisión y el resultado. El esquema de estado no tiene ningún trigger (`grep -c "CREATE TRIGGER" src/state/openclaw-state-schema.sql` imprime 0).

### Qué es transaccional

Cada operación es una transacción síncrona `BEGIN IMMEDIATE` (`runOpenClawStateWriteTransaction`, `src/state/openclaw-state-db.ts:442`). Las órdenes del trabajador de estado corren una a la vez por base (`executeSharedStateCommand`, `src/state/openclaw-state-worker-runtime.ts:175`). Dentro de la transacción, el código vuelve a pedir la autoridad al proceso principal dos veces: al entrar (`requestSqliteWorkerOperationAdmission({ stage: "transaction" })`) y antes de terminar (`stage: "commit"`). Si la autoridad ya no vale, la transacción se deshace. Ejemplo: `register`, `managed-task.worker.ts:106-138`.

En una sola transacción van hoy:
- El resultado, su proyección y el despertar del solicitante (`report`).
- La decisión, los hijos y el recibo (`resolveManagedTaskHandling`).
- La cancelación de todo el subárbol (`cancelManagedTaskInWorker`).
- La incidencia del host y su despertar (`recordManagedTaskHostIncidentInWorker`).

### Cómo se recupera tras un reinicio

No hay estado en memoria que importe. Lo que queda a medias se lee de la base:
- Una admisión `claimed` sin corrida confirmada contesta `needs-reconciliation` (`receipt`, `managed-task.admission.worker.ts:183`) y se ve como espera `admission-uncertain` (`readManagedTaskWait`, `managed-task.wait.worker.ts:22`). No se vuelve a despachar.
- Una reserva de llamada a modelo que se pide dos veces con la misma llave pasa a `uncertain` y no despacha (`reserveModel`, `managed-task.budget.worker.ts:461-473`).
- Un resultado, una decisión o una cancelación repetidos devuelven su recibo original.
- La recuperación automática de una corrida nativa se concede una vez por árbol (`beginRecovery`, `managed-task.recovery.worker.ts:34`).

### Qué garantiza hacia el host

- Solo el dispositivo configurado para ese `hostId` y ese adaptador entra (`assertHostDevice`, `src/gateway/server-methods/managed-tasks.ts:145-162`).
- El host solo ve tareas con admisión activa, sin resultado y sin cancelación, cuyo destino es su `hostId` y su adaptador (`claimHostAssignment`).
- Una admisión queda atada a una instancia. Otra instancia recibe `Managed host assignment is bound to another instance`.
- El host lee la cancelación de su tarea (`readManagedTaskHostCancellationInWorker`).
- La plaza de una tarea CLI se conserva hasta un cierre terminal del host (`managedTaskAdmissionRetainsBudgetSlot`, `managed-task.host-closure.worker.ts:86`).

### Dos anclas que condicionan el diseño

**El solicitante es una instancia de sesión.** `managedTaskRequesterScope` (`managed-task.db.ts:24`) mete `sessionInstance` en el alcance. Ocho comparaciones contra ese alcance protegen las operaciones del solicitante: `managed-task.admission.worker.ts:313`, `managed-task.budget.worker.ts:174` y `:218`, `managed-task.handling.worker.ts:64` y `:194`, `managed-task.worker.ts:474`, `managed-task.wait.worker.ts:135` y `:169`. Después de `/new` la sesión tiene otra instancia. La instancia nueva no ve la tarea (prueba "does not transfer a task to a replacement session incarnation", `managed-task.turn.test.ts:145`). El despertar pendiente va a dead letter (`src/gateway/server-restart-sentinel.ts:148-152`).

**El presupuesto cuelga de una tarea.** `rootForTask` (`managed-task.budget.shared.ts:41`) contesta la tarea raíz del árbol leyendo `managed_task_children`. `managed_task_budgets.root_task_id` referencia `managed_tasks(task_id)`, y `managed_task_budget_reservations.root_task_id` referencia `managed_task_budgets`. Las llaves foráneas están activas.

### Cómo se entrega un cambio de esquema en R

Leído en `src/state/` y en `docs/reference/database-schemas/versioning.md` de R:
- Un binario abre una base de versión menor y la migra al abrir. Un binario de versión menor que la base se niega a abrirla, también en solo lectura (`assertSupportedStateSchemaVersion`, `src/state/openclaw-state-db-schema-version.ts:141-158`). `T12-runbook.md` ya lo dice: "El binario anterior no abre la base migrada", y por eso su reversa restaura la foto de las bases.
- Una tabla nueva puede entrar sin subir la versión, porque un binario viejo ignora las tablas que no conoce (`versioning.md:21`; `collectSqliteSchemaIssues`, `src/infra/sqlite-schema-contract.ts`). La tabla se declara en `LAZY_ADDITIVE_STATE_TABLES` (`openclaw-state-db-contract.ts:88-106`) y la crea una función propia en su primer uso. El patrón es `ensureSecretStoreSchema` (`src/state/openclaw-state-db-schema-additive.ts`).
- Una columna nueva en una tabla que ya existe entra sin subir la versión solo si es un tipo desnudo y anulable. Con `CHECK`, `DEFAULT` o `NOT NULL` hace falta subir la versión.
- Cambiar una restricción, por ejemplo quitar el `UNIQUE` de `managed_task_children.child_task_id`, exige reconstruir la tabla en `versionedStateMigrations` (`src/state/openclaw-state-db-maintenance.ts:553-582`) y subir la versión a 28.
- Los bloques anteriores de tareas gestionadas subieron la versión cada vez (20 a 27) y cada uno dejó su prueba "upgrades a vNN database".

## 2. Lo que falta, punto por punto contra el bloque

Cada fila dice qué pide el plan, qué hay hoy y qué construye SUA-01. La columna "Dónde" apunta a la sección 4.

| Pide el bloque | Hoy en R | Lo que falta | Dónde |
|---|---|---|---|
| Raíz (`root`) junto a las tareas | No existe. "Raíz" hoy quiere decir la primera tarea de un árbol (`rootForTask`). `SessionGoal` está descartado por el contrato. | Una entidad raíz con solicitante, autoridad, presupuesto, plan y control. | 4.1, `managed_roots` |
| Revisión de plan | No hay plan. Una tarea tiene una asignación inmutable (`assignment_digest`). | Revisiones numeradas e inmutables, con `planDigest` y `requestDigest`. Una revisión nueva invalida lo que cambió y conserva lo que no cambió. | 4.1, `managed_root_plans`, y 4.5, `reviseManagedRootPlan` |
| Época de control | No existe. La cancelación es un hecho sin número (`managed_task_cancellations`). | Un registro de órdenes por raíz. Cada orden aceptada es la época siguiente. La admisión y el inicio de un efecto comparan la época que vio quien pide con la vigente. | 4.1, `managed_root_controls`, y 4.2 |
| Claims | No existen. Un resultado `review.v1` trae un veredicto, pero nadie guarda quién acreditó qué criterio. | Claims de evidencia por criterio y por intento, con verificador, artefacto y vigencia. Aceptar un intento exige un claim `passed` suyo por cada criterio. | 4.1, `managed_root_evidence` |
| Binding único | Un hijo de `continue` es único por `(padre, slot)`. No hay unidad ni intento. | La clave `(rootId, unitId, attempt)` liga un intento a una tarea. Una tarea pertenece a un solo intento. Una unidad tiene un solo intento vivo. | 4.1, `managed_root_attempts` |
| Capacidad del solicitante y su recuperación tras `/new` | El alcance incluye la instancia de sesión. Tras `/new` la tarea queda huérfana y el despertar va a dead letter. | La raíz guarda a su dueño sin la instancia, y aparte la instancia vigente con una generación. Una operación explícita mueve la raíz a la instancia nueva del mismo dueño y vuelve a despertar. | 4.4 |
| Contadores persistentes | El gasto se deriva de las reservas. No hay contadores libres. | Una tabla pequeña de contadores por raíz, que solo suben y que se escriben dentro del commit. SUA-05 guarda ahí el contador por linaje. | 4.1, `managed_root_counters` |
| Creación inicial de unidades sin resultado padre | Los hijos solo nacen de `continue`, que exige el recibo de un resultado (`resolveManagedTaskHandling`). | El commit de la raíz crea tareas para las unidades listas. Ninguna tiene padre en `managed_task_children`. | 4.5, `commitManagedRootDecision` |
| Fan-in A+B→C | `managed_task_children.child_task_id` es `UNIQUE`. Una tarea tiene un solo padre. | Las dependencias viven en el plan (`dependsOn`), no en `managed_task_children`. C se liga cuando A y B están aceptadas. El `UNIQUE` no se toca. | 4.5 |
| Pausa de una tarea gestionada | Solo existe cancelar en cascada. | La pausa es de la raíz. Una tarea de raíz pausada no obtiene permiso de inicio. Una tarea suelta no se pausa. | 4.2, 4.3 |
| Control, reservas, reclamación de escritor y efectos en la misma frontera | Las reservas existen. No hay control, escritor ni efectos. | Las cuatro cosas se escriben en transacciones del mismo trabajador de estado, contra las mismas tablas. | 4.5 |
| Serializar `Prepared → Started` con pausa | El análogo es `claimed → admitted` de una admisión, sin pausa con la que competir. | Una transacción por permiso. La pausa y el permiso son escrituras `BEGIN IMMEDIATE` de la misma base, así que una va antes que la otra. El recibo de pausa lista lo que quedó del otro lado. | 4.3 |
| Recibos recuperables tras ACK perdido, reinicio y fallo intermedio | Sí para registro, resultado, decisión y cancelación. | Lo mismo para abrir, controlar, revisar, hacer commit e iniciar un efecto. Cada orden lleva un id y deja un recibo en la misma transacción. | 4.5 |
| Revalidar autorización al admitir y antes de iniciar un efecto | La autoridad del turno se vuelve a comprobar dentro de la transacción. No hay autoridad de la raíz. | La autoridad de la raíz (acciones, repos, destinos, modo, plazo) se comprueba al admitir un intento y al iniciar un efecto, además de la del turno. | 4.3 |
| Cupo global, par atómico, escritor exclusivo (I20) | `maxConcurrentTasks` cuenta por árbol. No hay cupo entre árboles. | Un cupo de plazas para todo el gateway. Dos ligaduras en un commit entran las dos o ninguna. Un recurso de escritura tiene un solo dueño entre todas las raíces. | 4.5 |

## 3. Dos formas de modelar el dominio, comparadas

Antes de elegir se dibujaron tres bocetos completos e independientes, con tablas, restricciones, máquinas de estado y firmas. Uno es del diseñador. Los otros dos son de dos agentes con modelos distintos. A uno se le asignó a propósito la forma B, con el encargo de defender su mejor versión, para que la comparación no fuera contra un muñeco de paja. El otro tuvo postura libre y llegó a la forma A con otra migración. Las dos formas difieren en qué es una raíz.

### Forma A: la raíz es una entidad propia

La raíz vive en tablas nuevas que referencian tareas. Una unidad se ejecuta en una tarea normal, y una tabla de intentos liga `(raíz, unidad, intento)` con esa tarea. Las dependencias viven en el plan. `managed_task_children` no se usa para nada de la raíz.

Su dificultad es el presupuesto. `managed_task_budgets.root_task_id` referencia `managed_tasks`, y una raíz que no es tarea no puede ser dueña de una fila ahí. Tiene dos salidas:

- **A1, sin tocar tablas de hoy.** Cada tarea de raíz recibe su propia fila de presupuesto, y el árbol de una raíz se arma al leer con las tareas de sus intentos. Es código en `managed-task.budget.shared.ts`. La versión se queda en 27.
- **A2, con versión 28.** Se reconstruye `managed_task_budgets` sin la llave foránea a `managed_tasks`, y `root_task_id` pasa a guardar el id de una tarea o el de una raíz. El código de presupuesto cambia menos. La versión sube.

### Forma B: todo es una tarea

La raíz es una fila de `managed_tasks`. Cada intento es una tarea hija de esa fila en `managed_task_children`. El presupuesto por árbol, la cascada de cancelación y `rootForTask` funcionan sin cambiar una línea, porque el árbol ya es lo que esperan.

Su mejor versión, la que entregó el agente asignado, tampoco sube la versión. Encontró que la lectura literal de B no se sostiene:

- Las dependencias no pueden vivir en `managed_task_children`. Dar dos padres a C exige quitar el `UNIQUE`, reconstruir la tabla y subir a 28. Además `rootForTask` y `assertManagedChildBudgetCapacity` suben por un solo padre. C queda como hija de la raíz, y las dependencias en el plan, igual que en A.
- La clave tipada del intento no cabe en `slot`, que es un texto libre. Hace falta una tabla compañera. Cada intento son dos filas, la arista y el binding.
- Plan, claims, control, efectos, escritores, contadores y recibos necesitan tablas propias de todos modos. B salió con nueve tablas nuevas. A1 tiene once.
- `generation` no sirve de `attempt`. Reusar la fila obligaría a pisar `result_json` y a tener varios consumos por tarea.

Así que B no ahorra tablas. Ahorra código de presupuesto y de cascada, y lo paga con una fila que es tarea sin serlo.

### Comparación

| Criterio | A1, raíz propia sin subir versión | B, la raíz es una tarea |
|---|---|---|
| **Complejidad escondida tras la superficie** | La misma superficie en las dos, ocho funciones. A1 esconde además el árbol de presupuesto por raíz y el acceso del solicitante, cada uno en una función (`budgetTreeForTask`, `resolveTaskAccess`). Quien llama no sabe que existen. | Esconde lo mismo reutilizando más código de hoy. Deja fuera una cosa. Tras `/new` reescribe `requester_scope` y `requester_json` en todas las filas del árbol. |
| **Ruta viva: código que cambia** | Las ocho comparaciones de alcance pasan a una función. `rootForTask` pasa a `budgetTreeForTask`. Una rama en `claim` y una en `report`. Una tarea suelta se reconoce por su `requester_scope`, sin leer tablas nuevas. | Tres guardas en `claim`, `resolveManagedTaskHandling` y `cancelManagedTaskInWorker`, que leen una tabla nueva por llave primaria. Tres extracciones de cuerpo de transacción. Menos líneas tocadas que A1. |
| **Datos instalados** | Ninguna tabla de hoy cambia. Versión 27. Tablas nuevas perezosas. | Igual. |
| **Reversa al binario anterior** | Reinstalar el paquete. El binario anterior rechaza por sí solo `resolve`, `cancel` e `inspect` sobre una tarea de raíz, porque su alcance no es el de ningún llamador. | Reinstalar el paquete. El binario anterior no tiene las guardas: `main` puede resolver un intento con `managed_tasks_resolve` y consumir su resultado fuera de la frontera. El propio boceto lo lista como riesgo y añade un estado `consumedOutside` para verlo después. |
| **Lectores externos de `managed_tasks`** | Solo ven tareas de verdad. | Ven la fila raíz como una tarea `awaiting-result` que nunca termina. |
| **Estados ilegales que quedan representables** | La raíz no puede estar admitida, tener resultado, tener cierre de host ni ser hija de otra, porque no es tarea. Quedan cinco reglas en código (4.1). | El boceto lista catorce. Entre ellos: la fila raíz admitida, reportada o resuelta como tarea. Cancelada sin orden, con la época sin subir. Binding con otra raíz que su arista. Cierre de un intento en dos lugares. Árbol con alcances mezclados. Todos con guarda en tiempo de ejecución. |
| **Campos inventados** | Ninguno. | La fila raíz necesita un `assignment` completo y un `producer_token`. Se llenan con el pedido, con el dueño como destino y con `resultContract` forzado a `ready.v1`. |
| **Coste propio** | `maxChildren` y la concurrencia de la raíz se cuentan en el commit, con código nuevo. Una fila de presupuesto por tarea de raíz, con el perfil repetido. | Dos filas por intento. Cada reintento gasta `maxChildren` para siempre. |

A2 frente a A1. A2 deja el presupuesto más limpio, con una fila por raíz y sin perfil repetido. Lo paga con la reversa. El binario 27 no abre una base 28, así que volver atrás es restaurar la foto de las bases o escribir un script de bajada que R no tiene. Para una reconstrucción de una tabla de tres columnas es un precio alto.

### Elección

Se elige **A1**. Tres razones, en este orden:

1. **Estados ilegales.** El encargo pide hacer ilegales los estados ilegales, y es donde las formas más difieren. En B, que la raíz no corra como tarea depende de guardas. En A no hay nada que guardar.
2. **Reversa.** A1 y B dejan los datos instalados igual, pero A1 se defiende sola frente al binario anterior y B no.
3. **Lo que B ahorra se puede tener sin B.** El ahorro de B era no tocar el presupuesto ni las puertas de admisión. A1 toca el presupuesto en una función. Y las puertas de admisión no hacen falta en ninguna de las dos, por la idea que sigue.

Lo que A1 toma de los otros dos bocetos:

| Idea | De dónde | Qué cambia en A1 |
|---|---|---|
| La pausa cerca las admisiones `claimed` con el estado `fenced` que ya existe | B | El boceto del diseñador ponía una puerta nueva en `query`, `confirm`, `confirmHost` y `claimHostAssignment`. Con el cerco, esas cuatro funciones no cambian y un binario anterior también respeta la pausa. Es la mejora más grande. |
| La tabla de transiciones de control como `CHECK`, y la cadena de épocas como llave foránea a la fila anterior | B | "La época sube de uno en uno" y "no hay orden tras `cancelled`" pasan de código a esquema. Lo mismo para revisiones e intentos. |
| El contador como ordinales con clave primaria | B | Dos commits no pueden subir un contador desde el mismo valor. Antes era una comparación en código. |
| Recuperar todas las raíces del dueño sin dar `rootId` | B | La sesión nueva no recuerda ningún `rootId`. |
| El control como registro de solo inserción donde cada fila es su recibo | A2 | `managed_roots` deja de tener columnas de control que pudieran discrepar de su recibo. |
| El recibo del commit se inserta primero y cada hecho lo referencia | A2 | Un hecho sin recibo deja de ser representable. |
| Un efecto solo avanza, y reintentar es un efecto nuevo | B | El boceto del diseñador devolvía un efecto a `prepared`. Se quitó el ciclo. |

Lo que se descartó de ellos, y por qué:

- **Admitir dentro del commit** (B). El pipeline nativo exige que su propio `claim` conteste `claimed`. Una admisión que ya existe contesta `needs-reconciliation` y el pipeline aborta (`src/agents/spawn-pipeline.ts:78-82`). Admitir sigue siendo un paso aparte, por el camino de hoy.
- **Tablas de cupo con filas de reclamo** (A2). Cada camino de salida tendría que acordarse de liberar la fila. Aquí la plaza se deriva.
- **Aceptación por revisión de plan** (A2 y B). Cada revisión tiraría toda la evidencia, o pediría una lista de arrastre con texto libre. Aquí decide la huella de la unidad (4.2).
- **Efectos como pasos de solo inserción** (B). Es más estricto. Se prefirió una fila con estado y `CHECK`, que es lo que R ya hace con la admisión, para no sumar una tabla.

Ninguno de los tres bocetos pidió a un segundo modelo que revisara a otro. Fueron candidatos, no revisiones. El DDL de 4.1 se ejecutó en SQLite junto al esquema real de R, con una inserción ilegal por cada restricción. El resultado está al final de 4.1.

## 4. El diseño elegido

Una frase lo resume. La raíz es una entidad propia, guardada en once tablas nuevas junto a las once de tareas. Una unidad se ejecuta en una tarea normal. Las once tablas de hoy no cambian y la versión del esquema se queda en 27.

### 4.1 Modelo de datos

#### Tablas nuevas

Las once van al final del bloque de tareas en `src/state/openclaw-state-schema.sql`. Todas son `STRICT`. Los nombres de columna evitan `token`, `secret`, `password` y `credential`, que la prueba `secret-state-tables.test.ts` trata como columnas de credencial.

```sql
-- La raíz. Una fila por pedido. No se actualiza nunca: lo que cambia vive en las tablas de abajo.
CREATE TABLE IF NOT EXISTS managed_roots (
  root_id TEXT NOT NULL PRIMARY KEY,
  owner_scope TEXT NOT NULL,            -- dueño sin instancia de sesión: principal, agentId, sessionKey
  open_idempotency TEXT NOT NULL,       -- idempotencyKey de open
  open_digest TEXT NOT NULL,            -- digest del pedido de apertura completo
  contract_version TEXT NOT NULL,       -- literal del contrato con el que se abrió
  owner_json TEXT NOT NULL,
  request_digest TEXT NOT NULL,
  authority_json TEXT NOT NULL,
  budget_json TEXT NOT NULL,            -- las diez llaves de ManagedBudgetProfile
  quality_policy TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE (owner_scope, open_idempotency)
) STRICT;

-- Instancia de sesión del solicitante. Solo se insertan filas. La vigente es la de generación mayor.
CREATE TABLE IF NOT EXISTS managed_root_requesters (
  root_id TEXT NOT NULL REFERENCES managed_roots(root_id),
  generation INTEGER NOT NULL CHECK (generation > 0),
  prev_generation INTEGER,
  instance TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (root_id, generation),
  UNIQUE (root_id, instance),
  CHECK ((generation = 1 AND prev_generation IS NULL) OR
         (prev_generation IS NOT NULL AND prev_generation = generation - 1)),
  FOREIGN KEY (root_id, prev_generation) REFERENCES managed_root_requesters(root_id, generation)
) STRICT;

-- Control. Solo se insertan filas. El control vigente es la fila de época mayor.
-- Cada fila es el recibo de su orden. La tabla de transiciones es el CHECK y la cadena es la llave foránea.
CREATE TABLE IF NOT EXISTS managed_root_controls (
  root_id TEXT NOT NULL REFERENCES managed_roots(root_id),
  epoch INTEGER NOT NULL CHECK (epoch > 0),
  prev_epoch INTEGER,
  prev_state TEXT,
  command TEXT NOT NULL,
  state TEXT NOT NULL,
  reason TEXT,
  command_id TEXT NOT NULL,             -- 'open' para la época 1
  command_digest TEXT NOT NULL,
  receipt_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (root_id, epoch),
  UNIQUE (root_id, command_id),
  UNIQUE (root_id, epoch, state),
  CHECK ((epoch = 1 AND prev_epoch IS NULL AND prev_state IS NULL AND command = 'open' AND state = 'active') OR
         (prev_epoch IS NOT NULL AND prev_state IS NOT NULL AND prev_epoch = epoch - 1 AND (
           (command = 'pause'  AND prev_state = 'active' AND state = 'paused') OR
           (command = 'resume' AND prev_state = 'paused' AND state = 'active') OR
           (command = 'cancel' AND prev_state IN ('active', 'paused') AND state = 'cancelled')))),
  FOREIGN KEY (root_id, prev_epoch, prev_state)
    REFERENCES managed_root_controls(root_id, epoch, state)
) STRICT;

-- Revisiones de plan. Solo se insertan. La vigente es la de número mayor.
-- Cada fila es el recibo de su orden. La llave foránea a la anterior impide huecos.
CREATE TABLE IF NOT EXISTS managed_root_plans (
  root_id TEXT NOT NULL REFERENCES managed_roots(root_id),
  revision INTEGER NOT NULL CHECK (revision > 0),
  prev_revision INTEGER,
  plan_digest TEXT NOT NULL,
  assumptions_json TEXT NOT NULL,
  scope_change_json TEXT,               -- criterios quitados y la autoridad que lo permitió
  revision_id TEXT NOT NULL,            -- 'open' para la revisión 1
  revision_digest TEXT NOT NULL,
  receipt_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (root_id, revision),
  UNIQUE (root_id, revision_id),
  CHECK ((revision = 1 AND prev_revision IS NULL) OR
         (prev_revision IS NOT NULL AND prev_revision = revision - 1)),
  FOREIGN KEY (root_id, prev_revision) REFERENCES managed_root_plans(root_id, revision)
) STRICT;

-- Unidades de cada revisión. Solo se insertan.
CREATE TABLE IF NOT EXISTS managed_root_units (
  root_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  unit_id TEXT NOT NULL,
  unit_digest TEXT NOT NULL,            -- huella de la unidad y de todo aquello de lo que depende (4.2)
  unit_json TEXT NOT NULL,              -- title, dependsOn, criteria, scope
  PRIMARY KEY (root_id, revision, unit_id),
  UNIQUE (root_id, revision, unit_id, unit_digest),
  FOREIGN KEY (root_id, revision) REFERENCES managed_root_plans(root_id, revision)
) STRICT;

-- Recibo de cada commit. Se inserta primero, y cada hecho del commit lo referencia.
CREATE TABLE IF NOT EXISTS managed_root_commits (
  root_id TEXT NOT NULL REFERENCES managed_roots(root_id),
  commit_id TEXT NOT NULL,              -- decisionId
  commit_digest TEXT NOT NULL,
  plan_revision INTEGER NOT NULL,
  control_epoch INTEGER NOT NULL,
  receipt_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (root_id, commit_id),
  FOREIGN KEY (root_id, plan_revision) REFERENCES managed_root_plans(root_id, revision),
  FOREIGN KEY (root_id, control_epoch) REFERENCES managed_root_controls(root_id, epoch)
) STRICT;

-- Intentos: el binding único de una unidad a una tarea.
CREATE TABLE IF NOT EXISTS managed_root_attempts (
  root_id TEXT NOT NULL,
  unit_id TEXT NOT NULL,
  attempt INTEGER NOT NULL CHECK (attempt > 0),
  prev_attempt INTEGER,
  plan_revision INTEGER NOT NULL,
  unit_digest TEXT NOT NULL,
  task_id TEXT NOT NULL UNIQUE REFERENCES managed_tasks(task_id),
  commit_id TEXT NOT NULL,
  admission_epoch INTEGER,              -- época de su última admisión; nula si nunca se admitió
  outcome TEXT CHECK (outcome IN ('accepted', 'failed', 'cancelled')),
  outcome_ref TEXT,                     -- el commit, la época o la revisión que lo terminó
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (root_id, unit_id, attempt),
  FOREIGN KEY (root_id, plan_revision, unit_id, unit_digest)
    REFERENCES managed_root_units(root_id, revision, unit_id, unit_digest),
  FOREIGN KEY (root_id, commit_id) REFERENCES managed_root_commits(root_id, commit_id),
  FOREIGN KEY (root_id, admission_epoch) REFERENCES managed_root_controls(root_id, epoch),
  FOREIGN KEY (root_id, unit_id, prev_attempt)
    REFERENCES managed_root_attempts(root_id, unit_id, attempt),
  CHECK ((attempt = 1 AND prev_attempt IS NULL) OR
         (prev_attempt IS NOT NULL AND prev_attempt = attempt - 1)),
  CHECK ((outcome IS NULL) = (outcome_ref IS NULL))
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_managed_root_attempts_live
  ON managed_root_attempts(root_id, unit_id) WHERE outcome IS NULL;

-- Claims de evidencia. Solo se insertan. Cada claim acredita el resultado de un intento.
CREATE TABLE IF NOT EXISTS managed_root_evidence (
  root_id TEXT NOT NULL,
  evidence_id TEXT NOT NULL,
  plan_revision INTEGER NOT NULL,       -- revisión vigente cuando se guardó
  unit_id TEXT NOT NULL,
  attempt INTEGER NOT NULL,
  criterion_id TEXT NOT NULL,
  verifier_role TEXT NOT NULL CHECK (verifier_role IN ('reviewer', 'verifier', 'ci', 'owner')),
  outcome TEXT NOT NULL CHECK (outcome IN ('passed', 'failed', 'unknown')),
  expires_at INTEGER,
  claim_json TEXT NOT NULL,
  claim_digest TEXT NOT NULL,
  commit_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (root_id, evidence_id),
  FOREIGN KEY (root_id, plan_revision) REFERENCES managed_root_plans(root_id, revision),
  FOREIGN KEY (root_id, unit_id, attempt)
    REFERENCES managed_root_attempts(root_id, unit_id, attempt),
  FOREIGN KEY (root_id, commit_id) REFERENCES managed_root_commits(root_id, commit_id)
) STRICT;

CREATE INDEX IF NOT EXISTS idx_managed_root_evidence_criterion
  ON managed_root_evidence(root_id, unit_id, attempt, criterion_id);

-- Efectos externos.
CREATE TABLE IF NOT EXISTS managed_root_effects (
  root_id TEXT NOT NULL,
  effect_id TEXT NOT NULL,
  plan_revision INTEGER,
  unit_id TEXT,
  unit_digest TEXT,
  intent_json TEXT NOT NULL,            -- action, repo, destination, mode
  intent_digest TEXT NOT NULL,
  destination TEXT,                     -- destino ya redactado, para el recibo de pausa
  resource_ref TEXT,                    -- recurso de escritura que la unidad debe tener para iniciar
  cancellable INTEGER NOT NULL CHECK (cancellable IN (0, 1)),
  commit_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('prepared', 'started', 'confirmed', 'uncertain')),
  start_id TEXT,
  started_epoch INTEGER,
  settlement_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (root_id, effect_id),
  FOREIGN KEY (root_id, plan_revision, unit_id, unit_digest)
    REFERENCES managed_root_units(root_id, revision, unit_id, unit_digest),
  FOREIGN KEY (root_id, commit_id) REFERENCES managed_root_commits(root_id, commit_id),
  FOREIGN KEY (root_id, started_epoch) REFERENCES managed_root_controls(root_id, epoch),
  CHECK ((unit_id IS NULL) = (unit_digest IS NULL) AND (unit_id IS NULL) = (plan_revision IS NULL)),
  CHECK (resource_ref IS NULL OR unit_id IS NOT NULL),
  CHECK ((state = 'prepared') = (start_id IS NULL)),
  CHECK ((start_id IS NULL) = (started_epoch IS NULL)),
  CHECK (state != 'confirmed' OR settlement_json IS NOT NULL)
) STRICT;

-- Dueño exclusivo de un recurso de escritura, entre todas las raíces.
CREATE TABLE IF NOT EXISTS managed_root_writers (
  resource_ref TEXT NOT NULL,
  root_id TEXT NOT NULL,
  unit_id TEXT NOT NULL,
  commit_id TEXT NOT NULL,              -- el commit que lo reclamó
  claimed_at INTEGER NOT NULL,
  released_at INTEGER,
  release_ref TEXT,                     -- el commit, la época o la revisión que lo liberó
  PRIMARY KEY (resource_ref, root_id, commit_id),
  FOREIGN KEY (root_id, commit_id) REFERENCES managed_root_commits(root_id, commit_id),
  CHECK ((released_at IS NULL) = (release_ref IS NULL))
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_managed_root_writers_live
  ON managed_root_writers(resource_ref) WHERE released_at IS NULL;

-- Contadores que solo suben, de uno en uno. El valor es el ordinal mayor.
CREATE TABLE IF NOT EXISTS managed_root_counters (
  root_id TEXT NOT NULL,
  counter_ref TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK (ordinal > 0),
  prev_ordinal INTEGER,
  commit_id TEXT NOT NULL,
  PRIMARY KEY (root_id, counter_ref, ordinal),
  CHECK ((ordinal = 1 AND prev_ordinal IS NULL) OR
         (prev_ordinal IS NOT NULL AND prev_ordinal = ordinal - 1)),
  FOREIGN KEY (root_id, counter_ref, prev_ordinal)
    REFERENCES managed_root_counters(root_id, counter_ref, ordinal),
  FOREIGN KEY (root_id, commit_id) REFERENCES managed_root_commits(root_id, commit_id)
) STRICT;
```

#### Qué estado ilegal cierra cada restricción

| Estado ilegal | Lo cierra |
|---|---|
| Dos raíces para el mismo pedido reintentado | `UNIQUE (owner_scope, open_idempotency)` |
| Una raíz que es a la vez tarea: admitida, con resultado o hija de otra | La raíz no es una fila de `managed_tasks` |
| Una raíz que no nace activa en la época 1 | Primer renglón del `CHECK` de `managed_root_controls` |
| `resume` sobre una raíz activa, `pause` sobre una pausada, cualquier orden tras `cancelled` | El `CHECK` de transiciones. Ningún renglón acepta `prev_state = 'cancelled'` |
| Una época saltada, repetida o que sale de un estado que no era el anterior | Clave primaria, `prev_epoch = epoch - 1` y la llave foránea `(root_id, prev_epoch, prev_state)` |
| La misma orden con dos épocas | `UNIQUE (root_id, command_id)` |
| Una revisión 3 sin revisión 2, o dos revisiones 2 | Clave primaria, `CHECK` y llave foránea a la revisión anterior |
| Un commit que cita una revisión o una época que no existen | Las dos llaves foráneas de `managed_root_commits` |
| Un commit repetido que se ejecuta dos veces | Clave primaria de `managed_root_commits` |
| Un hecho sin el commit que lo escribió | `commit_id` con llave foránea en intentos, claims, efectos, escritores y contadores |
| Dos C para la misma unidad e intento | Clave primaria de `managed_root_attempts` |
| Dos intentos vivos de una unidad | `idx_managed_root_attempts_live` |
| Un intento 3 sin intento 2 | `CHECK` y llave foránea al intento anterior |
| Una tarea que sirve a dos intentos | `task_id UNIQUE` |
| Un intento de una unidad que el plan no tiene | Llave foránea compuesta hacia `managed_root_units` |
| Un intento terminado sin la orden que lo terminó | `CHECK ((outcome IS NULL) = (outcome_ref IS NULL))` |
| Un intento admitido en una época que no existió | Llave foránea de `admission_epoch` |
| Un claim con resultado o verificador fuera del contrato | Los dos `CHECK` de `managed_root_evidence` |
| Un claim sobre un intento que no existe | Llave foránea compuesta hacia `managed_root_attempts` |
| Un efecto `prepared` que ya tiene permiso, o `started` sin permiso | `CHECK ((state = 'prepared') = (start_id IS NULL))` |
| Un permiso de una época que no existió | `started_epoch` con llave foránea a `managed_root_controls` |
| Un efecto `confirmed` sin prueba | `CHECK (state != 'confirmed' OR settlement_json IS NOT NULL)` |
| Un efecto que exige un escritor sin pertenecer a una unidad | `CHECK (resource_ref IS NULL OR unit_id IS NOT NULL)` |
| Dos dueños vivos de un recurso de escritura | `idx_managed_root_writers_live` |
| Un contador que vale cero, que salta o que dos commits suben al mismo valor | `CHECK (ordinal > 0)`, la clave primaria con `ordinal` y la llave foránea al ordinal anterior |
| Dos generaciones del solicitante con la misma instancia, o una generación que salta | `UNIQUE (root_id, instance)`, y `CHECK` más llave foránea a la generación anterior |

Cinco reglas no caben en SQLite sin triggers, y el esquema de estado no usa triggers. Cada una se comprueba en una sola función, dentro de la transacción, y cada una tiene su caso de prueba (sección 5):
1. Un estado terminal no cambia. Un intento con `outcome` no vuelve a vivo y un efecto no retrocede. Las escrituras de `outcome` y de `state` usan `UPDATE ... WHERE` con el estado anterior y exigen una fila cambiada. Es el mismo recurso que usa hoy la admisión para pasar de `claimed` a `admitted`.
2. La tarea de un intento es una tarea de esa raíz. La llave foránea solo exige que la tarea exista. El commit crea la tarea en la misma transacción, con el alcance `{ kind: "root", rootId }`, y nunca liga una que ya existía.
3. La época que sella una admisión, un permiso o un commit es la vigente y está `active`. La llave foránea garantiza que la época existió, no que fuera activa.
4. Una raíz tiene siempre su época 1, su revisión 1 y su generación 1. Las inserta `openManagedRoot` en la misma transacción que la raíz.
5. No queda un escritor vivo a nombre de una unidad aceptada, de una unidad que salió del plan ni de una raíz cancelada. Lo hace `releaseUnitWriters`, la única función que libera, en la misma transacción que cambia ese estado.

**Comprobado.** El DDL de arriba se ejecutó en SQLite 3.51.0 junto al esquema completo de R (`src/state/openclaw-state-schema.sql` en `4acb881e`), con las llaves foráneas activas. Un script inserta una cadena legal y después intenta cada estado ilegal de la tabla. Las 62 inserciones o actualizaciones ilegales se rechazaron, cada una por su restricción, y las 29 legales entraron. Ocho de las ilegales prueban cada cadena con el campo `prev_` en nulo: en SQLite un `CHECK` que vale nulo pasa, y por eso cada cadena exige `prev_` no nulo. El script también ejecuta el cerco de una admisión sobre la tabla de hoy (4.3):

```
bash docs/evidence/sistema-agentes-unificado/SUA-01-ddl-probe.sh \
  docs/superpowers/specs/2026-10-13-sua-01-frontera-durable-design.md \
  /Users/dn/dev/openclaw-agent-work-integration
# sqlite 3.51.0: 91 comprobaciones bien, 0 mal
```

El script lee el DDL de este documento, así que comprueba lo que está escrito aquí. No comprueba que R acepte estas tablas como perezosas. Eso es el `unknown` 2 de la sección 8.

#### Lo que se deriva y por eso no se guarda

- **La revisión vigente.** Es la fila de `managed_root_plans` con el número mayor.
- **El control vigente.** Es la fila de `managed_root_controls` con la época mayor. `managed_roots` no tiene columnas de control que puedan quedar desfasadas de su recibo.
- **La instancia vigente del solicitante.** Es la fila de `managed_root_requesters` con la generación mayor.
- **El estado de un intento.** Sale de hechos que ya existen (4.2). No hay columna `state`.
- **La plaza ocupada.** Sale de los intentos vivos y de las admisiones activas (4.5). No hay fila que alguien tenga que acordarse de liberar.
- **El gasto.** Sale de `managed_task_budget_reservations`, como hoy.
- **Si un efecto todavía puede iniciar.** Sale de su estado, del control de la raíz y de si su unidad sigue en el plan. Por eso no hace falta un quinto estado "anulado".

#### Lo que cambia en las tablas de hoy

Ninguna definición cambia. Cambian cinco contenidos, todos compatibles con el binario instalado:

1. **Tareas de raíz en `managed_tasks`.** Son filas normales. Su `requester_scope` es `managedTaskJson({ kind: "root", rootId })` y su `task_key` es `unit:<unitId>:<attempt>`. Su `requester_json` guarda el llamador `agent` del turno que hizo el commit, que es el dueño. Tiene que ser así, porque `confirm` exige `kind: "agent"` y que su `sessionKey` sea el del solicitante de la corrida nativa (`managed-task.admission.worker.ts:495-508`). `report` y `recordManagedTaskHostIncidentInWorker` no usan la `sessionInstance` de ese campo para una tarea de raíz. Usan la vigente (4.4). Ningún solicitante de hoy puede producir ese alcance, porque `managedTaskRequesterScope` solo emite `kind: "agent"` o `kind: "director"`. Por eso las ocho comparaciones de hoy rechazan una tarea de raíz sin tocar una línea, y una tarea suelta nunca se confunde con una de raíz.
2. **Una fila de presupuesto por tarea de raíz.** `managed_task_budgets` guarda una fila con `root_task_id` igual a la propia tarea y el perfil de la raíz. Así las reservas conservan su llave foránea. El árbol de una raíz se arma al leer (4.5, `BudgetTree`).
3. **Admisiones cercadas por una pausa.** La pausa pasa a `fenced` las admisiones `claimed` de la raíz y anula su `claim_id` y su `request_digest`, como exige el `CHECK` de la tabla (4.3). `fenced` es un estado que la tabla ya tiene.
4. **Un consumo en `managed_task_handlings`.** Cuando un commit consume el resultado de una tarea de raíz, inserta la fila de esa tarea con `decision_json` `{ "kind": "root", "rootId", "decisionId" }`, `decision_digest` igual a la huella de ese JSON y `receipt_json` `{ taskId, resultDigest, decisionDigest, childTaskIds: [] }`. `ManagedTaskHandlingDecision` gana esa variante. La clave primaria garantiza un solo consumo. `inspect` sigue contestando `handled`.
5. **Cancelaciones con razón de la raíz.** `managed_task_cancellations.reason` no admite nulo. Una tarea cancelada por la raíz lleva `root-cancelled:<rootId>:<época>`, `root-revised:<rootId>:<revisión>` o `root-commit:<rootId>:<decisionId>`, y su `cancellation_id` es `hash([taskId, reason])`, como hoy.

#### Migración, versión y reversa

**No se sube la versión del esquema.** Las once tablas entran como tablas aditivas perezosas:
- Sus nombres van a `LAZY_ADDITIVE_STATE_TABLES` y sus tres índices a `LAZY_ADDITIVE_STATE_INDEXES` (`src/state/openclaw-state-db-contract.ts`).
- `ensureManagedRootSchema(database)` ejecuta su DDL canónico, con el patrón de `ensureSecretStoreSchema`. Hace una extracción por tabla con `extractSqliteTableSchema`, en el orden del DDL, y para las tablas que tienen índice usa de marcador final la última línea de ese índice. La llama `openManagedRoot` y nadie más. Sin una raíz abierta ninguna otra orden tiene sobre qué escribir. `readManagedRoot` y `recoverManagedRootRequester` contestan vacío si las tablas no existen, sin crearlas.
- Una base instalada en la versión 27 se abre igual que hoy. Las tablas no existen hasta que alguien abre la primera raíz. Una base nueva las crea al nacer.

**No hay datos que migrar.** Las tareas instaladas siguen sueltas. Ninguna recibe una raíz retroactiva.

**La versión de los datos va en la raíz.** `contract_version` guarda el literal del contrato con el que se abrió. El contrato lo pide: "Una raíz conserva la versión con la que se abrió". El literal lo valida el parser, no un `CHECK`. Así una versión 2 del contrato no obliga a reconstruir la tabla.

**Reversa.** Se reinstala el paquete anterior (`4acb881e`) y nada más. Ese binario abre la base porque la versión sigue en 27 y porque ignora las tablas que no conoce. No hay que restaurar la foto de las bases. Dos condiciones:
- Mientras no exista ninguna raíz, la reversa no pierde ni cambia nada. SUA-01 no abre raíces en producción, así que esta es la situación de todo el bloque.
- Con raíces abiertas, el binario anterior no las conoce. No puede admitir, decidir ni cancelar sus tareas, porque el alcance de una tarea de raíz no es el de ningún llamador. Respeta las admisiones que una pausa ya cercó. Lo que sí hace es dejar que un host inicie una admisión que ya estaba `claimed` en una raíz activa, y guardar resultados que nadie consume. Por eso, antes de volver atrás se pausan las raíces. La pausa cerca todo lo que no había iniciado. Es la regla del diseño del sistema ("volver al dueño anterior requiere drenaje"). El primer bloque que active raíces en producción decide si sube la versión para que un binario viejo no pueda abrir esa base. `LAZY_ADDITIVE_STATE_TABLES` ya lo prevé: "fold them into the next natural schema-version bump".

**Archivos que el cambio de esquema arrastra**, cada uno con la prueba o el chequeo que lo exige:

| Archivo | Por qué |
|---|---|
| `src/state/openclaw-state-db.generated.d.ts` | `pnpm db:kysely:gen`. `pnpm db:kysely:check` falla si no coincide. |
| `src/agents/tasks/managed-task.db.ts`, `ManagedTaskDatabase` | La lista de tablas es manual. |
| `src/state/secret-state-tables.ts`, `STATE_SECRET_DEPENDENT_TABLE_NAMES` | `managed_root_attempts` depende de `managed_tasks`, que los respaldos redactados omiten. Las once van a la lista. |
| `src/snapshot/git-backup-codec.test.ts` y `docs/cli/backup.md` | Lista literal de tablas excluidas. |
| `src/state/openclaw-state-db.test.ts:4853`, tope de lecturas del doctor (`<= 897`) | Más tablas e índices suben la cuenta. |
| `test/vitest/vitest.database-worker-core-paths.mjs` | Cada archivo de prueba nuevo se declara ahí. |

### 4.2 Máquinas de estado

Las cuatro son funciones puras en `managed-root.machine.ts`. Reciben datos y devuelven datos. Las transacciones las llaman y escriben el resultado.

#### Control de la raíz, con época

`nextRootControl(control, command)`. Una raíz nace `active` en la época 1. Una orden aceptada inserta una fila en `managed_root_controls` con la época siguiente. Una orden rechazada no escribe nada. La misma tabla de abajo está escrita como `CHECK` en el esquema (4.1), así que la función y la base no pueden discrepar sin que la inserción falle.

| Estado | `pause` | `resume` | `cancel` |
|---|---|---|---|
| `active` | `paused`, época + 1 | conflicto `transition-refused` | `cancelled`, época + 1 |
| `paused` | conflicto `transition-refused` | `active`, época + 1 | `cancelled`, época + 1 |
| `cancelled` | conflicto `transition-refused` | conflicto `transition-refused` | conflicto `transition-refused` |

Antes de mirar esta tabla, la transacción resuelve dos cosas, en este orden:

1. **Repetición.** Si `(rootId, commandId)` ya tiene fila y el digest de la orden es el mismo, devuelve su `receipt_json` con `replayed: true`. No sube la época. Si el digest es otro, contesta `operation-conflict`. Así una repetición exacta de `cancel` sobre una raíz ya cancelada devuelve su recibo.
2. **Época esperada.** Si `expectedControlEpoch` no es la época de la raíz, contesta `stale-control-epoch` con la época vigente. Un `resume` que vio una época vieja falla aquí.

`cancel` es terminal. `resume` no borra ni reinicia nada. Las reservas, los contadores, los intentos y los recibos siguen donde estaban.

#### Intento de una unidad

El contrato fija ocho estados y sus transiciones (`TRANSICIONES`, `scripts/sistema_agentes/contrato.py:65-74`). R no guarda el estado. `deriveAttemptState(facts)` lo calcula con el primer renglón que se cumpla:

| Orden | Hecho | Estado | Quién escribe el hecho |
|---|---|---|---|
| 1 | `outcome` del intento no es nulo | `accepted`, `failed` o `cancelled` | `commitManagedRootDecision`, `controlManagedRoot` (cancel), `reviseManagedRootPlan` |
| 2 | La tarea tiene `result_json` | `reported` | `report`, sin cambios |
| 3 | La tarea tiene una admisión `admitted` | `running` | `confirm` o `confirmHost` |
| 4 | El intento tiene `admission_epoch` | `admitted` | `claim` |
| 5 | Existe el intento | `ready` | `commitManagedRootDecision` (ligadura) |

Una unidad del plan vigente que no tiene intento no pasa por esta función. Su estado es `ready` si todas sus dependencias están aceptadas y `pending` si falta alguna. `readManagedRoot` la entrega aparte, en `unbound` (4.5 y 4.8, conflicto 9).

"Aceptada" quiere decir que el último intento de la unidad tiene `outcome = 'accepted'` y que la unidad tuvo esa misma `unit_digest` en todas las revisiones desde la `plan_revision` del intento hasta la vigente. Si una revisión cambia o quita la unidad y otra la deja como estaba, la aceptación vieja no revive, aunque nadie haya ligado un intento entre medio.

Cada escritura corresponde a una transición que el contrato permite:

| Transición | Operación | Condición que comprueba |
|---|---|---|
| `pending → ready` | Ninguna | Dependencias aceptadas |
| `ready → admitted` | `claim` | Raíz activa, época y revisión esperadas, intento vivo, autoridad vigente (4.3) |
| `admitted → running` | `confirm`, `confirmHost` | Las de hoy. Una admisión cercada o una tarea cancelada no pasan |
| `running → reported` | `report` | Las de hoy |
| `reported → accepted` | Commit, `outcomes` | Un claim `passed`, sin vencer y de ese mismo intento, por cada criterio. El resultado está consumido |
| `reported → failed`, `running → failed` | Commit, `outcomes` | El estado derivado es `reported` o `running`. Si no hay resultado, la misma transacción cancela la tarea |
| No terminal `→ cancelled` | `controlManagedRoot` (cancel), `reviseManagedRootPlan`, commit | El intento sigue vivo |
| Terminal `→` cualquiera | Ninguna | El renglón 1 gana siempre. Un resultado tardío se guarda en la tarea y no cambia el estado |

El commit rechaza `failed` sobre un intento `ready` o `admitted`, porque el contrato no tiene esa transición. Ese intento se cancela. La regla la da `attemptTransitionAllowed(from, to)`, que es la tabla `TRANSICIONES` del contrato.

**La huella de la unidad.** `digestPlanUnits(units)` calcula para cada unidad la huella de `[unitId, criterios ordenados por criterionId con sus tres campos, repos ordenados, mode, huellas de sus dependencias ordenadas]`. El título queda fuera. Toda huella de este diseño es `sha256:` seguido de `sha256(managedTaskJson(valor))` en hexadecimal, la forma que pide el contrato. Dos consecuencias:
- Una unidad que no cambió, y cuyas dependencias tampoco, conserva su huella entre revisiones. Su intento, los claims de ese intento y su aceptación siguen valiendo sin copiar nada.
- Una unidad que cambió, o que depende de una que cambió, tiene otra huella. Su aceptación deja de contar, su intento vivo se cancela en la misma transacción de la revisión, y los claims de ese intento se quedan con él.

Esa es la forma en que este diseño cumple "una revisión nueva invalida claims y admisiones afectados" y "conserva los válidos con una justificación comprobable". La justificación es la igualdad de huellas, que queda escrita en `managed_root_units`.

#### Efecto

`nextEffectState(state, event)`. La máquina solo avanza.

| Estado | `start` | `settle: confirmed` | `settle: uncertain` |
|---|---|---|---|
| `prepared` | `started`, si la puerta deja (4.3) | rechazado | rechazado |
| `started` | mismo `startId`: recibo original. Otro `startId`: rechazado | `confirmed` | `uncertain` |
| `uncertain` | rechazado | `confirmed` | recibo original |
| `confirmed` | rechazado | recibo original | rechazado |

- `Started` es el permiso de inicio. No dice que el destino recibió nada. Un efecto recibe un solo permiso en su vida.
- Un permiso que quedó en `started` tras una caída no autoriza un segundo envío a ciegas. Quien lo encuentra concilia primero con el destino. Si prueba que el envío no ocurrió, puede enviar con ese mismo permiso. Si no puede saberlo, asienta `uncertain`. El precedente en R es la reserva de modelo, que pasa a `uncertain` cuando se pide dos veces (`reserveModel`).
- `confirmed` quiere decir que el resultado se conoce, con su evidencia. El asiento lleva `occurred: true` o `occurred: false`. Un efecto `confirmed` no se repite: `start` lo rechaza. Reintentar es preparar un efecto nuevo, con otro `effectId`, en un commit nuevo. Así el reintento es una decisión y deja recibo.
- Un efecto `uncertain` conserva su fila y bloquea `start` hasta que alguien concilie y asiente `confirmed`.

#### Pausa

La pausa no es un estado de la tarea. Es el estado `paused` de la raíz. Su transacción hace dos cosas además de subir la época: cerca las admisiones que todavía no tenían permiso, y anota lo que ya lo tenía (4.3). Lo que la pausa hace con cada cosa:

| Cosa | Con la raíz en `paused` |
|---|---|
| Intento `ready` | No se puede admitir. Conserva su tarea, su plaza y sus escritores. |
| Intento `admitted` | Su admisión `claimed` pasa a `fenced` y ya no puede iniciar nunca. El intento sigue `admitted`, con la época vieja en `admission_epoch`. Es la "admisión con época obsoleta" del contrato. Tras `resume`, el solicitante lo admite otra vez con otra `admissionKey`, y eso actualiza la época. Conserva su plaza todo ese tiempo. |
| Intento `running` | Sigue. Tenía permiso antes de la pausa. Sale en el recibo. |
| Efecto `prepared` | `start` lo rechaza. Sigue `prepared` y puede iniciar tras `resume`. |
| Efecto `started` o `uncertain` | Sigue su curso. Sale en el recibo. |
| Commit | Se rechaza con `root-not-active`. |
| Revisión de plan | Se permite. |
| Resultado que llega | Se guarda en la tarea, como hoy. Se consume después de `resume`. |
| Tarea suelta | Nada. No tiene raíz. |

### 4.3 Permisos de inicio contra pausa

Hay dos clases de inicio. Lanzar el trabajo de un intento, y ejecutar un efecto externo. Cada una tiene una transacción que da el permiso. La pausa es otra transacción de la misma base. Las tres son `BEGIN IMMEDIATE`, así que SQLite las ordena. Una termina antes de que la otra lea.

- Si la pausa termina primero, el permiso ya no se puede dar. Nada se lanza ni se envía.
- Si el permiso termina primero, la pausa lo encuentra ya dado y lo anota en su recibo. El lanzamiento o el envío pueden ocurrir después del ACK de la pausa. El recibo ya lo dice.

No hay ningún candado de red y nadie promete deshacer un envío.

#### El permiso de lanzar un intento

R ya tiene ese permiso. Es el paso de la admisión de `claimed` a `admitted`: `confirmHost` para un host (`managed-task.admission.worker.ts:216`) y `confirm` para una corrida nativa (`:441`). Y ya tiene la forma de impedirlo para siempre. Es el estado `fenced`, que hoy escribe `query` cuando cerca una llave de admisión que nunca se usó (`:402`).

La pausa usa ese estado. En su transacción ejecuta, por cada tarea de la raíz:

```
UPDATE managed_task_admissions
   SET state = 'fenced', claim_id = NULL, request_digest = NULL, updated_at = ?
 WHERE task_id = ? AND state = 'claimed'
```

El `CHECK` de la tabla exige `claim_id` y `request_digest` nulos en una fila `fenced` (`openclaw-state-schema.sql:1648-1649`). Sin anularlos, el `UPDATE` falla. `native_run_id` y `native_generation` no se tocan. Son la marca de que un host ya la había tomado, y es lo que leen `attempt-spent` y `hostBound`. La transacción lee `unitId`, `attempt`, `taskId` y si `native_run_id` es nulo antes de cercar, porque de ahí sale `fencedAdmissions`. El script de 4.1 ejecuta las dos formas del `UPDATE` y comprueba que una falla y la otra entra.

Las funciones de hoy ya respetan una admisión cercada, sin cambiar una línea:

| Función de hoy | Qué hace con una admisión `fenced` |
|---|---|
| `claimHostAssignment` (`:28`) | Solo lee `claimed` y `admitted`. El host no ve la tarea. |
| `confirmHost` (`:216`) | Busca por `claim_id`, que el cerco anuló. Contesta `Managed host admission claim not found`. El host no lanza. |
| `confirm` (`:441`) | Contesta `Managed task admission claim not found`. |
| `query` (`:402`), que el pipeline nativo llama antes de despachar | Contesta `never-started`, y `assertManagedTaskAdmissionCurrent` lanza. El pipeline aborta y limpia. |
| `claim` (`:319`) con la misma `admissionKey` | Contesta `Managed task admission was fenced`. |

Dos consecuencias. La ruta viva no gana ninguna puerta en esas cuatro funciones. Y un binario anterior también respeta la pausa de las admisiones que ya estaban cercadas.

La única función de hoy que cambia es `claim`, porque es la que crea una admisión nueva. Para una tarea de raíz, y solo para ella, `claim` llama `rootAdmissionRefusal(database, task, expected, nowMs)`. Devuelve la primera razón que encuentre:

1. `root-not-active`. La raíz está `paused` o `cancelled`.
2. `stale-control-epoch` o `stale-plan-revision`. La petición trae `expectedControlEpoch` y `expectedPlanRevision`, y alguno no es el vigente.
3. `attempt-not-live`. El intento ya tiene `outcome`, o su huella no está en la revisión vigente.
4. `attempt-spent`. La tarea tiene alguna admisión `fenced` con `native_run_id` no nulo. Un host ya la había tomado. Ese intento no se vuelve a admitir. Se cancela y se liga el siguiente. La razón está en el `unknown` 5 de la sección 8.
5. `authority`. `scopeRefusal(authority, scope, nowMs)` comprueba, en este orden, el plazo (`autoridad-vencida`), cada repo de `scope.repos` contra `authority.repos` (`repo-fuera-de-autoridad` con el primero que falte) y `scope.mode` contra `authority.mode` (`modo-fuera-de-autoridad`). No comprueba acción ni destino, porque una unidad no los tiene.

Cómo sale el rechazo. `ManagedTaskAdmissionReceipt` gana una variante, `{ state: "root-refused"; conflict: RootConflict }`. `claim` la devuelve, no lanza. El pipeline nativo ya aborta con cualquier estado distinto de `claimed` (`src/agents/spawn-pipeline.ts:78-82`), así que no hay que tocarlo.

En qué punto de `claim` corre. El orden de hoy se conserva: acceso, cancelación, destino, reserva, llave ya usada, resultado, admisión activa, inserción. `rootAdmissionRefusal` entra después de "llave ya usada" y solo si la llave es nueva. Una llave ya usada contesta por su fila, como hoy: `claimed` da `needs-reconciliation` y `fenced` lanza "was fenced", sin mirar la época. Si ninguna razón aplica, `claim` inserta la admisión y sella `admission_epoch` en el intento. El campo `root` no entra en `requestDigest`.

Para una tarea suelta, `claim` no llama nada nuevo. Lo sabe por su `requester_scope`, sin leer ninguna tabla.

`nowMs` lo pone el proceso principal en la entrada de cada orden, con `Date.now()`, y el trabajador usa ese valor. Las pruebas no mueven el reloj. Abren la raíz con un `deadline` a pocos milisegundos y esperan a que pase.

Por qué una admisión de una época vieja no inicia, caso por caso:

| Caso | Qué lo impide |
|---|---|
| Se admitió, llegó la pausa, y el host pide su permiso | La pausa la cercó. `confirmHost` no la encuentra. |
| Se admitió, hubo pausa y `resume`, y el host pide su permiso | Sigue cercada. `resume` no la revive. |
| El solicitante manda una admisión que calculó antes de la pausa | `claim` ve `paused`, o ve otra época tras el `resume`. |
| El plan cambió y la unidad ya no es la misma | La revisión canceló el intento. Las funciones de hoy ya rechazan una tarea cancelada. |

Una llamada a modelo de una corrida que ya inició no pasa por ninguna puerta nueva. Esa corrida tenía permiso. La pausa no la corta.

#### El permiso de iniciar un efecto

`startManagedRootEffect` es nueva y trae su propia puerta, `effectStartRefusal`: raíz activa, `expectedControlEpoch` vigente, unidad todavía en el plan, escritor vivo si el efecto declara `resourceRef`, y `authorityRefusal(authority, intent, nowMs)`, que es `efecto_admisible` del contrato con sus cinco razones. Si pasa, el efecto queda `started` con su `startId` y la época.

Un efecto `prepared` no se cerca con la pausa. Es una intención y puede iniciar tras `resume`. La admisión sí se cerca porque su permiso lo da una función de hoy que no conoce la raíz.

Revalidar la autorización queda cubierto en los dos momentos que pide el bloque. Al admitir, por `rootAdmissionRefusal` en `claim`. Antes de iniciar un efecto, por `effectStartRefusal`. La autoridad del turno o del dispositivo se sigue comprobando como hoy, dentro de la transacción.

#### El recibo de pausa y de cancelación

Se calcula dentro de la transacción de control y se guarda en `receipt_json` de la fila que sube la época. Una repetición devuelve la misma lista. Es histórico. El estado de ahora se lee con `readManagedRoot`.

| Campo | Qué lista |
|---|---|
| `committedEffects` | Los efectos en `started` o `uncertain`, con `effectId`, `destination`, `state` y `cancellable`. Es el campo del contrato. El contrato no admite `destination` nulo, así que un efecto sin destino sale con su `action` en ese campo. |
| `runningAttempts` | Los intentos vivos con admisión `admitted` y sin resultado, con `unitId`, `attempt`, `taskId` y `destination`. Ya tenían permiso. La pausa no los detiene y el panel no los puede mostrar detenidos. |
| `fencedAdmissions` | Las admisiones que esta orden cercó, con `unitId`, `attempt`, `taskId` y `hostBound`. Nunca iniciaron y ya no pueden. |

`runningAttempts` y `fencedAdmissions` son campos opcionales que el contrato permite añadir sin cambiar de versión. `destination` es el destino redactado. Para un intento es `cli:<hostId>/<adapterId>` o `agent:<agentId>`.

`cancel` hace lo mismo y además cancela cada intento vivo con su tarea, en `managed_task_cancellations`. El host lee esa cancelación como hoy.

### 4.4 El solicitante y su recuperación

La raíz guarda dos cosas distintas:

- **El dueño**, que no cambia: `principal`, `agentId` y `sessionKey`. Es `owner_json`, y `owner_scope` es su forma canónica.
- **La instancia vigente**, que sí cambia: la fila de generación mayor en `managed_root_requesters`.

La capacidad del solicitante es esa pareja. No es un secreto ni un token. Se comprueba contra el turno admitido (`captureManagedTaskTurn`), nunca contra argumentos que escribe el modelo. Conocer el `rootId` no sirve de nada.

`resolveTaskAccess(database, task, caller)` sustituye las ocho comparaciones de hoy y contesta una de tres cosas:

| Respuesta | Cuándo | Qué se permite |
|---|---|---|
| `{ kind: "loose" }` | El alcance de la tarea es el del llamador, como hoy | Todo lo de hoy |
| `{ kind: "root", root, attempt }` | La tarea es de raíz, y el llamador es el dueño con la instancia vigente | `inspect`, `recordWait`, `clearWait`, reservar admisión, `claim` y `query` |
| `null` | Cualquier otro caso | Nada. El error es el de hoy en cada sitio |

`resolve`, `cancel` y `createBudget` solo aceptan `loose`. Una tarea de raíz se decide por el commit y se cancela por el control. Un binario anterior también las rechaza, porque el alcance de una tarea de raíz no es el de ningún llamador.

**Después de `/new`.** El dueño es el mismo y la instancia es otra. Toda orden de raíz contesta `requester-rebound` y no cambia nada. El solicitante llama entonces `recoverManagedRootRequester`. No necesita saber ningún `rootId`, porque la sesión nueva no recuerda ninguno. En una transacción:

1. Busca las raíces no canceladas cuyo `owner_scope` es el `principal`, el `agentId` y el `sessionKey` del turno admitido.
2. Para cada una cuya instancia vigente no es la del turno, inserta la generación siguiente con la instancia nueva.
3. Para cada una con resultados sin consumir, encola un despertar a la instancia nueva con `prepareSessionDelivery`, `contextKey` `root:<rootId>` y llave de idempotencia `managed-root-recovered:<rootId>:<generación>`. Lo inserta dentro de la transacción con `upsertBoundDeliveryQueueEntryInDatabase(..., insertOnly: true)`. La llave lleva la generación nueva, así que no choca con el despertar viejo que murió.
4. Devuelve la lista de raíces con su generación. Repetirla no inserta nada. Al volver el trabajador, el proceso principal llama `scheduleSessionDelivery` con el id de cada entrega, como hace hoy `reportManagedTaskResult` (`managed-task.store.ts:98-101`). Sin ese paso la entrega espera al siguiente barrido.

La instancia anterior pierde el acceso en ese mismo commit. Una sesión distinta del mismo agente tiene otro `sessionKey`. No encuentra ninguna raíz y recibe una lista vacía.

Los despertares de una tarea de raíz usan la instancia vigente de la raíz, no la que quedó copiada en `requester_json` de la tarea. Eso toca dos funciones de hoy, `report` y `recordManagedTaskHostIncidentInWorker`, con una rama cada una. Llaman las mismas funciones de entrega con el llamador de `requester_json` y su `sessionInstance` cambiada por la vigente. La llave de idempotencia no cambia. El texto sí, porque el de hoy manda a decidir con `managed_tasks_resolve`, que una tarea de raíz rechaza: "Managed root <rootId> has a result for unit <unitId> attempt <n>. Read the root and commit the next decision."

Todo despertar de una raíz lleva además `requesterIdentity`, derivada de `owner_json.principal` con la regla que ya usa `prepareManagedTaskResultDelivery` (`managed-task.delivery.ts:29-67`). Sin ella, el turno despertado no trae remitente, su `principal` sale `["agent", agentId]` (`managed-task.turn.ts:58-60`) y ya no es el dueño. No podría leer la raíz ni hacer commit. Con ella, el turno despertado toma el remitente del dueño (`src/infra/heartbeat-runner-run.ts:124-130`).

**Límite conocido.** El `principal` de un turno con remitente es el del canal. Una raíz abierta desde Telegram no la puede operar un turno del mismo agente que llegue por otro canal, por la CLI o por un cron. Ese turno no es el dueño. Mientras SUA-02 no decida cómo se vincula una identidad entre canales, la única salida para una raíz que su dueño ya no alcanza es que el operador la cancele.

### 4.5 Operaciones

#### Archivos

| Archivo nuevo en `src/agents/tasks/` | Contenido |
|---|---|
| `managed-root.types.ts` | Tipos del dominio y las entradas de las órdenes del trabajador. |
| `managed-root.json.ts` | Parsers `zod` de cada entrada externa. Es la única frontera de validación. |
| `managed-root.machine.ts` | Las funciones puras: plan, huellas, control, efecto, estado de intento, autoridad, cupo. |
| `managed-root.worker.ts` | Las transacciones. Un `switch` exhaustivo, como `executeManagedTaskCommand`. |
| `managed-root.store.ts` | Las envolturas del lado del proceso principal, con la autoridad, como `managed-task.store.ts`. |

Las órdenes nuevas se registran igual que las de hoy: una entrada en `ManagedTaskWorkerOperations` (`managed-task.types.ts:272`) y un grupo más en `executeSharedStateCommand` (`src/state/openclaw-state-worker-runtime.ts:188-227`).

#### Tipos

```ts
// managed-root.types.ts
declare const brand: unique symbol;
type Brand<T, Name extends string> = T & { readonly [brand]: Name };

export type RootId = Brand<string, "RootId">;
export type UnitId = Brand<string, "UnitId">;
export type UnitDigest = Brand<string, "UnitDigest">;
export type OperationId = Brand<string, "OperationId">; // commandId, revisionId, decisionId
export type EffectId = Brand<string, "EffectId">;
// Época y revisión son enteros que nunca se deben cruzar.
export type ControlEpoch = Brand<number, "ControlEpoch">;
export type PlanRevision = Brand<number, "PlanRevision">;

export type RootOwner = { principal: string; agentId: string; sessionKey: string };

export type RootControl =
  | { state: "active"; epoch: ControlEpoch }
  | { state: "paused"; epoch: ControlEpoch; reason: string | null }
  | { state: "cancelled"; epoch: ControlEpoch; reason: string | null };

export type AuthorityAction =
  | "read" | "implement" | "review" | "push" | "merge"
  | "deploy" | "send-mail" | "publish" | "create-repo";
export type AuthorityMode = "design" | "read" | "implement" | "publish";

export type RootAuthority = {
  authorityRef: string;
  grantedBy: string;
  grantedAt: string;
  actions: AuthorityAction[];
  repos: string[];
  accounts: string[];
  destinations: string[];
  deadline: string | null;
  mode: AuthorityMode;
};

export type PlanCriterion = {
  criterionId: string;
  text: string;
  verifier: "reviewer" | "verifier" | "ci" | "owner";
};

/** Lo que entrega el parser. `criteria` puede venir vacía: el contrato le da su regla, no es un error de forma. */
export type ParsedPlanUnit = {
  unitId: UnitId;
  title: string;
  dependsOn: UnitId[];
  criteria: PlanCriterion[];
  scope: { repos: string[]; mode: AuthorityMode };
};

/** Solo un plan sin hallazgos de `validateRootPlan` se convierte a esto. */
export type PlanUnit = Omit<ParsedPlanUnit, "criteria"> & {
  criteria: [PlanCriterion, ...PlanCriterion[]]; // nunca vacía
};

export type AttemptState =
  | "pending" | "ready" | "admitted" | "running"
  | "reported" | "accepted" | "failed" | "cancelled";

export type AttemptFacts = {
  /** Época de la última admisión. `null` si nunca se admitió. */
  admissionEpoch: ControlEpoch | null;
  /** La admisión está `admitted`: el permiso de lanzar ya se dio. */
  started: boolean;
  hasResult: boolean;
  outcome: "accepted" | "failed" | "cancelled" | null;
};

export type EffectState = "prepared" | "started" | "confirmed" | "uncertain";

export type EffectIntent = {
  effectId: EffectId;
  unitId: UnitId | null;
  action: AuthorityAction;
  /** Obligatorio, como en `efecto_admisible` del contrato. */
  repo: string;
  destination: string | null;
  mode: AuthorityMode;
  cancellable: boolean;
  /** Recurso de escritura que la unidad debe tener al iniciar. Exige `unitId`. */
  resourceRef: string | null;
};

export type CommittedEffect = {
  effectId: string;
  /** Nunca nulo: el contrato no lo admite. Sin destino, lleva la acción. */
  destination: string;
  state: "started" | "uncertain";
  cancellable: boolean;
};

export type AuthorityRefusal =
  | "autoridad-vencida" | "accion-fuera-de-autoridad" | "repo-fuera-de-autoridad"
  | "destino-fuera-de-autoridad" | "modo-fuera-de-autoridad";

export type RootConflict =
  | { code: "operation-conflict" }
  | { code: "stale-control-epoch"; current: ControlEpoch }
  | { code: "stale-plan-revision"; current: PlanRevision }
  | { code: "root-not-active"; state: "paused" | "cancelled" }
  | { code: "transition-refused"; state: RootControl["state"]; command: "pause" | "resume" | "cancel" }
  | { code: "not-owner" }
  | { code: "requester-rebound" }
  | { code: "authority"; reason: AuthorityRefusal }
  | { code: "plan-invalid"; rule: string; path: string }
  | { code: "criterion-removed"; unitId: UnitId; criterionId: string }
  | { code: "budget-exceeds-profile"; limit: keyof ManagedBudgetProfile }
  | { code: "attempt-not-live"; unitId: UnitId; attempt: number }
  | { code: "attempt-spent"; unitId: UnitId; attempt: number }
  | { code: "unit-not-ready"; unitId: UnitId; missing: UnitId[] }
  | { code: "unit-live"; unitId: UnitId }
  | { code: "unit-accepted"; unitId: UnitId }
  | { code: "result-mismatch"; taskId: string }
  | { code: "result-consumed"; taskId: string }
  | { code: "criteria-unproven"; unitId: UnitId; missing: string[] }
  | { code: "outcome-refused"; unitId: UnitId; state: AttemptState }
  | { code: "capacity"; pool: "gateway" | "root"; needed: number; free: number }
  | { code: "capacity-unconfigured" }
  | { code: "writer-held"; resourceRef: string }
  | { code: "writer-not-held"; resourceRef: string }
  | { code: "counter-mismatch"; counter: string; current: number }
  | { code: "effect-refused"; state: EffectState };

// Un conflicto es una respuesta normal, no una excepción. SUA-02 decide con ella.
export type RootResult<T> =
  | { ok: true; value: T; replayed: boolean }
  | { ok: false; conflict: RootConflict };
```

Se lanza una excepción solo en tres casos: la autoridad del turno se revocó, la entrada no pasa su parser, o un invariante interno falló.

#### Funciones puras

```ts
// managed-root.machine.ts
/**
 * Las cuatro reglas del contrato, en su orden. `id-duplicado` cubre también un `criterionId`
 * repetido dentro de una unidad. `path` va como lo escribe `contrato.py`, con el prefijo `plan.`.
 */
export function validateRootPlan(
  units: ParsedPlanUnit[],
): Array<{ rule: "id-duplicado" | "dependencia-faltante" | "ciclo" | "criterio-faltante"; path: string }> {
  throw new Error("not implemented");
}

export function digestPlanUnits(units: PlanUnit[]): Map<UnitId, UnitDigest> {
  throw new Error("not implemented");
}

export function nextRootControl(
  control: RootControl,
  command: "pause" | "resume" | "cancel",
  reason: string | null,
): RootControl | null {
  throw new Error("not implemented");
}

export function deriveAttemptState(facts: AttemptFacts): AttemptState {
  throw new Error("not implemented");
}

/** La tabla `TRANSICIONES` del contrato. El commit la usa para `outcome-refused`. */
export function attemptTransitionAllowed(from: AttemptState, to: AttemptState): boolean {
  throw new Error("not implemented");
}

export type EffectEvent =
  | { kind: "start"; startId: string }
  | { kind: "settle"; outcome: "confirmed" | "uncertain" };

export function nextEffectState(
  current: { state: EffectState; startId: string | null },
  event: EffectEvent,
): EffectState | "replay" | null {
  throw new Error("not implemented");
}

/** `efecto_admisible` del contrato. `mode` es texto: un modo desconocido queda por encima de cualquier autoridad. */
export function authorityRefusal(
  authority: RootAuthority,
  effect: { action: string; repo: string; destination: string | null; mode: string },
  nowMs: number,
): AuthorityRefusal | null {
  throw new Error("not implemented");
}

/** Lo que se comprueba de una unidad: plazo, repos y modo. Una unidad no tiene acción ni destino. */
export function scopeRefusal(
  authority: RootAuthority,
  scope: PlanUnit["scope"],
  nowMs: number,
): Extract<AuthorityRefusal, "autoridad-vencida" | "repo-fuera-de-autoridad" | "modo-fuera-de-autoridad"> | null {
  throw new Error("not implemented");
}

export function capacityShortfall(input: {
  slots: number;
  occupied: number;
  requested: number;
}): { needed: number; free: number } | null {
  throw new Error("not implemented");
}
```

#### Órdenes

`RequesterTurn` es lo que ya devuelve `captureManagedTaskTurn`: el llamador y su `assertAuthorized`. `RootActor` añade al operador del gateway, que solo puede leer y controlar.

```ts
// managed-root.store.ts
export type RequesterTurn = ReturnType<typeof captureManagedTaskTurn>;
export type RootActor =
  | { kind: "requester"; turn: RequesterTurn }
  | { kind: "operator"; operatorRef: string; assertAuthorized: () => void };

/** Límites que quien llama saca de la configuración, igual que hoy `options.managedTaskHost.profile`. */
export type RootHostLimits = {
  /** `managedTasks.profile`. Ninguna raíz pide más. */
  profile: ManagedBudgetProfile;
  /** `managedTasks.capacity`. `null` si no está configurado: entonces ninguna raíz liga. */
  gatewaySlots: number | null;
};

export type OpenRootInput = {
  idempotencyKey: string;
  requestDigest: string;
  authority: RootAuthority;
  budget: ManagedBudgetProfile;
  plan: { units: ParsedPlanUnit[]; assumptions: string[] };
  qualityPolicy: { version: string };
};

export type RootRef = { rootId: RootId; planRevision: PlanRevision; controlEpoch: ControlEpoch };

/** Abre la raíz con su revisión 1. No crea tareas. `rootId` es `hash([owner_scope, idempotencyKey])`. */
export async function openManagedRoot(
  input: OpenRootInput,
  turn: RequesterTurn,
  limits: RootHostLimits,
): Promise<RootResult<RootRef>> {
  throw new Error("not implemented");
}

export type RevisePlanInput = {
  rootId: RootId;
  revisionId: OperationId;
  expectedPlanRevision: PlanRevision;
  plan: { units: ParsedPlanUnit[]; assumptions: string[] };
  scopeChange: { authorityRef: string; removedCriteria: Array<{ unitId: UnitId; criterionId: string }> } | null;
};

export type PlanRevisionReceipt = {
  rootId: RootId;
  planRevision: PlanRevision;
  planDigest: string;
  cancelledAttempts: Array<{ unitId: UnitId; attempt: number; taskId: string }>;
};

/** Inserta la revisión siguiente y cancela los intentos vivos cuya huella salió del plan. */
export async function reviseManagedRootPlan(
  input: RevisePlanInput,
  turn: RequesterTurn,
): Promise<RootResult<PlanRevisionReceipt>> {
  throw new Error("not implemented");
}

export type RootControlCommand = {
  rootId: RootId;
  command: "pause" | "resume" | "cancel";
  commandId: OperationId;
  expectedControlEpoch: ControlEpoch;
  reason: string | null;
  issuedAt: string;
};

export type RootControlReceipt = {
  rootId: RootId;
  controlEpoch: ControlEpoch;
  state: "active" | "paused" | "cancelled";
  committedEffects: CommittedEffect[];
  runningAttempts: Array<{ unitId: UnitId; attempt: number; taskId: string; destination: string }>;
  fencedAdmissions: Array<{ unitId: UnitId; attempt: number; taskId: string; hostBound: boolean }>;
};

export async function controlManagedRoot(
  input: RootControlCommand,
  actor: RootActor,
): Promise<RootResult<RootControlReceipt>> {
  throw new Error("not implemented");
}

export type RootDecision = {
  rootId: RootId;
  decisionId: OperationId;
  expectedPlanRevision: PlanRevision;
  expectedControlEpoch: ControlEpoch;
  /** Resultados que esta decisión consume. Cada uno, una sola vez en la vida de la tarea. */
  consumedResults: ManagedTaskResultReceipt[];
  /** Claims de evidencia: los campos de `sistema-agentes.evidencia.v1` más `attempt`, el intento que acreditan. */
  evidenceClaims: EvidenceClaimInput[];
  /** Intentos que terminan. */
  outcomes: Array<{ unitId: UnitId; attempt: number; outcome: "accepted" | "failed" | "cancelled" }>;
  /** Unidades listas que reciben un intento y una tarea. Todas entran o ninguna. */
  bindings: Array<{ unitId: UnitId; assignment: ManagedTaskAssignment; writers: string[] }>;
  /** Efectos que quedan `prepared`. */
  effects: EffectIntent[];
  /** Contadores que suben uno. `expected` es el valor que vio quien decide. */
  counters: Array<{ counter: string; expected: number }>;
};

export type RootDecisionReceipt = {
  rootId: RootId;
  decisionId: OperationId;
  decisionDigest: string;
  planRevision: PlanRevision;
  controlEpoch: ControlEpoch;
  createdAttempts: Array<{ unitId: UnitId; attempt: number; taskId: string }>;
};

/** La transacción central. Es `host.commit` del diseño del sistema. */
export async function commitManagedRootDecision(
  input: RootDecision,
  turn: RequesterTurn,
  limits: RootHostLimits,
): Promise<RootResult<RootDecisionReceipt>> {
  throw new Error("not implemented");
}

export type EffectReceipt = {
  rootId: RootId;
  effectId: EffectId;
  state: EffectState;
  startId: string | null;
  startedEpoch: ControlEpoch | null;
};

/** `Prepared → Started`. El recibo con `state: "started"` es el permiso. */
export async function startManagedRootEffect(
  input: { rootId: RootId; effectId: EffectId; startId: string; expectedControlEpoch: ControlEpoch },
  actor: RootActor,
): Promise<RootResult<EffectReceipt>> {
  throw new Error("not implemented");
}

export async function settleManagedRootEffect(
  input: {
    rootId: RootId;
    effectId: EffectId;
    startId: string;
    outcome:
      | { kind: "confirmed"; occurred: boolean; evidenceRef: string }
      | { kind: "uncertain"; note: string };
  },
  actor: RootActor,
): Promise<RootResult<EffectReceipt>> {
  throw new Error("not implemented");
}

export type RequesterReceipt = { rootId: RootId; requesterGeneration: number; rebound: boolean };

/** Mueve a la instancia del turno todas las raíces vivas de su dueño. No recibe ningún `rootId`. */
export async function recoverManagedRootRequester(turn: RequesterTurn): Promise<RequesterReceipt[]> {
  throw new Error("not implemented");
}

export type RootSnapshot = {
  /** Documento `sistema-agentes.meta.v1`. Su tipo sale del parser de `managed-root.json.ts`. */
  meta: MetaDocument;
  /** Un documento `sistema-agentes.unidad.v1` por intento, vivo o anterior. */
  units: UnitDocument[];
  /** Unidades del plan vigente sin intento. No son documentos del contrato (4.8, conflicto 9). */
  unbound: Array<{ unitId: UnitId; state: "pending" | "ready"; missing: UnitId[] }>;
  /** Documentos `sistema-agentes.evidencia.v1`. */
  evidence: EvidenceDocument[];
  effects: EffectReceipt[];
  budget: ManagedBudgetSnapshot;
  counters: Record<string, number>;
  writers: Array<{ resourceRef: string; unitId: UnitId }>;
  /** Resultados reportados que ningún commit consumió. */
  pendingResults: ManagedTaskResultReceipt[];
  requesterGeneration: number;
};

export async function readManagedRoot(
  input: { rootId: RootId },
  actor: RootActor,
): Promise<RootSnapshot | null> {
  throw new Error("not implemented");
}
```

Una función de hoy gana un campo opcional para que una tarea de raíz pase por el camino de admisión que ya existe:

```ts
// managed-task.types.ts
export type ManagedTaskAdmissionRequest = {
  caller: ManagedTaskCaller;
  taskId: string;
  admissionKey: string;
  executionTarget: ManagedTaskAssignment["target"];
  inputRefs: string[];
  budgetReservation: string;
  /** Obligatorio para una tarea de raíz. Ausente para una tarea suelta. */
  root?: { expectedControlEpoch: number; expectedPlanRevision: number };
};
```

`reserveManagedAdmissionBudget` no cambia de firma. Deja de comparar alcances a mano y llama `resolveTaskAccess`.

El campo es opcional en el tipo y obligatorio en la conducta. `claim` lanza `Managed task admission root mismatch` para una tarea de raíz que llegue sin él y para una tarea suelta que llegue con él, justo después de la comprobación de acceso. No se pudo hacer obligatorio en el tipo sin partir la firma que usa el pipeline nativo de hoy (`createManagedSpawnAdmission`).

#### Qué va en una sola transacción y por qué

Cada orden es una transacción. Dentro, el orden siempre es el mismo: autoridad del turno, repetición, comparación de época y revisión, todas las comprobaciones, escrituras, autoridad otra vez. Las comprobaciones son lecturas. Devuelven el primer conflicto sin haber escrito nada.

**`openManagedRoot`.** La raíz, su época 1, su generación 1 de solicitante, su revisión 1 y sus unidades. Sin esas filas la raíz no tendría control, dueño ni plan vigentes. La repetición busca la apertura anterior por `(owner_scope, open_idempotency)` y compara `open_digest`: mismo digest, misma raíz. Otro digest, `operation-conflict`. El `UNIQUE` cubre dos aperturas a la vez. Rechaza a un trabajador gestionado, con la misma comprobación que `register`, porque un hijo no crea otra raíz. El presupuesto pasa `validateProfile` y cada una de sus diez llaves es menor o igual que la de `limits.profile`. La primera que no cumple, en el orden de `PROFILE_KEYS`, sale en `budget-exceeds-profile`. Aplica `scopeRefusal` a cada unidad y contesta `authority` si alguna pide un repo o un modo que la autoridad no da. El parser rechaza un `commandId` o un `revisionId` igual a `open`, que es el id de las filas iniciales.

**`commitManagedRootDecision`.** Todo lo que una decisión cambia. Por partes:

| Parte | Escribe | Por qué va junta |
|---|---|---|
| `consumedResults` | Una fila en `managed_task_handlings` por resultado. Vale también para el resultado tardío de un intento ya terminado, que así sale de `pendingResults` | Un resultado consumido sin su decisión, o al revés, es justo lo que I03 e I04 prohíben. |
| `evidenceClaims` | Filas en `managed_root_evidence` | La aceptación de la misma decisión las lee. |
| `outcomes` | `outcome` del intento. Si el intento tiene resultado, exige que esté consumido, en este commit o en uno anterior. Si no, `result-mismatch`. Al aceptar, libera los escritores de la unidad. Al fallar o cancelar sin resultado, cancela la tarea. | Aceptar C y ligar D, que depende de C, es una sola decisión. |
| `bindings` | El intento, la tarea, su fila de presupuesto y los escritores | Es el fan-in. La clave del intento y el índice de intento vivo dejan pasar a un solo reconciliador. Un par son dos ligaduras del mismo commit, y entran las dos o ninguna. |
| `effects` | Filas `prepared` | Un efecto preparado sin su decisión no tiene dueño. |
| `counters` | Un ordinal por contador, `expected + 1` | El contador de rondas no puede subir si la decisión que lo gastó no entró. |
| Recibo | La fila de `managed_root_commits`. Es la primera escritura, y cada hecho de arriba la referencia | Sin él, un ACK perdido repetiría la decisión. Con la llave foránea, ningún hecho existe sin su recibo. |

El recibo se puede calcular antes de escribir, porque el id de cada tarea es `hash([rootId, unitId, attempt])` y `attempt` sale de una lectura. Después de la fila del recibo, los hechos se escriben en este orden fijo: `consumedResults`, `evidenceClaims`, `outcomes`, `bindings`, `effects`, `counters`. Las comprobaciones de `bindings` ven los `outcomes` del mismo commit como ya aplicados. Por eso cabe en un commit cancelar el intento 1 de una unidad y ligar el 2.

Comprobaciones de `bindings`, en orden:

1. La unidad está en la revisión vigente y todas sus dependencias están aceptadas. Si no, `unit-not-ready`.
2. La unidad no está aceptada (`unit-accepted`) ni tiene un intento vivo (`unit-live`).
3. `attempt` es el mayor intento de la unidad más uno, entre todas las revisiones. Cambiar el plan no reinicia la cuenta.
4. Cupo de la raíz: los intentos de la raíz que retienen plaza, más los nuevos, no pasan de `maxConcurrentTasks`. El total de intentos no pasa de `maxChildren`.
5. Cupo del gateway: las plazas ocupadas en todo el gateway, más las nuevas, no pasan de `limits.gatewaySlots`. Con `null` contesta `capacity-unconfigured`. Un cupo desconocido no se trata como infinito.
6. Cada recurso de `writers` queda a nombre de la unidad. Si la unidad ya lo tiene, no se inserta nada. Si lo tiene otra unidad o otra raíz, `writer-held`.
7. La tarea se inserta como en `register`, con id `hash([rootId, unitId, attempt])`. `assignment_json` y `assignment_digest` salen de la asignación ya pasada por `parseManagedTaskAssignment` y `assertManagedTaskResultContract`. `producer_id` es el `agentId` o el `adapterId` del destino. `generation` es 1. `requester_json` es `managedTaskJson(turn.caller)`. `producer_token` lo genera `commitManagedRootDecision` en el proceso principal, uno por ligadura, y viaja en la orden como `bindingProducerTokens`, igual que hoy `childProducerTokens` (`managed-task.store.ts:316-319`). En una repetición los tokens nuevos se descartan.

**Plaza ocupada.** Una tarea retiene plaza si se cumple una de dos cosas. Tiene una admisión activa que la retiene según `managedTaskAdmissionRetainsBudgetSlot`, la regla de hoy. O es la tarea de un intento vivo sin admisión activa, es decir, sin ninguna en `claimed` ni en `admitted`. Eso incluye al intento recién ligado y al intento cuya admisión cercó una pausa. Sin la segunda parte, una pausa soltaría plazas que el `resume` volvería a ocupar sin pasar por el cupo. La cuenta del gateway incluye las tareas sueltas, porque ocupan la misma máquina. La admisión de una tarea suelta no consulta el cupo. La ruta viva se queda como está.

**`controlManagedRoot`.** Una fila en `managed_root_controls`, que es la época y el recibo a la vez. Si es `pause`, el cerco de las admisiones `claimed` de la raíz. Si es `cancel`, la cancelación de cada intento vivo con su tarea (`managed_task_cancellations`, la tabla de hoy) y la liberación de los escritores de la raíz. Va junto porque el recibo tiene que listar exactamente lo que la orden encontró y lo que cercó.

**`reviseManagedRootPlan`.** La revisión, que es también su recibo, sus unidades, la cancelación de los intentos vivos cuya huella salió del plan y la liberación de los escritores de las unidades que ya no existen. Rechaza quitar un criterio sin `scopeChange`, con `criterion-removed`. El `requestDigest` de la raíz no cambia nunca. Se permite con la raíz en pausa.

**`startManagedRootEffect` y `settleManagedRootEffect`.** Una fila de efecto cada una. Son transacciones separadas del envío a propósito, porque el envío no cabe en una transacción de SQLite.

**`recoverManagedRootRequester`.** Una generación nueva por raíz y su despertar.

#### El presupuesto por raíz

El presupuesto y las reservas siguen en las tablas de hoy. Cambia quién forma el árbol:

```ts
// managed-task.budget.shared.ts
export type BudgetTree =
  | { kind: "task"; rootTaskId: string } // árbol de hoy, por managed_task_children
  | { kind: "root"; rootId: string; taskIds: string[] }; // las tareas de los intentos de la raíz

export function budgetTreeForTask(database: OpenClawStateDatabase, taskId: string): BudgetTree {
  throw new Error("not implemented");
}
```

- `budgetTreeForTask` sustituye a `rootForTask`. Para una tarea suelta contesta lo mismo que hoy.
- `budgetForTask` devuelve `{ tree, reservationRoot, profile }`. `reservationRoot` es lo que se escribe y se compara en la columna `root_task_id` de una reserva. Con `kind: "task"` es `rootTaskId`, como hoy. Con `kind: "root"` es la propia tarea, que es la fila de presupuesto que su llave foránea necesita.
- `reservations` y `countRootRecoveryGrants` reciben el árbol. Con `kind: "task"` filtran por `root_task_id`, como hoy. Con `kind: "root"` filtran por `root_task_id IN (taskIds)`, y el perfil sale de `managed_roots.budget_json`.
- Los usos de `rootForTask` y `budgetForTask` son ocho: `managed-task.budget.worker.ts` líneas 96, 122, 138, 175, 223, 371 y 440, y `managed-task.recovery.worker.ts` línea 71. `budgetForTask` se queda y llama `budgetTreeForTask` por dentro. Los tres usos directos de `rootForTask` (122, 175 y 371) pasan a `budgetTreeForTask`. Dos de ellos, `createBudget` (175) y `assertManagedChildBudgetCapacity` (138), solo ven `kind: "task"`, porque `createBudget` y `resolve` rechazan una tarea de raíz.
- En la foto de una raíz, `ManagedBudgetSnapshot.rootTaskId` lleva el `rootId`.

Así una raíz comparte un solo fondo de llamadas, tokens, concurrencia y recuperación entre todos sus intentos, con el código de reservas de hoy. Repetir un resultado no crea presupuesto: `report` devuelve el recibo que ya tenía y ningún commit repetido vuelve a insertar.

### 4.6 Dónde se inyecta un fallo

R ya tiene los mecanismos. Ninguno hay que inventarlo.

| Fallo | Mecanismo | Precedente |
|---|---|---|
| Antes del commit | La autoridad lanza en la etapa `transaction` o `commit`. Cada orden nueva pide las dos, así que hay dos puntos por orden. La transacción se deshace. | `managed-task.store.test.ts:52-72`. Por etapa, `src/infra/sqlite-worker-shared-state-admission.test-support.ts:81-82` |
| A mitad de una transacción | Una parte tardía del commit viola una regla. Por ejemplo, un escritor ocupado después de un consumo válido. Nada de la decisión queda escrito. | "rolls back the whole decision when one child is invalid", `managed-task.handling.test.ts:276` |
| Después del commit, ACK perdido | La prueba descarta la respuesta, o lanza después de recibirla, y repite la orden. | `managed-tasks-tool.test.ts:418-440` |
| Reinicio | `drainGlobalSingletonLifecycleState("restart")` conserva el archivo de la base y tira todo lo demás. | `managed-task.admission.test.ts:100` |
| Dos reconciliadores | Dos órdenes concurrentes con `Promise.all`. | `managed-task.handling.test.ts:237-273` |
| Entre el permiso y el envío | Un adaptador de prueba que pide `start`, recibe el permiso, y espera a que la prueba mande la pausa antes de "enviar". Para un lanzamiento, la prueba llama `managedTasks.host.admit`, pausa, y solo después reporta. | `managed-tasks-tool.test.ts:375-396`, que escribe un archivo de efecto |
| Caída con un permiso dado | `start`, reinicio, y un segundo `start` con otro `startId`. | `managed-task.spawn-pipeline.test.ts:159-220` |

### 4.7 Lo que SUA-02 va a llamar

Diez funciones. Las ocho de `managed-root.store.ts`, y dos de hoy: reservar una admisión y admitir, la segunda con un campo nuevo.

```ts
// Un turno del solicitante en SUA-02, visto desde quien llama.
const turn = captureManagedTaskTurn(source);

const limits = { profile: managedTaskHost.profile, gatewaySlots: config.managedTasks?.capacity ?? null };
const opened = await openManagedRoot(
  { idempotencyKey, requestDigest, authority, budget, plan, qualityPolicy },
  turn,
  limits,
);
if (!opened.ok) return opened.conflict;
const { rootId } = opened.value;

// Reconciliar: leer, decidir con una función pura, hacer commit.
const snapshot = await readManagedRoot({ rootId }, { kind: "requester", turn });
const decision = decide(snapshot, verifiedFacts, policies); // SUA-02
const committed = await commitManagedRootDecision({ rootId, ...decision }, turn, limits);
if (!committed.ok && committed.conflict.code === "stale-control-epoch") {
  // Alguien pausó o reanudó. Se vuelve a leer y a decidir.
}

// Admitir cada intento creado, por el camino de hoy. Este es el de un destino CLI.
// Para un destino agente, la misma petición entra por `createManagedSpawnAdmission`,
// como hace hoy `managed_tasks_admit`, y el pipeline nativo llama `claim` y `confirm`.
for (const created of committed.ok ? committed.value.createdAttempts : []) {
  const reservation = await reserveManagedAdmissionBudget({
    caller: turn.caller,
    taskId: created.taskId,
    admissionKey: `epoch-${expectedControlEpoch}`,
  });
  const admission = await claimManagedTaskAdmission(
    {
      caller: turn.caller,
      taskId: created.taskId,
      admissionKey: `epoch-${expectedControlEpoch}`,
      executionTarget,
      inputRefs,
      budgetReservation: reservation.reservationId,
      root: { expectedControlEpoch, expectedPlanRevision },
    },
    turn,
  );
  if (admission.state === "root-refused") {
    // Pausa, época vieja, intento gastado o autoridad. Se vuelve a leer y a decidir.
  }
}

// Un adaptador de efecto.
const permit = await startManagedRootEffect({ rootId, effectId, startId, expectedControlEpoch }, actor);
if (!permit.ok) return; // la pausa ganó, o la autoridad ya no cubre el efecto. Nada se envía.
// `replayed: true` quiere decir que este permiso ya se había dado a este `startId`.
// Si el adaptador no sabe si alcanzó a enviar, concilia con el destino antes de enviar.
const outcome = permit.replayed ? await reconcileThenMaybeSend() : await send(); // fuera de toda transacción
await settleManagedRootEffect({ rootId, effectId, startId, outcome }, actor);
```

Lo que SUA-02 no tiene que saber: qué tablas existen, cómo se cuenta una plaza, qué invalida una revisión de plan, cómo se ordena una pausa contra un permiso, ni cómo se recupera un recibo. Lo que sí tiene que hacer: decidir, y volver a leer cuando recibe un conflicto.

### 4.8 Conflictos con el plan y con el contrato

Son nueve. Ninguno obliga a cambiar el plan ni el contrato. Cada uno es un punto donde su letra admite dos lecturas, o donde R no deja cumplir dos frases a la vez. Va con las dos opciones y la que este diseño toma.

**Conflicto 1. "Migrar datos con versión y reversa compatible" (plan, SUA-01, paso 1).**
En R, subir la versión del esquema y poder volver al binario anterior se excluyen. El binario 27 se niega a abrir una base 28.
- Opción A: no subir la versión. Tablas nuevas perezosas, ninguna tabla de hoy cambia, la versión de los datos va en `managed_roots.contract_version`. La reversa es reinstalar el paquete.
- Opción B: subir a 28, como hicieron los bloques 20 a 27. Permite cambiar tablas de hoy, por ejemplo quitar la llave foránea de `managed_task_budgets` para que una raíz sea dueña directa de su presupuesto. La reversa es restaurar la foto de las bases, como en `T12-runbook.md`, y se pierde lo escrito desde la foto. O un script de bajada que borra las tablas nuevas y reescribe la versión, que R no tiene hoy.
- Recomendación: A. Cumple "reversa compatible" al pie de la letra y "con versión" en los datos de la raíz. No cumple "migrar datos" porque no hay datos que migrar. Si el ensayo de la rebanada 4 falla, se pasa a B y este documento se corrige antes de seguir.

**Conflicto 2. `unidad.controlEpoch` no admite `null` (contrato, "Unidad").**
El contrato lo define como "época con la que se admitió" y el validador exige un entero desde 1. Un intento `pending` o `ready` todavía no se admitió.
- Opción A: `readManagedRoot` emite la época vigente de la raíz mientras el intento no tenga `admission_epoch`. Las unidades sin intento no emiten documento (conflicto 9).
- Opción B: cambiar el contrato para que el campo admita `null`. Según sus propias reglas de versión, cambiar un tipo sube la versión mayor.
- Recomendación: A, y una frase aclaratoria en el contrato: "antes de admitir, la época vigente de la raíz". No cambia el esquema ni los fixtures. La escribe la rebanada 15, que es la de G.

**Conflicto 3. "Pausa de una tarea gestionada" (inventario de SUA-00) frente a `control` sobre la raíz (contrato).**
- Opción A: la pausa es solo de la raíz. Una tarea suelta no se pausa.
- Opción B: una tabla `managed_task_pauses`, hermana de `managed_task_cancellations`, que pausa cualquier tarea.
- Recomendación: A. El contrato solo define control de raíz. B añade una puerta en la ruta viva que nadie pidió.

**Conflicto 4. "Un claim de otra `planRevision` queda invalidado salvo justificación comprobable registrada en la revisión" (contrato, "Evidencia").**
- Opción A: la justificación es la igualdad de huellas, que queda registrada en `managed_root_units`. Un claim pertenece a un intento, y vale mientras la huella de ese intento esté en la revisión vigente. El documento que R emite añade `attempt`, un campo opcional que el contrato permite.
- Opción B: una lista explícita de claims arrastrados, con un texto de justificación por cada uno, en una tabla más.
- Recomendación: A. Se comprueba sola y no deja que un texto libre conserve evidencia de un criterio que cambió. B queda disponible para SUA-02 sin deshacer A.

**Conflicto 5. "Capacidad acotada emitida por el host" (diseño del sistema).**
- Opción A: la capacidad es el vínculo durable entre la raíz, su dueño y la instancia vigente, con una generación. No hay secreto.
- Opción B: un token portador que el solicitante presenta.
- Recomendación: A. Un token tendría que pasar por argumentos de herramienta, que el transcript guarda. La redacción tapa cualquier campo llamado `token`, y R ya liga al solicitante con el turno admitido y no con argumentos del modelo (`captureManagedTaskTurn`).

**Conflicto 6. "Fan-in A+B→C (`managed_task_children.child_task_id` es `UNIQUE`)" (plan e inventario).**
La frase nombra el obstáculo. No ordena quitarlo.
- Opción A: dejar el `UNIQUE`. Las dependencias viven en el plan.
- Opción B: reconstruir la tabla para que una tarea tenga varios padres.
- Recomendación: A. B exige subir la versión (conflicto 1) y guardaría el grafo dos veces, en el plan y en la tabla.

**Conflicto 7. Un efecto del que se sabe que no ocurrió (contrato, "Control", y diseño del sistema).**
El contrato tiene cuatro estados de efecto. Ninguno dice "el destino lo rechazó y se sabe que no pasó".
- Opción A: asentarlo como `confirmed` con `occurred: false` en el asiento. `confirmed` quiere decir entonces "el resultado se conoce".
- Opción B: un quinto estado en una versión mayor del contrato.
- Recomendación: A. No toca el contrato: `committedEffects` solo expone `started` y `uncertain`. Quien lea un efecto `confirmed` tiene que mirar `occurred`. SUA-06 lo necesita saber para el panel.

**Conflicto 8. El solicitante es `principal` y `agentId` (contrato, "Meta") o además `sessionKey` (este diseño).**
El contrato define `requester` con dos campos. Aquí el dueño tiene tres.
- Opción A: el dueño incluye `sessionKey`, como el alcance de una tarea de hoy. Otra sesión del mismo agente no toma la raíz.
- Opción B: el dueño es solo `principal` y `agentId`. Cualquier sesión de ese agente con ese `principal` opera la raíz.
- Recomendación: A. Un turno sin remitente tiene `principal` `["agent", agentId]`. Con B, cualquier sesión de `main` tomaría cualquier raíz de `main` abierta sin remitente, y el plan pide lo contrario ("una nueva sesión no toma una raíz por conocer su ID"). `readManagedRoot` emite `requester` con los dos campos del contrato y añade `sessionKey`, que el validador acepta porque el objeto es abierto. El precio de A está en 4.4, "Límite conocido".

**Conflicto 9. Una unidad sin intento no cabe en `unidad.v1` (contrato, "Unidad").**
El contrato exige en ese documento `attempt` desde 1 y un `assignment` completo. Aquí la asignación llega con el intento, y una raíz recién abierta no tiene ninguno. El validador de G lo confirma. Sin `assignment` contesta `schema, assignment, falta el campo`.
- Opción A: `RootSnapshot.units` lleva un documento `unidad.v1` por intento y nada más. Las unidades del plan vigente sin intento van en `unbound`, que no es un documento del contrato. El plan completo ya está en `meta.plan.units`.
- Opción B: cambiar el contrato para que `attempt` y `assignment` admitan `null`. Sube la versión mayor.
- Recomendación: A.

**Tres notas que no son conflicto.**
- El encargo de este diseño cita `src/agents/goals/goals-operations.ts`. El archivo está en `src/config/sessions/goals-operations.ts`, como dice el contrato. De ahí se copia solo el patrón: un id por orden, la huella de la petición, el recibo en la misma transacción, `replayed: true` en la repetición exacta y conflicto en la distinta (`readSessionGoalOperationReceipt`, `writeSessionGoalOperationReceipt`). No se copia su caducidad de 24 horas ni su tope de 4096 recibos. Los recibos de una raíz no caducan.
- El contrato permite `taskId` nulo "antes de admitir". Aquí `taskId` nunca va nulo. Un intento siempre tiene tarea, porque el commit crea las dos cosas juntas, y una unidad sin intento no emite `unidad.v1` (conflicto 9).
- R guarda `principal` como un texto con JSON dentro. El contrato lo pide como lista. `readManagedRoot` lo emite como lista, con `JSON.parse`, en `requester.principal` y en `verifier.principal`.

## 5. Cómo se prueba

Las pruebas son de R, con `vitest`, y llaman las funciones de `managed-root.store.ts` como las llamará SUA-02. Comparan contra valores literales. Para leer lo que quedó escrito usan `readManagedRoot` y, donde hace falta contar filas, SQL directo, como ya hacen las pruebas de `src/agents/tasks/`.

Cada fila dice qué fallo del código la pone roja. Si la prueba sigue verde con ese fallo, la prueba no sirve y se reescribe.

### Ensayos integrados

| Ensayo | Archivo y caso | Qué hace | Fallo que la pone roja |
|---|---|---|---|
| I03 | `managed-root.commit.test.ts`, "binds C once under two reconcilers and a lost ACK" | Abre una raíz con A, B y C, donde C depende de A y de B. Liga A y B, las admite, reporta y acepta. Lanza dos commits a la vez, con `decisionId` distintos, que ligan C. Repite el que ganó. Espera un `ok`, un `unit-live`, un `replayed: true`, una sola tarea para C y cero filas de la raíz en `managed_task_children`. | Quitar la comprobación y el índice de intento vivo deja dos C. Quitar la búsqueda del recibo cambia el `replayed: true` por `unit-live`. |
| I03 | mismo archivo, "creates initial units without a parent result" | Liga A y B recién abierta la raíz. Espera dos tareas y ninguna fila en `managed_task_handlings` ni en `managed_task_children`. | Crear las unidades por `resolveManagedTaskHandling` exige un resultado padre y la orden falla. |
| I03 | mismo archivo, "refuses C while a dependency is not accepted" | Con A aceptada y B solo reportada, liga C. Espera `unit-not-ready` con `missing: ["B"]`. | Tratar `reported` como aceptada. |
| I04 | `managed-root.recovery.test.ts`, "recovers after a crash between commit and admission" | Commit que liga A. Reinicio. Otro turno de la misma sesión lee la raíz, ve A `ready` con su tarea y la admite. | Tomar el estado del intento de una caché de proceso. El reinicio de prueba solo borra los singletons registrados (`src/shared/global-singleton.ts:76-88`), así que la prueba además borra a mano la fila del intento y espera que la foto deje de mostrarlo. En revisión, `grep -nE "^(export )?(const|let|var) [^=]*= new (Map|Set)|^let " src/agents/tasks/managed-root.{types,json,machine,worker,store}.ts` no encuentra estado de módulo. |
| I04 | mismo archivo, "keeps an uncertain admission across a restart" | `claim` de A sin confirmar. Reinicio. Repetir el mismo `claim` contesta `needs-reconciliation` con el mismo `claimId`, la espera es `admission-uncertain` y la reserva de admisión sigue `reserved`. | Volver a insertar la admisión al repetir. |
| I04 | mismo archivo, "keeps the spend of a root across a restart" | Dos intentos, A y B, admitidos con corrida nativa confirmada. Una llamada a modelo en cada uno. Reinicio. La foto dice `usage.modelCalls: 2`, y con `maxModelCalls: 2` una tercera llamada en cualquiera de los dos lanza "Managed model tree budget exhausted". | Armar el árbol solo con la tarea propia: cada intento vería una llamada y la tercera pasaría. |
| I04 | mismo archivo, "consumes a result reported before a crash exactly once" | Reporta A, reinicia, consume desde otro turno, repite el commit. Espera el resultado en `pendingResults` antes y fuera después, y una sola fila en `managed_task_handlings`. | Consumir sin insertar en `managed_task_handlings`. |
| I04 | mismo archivo, "leaves nothing behind when authority is revoked before commit" | La autoridad lanza en la etapa `commit` de un commit con consumo, claim y ligadura. Espera cero filas nuevas en las tablas de la raíz y en `managed_task_handlings`, y el resultado todavía pendiente. | Escribir un hecho fuera de la transacción. |
| I04 | mismo archivo, "a decision is one transaction" | Una admisión de prueba anota cada petición de etapa, como `src/infra/sqlite-worker-shared-state-admission.test-support.ts:81-82`. Un commit con todas las listas que existan en esa rebanada pide una vez `transaction` y una vez `commit`. | Partir el commit en dos transacciones. |
| I05 | `managed-root.control.test.ts`, "pause wins over a start that has no permit yet" | Prepara un efecto, pausa, pide `start`. Espera `root-not-active`, el efecto `prepared` y `committedEffects: []`. Tras `resume`, `start` con la época nueva pasa. | Quitar `effectStartRefusal`. |
| I05 | mismo archivo, "a permit given before the pause is named in its receipt and still sends" | El adaptador de prueba recibe el permiso y espera. La prueba pausa y lee el recibo: lista el efecto como `started`. El adaptador "envía" después del ACK y asienta `confirmed`. La foto dice `confirmed`. La repetición de la pausa devuelve el mismo recibo. | Listar solo los `uncertain`. O no guardar la lista en `receipt_json`: la repetición devolvería una lista recalculada, ya sin el efecto. |
| I05 | mismo archivo, "replays a control command and refuses a stale resume" | Repite `pause` con el mismo `commandId`: mismo recibo, `replayed: true`, misma época. El mismo `commandId` con `cancel`: `operation-conflict`. Un `resume` con la época anterior: `stale-control-epoch`. | No guardar el recibo sube la época dos veces. No comparar la época deja pasar el `resume`. |
| I05 | mismo archivo, "a paused root gives no launch permit and a resume does not revive a stale one" | Intento CLI admitido en la época 1, sin host todavía. Pausa: el recibo lo trae en `fencedAdmissions`, `managedTasks.host.claim` contesta `null` y `managedTasks.host.admit` falla. `resume`: sigue sin verse. El solicitante repite la admisión con la `admissionKey` vieja: "was fenced". Con una llave nueva y la época 3: el host la ve, `host.admit` pasa y la foto dice `controlEpoch: 3`. | No cercar en la pausa. O dejar que `claim` acepte la época 1 después del `resume`. |
| I05 | mismo archivo, "a native start is refused while paused" | Mismo caso con destino agente, con la pausa entre `claim` y el despacho: `assertManagedTaskAdmissionCurrent` lanza y el adaptador de spawn de prueba no despacha. | No cercar las admisiones de destino agente. |
| I05 | mismo archivo, "a launch permitted before the pause is listed as running" | El host llama `managedTasks.host.admit` y recibe `host-admitted`. La prueba pausa. El recibo trae el intento en `runningAttempts` y no en `fencedAdmissions`. El host reporta después del ACK y el resultado se guarda. | Cercar también las admisiones `admitted`, o dejar `runningAttempts` vacío. |
| I05 | mismo archivo, "an attempt whose fenced admission already reached a host is spent" | El host llama `managedTasks.host.claim` y queda atado. Pausa y `resume`. El solicitante admite otra vez el mismo intento: `attempt-spent`. Cancela el intento y liga el siguiente, que sí se admite. | Quitar la comprobación de `native_run_id` en `rootAdmissionRefusal`. |
| I05 | mismo archivo, "cancel is terminal and a late result does not resurrect the attempt" | Cancela con un intento corriendo. El host lee la cancelación. Reporta después. Espera el intento `cancelled`, ningún despertar, `resume` en conflicto y commit en `root-not-active`. | Derivar el estado del resultado antes que de `outcome`. |
| I06 | `managed-root.effect.test.ts`, "a confirmed effect cannot start again" | `start`, `settle confirmed`, `start`. Espera `effect-refused`. | Permitir `start` desde `confirmed`. |
| I06 | mismo archivo, "an uncertain effect keeps its state until someone reconciles" | `start`, `settle uncertain`, reinicio, `start`: rechazado y sigue `uncertain`. `settle confirmed` sin `evidenceRef`: lo rechaza el parser. Con evidencia: `confirmed`. | Permitir `start` desde `uncertain`, o `confirmed` sin evidencia. |
| I06 | mismo archivo, "a retry is a new effect" | `start`, `settle confirmed` con `occurred: false`. `start` del mismo efecto: `effect-refused`. Un commit prepara otro `effectId` y ese sí inicia. | Volver un efecto asentado a `prepared`. |
| I06 | mismo archivo, "a permit found after a crash does not authorize a second send" | `start`, reinicio, `start` con otro `startId`. Espera rechazo y el efecto todavía `started`. El mismo `startId` devuelve el recibo original. | Dar un permiso nuevo a otro `startId`. |
| I06 | mismo archivo, "revalidates authority before the permit" | La raíz se abre con un `deadline` a pocos milisegundos y la prueba espera a que pase entre preparar e iniciar. Espera `authority` con `autoridad-vencida`. | Comprobar la autoridad solo al preparar. |
| I20 | `managed-root.capacity.test.ts`, "a pair does not fit with three of four slots taken" | Cupo 4. Tres plazas ocupadas, una por una tarea suelta admitida y dos por intentos. Commit que liga un par. Espera `capacity` con `needed: 2, free: 1` y cero intentos nuevos. | Comprobar el cupo ligadura por ligadura deja entrar una. |
| I20 | mismo archivo, "only one of two concurrent pairs fits with two of four slots taken" | Dos raíces. Dos commits a la vez, cada uno con su par. Espera un `ok` y un `capacity`. | Leer la ocupación fuera de la transacción. |
| I20 | mismo archivo, "a writer has one owner across roots" | La unidad A de la raíz 1 tiene `repo:x#rama`. La raíz 2 pide el mismo recurso: `writer-held`, nada ligado. Un segundo intento de A lo conserva. Aceptada A, la raíz 2 lo obtiene. | Quitar la comprobación 6 de `bindings` y `idx_managed_root_writers_live`, o liberar al fallar un intento. |
| I20 | mismo archivo, "attempts of one root share its model-call budget" | `maxModelCalls: 2`. Una llamada por intento en dos intentos. La tercera se rechaza con "Managed model tree budget exhausted". | Que `budgetTreeForTask` conteste `kind: "task"` para una tarea de raíz: cada intento tendría su propio fondo. |
| I20 | mismo archivo, "a fenced attempt keeps its slot across pause and resume" | Cupo 4. La raíz X admite dos intentos y se pausa. La raíz Y intenta ligar cuatro: `capacity` con `free: 2`. | Contar la plaza solo por admisiones activas. |
| I20 | mismo archivo, "repeating a result creates neither a writer nor budget" | Reporta el mismo resultado dos veces y repite el commit que lo consume. Cuenta filas de `managed_root_writers`, `managed_task_budgets` y `managed_task_budget_reservations` antes y después: iguales. | Insertar la fila de presupuesto al consumir. |

### El párrafo "Verificar" del bloque, frase por frase

| Frase | Dónde queda cubierta |
|---|---|
| Inyectar fallos antes y después del commit | Cada archivo nuevo tiene un caso de autoridad revocada en `transaction` y otro en `commit`, y un caso de ACK perdido. I04, filas cuarta y quinta. Mecanismos en 4.6. |
| Competir dos reconciliadores | I03, primera fila. I20, segunda fila. |
| Pausa y revisión ganan a admisiones obsoletas | I05, filas cuarta a séptima. `managed-root.plan.test.ts`, "a plan revision cancels the attempts it invalidates and keeps the rest": cambia A, deja B igual. Espera el intento de A cancelado, `host.admit` de A rechazado con el error de hoy para una tarea cancelada, una admisión con la revisión vieja en `root-refused` con `stale-plan-revision`, y el intento, los claims y la aceptación de B intactos. En otra raíz, A se acepta en la revisión 1, la revisión 2 la cambia y la 3 la deja como en la 1, sin ligar nada entre medio. Una ligadura de A entra y no contesta `unit-accepted`. |
| `Started` antes de pausa y envío después de su ACK | I05, segunda fila. |
| Control repetido devuelve recibo. Otro `Resume` con época obsoleta falla | I05, tercera fila. |
| Repetir un resultado no crea escritor ni presupuesto | I20, última fila. |
| Pares con dos y tres plazas ocupadas de cuatro | I20, filas primera y segunda. |
| Los controles nativos de presupuesto siguen verdes | Los casos de hoy de `scripts/agent-work/test-runtime.sh`, sin tocar: `budget_tree`, `budget_context`, `budget_evasion`, `recovery_limit`, `recovery_queue`, `admission_restart`, `handling_atomic`, `handling_unresolved`, `resource_release`, `waiting_reason`, `registration_identity`, `result_receipt`. |

### Lo que no es un ensayo integrado y también se prueba

| Qué | Archivo y caso | Fallo que la pone roja |
|---|---|---|
| El esquema rechaza cada estado ilegal de 4.1 | `managed-root.schema.test.ts`, una fila de tabla por restricción: un `INSERT` o un `UPDATE` ilegal que tiene que fallar | Quitar la restricción de esa fila |
| Las cinco reglas que viven en código | El caso de cada una: un intento terminado no vuelve a vivo y un efecto no retrocede (`managed-root.commit.test.ts`, `managed-root.effect.test.ts`). El commit no liga una tarea que ya existía. Un commit con la época de una raíz pausada contesta `root-not-active`. Una raíz recién abierta tiene sus tres filas iniciales (`managed-root.store.test.ts`). Aceptar y cancelar no dejan escritor vivo (`managed-root.capacity.test.ts`), y revisar tampoco (`managed-root.plan.test.ts`, en la rebanada 12) | Quitar esa comprobación |
| Cercar una admisión respeta el `CHECK` de la tabla de hoy | `managed-root.control.test.ts`, "fencing a claimed admission keeps the admissions CHECK": una admisión `claimed` de verdad, hecha con `claim` y con un host atado, y después la pausa | Cercar sin anular `claim_id` y `request_digest` |
| Una base 27 se queda en 27 | `managed-root.schema.test.ts`, "keeps a v27 database at version 27 and creates the root tables on first use". Una base nueva nace con las once tablas, así que la prueba fabrica la vieja: abre una base, borra las once con `DROP TABLE`, hijas primero, cierra y vuelve a abrir. Espera `user_version` 27, cero tablas `managed_root%` y la apertura sin error. Llama `ensureManagedRootSchema` y espera once tablas, tres índices y `user_version` 27. Cierra y abre otra vez sin error. Desde la rebanada 5 gana un caso: sobre la base sin tablas, `readManagedRoot` contesta `null` y siguen siendo cero tablas. Desde la 13, lo mismo con `recoverManagedRootRequester`, que contesta `[]` | Subir la versión, crear las tablas al abrir la base, o crearlas al leer |
| Las funciones puras siguen al contrato | `managed-root.machine.test.ts`: tablas literales de control y de efecto, y casos literales de `deriveAttemptState`, `scopeRefusal` y `digestPlanUnits`. Con `AGENT_WORK_G_ROOT`, además: `attemptTransitionAllowed` contra las 64 filas de `unidad/transiciones.json`, `authorityRefusal` contra `autoridad/efectos.json`, y `validateRootPlan` contra la regla y la ruta de cada plan de `casos.json` La compuerta de la sección 6 exporta siempre `AGENT_WORK_G_ROOT`. Una corrida sin la variable no cuenta para esta fila | Cambiar una celda de una tabla de 4.2, o una regla del plan |
| Un contador no sube dos veces por la misma lectura | `managed-root.commit.test.ts`, "two reconcilers cannot both raise a counter from the same value": dos commits con `expected: 0`. Uno entra y el otro recibe `counter-mismatch` | Calcular el ordinal sin la clave primaria |
| Abrir es idempotente | `managed-root.store.test.ts`: misma llave y mismo pedido, misma raíz y `replayed: true`. Otro pedido, `operation-conflict`. Un trabajador gestionado no abre. Un presupuesto mayor que el perfil contesta `budget-exceeds-profile` con la primera llave que sobra. Una unidad con un repo fuera de la autoridad contesta `authority` | Quitar la búsqueda de la apertura anterior |
| Una tarea de raíz no se decide ni se cancela por el camino de hoy | `managed-root.access.test.ts`: `resolveManagedTask` y `cancelManagedTask` contestan su error de hoy. `inspectManagedTask` contesta la foto al solicitante vigente y `null` a cualquier otro. `claim` rechaza una tarea de raíz sin `root` y una tarea suelta con `root` | Dejar pasar `root` en `resolve` |
| Recuperar tras `/new` | `managed-root.requester.test.ts`: la instancia nueva recibe `requester-rebound`, recupera sin dar ningún `rootId`, y recibe un despertar por los resultados pendientes. La instancia vieja pierde el acceso. Otra sesión del mismo agente recupera una lista vacía. La prueba de hoy "does not transfer a task to a replacement session incarnation" sigue verde | Comparar solo `agentId` |
| El turno despertado es el dueño | mismo archivo, "a wake from a sender-owned root commits from the woken turn": abre la raíz con remitente, reporta, drena la cola de entregas y hace commit desde el turno despertado | Encolar el despertar sin `requesterIdentity` |
| La ruta viva no cambió | El e2e `ruta_viva` de G contra R, en cada SHA | Cualquier cambio de conducta en `claim`, en `report` o en las ocho comprobaciones de alcance para una tarea suelta |

### La prueba de tabla de redacción

La prueba es "declares no managed task input field that transcript redaction masks" (`src/agents/tasks/managed-tasks-tool.test.ts:802`). Hoy junta los nombres de campo de las herramientas `managed_tasks_*`, de `managedTaskAssignmentSchema` y de `managedTaskHandlingDecisionSchema`, y compara contra un objeto literal. SUA-01 la extiende así:

1. **Entradas de raíz.** Añade los esquemas que exporta `managed-root.json.ts`, uno por orden. La tabla literal gana cada nombre nuevo, todos en `false`: `rootId`, `idempotencyKey`, `requestDigest`, `authority`, `authorityRef`, `grantedBy`, `grantedAt`, `actions`, `repos`, `accounts`, `destinations`, `deadline`, `mode`, `budget` y sus diez llaves, `plan`, `units`, `unitId`, `title`, `dependsOn`, `criteria`, `criterionId`, `text`, `verifier`, `scope`, `assumptions`, `qualityPolicy`, `version`, `revisionId`, `expectedPlanRevision`, `scopeChange`, `removedCriteria`, `command`, `commandId`, `expectedControlEpoch`, `issuedAt`, `decisionId`, `consumedResults`, `generation`, `resultDigest`, `evidenceClaims`, `evidenceId`, `planRevision`, `artifactRef`, `environment`, `host`, `versions`, `principal`, `role`, `procedure`, `outcome`, `at`, `expiresAt`, `outcomes`, `attempt`, `bindings`, `writers`, `effects`, `effectId`, `action`, `repo`, `destination`, `cancellable`, `counters`, `counter`, `expected`, `startId`, `occurred`, `evidenceRef`, `note`, `resourceRef`, `root`.
2. **Parámetros RPC de host.** Cierra la fila "SUA-00 (redacción no cubre los RPC de host)" de `followups.md`. `src/gateway/server-methods/managed-tasks.ts` exporta sus esquemas de parámetros, que hoy son constantes privadas. Una segunda tabla literal los recorre. En esa tabla `token` vale `true` y todo lo demás `false`. `token` queda tapado a propósito. Es el secreto del productor, viaja del host al gateway por RPC con autenticación de dispositivo y ningún agente lo escribe como argumento de una herramienta. Si los parámetros de un RPC llegan a algún registro es `unknown` (sección 8).
3. **Lo anidado en `receipt`.** `resolveInput.receipt` ya declara `taskId`, `generation` y `resultDigest`. La función `fieldNames` de la prueba recorre el esquema JSON de la herramienta, que declara `receipt` como `Type.Unknown()`. La extensión la hace recorrer también los esquemas `zod`, donde esos tres campos sí están.

Ningún campo nuevo se llama `key`, `token`, `secret`, `session`, `signature`, `credential`, `authorization`, `cookie`, `jwt` ni `password`, ni termina en `_key`, `_token` o `_secret`.

## 6. El corte en rebanadas

Dieciséis rebanadas. Cada una es un PR de R, salvo la última, que es de G. Cada una trae su prueba y deja verde lo anterior.

**Dónde se corre.** Nunca en el checkout compartido de R. `RWT` es el worktree de R de la rebanada, con su propio `pnpm install` y su propio `pnpm build`. `GWT` es un checkout de G en `origin/main`, en `2c817ce7` o posterior, que es donde entró el caso `ruta_viva`. Su SHA se anota en el recibo de la rebanada. Antes de correr nada, `git -C "$RWT" rev-parse HEAD` imprime el SHA de la rebanada.

"Verde lo anterior" quiere decir estas tres cosas:

```
cd "$RWT"
AGENT_WORK_G_ROOT="$GWT" node scripts/run-vitest.mjs src/agents/tasks/*.test.ts src/gateway/server-methods/managed-tasks.test.ts
pnpm lint:core && pnpm format:check && pnpm tsgo:core && pnpm db:kysely:check

cd "$GWT"
for caso in registration_identity result_receipt admission_restart handling_atomic handling_unresolved \
            resource_release budget_tree budget_context budget_evasion waiting_reason recovery_limit \
            recovery_queue delegation_bypass; do
  AGENT_WORK_RUNTIME_SOURCE="$RWT" bash scripts/agent-work/test-runtime.sh "$caso"
done
AGENT_WORK_RUNTIME_SOURCE="$RWT" bash scripts/tests/test-agent-work-e2e.sh ruta_viva
```

Tres cosas hacen que esa compuerta pueda salir en rojo de verdad:

- Cada corrida de `test-runtime.sh` imprime `candidateSha`. Tiene que ser el SHA de la rebanada. Si imprime `4acb881e`, la corrida probó otro árbol y no vale.
- `ruta_viva` cuenta como verde solo si su salida no trae `skipped`. El caso se salta si el usuario no está en el grupo de `AGENT_WORK_E2E_SLOT_GROUP` o si ese grupo tiene procesos vivos (`test_agent_work_ruta_viva_e2e.py:103` y `:106`). Un caso saltado sale con 0.
- En un checkout de G anterior a `2c817ce7`, `test-agent-work-e2e.sh ruta_viva` sale con 2, porque el caso no existe.

**Qué se puede hacer hoy.** El plan dice que "Preparación antes de SUA-01" se cumple antes del primer PR del bloque (plan, línea 408). Su punto 3 es `ruta_viva` en `test-agent-work-e2e.sh` y verde sobre R HEAD. El caso ya está en `origin/main` de G. Falta correrlo. Así que ninguna rebanada se mergea, tampoco la 1, hasta que `ruta_viva` haya salido verde sobre `4acb881e` en la rebanada 0. Las rebanadas se pueden escribir y revisar antes.

| N.º | Rebanada | Qué cambia | Su prueba | Toca código que corre la ruta viva |
|---|---|---|---|---|
| 0 | Línea base | Nada. Se corren los tres bloques sobre un worktree de R en `4acb881e` y se guarda la salida. | Las de hoy | No |
| 1 | Tipos, parsers y funciones puras | Archivos nuevos `managed-root.types.ts`, `managed-root.json.ts`, `managed-root.machine.ts`. Nadie los llama todavía. | `managed-root.machine.test.ts` | No |
| 2 | Un solo punto de acceso | `resolveTaskAccess` en `managed-task.db.ts` sustituye las ocho comparaciones de alcance. Solo contesta `loose` o `null`. Cada sitio conserva su mensaje de error. | Las de hoy, más una tabla en `managed-root.access.test.ts` que llama cada operación con un llamador ajeno y espera el mismo error de hoy | Sí |
| 3 | El árbol de presupuesto como tipo | `BudgetTree` y `budgetTreeForTask` sustituyen a `rootForTask`. Solo existe `kind: "task"`. | `budget_tree`, `budget_context`, `budget_evasion`, `recovery_limit`, `recovery_queue` | Sí |
| 4 | **Esquema** | El DDL de las once tablas, su registro perezoso, `ensureManagedRootSchema`, los tipos generados y las listas de 4.1. Ninguna orden las usa. | `managed-root.schema.test.ts`: una fila por restricción, y "keeps a v27 database at version 27" | No |
| 5 | Abrir y leer | `openManagedRoot`, `readManagedRoot` y su registro en el trabajador. | `managed-root.store.test.ts` | No |
| 6 | Commit: ligar | `commitManagedRootDecision` con `bindings` y recibo. Tareas de raíz, su fila de presupuesto, `BudgetTree` con `kind: "root"`, cupo de la raíz y la regla de plaza ocupada. `limits.gatewaySlots` ya viaja en la firma, y el commit lo comprueba desde la 11. `resolveTaskAccess` contesta `root` para `inspect`. | `managed-root.commit.test.ts`, casos de unidades iniciales y de repetición | Sí: `budgetTreeForTask` gana una rama |
| 7 | Admitir una tarea de raíz | `rootAdmissionRefusal` dentro de `claim`, y la variante `root-refused` del recibo. El campo `root` de la admisión y el sello de época. `resolveTaskAccess` contesta `root` para reservar, `claim`, `query`, `recordWait` y `clearWait`. Los despertares de `report` y de las incidencias de host usan la instancia vigente y llevan `requesterIdentity`. | I04, filas primera a tercera. "a wake from a sender-owned root commits from the woken turn" no cabe todavía. Necesita consumir y pasa a la 8 | Sí. Es la última que edita funciones de la ruta viva |
| 8 | Commit: consumir, acreditar y terminar | `consumedResults`, `evidenceClaims`, `outcomes`. Con esto existe el fan-in. | I03 completo. I04, filas cuarta a sexta. La sexta entra con las cuatro listas que ya existen y gana `effects` en la 10 y `counters` en la 11. El caso del turno despertado | No |
| 9 | Control | `controlManagedRoot`: pausa con cerco de admisiones, reanudación, cancelación, y su recibo con `runningAttempts` y `fencedAdmissions`. | I05, filas de control y de admisión | No. Escribe `fenced` en admisiones de tareas de raíz. Las funciones de hoy no se tocan |
| 10 | Efectos | `effects` en el commit, `startManagedRootEffect`, `settleManagedRootEffect`, y los efectos en el recibo de pausa. | I05, filas de efecto. I06 | No |
| 11 | Cupo, escritor y contadores | Cupo del gateway, par atómico, `writers`, `counters`. La llave `managedTasks.capacity` en `ManagedTasksConfigSchema`, opcional. | I20 | No |
| 12 | Revisión de plan | `reviseManagedRootPlan`. | `managed-root.plan.test.ts`, con el caso de escritores tras revisar | No |
| 13 | Recuperar al solicitante | `recoverManagedRootRequester` y el despertar de la raíz. | `managed-root.requester.test.ts` | No |
| 14 | Entrada del gateway y redacción | `managedTasks.root.read` y `managedTasks.root.control` en `src/gateway/server-methods/managed-tasks.ts`, con sus descriptores (`src/gateway/methods/core-descriptors.ts`). La prueba de tabla de redacción extendida. | La prueba de tabla, y dos casos nuevos en `src/gateway/server-methods/managed-tasks.test.ts` | El archivo sí. Sus manejadores de hoy no cambian |
| 15 | Casos en G | `docs/spec/sistema-agentes.v1.md` gana la frase del conflicto 2 ("antes de admitir, la época vigente de la raíz"). `scripts/agent-work/test-runtime.sh` gana `root_contract`, `root_fan_in`, `root_recovery`, `root_control`, `root_effects`, `root_capacity` y `root_redaction`. `runtime-map.json` y el recibo del bloque. | Cada caso corre su archivo de R. `root_contract` exporta `AGENT_WORK_G_ROOT`, y una prueba de G valida con `contrato.py` los documentos que `readManagedRoot` emitió | No |

### Por qué este orden

- **La 1 no depende de nada.** Son archivos nuevos y puros. Se puede escribir hoy, aunque `ruta_viva` no esté lista. Su merge espera, como el de todas.
- **La 2 y la 3 quitan antes de añadir.** Dejan un solo lugar donde se decide el acceso y un solo lugar donde se forma el árbol. No cambian ninguna conducta. Las rebanadas 6 y 7 añaden después una rama en cada uno, en vez de ocho.
- **La 4 es la primera que toca el esquema.** Antes de mergearla, `ruta_viva` tiene que estar verde contra R en el SHA de la rebanada, como pide el plan ("Preparación antes de SUA-01", punto 3). Aquí `ruta_viva` corre en todas, porque la 2 y la 3 ya editan funciones que la ruta viva ejecuta, aunque no toquen el esquema ni `managed-tasks.ts`.
- **El DDL entra completo en la 4.** Una tabla perezosa no existe en la Mini hasta que alguien abre una raíz. Por eso el esquema de las once tablas se puede corregir en una rebanada posterior sin migración, mientras no haya raíces en producción. Meterlo completo deja al revisor ver el modelo entero una vez.
- **La 7 va antes que la 8.** Para consumir un resultado primero hay que poder admitir la tarea y reportarlo.

### La reversa se ensaya en la rebanada 4

La afirmación central de la migración es que el código instalado abre una base que ya tiene las tablas nuevas. Se comprueba antes de mergear la 4, en la MacBook, con dos árboles de fuente: `RWT4`, el worktree de la rebanada 4, y `RWT0`, un worktree de R en `4acb881e`. El arnés `managed-cli-gateway-harness.mjs` importa el código de `AGENT_WORK_RUNTIME_SOURCE` con `tsx`, lee operaciones JSON por la entrada estándar y termina con `{"op":"stop"}`.

```
S=$(mktemp -d)
arnes() {  # $1 = árbol de R. Corre con ese árbol como directorio de trabajo.
  ( cd "$1" && AGENT_WORK_RUNTIME_SOURCE="$1" OPENCLAW_STATE_DIR="$S" CROSS_GATEWAY_TOKEN=ensayo \
      node --import "$1/scripts/tsx.mjs" "$GWT/scripts/tests/fixtures/agent-work/managed-cli-gateway-harness.mjs" )
}
printf '{"op":"stop"}\n' | arnes "$RWT4"                       # 1. la base nace con el código nuevo
BASE="$S/state/openclaw.sqlite"
sqlite3 -readonly "$BASE" "PRAGMA user_version; select count(*) from sqlite_master where type='table' and name like 'managed_root%'"
sqlite3 "$BASE" < raiz-de-ensayo.sql                           # 2. una raíz, su época 1, su revisión 1 y una unidad
printf '{"op":"tasks"}\n{"op":"stop"}\n' | arnes "$RWT0"       # 3. el código de 4acb881e abre esa base
```

Esperado: el paso 1 sale con 0, y la consulta imprime `27` y `11`. El paso 3 imprime una línea `{"type":"result"` para `tasks` y ninguna `{"type":"error"`. El código de salida no basta: el arnés sale con 0 aunque una operación falle. Eso prueba que el código de `4acb881e` abre y usa una base que ya tiene las tablas.

Estos comandos están leídos del arnés (`:22-27`, `:337-352`) y de cómo lo lanza `test_agent_work_main_cli_loop_e2e.py:66`. No se corrieron. Quien haga la rebanada 4 los corre una vez y corrige lo que no cuadre antes de darlos por buenos. `raiz-de-ensayo.sql` son los cuatro `INSERT` legales del script de 4.1.

Si el paso 3 falla, este diseño no cumple "reversa compatible" y la rebanada 4 no se mergea. La alternativa está en 4.8, conflicto 1.

Este ensayo compara dos árboles de fuente, no dos paquetes instalados. La comprobación con el paquete instalado de `4acb881e` sobre una copia con las tablas es el método de T11-c (`T11.md`, "la reversa con los dos binarios reales") y se hace antes de la primera instalación en la Mini. `ruta_viva` no entra en este ensayo, porque crea su propio directorio y su propio gateway.

### Primera instalación en la Mini: después de la rebanada 7

La 7 es la última rebanada que edita funciones que la ruta viva ejecuta (`claim`, `report`, `recordManagedTaskHostIncidentInWorker`). De la 8 en adelante todo es código que solo corre para una raíz, y en producción no hay raíces. Instalar ahí separa los dos riesgos. Primero se comprueba que la ruta viva sigue igual con todo lo que la toca, y el resto del bloque llega después sin tocarla.

Instalar antes, tras la 3, costaría una madrugada más y no probaría nada que `ruta_viva` no pruebe ya en local. Instalar solo al final juntaría en una noche todo el cambio de la ruta viva con todo lo nuevo.

La instalación sigue "Regla de instalación en vivo" del plan y `T12-runbook.md`. Lo que se comprueba ahí, además de lo que ese runbook ya pide:

| Comprobación | Comando en la Mini | Esperado |
|---|---|---|
| El binario es el de la rebanada | `cat ~/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw/dist/build-info.json` | `commit` igual al SHA mergeado |
| El paquete anterior abre una base con las tablas | Antes de instalar, en la MacBook, con el método de T11-c | El paquete de `4acb881e` arranca sobre la copia sembrada del ensayo de la rebanada 4 |
| La versión del esquema no se movió | `sqlite3 -readonly ~/.openclaw/state/openclaw.sqlite "PRAGMA user_version"` | `27` |
| No apareció ninguna tabla | `sqlite3 -readonly ~/.openclaw/state/openclaw.sqlite "select count(*) from sqlite_master where name like 'managed_root%'"` | `0` |
| La ruta viva atiende un encargo real | Un canario como el D de `B22-canarios.md`: un encargo por CLI de `main` a `mac-local/opencode` | En el spool del host, `acknowledged` y `AbsenceVerified`. En R, `result_json` guardado y un solo despertar de `main` |
| Los crons quedaron igual | `openclaw cron list --json` antes y después | Los mismos habilitados |

La ruta de la base de estado es la de `T12-runbook.md`, fila 1.1. La reversa de esta instalación es reinstalar el paquete de `4acb881e`, sin restaurar bases.

La segunda instalación es la del cierre del bloque, con la rebanada 14 mergeada. Comprueba lo mismo, y además que `openclaw gateway call managedTasks.root.read --params '{"rootId":"no-existe"}' --json` contesta `null` sin crear tablas.

## 7. Lo que no entra en SUA-01

| Qué | Por qué se queda fuera | Bloque |
|---|---|---|
| `decide`, el ciclo de reconciliación y el controlador | SUA-01 guarda y ordena. No decide. | SUA-02 |
| Herramientas `managed_roots_*` o cambios en `managed_tasks_*` | Las herramientas son archivo de SUA-02. SUA-01 entrega funciones y dos RPC. | SUA-02 |
| Importar `Plans.md` o un pedido en lenguaje natural | Es redacción de plan. Aquí el plan llega ya tipado. | SUA-02 |
| Las trece clases de excepción, su entrega y su reaviso | No hay excepción en la frontera. Un conflicto es una respuesta, no una pregunta al dueño. | SUA-02 |
| Vincular al dueño entre canales, o que el operador pase una raíz a otro dueño | Aquí el dueño es el `principal` del canal, el agente y la sesión durable. Es la regla más estrecha y la que R ya usa. Ensancharla es una decisión de identidad. | SUA-02, paso 2 |
| Quién puede emitir un claim, revocar o reducir la autoridad, delegar a un especialista | SUA-01 comprueba que el rol del verificador sea el del criterio y que la autoridad cubra el inicio. La autoridad de la raíz es inmutable aquí. | SUA-02 (I07) |
| Observación en sombra y ligar a una raíz una tarea suelta que ya existe | El commit solo crea tareas nuevas. Adoptar una tarea de `main` es otra operación y otra regla de acceso. | SUA-02 la decide. Ver el riesgo 8 |
| Elegir especialista, host, modelo y generación (`flota.v1`) | La asignación llega hecha en `bindings[].assignment`. | SUA-03, SUA-04 |
| Cambios en el host de G: qué hace cuando `host.admit` se niega por pausa, cupo por host | El host de hoy solo atiende tareas sueltas. | SUA-03 |
| La política de rondas y qué cuenta cada contador | SUA-01 da contadores. No sabe qué es una ronda. | SUA-05 |
| Adaptadores de efecto: push, merge, deploy, correo. El RPC para que un host externo pida un permiso | No hay ningún adaptador que lo llame todavía. Las funciones existen y se prueban con un adaptador de prueba. | SUA-05, SUA-08 |
| `proyeccion.v1`, panel y avisos | `readManagedRoot` da la foto. La proyección redactada es otra cosa. | SUA-06 |
| Activar raíces en producción, poner `managedTasks.capacity` en la Mini, pasar `managed_tasks_resolve` de `main` al controlador, decidir si entonces se sube la versión del esquema | Son el corte. | SUA-09O |
| Hermes | Otro host, otro almacén. | SUA-07 |
| Quitar el `UNIQUE` de `managed_task_children.child_task_id` | El fan-in no pasa por esa tabla. | Nadie |
| Dar una raíz a las tareas ya instaladas | No hay datos que migrar. | Nadie |
| Pausar una tarea suelta, o detener un proceso que ya corre | El contrato pone el control en la raíz. Un proceso con permiso es un efecto comprometido. | Nadie |
| Tocar `SessionGoal` o `/goal` | El contrato lo prohíbe. | Nadie |
| Un contrato de resultado nuevo, además de `review.v1` y `ready.v1` | El contrato pide que el bloque que lo necesite lo agregue en los dos lados. | El que lo necesite |

## 8. Riesgos, `unknown` y decisiones pendientes

**Tres estados que el esquema deja escribir.** Los encontró la revisión del diseño (2026-10-13) con un probe propio. No están entre las promesas de la sección 4.1 y los cierra una guarda en ejecución, pero el implementador tiene que saber que el esquema no los caza:

- Un `outcome_ref` que cita una orden que no existe. No lleva llave foránea porque apunta a tres cosas distintas (commit, época o revisión). Lo cubre la validación de quien lo escribe.
- Un escritor a nombre de una unidad que el plan no tiene. Lo cierran la comprobación 6 del commit y `releaseUnitWriters`.
- Un claim de evidencia con un `criterionId` que la unidad no define. Es inofensivo: nunca satisface un criterio real.

Cada uno lleva su prueba en la rebanada que escribe esa tabla: la prueba intenta el estado por la función pública y espera el rechazo.

### Lo que no se pudo comprobar

Cada fila es `unknown` hasta que alguien corra su comando. Ninguna se dio por buena.

| N.º | Qué no se sabe | Por qué importa | Comando o medición que lo contesta |
|---|---|---|---|
| 1 | Si el código de `4acb881e` abre de verdad una base 27 que ya tiene las once tablas. Leído: `collectSqliteSchemaIssues` recorre solo las tablas que el binario espera (`src/infra/sqlite-schema-contract.ts:102-160`) y busca índices únicos inesperados solo en ellas. No se corrió. | Es la base de "reversa compatible". | El ensayo de la sección 6, "La reversa se ensaya en la rebanada 4". Y antes de la primera instalación, el mismo ensayo con el paquete instalado, como T11-c. |
| 2 | Si R acepta como perezosas unas tablas con índices únicos parciales y con llaves foráneas compuestas hacia sí mismas. Leído: la reparación de índices salta los índices cuya tabla no existe (`src/infra/sqlite-index-schema.ts:101-106`), y el SQL canónico ya tiene llaves foráneas compuestas (`openclaw-state-schema.sql:1529` y `:1914`), ninguna hacia su propia tabla. | Cinco de las once tablas tienen una llave foránea a su fila anterior. Si R no las acepta, se quitan esas cinco llaves. Entonces "una fila saltada" pasa a ser regla de código y sale de la tabla de 4.1, porque el `CHECK` solo no ve que la fila anterior no existe. | `managed-root.schema.test.ts`, caso "keeps a v27 database at version 27", más `node scripts/run-vitest.mjs src/state/openclaw-state-schema-compatibility.test.ts`. |
| 3 | Cuánto sube el tope de lecturas del doctor (`<= 897`, `src/state/openclaw-state-db.test.ts:4853`). | La rebanada 4 puede poner roja esa prueba. | `node scripts/run-vitest.mjs src/state/openclaw-state-db.test.ts` sobre la rebanada 4. |
| 4 | La línea base de R en `4acb881e`. Este encargo no corrió ninguna prueba de R. | Sin línea base, un rojo no se puede atribuir. | Rebanada 0. |
| 5 | Qué hace el lazo del host de G cuando la misma tarea vuelve con otro `claimId`. Leído: la llave de una operación es `host_id`, `task_id`, `generation` e `instance_id`, sin `claimId` (`scripts/agent-work/contracts.py:12-21`). El `claimId` sí entra en el contenido (`host.py:204`), y `_register` lanza "operation key conflicts with different content" si la misma llave llega con otro contenido. O sea que una tarea readmitida tras un cerco, si un host ya la había tomado, choca en el host. No se leyó quién atrapa ese error. | Por esto existe `attempt-spent`. Un intento cuya admisión cercada ya tocó un host no se vuelve a admitir. No afecta a tareas sueltas. | Un caso en `test-agent-work-sesion.py` con un `FakeR` que entrega la misma tarea con dos `claimId`. Es de SUA-03. |
| 6 | Si el turno que despierta por un evento de sistema reproduce el `principal` del dueño. Leído, no corrido: el despertar lleva `requesterIdentity` (`managed-task.delivery.ts:29-67`), el turno despertado toma de ahí su remitente (`src/infra/heartbeat-runner-run.ts:124-130`) y ese remitente llega a `captureManagedTaskTurn` (`src/agents/openclaw-tools.managed-tools.ts:67`). | Si no lo reproduce, el controlador despertado no puede leer la raíz ni hacer commit. | En la rebanada 8, el caso "a wake from a sender-owned root commits from the woken turn" de `managed-root.requester.test.ts`: abre la raíz con remitente, reporta, drena la cola y hace commit desde el turno despertado. |
| 13 | Si una corrida nativa puede quedar viva cuando la pausa cerca su admisión entre el registro de la corrida y `confirm`. `confirm` falla y el pipeline limpia (`src/agents/spawn-pipeline.ts:98-138`). No se leyó `subagent-registry-queued-registration.ts` para saber si el lanzamiento en cola ya había arrancado. Lo que sí está leído: sin admisión `admitted`, esa corrida no puede reservar llamadas a modelo (`validateModelCaller`). | El recibo dice que una admisión cercada nunca inició. | El caso "a native start is refused while paused" con la pausa puesta entre `registerSubagentRun` y `confirm`, comprobando que `subagent_runs` no conserva una corrida viva de esa tarea. |
| 7 | Si los parámetros de un RPC del gateway llegan a algún registro. | `capability.token` viaja en `managedTasks.host.*`. | `grep -rn "params" /Users/dn/dev/openclaw-agent-work-integration/src/gateway/server-methods/*.ts \| grep -i "log\|redact" \| head`, y leer el manejador común de `GatewayRequestHandlers`. |
| 8 | El perfil de presupuesto instalado en la Mini: `maxConcurrentTasks`, `maxChildren`. Este encargo no puede leer `openclaw.json`. | Una raíz no puede pedir más que el perfil. Con `maxChildren` en 0 una raíz no liga nada. | En la Mini, `openclaw gateway call config.get --params '{}' --json` y leer `managedTasks.profile`. Lo corre quien instale. |
| 9 | Si el CI de R corre para la rama `feat/agent-work-integration`. `SUA-00-mediciones.md` ya lo dejó en `unknown`. | Sin CI, la batería completa de cada rebanada se corre a mano. | `gh run list --branch feat/agent-work-integration --limit 5` en el repo de R. |
| 10 | Cuánto sirve el reinicio de prueba. Leído: `drainGlobalSingletonLifecycleState("restart")` solo corre los `reset` registrados con ciclo `close-and-restart` (`src/shared/global-singleton.ts:76-88`). Una variable de módulo sin registrar sobrevive. | Una prueba de I04 no ve un estado guardado en una variable de módulo. | No hay comando que lo cierre. Se cubre en revisión con el `grep` de la primera fila de I04, y con la regla de que `managed-root.*.ts` no tiene estado de módulo. |
| 11 | Si un respaldo redactado hecho por el binario anterior queda con llaves foráneas rotas cuando existen filas en `managed_root_attempts`. Ese binario omite `managed_tasks` y no conoce las tablas nuevas. | Solo pasa si hay reversa con raíces ya creadas. | Con el build de `4acb881e` sobre la copia del ensayo 1, el flujo de `src/snapshot/git-backup-codec.test.ts:179-211`. |
| 12 | Si `STRUCTURED_APP_PASSWORD_FIELD_RE` (`src/logging/redact.ts`) altera el valor de `text` o de `reason` cuando contiene cuatro grupos de cuatro letras con guiones. | Un criterio con ese patrón se guardaría cambiado en el transcript. La prueba de tabla no lo ve, porque solo mira nombres. | Leer los usos de esa expresión en `redact.ts`, y un caso en la prueba de tabla con un `text` que tenga el patrón. |

### Riesgos conocidos

1. **Una tarea de raíz que el binario anterior no gobierna.** Ya está en 4.1, "Reversa". Mientras no haya raíces no existe. Lo cierra SUA-09O, que es quien las activa.
2. **Fuga de plazas heredada.** Una tarea con destino agente que se cancela sin resultado retiene su plaza hasta que reporta (`managedTaskAdmissionRetainsBudgetSlot`, y la prueba "keeps the slot of a cancelled agent task without a result"). El cupo del gateway hereda esa regla. Se conserva a propósito. Contar distinto que R daría dos verdades sobre la misma plaza.
3. **El cupo recorre todas las admisiones activas.** Cada commit que liga cuenta las plazas de todo el gateway. `assertManagedAdmissionBudgetReservation` ya hace hoy un recorrido igual por cada admisión. Con el volumen de hoy no importa. Si importara, la medición es el tiempo del commit con mil tareas terminadas en la base.
4. **El commit es ancho.** Seis listas en una orden. Es el precio de una sola transacción y un solo recibo. Un controlador que quiera pasos chicos manda commits chicos.
5. **La huella decide qué evidencia sobrevive.** Corregir un error de dedo en el texto de un criterio cambia la huella, cancela el intento vivo y deja su evidencia sin efecto. Es seguro y es tosco. Si SUA-02 necesita conservar evidencia a través de un cambio así, hará falta una tabla de arrastre con justificación. Va descrito en 4.8, conflicto 4.
6. **Dos binarios, un checkout.** R local es un solo checkout compartido. Otro agente construye ahí el e2e de la ruta viva. Cada rebanada se escribe en un worktree propio de R, con su propio `dist`.
7. **La llave `managedTasks.capacity` rompe al binario anterior.** `ManagedTasksConfigSchema` es `strictObject`. Si la llave está en `openclaw.json`, el binario `4acb881e` rechaza la configuración. SUA-01 no la pone en la Mini. Quien la ponga la quita antes de una reversa.
8. **La sombra de SUA-02 no tiene dónde apoyarse.** El plan dice que SUA-02 observa en sombra las tareas que `main` sigue decidiendo con `managed_tasks_resolve`, y "calcula la decisión sobre la raíz". Esas son tareas sueltas. Este diseño no liga una tarea suelta a una raíz. SUA-02 tiene dos salidas: una raíz de sombra que no liga nada y solo guarda su decisión en un commit sin `bindings`, o una operación nueva de adopción. La primera no pide nada más a SUA-01.
9. **Una raíz que su dueño ya no alcanza.** El dueño es el `principal` del canal, el agente y la sesión durable (4.4, "Límite conocido"). Si David abre una raíz por Telegram y después solo escribe por otro canal, ningún turno suyo es el dueño. El operador puede leerla y cancelarla, no moverla. SUA-02 decide cómo se vincula una identidad entre canales.

### Decisiones pendientes de David

Ninguna impide escribir SUA-01. Dos hacen falta antes de activar raíces, que no es en este bloque:

- **El cupo del gateway.** Pregunta exacta: "¿Cuántos trabajos de raíces pueden correr a la vez en todo el gateway, contando los encargos sueltos de `main`?". El diseño del sistema usa cuatro como ejemplo, y `workers.v1.json`, ya retirado, decía `max_external_sessions: 4`. Ninguno de los dos es una decisión de David. Las pruebas usan cuatro porque el plan lo pide ("dos y tres plazas ocupadas de cuatro"). La Mini se queda sin esa llave hasta que David conteste, y sin llave ninguna raíz liga nada.
- **De quién es una raíz.** Pregunta exacta: "Una raíz que abriste por Telegram, ¿la puede seguir un turno de `main` que no viene de ti, como un cron con sesión, o un mensaje tuyo por otro canal?". Este diseño contesta que no, que es lo más estrecho y lo que R hace hoy con las tareas. Si la respuesta es sí, cambia qué entra en `owner_scope`, y eso es una línea en `openManagedRoot` más su prueba. No cambia ninguna tabla.

### Lo que impide mergear, que no es una decisión

`ruta_viva` ya está en `origin/main` de G (`2c817ce7`). Lo único que falta antes del primer merge es la rebanada 0: la línea base, con `ruta_viva` verde y sin saltos sobre `4acb881e` (sección 6).
