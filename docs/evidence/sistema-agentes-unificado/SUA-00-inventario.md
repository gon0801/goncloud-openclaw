# SUA-00, inventario por ruta: lo que existe, lo que corre y lo que se probó en vivo

Fecha: 2026-10-13. Bloque SUA-00, paso 1 del
[plan](../../superpowers/plans/2026-10-05-sistema-agentes-unificado.md).
Bases: G `2213b930`, R `4acb881e015a` (instalado en la Mini), O `d83bb28`
(checkout local sin fetch), H sin inventario. La forma legible por máquina es
[SUA-00-inventario.json](SUA-00-inventario.json), esquema `sua-inventario.v1`.
No extiende `runtime-map.json`: ese archivo es el mapa del checkout y el build
de R, y lo leen `test-runtime.sh`, `artifact.py` y dos pruebas por
`runtime.localCheckout`. Un inventario de rutas de cuatro códigos no es un mapa
del build de R, y sus lectores cargarían datos que no usan.

Todo lo que dice este documento se leyó en el repo o en un recibo. Nada se
corrió en vivo. Cada afirmación cita archivo y símbolo, o recibo y línea.
`unknown` es una respuesta y va con el comando que la contestaría.

## Resumen para David

Hoy el trabajo entre agentes viaja por **cinco rutas vivas** y hay **cuatro que
ya no arrancan**.

Vivas y probadas con un pedido real:

1. **Turno nativo.** Le hablas a `main` por Telegram o por comando y contesta.
   Probada todos los días.
2. **Hijo nativo.** Un agente abre un subagente con `sessions_spawn`. Probada:
   1923 corridas medidas del 23 de septiembre al 9 de octubre.
3. **Encargo por CLI.** Dices "por CLI" y `main` lanza un proceso de opencode
   por encargo en la Mac, con el modelo que pidas de los proveedores permitidos.
   Probada el 13 de octubre con el canario D y con un pedido después del corte.
   Es la única ruta certificada en `coverage.json`.
4. **Incidencias y cancelación del host.** Si el encargo falla o lo cancelas, el
   host se lo dice a R y R te lo dice a ti. Probada en los canarios.
5. **Cron vigía.** Un loop de claw con vigía despierta cada 5 minutos. El 11 de
   octubre gastaba 16 llamadas al proveedor cada 30 minutos; el 13 de octubre,
   98 en 45 minutos. Solo queda `bids-02-vigia`.

Vivas en el código pero sin prueba en vivo en este bloque:

- **Corrida por `corrida.sh`** (abrir, lanzar CLIs en tmux, reconciliar,
  compuertas). Tiene 18 subcomandos y sus pruebas. La copia instalada en `~/bin`
  no es la del repo, y el merge automático nunca pudo correr porque ningún
  script escribe `authorization_ref`.
- **Encargo nativo a un agente** (`managed_tasks_submit` con destino agente).
  R lo soporta. Ningún pedido real pasó por ahí.
- **Hook Stop y vigilante tmux.** El hook está registrado. El vigilante no está
  cargado en esta Mac. El latido está apagado a propósito.

Ya no arrancan: la sesión adoptada de opencode (host B8), los hosts por alias
de modelo, `lanzar-host.sh`, y el latido como LaunchAgent.

**Los huecos que importan para decidir el orden de SUA-01 en adelante:**

- `coverage.json` se contradice. Dice `inventory-only` y no tiene la ruta viva
  en `managedRequesterRoutes`. Su foto de crons es del 7 de octubre. SUA-04 y
  SUA-09O parten de ese archivo. Hay que alinearlo antes.
- No hay medición del despertar por evento. Sin M-01 a M-04 de
  [SUA-00-mediciones](SUA-00-mediciones.md) no se elige el verbo del
  controlador. Eso es de SUA-01 y SUA-02.
- La ruta de corrida tiene piezas sin punto de entrada y una copia instalada
  vieja. Decidir si SUA-03 la migra o la retira ahorra trabajo a SUA-05.
- Hermes no está en esta Mac. SUA-07 no puede empezar sin saber dónde corre.
- R no tiene fan-in, hijos iniciales sin resultado padre, ni pausa de tareas.
  `SessionGoal` no sirve de base. SUA-01 construye la raíz junto a
  `managedTasks`.

## Después del inventario: decisiones y mediciones del 2026-10-13

El inventario de arriba y las tablas de abajo son la foto de SUA-00. Ese mismo
día, David contestó las cuatro preguntas que el inventario dejó abiertas: "1. si
2. es en gon pc 3, se wuita 4. se quita".

| Pregunta | Respuesta | Qué cambia |
|---|---|---|
| ¿Se corren las mediciones vivas? | Sí | Corridas el 2026-10-13. Resultados en [SUA-00-mediciones](SUA-00-mediciones.md). El hueco "no hay medición del despertar por evento" queda cerrado |
| ¿Dónde corre Hermes? | En la PC de Gon | `gon-pc` en la red privada, Windows. A las 15:05 UTC del 2026-10-13 estaba fuera de la red; versión e interfaces siguen `unknown` |
| ¿La ruta de corrida se migra o se retira? | Se retira | Las filas de "Rutas de corrida" pasan a ser historia cuando entre el PR del retiro. SUA-02, SUA-03 y SUA-05 pierden los archivos que tomaban de ella (marcas `corr: D13` del plan) |
| ¿La sesión adoptada se borra o se guarda? | Se borra | La fila "Sesión adoptada de opencode" y las piezas sin punto de entrada salen del repo en su propio PR |

La lista de crons vivos (M-09) confirma la fila "Cron vigía": hay 30 crons y un
solo vigía, `bids-02-vigia`.

## Cómo leer las tablas

Tres columnas que nunca se mezclan:

- **Fuente**: lo que dice el repo en la base de arriba.
- **Instalado**: la copia que corre en esta Mac, o en la Mini según los recibos.
- **Aceptado en vivo**: un pedido real que pasó por la ruta, con el recibo.

Cada columna tiene una capacidad: `passed`, `failed` o `unknown`. `failed` en
"instalado" significa que no corre o que la copia no es la del repo. `unknown`
lleva su razón y el comando que lo contestaría.

## Rutas nativas (R)

| Ruta | Versión y ubicación | Dueño | Autoridad | Resultado y recibo | Fuente | Instalado | Aceptado en vivo |
|---|---|---|---|---|---|---|---|
| Turno de agente por canal o RPC | R `4acb881`; `managed-task.turn.ts` liga el turno admitido | R | Scopes del gateway; principal `[sender, channel, accountId, senderId]` (`managed-task.turn.ts:58-59`) | Respuesta en la sesión; transcript | `passed`: `managed-task.turn.channel.test.ts:157-174` | `passed`: R `4acb881` en la Mini (`B22-canarios.md`, encabezado) | `passed`: cada canario se mandó con `openclaw agent --agent main` (`B22-canarios.md`, Canarios) |
| Hijo nativo (`sessions_spawn`) | R `4acb881`; `src/agents/spawn-pipeline.ts`, tabla `subagent_runs` | R | `agents.defaults.subagents` (`maxConcurrent` 8, `maxSpawnDepth` 5) | Anuncio al solicitante; fila en `subagent_runs` | `passed`: `capabilities.md`, registro durable `available` | `passed`: 1923 corridas en la copia de la Mini (`limits.json`, `measuredOn`) | `passed`: `T11-limites-medicion.md` §2, 885 filas de `subagent_runs` |
| Encargo nativo (`managed_tasks_submit` con destino agente) | R `4acb881`; `src/agents/tasks/`, 46 archivos, 11 tablas `managed_task_*` (`openclaw-state-schema.sql:1593-1712`), schema `state: 27` | R | Solicitante en `managedTasks.requesters` (`openclaw-tools.managed-tools.ts:37-59`); un cron isolated se rechaza (`managed-task.turn.ts:42-44`) | `review.v1` o `ready.v1` (`managed-task.json.ts:172-182`); despertar `systemEvent task:<id>` (`managed-task.delivery.ts:60-70`) | `passed`: `test-runtime.sh` casos `registration_identity`, `result_receipt`, `admission_restart` | `passed`: `managedTasks.enabled: true`, `requesters: ["main"]` (`deploy-receipt.md`, Checklist posterior) | `unknown`: ningún pedido real con destino agente. `coverage.json` marca `ingenieria → adversary` y `operaciones → ingenieria` con `certified: false`. Comando: leer `managed_tasks` con `target.kind = agent` en la Mini |
| `SessionGoal` y `/goal` | R `4acb881`; `packages/gateway-protocol/src/schema/sessions-goal.ts:6-31` | R | RPC con scope `operator.write` (`core-descriptors.ts:263-264`) | `SessionEntry.goal`; recibos en `session_goal_operations` | `passed`: `goals.test.ts` (16 casos), `goals-operations.test.ts` (13) | `unknown`: ningún recibo de este bloque lo probó en la Mini. La fuente dice que `/new` borra el goal (`src/auto-reply/reply/session.ts:1027`; `docs/tools/goal.md:116` de R). No se mide: SUA no reutiliza `SessionGoal` | No es ruta de trabajo. Está aquí por la decisión del contrato: no se reutiliza |

Lo que R no tiene y SUA-01 va a construir: fan-in A+B→C (`managed_task_children.child_task_id` es `UNIQUE`, un solo padre), hijos iniciales sin resultado padre, pausa de una tarea gestionada (solo existe `Cancel` en cascada), época de control, y recuperar la capacidad del solicitante después de `/new` (hoy la entrega va a dead letter si cambió el `sessionId`, `server-restart-sentinel.ts:148-152`). Fuente: `revision-2026-10-12/explorer-C-codigo.md` y el fact sheet de R de este bloque.

## Rutas por CLI (G y R)

| Ruta | Versión y ubicación | Dueño | Autoridad | Resultado y recibo | Fuente | Instalado | Aceptado en vivo |
|---|---|---|---|---|---|---|---|
| Encargo por CLI, un proceso por encargo (`main` → `mac-local/opencode`) | G desde `4000a1d4` (PR #284); `lanzar-encargos.sh`, `native_gateway.py --workspace-root`, `sesion.py`, `brief.py --model`, `encargo.py`; opencode 1.18.35 | G (host) y R (tarea) | `--device-auth` en todo `managedTasks.host.*` (`native_gateway.py:73-74`); `assertHostDevice` en R (`managed-tasks.ts:145-162`); política `proveedores-permitidos.json` por `authorize` (`modelos.py:577`); grupo `agent-work-enc1` (`lanzar-encargos.sh:21`) | `agent-work.result.v1` en `runs/<op>/result.json` (`contracts.py:46-48`); spool `enc-1/host.sqlite`; en R `result_json`, `admitted`, `host_closure AbsenceVerified` | `passed`: `coverage.json` `hostAdapterRoute.mac-local.opencode` forma `run-per-task`, 1.18.35; 120 pruebas en `test-agent-work-{sesion,encargo,lanzar-encargos}.py` | `passed`: checkout del host en `4000a1d4`, `opencode 1.18.35` en `/opt/homebrew/bin`, `brief.py` y skill `encargo-cli` en la Mini (`B22-canarios.md`, Cierre y Otros hechos) | `passed`: canario D, tarea `595755ae…`, `glm-4.7`, `acknowledged\|AbsenceVerified`; tarea `9ed258fc…` con el host sin canario (`B22-canarios.md`) |
| Sesión adoptada de opencode (host B8) | Retirada del repo el 2026-10-13. En G `2213b930` quedaban sin llamador `claim_cli_once` (`native_gateway.py:384`), `TmuxTransport` (`host.py:1014`) y `detect_silent_failures` (`host.py:714`) | G | La misma de arriba | `agent-work.result.v1`; spools `mac-local`, `-b`, `-c` cerrados | `failed`: David decidió "se quita" y el código salió del repo con sus pruebas e2e (`followups.md`, fila "B22 (ruta adoptada sin punto de entrada)"). Queda lo que cierra un spool de esa ruta: `--close-only` sobre filas `UserAdopted` (`LegacyAdoptionTests`, `test-agent-work-resources.py`) | `failed`: host B8 apagado el 2026-10-13, sha `bff085d7` (`B22-canarios.md`, El corte, paso 2) | `passed` histórico: 7 tareas y 7 cierres `ReleasedAdopted` el 2026-10-11 (`deploy-receipt.md`, R al cierre). Ya no arranca |
| Host por alias de modelo (`lanzar-host.sh`, `opencode@<proveedor>/<modelo>`) | Borrado en `4000a1d4` | G | n/a | spool `deepseek-1` cerrado | `failed`: `git grep lanzar-host -- scripts` da 0 | `failed`: `deepseek-1` apagado desde el 2026-10-12 (`followups.md`, B19 dos hosts) | `passed` histórico: canario 8 el 2026-10-12, cerrado por David ese día (`deploy-receipt.md`, Cobertura efectiva) |
| Hijo de una CLI | Cada CLI | cada CLI | La de la CLI; G no la mide | El de la CLI padre | `unknown`: G no modela hijos de CLI; el barrido del grupo los alcanza al cerrar (`B22-canarios.md`, Otros hechos: `tracker.js` de tokentracker) | `unknown` | `unknown`: es I08 e I09 de SUA-03 |

Lo que B22 dejó y SUA no repite: el catálogo sale de `opencode models` y la
política de `proveedores-permitidos.json` (ocho permisos y tres cierres con la
frase de David). Un modelo nuevo de un proveedor permitido corre sin editar
nada (canario D). La guarda `external_directory` no confina el shell
(`followups.md`, B22-S7). Claude por su propio CLI está pendiente (B22-S5).

## Rutas de corrida (`scripts/mac/`)

| Ruta | Versión y ubicación | Dueño | Autoridad | Resultado y recibo | Fuente | Instalado | Aceptado en vivo |
|---|---|---|---|---|---|---|---|
| Inicio de una CLI en tmux (`corrida.sh lanzar-sesion`, `adaptador start`) | G `2213b930`; `scripts/mac/corrida/*.sh`, `workers.v1.json` con siete trabajadores (`claude_fable`, `claude_opus`, `kimi_k3`, `kimi_coding`, `codex`, `zcode`, `grok`), `max_external_sessions: 4` | G | Lock del registro, reserva del carril, registro validado (`adaptador.sh:256-266`); `_check_argv_element` rechaza caracteres de control y operadores de shell (`registry.py:147-162`); `worker_argv` revisa cada argumento sustituido (`lib.sh:1024-1025`). Sin device auth | `LISTO <sha>` o `VEREDICTO` en el pane (`estado.sh:79-80`); `ADAPTADOR-MARCA` (`adaptador.sh:290`); `~/.local/state/corridas/<id>/registro.json` con `schema: corrida.v2` | `passed`: `test-native-harness-adapters.sh`, `test-adaptador-reserva.sh`, `test-worker-registry.sh`, `test-worker-model-binding.sh` (en main desde el 2026-10-12) | `unknown`: `~/bin` difiere del repo en 10 scripts de `corrida/`, 3 de `corrida_worker/`, falta `task_handoffs.py` y no existe `~/bin/agent-work/`. Comando: `bash scripts/mac/instalar-mac.sh --verificar` | `unknown`: ningún recibo de este bloque muestra una corrida real con un pedido de David. Los loops de claw usan ventanas tmux por `prompt-claw`, no `corrida.sh`. Comando: `corrida.sh seguimiento --json` |
| Reanudar una CLI (`adaptador resume`) | Igual; argv `resume:<rol>` con `--continue` | G | La misma | `resumed` o `unavailable` (`adaptador.sh:415`) | `passed`: `test-native-harness-adapters.sh` | `unknown`: misma copia desfasada | `unknown`: sin recibo de un resume real |
| Decisor de corrida (`reconciliar`, `compuerta`, `task_handoffs.py`) | G `2213b930`; `corrida_worker/{reconcile,gates,selector,registry,state,task_handoffs}.py`; `corrida-worker.py` | G | `gates.py`: revisión aprobada del head, revisor no autor, cero bloqueantes (`:251-264`); `mismo-revisor` (`:244-248`) y `bloqueante-repetido` con `rounds_seen >= 2` (`:401-402`); merge exige `authorization_ref` en `preaprobaciones.v1.json` (`compuerta.sh:68`); `resolve_via_gateway` llama `managedTasks.resolve` sin `--device-auth` (`task_handoffs.py:569-581`) | `CONVERGED`, `EXECUTED`, `REOBSERVAR` (`reconciliar.sh:52-74`); `ALLOW` o `DENY` (`compuerta.sh:211-215`); eventos `gate.*` y `evidence.*` en el registro | `passed`: `test-corrida-reconcile.sh`, `test-corrida-gates.sh` (fixtures 15 y 16), `test-agent-work-integration.py:1751` | `failed`: `~/bin/corrida_worker` no tiene `task_handoffs.py` | `unknown`: ningún script de G escribe `authorization_ref` ni `rounds_seen`. Con el kit apagado, `merge` da `DENY kit-no-disponible` (`compuerta.sh:95-98`). Nunca hubo un merge automático con recibo |

Las formas de resultado de esta ruta no tienen spec en `docs/spec/`. `LISTO
<sha>` lo lee una regex en `estado.sh:79-80` y `progress-events.py:174-175`.
`VEREDICTO` lo lee `progress-events.py:176-177`. `agent-work.result.v1` vive en
`host.py:24` y `:154-182`, y `ready.v1` y `review.v1` solo como valores en
`routing.py:35` y en prosa en la skill `encargo-cli` (`SKILL.md:33`, `:36`).
El contrato `sistema-agentes.v1` los envuelve en `resultado`.
`corrida.v2` guarda `lanes`, `effects`, `evidence`, `outcome` y
`authorization_ref` (`docs/spec/corrida.v2.md`). Es el único registro de G que
ya separa efectos ejecutados de evidencia por SHA. El contrato
`sistema-agentes.v1` lo toma como lectura histórica y no lo extiende.

## Host de encargos: piezas que el plan pide por nombre

| Pieza | Dónde | Estado tras B22 | Entrada hoy |
|---|---|---|---|
| `managedTasks.host.incident` | R `managed-tasks.ts:402-433`; G `native_gateway.py:215` | vigente | `flush_incidents` desde `pump_once` (`native_gateway.py:851-852`) |
| `record_incident` | `host.py:954-969` | vigente | `refuse` (`:503`) y `detect_run_failures` (`:861`). Las llamadas desde `detect_silent_failures` (`:771`, `:774`) se borraron con él el 2026-10-13 |
| `flush_incidents` | `host.py:971-990` | vigente | `pump_once`. Un rechazo definitivo no se reintenta (`DEFINITIVE_INCIDENT_REJECTIONS`, `native_gateway.py:34-45`) |
| `CLI_ROUTES` | `routing.py:15`: `{("ingenieria", "windows-remote"), ("main", "mac-local")}` | vigente solo para las skills `managed-task-routing` de `ingenieria` y `operaciones` | `main` no lo usa: `test_main_cli_route_points_main_at_the_encargo_cli_skill_and_not_at_routing_py` (`test-agent-work-routing.py:182`). `windows-remote` sigue `disabled-host-unverified` |
| `coverage.json.modelWakes` | `coverage.json:122-217` | desfasado | Foto del 2026-10-07 con 14 entradas. Dos citas de línea ya no cuadran (`latido.sh:224` contra `:220-221`; `settings.json:129` contra `:122`). Lista vigías que `deploy-receipt.md` da por cerrados el 2026-10-11 |
| `main_cli_loop` | `test_agent_work_main_cli_loop_e2e.py`; caso `main_cli_loop` de `test-agent-work-e2e.sh` | recortado el 2026-10-13 | Se borró el caso que armaba a mano la ruta adoptada. Conserva `test_isolated_cron_run_cannot_submit` (R rechaza un submit desde un cron aislado) y `LoopGateway`, el arnés de R que usa `cutover_fencing` |
| `detect_silent_failures` | `host.py:714-778` en la base | borrado el 2026-10-13 | Ninguna. Se fue con la ruta de sesión adoptada, junto con `settle_deliveries` y sus pruebas. La ruta viva usa `detect_run_failures` (`host.py:790`, `native_gateway.py:604` en la base) |
| `managedTasks.host.cancellation` | R `managed-tasks.ts:371-401`; G `native_gateway.py:186` | vigente | La pasada del host. Probada en vivo: canarios A intento 1 y B terminaron `cancelled\|AbsenceVerified` |
| `cutover_live.py` | `scripts/agent-work/cutover_live.py`, `agent-work-cutover.v2` | vigente sin `adapters` | `prepare\|inspect\|apply\|freeze\|revert` (`:424`). `rollback` (`:355`) es función sin subcomando. Probado en vivo: `loop:canario-encargos` con dueño `native` en generación 2 (`deploy-receipt.md`, El corte) |
| `ProgressPublisher` | `native_gateway.py:654` | vigente | `pump_once` (`:866`) y `watch_pump` (`:889`). Sin encargo con `progressBinding` después del arreglo (`deploy-receipt.md`, Lo que no se pudo comprobar) |

De las piezas sin punto de entrada que B22 dejó a decisión de David, el
2026-10-13 se borraron `claim_cli_once`, `TmuxTransport`,
`ShellAdapterTransport`, `detect_silent_failures` y `Spool.cancellation`
(`followups.md`, fila "B22 (ruta adoptada sin punto de entrada)", cerrada).
Siguen sin punto de entrada `corrida.sh adaptador deliver-ref`
(`adaptador.sh:16`), que perdió a su único llamador, y `cutover_live.rollback`.
La skill `native-harness-orchestration` de `main` (`SKILL.md:68`) ya no describe
esa ruta. Falta publicarla en la Mini.

## Despertares, crons y vigías

| Ruta | Versión y ubicación | Dueño | Autoridad | Resultado y recibo | Fuente | Instalado | Aceptado en vivo |
|---|---|---|---|---|---|---|---|
| Hook Stop de Claude Code | `scripts/mac/claude-stop-openclaw-event.sh` | G, registro en la Mac | Exige `OPENCLAW_WATCH=1` y se calla con `AGENT_WORK_MANAGED=1` (`:36-44`) | `openclaw system event --mode now --session-key agent:main:vigia-mac` o `corrida.sh avisos emitir` (`:135-149`); sin recibo, salida a `/dev/null` | `passed`: `test-tmux-activity-watch.sh`, `test-u3a-19-3.sh` | `failed`: registrado en `~/.claude/settings.json:122`, pero la copia de `~/bin` no trae el bloque `AGENT_WORK_MANAGED` (5 líneas de diferencia) | `unknown`: sin recibo de un despertar lanzado por este hook. M-01 midió el mismo verbo (`system event --mode now`) lanzado a mano |
| Vigilante tmux (`tmux-activity-watch.sh`) | `scripts/mac/tmux-activity-watch.sh`; LaunchAgent `ai.goncloud.tmux-activity-watch` | G | Vigila `OPENCLAW_WATCH=1`, excluye `AGENT_WORK_MANAGED=1` (`:200-205`) | `system event` por quietud de 900 s, diálogo o cierre; lanza `corrida.sh latido` cada 300 s (`:104-106`) | `passed`: `test-tmux-activity-watch.sh` | `failed`: plist en disco, no cargado (`launchctl print`: Could not find service); copia de `~/bin` con 21 líneas de diferencia | `failed`: no corre. Sin él nadie lanza el latido desde esta Mac |
| Latido de corrida (`corrida.sh latido`) | `scripts/mac/corrida/latido.sh`; LaunchAgent `ai.goncloud.corrida-latido` | G | n/a | `progress-events.py publish-all`, `system event` (`:220`, `:347`) | `passed`: `test-corrida-latido.sh` | `failed` a propósito: no cargado desde el 2026-09-27 y tiene que seguir así (`T12-runbook.md:290`) | `failed` a propósito |
| Cron vigía de un loop (`<loop>-vigia`, isolated, cada 5 min) | Gateway en la Mini; recreador `prompt-claw` §7 | gateway | Un cron isolated no puede ser solicitante de `managedTasks` (`managed-task.turn.ts:42-44`) | Turno con modelo cada 5 min | `passed`: foto de 11 crons vigía en `coverage.json.modelWakes` del 2026-10-07; `test_every_live_cron_is_classified` (`test-agent-work-routing.py:314`) | `passed`: `openclaw cron list --json` del 2026-10-13 da 30 crons y un solo vigía, `bids-02-vigia` (M-09). `coverage.json.modelWakes` sigue con la foto vieja | `passed`: solo `bids-02-vigia`. El 2026-10-11, 66 eventos de sesión y 16 llamadas al proveedor en 30 min (`deploy-receipt.md`, Contadores). El 2026-10-13, 98 llamadas al proveedor y 5 709 579 tokens en 45 min (`SUA-00-mediciones.md`, "El vigía de bids, medido") |
| Crons de negocio | Gateway | gateway | `scheduledToolPolicy` del servidor | Turnos propios | `passed`: 27 `out-of-perimeter` en `coverage.json` | `passed`: 30 habilitados el 2026-10-11 | `passed`: 30 habilitados, 0 corriendo (`deploy-receipt.md`, Checklist posterior) |

## Orbit (O) y Hermes (H)

| Código | Base | Receta o instalación | Fuente | Instalado | Aceptado en vivo |
|---|---|---|---|---|---|
| O | `d83bb28902e97949fea7b3fabc5fed6203d936b1`, checkout local `master`, sin fetch en este bloque | `docs/DEPLOY.md` de `goncloud-Orbit`: receta manual con ssh y docker, rebuild con `--no-deps`, salud en 8010 (plan, SUA-08) | `unknown`: se relee `origin/master` en SUA-08 | `unknown`: no se leyó el servidor | `unknown`: sin recibo versionado de un deploy |
| H | `unknown` | En esta Mac no hay runtime de Hermes: `~/.hermes` no existe, `which hermes` vacío, `pip3 show hermes-agent` no lo encuentra, `brew list` no lo lista. Existe `~/dev/goncloud-hermes` (configuración versionada de nueve perfiles) y `~/.hermes-ss` (ayudante de capturas para claw, no es el runtime). En G, `hermes` es un valor de vigía de corrida (`abrir.sh:22`, `latido.sh:228-230`) | `unknown` | `unknown`: corre en `gon-pc` (Windows), según David el 2026-10-13. Esa máquina estaba fuera de la red al medir; falta la versión | `unknown`: SUA-07 paso 1 |

## Consumidores de quality-kit en G

No hay `AGENTS.md` ni `CLAUDE.md` en la raíz de G, así que no hay bloque
administrado que migrar. Lo que sí hay, como mecanismo:

| Archivo | Qué hace |
|---|---|
| `.pre-commit-config.yaml:1` | Hooks generados por `init-repo.ps1`, marcador `QUALITY-KIT MANAGED` |
| `.github/workflows/quality.yml:285` | Shards con `SAIKIT_SHARD`; valida `.saikit/progress/*.json` (`:146`) |
| `scripts/run-checks.sh:65-77` | Lee `SAIKIT_SHARD` |
| `tests/run.sh:27` | Alias que el kit exige: `exec bash scripts/run-checks.sh` |
| `scripts/ci-fast-allowlist.txt:36-37` | `.saikit/progress/*` en el carril rápido |
| `scripts/cierre-de-fase.sh:325`, `scripts/arranque-de-fase.sh:213` | Leen y escriben `.saikit/progress/` |
| `scripts/lanzar-fase.sh:103` | Centinela `-saikit:autopilot` en el mensaje inicial |
| `summa-gate/index.ts:281`, `summa-gate/lib.ts:75` | `SENTINEL_RE` y `ADVERSARY_ZONE_RE` (`.saikit/findings`, `.saikit/scratch`) |
| `scripts/mac/corrida/compuerta.sh:184`, `:95-98` | Busca el contrato del kit; sin kit, `merge` da `DENY kit-no-disponible` |
| `scripts/mac/corrida_worker/gates.py:28`, `:18`, `:244-248`, `:401-402` | `saikit-entrega.v1`; compuerta `cross-review`; `mismo-revisor`; `bloqueante-repetido` |
| `scripts/mac/corrida/autoridad-merge.sh:85-97` | Exige `saikit-entrega.v1` en modo kit. Sin llamador fuera de pruebas |
| `scripts/mac/corrida/preaprobaciones.v1.json:9` | Decisión del 2026-09-28: con el kit apagado ningún PR trae `saikit-entrega.v1` |

Como texto: `docs/runbooks/loop-autopilot.md:112` copia la regla 4 con stop2 y
rotación de revisor, y 219 archivos mencionan `quality-kit`, `saikit` o
`cross-review` fuera de `docs/evidence`, casi todos rastro histórico en
`Plans.md`, runbooks y memorias de workspaces. Lo que SUA-05 retira:
`mismo-revisor` y `bloqueante-repetido` de `gates.py` y la copia de
`loop-autopilot.md` §4. Lo que conserva: revisión aprobada del head exacto,
revisor que no es autor y cero bloqueantes.

## Defectos encontrados y no arreglados

Van a `docs/evidence/agent-work/followups.md`, sección "SUA-00". Ninguno cambia
conducta en este bloque.

1. `coverage.json` se contradice consigo mismo (ya en la fila T12 `coverage.json`
   de `followups.md`): `status: inventory-only`, sin `main → mac-local/opencode`
   en `managedRequesterRoutes`, con una ruta `main → mac-local/claude_opus`
   `disabled-operator-setup-pending`, y `modelWakes` del 2026-10-07 con citas de
   línea viejas.
2. `~/bin` no es el repo: `claude-stop-openclaw-event.sh` y
   `tmux-activity-watch.sh` sin la exclusión `AGENT_WORK_MANAGED`, 10 scripts de
   `corrida/` y 3 de `corrida_worker/` distintos, falta `task_handoffs.py`, no
   existe `~/bin/agent-work/`.
3. El merge automático de corrida no puede correr: ningún script escribe
   `authorization_ref` ni `rounds_seen`. `bloqueante-repetido` nunca dispara en
   producción y `merge` da `DENY kit-no-disponible`.
4. `corrida.sh autoridad-merge` no está en la lista de subcomandos y
   `autoridad-merge.sh` no define `corrida_autoridad_merge`. Deducido de lectura.
5. Instalado, `adaptador.sh:312` y `lanzar-sesion.sh:37` buscan `host.py` en
   `~/agent-work/host.py`, y el instalador lo deja en `~/bin/agent-work/`
   (`instalar-mac.sh:164`). Sin `AGENT_WORK_HOST_BIN` la copia no lo encuentra.
   Deducido de lectura.
6. Corregido el 2026-10-13: `native-harness-orchestration/SKILL.md:68` describía
   la ruta adoptada que ya no arranca. Falta publicar la skill en la Mini (fila
   T12 `coverage.json` de `followups.md`).
7. En R, `usage_limited` de `SessionGoal` no lo escribe ningún código y
   `continuationTurns` nunca se incrementa (`goals-transitions.ts:95`,
   `:117`). No afecta a SUA porque no se reutiliza. Se anota para R.
8. La prueba de tabla de redacción de R no cubre los parámetros RPC de
   `managedTasks.host.*`, donde `capability` trae un campo `token`
   (`managed-tasks.ts:93`, `:109`, `:120`, `:134`). Un campo nuevo ahí no lo
   atrapa.

## Cómo se hizo

Dos fact sheets de solo lectura, uno sobre R y otro sobre G y esta Mac,
levantados por subagentes con rutas y líneas. Treinta citas de los fact sheets
se comprobaron contra el árbol antes de pegarlas aquí, y diez más al redactar
este documento (`routing.py:15`, `native_gateway.py:384`, `:420`, `:654`,
`:827`, `host.py:714`, `:790`, `:954`, `:971`, `gates.py:247`, `:401-402`,
`cutover_live.py:21`, `managed-task.turn.ts:42-44`, `managed-tasks.ts:371`,
`:402`, `managed-tasks-tool.test.ts:802`, `goals-transitions.ts:79-81`). No se
usó ssh, ni `tmux -L agent-work`, ni ningún comando `openclaw`, ni se leyó
`~/.local/state/agent-work-host`, `~/.ssh`, `.env` ni `~/.openclaw-r/openclaw.json`.
