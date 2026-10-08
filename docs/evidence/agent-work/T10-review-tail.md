# T10: revisión fuera de la cola de tmux (parcial)

G `3b307c9` añadió `review_tail_restart`. Contra R `5780efab16`, `AGENT_WORK_RUNTIME_SOURCE=/Users/dn/dev/openclaw-agent-work-integration bash scripts/tests/test-agent-work-e2e.sh review_tail_restart` pasó 1/1 en 23,3 s. El caso registra un resultado `Changes` en el Gateway aislado, comprueba su recibo durable, deja la respuesta fuera de las últimas 80 líneas de tmux, reinicia el proceso solicitante y ejecuta el reconciliador de G. El registro conserva la intención de corrección y R acepta exactamente un hijo de corrección. El fixture ahora acepta un presupuesto finito opcional; el primer intento mostró que un hijo sin presupuesto no podía admitirse.

La salida de tmux es sintética y la tarea se siembra directamente en el Gateway de prueba. El caso no acredita un revisor vivo, el despertar del modelo solicitante ni un repositorio de negocio; esas fronteras siguen pendientes para la aceptación completa de T10.

## B4-29-r1

Este commit va sobre la base `c5a4c6a`, con R `6e3d428` construido. La prueba previa (`scripts/tests/test_agent_work_review_tail_restart.py`) usa la ruta del director. La propia prueba fabrica la observación y llama al reconciliador, así que no acredita un despertar sin recordatorio humano (`acceptance.md:7`, fila A1). La ruta elegida es la del solicitante agente. R encola un despertar durable a la sesión que hizo `submit` (`src/agents/tasks/managed-task.delivery.ts:51-70`) y el modelo del solicitante decide con `managed_tasks_resolve`.

Lo que hay en este commit.

- El arnés `scripts/tests/fixtures/agent-work/managed-cli-gateway-harness.mjs` gana `pid` en su mensaje `ready` y `process.exit(0)` al terminar. Con `CROSS_TOOLS_PROFILE=full` publica `tools: { profile: "full", toolSearch: false }`. Con `CROSS_PROVIDER_SCRIPT=review-correction` el proveedor actúa como el modelo del solicitante. Ante el despertar de un resultado llama a `managed_tasks_inspect`, y solo si el resultado es `changes` y está `pending-handling` llama a `managed_tasks_resolve` con `continue` y un hijo `corregir` (`ready.v1`, mismo destino y misma revisión). Si la salida de `inspect` no es JSON, o el resultado no pide corrección, responde con un mensaje sin llamar a nada. También gana la op `tasks`, que lee tareas, hijos y manejos de la SQLite, y cada petición al proveedor registra `toolNames` y `answered`.
- `LoopGateway` (`scripts/tests/test_agent_work_main_cli_loop_e2e.py`) gana `reuse_state`, `extra_env`, `pid` y `kill()`, que mata el proceso sin `stop`, como una caída.
- La prueba nueva `scripts/tests/test_agent_work_review_correction_restart_e2e.py` registra y admite una revisión, mata el Gateway, arranca otro sobre el mismo estado con pid distinto, entrega `changes` y deja que el modelo con guion despierte solo, inspeccione y resuelva. La prueba ya no llama a `inspect` ni a `resolve`.
- El caso `review_correction_restart` en `scripts/tests/test-agent-work-e2e.sh` pide R y entra en `all`; sin R se salta.

Comando del rojo natural y del verde, con `LANG=en_US.UTF-8`.

```
AGENT_WORK_RUNTIME_SOURCE=/Users/dn/dev/openclaw-agent-work-integration python3 scripts/tests/test_agent_work_review_correction_restart_e2e.py
```

- Base sin cambios (`B4-29-base.log`). `bash scripts/tests/test-agent-work-e2e.sh delivery_latency` terminó `OK` con `rc=0`.
- Rojo natural, con solo la prueba aplicada (`B4-29-rojo-natural.log`). `rc=1` con `KeyError: 'pid'`, porque el arnés de entonces no decía su pid.
- Verde, con el arnés aplicado (`B4-29-verde.log`). `rc=0`, `OK`, y esta línea, con pids distintos, un solo manejo y un solo hijo.

```
REVIEW_CORRECTION_RESTART pid1=24649 pid2=26888 handlings=1 children=1 provider=['managed_tasks_inspect', 'managed_tasks_resolve', 'message']
```

- Siete mutaciones, cada una `rc=1` con un solo `FAIL`/`ERROR` y el texto esperado, deshecha con `cmp` limpio contra `impl.patch` (`B4-29-mutacion-<n>.log`). Con `blocked` en vez de `continue` salió `Lists differ: [] != [(`. Con el hijo en `review.v1` en vez de `ready.v1` salió `: 'review.v1'} != {`. Con dos hijos salió `'otro')] != [(`. Con el segundo Gateway sobre estado nuevo salió `the restart lost or changed the task`. Con el arnés ignorando `CROSS_TOOLS_PROFILE` salió `the requester never resolved` y la cuenta de `'managed_tasks_resolve'` en el log fue 0. Con el modelo siempre `NO_REPLY` salió `the requester never resolved`. Con el revisor aprobando en vez de pedir cambios salió `the requester never resolved`.

Regresión con R, un caso por corrida, todos `OK` con `rc=0` (`B4-29-reg-<caso>.log`): `cli_gateway`, `main_cli_loop`, `cli_silent_failure`, `cli_delivery_acceptance`, `review_correction_restart` y `review_tail_restart`, el caso del director, sin cambios. Suites cortas (`B4-29-cortas.log`): candados declarados y runbooks en `TODO VERDE`, `test-agent-work-e2e.sh` sin argumentos y sin R con `rc=0` y la prueba nueva saltada, ruteo `OK`, integración `OK (skipped=1)`, cinco `rc=0`.

Límites de esta parte. El revisor es un CLI doble, no un CLI en tmux, y no hay tail de 80 líneas; eso es B4-30. El modelo es un guion del arnés, no un modelo real. "Aceptada" es el `resolve` que R acepta: el hijo `corregir` queda `registered`, nadie lo admite y ningún CLI escribe su `accept.v1` (followups B4-29). El resultado llega después del reinicio (followups B4-29). El arnés pone `tools.profile full` y no está comprobado qué ve `main` en producción (followups B4-29).

Parte 2a de T10 (`:278`); no marca la casilla.

## B4-30-r1

Este commit va sobre la base `e40fe4a`, con R `6e3d428` construido. Tras B4-29 faltaban tres cosas medidas en VEREDICTO-B4-29-r1: el revisor no estaba en tmux, así que no había tail de 80 líneas; el hijo `corregir` quedaba `registered`, sin admisión ni `accept.v1`; y la prueba no fijaba sobre qué revisión ni a qué destino iba el hijo. En este commit hay las tres cosas. El revisor es el CLI doble nuevo `scripts/tests/fixtures/agent-work/review-cli.py`, corrido en un tmux real: acepta cada encargo que le tipean con su propio `accept.v1`, en el primero (la revisión) imprime su veredicto, lo empuja fuera de las últimas 80 líneas con 200 líneas más, imprime `review-cli review done` y deja el resultado `changes`; los siguientes (la corrección) solo los acepta. El guion del arnés, después de `resolve`, admite el hijo con `managed_tasks_admit` usando el id de `childTaskIds`, y la op `tasks` devuelve también el `target` de cada tarea. La prueba (`scripts/tests/test_agent_work_review_correction_restart_e2e.py::test_verdict_out_of_the_tail_and_a_crash_still_give_one_accepted_correction`) comprueba que el veredicto está en la pantalla (`capture-pane -S -`) y no en las últimas 80 (`-S -80`), mata el primer Gateway, arranca el segundo sobre el mismo estado, deja que el modelo despierte solo, inspeccione, resuelva y admita el hijo, y entrega el hijo al mismo CLI, que lo acepta. Exige un manejo y un hijo `corregir` `ready.v1` sobre la misma revisión y al mismo destino que la raíz, ninguna `review.v1` nueva del mismo SHA, el despertar como primer turno del modelo, y las peticiones exactas `inspect`, `resolve`, `admit` y un mensaje final. En `scripts/tests/test-agent-work-e2e.sh` el caso `review_tail_restart` corre esa prueba, el caso del director quedó como `review_tail_restart_director` y se fue `review_correction_restart`. En `acceptance.md`, `A1` y `T10:review_tail_restart` citan la prueba nueva y siguen `parcial`.

Comandos con `LANG=en_US.UTF-8 AGENT_WORK_RUNTIME_SOURCE=/Users/dn/dev/openclaw-agent-work-integration`.

- Base sin cambios (`B4-30-base.log`). `bash scripts/tests/test-agent-work-e2e.sh delivery_latency` terminó `OK` con `rc=0`.
- Rojo natural, con solo la prueba aplicada (`B4-30-rojo-natural.log`). `rc=1` con `the correction was never claimed`, porque el arnés de B4-29 no admite el hijo.
- Verde, con el arnés aplicado (`B4-30-verde.log`). `rc=0`, `OK` en 84,3 s, y esta línea, con pids distintos, un manejo, un hijo y la corrección aceptada.

```
REVIEW_TAIL_RESTART verdict_in_tail_80=0 pid1=9554 pid2=12472 handlings=1 children=1 correction_accepted=1 provider=['managed_tasks_inspect', 'managed_tasks_resolve', 'managed_tasks_admit', 'message']
```

- Ocho mutaciones, cada una `rc=1` con un solo `FAIL`/`ERROR` y el texto esperado, deshecha con `cmp` limpio contra `impl.patch` (`B4-30-mutacion-<n>.log`). Con el veredicto dentro de las últimas 80 líneas salió `the verdict is still in the last 80 lines`. Sin admisión del hijo, `the correction was never claimed`. Con el hijo sobre otro SHA, `the correction is not on the reviewed revision`. Con `blocked` en vez de `continue`, `the requester never resolved`. Con el segundo Gateway sobre estado nuevo, `the restart lost or changed the task`. Con el revisor aprobando en vez de pedir cambios, `the requester never resolved`. Con el CLI sin aceptar la corrección, `the CLI never accepted the correction`. Con el arnés ignorando `CROSS_TOOLS_PROFILE`, `the requester never resolved`.

La matriz estricta (`B4-30-estricto.log`) sigue `rc=1` con la misma lista que antes del encargo: `A1 parcial, A2 parcial, A3 parcial, A6 parcial, A8 parcial, A10 parcial, A11 parcial, A13 parcial, B1 parcial, B2 parcial, B3 parcial, B4 parcial, B5 parcial, B6 parcial, B7 parcial, T10:review_tail_restart parcial, T10:delivery_latency parcial, T10:idle_72h parcial, T10:cien_reenvios parcial`. Regresión con R, un caso por corrida, todos `OK` con `rc=0` (`B4-30-reg-<caso>.log`): `cli_gateway`, `main_cli_loop`, `cli_silent_failure`, `cli_delivery_acceptance` y `review_tail_restart_director`. Suites cortas (`B4-30-cortas.log`): candados declarados y runbooks en `TODO VERDE`, `test-agent-work-e2e.sh` sin argumentos y sin R con `rc=0` y la matriz de forma en `OK`, ruteo `OK`, integración `OK (skipped=1)`, cinco `rc=0`.

Límites de esta parte. El revisor es un doble que imprime y escribe, no un CLI real. El modelo es un guion del arnés. El resultado llega a R después del reinicio, aunque el revisor lo escribió antes (followups B4-29). El arnés pone `tools.profile full` (followups B4-29). El orden literal del plan falla en R: con el turno de despertar en vuelo al caer, R difiere la entrega y el turno recuperado no nombra la tarea, así que no hay corrección (followups B4-30). Por eso no se marca `:278`.

Parte 2b de T10 (`:278`); no marca la casilla.
