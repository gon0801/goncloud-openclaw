# SUA-00, mediciones: lo que se midió y el baseline

Fecha: 2026-10-13. Bloque SUA-00, pasos 3 y 4 del
[plan](../../superpowers/plans/2026-10-05-sistema-agentes-unificado.md).
El bloque SUA-00 no corrió nada vivo. David autorizó las mediciones vivas el
2026-10-13 ("1. si") y el coordinador las corrió ese día, de las 14:47 a las
15:05 UTC. Están en la sección "Mediciones vivas del 2026-10-13". Inventario
que acompaña: [SUA-00-inventario](SUA-00-inventario.md).

## Resumen para David

Las diez mediciones ya están hechas. Lo que salió:

- **Despertar a `main` por evento es rápido y barato si `main` está libre.**
  El turno empieza 2,3 segundos después del aviso y cuesta unos 20 500 tokens.
- **Si `main` está ocupado, el aviso por evento espera.** No se pierde, pero
  no empieza hasta que `main` termina lo que esté haciendo, aunque sea en otra
  sesión. Esperó 96 segundos detrás del vigía de bids.
- **Un mensaje directo a otra sesión no esperó.** Empezó en 2,8 segundos con
  otro turno de `main` en vuelo. Es una sola muestra.
- **Sesión nueva y `/new` cargan lo mismo:** unos 20 mil tokens de contexto
  base. No hay ahorro en reutilizar una sesión.
- **El vigía de bids gasta mucho más que hace dos días.** En 45 minutos hizo
  98 llamadas al modelo y 5,7 millones de tokens. El 11 de octubre eran 16
  llamadas cada 30 minutos.
- **Un cron aislado no puede pedir encargos.** R lo rechaza con el mensaje que
  dice el código.
- Nada de esto mandó mensajes a Telegram, y las sesiones de prueba quedaron
  borradas.

Con esto ya se puede elegir cómo se despierta el controlador de SUA-01 y
SUA-02. La elección sigue siendo de esos bloques.

## Ya medido, se reutiliza

### Ventana de 30 minutos del 2026-10-11

Fuente: `docs/evidence/agent-work/deploy-receipt.md`, sección "Contadores",
del 2026-10-11 19:44:31Z a las 20:14:37Z.

| Contador | Inicio | Fin |
|---|---|---|
| Eventos de la sesión `agent:main:canario-encargos` | 302 | 302 |
| Eventos de todas las sesiones de `main` | 18356 | 18422 |
| `managed_tasks` | 7 | 7 |
| `managed_task_incidents` | 3 | 3 |
| `managed_task_host_closures` | 7 | 7 |
| Tokens de opencode en el pane `canario` | 41.0K | 41.0K |
| Procesos `openclaw agent` en la Mac | 0 | 0 |
| Crons vigía habilitados | `bids-02-vigia` | `bids-02-vigia` |

Línea literal: "Conclusión: cero inferencia atribuible a vigilar encargos."
Los 66 eventos nuevos de `main` y las 16 llamadas al proveedor fueron todos de
`bids-02-vigia`, un cron cada 5 minutos. Esto vale para la ruta
`main` → `mac-local/opencode` y no se repite (corrección K11 del plan).

### Latencias de B22

Fuente: `docs/evidence/agent-work/B22-canarios.md`.

| Qué | Valor | Dónde |
|---|---|---|
| Pedido a `main` hasta cierre del host en R, canario A intento 2 | 64,8 s | tabla Canarios, "Pasaron 64,8 s entre el `created_at` de la tarea y el cierre del host en R" |
| Reinicio del host hasta `estado` con pid nuevo | menos de 10 s, 4 de 4 veces | "El corte, paso a paso", paso 6 |
| Pasadas del host perdidas por túnel ssh | 4 en el corte, la siguiente reclamó | "En `enc-1/host.log`, 4 pasadas fallaron con `gateway closed (1006 …)`" |
| Intervalo de la pasada del host | 1 s por omisión, tope 5 s | `scripts/agent-work/native_gateway.py:883-887` |

### Consumo por corrida de subagente nativo

Fuente: `docs/evidence/agent-work/limits.json` y `T11-limites-medicion.md`.
Copia consistente de la Mini del 2026-10-09, 1923 corridas de subagente del
2026-09-23 al 2026-10-09.

| Medida por corrida | Mediana | p95 | Máximo |
|---|---|---|---|
| Llamadas al modelo | 5 | 65 | 1440 |
| Tokens de entrada | 112 460 | 3 495 223 | 445 540 546 |
| Tokens de salida | 2 324 | 27 681 | 252 098 |
| Tokens del árbol | 114 248 | 3 514 452 | 445 792 644 |

Profundidad máxima observada 1, hijos simultáneos máximo 2, hijos totales
máximo 4. Los topes de `limits.json` son máximo observado × 10 por decisión de
David (2026-10-10, B8).

### Rondas de revisión del loop de encargos

Fuente: `docs/evidence/sistema-agentes-unificado/revision-2026-10-12/decisiones-para-david.md`, punto 1. 81 veredictos:
62 en ronda 1, 15 en ronda 2, 1 en ronda 3 y ninguno más arriba. Ningún tope
entre 3 y 5+5 habría cambiado nada.

## Baseline de coste y latencia del ciclo actual

Lo que se puede afirmar con recibos. Lo que no, dicho como tal.

| Dimensión | Baseline | Fuente | Qué no se puede medir |
|---|---|---|---|
| Vigilancia de un encargo por CLI | 0 llamadas al proveedor en 30 min | deploy-receipt.md, Contadores | nada |
| Vigilancia de un loop de claw con vigía | El 2026-10-11: 16 llamadas al proveedor en 30 min. El 2026-10-13: 98 llamadas y 5 709 579 tokens en 45 min (9 corridas de `bids-02-vigia`) | deploy-receipt.md, Contadores; M-04 de este documento | por qué subió entre las dos fechas. No se leyó el loop de bids |
| Latencia pedido → resultado cerrado, ruta por CLI | 64,8 s para un encargo de un archivo | B22-canarios.md | latencia de un encargo real de ingeniería. Ningún loop real corre por la ruta |
| Latencia pedido → resultado, ruta nativa | mediana 83,4 s, p95 1 570,3 s, 902 corridas de subagente | M-05 de este documento | la latencia de un encargo nativo (`managed_tasks_submit` con destino agente): no hay ninguno |
| Coste en dinero | `unknown` | n/a | todos los proveedores de la ruta por CLI cobran por suscripción salvo deepseek (`proveedores-permitidos.json`, `billing`). No hay tarifa por token que multiplicar |
| Rondas de corrección por bloque | 1 ronda en 62 de 81 veredictos | decisiones-para-david.md | el coste en tokens de una ronda. No se midió |
| Despertar por evento, `main` libre | 2,28 s hasta el inicio del turno; 20 502 tokens | M-01 de este documento | nada |
| Despertar por evento, `main` ocupado | espera hasta que termina el turno en vuelo: 96,1 s detrás del vigía | M-02 de este documento | la espera máxima. Depende de lo que dure el turno en vuelo |

## Mediciones vivas del 2026-10-13

Autorización: David, 2026-10-13, "1. si" a la pregunta de si se corrían las
mediciones sobre el gateway. Las corrió el coordinador desde la MacBook, de las
14:47 a las 15:05 UTC.

Entorno medido: gateway OpenClaw 2026.9.7 en la Mini (`gon@100.73.187.5`, pid
49116, R `4acb881`). CLI de la Mac: `~/.openclaw-r/openclaw`, 2026.9.7
(`4b9785c`). Modelo de `main` en todos los turnos: `opencode-go-resp/muse-spark-1.3-contributor`.

Cómo se leyó cada turno: consultas de solo lectura sobre
`~/.openclaw/agents/main/agent/openclaw-agent.sqlite` en la Mini, tabla
`trajectory_runtime_events`. El inicio del turno es el evento `session.started`,
que trae el disparador (`data.trigger`). Cada llamada al proveedor es un evento
`provider.payload.measured`. Los tokens salen de `model.completed`, campo
`data.usage`. Las horas de emisión son del reloj de la MacBook y las de los
turnos, del reloj de la Mini. Los dos relojes se compararon ese día por ssh,
tres veces: la Mini iba 0,15 s adelante, con 0,22 s de ida y vuelta. Las esperas
de este documento que cruzan los dos relojes llevan ese margen, menos de 0,3 s. Las salidas crudas quedaron en
`~/.local/state/sua-loop/mediciones/` de la MacBook, fuera del repo.

Las sesiones de ensayo se llamaron `agent:main:sua-ensayo-20261013-<n>`, con
`n` de 1 a 7. Ninguna llamada llevó `--deliver`.

### Resultados

| ID | Qué se hizo | Resultado |
|---|---|---|
| M-01 | `openclaw system event --mode now --timeout 15000 --session-key agent:main:sua-ensayo-20261013-1 --text "ensayo SUA-00 M-01: contesta NO_REPLY" --json`, emitido a las 14:51:45.264 sin ningún turno de `main` en vuelo | El comando contestó `{"ok": true}` a los 1,80 s, antes de que empezara el turno. La sesión no existía y el evento la creó a las 14:51:47.252. El turno empezó a las 14:51:47.541, 2,28 s después de la emisión, y terminó a las 14:51:49.089. Disparador `heartbeat`. Una llamada al proveedor, 81 952 bytes. Tokens: 20 479 de entrada, 23 de salida, 20 502 en total. Contestó `NO_REPLY` |
| M-02 | Tres pasadas, descritas abajo | Un evento con `main` ocupado no se pierde y no abre un turno paralelo: espera. Un `agent --message` a otra sesión sí corre en paralelo |
| M-03 | `/new` sobre la sesión 1 con `openclaw agent --agent main --session-key … --message-file`, y después un turno | El gateway contestó "✅ New session started." y escribió un evento `reset` con `reason: new`. El `session_id` no cambió. El primer turno después cargó 20 216 tokens de contexto (391 de entrada más 19 825 leídos de caché). Una sesión nueva cargó 20 479, 20 479 y 20 484 en tres muestras. La diferencia es de caché, no de contexto |
| M-04 | Un turno por `agent --message` en la sesión 7 que llama una vez `managed_tasks_inspect` sobre la tarea cerrada `9ed258fc-59c1-4e72-ba3d-36819bea0eb9` y contesta `NO_REPLY` | 2 llamadas al proveedor, 165 209 bytes, 8,0 s. Tokens: 830 de entrada, 40 162 leídos de caché, 416 de salida, 41 408 en total. Más el coste real del vigía, abajo |
| M-05 | Consulta de solo lectura sobre `subagent_runs` en `~/.openclaw/state/openclaw.sqlite` de la Mini, abierta con `mode=ro`. No fue sobre una copia. Duración de `createdAt` a `endedHookEmittedAt` | 902 corridas del 2026-09-23 al 2026-10-12. Mediana 83,4 s, p90 776,0 s, p95 1 570,3 s, máximo 609 577 s. Con solicitante `main`: 894 corridas, mediana 82,9 s, p95 1 573,5 s. Con solicitante `ingenieria`: 8 corridas, mediana 292,9 s, p95 414,9 s |
| M-06 | Leer `conversation_deliveries` en la base de `main` después de los ensayos | 0 filas con origen en una sesión de ensayo y 0 filas creadas o cambiadas desde la emisión de M-01. No salió nada a Telegram |
| M-07 | Cron de un disparo `sua-ensayo-m07`, `--session isolated --no-deliver`, corrido con `cron run`. Llamó `managed_tasks_inspect` y no `managed_tasks_submit`, para que no pudiera crear una tarea. Las dos herramientas pasan por la misma guarda, `captureManagedTaskTurn` (`managed-tasks-tool.ts:30`) | La herramienta devolvió `"error": "Managed task requires a durable requester session, not an isolated cron run"`. La corrida duró 5,9 s y gastó 41 619 tokens. El cron se borró con `cron rm` (`"removed": true`) y la lista volvió a 30 |
| M-08 | `openclaw sessions delete --yes --json` con las siete llaves de ensayo, desde la Mac y sin `--agent` | Las siete contestaron `deleted`. `session_nodes` de `main` bajó de 56 a 49. Queda la fila de la corrida del cron de M-07: `sessions delete` contesta `not_found` para una sesión `agent:main:cron:<id>:run:<id>`, con y sin `--agent main`. Pasa lo mismo con cada corrida de un cron aislado; las limpia `session.maintenance` |
| M-09 | `openclaw cron list --json` | 30 crons, los 30 habilitados. Un solo vigía: `bids-02-vigia` (`main`, cada 300 s, aislado, sin entrega). 19 `skill-collection-review-<agente>` semanales. 10 de negocio o mantenimiento: `packing-extras-7h` y `-11h`, `packing-digest-faseA-censo`, `-faseB-armado` y `-faseC-envio`, `verif-digest-20h`, `cuotas-proveedores`, `Memory Dreaming Promotion`, el de la renovación del token de Shopify y `seguimiento-yours-virtually-miercoles` (un disparo el 2026-10-14) |
| M-10 | `ps -o rss=` del proceso del gateway antes y después, y `openclaw health --json` | RSS 3 176 128 KB a las 14:47:43 y 3 384 224 KB a las 15:05:21: subió 208 096 KB en 17,6 minutos. En ese rato corrieron los ensayos y también cuatro corridas del vigía, así que la subida no se puede atribuir a los ensayos. `health` no trae una métrica de heap. El event loop no se degradó (`delayP99Ms` 21,1 antes y 21,5 después). El gateway corre con `--max-old-space-size=8192` |

### M-02, las tres pasadas

La primera pasada, a las 14:54:39.808, no sirvió para la pregunta: la corrida
del vigía de las 14:54:04 duró 20,1 s y ya había terminado. El turno empezó
2,06 s después de la emisión. Vale como segunda muestra de M-01 (20 499 tokens).

Pasada con un turno propio en vuelo. Un `agent --message` a la sesión 3 pidió
correr `sleep 45` con `exec`. Ese turno corrió de las 14:56:03.334 a las
14:56:52.0.

| Aviso | Emitido | Su turno empezó | Espera |
|---|---|---|---|
| `system event` a otra sesión de `main` (la 4) | 14:56:16.637 | 14:56:52.542, medio segundo después de que terminó el turno en vuelo | 35,9 s |
| `system event` a la misma sesión ocupada (la 3) | 14:56:17.999 | 14:56:56.838, después de que terminó el turno de la sesión 4 | 38,8 s |

Los dos avisos produjeron un turno cada uno, en el orden en que se emitieron.

Pasada con el vigía en vuelo. La corrida de `bids-02-vigia` de las 14:59:04.529
duró 106,6 s y terminó a las 15:00:51.238. El evento a la sesión 5 se emitió a
las 14:59:15.399 y su turno empezó a las 15:00:51.468: **96,1 s de espera**, y
0,23 s después de que el cron terminó. El vigía corre en una sesión aislada,
distinta de la del aviso.

Pasada con `agent --message`. Con un turno en vuelo en la sesión 3 (de las
15:01:15.196 a las 15:01:53.4), un `openclaw agent --agent main --session-key
agent:main:sua-ensayo-20261013-6 --message-file …` emitido a las 15:01:26.168
empezó su turno a las 15:01:29.000, **2,83 s después**, y terminó antes que el
turno de la sesión 3. Corrió en paralelo.

Lo que esto dice: los despertares por `system event --mode now` de `main` van
uno detrás de otro y detrás de cualquier turno de `main` en vuelo, sea de otra
sesión o de un cron aislado. Un `agent --message` a una sesión distinta no
entró en esa fila en la única muestra que se tomó.

No se midió: un `agent --message` a una sesión que ya tiene un turno en vuelo,
un evento a `main` mientras el ocupado es otro agente, ni el modo
`next-heartbeat`.

### El vigía de bids, medido

Las nueve corridas de `bids-02-vigia` de las 14:19 a las 14:59, leídas con la
misma consulta:

| Inicio | Duración | Llamadas al proveedor | Tokens en total |
|---|---|---|---|
| 14:19:04 | 143,6 s | 14 | 956 993 |
| 14:24:04 | 57,1 s | 7 | 317 849 |
| 14:29:04 | 9,0 s | 2 | 42 367 |
| 14:34:04 | 113,9 s | 17 | 903 997 |
| 14:39:04 | 93,5 s | 14 | 864 682 |
| 14:44:04 | 108,5 s | 16 | 1 093 207 |
| 14:49:04 | 139,1 s | 15 | 831 754 |
| 14:54:04 | 20,1 s | 2 | 42 039 |
| 14:59:04 | 106,6 s | 11 | 656 691 |

Suma: 98 llamadas y 5 709 579 tokens en 45 minutos. La mayor parte son tokens
leídos de caché. Una corrida que no encuentra nada que hacer cuesta 2 llamadas
y unos 42 mil tokens. Una que trabaja hace de 7 a 17 llamadas con `exec`. En
siete de las nueve corridas, `main` estuvo ocupado entre 57 y 144 segundos de
cada 300. La ventana del 2026-10-11 dio 16 llamadas en 30 minutos; esta da 98
en 45. No se investigó por qué subió.

### Un `NO_REPLY` por `agent --message` se reintenta

Hallazgo de M-03, con una sola muestra. El turno posterior a `/new` entró por
`agent --message` (disparador `user`) y el modelo contestó solo `NO_REPLY`. El
gateway repitió la llamada: dos veces con `opencode-go-resp` y dos con
`opencode-go-resp-2`, las cuatro con `NO_REPLY`, y después cayó a
`claude-cli/claude-opus-5-5`, que escribió 75 532 tokens de caché. Fueron cinco
llamadas donde bastaba una, por tres entradas de proveedor del gateway. Las dos
primeras llevan el nombre de opencode Go; no se leyó la configuración para
saber si son dos cuentas o una.

Con disparador `heartbeat` (`system event`), `NO_REPLY` se aceptó a la primera
en las cuatro muestras. En M-04, con una herramienta antes del `NO_REPLY`, no
hubo reintento y el CLI devolvió el texto "The tool run finished, but no final
summary was produced."

### Qué deciden estas mediciones

La regla de este documento era elegir el verbo con M-01, M-02 y M-04 en la
mano. Los hechos que pesan:

1. Un controlador que despierte por `system event` en el agente `main` empieza
   en 2,3 s si `main` está libre y espera lo que dure el turno en vuelo si no.
   Con el vigía de bids activo, esa espera llegó a 96 s y puede llegar a 144 s.
2. Un `agent --message` a una sesión distinta de la que tiene el turno en vuelo
   no esperó (una muestra). No se midió el mensaje a una sesión ya ocupada. Su
   turno tiene que contestar con texto, no con `NO_REPLY` solo: en la muestra
   que lo hizo se pagaron cinco llamadas.
3. Cada despertar cuesta unos 20 500 tokens de contexto base, con sesión nueva
   o con `/new`. Uno que además llama una herramienta cuesta unos 41 mil.
4. Un cron aislado no sirve de solicitante de `managedTasks`.
5. La sesión de la corrida de un cron aislado no se puede borrar por llave
   desde la Mac.

Lo que queda sin medir y decide SUA-01 o SUA-02 si lo necesita: el coste de un
cron con sesión durable, y el efecto de sacar al controlador a un agente
propio, distinto de `main`.

## Lint y formato de R

Leído en `/Users/dn/dev/openclaw-agent-work-integration` en `4acb881e015a`.
No se corrió nada sobre R.

| Qué | Comando literal | Herramienta | Configuración |
|---|---|---|---|
| Formato | `pnpm format:check` → `oxfmt --check` (`package.json:1814`) | oxfmt 0.68.0 | `.oxfmtrc.jsonc`: ancho 100, comillas dobles, punto y coma, coma final `all`, ordena imports, ignora `**/*.json` |
| Lint | `pnpm lint` → `node --import ./scripts/tsx.mjs scripts/run-lint.mts` (`:1849`) | oxlint 1.83.0 con oxlint-tsgolint 7.0.2002, más stylelint y una verificación i18n (`scripts/run-lint.mts:10-41`) | `.oxlintrc.json` y `config/oxlint/` |
| Tipos | `pnpm tsgo:core` → `node scripts/run-tsgo.mjs -p tsconfig.core.json --incremental ...` (`:2197`) | tsgo, typescript 7.1.0-dev | `tsconfig.core.json` |
| Pruebas | `node scripts/run-vitest.mjs <archivo> --testNamePattern <caso>` | vitest 5.0.1 | `vitest.config.ts`, `test/vitest/` |
| Pre-commit de R | `scripts/pre-commit/run-node-tool.sh oxlint --type-aware src test` y `... oxfmt --check src test` (`.pre-commit-config.yaml:87-97` de R) | los mismos | |
| CI de R | job `check-shard` corre `pnpm lint` y `pnpm format:check` (`.github/workflows/ci.yml:5034`, `:5040-5042`); `check-lint-core-<stripe>` corre `scripts/run-oxlint-shards.mts --only=core --split-core` (`:5245-5246`) | | Si ese CI corre para la rama `feat/agent-work-integration`: `unknown`, depende de `github.repository == 'openclaw/openclaw'` |

Un bloque que escriba en R corre `pnpm lint:core`, `pnpm format:check` y
`pnpm tsgo:core` sobre sus archivos antes del commit, como ya hicieron B4 a B18
(`docs/evidence/agent-work/B4-*-tsgo-core.log`).

## Alcance de lint y formato para los módulos nuevos de G

G no tenía lint ni formato de Python: ni `pyproject.toml`, ni `ruff.toml`, ni
hook, ni paso en CI. La única validación era correr las pruebas `unittest` por
sus envolturas `.sh`. SUA-00 deja configurado el alcance para lo nuevo sin tocar
el legado:

- `ruff.toml` en la raíz con `include` limitado a `scripts/sistema_agentes/**/*.py`
  y `scripts/tests/test-sistema-agentes-contrato.py`, `target-version = "py39"`
  y `line-length = 100`. Un archivo fuera de `include` no se revisa ni se
  reformatea.
- Hooks `ruff` y `ruff-format` en `.pre-commit-config.yaml`, con `files`
  limitado a esas mismas rutas. `pre-commit run --all-files ruff` no toca ningún
  archivo legado.
- Cada módulo nuevo que SUA cree en G entra al `include` en el mismo PR que lo
  crea. El legado (`scripts/agent-work/`, `scripts/mac/corrida_worker/`) entra
  solo cuando un bloque lo migre y lo diga en su recibo.

La corrida que lo prueba está en [SUA-00-mutaciones](SUA-00-mutaciones.md),
sección "Alcance del lint".
