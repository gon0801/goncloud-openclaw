# sistema-agentes.v1, el contrato común del sistema unificado de agentes

Fecha: 2026-10-13. Estado: contrato publicado por SUA-00. Ningún código de
producción lo consume todavía. Lo consume el validador
`scripts/sistema_agentes/contrato.py`, que ejercitan los fixtures de
`scripts/tests/fixtures/sistema-agentes/` y la prueba
`scripts/tests/test-sistema-agentes-contrato.py`. Los bloques SUA-01 a SUA-07
lo implementan en su host. Plan: [SUA](../superpowers/plans/2026-10-05-sistema-agentes-unificado.md).
Diseño: [sistema unificado](../superpowers/specs/2026-10-05-sistema-agentes-unificado-design.md).
Inventario que lo acompaña: [SUA-00-inventario](../evidence/sistema-agentes-unificado/SUA-00-inventario.md).

## Para qué

Hoy un pedido de David viaja por formas distintas según la ruta: una tarea
gestionada de R con `review.v1` o `ready.v1`, un `LISTO <sha>` escrito en una
ventana, un registro `corrida.v2`, un `runbook-progress.v2`. Ninguna de esas
formas dice qué se pidió, con qué autoridad, qué unidades faltan ni qué
evidencia acredita cada criterio. Este contrato fija siete esquemas que todos los
hosts comparten: meta, unidad, resultado, evidencia, control, flota y excepción.
Dos esquemas auxiliares, autoridad y proyección, los acompañan porque meta los
necesita y porque el panel los lee. Cada host guarda y decide con su propio
mecanismo. Lo que comparte es la forma y los fixtures.

## Decisión sobre `SessionGoal` y `/goal` de R

La meta de SUA no reutiliza ni extiende `SessionGoal`. Se llama **raíz**
(`root` en los campos) y vive junto a las tareas gestionadas, bajo
`src/agents/tasks/`, nunca en `src/agents/goals/`. La evidencia, leída en R
`4acb881e015a`:

- `SessionGoal` es un objetivo de texto por sesión. Un solo goal por sesión
  (`src/config/sessions/goals-transitions.ts:79-81`). Sin plan, unidades,
  dependencias, autoridad ni época (`packages/gateway-protocol/src/schema/sessions-goal.ts:6-31`).
- Su esquema es `closedObject` con `schemaVersion: Literal(1)`. Cualquier campo
  nuevo cambia el protocolo publicado.
- `tokenBudget` mide tokens de la sesión, no de un árbol de tareas
  (`goals-transitions.ts:48-51`). `ManagedBudgetProfile` ya mide el árbol
  (`src/agents/tasks/managed-task.types.ts:198-209`). Son presupuestos distintos.
- `/new` y `/reset` borran el goal (`src/auto-reply/reply/session.ts:1027`).
  Una raíz tiene que sobrevivir a una sesión nueva del propietario.
- `SessionGoal` y `managedTasks` no se tocan en el código. `git grep -i goal`
  en `src/agents/tasks` da cero resultados.
- El nombre `goal` ya está tomado en el protocolo (`sessions.goal.update`,
  `sessions.goal.clear`), en el comando `/goal`, en tres herramientas
  (`get_goal`, `create_goal`, `update_goal`) y en la UI.

Lo que sí se reutiliza es el patrón de `src/config/sessions/goals-operations.ts`:
`operationId` por mutación, recibo durable, `replayed: true` en el reintento
exacto y conflicto en el reintento distinto. El control de la raíz copia ese
patrón con `commandId`.

Lo que ya existe con otro nombre y la raíz no duplica: `root_task_id` en
`managed_task_children` (`src/state/openclaw-state-schema.sql:1675-1681`), el
presupuesto por árbol y las reservas (`managed_task_budgets`), la admisión
(`managed_task_admissions`), la cancelación en cascada
(`managed-task.handling.worker.ts`) y las incidencias de host
(`managed-task.host-incident.worker.ts`).

## Regla de nombres de campo

Todo campo nuevo va en camelCase y no usa un nombre que la redacción de R tape.
La prueba de tabla "declares no managed task input field that transcript
redaction masks" (`src/agents/tasks/managed-tasks-tool.test.ts:802-880`) fija
los nombres de las herramientas `managed_tasks_*` contra
`isSensitiveFieldKey` (`src/logging/redact.ts:970-972`), que prueba
`STRUCTURED_SECRET_FIELD_RE` (`:114-117`) y `STRUCTURED_SECRET_ENV_FIELD_RE`
(`:134-137`). Un campo tapado se guarda como `***` y `main` copia `***`
(hueco B12 de encargos).

Prohibidos exactos, sin importar mayúsculas: `key`, `token`, `secret`,
`session`, `signature`, `credential`, `authorization`, `cookie`, `jwt`,
`password`, `passwd`. Prohibidos por sufijo con separador: `<algo>_key`,
`<algo>-key`, `<algo>_token`, `<algo>_secret`, `<algo>_password`. También los
compuestos conocidos (`apiKey`, `idToken`, `accessToken`, `clientSecret`,
`privateKey`, `keyMaterial` y sus variantes). `idempotencyKey` y `taskKey`
pasan. `idempotency_key` y `task_key` no.

Los nombres de este contrato se comprobaron contra las dos expresiones copiadas
a mano: `rootId`, `unitId`, `planDigest`, `controlEpoch`, `commandId`,
`idempotencyKey`, `requesterId`, `authorityRef`, `evidenceId`, `effectId`,
`attemptId`, `exceptionId`, `tokenBudget`, `sessionRef`. Todos pasan. El
validador de G repite la regla por sufijo y por lista exacta en
`contrato.py` (`nombre_de_campo_prohibido`) para cada campo de cada fixture.
Un campo nuevo en R entra además a la tabla de esa prueba de R.

## Convenciones comunes

- `schema` es un literal `sistema-agentes.<tipo>.v1`. Sin él, o con otro
  literal, el documento es `ROTO`.
- Los identificadores (`rootId`, `unitId`, `criterionId`, `commandId`,
  `effectId`, `exceptionId`, `evidenceId`) son cadenas no vacías, estables y
  únicas dentro de su raíz. No llevan secretos ni rutas privadas.
- Las fechas son ISO 8601 en UTC con sufijo `Z`.
- Las referencias a artefactos (`artifactRef`, `evidenceRef`, `instructionRef`)
  son `{ "ref": "<cadena>", "digest": "sha256:<hex>" }`, como `instructionRef`
  de `ManagedTaskAssignment` (`managed-task.types.ts:30-37`).
- Un campo que un host no puede llenar va en `null` cuando el contrato lo
  permite, nunca inventado. Un consumidor trata `null` como desconocido.
- Códigos de regla. Toda violación de forma de cualquier esquema (campo que
  falta, tipo distinto, valor fuera de enum, mínimo o máximo, campo fuera de una
  tabla cerrada, `null` donde no se permite) lleva el código `schema`. Los demás
  códigos (`id-duplicado`, `dependencia-faltante`, `ciclo`, `criterio-faltante`,
  `opcion-no-ofrecida`, `campo-prohibido`, y las cinco razones de autoridad) nombran una regla que la
  forma sola no atrapa. El validador devuelve `(regla, ruta, detalle)` por
  hallazgo, con la ruta JSON del campo.
- Los campos marcados *mínimo* son los únicos que SUA-00 fija. Un bloque que
  necesite más los agrega como opcionales sin cambiar la versión.

## Forma

### Meta (`sistema-agentes.meta.v1`)

Es la raíz de un pedido. Contiene el plan vigente. Lo escribe el dueño nativo al
abrir el pedido (`open` en la interfaz propuesta del diseño). Lo lee el
controlador en cada reconciliación.

| Campo | Qué es |
|---|---|
| `schema` | `sistema-agentes.meta.v1` |
| `rootId` | Identificador estable de la raíz. Un hijo nunca crea otra raíz |
| `requester` | `{ "principal": [...], "agentId": "<id>" }`. El principal es el del turno admitido, como `managed-task.turn.ts:58-59` |
| `authority` | Un documento autoridad embebido (abajo) |
| `budget` | Las diez llaves de `ManagedBudgetProfile` (`managed-task.types.ts:198-209`), enteros no negativos. El host rechaza un valor que supere su perfil instalado |
| `plan` | El plan vigente (abajo) |
| `controlEpoch` | Entero desde 1. Sube en cada control aceptado |
| `control` | `{ "state": "active" \| "paused" \| "cancelled", "epoch": <int>, "reason": <texto o null> }` |
| `qualityPolicy` | `{ "version": "quality-kit.regla4" }`. Es la política vigente. Otra versión exige el recibo de la decisión de David (SUA-05) |
| `createdAt` | Fecha |

Plan, dentro de `plan`:

| Campo | Qué es |
|---|---|
| `revision` | Entero desde 1. Una revisión nueva invalida claims y admisiones afectados |
| `planDigest` | `sha256:<hex>` del plan canónico. Un replay con el mismo digest devuelve el mismo recibo |
| `requestDigest` | `sha256:<hex>` del pedido original. Quitar un criterio exige una modificación de alcance autenticada y se registra |
| `units` | Lista de unidades del plan |
| `assumptions` | Lista de textos. Puede ir vacía |

Unidad del plan, dentro de `units[]`:

| Campo | Qué es |
|---|---|
| `unitId` | Único dentro del plan |
| `title` | Texto corto |
| `dependsOn` | Lista de `unitId` del mismo plan. Vacía para una unidad inicial |
| `criteria` | Lista no vacía de `{ "criterionId", "text", "verifier" }`. `verifier` es `"reviewer"`, `"verifier"`, `"ci"` o `"owner"` |
| `scope` | `{ "repos": [...], "mode": "design" \| "read" \| "implement" \| "publish" }`. Se intersecta con `authority` |

El validador rechaza, en este orden y con este código de regla: `schema`,
`id-duplicado`, `dependencia-faltante`, `ciclo`, `criterio-faltante`,
`campo-prohibido`. Esos son los casos de I02. Un plan que pasa conserva
alcance, supuestos y criterios tal como entraron. Eso es I01.

### Autoridad (`sistema-agentes.autoridad.v1`)

Qué puede hacer la raíz. Se intersecta con los permisos del host, del agente y
del CLI al arrancar, al reanudar y antes de cada efecto. Un prompt no la amplía.

| Campo | Qué es |
|---|---|
| `schema` | `sistema-agentes.autoridad.v1` |
| `authorityRef` | Identificador de la decisión que la concede. Para David, `P<n>` del historial de prompts, como en `proveedores-permitidos.json` |
| `grantedBy` | `"David"` u otro principal autenticado |
| `grantedAt` | Fecha |
| `actions` | Lista de `"read"`, `"implement"`, `"review"`, `"push"`, `"merge"`, `"deploy"`, `"send-mail"`, `"publish"`, `"create-repo"` |
| `repos` | Lista de repos permitidos, `owner/nombre` |
| `accounts` | Lista de referencias a cuentas (nombre, nunca credencial). Puede ir vacía |
| `destinations` | Lista de destinos de efecto permitidos. Puede ir vacía |
| `deadline` | Fecha o `null` |
| `mode` | `"design"`, `"read"`, `"implement"` o `"publish"` |

Un efecto es admisible si su `action` está en `actions`, su repo en `repos`,
su destino en `destinations` cuando el efecto tiene destino, y el `mode` de la
unidad no supera el de la autoridad (`design` < `read` < `implement` <
`publish`). El validador lo calcula con `efecto_admisible` y devuelve la
primera razón del rechazo, en este orden: `autoridad-vencida`,
`accion-fuera-de-autoridad`, `repo-fuera-de-autoridad`,
`destino-fuera-de-autoridad`, `modo-fuera-de-autoridad`. Una autoridad vencida
gana a cualquier otra razón porque ya no autoriza nada. Esos son los fixtures
de autoridad negativa de I07.

### Unidad (`sistema-agentes.unidad.v1`)

Un intento de una unidad del plan, ligado a una tarea nativa. Es el
`UnitBinding` del diseño.

| Campo | Qué es |
|---|---|
| `schema` | `sistema-agentes.unidad.v1` |
| `rootId`, `planRevision`, `unitId`, `attempt` | La clave única del binding. `attempt` es entero desde 1 |
| `taskId` | Tarea nativa que lo ejecuta, o `null` antes de admitir |
| `assignment` | `ManagedTaskAssignment` tal cual. El validador exige `target`, `instructionRef`, `resultContract` y `continuation`. Los demás campos de R (`inputRevision`, `progressBinding`) pasan sin revisarse: su dueño es R |
| `state` | `"pending"`, `"ready"`, `"admitted"`, `"running"`, `"reported"`, `"accepted"`, `"failed"` o `"cancelled"` |
| `controlEpoch` | Época con la que se admitió; antes de admitir, la época vigente de la raíz. Una admisión con época obsoleta no inicia |

Transiciones permitidas: `pending → ready` cuando todas las dependencias están
`accepted`. `ready → admitted → running → reported`. `reported → accepted`
solo con un claim `passed` por cada criterio de la unidad. `reported → failed`.
`running → failed` cuando el host cierra el intento sin resultado
(`launch-failed` o `session-closed`, las incidencias que B22 midió en
`B22-canarios.md`). Cualquier estado no terminal `→ cancelled`. Un estado
terminal no cambia. `transicion_permitida` en `contrato.py` codifica la tabla.
Las condiciones (dependencias aceptadas, un claim por criterio) las comprueba el
dueño nativo en SUA-01, no el validador de forma.

### Resultado (`sistema-agentes.resultado.v1`)

Lo que entrega un trabajador. No es evidencia. No es aceptación.

| Campo | Qué es |
|---|---|
| `schema` | `sistema-agentes.resultado.v1` |
| `rootId`, `unitId`, `attempt` | A qué intento pertenece |
| `resultContract` | `"review.v1"` o `"ready.v1"`, los dos que R acepta (`managed-task.json.ts:172-182`). Otro valor es `ROTO` hasta que un bloque lo agregue aquí y en R |
| `payload` | Para `review.v1`, `{ "verdict": "approved", "evidenceRef" }` o `{ "verdict": "changes", "findingsRef" }`. Para `ready.v1`, `{ "evidenceRef" }` (`managed-task.json.ts:100-104`) |
| `resultDigest` | `sha256:<hex>` del `payload` canónico |
| `reportedAt` | Fecha |
| `reportedBy` | `{ "kind": "native" \| "cli", "taskId" }` |

Reportado, consumido, recurso cerrado, unidad aceptada y meta cumplida son
hechos distintos. Este documento solo dice "reportado".

### Evidencia (`sistema-agentes.evidencia.v1`)

Un claim de un verificador sobre un criterio. Es el `EvidenceClaim` del diseño.

| Campo | Qué es |
|---|---|
| `schema` | `sistema-agentes.evidencia.v1` |
| `evidenceId` | Único dentro de la raíz |
| `rootId`, `unitId`, `criterionId`, `planRevision` | Qué criterio acredita y de qué revisión |
| `artifactRef` | Referencia con digest. Un SHA de git va como `{ "ref": "git:<sha40>", "digest": "sha256:..." }` del artefacto evaluado |
| `environment` | `{ "host": "<id>", "versions": { ... } }`. Las versiones son cadenas |
| `verifier` | `{ "principal": [...], "role": "reviewer" \| "verifier" \| "ci" \| "owner" }`. Tiene que coincidir con el `verifier` del criterio |
| `procedure` | Comando o procedimiento literal |
| `outcome` | `"passed"`, `"failed"` o `"unknown"` |
| `at` | Fecha |
| `expiresAt` | Fecha o `null`. Datos vivos tienen frescura propia |

Un claim con `outcome` distinto de `passed` no acepta nada. Un claim de otra
`planRevision` queda invalidado salvo justificación comprobable registrada en la
revisión.

### Control (`sistema-agentes.control.v1`)

Una orden sobre la raíz y su recibo.

Orden:

| Campo | Qué es |
|---|---|
| `schema` | `sistema-agentes.control.v1` |
| `rootId` | Raíz |
| `command` | `"pause"`, `"resume"` o `"cancel"` |
| `commandId` | Único por orden. Repetir la misma orden con el mismo `commandId` devuelve el recibo original |
| `expectedControlEpoch` | Época que el emisor vio. Si no coincide, conflicto |
| `reason` | Texto o `null` |
| `issuedAt` | Fecha |

Recibo, en `receipt`. Una orden sin `receipt` es una orden emitida. Con
`receipt` es la respuesta del dueño nativo. El validador acepta las dos formas:

| Campo | Qué es |
|---|---|
| `controlEpoch` | Época después de la orden |
| `state` | `"active"`, `"paused"` o `"cancelled"` |
| `replayed` | `true` solo cuando el recibo es el original de un reintento exacto |
| `committedEffects` | Lista de `{ "effectId", "destination", "state": "started" \| "uncertain", "cancellable": true \| false }`. Son los efectos que ya tenían permiso de inicio cuando ganó la pausa. El panel no los muestra detenidos |

`cancel` es terminal. `resume` conserva raíz, reservas, contadores e historia.
`pause` sobre una raíz `cancelled` es conflicto.

### Flota (`sistema-agentes.flota.v1`)

Una asignación de trabajador a un intento. Es el `Assignment` del diseño.
Consumidor: SUA-03 y SUA-04. SUA-00 fija solo los campos mínimos.

| Campo | Qué es |
|---|---|
| `schema` | `sistema-agentes.flota.v1` |
| `rootId`, `unitId`, `attempt` | A qué intento |
| `specialist` | Perfil de especialidad, por ejemplo `"ingenieria"` o `"meli"` |
| `host` | `"mac-local"`, `"mini-native"` u otro `hostId` inventariado |
| `executor` | `"native"`, `"cli"` u `"opencode"` |
| `accountRef` | Nombre de la cuenta, nunca credencial. `null` si no aplica |
| `model` | `{ "id": "<proveedor/modelo exacto>" }` o `{ "id": null, "reason": "<por qué es desconocido>" }`. Un lanzador opaco no miente sobre el modelo |
| `generation` | Entero desde 1. Generación de flota vigente al asignar |
| `permissions` | Lista de permisos efectivos medidos. Vacía significa "no medido", no "ninguno" |
| `attestations` | Lista de `{ "what": "poteto" \| "profile" \| "tools", "digest": "sha256:..." }`. Un hash identifica contenido, no prueba que el modelo lo usó |

### Excepción (`sistema-agentes.excepcion.v1`)

Una pregunta tipada al propietario. Conserva las once clases heredadas y agrega
dos.

| Campo | Qué es |
|---|---|
| `schema` | `sistema-agentes.excepcion.v1` |
| `exceptionId` | Estable. Un reaviso usa el mismo id |
| `rootId`, `unitId` | A qué pertenece. `unitId` puede ser `null` |
| `type` | Uno de `SIN_REVISOR`, `SIN_CUOTA`, `AUTH_VENCIDA`, `CI_ROJO`, `BOT_CALLADO`, `CONFIRMAR_PLAN`, `NECESITA_DAVID`, `BLOQUEANTE_REPETIDO`, `DEPLOY_FALLO`, `CIERRE_ROJO`, `INESPERADO`, `EVIDENCIA_INCIERTA`, `CAPACIDAD_INCIERTA` |
| `options` | Lista no vacía de `{ "optionId", "text" }`. Solo esas opciones son válidas |
| `evidenceRef` | Referencia con digest, o `null` |
| `recipient` | `{ "channel": "telegram", "principal": [...] }`. El canal se lee de la configuración, nunca del repo |
| `raisedAt` | Fecha |
| `renoticeAfterMs` | Entero. Mínimo `3600000`, una hora |
| `response` | `null` o `{ "optionId", "by": [...], "at" }`. Una respuesta no se aplica a otra excepción. Su `optionId` es uno de los de `options`; si no, el validador contesta `opcion-no-ofrecida` |

### Proyección (`sistema-agentes.proyeccion.v1`)

La vista redactada que leen panel y avisos. Es derivada. Nunca ordena trabajo.
Consumidor: SUA-06. Campos mínimos.

| Campo | Qué es |
|---|---|
| `schema` | `sistema-agentes.proyeccion.v1` |
| `rootId`, `planRevision`, `controlEpoch` | De qué estado sale |
| `generatedAt` | Fecha |
| `progress` | `{ "declared", "observed", "accepted" }`, cada uno entero 0 a 100 o `null` cuando no hay criterios válidos |
| `units` | Lista de `{ "unitId", "state", "host", "executor", "modelId", "nextCheckAt", "error" }`. `modelId` y `error` pueden ser `null` |
| `freshness` | `{ "staleAfterMs": <int> }` |

`accepted` vale 100 solo con aceptación integrada vigente. Un proceso vivo,
`LISTO`, un merge, un rollback o borrar una unidad no lo producen. La
proyección excluye secretos, prompts, argv y transcripciones. Un campo que no
está en esta tabla no entra.

## Compatibilidad de versiones

- El literal `schema` lleva la versión mayor. `v1` es esta.
- Agregar un campo opcional no cambia la versión. Un consumidor ignora campos
  que no conoce y los conserva al reescribir.
- Quitar un campo, renombrarlo, cambiar su tipo o su significado, o agregar un
  valor a un enum que un consumidor viejo rechaza, sube la versión mayor.
- Un productor escribe la versión más nueva que conoce. Un consumidor acepta la
  versión vigente y la anterior, como hace `validar_registro` con `corrida.v1`
  y `corrida.v2` (`docs/spec/corrida.v2.md`). Una versión más vieja que la
  anterior o más nueva que la vigente es `ROTO` con su motivo.
- Una raíz conserva la versión con la que se abrió. Una promoción de software
  no reescribe raíces abiertas sin migración con reversa.
- Los fixtures de cada versión se conservan mientras un consumidor la acepte.

## Productores y consumidores a migrar

Lo que hoy produce o consume una forma que este contrato reemplaza o envuelve.
La columna "bloque" dice quién lo migra. Nada de esto cambia en SUA-00.

| Hoy | Forma actual | Pasa a | Bloque |
|---|---|---|---|
| `managed_tasks_submit` y `managedTasks.host.*` (R) | `ManagedTaskAssignment`, `review.v1`, `ready.v1` | `unidad.assignment` y `resultado.payload` los envuelven sin cambiarlos | SUA-01 |
| `managed_tasks_resolve` con `ManagedTaskHandlingDecision` | `continue`, `complete`, `blocked`, `cancelled` por tarea | Decisión del controlador sobre la raíz, con `plan` y `control` | SUA-01, SUA-02 |
| `corrida_worker/reconcile.py`, `task_handoffs.py` (G) | Decisión Python por SHA y `resolve_via_gateway` | Retirado el 2026-10-13, no se migra. No queda un decisor Python activo | SUA-02 |
| `corrida_worker/gates.py` | Compuertas `cross-review`, `mismo-revisor`, `bloqueante-repetido` | Retirado el 2026-10-13, no se migra. La política de rondas como datos se escribe nueva | SUA-05 |
| `autoridad-merge.sh`, `preaprobaciones.v1.json` | Tabla de preaprobaciones por corrida | Retirados el 2026-10-13, no se migran. `autoridad` va embebida en `meta` | SUA-05 |
| `LISTO <sha>` y `VEREDICTO` en ventanas tmux | Texto en el pane | `resultado` con `resultContract` y `evidencia` del head exacto | SUA-03 |
| `corrida.v2` (`corrida.sh`) | Registro por corrida con `lanes`, `effects`, `evidence`, `outcome` | Retirado el 2026-10-13, no se migra. `corrida.v2` queda como lectura histórica | SUA-03, SUA-09O |
| `runbook-progress.v2`, `progress_bridge.py`, `ProgressPublisher` | Documento de progreso por fase | `proyeccion` derivada del dueño nativo. Un emisor por host | SUA-06 |
| `ManagedTaskHostIncident`, `ManagedTaskIncident` (R), `record_incident` y `flush_incidents` (G) | Cuatro tipos de incidencia de host más `recovery-transport-failure` | `excepcion` con tipo, opciones y respuesta. Las incidencias de host siguen existiendo como hecho del host | SUA-02 |
| `workers.v1.json`, `registry.py`, `selector.py` | Registro y selección de trabajadores CLI | Retirados el 2026-10-13, no se migran. `flota` lleva modelo exacto o desconocido y generación | SUA-03, SUA-04 |
| `proveedores-permitidos.json`, `encargo.py` | Política de proveedores con la frase de David | Se conserva tal cual. `flota.accountRef` y `authority.accounts` la citan | SUA-04 |
| `coverage.json` (`hostAdapterRoute`, `hostAdapterCoverage`) | Certificación de rutas | Fuente de `flota.host` y `flota.executor` admisibles, después de alinearlo consigo mismo | SUA-04 |
| Hermes | Sin inventario | Implementa los mismos esquemas con su mecanismo local | SUA-07 |

## Qué no fija este contrato

- El mecanismo de almacenamiento de cada host. R lo hace en SQLite con sus
  tablas `managed_task_*`. Hermes decide el suyo.
- El transporte de los avisos. Se lee de la configuración del host.
- La política de rondas. Rige la regla 4 de quality-kit con el tope 5+5 de David
  (2026-10-12). `qualityPolicy.version` solo la nombra.
- El catálogo de modelos. Sale de `opencode models` y de
  `proveedores-permitidos.json`, no de una lista en este contrato.
