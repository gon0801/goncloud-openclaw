# Issues upstream — OpenClaw 2026.9.4 (corrida nocturna 2026-09-15)

Borradores listos para pegar en GitHub. Versión medida: `OpenClaw 2026.9.4 (3a9d69d)`
(`~/.openclaw/bin/openclaw --version` en la Mac, 2026-09-16). Archivos del `dist`:
`~/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw/dist`. No se reporta
`Task outside session tree`: es por diseño (el árbol de la sesión cambió al relanzar
el lead), no bug.

---

## 1. `Session transcript projection is rebuilding` tira ~8 latidos por reconciliación

**Versión:** 2026.9.4. **Cadena exacta:** `Session transcript projection is rebuilding: <sessionId>`.

**Dónde nace:** `dist/session-accessor-BxcCxteu.mjs` —
`SessionTranscriptProjectionUnavailableError` (`src/config/sessions/session-transcript-projection-error.ts`),
lanzado al final de `withCurrentProjectionSnapshot` cuando el snapshot no sirve.

**Condición de disparo (leída en el código):** cuando NO hay snapshot, la lectura
devuelve el estado vacío y no falla (`if (!snapshot) return { kind: "value", … state:
EMPTY_PROJECTION_STATE }`). El error se lanza cuando SÍ hay snapshot y pasa CUALQUIERA
de: el snapshot no trae `state`; `snapshot.state.needsRebuild` es true;
`indexedSeq != latestSeq`; o `hasUnclassifiedSessionTranscriptEvents(db, sessionId)`
devuelve true. En ese caso
dispara `startSessionTranscriptIndexReconcile({...databaseOptions, preferredSessionId})`
y tira el error en vez del valor — o sea, toda lectura de historial durante una
reconciliación (aunque sea por UN evento sin clasificar) falla en vez de devolver lo
indexado hasta ahí.

**Impacto medido en la corrida:** ~8 latidos perdidos en la sesión del lead mientras
la proyección se reconstruía; cada latido reintentó y falló con la misma cadena.

**Repro:** forzar `needs_rebuild=1` (o insertar un evento sin clasificar) en la fila
de la sesión en la base sqlite del agente y luego leer el historial
(`sessions.history.read`): la lectura tira el error hasta que termina la
reconciliación.

**Sugerencia:** devolver el snapshot parcial con un flag `stale:true` en vez de tirar,
o al menos exponer el progreso de la reconciliación para backoff con tope.

---

## 2. `execution identity admission envelope/token violates its bounded contract` mata el primer spawn sin decir qué campo falló

**Versión:** 2026.9.4. **Cadenas exactas:**
`execution identity admission envelope violates its bounded contract`,
`execution identity admission token violates its bounded contract`
(y la hermana `execution identity admission facts violate their bounded contract`).

**Dónde nace:** `dist/execution-identity-admission-DsSgIxAr.mjs` — `validateEnvelope`
(línea ~298) y `validateToken` (línea ~321): chequeo de esquema TypeBox
(`Value.Check(ExecutionIdentityAdmissionEnvelopeSchema, ...)` /
`ExecutionIdentityAdmissionTokenSchema`) más `Number.isSafeInteger(createdAt)`.

**Condición de disparo (leída en el código):** el chequeo falla si el objeto no
calza el esquema cerrado (`closedObject`: cualquier campo de más también falla) o si
`createdAt` no es entero seguro. El error no dice cuál campo ni por qué (schema vs
timestamp vs campo extra), así que el operador no puede distinguir "reloj corrupto"
de "versión vieja del emisor".

**Impacto medido en la corrida:** el primer spawn del lead murió con este error;
relanzamiento manual, sin más diagnóstico que la cadena.

**Repro:** llamar al spawn con un envelope cuyo `createdAt` sea float (p. ej.
`Date.now()/1000` sin truncar) o con un campo adicional: el error es el mismo en
ambos casos.

**Sugerencia:** incluir en el mensaje el campo que falló y la causa
(`schema`/`createdAt`/`campo extra: <nombre>`).

---

## 3. `incompatible Gateway bindings: bound and unbound owners` traga reportes de fixers ya terminados

**Versión:** 2026.9.4. **Cadena exacta:**
`incompatible Gateway bindings: bound and unbound owners`.

**Dónde nace:** `dist/gateway-request-scope-D3jaIclh.mjs` —
`getSharedGatewayContextResolver(owners)`: mapea cada owner a su resolver; si
ALGUNOS tienen resolver y otros no (`resolvers.some((resolve) => !resolve)`), el
`shared()` tira este error al resolver el contexto.

**Condición de disparo (leída en el código):** lote de subagentes (`requesterSettleWake`,
ver `worker.mjs`: `getSharedGatewayContextResolver(Br)`) donde los runs mezclan
owners con y sin contexto de Gateway — p. ej. un fixer lanzado desde un turno con
binding y otro desde un contexto sin binding (relanzamiento del lead, sesión
recortada). El lote entero no se entrega aunque cada run haya terminado bien.

**Impacto medido en la corrida:** 2 fixers terminaron y su reporte no llegó al
requester; el trabajo se perdió del lado del que esperaba.

**Repro:** difícil sin instrumentación (requiere mezclar owners en un mismo lote de
`requesterSettleWake`); el camino corto es un test unitario sobre
`getSharedGatewayContextResolver` con `[resolver, undefined]`.

**Sugerencia:** entregar los runs con contexto válido y marcar solo los huérfanos
como `delivered:false` con su runId, en vez de tirar el lote entero.

---

## 4. Reportes de subagentes cortados por `MAX_LIVE_TOOL_RESULT_CHARS` sin ruta a archivo

**Versión:** 2026.9.4. **Cadenas/constantes:** `DEFAULT_MAX_LIVE_TOOL_RESULT_CHARS = 16e3`,
`LARGE_CONTEXT_MAX_LIVE_TOOL_RESULT_CHARS = 32e3`,
`XL_CONTEXT_MAX_LIVE_TOOL_RESULT_CHARS = 64e3` (en
`dist/tool-result-limits-Bz171wrQ.mjs`, `src/agents/tool-result-limits.ts`).

**Condición de disparo (leída en el código):** `resolveAutoLiveToolResultMaxChars(contextWindowTokens)`
elige 64e3 solo si el modelo declara ≥200k tokens de contexto
(`XL_CONTEXT_TOOL_RESULT_TOKENS = 2e5`), 32e3 si ≥100k, y 16e3 en cualquier otro
caso (incluido contexto desconocido/no-finito). Todo resultado de tool que exceda el
tope se trunca para el modelo que lo lee: un reporte largo de `sessions_spawn`
llega cortado al requester sin aviso de dónde se cortó.

**Impacto medido en la corrida:** reportes de subagentes llegaron truncados; la
mitigación nuestra es que el subagente escriba el reporte a archivo y pegue solo la
ruta (ver runbooks de autopilot).

**Repro:** un subagente que devuelva >16k chars de reporte a un requester con modelo
de contexto <100k: el requester ve el texto cortado.

**Sugerencia (feature):** que el resultado de `sessions_spawn` pueda devolver ruta a
archivo (el worker ya corre en un host con disco): `reportPath` además de `text`,
con el mismo presupuesto de lectura que un `read` normal.
