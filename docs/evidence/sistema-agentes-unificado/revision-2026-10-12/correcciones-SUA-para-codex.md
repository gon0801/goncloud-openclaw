# Correcciones al diseño SUA (para aplicar en `~/dev/wt/flota-poteto`)

Autor: Claude Code, revisión del 2026-10-05/06. Cada corrección trae su evidencia y el texto para pegar. Rutas relativas a `~/dev/wt/flota-poteto`:
- **D** = `docs/superpowers/specs/2026-10-05-sistema-agentes-unificado-design.md`
- **P** = `docs/superpowers/plans/2026-10-05-sistema-agentes-unificado.md`
- **PL** = `Plans.md`

**Paso 0, antes de editar.** Guarda la versión actual de codex en un commit local en `feat/flota-poteto`, sin push: hoy son 4 archivos sin trackear más 12 modificados, y se pierden si alguien limpia el worktree. Después aplica estas correcciones en un segundo commit.

## 1. Orden con el loop de encargos (P:28-40, PL:38-44)

**Evidencia:**
- SUA-01 reescribe `managed-task.{store,types,budget.*,recovery*}.ts`, `server-methods/managed-tasks.ts` y `core-descriptors.ts`. B4 ya cambió 12 de esos archivos (`git -C /Users/dn/dev/openclaw-agent-work-integration diff --name-only 3c1c748 6e3d428`).
- El plan de encargos prohíbe dos escritores en paralelo sobre `R.taskStore` (`docs/superpowers/plans/2026-09-30-encargos-agentes.md:67` en origin/main).
- La base G de SUA (`e5cae2d`) no contiene los commits G de B4: incidencias de host, `CLI_ROUTES main→mac-local`, `coverage.json.modelWakes`, `main_cli_loop` y los detectores de `cli_silent_failure`. Hoy van de `encargos/b4` 82f26f4 a e655060 y siguen.

**Texto para P**, después de la tabla de bases (P:35):
> **Orden con encargos.** SUA-01 y cualquier bloque que escriba en `src/agents/tasks/` empieza después de que B4 de encargos esté mergeado en main. SUA-00 puede correr antes, en solo lectura, partiendo de la cabeza de `encargos/b4` y no de `e5cae2d`. Su inventario incluye incidencias de host (`managedTasks.host.incident`, `Host.record_incident`/`flush_incidents`), `CLI_ROUTES`, `coverage.json.modelWakes`, `main_cli_loop` y `detect_silent_failures`. **B5 (T11–T12): decisión de David pendiente.** O lo termina el loop de encargos, o SUA-09 lo absorbe con filas explícitas para la ventana de 30 min sin inferencia de vigilancia, la plantilla `prompt-claw` sin `<loop>-vigia` y `limits.json`. Nunca los dos.

**Texto para PL:38**, columna de estado de la fila Encargos:
> cc:WIP — B4 en curso en `encargos/b4`; SUA-01 espera su merge; B5 pendiente de decisión de David

**PL:42**, el "orden histórico". Cambia "El orden histórico U3b → flota → U4/U5 → U6 queda sustituido" por lo siguiente. Ese orden nunca estuvo en main; la Fase F solo existe en el PR #247.
> El orden vigente en main (U3 → U3a → base de encargos → U3b → U4 → U5 → U6; "U3b solo con U3a al 100%", decisión de David del 2026-09-30, P9636) queda sustituido para el trabajo futuro, **cuando David apruebe este orden**.

Tampoco hay ningún registro de que David haya aprobado el orden SUA: solo pidió diseño (`architecture-task.md`).

## 2. Política de rondas (D:238-248)

**Evidencia:**
- La regla 5+5 **sí fue orden de David**: P9580 del 2026-09-30 00:15Z, "Pon límite 5 rondas si necesita más cambia de modelo… si ese modelo tiene otras 5 rondas y no puede ahora si pregunta". Está en `35c0661`/PR #227, fila 9 de "Decisiones de David — no se vuelven a discutir".
- stop2 la impuso `8358fac`/`a19501c` (autor `t`) sin decisión de David registrada.
- Los loops de claw corren hoy con 5+5 (`~/.local/state/encargos-loop/PROMPT.md:327-330`).
- A David le molesta que un agente "haga sus propias reglas" (P9591).

**Sustituir D:238-248 por:**
> Cuatro es un límite inicial propuesto, no una cifra medida. La última orden de David sobre rondas (2026-09-29, PR #227, fila 9) es 5 rondas por implementador, relevo a otro modelo con otras 5 y después preguntar. stop2 la sustituyó en `8358fac` sin decisión registrada. Implementar la política no la activa. **La adopción es una sola decisión explícita de David que fija el número de ciclos (por ejemplo 3, 4 o 5+5) y su alcance.** Se registra recibo con principal, alcance, versión/digest anterior y nuevo, fecha y read-back. Una autorización genérica del programa no la activa. Mientras falte esa decisión, los loops de claw conservan la regla 5+5 de David y el resto de repos la regla vigente de su repo. Las raíces existentes conservan su versión de calidad; una promoción no amplía sus ciclos. No se edita manualmente el bloque administrado de AGENTS.md para adelantarse a esa migración.

Lo que se quita es "Si la autorización del programa ya cubre ese cambio, se usa sin volver a preguntar" y "ni una orden histórica de David".

## 3. Promesa visible: Telegram (P, SUA-10O, paso 2)

**Evidencia:**
- La promesa de U3b (fila 20.10) era que David pide por Telegram en prosa y recibe el cambio mergeado y desplegado, sin preguntas fuera de una excepción.
- "Telegram" aparece 0 veces en D, P y la cobertura.
- El "Resultado buscado" de PL todavía dice "avisa por Telegram".

**Agregar a SUA-10O, paso 2:**
> Uno de los pedidos llega por Telegram en prosa a OpenClaw y termina con el cambio mergeado y desplegado. Los avisos y excepciones de ese pedido llegan por Telegram, sin preguntas fuera de una excepción tipada. Es el `FUNCIONA` que heredan 20.10 y U4.

**Agregar a SUA-02:**
> Canal de avisos y excepciones: Telegram vía OpenClaw, el mismo destino que los crons actuales. Se lee de la configuración, nunca se pega en el repo. Qué agente recibe el pedido (claw/`main`) y quién redacta el plan desde lenguaje natural (un trabajador con modelo, validado por `decide`) se fija aquí.

## 4. Choque con `SessionGoal` (P:121, P:144)

**Evidencia:**
- R ya tiene `SessionGoal` y el comando `/goal`, con estados `active|paused|blocked|usage_limited|budget_limited|complete` y `tokenBudget` (`packages/gateway-protocol/src/schema/sessions-goal.ts:6-31` y `src/config/sessions/goals*.ts`, en 6e3d428).
- SUA propone `src/agents/goals/` y un `Goal` propio, y no menciona el existente.

**Agregar en SUA-00, paso 2:**
> Decidir la relación con `SessionGoal`/`/goal` de R antes de crear `src/agents/goals/`: reutilizar, extender o renombrar. Dos conceptos "goal" con pausa y presupuesto propios no conviven.

## 5. Datos menores que corregir

- **P:410**, `director_handling`: sí existe, como `DirectorHandlingTest` en `scripts/tests/test-agent-work-integration.sh`, desde 77fafb0.
- **P:36-39**, el bug `--model\nwrong`: `e5cae2d` ya rechaza caracteres de control (`registry.py _check_argv_element`) y tiene su prueba. Hay que decir cuál es el residuo, por ejemplo `worker_argv` en `lib.sh`, que sustituye `{brief}`/`{worktree}`/`{session_*}` sin validar.
- **FC:519** (contrato de flota): todavía dice que U3b conserva `corrida_worker.reconcile()` como único decisor, y contradice SUA-02.
- **PL:46,** "Reconciliación de números": "17 = U4/U5" ya no aplica.

## Lo que decide David, no codex

1. Si aprueba el orden SUA.
2. B5: lo hace el loop o lo absorbe SUA-09.
3. El número de ciclos de corrección y si adopta v2.
4. Si el PR #247 se cierra o se redefine, porque SUA rechaza su código.
