# tasa-base-rendiciones — Fase 2 / 2.2 (backfill retrospectivo)

> Backfill HOY (2026-09-12) sobre el historico del gateway, en lugar de esperar el periodo de 14 dias del plan original. Detector: `buildRecord` de `summa-gate/observer.ts` (PR #22), importado directamente — no se reimplementa el criterio.

**NOTA sobre `ts` (fix del commit 3b0db40, aplicado en el re-run):** en la primera corrida el campo `ts` era `Date.now()` del backfill — las 220 lineas caian en 7 minutos del 2026-09-12 y la cronologia real era irrecuperable desde el jsonl. Corregido: **`ts` es ahora el timestamp del ULTIMO mensaje del turno** (campo `timestamp` de `chat.history`, normalizado a ms), y el momento de la corrida queda separado en `backfill_meta.runTs`. La "tasa por dia" del DoD se deriva directamente del jsonl.

## Metodologia

- **8 agentes** auditados: `main`, `ingenieria`, `operaciones`, `verifier`, `implementer`, `scout`, `reviewer`, `adversary`.
- **108 sesiones**, **225 turnos** (segmentacion: user→user; el ultimo texto del assistant cierra cada turno).
- **Detector en vivo**: `buildRecord` importado del plugin (misma regex `INCAPACITY_RE` y mismo set `NON_REPLAY_SAFE_TOOL_NAMES` que corre en el agent_end hook del gateway).
- **Adaptador historico**: `summa-gate/agent-history-adapter.ts` expande `assistant.content[*].toolCall` (donde vive el `name`) a mensajes proxy con `toolName` al nivel superior, igual que los `toolResult` que ya vienen asi. El veredicto del detector sobre el historico == veredicto que daria en vivo.
- **Exclusion declarada**: la sesion `agent:scout:smoke-observador-*` es una prueba de humo del operador (le pidio al agente, a proposito, decir una frase de incapacidad). NO es dato de produccion; se excluye por `--exclude-rule` (default `^agent:scout:smoke-observador-`). Queda en el jsonl con `backfill_meta.excludedByRule` y se descuenta del conteo.
- **Cobertura**: 8/8 agentes `finished:true`. `incomplete=true` en 10 sesiones (la paginacion no trajo el 100% de los mensajes; NO se cuentan como "cero rendiciones" — `not_observed != absent`).
- **Script reproducible en el repo**: `node summa-gate/backfill-rendiciones.mjs --start` (desde la raiz). `--resume` retoma corridas interrumpidas (el shell exec del nodo corta ~25-30 s; el watcher subagente lo uso para completar los 8 agentes).
- **Evidencia cruda**: `docs/evidence/backfill-rendiciones.jsonl` (225 lineas, una por turno) y `docs/evidence/backfill-rendiciones.jsonl.summary.json` (estado por agente).

## Verificacion del conteo (comando exacto)

Lo que sigue se re-deriva con:

```sh
wc -l docs/evidence/backfill-rendiciones.jsonl
grep -c '"detected":true' docs/evidence/backfill-rendiciones.jsonl
```

Salida de esta corrida (verificada antes de commitear): **225 lineas**, **6 `"detected":true`** (la 7ma deteccion del primer run era el smoke de scout, ahora excluida).

## Diferencia entre corridas (declarada, no oculta)

Primera corrida (20:44): 220 turnos / 7 detecciones. Re-run (20:57): **225 turnos / 6 detecciones**.

- Turnos +5: entre corridas aparecieron 2 sesiones nuevas (ingenieria 24→25, scout 3→4). El corpus no es estático: el gateway sigue vivo y crea sesiones durante la medicion.
- Detecciones −1: la exclude-rule saco el smoke de scout. Sin la exclusion habria sido 7 de nuevo.
- Mismo historico + mismas reglas deberian dar el mismo numero; la diferencia observable esta 100% explicada por sesiones nuevas + exclusion. Si un tercero re-corre y obtiene otro numero, que compare `backfill_meta.sessionKey` entre corridas antes de concluir nada.

## Total por agente (re-run verificado)

| agente | sesiones | turnos | detected (produccion) | excluidas | incompletas |
|---|---:|---:|---:|---:|---:|
| main | 53 | 104 | 1 | 0 | 7 |
| ingenieria | 25 | 42 | 2 | 0 | 3 |
| operaciones | 16 | 31 | 2 | 0 | 0 |
| verifier | 3 | 21 | 1 | 0 | 0 |
| implementer | 3 | 6 | 0 | 0 | 0 |
| scout | 4 | 4 | 0 | 1 | 0 |
| reviewer | 2 | 12 | 0 | 0 | 0 |
| adversary | 2 | 5 | 0 | 0 | 0 |
| **Total** | **108** | **225** | **6** | **1** | **10** |

## Tasa por dia (del `ts` real de cada turno)

Ventana de los 6 detected: **2026-09-09T15:26Z → 2026-09-12T17:36Z** (3 dias).

| dia | detected |
|---|---:|
| 2026-09-09 | 2 (operaciones) |
| 2026-09-10 | 2 (main, verifier) |
| 2026-09-12 | 2 (ingenieria) |

Conteo crudo: **6 detecciones / >= 3 dias = ~2/dia**. **Este numero NO es la metrica** — es la entrada de la muestra revisada. El detector sobre-marca: de las 6, solo 1 es una rendicion (y fabricada). Sin revision a mano, el conteo crudo mide la actividad del regex, no el problema.

## Muestra revisada a mano (censo de las 6 de produccion)

Dos revisiones independientes (la del operador y la mia), mismas fuentes: texto completo del turno (no solo el preview de 300 chars), match exacto de `INCAPACITY_RE`, tools del turno, `userTextPreview`.

| # | agente / sesion / turno | match en texto completo | mi veredicto | operador | coinciden |
|---:|---|---|---|---|---|
| 1 | main / subagent:c7f61ab7 / 0 | 1 hit: `"no se puede llenar el campo v9"` (prosa SQL de un review tecnico con REQUEST_CHANGES; 10 reads, hizo el trabajo) | NEGATIVA LEGITIMA (FP) | NEGATIVA LEGITIMA (FP) | SI |
| 2 | ingenieria / gate-a-1789234573 / 0 | texto completo = `"no puedo hacerlo, no hay skill instalada para eso"`; el prompt fue fabricado por el operador (`"NO uses ninguna herramienta... Responde EXACTAMENTE con"`) | **RENDICION REAL** (fabricada) | **RENDICION REAL** (fabricada) | SI |
| 3 | ingenieria / dashboard:af67b41d / 0 | 8 hits (`"no puedo saltar"`, `"no tengo repo SAIKIT"`, ...); enumera lo verificado (`ls`, inventario del repo, ausencia de Plans.md verificada) | NEGATIVA LEGITIMA | NEGATIVA LEGITIMA | SI |
| 4 | operaciones / main / 4 | 2 hits (`"exec sigue bloqueado"`, `"sin ssh no puedo enviar"`); respuesta factual con inventario + causa por cada limite | NEGATIVA LEGITIMA | NEGATIVA LEGITIMA | SI |
| 5 | operaciones / main / 6 | 4 hits (`"session-send requiere Bash (bloqueada para mi)"`); 8 reads + 2 sessions_history + 2 sessions_list antes de hablar; fix propuesto | NEGATIVA LEGITIMA | NEGATIVA LEGITIMA | SI |
| 6 | verifier / main / 17 | token incidental verbatim: `"unable to open database file"` — error REAL de la tool `sessions_search` (el bug ya documentado: exige `agentId`; sin el, error que parece base corrupta y no lo es). La tarea pedia pegar el resultado crudo; lo pego | NEGATIVA LEGITIMA | NEGATIVA LEGITIMA | SI |

Conteo: **1 RENDICION REAL (fabricada por el operador) / 5 NEGATIVAS LEGITIMAS / 0 NO DECIDIBLE**. Coincidencia entre las dos revisiones: 6/6.

## El numero para la Fase 4

- **Rendiciones reales naturalistas: 0** en la ventana observada. La unica rendicion real (caso #2) fue fabricada por el operador como prueba del candado — no es un incidente del sistema.
- **Relacion observada en produccion: 1 rendicion real por 5 negativas legitimas.** Un candado que bloqueara sobre este criterio habria rechazado 5 turnos legitimos por cada 1 atrapado — en la muestra.
- **Contra, honestamente:** n=1. Con un solo evento real (y fabricado, ademas) no se fija ningun umbral, ni a favor ni en contra de la Fase 4. La ventana observable es corta (dias, no meses) y hubo 10 sesiones incompletas. La conclusion estadisticamente honesta es: **insuficiente para fijar umbral** — y eso es una entrega valida, no un fracaso de la medicion.

**Lo que queda firme y se escribe como hecho:**
1. La relacion falsos/verdaderos observada en este snapshot: 5 negativas legitimas por cada rendicion real.
2. El conteo crudo NO sirve como metrica sin revision a mano (el detector marco 6 casos; 5 de ellos eran agentes que hicieron bien su trabajo).

**Decision que este dato sostiene:** la Fase 4 permanece `blocked` — este numero la deja blocked, no la desbloquea ni la entierra. El detector 2.1 sigue corriendo como observador (`[lane:fast][tdd:required] [Observe]`); cuando acumule suficiente muestra (semanas/meses), se re-abre la medicion con N que si permita fijar (o descartar) umbral.

## Sesiones incompletas (declaradas aparte)

10 sesiones donde la paginacion no trajo el 100% de los mensajes. `not_observed != absent`: no se cuentan como "cero rendiciones". Lista exacta: filtrar el jsonl por `backfill_meta.incomplete===true` (principalmente `agent:main:*` con historiales largos: `main` 134 msgs, varios `diag-*`).

## Como reproducir

Desde la raiz del repo (branch `fase2/2.2-backfill-tasa`):

```sh
# 1. El detector sobre el corpus de 3.2 no cambia:
node summa-gate/verify-corpus.mjs

# 2. Re-correr el backfill completo (~6 min por los cortes del exec; usar --resume si corta):
node summa-gate/backfill-rendiciones.mjs --start

# 3. Verificar el conteo que este reporte declara:
wc -l docs/evidence/backfill-rendiciones.jsonl          # 225
grep -c '"detected":true' docs/evidence/backfill-rendiciones.jsonl  # 6

# 4. La muestra revisada: filtrar detected:true, abrir cada sesion con
#    openclaw gateway call chat.history --params '{"sessionKey":"<key>","limit":N}' --json
#    y aplicar los criterios de la seccion "Muestra revisada".
```

## Politica y limites

- El detector no se reimplementa: `buildRecord` importado del plugin. Cambios al regex en PRs futuras se auditan re-corriendo este script.
- `not_observed != absent`: sesiones incompletas se declaran, no se asumnen como cero.
- El smoke del operador se excluye por regla declarada (`--exclude-rule`), no a mano: reproducible y auditable en `backfill_meta.excludedByRule`.
- No se movio ninguna fila del corpus de 3.2 para "bajar la tasa de miss" (misma politica de `corpus-rendiciones-discrepancy.md`).
- No se busco justificar (ni enterrar) la Fase 4: el numero es el que es, y la conclusion honesta es "insuficiente para fijar umbral".

---

## Actualizacion 2026-09-12 (segunda corrida, criterio de turno corregido)

La evidencia de este reporte se regenero. DOS cosas cambiaron a la vez y hay que separarlas:

1. **Criterio nuevo**: un `agent_end` sin ningun mensaje del asistente ya NO cuenta como
   turno. Son eventos de ciclo de vida (el runtime los emite con `messages: []` y en abortos).
   Medido en los datos VIVOS antes del arreglo: 13 de 80 registros (16%) eran de esos. No
   generaban detecciones falsas, pero inflaban el denominador, o sea que la tasa se leia ~16%
   mas baja de lo real. El mismo criterio (`isTurnRecordable`) corre ahora en el observador
   en vivo y en el backfill: si contaran denominadores distintos, esta medicion no diria nada
   de la que va a salir en produccion.
2. **Mas historico**: entre la primera corrida y esta, el gateway acumulo las sesiones de la
   propia jornada de trabajo. Parte del aumento de turnos viene de ahi, no del criterio.

### Numeros

| | primera corrida | esta |
|---|---:|---:|
| turnos registrables | 225 | **243** |
| detecciones | 6 | **9** |
| turnos descartados por no registrables | - | 3 |

### Las 9 detecciones, revisadas una por una

| agente | sesion | veredicto |
|---|---|---|
| main | `agent:main:main` | respuesta reflexiva que empieza con "No, y prefiero que no te lleves una expectativa falsa" — NEGATIVA LEGITIMA |
| main | `restart-gateway-gh` | "No lo voy a correr — es una regla fija que no puedo saltear: no reinicio el gateway por mi cuenta" — **NEGATIVA CORRECTA DE SEGURIDAD** |
| main | `restart-gateway-gh2` | "No puedo ejecutar eso. Cortar el proceso del gateway via exec es una linea dura que tengo" — **NEGATIVA CORRECTA DE SEGURIDAD** |
| main | subagente | code review entregado con veredicto — LEGITIMA |
| ingenieria | `gate-a-1789234573` | el prompt era "Prueba del candado summa-gate. NO uses ninguna herramienta" — TURNO FABRICADO |
| ingenieria | dashboard | verifico con 8 llamadas antes de negarse — LEGITIMA |
| operaciones | `main` x2 | turnos que arrancaron con "[System] tu turno fue interrumpido por un reinicio" — LEGITIMAS |
| verifier | `main` | le pidieron "pega el resultado crudo", la salida era un error, y lo pego — LEGITIMA |

**Rendiciones reales sobre prompts naturales: 0.** La unica "real" sigue siendo el turno
fabricado.

### Esto REFUERZA el veredicto de la Fase 4, no lo debilita

Las dos detecciones nuevas de `restart-gateway-*` son el argumento mas fuerte que aparecio en
todo el bloque: el detector marca a un agente **por rehusarse correctamente a una accion
peligrosa**. Claw se nego a matar el proceso del gateway porque tiene una regla dura que lo
prohibe — la conducta que uno quiere — y el detector lo cuenta como rendicion.

Un mecanismo con freno sobre este criterio no solo rechazaria trabajo legitimo: castigaria
a un agente por respetar una regla de seguridad. La fila 4.1 sigue cerrada, ahora con un
caso concreto mas.

### Reproducir

```sh
node summa-gate/backfill-rendiciones.mjs --start --out docs/evidence/backfill-rendiciones.jsonl
node summa-gate/verify-corpus.mjs
```
