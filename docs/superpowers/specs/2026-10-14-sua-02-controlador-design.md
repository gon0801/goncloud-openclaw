# SUA-02, controlador y autoridad: diseño y corte en rebanadas

Fecha: 2026-10-14. Estado: diseño propuesto, sin código. Lo escribió el diseñador del bloque. Lo revisa el revisor asignado antes de implementar.

Bases leídas: G `origin/main` `8dfaaeb1`, en el worktree `~/dev/wt/sua-02-diseno` (rama `sua/02-diseno`). R `/Users/dn/dev/openclaw-agent-work-integration`, rama `feat/agent-work-integration`, HEAD `65432d099d07`, el que corre en la Mini desde la segunda instalación de SUA-01. Ningún comando de este documento se corrió contra la Mac mini. No se corrió ninguna prueba de R: lo que dice de R sale de leer el código. La única medición viva que usa es M-11, que corrió el coordinador.

Documentos que manda este diseño y que no cambia:
- El bloque "SUA-02" del [plan](../plans/2026-10-05-sistema-agentes-unificado.md), con "Orden y dependencias", "Ensayos integrados" y "Regla de instalación en vivo".
- El [contrato](../../spec/sistema-agentes.v1.md) `sistema-agentes.v1`, en especial "Excepción".
- El [diseño de SUA-01](2026-10-13-sua-01-frontera-durable-design.md), sección 4.7 "Lo que SUA-02 va a llamar", y su [recibo](../../evidence/sistema-agentes-unificado/SUA-01.md).
- El [diseño del sistema](2026-10-05-sistema-agentes-unificado-design.md), "Interfaz propuesta" y "Autoridad y calidad".

Palabras que este documento usa con un solo sentido. Las de SUA-01 (raíz, unidad, intento, época, efecto, solicitante) siguen igual.

| Palabra | Sentido |
|---|---|
| controlador | El código de R que lee una raíz, decide y hace commit (`reconcileManagedRoot`), más la sesión de `main` que lo invoca cuando R la despierta. |
| `decide` | La función pura del controlador. Recibe la foto de la raíz, los hechos verificados y la política, y devuelve una propuesta. No lee ni escribe nada. |
| hecho verificado | Algo que el modelo de `main` aporta en una llamada y que R tipa y sella: una asignación para una unidad lista, un claim de verificador, un efecto que hay que preparar. |
| propuesta | Lo que devuelve `decide`: una decisión para `commitManagedRootDecision`, las excepciones nuevas, lo que falta que aporte el modelo y lo que hay que avisar. |
| excepción | Una pregunta tipada al dueño de la raíz (`sistema-agentes.excepcion.v1`). |
| dueño | El dueño de la raíz de SUA-01: `principal`, `agentId` y `sessionKey`. Para una raíz abierta por David en Telegram, `principal` es `["sender","telegram",<cuenta>,<id>]`. |
| autoridad vigente | La autoridad de la raíz después de su última restricción. |
| concesión de efecto | La respuesta `autorizar` del dueño a una excepción sobre un efecto concreto. Autoriza ese `effectId` y nada más. |
| sombra | Calcular con `decide` lo que el controlador haría con un encargo suelto de `main`, sin escribir nada en R y sin despachar. |

## 1. Lo que existe hoy

### La frontera de SUA-01, sin nadie que la llame

- `managed-root.store.ts` exporta las ocho órdenes de la raíz (`openManagedRoot` `:75`, `commitManagedRootDecision` `:97`, `controlManagedRoot` `:126`, `reviseManagedRootPlan` `:148`, `recoverManagedRootRequester` `:170`, `startManagedRootEffect` `:204`, `settleManagedRootEffect` `:222`, `readManagedRoot` `:240`). Un conflicto es una respuesta, no una excepción (`RootResult`, `managed-root.types.ts:168-170`).
- Fuera de las pruebas, el único que llama alguna es el gateway: `managedTasks.root.read` (`src/gateway/server-methods/managed-tasks.ts:197`) y `managedTasks.root.control` (`:221`), los dos del operador. `git grep -n "openManagedRoot\|commitManagedRootDecision\|recoverManagedRootRequester" -- 'src/**/*.ts' ':!*.test.ts'` solo encuentra las definiciones.
- `managedRootGatewaySlots` (`managed-root.limits.ts:11`) tampoco tiene llamador. Contesta `managedTasks.capacity` o 4. El comentario de `:4-6` lo dice: "The operator has not decided the number yet".
- El commit sí comprueba el cupo del gateway (`managed-root.commit.worker.ts:275-280`). El comentario de `managedRoots.commit` dice lo contrario, "It travels with the decision; no check reads it yet" (`managed-root.types.ts:390`): quedó de la rebanada 6. La R2 lo corrige.

### Las herramientas del solicitante son solo de tareas sueltas

`createManagedTaskTools` (`src/agents/tools/managed-tasks-tool.ts:65`) da seis herramientas: `managed_tasks_submit`, `_admit`, `_resolve`, `_cancel`, `_inspect` y `_artifact_read`. Las registra `resolveManagedRequesterTools` (`src/agents/openclaw-tools.managed-tools.ts:37-78`) para los agentes de `managedTasks.requesters`, si la corrida tiene `managedTaskHost`. Ninguna herramienta toca una raíz.

`managedTaskHost` lo recibe toda corrida embebida cuando `managedTasks.enabled` está puesto (`resolveManagedTaskHostCapability`, `src/agents/tasks/managed-task.host.ts:8`; `run-attempt-dispatch.ts:424`). `resolveManagedRequesterTools` no mira si la sesión es de un hijo. `isSubagentSessionKey` existe (`src/sessions/session-key-utils.ts:83`) y nadie lo usa ahí.

### El despertar ya existe y apunta a una herramienta que falta

Para una tarea de raíz, R ya encola el despertar del solicitante, a la instancia vigente y con `requesterIdentity` (`prepareManagedTaskResultDelivery` y `prepareManagedTaskIncidentDelivery`, `src/agents/tasks/managed-task.delivery.ts:59-110`). El texto dice "Read the root and commit the next decision" (`:79` y `:106`). El modelo no tiene con qué leer la raíz ni con qué hacer commit.

### La cola de sesión sabe esperar

Una entrega de la cola de sesión tiene `availableAt` (`src/infra/session-delivery-queue.records.ts:108`). El runtime la arma con ese retraso (`resolveRetryDelayMs`, `src/infra/session-delivery-queue-runtime.ts:63-73`) y la recuperación tras un reinicio la respeta (`isDeliveryRecoveryRetryEligible`, `src/infra/delivery-recovery.shared.ts:80-86`). Existe la orden `sessionDelivery.defer` (`src/infra/session-delivery-queue.worker.ts:103-110`). Nadie la usa hoy para una tarea gestionada.

### Lo que la foto de una raíz no trae

`RootSnapshot` (`managed-root.types.ts:344-363`) trae la meta, los intentos, las unidades sin intento, la evidencia, los efectos, el presupuesto, los resultados sin consumir, los contadores y los escritores. No trae las incidencias de sus tareas ni ninguna excepción, porque no hay dónde guardarla.

### La autoridad es inmutable y se lee en cuatro sitios

`managed_roots.authority_json` se escribe una vez al abrir (`managed-root.worker.ts:155`). Se lee con `JSON.parse` en `claim` (`managed-root.admission.worker.ts:67`), al iniciar un efecto (`managed-root.effect.worker.ts:125`), al revisar el plan (`managed-root.plan.worker.ts:130`) y en la foto (`managed-root.worker.ts:262`). No hay forma de restringirla ni de conceder un efecto que no cubre.

### El turno y la identidad

`captureManagedTaskTurn` (`src/agents/tasks/managed-task.turn.ts:22-68`) arma el llamador desde el turno admitido, nunca desde argumentos del modelo. Con remitente, `principal` es `["sender", canal, cuenta, id]`. Sin remitente es `["agent", agentId]`. Un cron aislado no pasa (`:42-44`). `openManagedRoot` rechaza a un trabajador gestionado (`managed-root.worker.ts:94-103`), no a un hijo nativo de `main`.

### Incidencias del host

R tiene cuatro clases de incidencia de host (`ManagedTaskHostIncident`, `managed-task.types.ts:121-125`) y una nativa (`recovery-transport-failure`, `:127-129`). El host de G usa `transport-unavailable` con episodios propios: `launch-refused` y `launch-failed` (`scripts/agent-work/host.py:26-29`), `session-closed`, `delivery-unaccepted` y los de `SILENT_EPISODES` (`:22-25`).

### Las once clases de excepción solo existen en papel

El contrato enumera trece tipos (`docs/spec/sistema-agentes.v1.md`, "Excepción") y `contrato.py` los valida (`_EXCEPCION`, `scripts/sistema_agentes/contrato.py:375-402`). Las opciones de cada clase y el reaviso de 3600 s vienen del director de corrida retirado (`docs/superpowers/specs/2026-09-29-director-corrida-transiciones.md`, "Excepciones tipadas", `:168-213`). Su tratamiento nuevo está en `cobertura.md`, "Excepciones heredadas" (`:127-145`). Ningún código de R ni de G vivo las produce.

### Quién decide hoy

`main` decide cada encargo suelto con `managed_tasks_resolve` o `managed_tasks_cancel`, siguiendo la skill `encargo-cli` ("Cuando R te despierte", `agents/main/agent/workshop-skills/encargo-cli/SKILL.md:46`). Después le cuenta a David el resultado por Telegram (`B22-canarios.md:220`).

### Lo que dicen las mediciones

- M-01: un despertar por evento con `main` libre empieza en 2,3 s y cuesta unos 20 500 tokens.
- M-02 y M-11: un `system event --mode now` espera detrás de un turno de `main` en vuelo, sea a otra sesión de `main` (M-02) o a una sesión de `ingenieria` (M-11, tres de tres, 39,1 a 40,7 s). Por el criterio del plan, **el controlador vive en `main`**. Las tres muestras están en `SUA-00-mediciones.md`, "Mediciones vivas del 2026-10-14 (SUA-02)".
- M-04: un despertar que llama una herramienta y contesta `NO_REPLY` cuesta 41 408 tokens.

## 2. Lo que falta, punto por punto contra el bloque

| Pide el bloque | Hoy | Lo que falta | Dónde |
|---|---|---|---|
| Paso 1. `open/control/reconcile/read` con funciones puras de meta, ingeniería y flota | `open`, `control` y `read` existen en R desde SUA-01. No hay `reconcile` ni `decide`. | `decide` puro y `reconcileManagedRoot`, que lee, decide, hace commit y admite. Las herramientas que el modelo llama. | 4.2, 4.3, 4.8 |
| Paso 1. Importar Plans o pedido natural sin perder criterios | El plan llega tipado a `openManagedRoot`. Nada lo redacta. | Un importador de filas de `Plans.md` en G. Para un pedido natural, `main` redacta y R comprueba que cada frase del pedido quedó cubierta. | 4.7 |
| Paso 2. Solicitante durable, identidad autenticada, autoridad heredada | El dueño y su recuperación existen. La autoridad la escribe quien llama. | R sella `grantedBy` y `grantedAt` desde el turno, y solo abre desde un turno con remitente. Una restricción de autoridad. Una concesión de efecto por respuesta del dueño. | 4.6 |
| Paso 2. Una sesión nueva no toma una raíz por su ID | Cubierto por SUA-01 (`managedRootStanding`, `managed-root.worker.ts:250-255`). | Nada en R. Una prueba de herramienta. | 5 |
| Paso 2. Un hijo no crea otra raíz | Cubierto para el trabajador gestionado. No para un hijo nativo de `main`. | Las herramientas de raíz no existen en una sesión de hijo. | 4.6 |
| Paso 3. Seleccionar unidades aceptables, seguir ramas independientes, reparar dentro del alcance, invalidar solo evidencia afectada | Lo mecánico existe en el commit y en la revisión de plan. | Las reglas de `decide`. | 4.3 |
| Paso 4. Once clases más las de evidencia y capacidad inciertas, como enum, con IDs, opciones, entrega, respuesta única y reaviso | Solo el contrato. | Un registro de las trece clases, una tabla de excepciones, una orden para responder y el reaviso. | 4.5 |
| Paso 5. Enganche a eventos y sombra sin despachar | Los eventos existen. No hay sombra. | Las herramientas responden a los despertares de raíz. La sombra se calcula fuera de línea sobre los encargos sueltos. | 4.4, 4.9 |
| Despertar | Decidido por el plan: el evento de R, sin `agent --message` ni cron. | Nada. M-11 deja el controlador en `main`. | 4.4 |
| M-12 | Pendiente | No hace falta. | 4.4 |
| Canal de avisos | Telegram, por la sesión de `main` con David. | Las excepciones salen por esa misma sesión. | 4.5 |
| Residuales de SUA-01 | Siete, en `followups.md`. | Decisión por cada uno. | 4.10 |

## 3. Dos formas de modelar el controlador, comparadas

Las dos parten de lo mismo: el despertar llega a la sesión de `main` que abrió la raíz, y R guarda todo. Difieren en quién arma la decisión.

### Forma A: R decide, el modelo aporta hechos

Una herramienta de R, `managed_roots_reconcile`, lee la raíz, llama `decide`, hace commit y admite los intentos nuevos, todo en el proceso del gateway. El modelo aporta solo lo que R no puede saber: la asignación de una unidad lista (el brief y el destino), los claims de lo que comprobó y los efectos que el pedido necesita. R tipa esos hechos y sella su autor. El resto lo decide código puro.

### Forma B: el modelo decide, R valida

Las herramientas son envolturas finas de las ocho órdenes. La skill de `main` explica cómo leer la foto y cómo escribir `RootDecision`. R valida en el commit lo que ya valida: dependencias, cupo, época, claims por criterio.

### Comparación

| Criterio | A, R decide | B, el modelo decide |
|---|---|---|
| **Qué queda fuera de política** | La política está en una función pura con pruebas literales. El modelo no puede saltarse una regla de `decide`, solo dejar de aportar un hecho. | El commit impide estados ilegales, no decisiones malas. Reintentar sin límite, aceptar sin verificar un criterio de rol `verifier` con un claim inventado o ignorar una incidencia son decisiones válidas para el commit. |
| **Coste por despertar** | Una llamada (`managed_roots_reconcile`) y la respuesta. M-04 midió 41 408 tokens para un despertar con una herramienta. | Al menos tres llamadas (leer, commit, admitir), con la foto entera en el contexto. No medido. |
| **Copias** | La foto no pasa por el modelo. | El modelo copia `resultDigest`, épocas y revisiones a mano. El hueco B12 de encargos fue un campo copiado como `***`. |
| **El diseño del sistema** | Cumple "Los llamadores no encadenan por su cuenta reserva, spawn, registro y aceptación" ("Interfaz propuesta") y "En OpenClaw se implementan decisiones y transacciones en R" ("Módulos y propiedad"). | Contradice las dos frases. |
| **Cómo se prueba** | `decide` con tablas literales en vitest. El ciclo completo con el arnés de G y su proveedor de guion. | La conducta depende del modelo. Solo un e2e con modelo real la prueba, y una sola corrida no prueba la siguiente. |
| **Coste propio** | Más código en R: `decide`, el controlador y seis herramientas. | Menos código en R. Una skill larga. |
| **Corte de SUA-09O** | Pasar `resolve` de `main` al controlador es cambiar de herramienta. | Igual, pero la política vive en una skill. |

### Elección

Se elige **A**. La razón que decide es la primera fila: con B, nada en R impide una decisión que la política prohíbe, y la política es justo lo que este bloque escribe. La tercera razón es de diseño del sistema, que ya pide A.

De B se toma una cosa: `managed_roots_reconcile` acepta `commit: false`. Con eso el modelo lee la foto y la propuesta sin escribir nada, que es la lectura que B daba.

Los dos bocetos son del diseñador. No se pidieron bocetos a otros modelos.

## 4. El diseño elegido

Una frase lo resume. `main` sigue siendo el que recibe a David y el que despierta, y R hace lo demás: guarda, decide con una función pura, hace commit, admite y recuerda las preguntas abiertas.

### 4.1 Dónde vive cada pieza

| Pieza | Repo y archivo | Por qué ahí |
|---|---|---|
| `decide` y la política de rondas | R, `src/agents/tasks/managed-root.decide.ts`, pura | Es la decisión. El diseño del sistema la pone en R. |
| Registro de las trece clases de excepción | R, `managed-root.exceptions.ts`, datos. G, `scripts/tests/fixtures/sistema-agentes/excepcion/clases.json`, la misma tabla | R la usa. G la fija como fixture del contrato, como `unidad/transiciones.json`. |
| Excepciones, autoridad vigente y sus órdenes | R, `managed-root.exception.worker.ts`, `managed-root.authority.ts` | Son transacciones de la misma base. |
| El controlador | R, `managed-root.controller.ts`, proceso principal | Encadena leer, decidir, commit y admitir. Es la única pieza con efectos. |
| Las herramientas | R, `src/agents/tools/managed-roots-tool.ts` | El modelo solo ve herramientas. |
| La skill de `main` | G, `agents/main/agent/workshop-skills/raiz/SKILL.md` | Dice cuándo abrir una raíz, cómo redactar el plan, qué hacer al despertar, cómo avisar a David y cómo leer su respuesta. |
| Importador de `Plans.md` | G, `scripts/sistema_agentes/importar_plans.py`, puro | `Plans.md` vive en los repos de la Mac. Lo corre `main` con `exec`, como `encargo.py`. |
| Redactar la asignación de una unidad | G, la ruta de hoy: `encargo.py preparar` y `brief.py` | No cambia. La asignación entra como hecho. SUA-03 la automatiza. |
| Sombra | G, `scripts/sistema_agentes/sombra.mjs`, que importa `decide` de R con `tsx` | No toca la ruta viva. |
| Host de encargos | G, `host.py`, sin cambios | Sus incidencias llegan a R como hoy. La traducción a excepción la hace `decide`. |

**Quién recibe el pedido.** `main`, como hoy. Es el único solicitante de `managedTasks` y M-11 lo deja como sede del controlador.

**Quién redacta el plan desde lenguaje natural.** `main`, que es un trabajador con modelo y es quien leyó el pedido. R lo valida al abrir con `validateRootPlan` (SUA-01) y con la cobertura del pedido (4.7). La alternativa, un encargo previo que redacta el plan, cuesta un encargo más por pedido y no da una validación mejor: el plan que devuelva pasa por las mismas dos comprobaciones.

### 4.2 Tipos

```ts
// managed-root.exceptions.ts
export const ROOT_EXCEPTION_TYPES = [
  "SIN_REVISOR", "SIN_CUOTA", "AUTH_VENCIDA", "CI_ROJO", "BOT_CALLADO", "CONFIRMAR_PLAN",
  "NECESITA_DAVID", "BLOQUEANTE_REPETIDO", "DEPLOY_FALLO", "CIERRE_ROJO", "INESPERADO",
  "EVIDENCIA_INCIERTA", "CAPACIDAD_INCIERTA",
] as const;
export type RootExceptionType = (typeof ROOT_EXCEPTION_TYPES)[number];

export type RootExceptionOption =
  | "seguir" | "relevo" | "cancelar" | "listo" | "omitir" | "si"
  | "autorizar" | "aceptar" | "rechazar" | "conciliar";

/** Una fila por clase. La misma tabla es `excepcion/clases.json` en G. */
export const ROOT_EXCEPTION_CLASSES: Record<RootExceptionType, {
  options: readonly RootExceptionOption[]; // vocabulario de la clase
}>;

export type ExceptionId = Brand<string, "ExceptionId">;

/** Lo que `decide` levanta. El id sale del hecho: el mismo hecho da el mismo id. */
export type ExceptionDraft = {
  exceptionId: ExceptionId;               // sha256([rootId, type, subject])
  type: RootExceptionType;
  subject:
    | { kind: "attempt"; unitId: UnitId; attempt: number; cause: string }
    | { kind: "effect"; effectId: EffectId }
    | { kind: "unit"; unitId: UnitId; cause: string }
    | { kind: "root"; cause: string };
  options: RootExceptionOption[];          // subconjunto del vocabulario de la clase
  evidenceRef: { ref: string; digest: string } | null;
};

export type RootException = ExceptionDraft & {
  raisedAt: number;
  noticedAt: number | null;
  notices: number;
  renoticeAfterMs: number;                 // >= 3_600_000
  response: { optionId: RootExceptionOption; by: string[]; at: number } | null;
  appliedBy: OperationId | null;           // el commit que aplicó la respuesta
};
```

```ts
// managed-root.decide.ts
export type QualityPolicy = {
  version: "quality-kit.regla4";
  roundsPerImplementer: 5;                 // David, 2026-10-12
  relays: 1;                               // un relevo con otras 5
};

/** Lo que el modelo aporta en una llamada. R sella el principal; el modelo no lo escribe. */
export type VerifiedFacts = {
  assignments: Array<{ unitId: UnitId; assignment: ManagedTaskAssignment; relay: boolean }>;
  claims: Array<Omit<EvidenceClaimInput, "verifier" | "evidenceId"> & { role: "verifier" | "ci" }>;
  effects: EffectIntent[];
};

export type ControllerView = RootSnapshot & {
  incidents: Array<{ unitId: UnitId; attempt: number; taskId: string; incidentKey: string; incident: ManagedTaskIncident }>;
  exceptions: RootException[];
  authority: { revision: number; authority: RootAuthority };
};

export type ControllerNeed =
  | { kind: "assignment"; unitId: UnitId; reason: "first" | "correction" | "relay"; findingsRef: string | null }
  | { kind: "verify"; unitId: UnitId; attempt: number; criteria: string[] };

export type ControllerProposal = {
  decision: Omit<RootDecision, "rootId" | "decisionId" | "expectedPlanRevision" | "expectedControlEpoch"> & {
    exceptions: ExceptionDraft[];
    appliedAnswers: ExceptionId[];
  };
  needs: ControllerNeed[];
  notify: ExceptionId[];                   // excepciones a avisar o reavisar ahora
  state: "working" | "waiting" | "done" | "stopped";
};

export function decideRoot(view: ControllerView, facts: VerifiedFacts, policy: QualityPolicy, nowMs: number): ControllerProposal;

/** La misma regla sobre un encargo suelto, para la sombra (4.9). */
export function decideLooseTask(facts: LooseTaskFacts): LooseShadowProposal;
```

`decideRoot` es total: devuelve una propuesta para cualquier foto. Una propuesta con todas las listas vacías no produce commit.

`RootConflict` gana ocho variantes: `effect-unknown`, `exception-unknown`, `exception-answered`, `option-not-offered`, `not-recipient`, `authority-widens`, `coverage-incomplete` y `quality-policy-unknown`. `RootDecision` gana `exceptions` y `appliedAnswers`. Las dos son listas nuevas de un commit que sigue siendo una transacción.

### 4.3 Las reglas de `decide`

`decide` recorre la foto en este orden fijo. Cada paso ve lo que los anteriores ya decidieron en la misma propuesta, como el commit de SUA-01 ve sus `outcomes` antes que sus `bindings`.

1. **Control.** Con la raíz `paused` o `cancelled`, la propuesta no trae decisión. Solo trae `notify` del paso 8. Una respuesta del dueño se guarda igual (4.5) y se aplica tras `resume`.
2. **Respuestas.** Cada excepción con respuesta y sin `appliedBy` se aplica según la tabla de 4.5, sobre su propio sujeto y nada más. Su id entra en `appliedAnswers`.
3. **Resultados.** Cada resultado pendiente se consume. Si su intento ya terminó, solo se consume. Si no:
   - Un `review.v1` con `verdict: "changes"` termina el intento en `failed` y pasa al paso 6.
   - Si no, se miran los criterios de la unidad. Un criterio con claim `passed` vigente de ese intento está cumplido. Uno de rol `owner` sin claim levanta `NECESITA_DAVID` con `aceptar` y `rechazar`. Uno de rol `verifier` o `ci` sin claim pide `verify` al modelo. Un claim `failed` termina el intento en `failed`. Un claim `unknown` levanta `EVIDENCIA_INCIERTA`.
   - Con todos cumplidos, el intento termina en `accepted`.
4. **Incidencias.** Una incidencia de un intento vivo se traduce con la tabla siguiente. "Reintento" quiere decir: el intento termina en `failed` (en `cancelled` si nunca se lanzó, porque el contrato no tiene `admitted → failed`), y se liga el siguiente con la misma asignación, que `decide` toma de la foto. Hay un reintento automático por unidad, contado en `reintentos:<unitId>`. Agotado, se levanta la excepción.

   | Incidencia | Qué hace |
   |---|---|
   | `transport-unavailable` con `launch-failed`, `session-closed` o `delivery-unaccepted`; `deadline-missed`; `invalid-result`; `recovery-transport-failure` | Reintento. Después, `INESPERADO` |
   | `transport-unavailable` con `launch-refused` | `CAPACIDAD_INCIERTA`, sin reintento: el host ya dijo que no lanza |
   | `permission-required` | `NECESITA_DAVID`, sin reintento |
   | Cualquier otro `episodeId` | `INESPERADO`, sin reintento |

5. **Efectos.** Un efecto `uncertain` levanta `EVIDENCIA_INCIERTA`. Un efecto `prepared` que la autoridad vigente no cubre y que no tiene concesión levanta `NECESITA_DAVID` con `autorizar`, `listo`, `omitir` y `cancelar`. Los efectos nuevos de los hechos se preparan siempre: así la excepción tiene un `effectId` real al que referirse. `decide` nunca prepara otra vez un `effectId` que ya está en la foto.
6. **Correcciones.** Una unidad no aceptada cuyo último intento terminó en `failed` por su resultado (paso 3, no por una incidencia del paso 4) necesita otro intento. El contador `rondas:<unitId>` cuenta las correcciones de la unidad y no se reinicia con hallazgos nuevos, con una revisión que no cambie la huella de la unidad ni con un relevo. Con el contador por debajo de `roundsPerImplementer`, se pide una asignación de corrección. Al llegar, se pide una con `relay: true`. Al llegar a `roundsPerImplementer × (1 + relays)`, se levanta `NECESITA_DAVID` con `seguir`, `omitir` y `cancelar`, y no se liga nada más. El contador sube en el mismo commit que liga la corrección.
7. **Unidades listas.** Cada unidad sin intento cuyas dependencias están aceptadas recibe una ligadura si el modelo trajo su asignación. Si no, se pide. Una excepción sobre una unidad no frena a otra que no depende de ella.
8. **Avisos.** Cada excepción abierta sin aviso, o con `now >= noticedAt + renoticeAfterMs`, entra en `notify`.
9. **Cierre.** Con todas las unidades del plan vigente aceptadas, `state` es `done`. Con todas terminadas y alguna sin aceptar, se levanta `CIERRE_ROJO`.

Lo que `decide` no hace: no pregunta por tamaño. Una raíz de doce unidades dentro de su autoridad no levanta ninguna excepción. Tampoco elige modelo ni especialista: eso llega como asignación y es de SUA-03.

**El controlador.** `reconcileManagedRoot(input, turn, deps)` hace, en el proceso principal:

1. Si los hechos traen una revisión de plan, llama `reviseManagedRootPlan`.
2. Lee la foto ampliada (4.8) y llama `decideRoot`.
3. Con `commit: true` y una decisión no vacía, llama `commitManagedRootDecision`. Si contesta `stale-control-epoch` o `stale-plan-revision`, vuelve a leer y a decidir una vez. Un segundo conflicto se devuelve al modelo. No hay bucle.
4. Si el commit no cabe por cupo (`capacity`), lo repite sin `bindings`. Esperar plaza no es una excepción.
5. Admite cada intento creado por el camino de hoy, con `root: { expectedControlEpoch, expectedPlanRevision }` y `admissionKey` `<taskId>-e<época>`. Un destino CLI pasa por `reserveManagedAdmissionBudget` y `claimManagedTaskAdmission`. Un destino agente, por `createManagedSpawnAdmission` y `spawnSubagentDirect`, como `managed_tasks_admit` (`managed-tasks-tool.ts:116-220`). Ese cuerpo se extrae a una función que usan las dos herramientas (rebanada 1).
6. Marca como avisadas las excepciones de `notify` y encola el siguiente reaviso (4.4).
7. Devuelve al modelo `needs`, las excepciones a avisar con su texto y opciones, los intentos admitidos y `state`.

### 4.4 El despertar y el reloj

**El despertar.** No cambia. R despierta a la sesión del dueño con el evento de sistema que ya emite para un resultado o una incidencia de una tarea de raíz (`managed-task.delivery.ts:59-110`). SUA-02 cambia solo el texto de las dos ramas de raíz para que nombre la herramienta: "Managed root `<rootId>` has a result for unit `<unitId>` attempt `<n>`. Call managed_roots_reconcile with this rootId." Las ramas de tarea suelta no cambian.

Dos despertares nuevos, los dos del mismo tipo `systemEvent`, con `requesterIdentity`:
- **Tras un `resume` o una restricción del operador.** Sin él, nadie reconcilia una raíz que el operador reanudó por el gateway hasta el siguiente resultado. Lo encola la misma transacción de control, con llave `managed-root-control:<rootId>:<época>`.
- **El reaviso.** Abajo.

**El reloj.** Lo único de SUA-02 que depende de la hora es el reaviso de una excepción. Cuando el controlador marca un aviso, encola en la misma transacción una entrega `systemEvent` con `availableAt = ahora + renoticeAfterMs`, una por raíz, con llave `managed-root-renotice:<rootId>:<n>`, donde `n` es el número de avisos de la raíz. Al vencer, despierta a `main`. `main` llama `managed_roots_reconcile`, y el paso 8 de `decide` dice qué reavisar. Si al responder ya no queda ninguna excepción abierta en la raíz, la transacción de la respuesta borra esa entrega pendiente (`unknown` 5). Si no se puede borrar, el despertar llega, `notify` sale vacío y `main` contesta `NO_REPLY`: un despertar perdido, como mucho uno por hora y por raíz.

**Los demás plazos ya son eventos.** El host reporta `deadline-missed` como incidencia y R despierta. El plazo de la autoridad se comprueba al admitir y al iniciar un efecto (SUA-01). Nada más en SUA-02 espera al reloj.

**M-12.** No se corre. El tic que pedía no existe: el único reloj es la cola de sesión de R, que no cuesta nada mientras espera y cuesta un despertar de M-01 al vencer. No se agrega ningún cron ni ningún `agent --message`, como pide el plan.

**Lo que cuesta.** Cada despertar de raíz es un turno de `main` con una llamada: unos 41 000 tokens, como M-04. Un reaviso abierto cuesta eso una vez por hora mientras David no conteste. La espera detrás de un turno de `main` en vuelo es la de M-02 y M-11: lo que le quede a ese turno.

### 4.5 Excepciones

**Las trece clases.** El enum es `ROOT_EXCEPTION_TYPES`, en el orden del contrato. La tabla dice cuándo la levanta `decide`, qué bloque trae el hecho que la dispara, las opciones y qué hace cada una. El destinatario es siempre el dueño de la raíz. Las clases que en el director de corrida iban a claw (`SIN_REVISOR`, `SIN_CUOTA`, `CI_ROJO`, `BOT_CALLADO`, `DEPLOY_FALLO`, `CIERRE_ROJO`, `INESPERADO`) se resuelven solas dentro de la autoridad y solo llegan al dueño cuando no queda una opción automática. Así lo pide `cobertura.md`.

| Clase | La levanta `decide` cuando | Hecho que la dispara | Opciones y efecto |
|---|---|---|---|
| `SIN_REVISOR` | Un criterio de rol `reviewer` no tiene revisor elegible | SUA-05 | `seguir`: espera otra selección. `relevo`: pide asignación de otro revisor. `cancelar`: la unidad termina en `cancelled` |
| `SIN_CUOTA` | No hay cuenta elegible para la asignación | SUA-03, SUA-04 | `seguir`: espera. `relevo`: pide asignación con otra cuenta. `cancelar` |
| `AUTH_VENCIDA` | El host dice que la sesión del proveedor venció | SUA-03 (hoy el host no lo distingue: llega como `launch-refused`) | `listo`: reintenta con otro intento; no fabrica credenciales. `cancelar` |
| `CI_ROJO` | CI sigue rojo tras las correcciones de la política | SUA-05 | `seguir`: una corrección más, que cuenta en `rondas`. `omitir`: la unidad termina en `failed`, sin merge ni crédito. `cancelar` |
| `BOT_CALLADO` | El check requerido no contesta | SUA-05 | `seguir`: consultar otra vez. `cancelar` |
| `CONFIRMAR_PLAN` | Una revisión de plan quita un criterio, o una unidad pide un repo o un modo que la autoridad no da | SUA-02 | `si`: la respuesta es la `scopeChange` autenticada. `cancelar` |
| `NECESITA_DAVID` | Efecto sin autoridad; criterio de rol `owner`; tope de rondas; `permission-required` | SUA-02 | Por causa. Efecto: `autorizar`, `listo` (David lo hizo), `omitir`, `cancelar`. Criterio: `aceptar`, `rechazar`. Tope: `seguir` (otras `roundsPerImplementer` rondas), `omitir`, `cancelar`. Permiso: `listo`, `omitir`, `cancelar` |
| `BLOQUEANTE_REPETIDO` | Nunca con `quality-kit.regla4` | Ninguno hoy (4.11, conflicto 4) | `omitir`, `cancelar` |
| `DEPLOY_FALLO` | Un efecto `deploy` asentado con `occurred: false` | SUA-08 | `seguir`: un efecto nuevo. `listo`: exige recibo y salud. `cancelar` |
| `CIERRE_ROJO` | Todas las unidades terminaron y alguna no está aceptada | SUA-02 | `seguir`: nuevos intentos de las no aceptadas. `cancelar`: cancela la raíz |
| `INESPERADO` | Incidencia sin reintento posible, o agotado el reintento | SUA-02 | `seguir`: un intento nuevo, sin poner contadores a cero. `omitir`. `cancelar` |
| `EVIDENCIA_INCIERTA` | Efecto `uncertain`, o claim `unknown` | SUA-02 | `conciliar`: pide al modelo conciliar y asentar. `omitir`. `cancelar` |
| `CAPACIDAD_INCIERTA` | El host rechazó lanzar (`launch-refused`) o el cupo no está configurado | SUA-02 | `seguir`: reintenta. `relevo`: pide otra asignación. `cancelar` |

`cancelar` termina la unidad del sujeto. Para una excepción de raíz (`CIERRE_ROJO`), cancela la raíz. `omitir` termina la unidad sin aceptarla: nunca cuenta como criterio cumplido.

Respecto del director retirado se quitan tres opciones, porque `cobertura.md` las prohíbe: `hecho` de `CIERRE_ROJO` ("respuesta humana no cambia tests rojos a verdes"), `seguir` con el contador en cero de `INESPERADO` ("no poner contadores a cero") y `SI` como reanudación de `BLOQUEANTE_REPETIDO`. Se agregan `autorizar`, `aceptar`, `rechazar` y `conciliar`. Las palabras de David se traducen como antes (`PALABRAS_DAVID`): `sí` y `si` son `si`; `listo` y `hecho`, `listo`; `salta`, `omitir`; `cancela`, `cancelar`.

**IDs.** `exceptionId = sha256(managedTaskJson([rootId, type, subject]))`. El mismo hecho da el mismo id, así que un commit repetido no levanta dos. En el aviso va un código corto, los seis primeros caracteres del id, que es lo que David escribe.

**La tabla.** Lazy, como las once de SUA-01:

```sql
CREATE TABLE IF NOT EXISTS managed_root_exceptions (
  root_id TEXT NOT NULL REFERENCES managed_roots(root_id),
  exception_id TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('SIN_REVISOR', 'SIN_CUOTA', 'AUTH_VENCIDA', 'CI_ROJO',
    'BOT_CALLADO', 'CONFIRMAR_PLAN', 'NECESITA_DAVID', 'BLOQUEANTE_REPETIDO', 'DEPLOY_FALLO',
    'CIERRE_ROJO', 'INESPERADO', 'EVIDENCIA_INCIERTA', 'CAPACIDAD_INCIERTA')),
  subject_json TEXT NOT NULL,
  unit_id TEXT,
  attempt INTEGER,
  effect_id TEXT,
  options_json TEXT NOT NULL,
  evidence_ref_json TEXT,
  recipient_json TEXT NOT NULL,          -- { channel, principal } del dueño
  renotice_after_ms INTEGER NOT NULL CHECK (renotice_after_ms >= 3600000),
  commit_id TEXT NOT NULL,               -- el commit que la levantó
  raised_at INTEGER NOT NULL,
  noticed_at INTEGER,
  notices INTEGER NOT NULL CHECK (notices >= 0),
  response_option TEXT,
  response_by TEXT,
  response_at INTEGER,
  applied_commit_id TEXT,                -- el commit que aplicó la respuesta
  PRIMARY KEY (root_id, exception_id),
  FOREIGN KEY (root_id, commit_id) REFERENCES managed_root_commits(root_id, commit_id),
  FOREIGN KEY (root_id, applied_commit_id) REFERENCES managed_root_commits(root_id, commit_id),
  FOREIGN KEY (root_id, unit_id, attempt) REFERENCES managed_root_attempts(root_id, unit_id, attempt),
  FOREIGN KEY (root_id, effect_id) REFERENCES managed_root_effects(root_id, effect_id),
  CHECK ((response_option IS NULL) = (response_by IS NULL)),
  CHECK ((response_by IS NULL) = (response_at IS NULL)),
  CHECK (applied_commit_id IS NULL OR response_option IS NOT NULL),
  CHECK ((noticed_at IS NULL) = (notices = 0))
) STRICT;
```

Lo que el esquema no puede decir y queda en código, cada regla con su prueba: la opción respondida está en `options_json`; una respuesta no cambia (`UPDATE ... WHERE response_option IS NULL`, con una fila cambiada); y las opciones son un subconjunto del vocabulario de la clase.

**Levantar.** Solo dentro de `commitManagedRootDecision`, en la lista `exceptions`, después de los `outcomes`. Una excepción y la decisión que la causa entran juntas o no entra ninguna.

**Entregar.** `managed_roots_reconcile` devuelve cada excepción de `notify` con su código, su clase, la causa en una línea y sus opciones. `main` se lo dice a David en su respuesta, que sale por Telegram en la sesión de David, como el resultado de un encargo hoy (`B22-canarios.md:220`). `recipient` es `{ channel: <canal del principal>, principal: <principal del dueño> }`: sale del turno que abrió la raíz, no del repo ni de un argumento. R no sabe si Telegram entregó el mensaje. El contrato lo acepta: "sin prometer exactamente una notificación cuando no hay consulta o clave idempotente" (diseño del sistema, "Proyección, reloj y publicación").

**Responder.** `answerManagedRootException({ rootId, exceptionId, optionId }, turn)`, una transacción:
1. La raíz existe y no está `cancelled`. Si no, `root-not-active`.
2. El turno es el dueño con la instancia vigente (`managedRootStanding`).
3. El `principal` del turno es el de `recipient`. Si no, `not-recipient`. Un turno de `main` sin remitente no puede contestar por David.
4. La excepción existe en esa raíz (`exception-unknown`) y la opción está entre las suyas (`option-not-offered`).
5. Sin respuesta, la guarda. Con la misma respuesta, devuelve el recibo con `replayed: true`. Con otra, `exception-answered`.
6. Si no queda otra excepción abierta en la raíz, borra el reaviso pendiente.

La herramienta llama después al controlador, así que la respuesta se aplica en la misma llamada. Una respuesta nombra siempre un `exceptionId`. Con varias abiertas, la skill le pide a `main` que pregunte cuál si David no dio el código. R no adivina: no hay forma de responder sin id.

**Reavisar.** 4.4. El reaviso es de una línea: código, clase y opciones.

### 4.6 Autoridad

**Al abrir.** El modelo escribe `actions`, `repos`, `accounts`, `destinations`, `deadline` y `mode` a partir de las palabras de David. R sella el resto desde el turno: `grantedBy` es el `principal` del turno, `grantedAt` es la hora de R y `authorityRef` es `run:<runId>`. `managed_roots_open` rechaza un turno sin remitente: una raíz solo nace de un mensaje de una persona. El texto del pedido se guarda como artefacto con `storeManagedTaskInstruction`, y `requestDigest` es su huella, calculada por R. Así la autoridad y el pedido del que salió quedan uno junto al otro, con el mismo turno.

**Un pedido grande autorizado no pregunta.** `decide` no tiene ninguna regla por tamaño ni por número de unidades. Pregunta solo con una de las causas de 4.5.

**Restringir.** `restrictManagedRootAuthority({ rootId, restrictionId, expectedAuthorityRevision, authority }, actor)`. La puede pedir el dueño desde su turno o el operador. La autoridad nueva tiene que estar contenida en la vigente: mismas o menos acciones, repos, cuentas y destinos, un plazo igual o anterior y un modo igual o menor. Si no, `authority-widens`. Se guarda en una tabla de solo inserción:

```sql
CREATE TABLE IF NOT EXISTS managed_root_authority (
  root_id TEXT NOT NULL REFERENCES managed_roots(root_id),
  revision INTEGER NOT NULL CHECK (revision > 1),    -- la 1 es managed_roots.authority_json
  prev_revision INTEGER,
  authority_json TEXT NOT NULL,
  restriction_id TEXT NOT NULL,
  restriction_digest TEXT NOT NULL,
  actor_json TEXT NOT NULL,
  receipt_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (root_id, revision),
  UNIQUE (root_id, restriction_id),
  CHECK ((revision = 2 AND prev_revision IS NULL) OR
         (prev_revision IS NOT NULL AND prev_revision = revision - 1)),
  FOREIGN KEY (root_id, prev_revision) REFERENCES managed_root_authority(root_id, revision)
) STRICT;
```

`currentRootAuthority(database, rootId)` contesta la fila de revisión mayor, o `authority_json` si no hay ninguna. Sustituye los cuatro `JSON.parse(root.authority_json)` de hoy (rebanada 1). Así `claim`, el inicio de un efecto y la revisión de plan comprueban la autoridad vigente sin cambiar una línea más. No se amplía nunca: quitar una restricción es abrir otra raíz.

**Conceder un efecto.** `effectStartRefusal` gana una salida: si `authorityRefusal` rechaza, el efecto inicia igual cuando la raíz tiene una excepción `NECESITA_DAVID` sobre ese `effectId`, respondida `autorizar` por el dueño, después de la última restricción. Concede ese efecto, con esa acción, ese repo y ese destino. Un efecto nuevo con otro `effectId` vuelve a preguntar. Así "SHA exacto significa ese SHA" se cumple sin ampliar la autoridad.

**Una sesión nueva no toma una raíz.** SUA-01 ya lo hace (`managedRootStanding`). Las herramientas no aceptan un `principal` ni un `sessionKey` como argumento.

**Un hijo no crea otra raíz.** `createManagedRootTools` no devuelve nada en una sesión de hijo (`isSubagentSessionKey`) ni en una corrida de trabajador gestionado. La comprobación de `openManagedRoot` (`managed-root.worker.ts:94-103`) se queda como segunda barrera.

**Quién emite un claim.** El modelo aporta claims solo de rol `verifier` o `ci`, con `procedure` y `artifactRef`. R escribe `verifier.principal` con el del turno y genera `evidenceId`. Un claim de rol `owner` sale solo de una respuesta `aceptar` del dueño. Uno de rol `reviewer` no se acepta del modelo en SUA-02: lo trae SUA-05 desde un resultado `review.v1` de otra tarea.

**Lo que esta autoridad no cubre.** Un trabajador por CLI tiene shell. Si su brief le pide crear un repo, la guarda de carpeta de opencode no lo impide (`followups.md`, B22-S7). La autoridad de la raíz detiene los efectos que pasan por el controlador. Los permisos efectivos del trabajador son de SUA-03 (I09).

### 4.7 Redactar e importar el plan

**Pedido natural.** `main` redacta el plan en el turno en que David lo pide. `managed_roots_open` recibe el texto del pedido y una cobertura: una entrada por frase del pedido, con su papel (`criterion`, `assumption` o `context`) y, para un criterio, los `criterionId` que la cubren. R parte el texto en frases con una regla fija y pura (`requestSentences`: por salto de línea y por punto seguido de espacio). Comprueba que cada frase tiene exactamente una entrada y que cada `criterionId` citado existe en el plan. Si no, `coverage-incomplete` con la primera frase que falta. Un criterio puede no venir de ninguna frase. Una frase no puede quedar sin papel. Esto no prueba que el modelo entendió el pedido. Prueba que no se saltó una frase sin decirlo.

**Fila de `Plans.md`.** `importar_plans.py --repo <ruta> --filas <ids>` lee `Plans.md` y devuelve la entrada de `managed_roots_open`. Cada fila es una unidad: `unitId` es el id de la fila, `title` su "Entrega" hasta el primer punto, `dependsOn` las filas de "Depends" que están en la selección. Una dependencia fuera de la selección con estado cerrado es un supuesto. Abierta, el importador falla. Cada cláusula de "Compuerta verificable", separada por `;`, es un criterio literal con rol `verifier`. El texto del pedido son las filas tal cual, una línea por cláusula, así que la cobertura sale sola. El importador es puro y sus pruebas comparan contra valores literales.

**Validación.** La de SUA-01 (`validateRootPlan`, con las cuatro reglas del contrato) más la cobertura. Un plan sin unidades se rechaza con `plan-invalid` (4.10, residual 6).

### 4.8 Herramientas y lo que cambia en R

**Seis herramientas.** En `managed-roots-tool.ts`, con el mismo patrón que `managed-tasks-tool.ts`: parser `zod` estricto, `captureManagedTaskTurn` y `runWithScopedSessionAccess`.

| Herramienta | Entrada | Llama |
|---|---|---|
| `managed_roots_open` | `idempotencyKey`, `request: { text, coverage }`, `authority` sin los campos que sella R, `plan`, `budget` opcional (sin él, el perfil instalado) | `openManagedRoot` |
| `managed_roots_reconcile` | `rootId`, `commit` (por omisión `true`), `facts` opcional: `assignments`, `claims`, `effects`, `revision` | `reconcileManagedRoot` |
| `managed_roots_answer` | `rootId`, `exceptionId`, `optionId` | `answerManagedRootException`, después `reconcileManagedRoot` |
| `managed_roots_control` | `rootId`, `command` (`pause`, `resume`, `cancel`, `restrict`), `commandId`, la época o revisión esperada, `reason`, `authority` para `restrict` | `controlManagedRoot` o `restrictManagedRootAuthority` |
| `managed_roots_effect` | `rootId`, `effectId`, `startId`, `step` (`start` o `settle`), `outcome` para `settle` | `startManagedRootEffect` o `settleManagedRootEffect` |
| `managed_roots_recover` | nada | `recoverManagedRootRequester` |

`managed_roots_effect` existe porque en SUA-02 el adaptador de un efecto es `main`: pide el permiso, hace el envío con `exec` y lo asienta. Los adaptadores propios son de SUA-05 y SUA-08.

**La llave que las enciende.** `ManagedTasksConfigSchema` gana `rootRequesters: string[]`, opcional. Sin la llave, ningún agente recibe herramientas de raíz y la lista de herramientas de `main` es la de hoy. En la Mini no se pone en SUA-02. La pone el corte de SUA-09O. Un binario anterior rechaza la llave, como `capacity` (riesgo 7 de SUA-01): quien la ponga la quita antes de una reversa.

**Lo demás que cambia en R:**

| Archivo | Cambio | Toca la ruta viva |
|---|---|---|
| `managed-root.authority.ts` (nuevo) | `currentRootAuthority`, `authorityNarrows`, la concesión | No |
| `managed-root.{admission,effect,plan}.worker.ts`, `managed-root.worker.ts` | Leen la autoridad con `currentRootAuthority` | No: solo ramas de raíz |
| `managed-tasks-tool.ts` | El cuerpo de `managed_tasks_admit` pasa a `admitManagedTask`, sin cambiar la conducta | Sí |
| `managed-task.delivery.ts` | Exporta `requesterIdentity`. Cambian los textos de las dos ramas de raíz | Sí, por el export |
| `managed-root.requester.worker.ts` | Usa `requesterIdentity` en lugar de `senderOf` (`:35`) | No |
| `managed-root.worker.ts` | La foto ampliada: `incidents`, `exceptions`, `authority` | No |
| `managed-root.commit.worker.ts` | Listas `exceptions` y `appliedAnswers` | No |
| `managed-root.control.worker.ts` | Despertar tras `resume` del operador | No |
| `openclaw-tools.managed-tools.ts` | Registra las herramientas de raíz con la llave | Sí: es donde se arma la lista de `main` |
| `zod-schema.managed-tasks.ts` | `rootRequesters` | Sí: la configuración se valida al arrancar |
| `src/state/openclaw-state-schema.sql` y las listas perezosas | Las dos tablas nuevas | No |

**Redacción.** La prueba de tabla (`managed-tasks-tool.test.ts`) gana los campos de las seis herramientas, todos en `false`: `request`, `text`, `coverage`, `role`, `criterionIds`, `commit`, `facts`, `assignments`, `relay`, `claims`, `revision`, `exceptionId`, `optionId`, `step`, `restrictionId`, `expectedAuthorityRevision`. Ninguno se llama `key`, `token`, `secret` ni `session`.

### 4.9 La sombra

El plan pide que el controlador "lee con `managed_tasks_inspect`, calcula la decisión sobre la raíz y la registra en su recibo, sin llamar `managed_tasks_resolve`". Hoy no hay raíces en producción: los encargos de `main` son tareas sueltas, y SUA-01 no liga una tarea suelta a una raíz (su riesgo 8). La sombra se hace así:

1. **Extracto.** En la Mini, una consulta de solo lectura (`file:<base>?mode=ro`, con el gateway arriba, como pide la fila "Operación" de `followups.md`) saca de `managed_tasks`, `managed_task_incidents`, `managed_task_handlings` y `managed_task_cancellations` solo lo que `decide` necesita: id de tarea, destino, contrato de resultado, tipo de resultado y veredicto, incidencias con su `episodeId` y hora, y la decisión o cancelación de `main` con su hora. Nada de credenciales ni de briefs. Se copia a la MacBook como JSON.
2. **Cálculo.** `sombra.mjs` importa `decideLooseTask` del worktree de R con `tsx`, como el arnés de G, y calcula para cada tarea lo que el controlador habría propuesto con los hechos anteriores a la decisión de `main`.
3. **Registro.** Escribe `docs/evidence/sistema-agentes-unificado/SUA-02-sombra.md` con una fila por tarea y la tabla de coincidencias:

| Propuesta de la sombra | Coincide con `main` si `main` hizo |
|---|---|
| `verificar-y-aceptar` (resultado sin cambios pedidos) | `resolve` con `complete` |
| `corregir` (`review.v1` con `changes`) | `resolve` con `continue` |
| `reintentar` | `cancel` y un encargo nuevo con el mismo brief |
| `excepcion:<clase>` | `cancel`, o nada, con aviso a David |

Una tarea sin decisión de `main` cuenta aparte.

No escribe en R, no despierta a nadie y no despacha. No hace falta instalar nada para correrla. Su límite está en 4.11, conflicto 1.

### 4.10 Los residuales de SUA-01

Son los siete de la fila "SUA-01/residuales" de `followups.md`.

| Residual | Decisión | Rebanada |
|---|---|---|
| 1. La ventana del `unknown` 13: una corrida nativa cuya admisión cerca la pausa entre su registro y `confirm` | Lo cierra SUA-02, porque el controlador es el primer llamador real de la admisión de un intento con destino agente. Caso con el registro de subagentes real: pausa entre `registerSubagentRun` y `confirm`, y `subagent_runs` no conserva una corrida viva de esa tarea | 8 |
| 2. Un `effectId` inexistente lanza | Pasa a conflicto `effect-unknown`. El controlador y la herramienta lo tratan como respuesta | 2 |
| 3. Volver a una instancia anterior del solicitante (A, B, A) lanza por `UNIQUE (root_id, instance)` | No hace falta en SUA-02. Solo pasa si una sesión recupera un `sessionId` viejo, y no se encontró qué lo haría (`unknown` 7). Si pasa, el operador cancela la raíz. Queda en `followups.md` | Ninguna |
| 4. `senderOf` copia la regla de `delivery.ts` | Se borra: `delivery.ts` exporta `requesterIdentity` y lo usan los tres despertares | 2 |
| 5. `release_ref` sin llave foránea | No hace falta. Es como `outcome_ref`: apunta a tres clases de orden. La única función que libera (`releaseUnitWriters`) ya tiene su prueba | Ninguna |
| 6. Un plan sin unidades abre una raíz | Se rechaza al abrir con `plan-invalid`, regla `schema`, ruta `plan.units`. Es una regla de la entrada de `open`, no del documento: `contrato.py` no cambia | 2 |
| 7. `ensayo-reversa.sh` imprime el SHA anterior y no lo fija | Se arregla al usarlo otra vez. La rebanada 4 agrega dos tablas perezosas y ensaya la reversa con un script versionado en G que comprueba `git -C "$RWT0" rev-parse HEAD` contra el SHA esperado antes de correr | 4 |

### 4.11 Conflictos con el plan y con el contrato

**Conflicto 1. La sombra "sobre la raíz" (plan, paso 5) y las tareas sueltas.**
- Opción A: sombra fuera de línea sobre un extracto de la base, con `decideLooseTask` (4.9).
- Opción B: un enganche en R que, después de cada `report` y cada incidencia de una tarea suelta, calcula la sombra y la guarda en una tabla. Ve los hechos en vivo, pero cambia la ruta viva para algo que no despacha, y obliga a instalar.
- Opción C: una raíz de sombra que no liga nada (riesgo 8 de SUA-01). Su propuesta sería siempre "ligar la unidad", que no se puede comparar con un `complete`.
- Recomendación: A. Observación honesta: la sombra de un encargo suelto discrimina poco, porque `main` hoy solo decide entre aceptar, corregir y cancelar. Lo que prueba `decide` de verdad son las pruebas de la sección 5 y los canarios de raíz de SUA-09O.

**Conflicto 2. "Dueño: R para control local" y "el controlador vive en `main`" (M-11).**
No es contradicción. El código del controlador vive en R. La sesión que R despierta y que llama la herramienta es la de `main` con David. Se anota porque el plan usa "controlador" para las dos cosas.

**Conflicto 3. Clase para "el dueño acepta un criterio".**
- Opción A: `NECESITA_DAVID` con `aceptar` y `rechazar`.
- Opción B: una clase nueva. Agregar un valor al enum sube la versión mayor del contrato.
- Recomendación: A.

**Conflicto 4. `BLOQUEANTE_REPETIDO` se conserva sin disparador.**
El plan pide conservar las once clases. SUA-05 dice que la política vigente "no lleva rotación forzada de revisor ni paro por bloqueante repetido". La clase queda en el enum, con opciones, y `decide` no la levanta mientras la raíz tenga `quality-kit.regla4`. El tope de 5+5 se pregunta como `NECESITA_DAVID`, que es lo que dice SUA-05.

**Conflicto 5. I12 está en SUA-02 y en SUA-05.**
SUA-02 hace la parte del linaje: el contador por unidad que no se reinicia, el tope y la parada. La versión queda fija en la raíz desde que se abre. `openManagedRoot` rechaza con `quality-policy-unknown` una versión que no esté en la tabla de políticas de `decide`, que en SUA-02 solo tiene `quality-kit.regla4`. Otra versión necesita la decisión registrada de David y es de SUA-05. Que el relevo use otro modelo no se puede comprobar en SUA-02: el modelo de un encargo por CLI va en la cabecera del brief, que R no lee. Lo comprueba SUA-05 con el documento `flota.v1` de SUA-03.

**Conflicto 6. Opciones heredadas que se quitan.**
El paso 4 pide "conservar opciones válidas". Tres no son válidas según `cobertura.md` (4.5). Recomendación: conservar el vocabulario salvo esas tres, con la razón escrita.

**Observaciones, sin conflicto:**
- El paso 1 pide implementar `open`, `control` y `read`. Ya existen desde SUA-01. Falta `reconcile`.
- El plan lista como archivos de SUA-02 la skill `encargo-cli` y `record_incident` y `flush_incidents` del host. Con este diseño ninguno cambia en SUA-02. `encargo-cli` cambia en SUA-09O, cuando `resolve` pase al controlador.
- El diseño del sistema habla de "un latido inicial de cinco minutos" ("Proyección, reloj y publicación"). El plan lo quitó (D14). No hay latido.

## 5. Cómo se prueba

Las pruebas de R son de `vitest` y llaman las herramientas o las órdenes como las llamará `main`. Las de G son `unittest` y el arnés de `test-agent-work-e2e.sh` con el proveedor de guion (`CROSS_PROVIDER=loopback`, `managed-cli-gateway-harness.mjs:32`), que hace llamadas a herramientas de verdad (`:129`). Cada fila dice qué fallo la pone roja.

### Ensayos integrados

| Ensayo | Archivo y caso | Qué hace | Fallo que la pone roja |
|---|---|---|---|
| I01 | G, `test-sistema-agentes-importar.py`, "una fila importada conserva sus criterios" | Importa tres filas de un `Plans.md` de fixture. Compara la entrada de `open` con un JSON literal: unidades, dependencias, supuestos y cada criterio palabra por palabra | Partir mal las cláusulas o perder una dependencia |
| I01 | R, `managed-roots-tool.test.ts`, "open refuses a request sentence without coverage" | Un pedido de cuatro frases y una cobertura de tres. Espera `coverage-incomplete` con la frase 3 y cero tablas de raíz | Quitar la comprobación de cobertura |
| I01 | Mismo archivo, "open keeps scope, assumptions and criteria" | Abre y lee: el plan, los supuestos y los criterios son los de entrada, y `requestDigest` es la huella del texto guardado | Recalcular o normalizar el texto |
| I02 | Mismo archivo, "an invalid plan launches nothing" | Ciclo, id duplicado, dependencia y criterio faltantes, y plan vacío. Cada uno contesta `plan-invalid` con la regla del contrato, y `managed_tasks` sigue con cero filas | Abrir antes de validar |
| I03 | R, `managed-root.decide.test.ts`, "binds C only after A and B are accepted" | Tabla de fotos literales: C pendiente con A aceptada y B reportada; C ligada con las dos aceptadas | Tratar `reported` como aceptada |
| I03 | R, `managed-root.controller.test.ts`, "two reconcilers bind one C" | Dos `reconcileManagedRoot` a la vez. Una C | Ligar fuera del commit |
| I04 | G, `test_agent_work_raiz_e2e.py` (caso `raiz_controlador`), "the turn ends and the root continues" | Raíz A→B por CLI con el doble de opencode. El turno que abre termina. El resultado de A despierta a `main`, el guion llama `managed_roots_reconcile`, B se liga y se admite sin ningún turno de persona. Cuenta peticiones al proveedor: una por despertar | Quitar el despertar de raíz, o que el texto no nombre la herramienta |
| I04 | R, `managed-root.controller.test.ts`, "decides from R after a restart" | Commit, reinicio de prueba, reconcilia otro turno. Misma propuesta | Estado de módulo en el controlador |
| I05 | Mismo archivo, "a paused root proposes nothing and an operator resume wakes the owner" | Pausa: propuesta sin decisión. `resume` por `managedTasks.root.control`: una entrega encolada a la sesión del dueño | No encolar el despertar |
| I05 | Mismo archivo, "a stale epoch re-reads once" | Una pausa y un `resume` entre la lectura y el commit. El controlador vuelve a leer una vez y hace commit. Con dos conflictos seguidos devuelve el conflicto | Bucle sin tope, o ninguna relectura |
| I06 | `managed-root.decide.test.ts`, "an uncertain effect raises one exception and is never prepared again" | Efecto `uncertain`: una `EVIDENCIA_INCIERTA`. Repetir la propuesta: el mismo id. Un efecto `confirmed` no vuelve a prepararse | Preparar de nuevo un `effectId` de la foto |
| I07 | R, `managed-root.authority.test.ts` | Seis casos. Sin autoridad: `create-repo` y `send-mail` levantan `NECESITA_DAVID` y la unidad independiente se liga en el mismo commit. Revocación: tras restringir `push`, el inicio de un efecto `push` se rechaza y una concesión anterior no vale. Ampliar contesta `authority-widens`. Otra sesión: la foto es `null` y responder contesta `not-owner`. Un turno sin remitente no responde (`not-recipient`). Diseño: una unidad `implement` en una raíz `design` no abre. SHA futuro: un efecto cuyo destino no está en `destinations` se rechaza | Leer `authority_json` en vez de la vigente; aceptar respuesta de cualquiera |
| I07 | Mismo archivo, "a large authorized request asks nothing" | Raíz de doce unidades dentro de su autoridad. Cero excepciones, y las que caben en el cupo se ligan | Una regla por tamaño |
| I12 | `managed-root.decide.test.ts`, "corrections converge or stop" | Una unidad falla diez veces. Pide corrección hasta 5, relevo de 6 a 10, y en 10 levanta `NECESITA_DAVID` sin ligar más. Una revisión que no cambia la huella y hallazgos nuevos no bajan `rondas` | Reiniciar el contador; ligar después del tope |
| I12 | `managed-root.store.test.ts`, "a root opens only with a known quality policy" | `openManagedRoot` con `qualityPolicy.version` `quality-policy.v2` contesta `quality-policy-unknown` y no crea tablas. Con `quality-kit.regla4`, abre | Aceptar cualquier versión |

### El párrafo "Verificar" del bloque, frase por frase

| Frase | Dónde queda cubierta |
|---|---|
| I01–I07/I12 | Tabla de arriba |
| Tres entradas: pedido pequeño, fila importada y pedido compuesto | `raiz_controlador` corre las tres con los planes de `planes/validos/` (`pedido-chico.json`, `fila-importada.json`, `pedido-compuesto.json`) |
| El turno termina y la meta continúa | I04, primera fila |
| Respuestas con cero, una o varias excepciones no se aplican a otra | `managed-root.exception.test.ts`: responder sin excepciones abiertas contesta `exception-unknown`; con una, cambia solo esa; con tres, responder la segunda deja la primera y la tercera abiertas y sin `appliedBy`; responder otra vez con otra opción contesta `exception-answered` |
| Un pedido grande autorizado no pregunta por ritual | I07, segunda fila |
| Crear repo o enviar mail sin autoridad queda detenido | I07, primera fila. El efecto sigue `prepared` y la excepción está abierta |

### Lo que no es un ensayo integrado y también se prueba

| Qué | Archivo y caso | Fallo que la pone roja |
|---|---|---|
| Las clases de R son las del contrato | `managed-root.exceptions.test.ts` compara `ROOT_EXCEPTION_CLASSES` con `excepcion/clases.json` y los tipos con el enum de `contrato.py`, con `AGENT_WORK_G_ROOT`. Sin la variable el caso falla por la guarda de nombres, como `root_contract` | Cambiar una opción en un solo lado |
| El esquema rechaza cada estado ilegal | `managed-root.schema.test.ts` gana una fila por restricción de las dos tablas | Quitar la restricción |
| Una respuesta no cambia | `managed-root.exception.test.ts`: un `UPDATE` directo que cambia la respuesta no lo hace la orden; la orden contesta `exception-answered` | Escribir sin `WHERE response_option IS NULL` |
| El reaviso espera y sobrevive a un reinicio | `managed-root.exception.test.ts`: una entrega con `availableAt` a 200 ms no se entrega antes; tras un reinicio de prueba se entrega después | `unknown` 2 |
| Sin la llave no hay herramientas | `openclaw-tools.managed-tools.test.ts`: con la configuración de la Mini sin `rootRequesters`, la lista de `main` es igual a la literal de hoy | Registrar sin mirar la llave |
| Un hijo no recibe herramientas de raíz | Mismo archivo, con una sesión `isSubagentSessionKey` | `unknown` 3 |
| La ruta viva no cambió | `ruta_viva` en cada SHA, sin `skipped` | Cualquier cambio en la admisión, el reporte o los despertares de tarea suelta |
| La sombra calcula lo mismo que `decide` | `test-sistema-agentes-sombra.py` con un extracto de fixture y su salida literal | Otra regla en la sombra |

## 6. El corte en rebanadas

Nueve rebanadas de R y tres de G. Cada una trae su prueba y deja verde lo anterior.

**Dónde se corre.** Como en SUA-01: `RWT` es el worktree de R de la rebanada, con su `pnpm install` y su `pnpm build`. `GWT` es un checkout de G en `origin/main` con el diseño mergeado. Antes de correr nada, `git -C "$RWT" rev-parse HEAD` imprime el SHA de la rebanada.

**La compuerta** es la de SUA-01 (su sección 6) más los siete casos `root_*` de `test-runtime.sh`, y desde la G3 los tres nuevos (`root_controller`, `root_exceptions`, `root_authority`). Hasta la G3, los archivos nuevos de R se corren con `node scripts/run-vitest.mjs`. Las tres condiciones de SUA-01 siguen: `candidateSha` es el de la rebanada, `ruta_viva` sin `skipped`, y lint con los mismos 8 errores heredados y ninguno nuevo (`followups.md`, "SUA-01/R lint").

| N.º | Rebanada | Qué cambia | Su prueba | Toca la ruta viva |
|---|---|---|---|---|
| R0 | Línea base | Nada. La compuerta sobre R `65432d0` | Las de hoy | No |
| R1 | Una lectura de autoridad y una admisión | `currentRootAuthority` sustituye los cuatro `JSON.parse`. El cuerpo de `managed_tasks_admit` pasa a `admitManagedTask`. Sin cambio de conducta | Las de hoy, y `ruta_viva` | Sí |
| R2 | Residuales | `effect-unknown`, plan vacío rechazado, `requesterIdentity` exportado y `senderOf` borrado, y el comentario viejo de `gatewaySlots` (`managed-root.types.ts:390`) | Un caso por residual | Sí, por el export |
| G1 | Clases en el contrato | `excepcion/clases.json` y su prueba en `test-sistema-agentes-contrato.py` | La prueba del contrato | No |
| R3 | `decide` puro | `managed-root.exceptions.ts`, `managed-root.decide.ts` con `decideRoot`, `decideLooseTask` y la tabla de políticas. `openManagedRoot` rechaza una política que no está en la tabla. Nadie más los llama | `managed-root.decide.test.ts`, `managed-root.exceptions.test.ts` | No |
| R4 | Esquema | Las dos tablas, su registro perezoso, los tipos generados, las listas de 4.1 de SUA-01 y el ensayo de reversa con el script fijado | `managed-root.schema.test.ts`, el ensayo | No |
| R5 | Foto ampliada | `incidents`, `exceptions` y `authority` en la foto | Casos de lectura | No |
| R6 | Excepciones | Levantar en el commit, responder, avisar, el reaviso con `availableAt`, el borrado del reaviso, la concesión de efecto | `managed-root.exception.test.ts` | No |
| R7 | Restringir | `restrictManagedRootAuthority` y el despertar tras `resume` o restricción del operador | `managed-root.authority.test.ts` | No |
| R8 | Controlador | `reconcileManagedRoot` y el residual 1 | `managed-root.controller.test.ts` | No |
| R9 | Herramientas | Las seis herramientas, `rootRequesters`, los textos de despertar de raíz, la prueba de redacción | `managed-roots-tool.test.ts`, `openclaw-tools.managed-tools.test.ts`, la tabla de redacción | Sí: la lista de herramientas y la configuración |
| G2 | Skill e importador | `raiz/SKILL.md` (no se publica en la Mini), `importar_plans.py` con su entrada en `ruff.toml` y en los hooks | `test-sistema-agentes-importar.py`, `pre-commit` | No |
| G3 | Casos en G y cierre | `raiz_controlador` en `test-agent-work-e2e.sh`, los tres casos de `test-runtime.sh`, `runtime-map.json`, `sombra.mjs` y su prueba, la corrida de la sombra, el recibo `SUA-02.md` | Cada caso corre su archivo de R | No |

### Por qué este orden

- **R1 y R2 quitan antes de añadir.** R1 deja un solo lugar que lee la autoridad y un solo lugar que admite. R6, R7 y R8 añaden sobre eso. R2 cierra los residuales pequeños antes de que el controlador los pise.
- **G1 va antes que R3.** La prueba de R compara su tabla con el fixture de G.
- **R3 no depende de nada nuevo.** Es puro. Se puede escribir en paralelo con R1 y R2. Su merge espera, como todas.
- **El esquema entra completo en R4**, como en SUA-01. Las tablas perezosas no existen en la Mini hasta que alguien abra una raíz, y nadie puede hasta SUA-09O.
- **R9 es la última de R.** Es la única que cambia lo que `main` ve, y su prueba compara la lista de herramientas con la de hoy.

### Instalación en la Mini: una, después de R9

R1, R2 y R9 tocan código que corre la ruta viva. Las demás solo corren para una raíz, y en producción no hay raíces. En SUA-01 hubo dos instalaciones para separar la ruta viva de lo nuevo. Aquí la última rebanada que toca la ruta viva es también la última de R, así que una instalación basta. Instalar tras R2 probaría solo el traslado de la admisión, que `ruta_viva` ya prueba en local.

Sigue la "Regla de instalación en vivo": a cualquier hora, en un hueco sin turnos, crons ni encargos en vuelo, hasta 20 minutos de espera, con foto y reversa listas, con un `t12-actualizar-<sha>.sh` como el de SUA-01. Antes, la T11-c con el paquete instalado de `65432d0` sobre una base sembrada con las trece tablas, una raíz, una excepción y una restricción.

| Comprobación | Comando en la Mini | Esperado |
|---|---|---|
| El binario es el de R9 | `cat ~/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw/dist/build-info.json` | `commit` igual al SHA mergeado |
| La versión del esquema no se movió | `sqlite3 'file:/Users/gon/.openclaw/state/openclaw.sqlite?mode=ro' "PRAGMA user_version"` con el gateway arriba | `27` |
| No apareció ninguna tabla de raíz | `sqlite3 'file:…?mode=ro' "select count(*) from sqlite_master where name like 'managed_root%'"` | `0` |
| La configuración no tiene la llave | `openclaw gateway call config.get --params '{}' --json` y leer `managedTasks` | Sin `rootRequesters` |
| `main` no ve herramientas de raíz | `unknown` 6 | Ninguna `managed_roots_*` |
| La ruta viva atiende un encargo real | Un canario como el de SUA-01: un encargo por CLI de `main` | `acknowledged`, `AbsenceVerified`, `result_digest` en R y un solo despertar |
| Los crons quedaron igual | `openclaw cron list --json` antes y después | Los mismos habilitados |
| La lectura de raíz sigue sin crear tablas | `openclaw gateway call managedTasks.root.read --params '{"rootId":"no-existe"}' --json` | `null`, y siguen siendo 0 tablas |

La reversa es reinstalar el paquete de `65432d0`, sin restaurar bases, mientras la llave `rootRequesters` no esté puesta.

## 7. Lo que no entra en SUA-02

| Qué | Por qué | Bloque |
|---|---|---|
| Abrir raíces en producción, poner `rootRequesters` y `capacity` en la Mini, pasar `managed_tasks_resolve` de `main` al controlador, publicar la skill `raiz` | Es el corte | SUA-09O |
| Elegir especialista, modelo y cuenta; `flota.v1`; comprobar que el relevo usa otro modelo | La asignación llega como hecho | SUA-03, SUA-04, SUA-05 |
| Los permisos efectivos del trabajador por CLI | El shell no está confinado | SUA-03 |
| La política de rondas como archivo de datos, el revisor independiente, los claims de rol `reviewer`, CI y bots | SUA-02 usa la tabla de una sola versión | SUA-05 |
| Adaptadores de efecto propios: push, merge, deploy, correo | En SUA-02 el adaptador es `main` | SUA-05, SUA-08 |
| Avisos consolidados, panel, proyección | La excepción se avisa por la sesión de `main` | SUA-06 |
| Que el host distinga una sesión vencida del proveedor | Hoy llega como `launch-refused` | SUA-03 |
| Vincular la identidad de David entre canales | Decisión pendiente de SUA-01 | Antes de SUA-09O |
| Una sombra en vivo dentro de R | 4.11, conflicto 1 | Nadie |
| Un latido o un cron del controlador | 4.4 | Nadie |

## 8. Riesgos, `unknown` y decisiones pendientes

### Riesgos conocidos

1. **La autoridad la interpreta el modelo.** `main` traduce las palabras de David a `actions` y `repos`. R sella quién y cuándo, y guarda el pedido junto a la autoridad, pero no puede saber si "hazlo" incluía `merge`. Lo que lo acota: solo abre un turno con remitente, la autoridad no se amplía nunca y una acción fuera de ella pregunta. El revisor debe atacar esto primero.
2. **La sesión de David crece.** Cada despertar de una raíz es un turno en la sesión de `main` con David. Un programa largo la agranda (la memoria "Gateway congelado = sesión gigante" lo vivió). `/new` y `managed_roots_recover` son la salida que SUA-01 ya dejó.
3. **El despertar espera detrás de cualquier turno de `main`.** M-11 lo midió también hacia otro agente. Un turno largo de `main` retrasa cada reconciliación lo que le quede.
4. **El commit se ensancha.** Pasa de seis listas a ocho. Sigue siendo una transacción. Un controlador que quiera pasos chicos manda commits chicos.
5. **Un reaviso perdido por hora.** Si borrar la entrega pendiente no se puede (`unknown` 5), una raíz sin excepciones abiertas puede despertar a `main` una vez más.
6. **El shell del trabajador.** 4.6, "Lo que esta autoridad no cubre".

### Lo que no se pudo comprobar

| N.º | Qué no se sabe | Por qué importa | Comando que lo contesta |
|---|---|---|---|
| 1 | Si un turno de `main` que viene de un mensaje de David en Telegram lleva remitente, o sea `principal` `["sender","telegram",…]` | Sin remitente, `managed_roots_open` no abre y nadie puede responder una excepción como dueño. Es lo primero que hay que saber antes de R9 | En la Mini, con el gateway arriba: `sqlite3 'file:/Users/gon/.openclaw/state/openclaw.sqlite?mode=ro' "select requester_json from managed_tasks order by created_at desc limit 5"`. Una tarea que David pidió por Telegram tiene que traer `\"sender\",\"telegram\"` |
| 2 | Si una entrega `systemEvent` con `availableAt` futuro espera de verdad y sobrevive a un reinicio | Es el reloj del reaviso | Leído en `session-delivery-queue-runtime.ts:63-73` y `delivery-recovery.shared.ts:80-86`. Lo cierra el caso de R6 |
| 3 | Si un hijo nativo de `main` (`sessions_spawn`) recibe hoy las herramientas `managed_tasks_*` | Si las recibe, también recibiría las de raíz sin la guarda de 4.6 | En R: un caso en `openclaw-tools.managed-tools.test.ts` que arma las herramientas con `runSessionKey` de subagente de `main` |
| 4 | Si la respuesta de un turno despertado por `heartbeat` sale por Telegram, o si `main` usa la herramienta `message` | Es el canal de los avisos de excepción | En la Mini, con `turnos.sh` sobre el último despertar de un encargo: ver `tools` del turno. O leer el `AGENTS.md` de `main` respaldado en `goncloud-workspace-main` |
| 5 | Si completar una entrega pendiente que todavía no vence, dentro de la transacción de la respuesta, la saca de la cola sin efectos. Leído: existe `completeDeliveryQueueEntryInDatabase` (`src/infra/delivery-queue-sqlite.kernel.ts:227`), que usa `sessionDelivery.complete` (`session-delivery-queue.worker.ts:174-178`) | Para no gastar un despertar tras responder | El caso de R6 que responde la última excepción y cuenta las entregas pendientes de la raíz antes y después |
| 6 | Si `tools.effective` (`core-descriptors.ts:137`) lista las herramientas gestionadas, que solo se arman con una corrida (`runId`, `openclaw-tools.managed-tools.ts:44-52`) | Es la comprobación de la instalación de que `main` no ve herramientas de raíz | En la Mini: `openclaw gateway call tools.effective --params '{"sessionKey":"<sesión de David con main>"}' --json` antes y después de instalar. Si no lista `managed_tasks_*` antes, no sirve y se usa la prueba de R de la tabla de 5 |
| 7 | Si algo en R vuelve a usar un `sessionId` anterior para la misma sesión | Es el residual 3 | En R: `git grep -n "sessionId" -- src/config/sessions \| grep -i "restore\|revert"` |
| 8 | Si en el arnés de G el turno que despierta la cola de entregas llega con el remitente del dueño y puede llamar las herramientas de raíz como dueño. El arnés ya arma herramientas con un remitente de prueba (`managed-cli-gateway-harness.mjs:284-288`), y SUA-01 probó la regla en vitest ("a wake from a sender-owned root commits from the woken turn") | Sin eso, `raiz_controlador` no puede probar I04 de punta a punta y el despertar de la Mini tampoco funcionaría | El primer paso de G3: abrir una raíz desde una operación del arnés con remitente, reportar, drenar la cola y comprobar que el turno del guion recibe `managed_roots_reconcile` y su commit entra |

### Decisiones pendientes de David

Ninguna impide implementar SUA-02. Las dos vienen de SUA-01 y siguen sin respuesta. Hacen falta antes de SUA-09O:

- **El cupo del gateway.** "¿Cuántos trabajos de raíces pueden correr a la vez en todo el gateway, contando los encargos sueltos de `main`?". Hoy el código usa 4 cuando falta `managedTasks.capacity` (`managed-root.limits.ts:8`), y su comentario dice que nadie lo decidió.
- **De quién es una raíz.** "Una raíz que abriste por Telegram, ¿la puede seguir un turno de `main` que no viene de ti, como un cron con sesión, o un mensaje tuyo por otro canal?". Este diseño sigue con lo de SUA-01: no. Con eso, solo David por el mismo canal responde una excepción.

### Lo que impide empezar a implementar

Nada que sea una decisión. Antes de R9 hay que contestar el `unknown` 1 con su consulta de solo lectura en la Mini. Antes del primer merge, la R0: la compuerta verde sobre `65432d0` con `ruta_viva` sin saltos.
