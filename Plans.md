# Plans

## Purpose

Que un agente no le haga perder una noche a David concluyendo "no se puede" sin haberlo intentado — y que la solución no cueste más que el problema. El intento anterior (candado en `before_agent_finalize`, PR #15) se revirtió en PR #16 tras 4 hallazgos altos del adversary. Este plan sale de esos hallazgos más dos revisiones independientes (reconocimiento del runtime + escéptico), y **cambia de mecanismo**: no se rehace el candado.

## Veredicto de la planificación

**No rehacer el bloqueo.** Tres razones medidas, no opinadas:

1. **El hook no puede actuar donde importa.** El `revise` de `before_agent_finalize` se descarta ante cualquier herramienta que no sea de solo lectura — un `exec` o un `write` basta (`builtin-openclaw-B-H-7lKk.mjs:2488, 3513, 9884, 13040`; lista blanca en `tool-mutation-D3ot3Ltc.mjs:50-62` con `case "exec": case "bash": return false`). Su dominio vivo son los turnos donde el agente no hizo nada.
2. **El texto no distingue el error.** La frase del incidente ("no hay skill instalada para eso") **era verdadera**: la skill de ese commit no cubría teclear en una tty. Lo falso fue la inferencia "no hay skill ⇒ imposible", que no aparece en el texto. Un detector léxico vigila la parte cierta.
3. **Esfuerzo no es acierto.** En este mismo repo hay un caso documentado (`agents/ingenieria/agent/workshop-skills/mac-node-ops/locate-session-cwd.md:95-111`) donde el agente SÍ corrió comandos, tuvo evidencia, y concluyó mal — y por tener evidencia su conclusión resultó más creíble. El discriminador "¿lo intentaste?" tiene 100% de miss en el caso más caro.

**Y falta el dato que decide todo:** nadie sabe la tasa base. No se sabe si esto pasa 2 veces al mes o 20 al día. Se construyó un freno de producción con N=2 anécdotas.

`team_validation_mode: subagent` — adversary (8 hallazgos), scout (28 hechos con cita), escéptico.

## Spec skip reason

No se toca `spec.md` (este repo no tiene uno y no se crea aquí): ninguna task cambia comportamiento de producto visible para David, API, datos, permisos ni cobros. F.1 y F.2 son observación y documentación; F.3 es una regla de redacción en skills. Si en F.4 se decidiera construir un mecanismo que bloquea, ESA task sí requiere `Spec delta` antes de implementarse.

---

## Fase 1 — Lo urgente (afecta algo vivo hoy)

| Task | Contenido | DoD | Depends | Status |
|---|---|---|---|---|
| 1.1 | `[lane:gate] [tdd:skip:medición-solo-lectura]` **Medir si el gate de recibo vivo es teatro.** El gate de cierre de summa-gate (`index.ts:415-489`) usa el mismo camino que el candado revertido. Contar en los logs del gateway `summa-gate: revise solicitado` contra `before_agent_finalize requested revision after potential side effects`, sobre la ventana más larga que el CLI permita (`logs --limit 5000 --max-bytes 900000`, ~45 min) repetida durante 3 días. | Un archivo `docs/evidence/gate-recibo-descartes.md` con: conteo de ambas líneas por corrida, fecha/hora de cada muestra, y el cociente descartados/solicitados. Si el cociente ≥ 0.8, la conclusión "el gate de recibo no bloquea en turnos de trabajo" queda escrita como hecho con su evidencia. `not_observed != absent`: si no hubo ninguna solicitud en la ventana, se registra como `unknown`, no como 0. | - | cc:完了 |
| 1.2 | `[lane:gate] [tdd:required]` **Decidir qué hacer con el gate de recibo** según 1.1. Si está siendo descartado: o se mueve su exigencia al contrato inyectado en `before_prompt_build` (que es lo que sí funciona), o se documenta explícitamente que solo actúa en turnos sin herramientas mutantes. No dejarlo como está creyendo que bloquea. | El código o el comentario de `index.ts:415-489` declara su alcance real con la cita del runtime que lo limita. Si se cambia comportamiento, prueba que falle contra la versión anterior. | 1.1 | cc:完了 |

## Fase 2 — Medir antes de frenar

| Task | Contenido | DoD | Depends | Status |
|---|---|---|---|---|
| 2.1 | `[lane:fast] [tdd:required]` **Observador, no candado.** Handler `agent_end` en summa-gate (hook de tipo Observe: no puede rechazar nada) que registra a `~/.openclaw/summa-gate/rendiciones.jsonl` los turnos que terminan con cero herramientas no-replay-safe y texto con forma de incapacidad. Cada línea: timestamp, `sessionKey`, agente, `inputProvenance.kind`, si hubo `read` de algún `SKILL.md` en el turno, conteo de herramientas por tipo, y los primeros 300 caracteres del texto final. | El handler no devuelve nunca una acción que pueda alterar el turno (verificable leyendo el código: `agent_end` es Observe por tipo). Prueba unitaria que, dado un evento sintético, produce la línea jsonl esperada. Prueba de mutación: borrar el filtro de herramientas deja la batería en rojo. | - | cc:TODO |
| 2.2 | `[lane:fast] [tdd:skip:análisis-de-datos]` **Leer el medidor a los 14 días.** Contar cuántas rendiciones hubo, por agente, y cuántas resultaron falsas (el trabajo sí se podía) revisando una muestra a mano. | `docs/evidence/tasa-base-rendiciones.md` con: total por agente, tasa por día, y la muestra revisada con su veredicto. El número de "falsas rendiciones por semana" queda escrito. | 2.1 | cc:TODO |

## Fase 3 — Lo que sí ataca el problema (texto, fail-open)

| Task | Contenido | DoD | Depends | Status |
|---|---|---|---|---|
| 3.1 | `[lane:fast] [tdd:required]` **Regla del artefacto re-derivable.** En el AGENTS.md de `ingenieria` (y en la skill `mac-node-ops`): una declaración de imposibilidad no vale como prosa. Tiene que traer el comando exacto que se corrió y su salida verbatim, para que un tercero pueda re-derivarla. Sin eso, no es un bloqueo: es una suposición. Es la misma disciplina que ya existe en `locate-session-cwd.md:150-153` ("the artifact a verifier re-derives, not prose"). | Sección nueva con anclas de frase exacta y su prueba `.ps1`, verificada en rojo contra `origin/master`. La prueba incluye un anti-ancla que rechaza redacciones que permitan declarar imposible sin evidencia. | - | cc:TODO |
| 3.2 | `[lane:fast] [tdd:skip:docs-only]` **Corpus etiquetado, gratis.** Extraer de `.saikit/findings/adversary-20260912T175152Z.json` los 23 textos que deberían detectarse y los 8 legítimos que no, a `docs/evidence/corpus-rendiciones.tsv` con su etiqueta. Sirve como línea base para cualquier mecanismo futuro y para medir 2.2. | El TSV existe con 31 filas etiquetadas y su procedencia (hallazgo de origen) en cada una. | - | cc:TODO |

## Fase 4 — Solo si el medidor lo justifica

| Task | Contenido | DoD | Depends | Status |
|---|---|---|---|---|
| 4.1 | `[lane:release] [tdd:required]` **Mecanismo con freno, condicionado.** Solo se abre si 2.2 mide una tasa que lo justifique. Requiere `Spec delta` previo. Criterios innegociables: (a) umbral fijado sobre el corpus de 3.2, no sobre intuición; (b) prueba de mutación obligatoria — si borrar la rama principal deja la batería en verde, la batería no vale; (c) alcance acotado por `inputProvenance`, nunca el chat de main con David; (d) nada que rechace un cierre antes de tener la tasa base. | No aplica todavía. Esta fila queda `blocked` hasta que 2.2 entregue el número. | 2.2, 3.2 | blocked |

---

## Clasificación

**Required:** 1.1, 1.2 (afectan algo vivo), 2.1, 2.2 (sin el número no se decide nada), 3.1 (es lo único que atacó el incidente de verdad).

**Recommended:** 3.2 (barato, habilita todo lo demás).

**Optional:** ninguna.

**Reject, con razón:**
- *Rehacer el candado con regex mejorados.* El error es de dos lados por construcción: un léxico amplio bloquea verdades (5 de 8 textos legítimos), uno angosto se rompe cambiando una palabra (23 de 23 se escapan). El rasgo que distingue no es léxico.
- *Clasificador LLM para bloquear.* Una llamada al modelo por turno, dentro de un presupuesto de 15 s, en una flota donde 4 de 5 cuotas son invisibles y el fallback mata trabajo en vuelo (`docs/briefs/2026-09-11-problema-fallback-destructivo.md`). Aceptable para observar; inaceptable para bloquear.
- *Contar `exec` como prueba de esfuerzo.* `echo hola` lo desarma, y el mutante `cuenta-cualquier-tool` ya sobrevivió a la batería anterior en verde.

## 事前確認

- Evento: escritura de `~/.openclaw/summa-gate/rendiciones.jsonl` en el host del gateway
  Razón: es la salida del medidor de la task 2.1
  scope: Fase 2 / Task 2.1
- Evento: lectura de los logs del gateway con `openclaw logs`
  Razón: 1.1 necesita contar las dos líneas del runtime
  scope: Fase 1 / Task 1.1
- Evento: `git push` de rama + `gh pr create` en `goncloud-openclaw` y `goncloud-workspace-ingenieria`
  Razón: entrega de 1.2, 2.1, 3.1 y 3.2
  scope: Fases 1-3

No hay secret-read ni operación destructiva en este plan.
