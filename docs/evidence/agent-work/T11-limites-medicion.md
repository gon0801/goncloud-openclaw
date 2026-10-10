# T11-a. Medición para el perfil productivo de `limits.json`

Medido el 2026-10-09 sobre la copia `~/respaldos/claw-mini-copia-20261009-1255` (gateway Mac Mini, OpenClaw 2026.9.7, `schema_meta` = `primary|global|19||2026.9.7`). Todas las bases se abrieron en modo `file:<ruta>?immutable=1`. No se escribió en la copia ni en ningún repo. Ningún secreto de `openclaw.json` aparece aquí.

Código de referencia: R = `/Users/dn/dev/openclaw-agent-work-integration` en `818f0fdacfb`. Los defaults de subagentes no cambian entre el tag `v2026.9.7` y ese commit (`git diff --stat v2026.9.7 HEAD -- src/config/agent-limits.ts src/config/zod-schema.agent-defaults-base.ts src/agents/spawn-plan.ts` vacío).

Script reproducible: `/Users/dn/.local/state/encargos-loop/artifacts/T11-a/medir.py` (stdout = medición principal; escribe `medicion-extra.json` en el directorio actual).

## 0. Qué mide cada campo en R

Fuente: `src/agents/tasks/managed-task.budget.worker.ts` y `managed-task.provider-stream.ts`.

| Campo | Alcance | Regla en código |
|---|---|---|
| maxConcurrentTasks | por raíz | admisiones `claimed/admitted` del mismo root que retienen ranura; la raíz con target agente retiene ranura hasta tener resultado (`host-closure.worker.ts:84-109`). worker.ts:126 |
| maxDepth | por raíz | `depth + 1 > maxDepth`, hijo directo de la raíz = profundidad 1. worker.ts:159 |
| maxChildren | por raíz, total | filas de `managed_task_children` del root (no solo activas). worker.ts:146 |
| maxModelCalls | por raíz, total | reservas de modelo del árbol. worker.ts:485 |
| maxInputTokens | por raíz, total | `used.input + context`; liquidado `inputTokens = input + cacheRead + cacheWrite` (provider-stream.ts:240). worker.ts:486 |
| maxOutputTokens | por raíz, total | `used.output + outputLimitTokens`; la reserva usa `max_tokens`/`max_output_tokens` del payload, no la salida real. worker.ts:487 |
| maxCacheReadTokens | por raíz, total | `used.cache + context`; en vuelo se reserva el contexto completo como caché. worker.ts:488 |
| maxContextTokens | por llamada | `context > maxContextTokens`. **La unidad real es bytes UTF-8 del cuerpo HTTP** (`historyTokens: Buffer.byteLength(wireBody ?? serialized)`, provider-stream.ts:147-150). Debe ser ≤ maxInputTokens (worker.ts:87). |
| maxTreeTokens | por raíz, total | `used.input + used.output + context + outputLimit`. worker.ts:489-490 |
| maxAutomaticRecoveryCalls | por raíz | zod `min(0).max(1)` (`zod-schema.managed-tasks.ts`). |

Solo están certificadas las llamadas al proveedor `openai` por HTTP en `api.openai.com`, con las API `openai-completions` u `openai-responses` (provider-stream.ts:116-121, `createManagedNativeProviderStream`). Que otro proveedor use esas API, como `opencode-go-*`, no lo certifica. `anthropic-messages` y el runtime `claude-cli` lanzan "not budget-certified".

## 1. Configuración efectiva

Consulta (Python, sin imprimir llaves secretas): `json.load(open('openclaw.json'))`, rutas `agents.defaults`, `agents.entries.<id>.{model,subagents}`, `models.providers.<p>.{api,models[].{id,api,contextWindow,maxTokens}}`. Conteo de cadenas en el JSON: `maxConcurrent` 0, `maxSpawnDepth` 0, `maxChildren` 0, `managedTasks` 0.

Límites de delegación. `agents.defaults` tiene solo `workspace, model, models, systemAgent, heartbeat`. No hay bloque `subagents`, así que rigen los defaults del código:

| Ajuste | Valor efectivo | Fuente |
|---|---|---|
| agents.defaults.subagents.maxConcurrent | 8 (por sesión controladora) | ausente en config; `DEFAULT_SUBAGENT_MAX_CONCURRENT = 8` (`src/config/agent-limits.ts:25`), materializado en `src/config/defaults.ts:494` |
| agents.defaults.subagents.maxSpawnDepth | 5 (desde la sesión principal) | ausente; `DEFAULT_SUBAGENT_MAX_SPAWN_DEPTH = 5` (agent-limits.ts:31), usado en `spawn-plan.ts:300-301` |
| agents.defaults.subagents.maxChildrenPerAgent | 5 (hijos activos por sesión) | ausente; `DEFAULT_SUBAGENT_MAX_CHILDREN_PER_AGENT = 5` (agent-limits.ts:27), `spawn-plan.ts:325-326` |
| agents.defaults.maxConcurrent | `unknown` | ausente; default `max(8, 4 × CPUs)` (agent-limits.ts:6-21). La copia no dice cuántos CPU tiene la Mac Mini. |
| runTimeoutSeconds de subagentes | 0 en las corridas registradas | `subagent_runs.payload_json.runTimeoutSeconds` |
| allowAgents | main: 19 agentes; operaciones: [odoo]; resto sin clave | `agents.entries.<id>.subagents.allowAgents` |

Modelo primario y ventana por agente:

| Agente | Primario | API | contextWindow | maxTokens |
|---|---|---|---|---|
| main | opencode-go-resp/muse-spark-1.3-contributor | openai-responses | 1048576 | 131072 |
| ingenieria | opencode-go-resp/muse-spark-1.3-contributor | openai-responses | 1048576 | 131072 |
| implementer | opencode-go-resp/muse-spark-1.3-contributor | openai-responses | 1048576 | 131072 |
| operaciones | opencode-go/deepseek-v4.1-flash | no declarada en config; observada `openai-completions` en transcripts | `unknown` | 8192 |
| reviewer | opencode-go/deepseek-v4.1-flash | igual | `unknown` | 8192 |
| adversary | opencode-go/deepseek-v4.1-flash | igual | `unknown` | 8192 |
| verifier | opencode-go/deepseek-v4.1-flash | igual | `unknown` | 8192 |
| scout | opencode-go/deepseek-v4.1-flash | igual | `unknown` | 8192 |

Para `deepseek-v4.1-flash` la config no declara `contextWindow`. Sin entrada de catálogo, `src/config/defaults.ts:293-300` usa `DEFAULT_CONTEXT_TOKENS = 200000` solo para calcular maxTokens; no encontré el modelo en el catálogo de R (`grep -rln deepseek-v4.1-flash src extensions` vacío). La ventana efectiva queda `unknown`.

Los fallbacks incluyen `kimi/k3` (`anthropic-messages`) y `anthropic/*` con `agentRuntime: claude-cli`. Esas rutas no se pueden presupuestar en modo gestionado.

## 2. Consumo medido

### Fuentes en las bases

- `openclaw.sqlite`, tabla `subagent_runs` (885 filas, 2026-09-23 06:46 a 2026-10-09 19:38 UTC). Guarda árbol y tiempos, no tokens. `task_runs` con `runtime='subagent'` (1338) no tiene `usage` en `detail_json`; solo las 3152 de `cron` lo tienen.
- `agent-<id>.sqlite`, tablas `transcript_events` (`event_json` o `event_zstd`) y `session_transcript_archives` (`archive_blob` zstd, JSONL). Cada mensaje `role=assistant` con `usage` es una llamada al modelo, con `__openclaw.runId`.
- `session.maintenance.pruneAfter = 1d` borra sesiones; sus transcripts sobreviven en `session_transcript_archives` (`reason='deleted'`). De 1818 sesiones de subagente archivadas, 1804 traen `cwd` de Windows: casi toda la historia viene del gateway Windows anterior, con los mismos agentes.
- `trajectory_runtime_events` (`model.completed`) da uso agregado por corrida; sirvió de control cruzado, no de fuente.
- Ninguna tabla guarda bytes del cuerpo HTTP enviado al proveedor.

Consultas exactas:

```sql
-- descubrimiento
.tables
PRAGMA table_info(subagent_runs); PRAGMA table_info(task_runs);
PRAGMA table_info(transcript_events); PRAGMA table_info(session_transcript_archives);
SELECT runtime, count(*), sum(detail_json like '%usage%') FROM task_runs GROUP BY runtime;
-- registro de subagentes
SELECT run_id, child_session_key, requester_session_key, controller_session_key, created_at, payload_json FROM subagent_runs;
-- llamadas al modelo (por agente)
SELECT current_session_id, session_key FROM session_nodes;
SELECT session_id, json_extract(event_json,'$.sessionKey') FROM trajectory_runtime_events
  WHERE json_extract(event_json,'$.sessionKey') IS NOT NULL GROUP BY session_id;
SELECT session_id, event_json, event_zstd FROM transcript_events ORDER BY session_id, seq;
SELECT session_id, session_key, archive_blob FROM session_transcript_archives;
-- anidamiento
SELECT run_id, child_session_key, requester_session_key, datetime(created_at/1000,'unixepoch')
  FROM subagent_runs WHERE requester_session_key LIKE '%:subagent:%';
```

Normalización, igual a `provider-stream.ts:240`: entrada por llamada = `input + cacheRead + cacheWrite`. Una corrida = (sessionKey de subagente, runId). Árbol del registro = corrida cuyo solicitante no es sesión de subagente, más sus descendientes.

### Totales

- Llamadas de asistente con `usage`: 40855; de sesiones de subagente: 35646 (1532 con uso cero, errores). Fechas: 2026-09-23T06:47Z a 2026-10-09T19:41Z.
- Corridas de subagente con uso: 1923 (ingenieria 1679, scout 114, implementer 72, reviewer 24, odoo 12, operaciones 10, main 4, verifier 4, pers 2, amazon 1, mail 1). El registro solo cubre 885 corridas; 814 de ellas tienen uso.
- Modelos usados en llamadas de subagente: opencode-go-resp/muse-spark 24229, opencode-go-resp-2/muse-spark 7597, opencode-go/deepseek 1769, openai/gpt-5.6-sol 1514, kimi/k3 (anthropic-messages) 382, zai/glm-5.3-flash 140, claude-cli/claude-opus-5 7, otros 8.

### Atípicos

Tres llamadas de `openai/gpt-5.6-sol` (ingenieria, 2026-09-28 02:03, 03:24 y 05:07 UTC) reportan entrada de 1,06 M, 22,6 M y 55,9 M tokens. Ninguna petición única cabe así en la ventana mayor declarada (1048576), así que parecen uso agregado del proveedor. Las excluí solo del máximo de contexto por llamada. No afectan los máximos por corrida, que vienen de muse-spark.

### Por corrida de subagente (n = 1923)

| Métrica | mediana | p95 | máximo |
|---|---|---|---|
| llamadas al modelo | 5 | 65 | 1440 |
| entrada (input+cacheRead+cacheWrite) | 112460 | 3495223 | 445540546 |
| salida | 2324 | 27681 | 252098 |
| cache read | 90918 | 3397030 | 440339646 |
| contexto máx. por llamada (sin atípicos, n=1920) | 27872 | 100179 | 568939 |
| salida máx. por llamada (sin atípicos) | 884 | 7392 | 24944 |
| árbol (entrada + salida) | 114248 | 3514452 | 445792644 |

Por llamada (n = 35643 sin atípicos): entrada mediana 68232, p95 333323, máx. 568939; salida mediana 199, p95 1215, máx. 102252 (atípico incluido).

Corridas más grandes: ingenieria 2026-09-29 03:43-05:34, 1440 llamadas, 445,8 M; implementer 2026-09-26, 1222 llamadas, 353,8 M; implementer 2026-10-09, 970 llamadas, 282,5 M. 34 corridas pasan de 200 llamadas y 16 de 50 M tokens.

### Árboles y concurrencia

- Árboles del registro: 877 raíces. 8 corridas tienen solicitante subagente; sus padres ya no están en `subagent_runs`, así que los reconstruí por `requester_session_key`.
- Cuatro árboles anidados, todos de ingenieria, del 2026-09-25 al 26: hijos 4, 2, 1 y 1; profundidad 1 en todos (ningún nieto); hijos simultáneos máx. 2, es decir 3 contando la raíz (c0689b4a). Uso del árbol completo: 140 a 153 llamadas, 3,8 M a 19,2 M tokens; solo 1 de los 4 tiene uso completo de todos sus miembros.
- Concurrencia nativa por sesión solicitante: máx. 4 (`agent:main:main`).
- Árboles del registro con uso completo (n = 813): llamadas mediana 10, p95 138, máx. 1222; árbol mediana 296171, p95 10663709, máx. 353780796.

Límite de cobertura. El registro perdió filas (885 frente a 1923 corridas con uso), así que el anidamiento puede estar subcontado. Los máximos de consumo por corrida no dependen del registro.

### No medible en la copia

- Bytes UTF-8 del cuerpo HTTP por llamada, que es la unidad real de `maxContextTokens`: `unknown`. Los tokens medidos son solo una cota inferior.
- `max_tokens`/`max_output_tokens` enviado en cada payload: `unknown`. La cota de config es 131072 (muse-spark) y 8192 (deepseek).
- CPU de la Mac Mini, que define `agents.defaults.maxConcurrent`: `unknown`.

## 3. Perfil propuesto

Regla general para totales del árbol: máximo observado por corrida × 1,5, redondeado hacia arriba a 3 cifras significativas. Conteos: `ceil(máx. observado × 1,5)`, acotado por el límite nativo cuando existe.

| Campo | Valor | Regla y fuente |
|---|---|---|
| maxConcurrentTasks | 5 | máx. observado en un árbol 3 (raíz + 2 hijos, c0689b4a) × 1,5 = 5; ≤ subagents.maxConcurrent efectivo 8 |
| maxDepth | 2 | máx. observado 1 × 1,5 = 2; ≤ 4 (maxSpawnDepth 5 menos el nivel que ocupa la raíz bajo main) |
| maxChildren | 6 | máx. observado 4 hijos totales (99edf82b) × 1,5 = 6. No hay tope nativo de hijos totales; maxChildrenPerAgent 5 es de activos |
| maxModelCalls | 2160 | máx. 1440 llamadas por corrida × 1,5 |
| maxInputTokens | 669000000 | máx. 445540546 × 1,5 |
| maxOutputTokens | 510000 | máx. 252098 × 1,5 + 131072 (reserva de una llamada al maxTokens de muse-spark) |
| maxCacheReadTokens | 661000000 | máx. 440339646 × 1,5 |
| maxContextTokens | null | la unidad aplicada son bytes del cuerpo HTTP y la copia no los guarda. Cota inferior 568939 tokens; ventana declarada 1048576 (muse) y `unknown` (deepseek) |
| maxTreeTokens | 669000000 | máx. 445792644 × 1,5 |
| maxAutomaticRecoveryCalls | 1 | política del spec ("como máximo una recuperación automática adicional con modelo por raíz") = tope del schema zod `max(1)` |

Consecuencia. Con `maxContextTokens = null` el perfil no pasa `ManagedTaskBudgetProfileSchema` ni `validateProfile`, y toda reserva de modelo lo consulta. `productionAdmissionEnabled` debe seguir en `false` hasta medir bytes de cuerpo por llamada, por ejemplo registrando `Buffer.byteLength(wireBody)` en modo sombra en el mismo punto donde hoy se reserva.

Lectura franca de los valores. La regla de máximo × 1,5 deja topes de cientos de millones de tokens por encargo. Solo frenan un desborde peor que la peor corrida vista, una sesión de ingenieria de 1440 llamadas. Una regla de p95 × 1,5 (98 llamadas, 5,3 M de árbol) frenaría a cerca del 5 % de las corridas observadas. Elegir entre las dos es decisión del operador, no un dato.

Otras restricciones fuera de los 10 campos:

- Los primarios de los 8 agentes usan API `openai-*`, pero ninguno es el proveedor `openai`, así que no son certificables (fila B5/T12 de `followups.md`). Los fallbacks `kimi/k3` y `claude-cli` no lo son: una caída a ellos dentro de un encargo gestionado falla por diseño.
- `maxContextTokens ≤ maxInputTokens` se cumplirá con cualquier valor de bytes razonable.
