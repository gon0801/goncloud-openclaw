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
| 5.6 | `[Ops] [lane:gate] [tdd:required]` Implementar guía de descubrimiento absoluto para `gh.exe`, restaurar literalmente la directiva de seguridad borrada de `C:\Users\ehven\.openclaw\workspace\USER.md` desde historia verificable y preparar rollout `observe`. | El smoke encuentra `C:\Users\ehven\.openclaw\tools\bin\gh.exe`, lo invoca por ruta absoluta y verifica capacidad/auth sin revelar valores; la restauración modifica solo la línea recuperada y su diff queda guardado; no cambia modelos, auth, permisos ni `PATH`; `tools.exec.pathPrepend` queda sin aplicar. Config se relee y rollback `off` está probado fuera de cron activo. | 5.5 | cc:完了 (2026-09-12: fuente exacta `goncloud-workspace-main` `a4c023c^`; backup vivo creado y releído; entrada restaurada literalmente; verificación independiente 1/0 y regla nueva 1/1; 31 cron, 0 activos; sin reload ni cambios de modelo/auth/permisos/PATH) |
| 5.7 | `[Review] [lane:gate] [tdd:skip:revision-solo-lectura]` Codex/root revisa el diff de Muse una sola vez y agrupa todos los hallazgos. | La revisión cubre comportamiento, privacidad, concurrencia, compatibilidad SDK, tests y AI residuals. Muse corrige esa ronda en un solo bloque. Solo severidad alta permite una segunda ronda; nunca una tercera. | 5.6 | cc:完了 — discrepancia declarada: se ejecutaron 3 rondas por instrucción directa del operador pese al tope del plan; la tercera aprobó el bloque corregido tras 152 tests focalizados y los contratos shell/npm. No se abre otra ronda. |
| 5.8 | `[PR] [lane:gate] [tdd:skip:cierre-y-ci]` Entregar la rama y validar el SHA final. | `git log origin/main..HEAD` contiene solo commits de esta fase; pre-commit corrió sin `--no-verify`; se hace push y se abre PR; la unión de CI ejecuta la batería completa una vez sobre el SHA final y queda verde; el PR permanece abierto, sin merge automático. | 5.7 | cc:完了 (cierre autorizado; validez condicionada al PR abierto y CI verde sobre el SHA final reportados en el handoff) |

### 事前確認 de Fase 5

- Evento: `git push` de la rama de Fase 5 y `gh pr create` en `goncloud-openclaw`.
  Razón: disparar la batería completa en CI de pull request y entregar el trabajo para revisión.
  scope: 5.8; no incluye merge.
- Evento: restaurar una directiva en `C:\Users\ehven\.openclaw\workspace\USER.md`, cambiar `diagnosticGuard.mode` a `observe` y recargar el plugin fuera de cron activo.
  Razón: reparar el daño vivo y ejecutar el canary de la conducta nueva.
  scope: 5.6; exige diff previo, backup recuperable, read-back y rollback `off`.

No hay secret-read ni operación destructiva preaprobada. Leer presencia/estado de auth está permitido; leer o imprimir el valor de un secreto no forma parte del plan. `tools.exec.pathPrepend`, cambios de modelo, cambios de auth, merge y deploy fleet-wide quedan fuera de esta preaprobación.

---

## Fase 6 — Claw adopta lo que le falta del modelo DG (director que delega, camino feliz, verify de producto)

Fecha de planificación: 2026-09-15

Origen: comparación del documento de la flota Grok Bot (`DG — Ingeniería, estructura del agente y Grok Bot como herramienta`, 2026-09-15) contra los contratos vivos de claw (SOUL/AGENTS de main, ingenieria y operaciones; workspace-implementer/verifier/reviewer/adversary; skills agent-dispatch, post-merge-closure, goncloud-ssh-ops; crons vivos). Claw ya cubre delegación dura, cadena de calidad con adversary, deploy a gonserver, reporte al dueño y vigías con silencio. Lo que falta es lo que sigue.

Decisiones del dueño (2026-09-15): **D1** main nunca mergea; la orden de merge de David va citada en el brief y la ejecuta implementer o ingenieria. **D2** se crea `verify/` en goncloud-Orbit y goncloud-accounting con `saikit-verificar-app`; no se adapta el verifier a `.cursor/skills/verify-*`. **D3** sin briefing matutino.

`team_validation_mode: subagent` — producto (10 hallazgos), seguridad+QA (12), arquitectura+escéptico (12). Lo que cambió respecto del borrador: un solo go/no-go donde merge = deploy; roster de una línea por agente (los contratos van en cada AGENTS.md); 6.4 es mapa hacia skills, no cuarto procedimiento; el spike de 6.5 sobra porque `ctx.agentId` ya llega al hook (`summa-gate/index.ts:439-453`) y el guard tampoco cubre la ruta REST de merge de ramas; los Drive de 6.6/6.7 quedan aislados de producción por DoD; 6.9 protege al gateway vivo del sync.

Hechos verificados (no repetir la investigación): ramas por defecto — openclaw y accounting `main`; workspace-main, workspace-ingenieria, workspace-operaciones y Orbit `master`. Los 3 workspaces no tienen CI ni pre-commit; sus `tests/*.ps1` corren a mano con pwsh 7.7 en la Mac. `allowAgents` de main lista 8: main, operaciones, ingenieria, implementer, verifier, reviewer, adversary, scout. `scripts/sync-repos.ps1` despliega openclaw + 3 workspaces al gateway cada 2 h con `git add -A` + auto-commit antes del pull, y su único guardia es `openclaw config validate` (no valida plugins). goncloud-ssh-ops ya trae backup `app.bak-predeploy` (rama archive de Orbit), chequeo de SHA en master y `/health`.

### Spec delta

`docs/spec/00-project-spec.md` gana la sección "Fleet roles and routing", en términos del dueño:

1. main coordina y le reporta a David; nunca mergea ni toca el servidor directamente.
2. Cambios de código van a la cadena de calidad (implementer → verifier → adversary → reviewer); servidor y deploy van a ingenieria; negocio va a operaciones.
3. Nada se mergea sin autorización explícita de David; donde mergear ya despliega (openclaw y los 3 workspaces, por el sync) la autorización es una sola: "merge y deploy".
4. Nada se reporta como "listo" sin haberse verificado antes con la prueba del repo (`verify/`) cuando existe.

Decisión de producto registrada: no se adapta el verifier a `.cursor/skills/verify-*` (D2) porque duplica mantenimiento sin cambiar nada para David; esas skills siguen siendo de la flota DG y `verify/` es la fuente de claw.

### Baseline de calidad

openclaw: CI `quality.yml` corre pre-commit → `scripts/run-checks.sh` (itera `scripts/tests/*.sh` y `node --test` de summa-gate). Orbit y accounting: `quality.yml` propio (pytest). Workspaces: sin CI ni pre-commit → la tarea 6.0 lo instala antes de tocar sus AGENTS/SOUL.

### Tareas

| Task | Contenido | DoD | Depends | Status |
|---|---|---|---|---|
| 6.0 | `[lane:fast] [tdd:skip:configuracion-del-runner]` **Baseline de los 3 workspaces + medición del ruteo.** (a) En goncloud-workspace-main, -ingenieria y -operaciones: `tests/run-all.ps1` que ejecuta todos los `tests/*.ps1` y sale 1 si alguno falla, más `.github/workflows/quality.yml` (`shell: pwsh`) que lo corre en pull_request. (b) Medir antes de cambiar el default: con `openclaw audit --kind agent_run --limit 500 --json` (solo lectura, host gateway), contar en las últimas 2–4 semanas cuántos despachos de main a ingenieria fueron cambios de repo y cuántos terminaron en PR. | (a) Un PR de prueba en cada workspace muestra el job verde; forzar un `throw` en un test lo pone rojo. (b) `docs/evidence/ruteo-ingenieria-vs-cadena.md` con la tabla (fecha, despacho, ¿tocó repo?, ¿PR?) y el número; si el audit no cubre la ventana, se escribe `unknown` con el límite del CLI, no 0. | - | cc:TODO |
| 6.1 | `[lane:fast] [tdd:required]` **Ruteo y roster de main** en goncloud-workspace-main/SOUL.md. Reemplaza la cláusula "servidor, docker, logs, código de las apps, deploys, fixes o rendimiento → ingenieria" por la regla de ruteo con desempate literal: (a) cambia el estado de una máquina → ingenieria; cambia solo archivos de un repo → cadena implementer vía agent-dispatch; (b) si la entrega es un PR → cadena; (c) "un script de deploy: cambiarlo es repo (cadena); correrlo es ingenieria"; (d) el diagnóstico arranca en ingenieria y, si concluye que hay que cambiar código, devuelve el diagnóstico y main abre la lane; (e) empate → ingenieria y main declara la elección en su reporte. Si 6.0(b) muestra que la mayoría de los cambios de repo son de una sola edición, la regla (a) lleva ese umbral escrito. Roster: **una línea por agente** (8, los de `allowAgents`) con "cuándo se usa"; los contratos completos viven en cada AGENTS.md (6.2). Línea literal: "main nunca mergea ni hace SSH a producción". | `tests/test-ruteo-y-roster.ps1` rojo contra `origin/master`, con recorte por encabezado (patrón de `tests/test-mapa-maquinas.ps1`): anclas de (c), (e), "main nunca mergea", y las 8 líneas de roster (id + "cuándo" en la misma línea); anti-ancla que falla si sobrevive "deploys, fixes o rendimiento → NUNCA lo hagas tú. SIEMPRE a `ingenieria`". Mutante: roster con los 8 nombres pero sin el "cuándo" deja rojo. `grep -c GraphQL SOUL.md` = 0. | 6.0 | cc:TODO |
| 6.2 | `[lane:fast] [tdd:required]` **Contrato de rol por agente.** Bloque `## Contrato de dispatch` (mismo encabezado que ya usan implementer/verifier/reviewer/adversary) al inicio de AGENTS.md de ingenieria y operaciones, ≤8 líneas: único trabajo, nunca (anti-jobs), reporta solo a main, máquina donde ejecuta, rutinas. En implementer/verifier/reviewer/adversary se completa el bloque existente con "nunca" y "reporta a" si faltan (scout: `unknown` si no tiene workspace versionado; se declara). Poda de plantilla OpenClaw que no aplica (Group Chats, React Like a Human, Voice storytelling, Platform formatting, Local notes de cámaras/TTS) con razón declarada: cada línea se carga en cada turno (~138k tokens de prompt medidos). Las lecciones "Medido el" se conservan íntegras. | Test `.ps1` por workspace (ingenieria, operaciones) y `.sh` en openclaw para los 4 workspace-*: anclas del contrato por sección recortada; anti-anclas evaluadas solo fuera de bloques que contienen "Medido el"; conteo de "Medido el" ≥ el de `git show origin/<default>:AGENTS.md` y `wc -l` ≤ (en operaciones el conteo previo es 0 y se declara). Rojo antes, verde después. | 6.0 | cc:TODO |
| 6.3 | `[lane:fast] [tdd:required]` **Extender la tabla "En que maquina vive cada cosa"** de goncloud-workspace-main/AGENTS.md (no crear una segunda) con columnas: URL viva y puerto, rama de deploy, cómo se verifica (`verify/` o `unknown`), unidad o contenedor en gonserver. Filas: Orbit, accounting, openclaw + 3 workspaces, summonaikit-claude. Los datos salen de goncloud-ssh-ops y de una lectura `ss -lnt` (sin `-p`) filtrada por puerto en gonserver. Esta tabla es la fuente del cierre "Live <SHA> en <URL>" del mapa 6.4. | Test `.ps1` con anclas de la cadena exacta URL:puerto de cada fila (o `unknown` + razón en la misma línea). Evidencia manual en el PR: salida de `ss -lnt` filtrada y redactada (sin PIDs ni rutas de proceso). Rojo contra `origin/master`. | 6.0 | cc:TODO |
| 6.4 | `[lane:fast] [tdd:required]` **Mapa de una página del camino feliz** `docs/runbooks/camino-feliz-producto.md`: pedido → clasificación (regla 6.1) → brief → PR por cadena → verify (`verify/` si existe) → resumen a David → go/no-go (uno solo "merge y deploy" para openclaw y workspaces; dos separados, merge y luego deploy, para Orbit y accounting) → merge por implementer con la orden citada (skill 6.5) → deploy por ingenieria (goncloud-ssh-ops) → "Live <SHA> en <URL>" (datos de 6.3) → regresión vuelve al brief. Cada paso nombra la skill autoritativa y **no repite sus pasos**. Tablas de variantes (solo investigar, fix en PR abierto, ops sin código) y de bloqueos → acción. Lo que hoy no está en ninguna skill (los go/no-go, la vuelta por regresión) se agrega a `agent-dispatch`, no al mapa. Una línea del SOUL de main apunta al mapa. | `scripts/tests/test-camino-feliz.sh` rojo primero: el archivo existe; cada skill nombrada existe bajo `agents/*/agent/workshop-skills/`; anclas de los dos tipos de go/no-go; `grep -c GraphQL` = 0 en el mapa; ninguna línea del mapa duplica textualmente una línea de las 4 skills (agent-dispatch, post-merge-closure, owner-report-delivery, goncloud-ssh-ops). | 6.1, 6.3 | cc:TODO |
| 6.4b | `[lane:gate] [tdd:required]` **Deploy uniforme en goncloud-ssh-ops**: el backup `app.bak-predeploy-<timestamp>` y el smoke con código HTTP aplican a las DOS ramas del paso 5 (archive de Orbit y `git pull` de accounting), y el cierre del deploy es la línea "Live <SHA> en <URL>" para main. El chequeo "SHA aprobado ya en la rama de deploy" (merge antes que deploy) se declara como precondición, no como nota. | `scripts/tests/test-goncloud-ssh-ops-deploy.sh` rojo primero: anclas de backup en ambas ramas, del código HTTP y de la línea de cierre. Sin cambios de comandos SSH ni de hosts. | 6.3 | cc:TODO |
| 6.5 | `[lane:gate] [tdd:required]` **Main no mergea.** (a) Quitar de `agents/main/agent/workshop-skills/agent-dispatch/SKILL.md` la sección "Merging approved PRs" **y** las dos cláusulas de merge del `description` del frontmatter. (b) Mover ese texto verbatim (re-target, `expectedHeadOid`, carrera `UNPROCESSABLE`, PRs apilados) a una sección "Merge por orden del dueño" de `agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md` con el requisito: el brief trae la orden textual de David con fecha; sin ella no se mergea. (c) `summa-gate/lib.ts`: `mergeGuardVerdict(command, agentId?)` (parámetro opcional para no romper `role.test.ts`) bloquea además la mutación GraphQL `mergePullRequest`, la ruta REST de merge de ramas (`/merges`, con s) y llamadas a `api.github.com` con path de merge, salvo que `agentId` esté en la allowlist `implementer`, `ingenieria`; el registro en `index.ts` pasa `ctx.agentId`. El guard es léxico sobre `exec`: `query=@archivo` lo esquiva y eso se declara en el código y en la skill (alcance real, como en 1.2). `curl` con token queda fuera de alcance (requeriría secret-read) y se declara. | `node --test` rojo primero: `mergePullRequest` desde main → bloqueado; desde implementer → pasa; ruta `/merges` → bloqueada; `gh pr view` y `git push rama` → NO bloqueados; `query=@file` → pasa y el test lo documenta como bypass conocido; `role.test.ts` sigue verde con un solo argumento. Mutante: borrar la rama `mergePullRequest` deja rojo. Smoke de import del plugin verde. grep del archivo entero de agent-dispatch sin "merge". | 6.4 | cc:TODO |
| 6.6 | `[lane:gate] [tdd:required]` **`verify/` en goncloud-Orbit** con `saikit-verificar-app`: generar, completar LEEME (3–5 funciones en español), Drive corre en la Mac contra un Postgres desechable local (mismas credenciales que `quality.yml` del repo) y `ORBIT_SECRETS_DIR` vacío. **Prohibido** cualquier DSN o URL con `10.13.13.1` o `gonserver`, y prohibido correr el Drive por ssh. Si el generador dice `PROPONGO` framework → preguntar a David antes de instalar nada. El LEEME declara la convivencia: `verify/` es de la flota claw; `.cursor/skills/verify-orbit` sigue siendo de la flota DG. PR en Orbit (rama base `master`). | `verify/LEEME.md` con sello `generado: <fecha> · <sha>` y la nota de convivencia; `verify/Evidence.txt` con una corrida real; `n/a` solo con aprobación escrita de David citada en el PR; grep de `10.13.13.1` y `gonserver` en `verify/` vacío; CI verde. | - | cc:TODO |
| 6.7 | `[lane:gate] [tdd:required]` **`verify/` en goncloud-accounting**, mismo procedimiento que 6.6, con: la variable de ruta de la base (`DB_PATH` o equivalente) a un sqlite temporal, `HOST=127.0.0.1`, funciones de Amazon Ads (OAuth/API real) excluidas del mapa o mockeadas, prohibido correr el Drive en gonserver. Rama base `main`. | Igual que 6.6 más: el Drive no abre sockets a `amazon` ni a `10.13.13.1` (comprobado con grep en el Drive y en Evidence.txt). | - | cc:TODO |
| 6.8 | `[lane:fast] [tdd:skip:docs-only]` **Spec delta** en `docs/spec/00-project-spec.md`: sección "Fleet roles and routing" con las 4 reglas de arriba y la decisión D2 registrada; enlaza al mapa 6.4. | Anclas de las 4 reglas presentes (grep por frase exacta de cada una) y el enlace resuelve a un archivo existente. | 6.1, 6.5 | cc:TODO |
| 6.9 | `[lane:release] [tdd:skip:cierre-y-ci]` **Cierre por repo, sin romper el gateway vivo.** PRs: openclaw-docs (6.2 tests .sh, 6.4, 6.4b, 6.8), openclaw-summa-gate (6.5, **separado y último**, con nota de reversa: `git revert` + esperar un ciclo de sync o `scripts/restart-openclaw-gateway.ps1` fuera de ventana de cron), workspace-main (6.0a, 6.1, 6.3), workspace-ingenieria (6.0a, 6.2), workspace-operaciones (6.0a, 6.2), Orbit (6.6), accounting (6.7). `git log origin/<default>..HEAD` solo trae commits de esta fase; pre-commit sin `--no-verify`; CI verde sobre el SHA final. **El merge lo hace el autopilot** por la ruta del kit, en el orden y con las compuertas de `docs/runbooks/autopilot-fase6.md` (Q1–Q5); David no mergea nada en esta fase (decisión del dueño, 2026-09-15). La sección de merge de 6.5 no se usa aquí. Los workspaces y summa-gate se mergean en una ventana sin crons a punto de correr (`openclaw cron list`, regla "Antes de reiniciar el gateway"). | 7 PRs abiertos y verdes, más el PR de cierre `fase6/cierre`. Tras el merge y un ciclo de sync: `git -C C:\Users\ehven\.openclaw log -1 --format=%H` y el del workspace de main igualan el SHA mergeado; `sync-repos.log` sin `CONFLICTO` ni `FALLO` en ese ciclo; canary de ruteo de solo lectura: a main se le pregunta "¿a quién mandarías 'arregla el favicon de Orbit'?" y responde cadena implementer sin despachar nada; `exec` de un agente cualquiera sigue funcionando (un `gh pr view` no bloqueado) después del merge de summa-gate. | 6.0–6.8 | cc:TODO |

### Clasificación

**Required:** 6.0, 6.1, 6.2 (el bloque de contrato; la poda es parte del mismo PR con su razón), 6.4, 6.5, 6.9.

**Recommended:** 6.3, 6.4b, 6.6, 6.7, 6.8.

**Optional:** cron mensual del verifier que corre `verify/` de Orbit y accounting y reporta solo si hay drift (equivalente al maintain-verification de Engineer en DG) — nace con la regla "clean = silencio; changed = PR; blocked = qué frenó".

**Reject, con razón:**
- *Briefing matutino de main* (D3): los vigías ya avisan cuando algo falla; un turno diario de main cuesta ~138k tokens de prompt.
- *Adaptar el verifier a `.cursor/skills/verify-*`* (D2): duplica mantenimiento sin cambiar nada para David.
- *Roster con contratos completos en el SOUL de main*: segunda fuente de verdad que se carga cada turno; los contratos viven en cada AGENTS.md.
- *Runbook de 9 pasos como procedimiento nuevo*: cuarta copia de lo que ya está en 4 skills; se hace mapa.
- *Rol "Engineer" separado*: lo cubre verifier más el cron opcional.
- *Candado nuevo en summa-gate para el ruteo*: mismo criterio que Fase 3; el ruteo es texto + test de anclas.
- *Roster con UUIDs estilo Grok Bot*: claw identifica agentes por `agentId` legible.

### 事前確認 de Fase 6

- Evento: `git push` de rama + `gh pr create` en 7 repos (goncloud-openclaw ×2, workspace-main, workspace-ingenieria, workspace-operaciones, goncloud-Orbit, goncloud-accounting).
  Razón: entrega de todas las tareas; CI de pull_request corre la batería una vez por repo.
  scope: Fase 6 / Task 6.9.
- Evento: merge automatizado de los PRs de la fase por la ruta del kit, en el orden Q1–Q5 del runbook de autopilot.
  Razón: David pidió la implementación completa sin intervención (2026-09-15); mergear openclaw y workspaces despliega al gateway por el sync.
  scope: Fase 6 / Task 6.9; con revert automático de 6.5 si el exec de la flota queda bloqueado.
- Evento: cambio de código del plugin `summa-gate` que corre vivo en el gateway (se despliega solo al mergear, por el sync).
  Razón: 6.5(c); el guard de merge se amplía. Sin cambios de `openclaw.json`, modelos, auth, cron ni permisos.
  scope: Fase 6 / Task 6.5 y 6.9.
- Evento: lectura `openclaw audit --kind agent_run` y `openclaw cron list` en el host gateway (solo lectura).
  Razón: 6.0(b) medición y 6.9 ventana sin crons.
  scope: Fase 6 / Task 6.0, 6.9.
- Evento: `ssh gonserver` con `ss -lnt` filtrado por puerto (solo lectura, sin `-p`); salida redactada antes de pegarse.
  Razón: 6.3 confirma URL y puerto de cada fila.
  scope: Fase 6 / Task 6.3.
- Evento: levantar en la Mac un Postgres desechable (docker) y la app de Orbit/accounting en `127.0.0.1` para correr el Drive.
  Razón: 6.6 y 6.7; nunca contra `10.13.13.1` ni por ssh.
  scope: Fase 6 / Task 6.6, 6.7.
- Evento: instalar un framework de test en Orbit o accounting.
  Razón: solo si el generador dice `PROPONGO` — **no preaprobado**: se pregunta a David en ese momento.
  scope: Fase 6 / Task 6.6, 6.7.

No hay secret-read: obtener el DSN real de Orbit o credenciales de Amazon Ads queda como Risk Gate y la salida honesta es `n/a` con aprobación de David. No hay operación destructiva ni merge por agente en esta fase.

---

## Fase 7 — Tablero de runbook: plugin `tablero-runbook` para ver el avance de una fase en autopilot

Fecha de planificación: 2026-09-15

Pregunta de David: "¿sería posible un plugin para ver en una interfaz gráfica el avance de una tarea con runbook?". Sí. El SDK de plugins expone lo necesario y ya está probado en este repo con summa-gate: `api.registerGatewayMethod` (método RPC que la CLI remota de la Mac invoca con `openclaw gateway call`, autenticada por la sesión existente, sin leer tokens), `api.registerHttpRoute` (ruta HTTP con `auth` declarada) y `api.session.controls.registerControlUiDescriptor` (pestaña en la barra lateral de la Control UI que carga una ruta del plugin). Lo que no existe es la fuente de datos: el avance vive repartido en PRs, comentarios `APPROVE lead`, celdas de `Plans.md` y palomitas manuales. Por eso la fase empieza por el contrato del dato y sigue con la interfaz.

Decisión de diseño: el **lead escribe** el progreso (JSON `runbook-progress.v1`, SSOT en `docs/spec/runbook-progress.v1.md`) y el plugin **solo lo guarda y lo pinta**, cruzándolo con GitHub cuando puede y diciendo "GitHub: sin verificar" cuando no. Plugin aparte de summa-gate: summa-gate es un guard con hooks en cada turno; este no registra ningún hook de agente ni tool y no puede alterar un turno (blast radius separado). Sin dependencias nuevas; misma batería `node --test` y mismo `scripts/run-checks.sh`. Lo que summa-gate ya resolvió se reusa, no se reescribe: sanitizado de claves (`summa-gate/index.ts:87-89`), escritura a disco fail-open (`index.ts:107-114`), rotación del jsonl con tope (`summa-gate/observer.ts:31-57`, `OBSERVER_MAX_BYTES`) y el contrato "la salida de un plugin no se trackea" (`scripts/tests/test-salida-del-observador-no-trackeada.sh`).

`team_validation_mode: subagent` — arquitectura+seguridad (10 hallazgos) y producto (8), una ronda cada uno; todos aplicados en este texto y en el spec.

### Spec delta

`docs/spec/runbook-progress.v1.md` (nuevo, SSOT del dato) y una sección "Tablero de runbook" en `docs/spec/00-project-spec.md` con cuatro reglas: (1) el progreso de un runbook lo escribe el lead como `runbook-progress.v1`; la interfaz nunca lo infiere; (2) el plugin `tablero-runbook` no registra hooks de agente ni tools: no puede alterar, retrasar ni bloquear ningún turno; (3) todo texto del progreso se trunca y escapa en el punto de interpolación antes de pintarse; el tablero no muestra salidas crudas ni secretos; (4) lo que el plugin lee de GitHub se rotula "GitHub" y, apagado, se rotula "GitHub: sin verificar"; el tablero nunca presenta lo reportado por el lead como verificado.

### Baseline de calidad

Igual que summa-gate: `node --test` sobre `tablero-runbook/*.test.ts`, `node --check` de cada `.ts`, con bloque propio en `scripts/run-checks.sh` (7.3) y guard de conteo: una batería que reporta 0 `pass` es FALLA (medido: `node --test` en un directorio sin pruebas sale 0). CI de pull_request corre la batería una vez.

### Hechos verificados y desconocidos

- Verificado en la documentación del SDK (rama principal): `registerGatewayMethod(method, handler, {scope})`, `registerHttpRoute({path, auth, match, handler})`, `registerControlUiDescriptor({surface:"tab", id, label, path, group, requiredScopes})`, `backupResources` con `scope: "state"`. `registerHttpHandler` fue eliminado: usar `registerHttpRoute`.
- `unknown` hasta 7.0: que el gateway instalado (2026.9.4) exporte esas funciones con esa firma; a qué ruta absoluta resuelve el directorio de estado de un plugin en ese host (y si cae dentro del clon `C:\Users\ehven\.openclaw`, que el sync commitea con `add -A`); qué rechaza exactamente `auth: "gateway"` y qué scope trae `openclaw gateway call` desde la Mac. El gateway escucha en `100.80.179.76:18789`, es decir, en toda la tailnet.
- La CLI remota de la Mac ya autentica contra el gateway (`~/.openclaw/bin/openclaw`): el lead no lee ningún token para escribir progreso.

### Tareas

| Task | Contenido | DoD | Depends | Status |
|---|---|---|---|---|
| 7.0 | `[lane:fast] [tdd:skip:spike-solo-lectura]` **Spike del SDK instalado y de la autorización.** Vía un turno de solo lectura a main (mecanismo del runbook de Fase 6): `grep -l` de `registerGatewayMethod`, `registerControlUiDescriptor`, `registerHttpRoute`, `backupResources`, `stateDir` y `dataDir` en el `dist` del openclaw instalado, `openclaw --version`, y la ruta absoluta del directorio de estado de un plugin en ese host (la de summa-gate sirve de muestra). Desde la Mac: `~/.openclaw/bin/openclaw gateway call status` (debe responder) y `gateway call runbook.progress.get --params '{"fase":"x"}'` (debe fallar por método desconocido, no por auth); `curl -s -o /dev/null -w '%{http_code}' http://100.80.179.76:18789/__openclaw__/a2ui/` **sin credencial** para fijar qué significa `auth: "gateway"` (401/403 esperado). | `docs/evidence/tablero-runbook-spike.md` con cada comando, salida verbatim recortada y un veredicto por función: `presente` / `ausente` / `unknown`; la ruta de estado escrita y marcada "dentro del clon" o "fuera del clon"; el código HTTP sin credencial. Si `registerControlUiDescriptor` está ausente, 7.4 se entrega sin pestaña y el tablero se abre por URL; si el estado cae dentro del clon o es `unknown`, 7.4 usa `configSchema.stateDir` con default fuera del clon. Ambas decisiones se escriben aquí. | - | cc:TODO |
| 7.1 | `[lane:fast] [tdd:required]` **Contrato del dato.** `docs/spec/runbook-progress.v1.md` (ya redactado, con `atencion_requerida`, `siguiente_paso`, `fase` con forma cerrada, `cola[].detenido_por` y `cola[].verificado`) más fixtures versionados en `tablero-runbook/fixtures/`: `fase6-en-curso.json` (siete carriles en estados distintos, uno `atorado`, cola Q2 `esperando-ventana`, `atencion_requerida.necesaria: false`), `fase6-cerrada.json` (todo `mergeado`, cierre con `telegram_message_id`), `fase6-diez-prs.json` (diez PRs entre carriles y cola, para 7.5), `invalido.json` (`schema` incorrecto, `estado` fuera de lista, texto de 400 caracteres, `fase: "../../openclaw.json"`, `repo: "a/b; calc.exe"`). `omitido` no aparece en los fixtures de Fase 6: existe para runbooks futuros y se declara. | Los fixtures existen y `tablero-runbook/progress.test.ts` (rojo primero, sin validador aún) los lee: los válidos deben pasar y `invalido.json` debe fallar con cinco razones nombradas. | - | cc:TODO |
| 7.2 | `[lane:fast] [tdd:required]` **La obligación en el runbook y en la skill.** Regla 8 "Progreso escrito, no contado" en `docs/runbooks/autopilot-fase6.md` (ya redactada): copia local `.saikit/progress/<fase>.json` en el checkout de la Mac (ahí no corre ningún `add -A`), envío con `openclaw gateway call runbook.progress.set --params @<archivo>`, fallo no bloqueante, `atencion_requerida` y `siguiente_paso` escritos en cada cambio, y Fase 6 en vuelo: Q5 escribe el estado final **reconstruyendo los eventos clave** (mergeado, atorado, reversa, con fecha) desde los PRs y el Telegram de cierre, no un snapshot vacío. Slot 12 "Progreso" en la skill `autopilot-runbook` (ya redactado, fuera del repo). | `scripts/tests/test-runbook-progreso.sh` rojo contra `origin/main`: anclas de "runbook.progress.set", ".saikit/progress/", "no detiene nada", "atencion_requerida", "eventos clave" y el enlace al spec; anti-ancla que falla si el runbook dice que la interfaz "calcula" o "infiere" el progreso. | 7.1 | cc:TODO |
| 7.3 | `[lane:gate] [tdd:required]` **Núcleo puro `tablero-runbook/lib.ts`** sin dependencias: `validarFase(s)` con `^[0-9]{1,3}(\.[0-9]{1,3})?$`; `validarProgreso(doc)` → `{ok, razones[]}` con los valores cerrados del spec, `repo` con `^[A-Za-z0-9][A-Za-z0-9._-]{0,38}/[A-Za-z0-9._-]{1,100}$`, `pr` entero positivo < 10 000 000, truncado a 300 y rechazo de `schema` distinto; `derivar(doc)` → porcentaje mergeado, carriles atorados, siguiente ítem de cola, minutos desde el último evento; `renderTablero(doc, derivado, github?)` → HTML autocontenido (CSS inline, sin scripts, sin fuentes remotas) con una sola función `esc()` aplicada **en el punto de interpolación** a todo valor, en el orden truncar primero y escapar después; banner de `atencion_requerida` arriba de todo; `siguiente_paso` como primera frase; rótulo "GitHub: sin verificar" cuando no hay cruce; `fusionarEventos(previo, nuevo)` append-only con la política de tope y rotación de `summa-gate/observer.ts`. | `progress.test.ts` verde sobre los fixtures de 7.1; mutantes que dejan rojo: quitar `esc()` (un `<script>` en `titulo`, en `repo` y en un nombre de check de GitHub aparece literal), invertir truncar/escapar (una entidad cortada), quitar el truncado, aceptar un `estado` fuera de lista, aceptar `fase` con `/` o `..`, aceptar `repo` con `;` o que empiece con `-`, y perder eventos previos al fusionar. `scripts/run-checks.sh` gana un bloque propio `tablero-runbook` (`npm run check` + `node --test`) con guard de conteo (0 `pass` = FALLA), y `scripts/tests/test-summa-gate-quality-entrypoints.sh` se extiende para exigir lo mismo de `tablero-runbook/package.json`. | 7.1 | cc:TODO |
| 7.4 | `[lane:gate] [tdd:required]` **Cableado `tablero-runbook/index.ts` + manifest.** Método `runbook.progress.set` (scope `operator.write`): pasa `fase` por `validarFase` **antes** de tocar disco, valida con 7.3, persiste `<stateDir>/tablero-runbook/progress/<fase>.json` (last-writer-wins, escritura fail-open como `saveState` de summa-gate) y agrega a `<stateDir>/tablero-runbook/events/<fase>.jsonl` con tope y rotación; `runbook.progress.get` devuelve documento + derivado. Rutas HTTP con `auth: "gateway"`: `GET /runbook/tablero/<fase>` (HTML, `Content-Type: text/html; charset=utf-8`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'`) y `GET /runbook/progress/<fase>.json` (`application/json`). `stateDir`: el que 7.0 midió si está fuera del clon; si no, `configSchema.stateDir` con default fuera de `C:\Users\ehven\.openclaw`. Pestaña `registerControlUiDescriptor({surface:"tab", id:"runbook", label:"Runbook", path:"/runbook/tablero/6", group:"control", requiredScopes:["operator.read"]})` solo si 7.0 la confirma. Manifest con `activation.onStartup: true`, `backupResources` scope `state`, `configSchema` con `stateDir`, `fases` (default `["6"]`), `github.enabled` (default `false`) y `github.ghPath`. **Cero `registerHook`, cero `registerTool`.** En el mismo PR: `.gitignore` con `tablero-runbook/*.jsonl`, `tablero-runbook/*.log` y la ruta real de estado, y `scripts/tests/test-salida-del-observador-no-trackeada.sh` extendido con el bloque de `tablero-runbook`. | Tests con host simulado 100 % local (patrón de `summa-gate/role.test.ts`, sin importar `openclaw/plugin-sdk`; si se importa, se declara y se reusa el `OPENCLAW_NODE_MODULES` de `quality.yml`): `set` con documento inválido responde `{ok:false, razones}` y cero writes; `set` con `fase:"../../openclaw.json"` → `{ok:false}` y cero writes; `GET /runbook/tablero/..%2f..%2fopenclaw.json` → 400; petición sin auth no llega al handler; `get` de fase desconocida → 404 en la ruta y `{ok:false}` en el método; la ruta HTML devuelve los tres headers; el manifest no declara `contracts` de middleware ni tools; un fallo de disco se registra y responde `{ok:false, razon:"disco"}` sin lanzar. `node --check` de los `.ts`. El spec declara que `get` y la ruta `.json` exponen `residuales` y `eventos` a quien pase la auth del gateway. | 7.0, 7.3 | cc:TODO |
| 7.5 | `[lane:gate] [tdd:required]` **Cruce con GitHub, apagado por defecto.** Con `github.enabled: true`, en cada `GET` del tablero el plugin ejecuta `execFile(ghPath, ["pr","view",String(pr),"-R",repo,"--json","mergeable,mergeStateStatus,statusCheckRollup"], {shell:false, timeout, killSignal:"SIGKILL"})` solo para `repo`/`pr` que pasaron `validarProgreso`; `ghPath` viene de `configSchema.github.ghPath` (default `C:\Users\ehven\.openclaw\tools\bin\gh.exe`, nunca `PATH`) y debe terminar en `.exe` (un `.cmd` reabre el bug de quoting de Windows); subcomando fijo `pr view`, nada más. Presupuesto **total** de 8 s por render, máximo 10 PRs por render, `Promise.allSettled` con concurrencia ≤ 4, caché de 60 s por PR, `child.kill()` real al vencer; cualquier fallo pinta "GitHub: unknown" en esa fila. | Tests con `gh` simulado: éxito pinta el estado rotulado "GitHub"; timeout pinta `unknown`; con el fixture de diez PRs el render responde en < 8 s; con `github.enabled: false` no se ejecuta nada y el tablero dice "GitHub: sin verificar"; mutantes que dejan rojo: quitar el flag, `repo="a/b; calc.exe"` y `repo="--template x"` (no se ejecuta nada, la fila pinta `unknown`), `ghPath` terminado en `.cmd` rechazado, y quitar el `kill` (el proceso simulado sobrevive al timeout). | 7.4 | cc:TODO |
| 7.6 | `[lane:release] [tdd:skip:rollout-y-canary]` **Despliegue, canary y aviso a David.** Mergear a `main` (el sync lo lleva al gateway) en ventana segura (reglas Q2 de la Fase 6). Antes del `config patch`: cero runs de cron en vuelo y cero turnos activos, con salida verbatim (`openclaw cron runs` de los jobs con `Next` cercano y `sessions_list` por agente), porque un patch con runs en vuelo los mata (mecanismo *superseded* ya medido en este gateway). Habilitar con `openclaw config patch` (nunca editando `openclaw.json` en el repo): `plugins.entries.tablero-runbook.enabled: true`, `github.enabled: false`. Canary desde la Mac: `gateway call runbook.progress.set --params @tablero-runbook/fixtures/fase6-en-curso.json`, `runbook.progress.get`, `GET /runbook/progress/6.json` y el HTML; canary de que summa-gate sigue vivo tras el reload: `openclaw plugins list` con los dos habilitados y un `gh pr merge` de prueba desde un agente que sale bloqueado. Después, con eso verde, `github.enabled: true` y segundo canary. **Aviso:** un Telegram a David con el enlace directo al tablero y una línea de qué es; sin eso la herramienta existe y él no se entera. Rollback: `enabled: false` por config patch. | `docs/evidence/tablero-runbook-canary.md` con cada comando y su salida verbatim; el cuerpo de `GET /runbook/progress/6.json` y las primeras 30 líneas del HTML, donde deben aparecer literalmente el `titulo` del fixture y "GitHub: sin verificar" (primer canary) y "GitHub" con un estado (segundo); timestamps del log de corridas de cron antes y después del reload sin ninguna corrida nueva en medio; `plugins list` con summa-gate y tablero-runbook habilitados y el merge de prueba bloqueado; `message_id` del Telegram enviado. Sin cambios de modelos, auth ni permisos. | 7.4, 7.5 | cc:TODO |
| 7.7 | `[lane:release] [tdd:skip:cierre-y-ci]` **Cierre.** Un PR de docs (7.0, 7.1 spec y fixtures, 7.2) y un PR de código (7.3, 7.4, 7.5) en goncloud-openclaw, ambos desde `origin/main`; el de código se mergea después del de docs. `git log origin/main..HEAD` solo con commits de esta fase; pre-commit sin `--no-verify`; CI verde sobre el SHA final. Merge: autopilot por la ruta del kit según `docs/runbooks/autopilot-fase7.md`; si el gate no sella, el PR queda abierto con `APPROVE lead <sha>` y se lista en el Telegram (nadie mergea a mano dentro de la fase). Plans.md cierra con SHAs y salvedades. | Dos PRs verdes y mergeados; filas `cc:完了` solo con evidencia. | 7.6 | cc:TODO |

### Clasificación

**Required:** 7.0, 7.1, 7.2, 7.3, 7.4, 7.6, 7.7. **Recommended:** 7.5 (el cruce con GitHub; sin él el tablero sirve pero se rotula "sin verificar" en cada fila, para no dar confianza falsa). **Optional:** widget `show_widget` en el tablero de sesión alimentado por el mismo JSON; `runbook.progress.set` aceptando parches parciales (v2). **Reject:** inferir el progreso leyendo transcripts o PRs sin que el lead lo escriba (humo con buena cara); registrar hooks de agente en este plugin (mezcla guard con UI); un dashboard con dependencias (Next, React) para lo que cabe en un HTML de 200 líneas; hardcodear rutas del host en el código (van a `configSchema`).

### 事前確認 de Fase 7

- Evento: `git push` de rama + `gh pr create` en goncloud-openclaw (dos PRs).
  Razón: entrega; CI corre la batería una vez.
  scope: Fase 7 / Task 7.7.
- Evento: turno de solo lectura a main para el spike (`grep -l` en el `dist` de openclaw, `openclaw --version`, ruta de estado), llamadas `openclaw gateway call` desde la Mac, y un `curl` sin credencial contra el puerto del gateway.
  Razón: 7.0 y el canary de 7.6.
  scope: Fase 7 / Task 7.0, 7.6.
- Evento: `openclaw config patch` para habilitar el plugin `tablero-runbook` y, después, `github.enabled`; reload fuera de ventana de cron y con cero runs en vuelo; rollback `enabled: false`.
  Razón: 7.6 es el despliegue de la fase; cambio de config del gateway acotado a `plugins.entries.tablero-runbook.*`. Sin cambios de modelos, auth, permisos ni otros plugins.
  scope: Fase 7 / Task 7.6.
- Evento: código nuevo que corre vivo en el gateway (plugin sin hooks de agente) y un `gh pr merge` de prueba desde un agente que debe salir bloqueado.
  Razón: 7.4, 7.5 y el canary de summa-gate en 7.6.
  scope: Fase 7 / Task 7.4, 7.5, 7.6.
- Evento: un Telegram a David con el enlace al tablero.
  Razón: 7.6; sin aviso la herramienta no llega a quien la pidió.
  scope: Fase 7 / Task 7.6.

No hay secret-read: `gh.exe` ya está autenticado en el host; el plugin no lee ni imprime credenciales. No hay operación destructiva.
