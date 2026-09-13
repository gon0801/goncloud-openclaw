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
| 1.1 | `[lane:gate] [tdd:skip:medición-solo-lectura]` **Medir si el gate de recibo vivo es teatro.** El gate de cierre de summa-gate (`index.ts:415-489`) usa el mismo camino que el candado revertido. Contar en los logs del gateway `summa-gate: revise solicitado` contra `before_agent_finalize requested revision after potential side effects`, sobre la ventana más larga que el CLI permita (`logs --limit 5000 --max-bytes 900000`, ~45 min) repetida durante 3 días. | Un archivo `docs/evidence/gate-recibo-descartes.md` con: conteo de ambas líneas por corrida, fecha/hora de cada muestra, y el cociente descartados/solicitados. Si el cociente ≥ 0.8, la conclusión "el gate de recibo no bloquea en turnos de trabajo" queda escrita como hecho con su evidencia. `not_observed != absent`: si no hubo ninguna solicitud en la ventana, se registra como `unknown`, no como 0. | - | **Salvedad al cerrar:** la DoD pedia repetir la ventana mas larga durante 3 dias; se entrego con 5 corridas en ~50 min de un solo dia porque la CLI topa en `--limit 200 / --max-bytes 250000`. El tope esta declarado en el artefacto. El resultado fue `unknown` de todos modos, asi que mas ventana no lo habria movido — pero el cierre no equivale a haber cumplido la ventana. cc:完了 |
| 1.2 | `[lane:gate] [tdd:required]` **Decidir qué hacer con el gate de recibo** según 1.1. Si está siendo descartado: o se mueve su exigencia al contrato inyectado en `before_prompt_build` (que es lo que sí funciona), o se documenta explícitamente que solo actúa en turnos sin herramientas mutantes. No dejarlo como está creyendo que bloquea. | El código o el comentario de `index.ts:415-489` declara su alcance real con la cita del runtime que lo limita. Si se cambia comportamiento, prueba que falle contra la versión anterior. | 1.1 | cc:完了 |

## Fase 2 — Medir antes de frenar

| Task | Contenido | DoD | Depends | Status |
|---|---|---|---|---|
| 2.1 | `[lane:fast] [tdd:required]` **Observador, no candado.** Handler `agent_end` en summa-gate (hook de tipo Observe: no puede rechazar nada) que registra a `~/.openclaw/summa-gate/rendiciones.jsonl` los turnos que terminan con cero herramientas no-replay-safe y texto con forma de incapacidad. Cada línea: timestamp, `sessionKey`, agente, `inputProvenance.kind`, si hubo `read` de algún `SKILL.md` en el turno, conteo de herramientas por tipo, y los primeros 300 caracteres del texto final. | El handler no devuelve nunca una acción que pueda alterar el turno (verificable leyendo el código: `agent_end` es Observe por tipo). Prueba unitaria que, dado un evento sintético, produce la línea jsonl esperada. Prueba de mutación: borrar el filtro de herramientas deja la batería en rojo. | - | **Salvedad:** la DoD pedia registrar "si hubo `read` de algun `SKILL.md`"; el runtime no expone la ruta del `read` a `agent_end`, asi que el campo es `hadRead` (hubo algun read) y se llama asi a proposito. **Contrato del jsonl (revision 2026-09-12):** una linea por CADA turno —sin el denominador no hay tasa— y el `textPreview` solo en las lineas detectadas, para que el medidor no sea un archivo de transcripciones. Ambas direcciones fijadas con prueba de mutacion. cc:完了 |
| 2.2 | `[lane:fast] [tdd:skip:análisis-de-datos]` **Leer el medidor a los 14 días.** Contar cuántas rendiciones hubo, por agente, y cuántas resultaron falsas (el trabajo sí se podía) revisando una muestra a mano. | `docs/evidence/tasa-base-rendiciones.md` con: total por agente, tasa por día, y la muestra revisada con su veredicto. El número de "falsas rendiciones por semana" queda escrito. | 2.1 | cc:完了 |

## Fase 3 — Lo que sí ataca el problema (texto, fail-open)

| Task | Contenido | DoD | Depends | Status |
|---|---|---|---|---|
| 3.1 | `[lane:fast] [tdd:required]` **Regla del artefacto re-derivable.** En el AGENTS.md de `ingenieria` (y en la skill `mac-node-ops`): una declaración de imposibilidad no vale como prosa. Tiene que traer el comando exacto que se corrió y su salida verbatim, para que un tercero pueda re-derivarla. Sin eso, no es un bloqueo: es una suposición. Es la misma disciplina que ya existe en `locate-session-cwd.md:150-153` ("the artifact a verifier re-derives, not prose"). | Sección nueva con anclas de frase exacta y su prueba `.ps1`, verificada en rojo contra `origin/master`. La prueba incluye un anti-ancla que rechaza redacciones que permitan declarar imposible sin evidencia. | - | Entregado en las DOS mitades: `AGENTS.md` de ingenieria (+ `tests/test-artefacto-rederivable.ps1`, rojo por seccion faltante y por redaccion permisiva) y la seccion "Declaring something impossible" de la skill `mac-node-ops`. cc:完了 |
| 3.2 | `[lane:fast] [tdd:skip:docs-only]` **Corpus etiquetado, gratis.** Extraer de `.saikit/findings/adversary-20260912T175152Z.json` los 23 textos que deberían detectarse y los 8 legítimos que no, a `docs/evidence/corpus-rendiciones.tsv` con su etiqueta. Sirve como línea base para cualquier mecanismo futuro y para medir 2.2. | El TSV existe con 31 filas etiquetadas y su procedencia (hallazgo de origen) en cada una. | - | **Discrepancia declarada:** la DoD pedia 31 filas; el TSV tiene 22, las unicas citables verbatim del hallazgo del adversary. El resto no es reconstruible sin `probe.mjs`, que no sobrevivio. Detalle y politica en `docs/evidence/corpus-rendiciones-discrepancy.md`; re-derivable con `node summa-gate/verify-corpus.mjs`. cc:完了 |

## Fase 4 — Solo si el medidor lo justifica

| Task | Contenido | DoD | Depends | Status |
|---|---|---|---|---|
| 4.1 | `[lane:release] [tdd:required]` **Mecanismo con freno, condicionado.** Solo se abre si 2.2 mide una tasa que lo justifique. Requiere `Spec delta` previo. Criterios innegociables: (a) umbral fijado sobre el corpus de 3.2, no sobre intuición; (b) prueba de mutación obligatoria — si borrar la rama principal deja la batería en verde, la batería no vale; (c) alcance acotado por `inputProvenance`, nunca el chat de main con David; (d) nada que rechace un cierre antes de tener la tasa base. | No aplica todavía. Esta fila queda `blocked` hasta que 2.2 entregue el número. | 2.2, 3.2 | **NO SE ABRE (cerrada 2026-09-12).** 2.2 midio 6 detecciones en 225 turnos de 8 agentes: 0 rendiciones reales sobre prompts naturales; la unica "real" venia de un prompt de prueba fabricado. Las 6 incluyen a un agente que obedecio la orden "pega el resultado crudo" y pego un error. Un mecanismo con freno sobre este criterio rechazaria trabajo legitimo sin atrapar nada. El criterio (a) de esta misma fila exigia fijar el umbral sobre datos y no sobre intuicion: los datos dicen que no hay umbral. Salvedad declarada: n=1 y ventana corta, o sea "insuficiente para fijar umbral" — si el observador de 2.1, que queda corriendo, acumula rendiciones reales, esta fila se reabre con datos nuevos. Evidencia: `docs/evidence/tasa-base-rendiciones.md`. cc:完了 |

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

---

## Fase 5 — Guardia estructural condicionada por error real

Fecha de planificación: 2026-09-12

Implementation owner: Muse

Review owner: Codex/root, una sola ronda
`team_validation_mode: subagent` — arquitectura, seguridad, QA y producto/escéptico.

### Spec delta

Esta fase sí cambia comportamiento visible y, por eso, agrega el SSOT [docs/spec/00-project-spec.md](docs/spec/00-project-spec.md) y el diseño [docs/superpowers/specs/2026-09-12-structural-investigation-guard-design.md](docs/superpowers/specs/2026-09-12-structural-investigation-guard-design.md). No reescribe la conclusión histórica de 4.1: aquel corpus no justificaba un bloqueo léxico. La evidencia nueva es distinta y estrecha: un error real de `gh` se convirtió indebidamente en “no existe”. Fase 5 responde solo a tres pares tool/sujeto allowlisted y falla abierta para todo lo demás.

La revisión del SDK fijó dos límites innegociables para OpenClaw 2026.9.4:

- `scheduleSessionTurn` solo funciona para plugins `bundled`; `summa-gate` es instalado/configurado. No habrá cancelación de respuesta ni continuación automática entre runs.
- `resolve_exec_env` descarta `PATH`. La guía descubre `gh.exe` y lo usa por ruta absoluta; cualquier `tools.exec.pathPrepend` será otro cambio operativo, con aprobación propia.

### Baseline de calidad

Estado: falta un comando explícito de sintaxis en `summa-gate/package.json`; la batería actual usa Node 24 `node --test` y CI ejecuta `scripts/run-checks.sh`. El árbol actual pasa `node --check` sobre `index.ts`, `lib.ts` y `observer.ts`. La tarea 5.2 agrega scripts `check`/`test` sin dependencias y conecta el chequeo de sintaxis al runner existente. Durante RED/GREEN Muse corre únicamente el archivo focalizado. El hook pre-commit no se omite. La batería completa se consume una vez en CI de pull request sobre el SHA final; no se agrega una corrida manual duplicada.

### Evaluación neutral

Escala 1–5. Total máximo: 35.

| Propuesta | Producto | Evidencia | Usuario | Factibilidad | Regresión | Seguridad | Funciona | Total | Clasificación |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| Guía allowlisted + estado simbólico, sin retener contenido | 5 | 4 | 4 | 4 | 4 | 4 | 4 | 29 | Required |
| Descubrimiento y uso de `gh.exe` por ruta absoluta | 5 | 5 | 5 | 5 | 4 | 5 | 5 | 34 | Required |
| Revisión same-run best-effort, canary y configuración | 4 | 3 | 4 | 3 | 3 | 4 | 3 | 24 | Recommended |
| Activar `enforce` por defecto en toda la flota | 4 | 2 | 3 | 3 | 2 | 3 | 2 | 19 | Reject |
| Continuación cross-run con APIs privadas, Cron o shell | 3 | 1 | 3 | 1 | 1 | 1 | 1 | 11 | Reject |

**Required:** evidencia sanitizada del incidente, baseline de calidad, clasificador/middleware allowlisted, aislamiento por `runId`, privacidad, guía por ruta absoluta y preservación de los tres guardas existentes.

**Recommended:** revisión same-run con máximo uno, rollout inicial `observe`, canary antes de `enforce` y rollback documentado.

**Optional:** una propuesta upstream para ofrecer una primitiva autenticada de continuación a plugins instalados; queda fuera de este bloque.

**Reject:** regex genérico, default fleet-wide `enforce`, cancelación de finales, `enqueueNextTurnInjection`, scheduler bundled-only, Cron/heartbeat/shell como continuación, parche de `dist`, `resolve_exec_env` para `PATH`, y un `tools.exec.pathPrepend` global sin revisión operativa separada.

### Tareas

| Task | Contenido | DoD | Depends | Status |
|---|---|---|---|---|
| 5.1 | `[Evidence] [lane:gate] [tdd:skip:evidencia-sanitizada-solo-lectura]` Capturar el incidente `gh` en `docs/evidence/gh-path-miss-20260912.md` y citar el límite bundled-only del runtime instalado. | El artefacto contiene host/runtime, tool, error sanitizado, conclusión incorrecta, ruta conocida encontrada y fuente de re-derivación; no contiene prompts, tokens, variables, credenciales ni salida cruda sensible. Distingue hecho, inferencia y dato removido. | - | cc:完了 (re-derivación desde skills versionadas git-commit-push:23 y gateway-cli-setup:16 + SDK instalado; log RED en `diagnostic-guard-review-fixes-red.md`) |
| 5.2 | `[Quality] [lane:gate] [tdd:skip:configuracion-del-runner]` Agregar `check` y `test` a `summa-gate/package.json`; ejecutar el chequeo de sintaxis desde `scripts/run-checks.sh` y quitar la segunda invocación directa de la batería en CI. | `check` cubre todos los `.ts` fuente de `summa-gate`, `test` ejecuta `node --test`, no se agrega dependencia, eliminar `diagnostic-guard.ts` del chequeo deja el test contractual rojo y el workflow alcanza la batería una vez mediante pre-commit. | - | cc:完了 (test usa el mismo fallback de node que run-checks.sh; verificado con y sin node en PATH) |
| 5.3 | `[Feature] [lane:gate] [tdd:required]` Implementar el núcleo puro allowlisted en `summa-gate/diagnostic-guard.ts` con su test focalizado. | Solo reconoce `path_miss:gh_cli`, `wrong_profile:browser_claw` y `session_scope:sessions_search` cuando tool, sujeto y fallo estructurado coinciden; limita inspección a 8192 caracteres; deduplica categorías; desconocidos y éxitos quedan intactos; no persiste contenido. Mutantes de `isError`, firma, deduplicación, límite y redacción fallan. | 5.1, 5.2 | cc:完了 (2 rondas Codex: browser vía exec, scope ausente exigido, probes por ejecutable invocado con segmentos quote-aware, umbral por distintas) |
| 5.4 | `[Feature] [lane:gate] [tdd:required]` Cablear middleware, contrato de manifest, configuración y estado por `runId`; aislar fallos de registro. | OpenClaw recibe `<diagnostic-contract>` sin perder `content`, imágenes, `details`, `progress` ni `terminate`; Codex nativo se considera observable cuando su host no reinyecta la transformación; llamadas sin `runId` no crean estado; dos runs concurrentes no se mezclan; actualizaciones paralelas no pierden categorías; un fallo diagnóstico conserva merge guard, adversary confinement y `sessions_send`. | 5.3 | cc:完了 (`runId` solo desde ctx SDK; `setRunContext===false` tratado como fallo; estado corrupto/duplicado rechazado) |
| 5.5 | `[Guardrail] [lane:gate] [tdd:required]` Agregar cierre best-effort y telemetría simbólica. | `observe` guía/registra sin revisar; `enforce` puede pedir exactamente un `revise` same-run con `maxAttempts: 1`; `off` no registra hooks diagnósticos; un final ambiguo, cron, dos finales concurrentes y un run con efectos laterales nunca se cancelan ni programan otro run. No existe handler diagnóstico de `reply_payload_sending`, llamada a scheduler, Cron, heartbeat, marker de continuación ni mapa con texto final. | 5.4 | cc:完了 (automatización filtrada por `ctx.trigger` real del SDK, espejo del bundled memory-core; `inputProvenance` no se consulta para cron/heartbeat) |
| 5.6 | `[Ops] [lane:gate] [tdd:required]` Implementar guía de descubrimiento absoluto para `gh.exe`, restaurar literalmente la directiva de seguridad borrada de `C:\Users\ehven\.openclaw\workspace\USER.md` desde historia verificable y preparar rollout `observe`. | El smoke encuentra `C:\Users\ehven\.openclaw\tools\bin\gh.exe`, lo invoca por ruta absoluta y verifica capacidad/auth sin revelar valores; la restauración modifica solo la línea recuperada y su diff queda guardado; no cambia modelos, auth, permisos ni `PATH`; `tools.exec.pathPrepend` queda sin aplicar. Config se relee y rollback `off` está probado fuera de cron activo. | 5.5 | **Parcial 2026-09-13:** guía + runbook `observe` listos; fixture browser del runbook corregida a forma exec (review 2). Restauración USER.md STOPPED: sin fuente histórica verificable no se reconstruye de memoria; 5.6 NO puede declararse completa hasta aporte del operador. cc:完了-parcial |
| 5.7 | `[Review] [lane:gate] [tdd:skip:revision-solo-lectura]` Codex/root revisa el diff de Muse una sola vez y agrupa todos los hallazgos. | La revisión cubre comportamiento, privacidad, concurrencia, compatibilidad SDK, tests y AI residuals. Muse corrige esa ronda en un solo bloque. Solo severidad alta permite una segunda ronda; nunca una tercera. | 5.6 | **2 rondas consumidas (2026-09-13):** ronda 1 → 7 mayores (firma SDK, browser invertido, spoof, scope, español, setRunContext, node fallback); ronda 2 → 3 bloqueantes (trigger real, ejecutable invocado, duplicados) + runbook/plan/base/5.6. No hay tercera ronda: lo pendiente (push/PR) es aprobación del operador, no revisión. |
| 5.8 | `[PR] [lane:gate] [tdd:skip:cierre-y-ci]` Entregar la rama y validar el SHA final. | `git log origin/main..HEAD` contiene solo commits de esta fase; pre-commit corrió sin `--no-verify`; se hace push y se abre PR; la unión de CI ejecuta la batería completa una vez sobre el SHA final y queda verde; el PR permanece abierto, sin merge automático. | 5.7 | cc:TODO |

### 事前確認 de Fase 5

- Evento: `git push` de la rama de Fase 5 y `gh pr create` en `goncloud-openclaw`.
  Razón: disparar la batería completa en CI de pull request y entregar el trabajo para revisión.
  scope: 5.8; no incluye merge.
- Evento: restaurar una directiva en `C:\Users\ehven\.openclaw\workspace\USER.md`, cambiar `diagnosticGuard.mode` a `observe` y recargar el plugin fuera de cron activo.
  Razón: reparar el daño vivo y ejecutar el canary de la conducta nueva.
  scope: 5.6; exige diff previo, backup recuperable, read-back y rollback `off`.

No hay secret-read ni operación destructiva preaprobada. Leer presencia/estado de auth está permitido; leer o imprimir el valor de un secreto no forma parte del plan. `tools.exec.pathPrepend`, cambios de modelo, cambios de auth, merge y deploy fleet-wide quedan fuera de esta preaprobación.
