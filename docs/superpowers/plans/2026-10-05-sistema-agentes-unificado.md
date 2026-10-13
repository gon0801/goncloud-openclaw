# Plan: Sistema unificado de agentes

Fecha: 2026-10-05. Identificador: **SUA**. Estado: **SUA-00 cerrado el 2026-10-13 (PR #288 y #289); SUA-01 a SUA-11 autorizados de corrido el 2026-10-13**.
<!-- corr: K1 -->
Revisado el 2026-10-12 contra G `6e01ec0` y R `605aef7`, después del cierre de encargos.
<!-- corr: B22 -->
Bases y contacto con B22 actualizados el 2026-10-13 contra G `c11d74ed` y R `4acb881`.
<!-- corr: D14 -->
Puesto en ejecutable el 2026-10-13 contra G `f1d25bbf` (PR #292) y R `4acb881e`,
después de retirar la ruta de corrida (PR #291) y la sesión adoptada (PR #290).

<!-- corr: C1.6 K9 K10 -->
Este plan es el único programa futuro para U3b, U4, U5, U6 y flota. David aprobó
su orden el 2026-10-13 (abajo, "Decisiones de David vigentes"). Integra la adopción
selectiva de OpenCode. Retira el último resto de coordinación de quality-kit que
sigue en G: el paro por bloqueante repetido copiado en la §4 de
`docs/runbooks/loop-autopilot.md` (`:112`). <!-- corr: D14 -->
`scripts/mac/corrida_worker/gates.py`, que traía ese paro y la rotación forzada
de revisor, salió del repo con la ruta de corrida (PR #291) y ya no hay nada que
retirar de él. La revisión con otro modelo ya la quitó David
en todos los repos. Sus planes anteriores son antecedentes; no se ejecutan en
paralelo ni se suman como una segunda batería de aceptación. El plan de encargos
cerró y no se reabre: sus seguimientos abiertos los cierra su propio loop, no SUA.

- [Diseño y contratos](../specs/2026-10-05-sistema-agentes-unificado-design.md).
- [Cobertura de todas las filas y aceptación](../../evidence/sistema-agentes-unificado/cobertura.md).
- [Fuentes, decisiones y revisión](../../evidence/sistema-agentes-unificado/revision.md).

## Resultado y alcance

Un pedido de dominio o ingeniería avanza entre agentes nativos y CLI, con poteto,
especialistas competentes, modelos acreditados, límites persistentes, revisión y
evidencia. Los agentes nuevos se conectan automáticamente cuando cumplen su perfil.
Los sucesores de modelos se promueven tras comprobar acceso y capacidad. OpenClaw
y Hermes funcionan en sus computadoras con estado y credenciales independientes.

<!-- corr: D14 -->
La autorización vigente es la del 2026-10-13 (abajo). Cubre implementar, lanzar
trabajadores, integrar en R y en G, instalar versiones de R en la Mini de madrugada
y el cambio de dueño de SUA-09, en el orden de este plan y sin volver a preguntar
por cada paso. No cubre el deploy de producción de Orbit (SUA-08 paso 4 y el
ensayo real de SUA-10O) ni ninguna decisión de dinero o de proveedor: ahí se avisa
a David y se espera su respuesta. Una autorización se interpreta con su alcance
real y se conserva; no se vuelve a pedir para cada paso que ya cubra.
<!-- corr: C1.6 C2 -->
Dos cosas no las cubre nunca una autorización genérica del programa: el orden SUA
frente al orden vigente en main y la política de rondas de corrección. Las dos
son decisiones explícitas de David, con fecha y registro. Las dos ya están
tomadas: el orden, el 2026-10-13; las rondas, el 2026-10-12. <!-- corr: D14 -->

<!-- corr: B22 -->
**Decisiones de David vigentes.**

<!-- corr: D14 -->
- 2026-10-13, después de las mediciones y de los dos retiros: "1. sí todo 2. sí de
  madrugada 3. si y entonces tienes que corregirnplan antes?". Contesta tres
  preguntas del coordinador. Uno: autoriza todo SUA de corrido, de SUA-01 a SUA-11,
  en el orden de este plan. Dos: las versiones nuevas del gateway se instalan en la
  Mac Mini sin preguntarle, de madrugada (sección "Regla de instalación en vivo").
  Tres: el cambio de dueño de SUA-09 también va sin esperarlo. Antes de esa
  respuesta el coordinador le dijo qué no quedaba cubierto: el deploy de producción
  de Orbit (SUA-08) y cualquier decisión de dinero o de proveedor; ahí se avisa y se
  espera. Su cuarta frase pide corregir el plan antes de arrancar: eso es esta
  revisión. Las marcas `<!-- corr: D14 -->` señalan cada lugar que esa autorización
  y los dos retiros del mismo día cambian; donde una nota `D13` decía "queda sin
  objeto" o "se decide al abrir el bloque", `D14` escribe qué se hace en su lugar.
- 2026-10-13: "1. sí solo SUA-00 2. claude y glm". Autorizó SUA-00 y nada más. Lo
  implementó Claude y lo revisó GLM. SUA-00 cerró ese día con los PR #288
  (inventario y contrato) y #289 (mediciones). La autorización de arriba la
  sustituye para SUA-01 en adelante. <!-- corr: D14 -->
<!-- corr: D13 -->
- 2026-10-13, después del inventario: "1. si 2. es en gon pc 3, se wuita 4. se quita".
  Contesta las cuatro preguntas que dejó SUA-00. Uno: autoriza las mediciones vivas
  sobre el gateway; se corrieron ese día y están en
  `docs/evidence/sistema-agentes-unificado/SUA-00-mediciones.md`. Dos: Hermes corre
  en la PC de Gon (`gon-pc` en la red privada, Windows). Tres: la ruta de corrida
  (`scripts/mac/corrida.sh`, `corrida/`, `corrida_worker/`, `workers.v1.json`) se
  retira; no se migra a SUA. El retiro alcanza a los consumidores de `corrida.sh`:
  el vigilante tmux y el hook Stop siguen sin ella, y el instalador y las skills
  dejan de nombrarla. Cuatro: la ruta de sesión adoptada de encargos se
  borra con sus pruebas. Los dos retiros fueron en PR propios ese mismo día: #290
  (sesión adoptada) y #291 (ruta de corrida) <!-- corr: D14 -->. Las marcas
  `<!-- corr: D13 -->` de este plan señalan cada lugar que esas respuestas cambian.
- 2026-10-12: las rondas siguen la regla 4 de quality-kit, con tope de 5 rondas por
  implementador y relevo a otro modelo con otras 5. La propuesta de cuatro ciclos
  queda inactiva.
- 2026-10-12: el PR #247 se cerró. Su arreglo de argv entró a main por un PR aparte.

## Bases y preparación

<!-- corr: K1 -->
El plan `2026-09-30-encargos-agentes.md` cerró al 100% el 2026-10-11 con el PR
#266 (G `71b3bc3`). Recibo: `docs/evidence/agent-work/deploy-receipt.md`. Las
bases inspeccionadas por el diseño (G `e5cae2d`, R `6e3d428`, main `77fafb0`) ya
no sirven.

| Código | Base | Uso y qué cambió frente a la base del diseño |
|---|---|---|
| G | origin/main `f1d25bbf989bf6d65547369a5e25319187bea6a1` (PR #292) <!-- corr: D14 --> | Encargos B0–B19 y B22 mergeados. Host de la Mac (`scripts/agent-work/`): desde B22 un solo host lanza un `opencode run -m <modelo>` por encargo (`lanzar-encargos.sh`, `sesion.py`), el modelo viaja en la cabecera del brief (`brief.py --model`) y `proveedores-permitidos.json` dice qué proveedores se pueden pedir. La ruta por alias y `lanzar-host.sh` ya no existen. Corte `cutover_live.py` (`agent-work-cutover.v2`), publicación propia del avance al tablero (B16) y `--close-only` (B14). <!-- corr: D14 --> Desde el 2026-10-13 tampoco existen la ruta de corrida (`scripts/mac/corrida.sh`, `corrida/`, `corrida_worker/`, `workers.v1.json`, `cli-modos.tsv`, el plist del latido; PR #291) ni la sesión adoptada de encargos (`claim_cli_once`, `TmuxTransport`, `detect_silent_failures` y sus e2e; PR #290). En `scripts/mac/` quedan el instalador, el vigilante tmux, el hook Stop, `progress-events.py`, `respaldo-workspaces.sh` y `tablero-trabajo.sh`. El checkout del host vivo (`~/dev/wt/agent-work-host`) sigue en `4000a1d4`, anterior a esos dos retiros. El diseño se escribió en `~/dev/wt/flota-poteto` sobre `e5cae2d`, cabeza del PR #247, que se cerró sin entrar a main. |
| R | `/Users/dn/dev/openclaw-agent-work-integration`, `4acb881e015a` | Instalado en la Mac Mini del gateway el 2026-10-12. Sobre `605aef7` trae B18-R (`c928144`, residuales de B11) y un arreglo: un turno directo de Telegram ya admite una tarea (`managed-task.turn.ts`). `managedTasks` en vivo con `requesters ["main"]`, host `mac-local` y `adapters ["opencode"]`. B22 no cambió R. |
| O | `/Users/dn/dev/goncloud-Orbit`, `d83bb28902e97949fea7b3fabc5fed6203d936b1` (checkout local `master`) | Receta de deploy existente; automatización pendiente. Se vuelve a leer `origin/master` antes de SUA-08. |
| H | Corre en `gon-pc` (Windows), según David el 2026-10-13 <!-- corr: D13 -->. Instalación, repo y versión pendientes de inventario | No se inventan flags ni se usa OpenClaw como proxy. |

Contacto con lo que dejó encargos:
- Las rutas certificadas de SUA-03 y SUA-04 parten de `coverage.json` de G. Hoy
  solo `mac-local`/`opencode` está certificado (`hostAdapterCoverage`).
  <!-- corr: B22 -->
  Desde B22 lo certificado es la forma `run-per-task` con opencode 1.18.35
  (`hostAdapterRoute`). Otra versión de opencode cierra la ruta hasta recertificar.
- Un encargo por CLI trabaja dentro de un repo de `~/dev` y la guarda de carpeta de
  opencode no confina el shell del modelo (`followups.md`, B22-S7). Un bloque de SUA
  no la usa como aislamiento.
- La regla que hace que `main` use la ruta con "por CLI" y el formato de sus reportes
  viven en el `AGENTS.md` de su workspace, en la Mini. Se respaldan cada día a
  `goncloud-workspace-main` (`scripts/mac/respaldo-workspaces.sh`).
- Un loop sobre la ruta de encargos ya no lleva vigía (`prompt-claw` §7).
  `bids-02` conserva el suyo y lo declara.
- Ninguna herramienta nueva de `managed_tasks_*` o de metas usa un nombre de campo
  que la redacción tape (`key`, `token`, `secret`, `session`, o `<algo>_key` en
  snake_case). La prueba de tabla de B17-R lo vigila.
- <!-- corr: D14 -->
  El latido de corrida ya no existe: `latido.sh` y el plist
  `ai.goncloud.corrida-latido` salieron del repo con la ruta de corrida (PR #291)
  y el plist no está en `~/Library/LaunchAgents` de la Mac. El avance lo publica
  el host (`ProgressPublisher`, `native_gateway.py`). Ningún bloque lo revive.

<!-- corr: C5.2 K2 -->
Antes de implementar se reconcilian estas bases con los commits aprobados.
<!-- corr: B22 -->
El PR #247 se cerró el 2026-10-12 por decisión de David. Su código previo, que
este diseño no acepta, no entró a main.
<!-- corr: D14 -->
Su rescate del rechazo de caracteres de control (`_check_argv_element`,
`worker_argv`, `test-worker-model-binding.sh`) entró a main y salió el 2026-10-13
con la ruta de corrida (PR #291): hoy ninguno de los tres existe
(`ls scripts/tests/test-worker*` no encuentra nada). En la ruta viva el modelo no
pasa por un shell: `brief.py --model` lo valida con `model_id` (`brief.py:53`),
`ModelId.parse` solo acepta `[a-z0-9-]/[A-Za-z0-9._:@/-]` por `fullmatch`
(`modelos.py:37-38`, `:55-59`), así que `--model\nwrong` es `MalformedModel`, y
el host lanza `-m <modelo>` como un elemento propio de argv (`opencode_argv`,
`sesion.py:205-212`). Lo que SUA-03 todavía prueba sobre eso está en su paso 5.
U1/U3/U3a/Fase14 y encargos conservan sus
recibos; sólo se repite evidencia invalidada o de un perímetro nuevo.

<!-- corr: C1.1 C1.2 C1.3 K10 -->
**Orden con encargos.** T11 y T12 los terminó el loop de encargos; SUA no los
absorbe ni los repite. Los seguimientos abiertos están en
`docs/evidence/agent-work/followups.md` y los cierra ese loop (B18-G en G y B18-R
en R sobre `605aef7`). SUA-01, y cualquier bloque que escriba en
`src/agents/tasks/` o en las herramientas `managed_tasks_*` de R, empieza después
de que B18-R esté mergeado o cerrado. El plan de encargos (`:67`) prohíbe dos
escritores en paralelo sobre `R.taskStore` y `R.scheduler`.
<!-- corr: D14 -->
SUA-00 corrió en solo lectura desde G `2213b930` y R `4acb881` y cerró el
2026-10-13 (PR #288 y #289). B18-R está mergeado e instalado (R `c928144`, dentro
de `4acb881e`), así que esa condición de SUA-01 está cumplida. El inventario
(`SUA-00-inventario.md`, "Host de encargos: piezas que el plan pide por nombre")
cubrió las incidencias de host (`managedTasks.host.incident`;
`record_incident` en `scripts/agent-work/host.py` y `spool.py`, y `flush_incidents`
en `host.py`), `CLI_ROUTES` (`routing.py`), `coverage.json.modelWakes`,
`main_cli_loop`, `managedTasks.host.cancellation`, el
corte `cutover_live.py` y la publicación del host (`ProgressPublisher`).
`detect_silent_failures` se borró el 2026-10-13 con la sesión adoptada (PR #290);
la ruta viva usa `detect_run_failures` (`host.py`). Lo que todavía tiene que estar
hecho antes de escribir en R está en "Preparación antes de SUA-01".

## Orden y dependencias

Un bloque puede integrar código sin activar producción. Cada integración registra
el par de versiones G/R o el paquete Hermes que la acredita. Las dependencias son
de artefactos; compartir contratos no crea dependencia de disponibilidad entre hosts.

<!-- corr: D14 -->
| Bloque | Entrega | Depende de | Estado |
|---|---|---|---|
| SUA-00 | Inventario residual, contratos y fixtures comunes | — | cerrado el 2026-10-13 (PR #288, #289) |
| SUA-01 | Estado, DAG y control atómicos en OpenClaw | SUA-00 (cerrado); B18-R mergeado (R `c928144`, cumplido) <!-- corr: C1.1 -->; "Preparación antes de SUA-01" | autorizado el 2026-10-13 |
| SUA-02 | Controlador, autoridad y excepciones | SUA-01 | autorizado el 2026-10-13 |
| SUA-03 | Poteto, perfiles y rutas nativo/CLI/OpenCode | SUA-02 | autorizado el 2026-10-13 |
| SUA-04 | Catálogo, promoción y alta automática | SUA-03 | autorizado el 2026-10-13 |
| SUA-05 | Ingeniería y calidad propias del sistema | SUA-02, SUA-03 | autorizado el 2026-10-13 |
| SUA-06 | Proyección, avisos y LobsterBoard | SUA-02 | autorizado el 2026-10-13 |
| SUA-07 | Implementación Hermes independiente | SUA-00; `gon-pc` en la red | autorizado el 2026-10-13; empieza cuando `gon-pc` esté en la red |
| SUA-08 | Automatización de deploy de Orbit | SUA-05 | autorizado el 2026-10-13, salvo el deploy de producción (se avisa y se espera) |
| SUA-09O | Paquete y transición exclusiva OpenClaw | SUA-04, SUA-05, SUA-06 | autorizado el 2026-10-13, cambio de dueño incluido; instala solo de madrugada |
| SUA-09H | Paquete y transición exclusiva Hermes | SUA-04, SUA-05, SUA-06, SUA-07 | autorizado el 2026-10-13; empieza cuando `gon-pc` esté en la red |
| SUA-10O | Aceptación OpenClaw y Orbit | SUA-08, SUA-09O | autorizado el 2026-10-13, salvo el ensayo real de Orbit (se avisa y se espera) |
| SUA-10H | Aceptación Hermes | SUA-09H | autorizado el 2026-10-13; empieza cuando `gon-pc` esté en la red |
| SUA-11 | Retiro residual y cierre del programa | SUA-10O, SUA-10H | autorizado el 2026-10-13 |

SUA-07 puede empezar con el contrato sin esperar el código de R. SUA-09H consume
formatos, políticas y fixtures de SUA-03–06; no llama sus servicios OpenClaw.
La parte OpenClaw de SUA-10O puede emitir su recibo antes del ensayo Orbit; el
bloque completo espera ambos. Hermes no bloquea ese recibo ni el de Orbit.
<!-- corr: D14 -->
Ninguna dependencia de esta tabla pasaba por la ruta de corrida ni por la sesión
adoptada: las dos eran consumidores de SUA-02, SUA-03 y SUA-05, no entregas de
las que otro bloque dependiera, y sus filas de `SUA-00-inventario.md` son
historia. Lo que sí cambia es el contenido de esos tres bloques, abajo.

## Preparación antes de SUA-01

<!-- corr: D14 -->
Cada punto tiene su comando de comprobación. Se corren desde la MacBook, sobre
`origin/main` de G y el checkout local de R. Ninguno escribe en la Mini.

1. **R local construido en su HEAD.** `git -C /Users/dn/dev/openclaw-agent-work-integration rev-parse HEAD`
   imprime `4acb881e015a27a36a5d5f2cb4002783e79cf29d`. El build de R escribe
   `dist/build-info.json` con el campo `commit` (`scripts/write-build-info.ts:135`,
   `pnpm build`). Hecho el 2026-10-13 a las 17:43 UTC: el `dist` anterior era de
   `605aef74`, y ahora `dist/build-info.json` dice `4acb881e…`. Con ese build la
   línea base contra R dio `main_cli_loop` 1 OK y `cutover_fencing` 5 OK sobre G
   `f1d25bbf`. Comprobación, que se repite después de cada `pnpm build`:
   `python3 -c "import json; print(json.load(open('dist/build-info.json'))['commit'])"`
   imprime el mismo sha que `rev-parse HEAD`. Sin ese build no corre en esta Mac
   ningún caso de `scripts/tests/test-agent-work-e2e.sh` que pida
   `AGENT_WORK_RUNTIME_SOURCE con R construido` (`main_cli_loop`,
   `cutover_fencing`, `acceptance_pair`) ni `test-runtime.sh projection_gateway`
   (exige `dist/entry.js`). Los demás casos de `scripts/agent-work/test-runtime.sh`
   corren con vitest desde fuente y solo exigen que `sourceBaseSha` de
   `runtime-map.json` sea ancestro de HEAD.
2. **`coverage.json` alineado con lo medido.** Hoy dice `status: inventory-only`,
   `hosts[mac-local].status: sandbox-tested-uncertified`, no tiene
   `main → mac-local/opencode` en `managedRequesterRoutes` (sus cuatro filas son
   `ingenieria → adversary`, `operaciones → ingenieria`,
   `ingenieria → windows-remote/codex` y `main → mac-local/claude_opus`, todas
   `certified: false`) y `modelWakes` es la foto del 2026-10-07 (filas T12 y SUA-00
   de `followups.md`). Un PR de G lo alinea: `status` y el host pasan a lo que
   `hostAdapterCoverage` y `hostAdapterRoute` ya dicen (`certified`, forma
   `run-per-task`, opencode 1.18.35), entra la fila `main → mac-local/opencode`
   con `certified: true` y `B22-canarios.md` como evidencia, y `modelWakes` y
   `cronJobs` se rehacen con una lectura nueva de `openclaw cron list --json`
   (M-09 del 2026-10-13 dio 30 crons y un solo vigía, `bids-02-vigia`, a las 14:47 UTC; a las
   18:09 UTC eran 29 y ninguno, porque ese loop cerró y su vigía borró su propio cron). La foto
   nueva es un archivo nuevo y un sha256 literal nuevo en
   `test_every_live_cron_is_classified` (`scripts/tests/test-agent-work-routing.py:298-344`).
   Comprobación: `python3 scripts/tests/test-agent-work-routing.py` en verde y
   `python3 -c "import json; d=json.load(open('docs/evidence/agent-work/coverage.json')); print(d['status'], [r['target'] for r in d['managedRequesterRoutes'] if r['requester']=='main' and r['certified']])"`
   imprime un estado distinto de `inventory-only` y `['mac-local/opencode']`.
   SUA-04 y SUA-09O leen el archivo alineado; el loop de encargos cerró, así que
   este PR es de SUA.
3. **Un e2e de la ruta viva contra R antes de tocar `src/agents/tasks/`.** Hace
   falta, por esto: SUA-01 cambia `managed-task.{db,store,types}.ts` y migra
   datos, y el host de encargos depende de esas tablas y de
   `managedTasks.host.*` (`assertHostDevice`, `src/gateway/server-methods/managed-tasks.ts:145-162`;
   incidencias `:402-433`; cancelación `:371-401`). La única evidencia de la ruta
   viva contra un gateway real son los canarios de B22, que corrieron en la Mini,
   y las pruebas de G usan un doble (`FakeR`, `test-agent-work-sesion.py`). Los e2e
   que entregaban por la sesión adoptada se borraron (PR #290), y
   `followups.md` ("Ruta viva sin e2e contra R") deja escrito el arnés que falta:
   el host de un proceso por encargo, con un doble de opencode, contra el gateway
   de `scripts/tests/fixtures/agent-work/managed-cli-gateway-harness.mjs`. El
   mínimo es un caso que recorra claim, admit, lanzamiento del doble, report,
   close y `AbsenceVerified` con `--device-auth`, y que compruebe el despertar
   del solicitante tras el reporte (`prepareManagedTaskResultDelivery`,
   `managed-task.delivery.ts:55-70`). Ese caso entra a
   `test-agent-work-e2e.sh` y corre en verde sobre R HEAD antes de mergear el
   primer cambio de SUA-01 que toque el esquema o `managed-tasks.ts`.
   Comprobación: `AGENT_WORK_RUNTIME_SOURCE=/Users/dn/dev/openclaw-agent-work-integration bash scripts/tests/test-agent-work-e2e.sh <caso nuevo>`
   sale 0, y vuelve a salir 0 sobre cada SHA de SUA-01 antes de su merge.
   `main_cli_loop` conserva `test_isolated_cron_run_cannot_submit` y `LoopGateway`
   (`test_agent_work_main_cli_loop_e2e.py`) y corre en la misma pasada.
4. **El checkout del host vivo al día.** `git -C ~/dev/wt/agent-work-host rev-parse HEAD`
   imprime hoy `4000a1d4…`, y los PR #290 y #291 cambiaron `host.py`,
   `native_gateway.py`, `resources.py`, `spool.py` y `sesion.py` después. No
   bloquea SUA-01 (escribe en R), pero sí a SUA-03 y a cualquier recibo que cite
   el host: antes de la primera evidencia viva de SUA, el checkout se mueve a
   `origin/main` y el host se relanza como dice `T12-runbook.md` ("El host de
   encargos"): con el spool sin operaciones sin asentar
   (`sqlite3 -readonly ~/.local/state/agent-work-host/enc-1/host.sqlite "select count(*) from operations where status not in ('acknowledged','abandoned','cancelled')"`
   imprime `0`), `tmux -L agent-work kill-session -t host-encargos` y
   `bash scripts/agent-work/lanzar-encargos.sh`. Comprobación:
   `python3 scripts/agent-work/encargo.py estado` contesta `slot` `free` y el
   `commit` de `origin/main`.
5. **El grupo del slot.** `id -Gn | tr ' ' '\n' | grep -x agent-work-enc1`
   imprime `agent-work-enc1` (comprobado el 2026-10-13 en la MacBook).
6. **Lint y formato.** Cada módulo nuevo de G entra al `include` de `ruff.toml` y
   al `files` de los hooks `ruff-check` y `ruff-format` en el mismo PR que lo crea
   (`SUA-00-mediciones.md`, "Alcance de lint"). Un bloque que escriba en R corre
   `pnpm lint:core`, `pnpm format:check` y `pnpm tsgo:core` sobre sus archivos
   antes del commit. Comprobación: `pre-commit run --files <archivos>` en verde.

## Regla de instalación en vivo

<!-- corr: D14 -->
Rige para cada versión de R que un bloque instale en la Mac Mini del gateway
(`gon@100.73.187.5`), sea para un e2e vivo o para el corte de SUA-09O. David lo
autorizó el 2026-10-13 "de madrugada" y sin preguntarle cada vez.

- **Solo de madrugada, hora de David.** Madrugada es entre las 00:00 y las 06:00
  del reloj de la Mini (`date` por ssh), que es la máquina donde corren los
  crons. Es el sentido llano de la palabra, no una ventana que David haya fijado;
  si fija otra, la suya manda. A juzgar por sus nombres, los crons de negocio
  corren a las 7 h, 11 h y 20 h (`packing-extras-7h`, `-11h`, `verif-digest-20h`;
  M-09 solo da los nombres), así que esa ventana no los pisa.
- **Ningún cron cerca.** Antes de detener el gateway, `openclaw cron list --json`
  no trae ningún `runningAtMs` y ningún cron tiene su próxima corrida dentro de
  la ventana que tarda la instalación (`T12-runbook.md` da 2 min para instalar y
  2 min para arrancar, filas 1.3 y 1.4). Con un cron a menos de 10 min, se espera a que
  pase. `openclaw gateway call sessions.list --params '{"agentId":"main"}' --json`
  sin turnos activos (`T12-runbook.md`, 0.5).
- **Foto y reversa listas antes de instalar.** Es el procedimiento de
  `T12-runbook.md`: el artefacto revisado (0.1, `artifact.py verify`), los
  paquetes nuevos y los de la versión anterior copiados y con hash (0.2), la foto
  completa de las bases y de `openclaw.json` (1.1), detener, instalar, arrancar y
  releer `build-info.json` (1.2 a 1.6), y la sección "Reversa": `cutover_live.py
  revert` o `freeze` si falla una entrada, y restaurar la foto si falla el
  binario. Un script `t12-actualizar-<sha>.sh` hace todo eso de corrido y
  termina en `ACTUALIZADO OK`, `PARO` o `REVERSA`; SUA-09O versiona esos scripts
  (sus "Archivos"). Esta sección no repite los comandos.
- **Después.** El recibo del bloque registra el `commit` de `build-info.json`,
  los hashes y los crons habilitados antes y después, como `deploy-receipt.md`.

## Regla de ejecución futura por bloque

1. Leer las obligaciones del bloque y su autoridad. Reclamar recursos de escritura.
2. Abrir un cambio acotado sobre una base conocida, con worktree por escritor.
3. Reproducir cada bug antes de corregirlo y conservar su prueba en el mismo cambio.
4. Ejecutar pruebas focalizadas. Guardar comandos, salidas y artefactos redactados.
5. Revisar los hallazgos agrupados. Corregir bloqueantes bajo la política vigente.
6. Ejecutar hooks y la batería completa una vez sobre el commit final, reutilizando
   CI del mismo artefacto y entorno. No usar `--no-verify` ni recortar shards.
7. Registrar recibo, límites y estado; activar sólo el perímetro autorizado y probado.

<!-- corr: C2 K8 -->
SUA-05 implementa como datos la política de rondas que David fijó el 2026-10-12
<!-- corr: D14 -->
(regla 4 de quality-kit con tope 5+5; abajo, en SUA-05). Mientras no esté
implementada rige esa misma regla tal como está en `~/.claude/CLAUDE.md`: se agrupan los
hallazgos; solo un bloqueante con el comando que lo reproduce reabre el ciclo; un
bloqueante nunca va al plan ni se mergea abierto, se corrige o se para y decide el
operador. En los loops de claw rige además la regla 5+5 de David: hasta 5 rondas
por implementador y relevo a otro modelo con otras 5 (`prompt-claw` SKILL.md:59).
`quality-policy.v2` de cuatro ciclos queda como propuesta inactiva. Revisa el
revisor asignado, que excluye a todos los autores, más los bots del PR y CI; no
se añade una segunda revisión con otro modelo. Un revisor no convierte
un defecto bloqueante en residual para permitir el cierre. Un límite agotado deja
el bloque detenido, con diagnóstico y resultado parcial.

Los nombres de ensayos I01–I24 siguientes son especificaciones futuras. No son
scripts ya instalados. SUA-00 fija su manifiesto y cada bloque implementa su caso
en el harness nativo; no se crean ejecutables vacíos para simular aceptación.

## SUA-00 — Inventario y contrato

**Dueño:** G, con lectura de R/O y del host H autorizado.

**Archivos:** `docs/evidence/agent-work/runtime-map.json`, contratos existentes en
`docs/spec/`, inventarios efectivos de agentes/CLI, configs de sync e instaladores.
Nuevos: `docs/spec/sistema-agentes.v1.md` y fixtures de contrato bajo
`scripts/tests/fixtures/sistema-agentes/`.

1. Registrar por ruta versión, ubicación, dueño, autoridad, resultado, recibo y
   capacidad `passed/failed/unknown`. Separar fuente, instalado y aceptación viva.
2. Fijar esquemas de meta/unidad/resultado/evidencia/control/flota/excepción y
   compatibilidad de versiones. Enumerar productores y consumidores a migrar.
   <!-- corr: C4 -->
   Decidir la relación con `SessionGoal`/`/goal` de R antes de crear
   `src/agents/goals/`: reutilizar, extender o renombrar. Dos conceptos "goal" con
   pausa y presupuesto propios no conviven. `SessionGoal` ya tiene estados
   `active|paused|blocked|usage_limited|budget_limited|complete` y `tokenBudget`
   (`packages/gateway-protocol/src/schema/sessions-goal.ts`).
3. Medir despertar por evento y mensaje: gateway ocioso/ocupado, sesión nueva,
   `/new`, tokens, latencia, `NO_REPLY`, aislamiento y borrado remoto de sesiones
   de ensayo propias. Elegir el verbo con evidencia, no por preferencia.
   <!-- corr: K11 -->
   La ventana de 30 minutos de encargos (2026-10-11, `deploy-receipt.md`,
   "Contadores": cero inferencia atribuible a vigilar encargos) ya es evidencia
   válida para la ruta `main` → `mac-local/opencode`. Se reutiliza, no se repite.
4. Definir baseline de coste y latencia del ciclo actual; documentar lo que no se
   puede medir. Verificar lint/formatter de R y configurar alcance de módulos
   nuevos en G antes de su primer cambio de código, sin reformatear todo el legado.
5. Publicar fixtures de planes válidos/inválidos, autoridad negativa, resultados y
   proyección. Fijar IDs I01–I24 y el inventario de consumidores de quality-kit.

**Verificar:** I01/I02; cada capacidad tiene prueba y recibo o `unknown`. El
inventario de H pendiente bloquea sólo su integración. Las mediciones vivas se
hacen únicamente cuando la futura autorización las cubra. No se cierran con mocks.
<!-- corr: D14 -->
Cerrado el 2026-10-13: inventario y contrato en el PR #288, mediciones vivas
(autorizadas ese día, "1. si") en el PR #289. Sus salidas son
`SUA-00-inventario.md` y `.json`, `SUA-00-mediciones.md`, `SUA-00-mutaciones.md`,
`docs/spec/sistema-agentes.v1.md` y los fixtures de
`scripts/tests/fixtures/sistema-agentes/`. La relación con `SessionGoal` quedó
decidida (SUA-01) y el alcance de lint configurado ("Preparación", punto 6).

## SUA-01 — Frontera durable OpenClaw

**Dueño:** R. **Archivos:** `src/agents/tasks/managed-task.{db,store,types}.ts`,
handling, admission, budget, recovery y sus tests; entrada gateway correspondiente.
<!-- corr: C4 -->
<!-- corr: D14 -->
SUA-00 decidió: la meta de SUA no reutiliza ni extiende `SessionGoal`. Se llama
raíz (`root`), vive junto a las tareas gestionadas bajo `src/agents/tasks/` y
nunca en `src/agents/goals/` (`docs/spec/sistema-agentes.v1.md`, "Decisión sobre
`SessionGoal` y `/goal` de R"). Del patrón de `goals-operations.ts` se copia solo
`operationId` por mutación, recibo durable y `replayed: true`, con `commandId`.
Lo que R no tiene y este bloque construye está en `SUA-00-inventario.md`, debajo
de "Rutas nativas": fan-in A+B→C (`managed_task_children.child_task_id` es
`UNIQUE`), hijos iniciales sin resultado padre, pausa de una tarea gestionada,
época de control y recuperar la capacidad del solicitante después de `/new`.
Antes del primer PR de este bloque se cumple "Preparación antes de SUA-01".

1. Añadir revisión de plan, época, claims, binding único, capacidad del solicitante
   y contadores persistentes. Migrar datos con versión y reversa compatible.
2. Implementar creación inicial de unidades y fan-in transaccional junto a tareas,
   sin fabricar resultados padres ni escribir tablas desde G.
3. Incluir control, reservas, reclamación de escritor y efectos en la misma frontera.
   Serializar `Prepared → Started` con pausa: es el permiso de inicio, no el ACK
   del destino. El recibo de pausa enumera efectos comprometidos o inciertos.
4. Recuperar recibos después de ACK perdido, reinicio y fallo intermedio. Revalidar
   autorización al admitir y antes de iniciar un efecto.

**Verificar:** I03/I04/I05/I06/I20. Inyectar fallos antes/después del commit; competir
dos reconciliadores; pausa y revisión ganan a admisiones obsoletas. Ensayar también
Started antes de pausa y envío después de su ACK: el recibo identifica ese efecto,
que no se presenta detenido. Control repetido devuelve recibo; otro Resume con
época obsoleta falla. Repetir un
resultado no crea escritor ni presupuesto. Probar pares con dos y tres plazas
ocupadas de cuatro. Los controles nativos de presupuesto existentes siguen verdes.
<!-- corr: K7 -->
La prueba de tabla de B17-R ("declares no managed task input field that transcript
redaction masks") cubre cada campo de entrada nuevo. `idempotency_key`, `task_key`,
`session` y `key` quedan tapados como `***`; `idempotencyKey` y `taskKey`, no
(comprobado contra `STRUCTURED_SECRET_FIELD_RE` y `STRUCTURED_SECRET_ENV_FIELD_RE`
de `src/logging/redact.ts`).

## SUA-02 — Controlador y autoridad

**Dueño:** R para control local; G para adaptadores/recetas. **Archivos:** la
raíz de SUA-01 bajo `src/agents/tasks/` <!-- corr: C4 D14 -->, la entrega al
solicitante (`managed-task.delivery.ts`) y las herramientas `managed_tasks_*`
(`src/agents/tools/managed-tasks-tool.ts`). En G, como consumidores: las
incidencias del host (`record_incident`, `flush_incidents` en `host.py`) y la
skill `encargo-cli` de `main` (`agents/main/agent/workshop-skills/encargo-cli/SKILL.md`).

<!-- corr: D14 -->
**Despertar del controlador: lo que las mediciones sostienen.** Los hechos son
los de `SUA-00-mediciones.md` ("Qué deciden estas mediciones"). Uno: R ya
despierta al solicitante con un evento de sistema a su propia sesión durable,
tanto para un resultado como para una incidencia (`prepareSessionDelivery` con
`kind: "systemEvent"`, `managed-task.delivery.ts:61` y `:85`), y un cron aislado
no puede ser solicitante (`managed-task.turn.ts:42-44`, M-07). Dos: ese verbo
empieza en 2,3 s con `main` libre (M-01), acepta `NO_REPLY` a la primera en las
cuatro muestras, y espera detrás de cualquier turno de `main` en vuelo, sea de
otra sesión o del cron vigía: 96 s medidos, hasta 144 s por lo que dura una
corrida de `bids-02-vigia` (M-02). Tres: `agent --message` a otra sesión no
esperó en una sola muestra, pero un turno que contesta solo `NO_REPLY` por ese
verbo se reintentó cinco veces y cayó a `claude-cli` (M-03); un controlador
contesta `NO_REPLY` casi siempre. Decisión que esos hechos sostienen: el
controlador despierta por el evento de sistema que R ya emite, a la sesión
durable del solicitante, y no se agrega ningún `agent --message` ni ningún cron
como despertador. La espera detrás de un turno de `main` es el coste conocido. Su
única fuente grande era `bids-02-vigia`, que borró su propio cron el 2026-10-13 al
cerrar su loop; vuelve con cada loop de claw que arranque con vigía.

Lo que queda sin medir decide dónde vive el controlador, y se mide en este bloque
antes de "Verificar", con el mismo método de M-02 (lectura de
`trajectory_runtime_events`, sesiones `agent:<agente>:sua-ensayo-*` sin
`--deliver`, borradas al final):

- M-11, controlador en un agente propio. Con un turno de `main` en vuelo, un
  `system event --mode now` a una sesión de otro agente ya configurado en la Mini
  (por ejemplo `ingenieria`), tres muestras. El turno en vuelo se provoca como en
  la segunda pasada de M-02: un `agent --message` a una sesión de ensayo de `main`
  que corre `sleep 45` con `exec`. Ya no sirve esperar al vigía: no hay ninguno
  desde el 2026-10-13. Criterio: si en las tres el turno del otro agente empieza
  antes de que termine el turno de `main`, el controlador vive
  en un agente propio, ese agente entra a `managedTasks.requesters`
  (`resolveManagedRequesterTools`, `openclaw-tools.managed-tools.ts:53-59`) y
  `main` le pasa el pedido. Si en alguna espera, se queda en `main` y el plan
  acepta la fila: ninguna de las dos opciones cambia el verbo.
- M-12, solo si SUA-02 necesita un tic periódico además del evento de R: coste de
  un cron con `--session` durable (no aislado), tres corridas sin trabajo.
  Criterio: si cada corrida vacía cuesta más que un despertar por evento (20 500
  tokens, M-01), no hay tic y el reloj es el evento de R. Si SUA-02 no necesita
  tic, M-12 no se corre y se anota.

El decisor legacy de corrida (`reconcile.py`, `task_handoffs.py`) salió del repo
con la ruta de corrida (PR #291); no se envuelve. Hoy el único que decide sobre
una tarea gestionada es `main`, con `managed_tasks_resolve` desde la skill
`encargo-cli`. Esa entrada pasa al controlador con el corte de SUA-09O, no aquí.

<!-- corr: C3.2 -->
Canal de avisos y excepciones: Telegram vía OpenClaw, el mismo destino que los
crons actuales. Se lee de la configuración, nunca se pega en el repo. Aquí se fija
qué agente recibe el pedido (claw/`main`, hoy el único solicitante de
`managedTasks`) y quién redacta el plan desde lenguaje natural (un trabajador con
modelo, validado por `decide`).

1. Implementar `open/control/reconcile/read` con funciones puras internas de meta,
   ingeniería y flota. Importar Plans o pedido natural sin perder criterios.
2. Vincular solicitante durable, identidad autenticada y autoridad heredada. Una
   nueva sesión no toma una raíz por conocer su ID. Un hijo no crea otra raíz.
3. Seleccionar unidades aceptables; continuar ramas independientes; reparar dentro
   del alcance; invalidar sólo evidencia afectada por revisiones acreditadas.
4. Migrar las once clases de excepción antiguas a un enum explícito y añadir las
   necesarias para evidencia/capacidad incierta. Conservar IDs, opciones válidas,
   entrega al propietario, respuesta única y reaviso máximo de una vez por hora.
5. Conectar scheduler y eventos existentes; observación en sombra sin despachar.
   <!-- corr: D14 -->
   Lo que queda de este paso: el controlador se engancha a los eventos que R ya
   emite (resultado e incidencia, `managed-task.delivery.ts`) y a las incidencias
   del host (`managedTasks.host.incident`, `managed-tasks.ts:402-433`), que pasan
   a `excepcion` con tipo y opciones. En sombra significa que lee con
   `managed_tasks_inspect`, calcula la decisión sobre la raíz y la registra en su
   recibo, sin llamar `managed_tasks_resolve`: esa llamada la sigue haciendo
   `main` hasta el corte de SUA-09O. No hay decisor legacy que envolver.

**Verificar:** I01–I07/I12. Tres entradas: pedido pequeño, fila importada y pedido
compuesto. El turno termina y la meta continúa. Respuestas con cero/una/varias
excepciones no se aplican a otra. Un pedido grande autorizado no pregunta por
ritual; crear repo o enviar mail sin autoridad sí queda detenido.

## SUA-03 — Poteto y trabajadores especializados

**Dueño:** G/R. **Archivos:** <!-- corr: D14 --> en G, la ruta por CLI que vive:
`scripts/agent-work/{sesion,modelos,brief,encargo,host,native_gateway}.py`,
`lanzar-encargos.sh`, `docs/evidence/agent-work/coverage.json` y
`proveedores-permitidos.json`, la skill `encargo-cli` de `main`. En R, el hijo
nativo (`src/agents/spawn-pipeline.ts`, tabla `subagent_runs`) y el encargo
nativo a un agente (`managed_tasks_submit` con `target.kind: "agent"`,
`managed-task.types.ts:31`). Nuevo: el manifiesto de perfiles y el documento
`flota.v1` por intento.

<!-- corr: D14 -->
La ruta de corrida y la sesión adoptada salieron del repo el 2026-10-13 (PR #291
y #290). Con ellas se fueron `workers.v1.json`, `registry.py`, `selector.py`,
`corrida/lib.sh`, los adaptadores que abrían una CLI en tmux y las rutas "inicio"
y "resume" de una CLI. Las rutas que existen hoy son cinco, las del inventario
(`SUA-00-inventario.md`, "Rutas nativas" y "Rutas por CLI"): turno nativo, hijo
nativo (`sessions_spawn`), encargo nativo a un agente, encargo por CLI con un
proceso de opencode por encargo, e hijo de una CLI. Un reintento en la ruta por
CLI no es un resume: es un intento nuevo (`attempt` del contrato) con su propio
`argv.json` y su propio brief.

1. Materializar contexto de poteto canónico, perfil, skills y evidencia por tarea.
   Preservar memoria y archivos del usuario. Versionar contenido y adaptación.
2. <!-- corr: D14 -->
   Certificar las cinco rutas. Qué se certifica de cada una:
   - Turno nativo. El contexto de poteto y el perfil llegan al agente por su
     workspace en la Mini (el `AGENTS.md` de `main`, respaldado a diario en
     `goncloud-workspace-main`). Se certifica el digest de lo entregado contra el
     workspace y una conducta observable: un pedido que exige el procedimiento
     poteto se resuelve con ese procedimiento y no con un atajo.
   - Hijo nativo (`sessions_spawn`, `spawn-pipeline.ts`). Se certifica que el hijo
     recibe el mismo poteto y perfil que el padre, que respeta
     `agents.defaults.subagents` (`maxConcurrent` 8, `maxSpawnDepth` 5) y los
     topes de `limits.json`, y que su fila de `subagent_runs` ata modelo y padre.
   - Encargo nativo a un agente. R lo soporta y ningún pedido real pasó por ahí
     (inventario: `unknown`; `coverage.json` tiene `ingenieria → adversary` y
     `operaciones → ingenieria` con `certified: false`). Se certifica con un
     primer encargo real `main → ingenieria` leído en la Mini
     (`managed_tasks` con `target.kind = agent`), con poteto en el brief y
     resultado `review.v1` o `ready.v1`.
   - Encargo por CLI, un proceso de opencode por encargo. La ruta ya está
     certificada como ruta (`hostAdapterRoute.mac-local.opencode`, forma
     `run-per-task`, opencode 1.18.35; `B22-canarios.md`). Lo que este bloque
     certifica encima: que el poteto y el perfil llegan a la sesión de opencode
     (el brief es el único texto que el host entrega; el `AGENTS.md` global de
     opencode también entra, fila B22-S8), los permisos efectivos medidos
     (`permisosNegados` de `encargo.py estado --tarea`), el modelo efectivo (paso
     5) y que un reviewer no escribe fuente (paso 6). La guarda de carpeta no
     confina el shell (B22-S7): ningún permiso de esta ruta se da por medido por
     la regla `deny` sola.
   - Hijo de una CLI. `unknown` en el inventario. Se certifica qué lanza opencode
     dentro del grupo del slot (en el canario A se vio `tracker.js sync`,
     `B22-canarios.md`, "Otros hechos"), si un hijo hereda el brief, y que el
     cierre del grupo lo barre (`closureProof` de `coverage.json`).
   Medir permisos efectivos y herramientas que necesita el procedimiento completo.
3. Crear perfiles de capacidad y competencia para todas las especialidades
   descubiertas, incluidas operaciones, ingeniería, revisión, adversario, Amazon,
   Meli y mail. No deducir capacidad del nombre ni compartir contexto indiscriminado.
4. Certificar OpenCode con el adaptador existente y los siete perfiles disponibles.
   Resolver permisos de shell/hijos y modelo efectivo; background no es requisito.
   <!-- corr: K6 -->
   Se parte de lo ya certificado: `main` → `mac-local/opencode`.
   <!-- corr: B22 -->
   Desde B22 esa ruta es un proceso de opencode por encargo (`coverage.json`,
   `hostAdapterRoute`, forma `run-per-task`, opencode 1.18.35; recibo en
   `docs/evidence/agent-work/B22-canarios.md`). La sesión adoptada de B8 ya no
   tiene punto de entrada. Los siete perfiles locales siguen
   sin certificar. Los agentes con primario `opencode-go/deepseek-v4.1-flash` no
   reciben encargos: R rechaza un plugin dentro de un encargo (`T12-runbook.md`).
   <!-- corr: D14 -->
   **La flota.** El contrato define `flota.v1` (`docs/spec/sistema-agentes.v1.md`)
   y `workers.v1.json`, `registry.py` y `selector.py` ya no existen. El registro
   de trabajadores de la ruta por CLI nace de lo que B22 dejó y funciona: el
   catálogo de `opencode models` (`CatalogStore`, `modelos.py:276`) filtrado por
   `proveedores-permitidos.json` (`ProviderPolicy`, `:202`) en `authorize`
   (`:577`), la misma función que usan `preparar` y el host. Con el catálogo del
   2026-10-13 pasan 62 modelos y se niegan 154 (`followups.md`, fila B22). SUA no
   escribe otra lista. Lo que SUA-03 añade encima: un documento `flota.v1` por
   intento con `specialist`, `host`, `executor`, `model.id` leído de lo que se
   lanzó de verdad (`sessions/<op>/argv.json`, el `-m`; `encargo.py estado --tarea`),
   `permissions` con lo medido (vacío es "no medido"), `generation` y
   `attestations` con los digests de poteto, perfil y herramientas. Para el
   executor `native`, `model.id` sale de la configuración efectiva del agente en
   la Mini; mientras no se lea, va `{ "id": null, "reason": ... }`, nunca
   inventado. La sucesión y la promoción son de SUA-04.
   **Claude como trabajador.** David quiere que Claude implemente y GLM revise.
   Hoy "por CLI" no puede lanzar a Claude: opencode solo acepta llave de API para
   Anthropic, David tiene plan Max y no va a usar llave, y `preparar --modelo
   "claude opus"` contesta `proveedor-sin-sesion` (`followups.md`, B22-S5;
   `B22-canarios.md`, canario E). Esa ruta entra en SUA-04, que ya la lista como
   suya ("Lo que B22 ya dejó para este bloque"), como un segundo adaptador de
   `mac-local` por el CLI propio de Claude. Lo que hay que probar para abrirla,
   en una fase 0 como la de B22: que `claude` corre sin teclado y con la
   suscripción desde el proceso del host (sin llave de API, sin cobro por token),
   con qué flag se apaga la pregunta de permisos (`followups.md` nombra
   `--permission-prompts none`; el nombre exacto se lee en `claude --help`, no se
   supone), que `PWD` es la carpeta del encargo, que el modelo pedido es el que
   corre y con qué protocolo escribe acuse y resultado. Si la fase 0 muestra que
   la única vía es una llave de API, eso es una decisión de dinero: se avisa a
   David con la pregunta "¿autorizas una llave de API de Anthropic cobrada por
   token para los encargos por CLI, o Claude queda fuera de esa ruta?" y SUA-04
   sigue con los demás proveedores sin esperarla. Mientras tanto Claude trabaja
   como hoy: en la ventana de la Mac, fuera de la ruta por CLI.
5. <!-- corr: D14 -->
   Probar que el modelo efectivo es el pedido, en la ruta viva. Lo que ya está
   probado y no se repite: `brief.py --model` rechaza un id que el host no
   parsearía y no escribe nada (`test_brief_refuses_a_model_the_host_would_not_parse_and_writes_nothing`),
   la cabecera `agent-work.launch.v1` usa la misma gramática en `brief.py` y en el
   host (`test_brief_carries_the_same_header_grammar_as_the_host`), el host relee
   el modelo que `brief.py` escribió (`test_the_host_reads_back_the_model_brief_wrote_and_none_from_a_brief_without_one`;
   los tres en `scripts/tests/test-agent-work-routing.py:593-636`), `ModelId.parse`
   rechaza `--model\nwrong` por `fullmatch` (`modelos.py:37-38`) y `-m` viaja como
   elemento propio de argv (`sesion.py:212`). Lo que queda por probar: que el
   modelo que opencode usó es el de `-m`. Hoy `estado --tarea` da el `-m` lanzado
   y `proveedoresLlamados`, que prueba el proveedor y no el modelo (en el canario
   B el proveedor rechazó el modelo con `launch-failed`). Este paso lee el modelo
   de los eventos de opencode de la corrida (`read_events`, `sesion.py:334`) o
   de su base, lo compara con `argv.json` y lo escribe en `flota.model.id`; si
   no se puede leer, `model.id` va `null` con la razón y el intento queda
   inelegible donde se exige versión exacta. Un intento nuevo (no hay resume)
   conserva su snapshot: brief con digest y `argv.json` del intento.
6. <!-- corr: D14 -->
   Las sesiones son las `enc-<op>` que el host crea y nombra antes de lanzar
   (`session_name`, `sesion.py:172`); el host no adopta sesiones, no teclea y no
   aprueba permisos (`T12-runbook.md`, "El host de encargos"). No hay teclas que
   serializar. Lo que queda fuera de Git es el spool del host
   (`~/.local/state/agent-work-host/enc-1/`, con `runs/<op>/` y
   `sessions/<op>/`). El reviewer entrega su resultado en `runs/<op>/result.json`
   (`contracts.py:46-48`), fuera del repo. Que no escriba fuente no lo garantiza
   la guarda de carpeta (B22-S7): se certifica leyendo el repo después del
   encargo de revisión (`git -C <repo> status --porcelain` vacío y `HEAD` igual)
   y exigiendo `review.v1` como `resultContract`.

**Verificar:** I08/I09/I11/I18. Quitar poteto, permitir escritura al reviewer o
deshabilitar una herramienta necesaria del hijo debe impedir esa admisión. Perfil
Meli pasa su tarea y rechaza una ajena; skill irrelevante no entra; memoria sobrevive.
Entregar un digest sin conducta observable no completa este bloque.
<!-- corr: D14 -->
Las clases `Live*` de `scripts/tests/test-agent-work-sesion.py` no corren mientras
el host tenga un encargo en vuelo: lanzan procesos en `agent-work-enc1`, el grupo
del host (`T12-runbook.md`).

## SUA-04 — Modelos y agentes que se actualizan

**Dueño:** política de flota local; G distribuye manifiestos. **Archivos:** ampliar
<!-- corr: D14 -->
`scripts/agent-work/modelos.py` (`CatalogStore`, `ProviderPolicy`, `authorize`),
`encargo.py proveedores|permitir|cerrar`, `coverage.json` (`hostAdapterCoverage`,
`hostAdapterRoute`) y el scheduler anfitrión; nuevo manifiesto versionado de catálogo,
perfiles y generaciones. No crear daemon ni store de tareas nuevo. El registro y
el selector de la ruta de corrida ya no existen (PR #291); no hay nada que ampliar
ahí.

1. Consultar fuentes oficiales y acceso por cuenta. Mantener sucesión, estabilidad,
   capacidades y causa de inelegibilidad, independientes de nombres comerciales.
2. Probar un sucesor y promoverlo automáticamente dentro de plantilla/autorización.
   Mantener el intento activo; un relevo hereda raíz, gasto y restricciones.
3. Descubrir altas y retiros; validar perfil y conexiones ida/vuelta; publicar nuevos
   destinos mediante manifiesto autorizado, no una allowlist abierta de carpetas.
   <!-- corr: K6 -->
   Las rutas certificadas parten de `coverage.json` de G.
   <!-- corr: D14 -->
   Ya alineado consigo mismo en "Preparación antes de SUA-01", punto 2; este
   bloque lee esa versión. Los siete adaptadores de CLI que `hostAdapterCoverage`
   lista en `disabled-operator-setup-pending` (`claude_fable`, `claude_opus`,
   `kimi_k3`, `kimi_coding`, `codex`, `zcode`, `grok`) son ids sin host que los
   atienda desde el 2026-10-13; la ruta de Claude por su CLI (abajo) decide si
   reutiliza `claude_opus` o entra con un id nuevo, y los demás se retiran del
   archivo en este bloque con su prueba, porque ningún host los implementa.
4. Refrescar fuentes/skills de especialidad por caducidad; acotar mantenimiento,
   backoff, coste y cambios. Aplicar generación con CAS, atestación y read-back.

<!-- corr: B22 -->
**Lo que B22 ya dejó para este bloque.** La ruta por CLI ya tiene su política de
proveedores: `docs/evidence/agent-work/proveedores-permitidos.json` (permisos con
forma de cobro y la frase fechada de David, y cierres que ningún comando reabre) y
`scripts/agent-work/encargo.py proveedores|permitir|cerrar`. El catálogo sale de
`opencode models`, no de una lista escrita a mano: un modelo nuevo de un proveedor
permitido corre sin editar ningún archivo (canario D de `B22-canarios.md`). SUA-04
parte de ahí y no crea otra lista para esa ruta. Lo que B22 no hizo y sigue siendo
de este bloque: sucesión y promoción automática, modelo por omisión por proveedor,
Claude por su propio CLI (B22-S5) y que `main` abra un proveedor a pedido de David
(B22-S6).

**Verificar:** I10/I11/I19. Sucesor estable funciona sin editar IDs a mano; preview,
proveedor sin acceso y canary fallido no se promueven. Alta posterior recibe y
devuelve tarea; alta incompleta queda visible. Crash entre aplicar/verificar no
activa bytes no acreditados. Revocación permanece tras reversa.

## SUA-05 — Ingeniería y calidad

**Dueño:** G/R y cada repo consumidor. **Archivos:** <!-- corr: D14 -->
`scripts/ci-fast-allowlist.txt`, `scripts/run-checks.sh`, `.github/workflows/`,
verificadores de cobertura/corpus, hooks, recetas de repos y reglas administradas.
Nuevos: política de calidad versionada y catálogo de efectos por repo.
<!-- corr: D14 -->
`corrida_worker/gates.py` ya no existe (PR #291) y no es archivo de este bloque.

<!-- corr: D14 -->
**La política de rondas como datos, escrita nueva.** `gates.py` salió del repo con
la ruta de corrida; las reglas `mismo-revisor` y `bloqueante-repetido`
desaparecieron con él y no hay nada que migrar. La política que este bloque
escribe trae exactamente las reglas vigentes, con su fuente:
- La regla 4 de quality-kit (`~/.claude/CLAUDE.md`, "REGLAS DE CALIDAD"): los
  hallazgos se agrupan y se corrigen en una ronda por bloque; solo un hallazgo
  bloqueante reabre el ciclo (seguridad, datos, regla innegociable, conducta
  pedida rota o prueba que no discrimina), siempre con el comando que lo
  reproduce; un bloqueante nunca va a una fila del plan ni se mergea abierto;
  lo no bloqueante se corrige en la misma ronda si es de una línea y si no va a
  una fila del plan y se nombra en el PR.
- El tope de David del 2026-10-12 (`decisiones-para-david.md`, "Lo que David
  contestó", punto 1; `prompt-claw` SKILL.md:59): hasta 5 rondas por
  implementador, relevo a otro modelo con otras 5, y después se le pregunta. La
  pregunta es una `excepcion` `NECESITA_DAVID`.
- El revisor asignado excluye a todos los autores; revisan además los bots del
  PR y CI; ningún paso pide revisión a un segundo modelo (`~/.claude/CLAUDE.md`,
  "Revisión cruzada").
La forma: un archivo versionado en G, al estilo de `proveedores-permitidos.json`,
con `version: "quality-kit.regla4"` (el literal que `meta.qualityPolicy` ya
nombra en el contrato), los topes como números, las tres reglas como campos y la
frase fechada de David. No lleva rotación forzada de revisor ni paro por
bloqueante repetido: un bloqueante que vuelve cuenta como una ronda más, hasta el
tope. El contador por linaje del paso 2 y la escalación persistente se guardan
junto a la raíz, en R.

1. Implementar revisión independiente, resultados tipados, cobertura completa del
   diff y escritura restringida al resultado. No recortar silenciosamente el diff.
   <!-- corr: K9 -->
   La revisión independiente es la del revisor asignado, más los bots del PR y CI.
2. <!-- corr: C2 K8 -->
   Implementar la política de rondas como datos versionados: contador por linaje
   estable del bloque, hallazgos acumulados, relevo y escalación persistente. La
   versión que se activa es la regla 4 de quality-kit vigente (y 5+5 en los loops
   de claw). Cuatro es un límite inicial propuesto, no una cifra medida. La última
   orden de David sobre rondas (2026-09-29, PR #227, fila 9) es 5 rondas por
   implementador, relevo a otro modelo con otras 5 y después preguntar; stop2 la
   sustituyó en `8358fac` sin decisión registrada. Implementar la política no la
   activa. **Cambiarla es una sola decisión explícita de David que fija el número
   de ciclos (por ejemplo 3, 4 o 5+5) y su alcance.** Se registra recibo con
   principal, alcance, versión/digest anterior y nuevo, fecha y read-back. Una
   autorización genérica del programa no la activa. Las raíces existentes
   conservan su versión de calidad; una promoción no amplía sus ciclos. Actualizar
   instaladores/consumidores al adoptar; no editar a mano marcadores de quality-kit
   ni el bloque administrado de AGENTS.md para adelantarse.
3. Unificar merge en CI/reviewer del head exacto, check-run del bot, SHA esperado
   y lectura remota del resultado. Migrar y retirar la tabla de merge redundante.
4. Implementar push/PR draft, reintento CI, corrección, rebase y ready por política
   del repo. Separar autoridad de merge/deploy de respuestas a diálogos CLI.
5. Corregir el carril rápido del corpus y la duplicación de `test-ci-coverage-contract`;
   probar inventario y unión de shards. Mantener hooks, regresión y batería íntegra.
6. <!-- corr: K9 -->
   `cross-review.ps1` ya está retirado por orden de David en todos los repos
   (`~/.claude/CLAUDE.md`, "Revisión cruzada"). No se migra a otra revisión con
   segundo modelo.
   <!-- corr: D14 -->
   Las tres piezas que coincidían con la regla vigente (revisión aprobada del head
   exacto antes del push, revisor que no es autor y cero bloqueantes para merge)
   se escriben nuevas en la política de datos de arriba, no se copian de
   `gates.py`, que ya no existe. Lo único que queda por retirar es la copia del
   paro por bloqueante repetido en `docs/runbooks/loop-autopilot.md` §4 (`:112`,
   "Si el mismo bloqueante vuelve en dos rondas seguidas"), que sigue ahí después
   del PR #291. El kit puede seguir como bootstrap opcional externo.

**Verificar:** I12/I13/I21. Código cero con texto `BLOCKER` no aprueba; evidencia de
otro head falla; comentario de bot sin check-run falla. Un bloqueante nuevo en
cada ronda no reinicia límites. Activar una política distinta de la vigente sin
la decisión registrada de David falla; con ella, rige sólo raíces nuevas del
perímetro adoptado <!-- corr: C2 -->. Ningún paso pide revisión a un segundo modelo <!-- corr: K9 -->. Cambiar corpus dispara
su checker; shard vacío o
prueba omitida hace fallar cobertura. Reviewer sin acceso de escritura a fuente.

## SUA-06 — Seguimiento y panel

**Dueño:** proyección/emisor locales; G empaqueta. **Archivos:** proyección nativa,
`scripts/agent-work/progress_bridge.py`, contratos de seguimiento y manifiesto LobsterBoard.

1. Antes de UI propia, probar LobsterBoard original con plantilla, commit, licencia,
   assets y dependencias fijados. Guardar capturas móvil/escritorio y faltantes.
2. Proyectar meta/unidad/intento desde recibos nativos; distinguir declarado,
   observado, aceptado y desconocido. Vincular evidencia y próxima comprobación.
3. Unificar avisos y panel sobre el mismo snapshot; conservar un emisor por host,
   entrega durable, reintentos y checkpoint posterior al envío confirmado.
   <!-- corr: K5 -->
   En la Mac ese emisor ya existe: el host de encargos publica su propia cola de
   avance (B16, `ProgressPublisher` en `native_gateway.py`).
   <!-- corr: D14 -->
   El latido de corrida (`latido.sh`, plist `ai.goncloud.corrida-latido`) salió
   del repo con la ruta de corrida (PR #291) y no está cargado en la Mac. El reloj
   de SUA vive en el scheduler nativo y en los eventos que R emite (SUA-02), no en
   un LaunchAgent. El emisor de la Mac sigue siendo el host; el de la Mini, la
   proyección nativa de este bloque.
4. Aplicar allowlist de campos/URLs, escape, límites y autenticación. Panel inicial
   de lectura; acciones se mantienen en las entradas autenticadas existentes.
5. Hacer sólo ajustes ligados a faltantes. Si requiere reescritura amplia, detener
   la entrega UI con evidencia y alternativas; no sustituirla automáticamente.

**Verificar:** I14/I15/I16/I17. Dos tareas comparten reloj y consolidado; cerrar una
no apaga la otra. Una sin PR puede cerrar por evidencia. Probar teclado/móvil,
error/offline/vacío, frescura, corrupción, PID reutilizado, métricas ausentes y
secretos/XSS sintéticos. Sin OpenGrokBot instalado. Probar fallos de envío sin ACK.

## SUA-07 — Hermes independiente

**Dueño:** integración local H. **Archivos:** se fijan con el inventario real en el
primer paso; contrato objetivo y fixtures son los de SUA-00, no APIs inventadas.

<!-- corr: D13 -->
Hermes corre en la PC de Gon (David, 2026-10-13): `gon-pc` en la red privada,
Windows. El 2026-10-13 a las 15:05 UTC esa máquina estaba apagada o fuera de la
red, así que la versión y las interfaces siguen `unknown`. El paso 1 se hace ahí.
<!-- corr: D14 -->
SUA-07, SUA-09H y SUA-10H empiezan cuando `gon-pc` esté en la red, y no frenan
nada de OpenClaw: SUA-01 a SUA-06, SUA-08, SUA-09O y SUA-10O corren sin esperarla.
Comprobación: `tailscale status` desde la MacBook lista `gon-pc` como conectada
(`unknown` si esa máquina no está en la tailnet: entonces `ping gon-pc` desde la
red privada). En esta Mac no hay runtime de Hermes; `~/dev/goncloud-hermes` es su
configuración versionada, no el runtime (`SUA-00-inventario.md`, "Orbit (O) y
Hermes (H)").

1. Identificar instalación, plataforma, entradas, store, scheduler, identidad,
   autoridad, procesos y transporte. Registrar cada interfaz soportada y su versión.
   Registrar qué contratos/fixtures compartidos están listos aunque una integración
   R siga pendiente; las dependencias del paquete no exigen disponibilidad de R.
2. Implementar controlador y frontera transaccional locales. Si no hay operación
   durable adecuada, añadirla al host local antes de habilitar tareas compuestas.
3. Implementar los mismos contratos de poteto, flota, calidad, proyección y control.
   Compartir fixtures/esquemas; no credenciales, sesiones, cola ni RPC OpenClaw.
4. Acreditar versión/capacidades y fallos recuperables. Publicar instalador/reversa
   propios para SUA-09H. El modo legacy `--vigia hermes` no acredita este bloque.

**Verificar:** I01–I14/I16/I18/I20 contra H. Ejecutable y gateway OpenClaw ausentes
en el entorno de prueba; romper su acceso no altera Hermes. Una capacidad faltante
impide aceptar esa ruta y no bloquea desarrollo ni aceptación de OpenClaw.

## SUA-08 — Orbit

**Dueño:** O, con receta invocada por efecto admitido. **Archivos:** `docs/DEPLOY.md`,
nuevo `scripts/deploy-goncloud.sh` y prueba con dobles de SSH/Docker; receta en G.

1. Confirmar branch, método de merge, hooks EHV, destino y autoridad del repo.
2. Automatizar archivo desde revisión remota, copia verificada, respaldo y rebuild
   de la aplicación con `--no-deps`; conservar receta vigente y salud en 8010.
3. Registrar intención y recibo por SHA/destino. Consultar resultado tras fallo de
   transporte; no repetir un deploy incierto por silencio. Implementar reversa.
4. Permitir la ruta sin operador rutinario sólo dentro de una política que cubra
   selección del artefacto, publicación, destino y verificación.

<!-- corr: D14 -->
La autorización del 2026-10-13 cubre los pasos 1 a 3 con dobles y el script. No
cubre ningún deploy de producción en el servidor de Orbit: antes del primer deploy
real (paso 4 y el ensayo de SUA-10O) se le avisa a David con el SHA, el destino y
la reversa, y se espera su respuesta.

**Verificar:** I23 primero con dobles: SHA equivocado, copia incompleta, fallo de
salud y ACK perdido. Ensayo real autorizado en SUA-10O; un script escrito o mock
verde no acredita el deploy vivo ni permite cerrar Orbit.

## SUA-09O y SUA-09H — Publicación y cambio de dueño

<!-- corr: K3 K10 -->
**Dueño:** instalador del host respectivo. **Archivos:** en OpenClaw, la
publicación a la Mac Mini del gateway (`gon@100.73.187.5`) que dejó encargos:
`scripts/agent-work/artifact.py` con `artifact-manifest.json`,
`scripts/agent-work/cutover_live.py` y los scripts `t12-parte-a.sh` y
`t12-actualizar-<sha>.sh`. Esos scripts hoy viven fuera del repo
(`~/.local/state/encargos-loop/artifacts/T12/`); SUA-09O los versiona con sus
pruebas. U1/sync seguro queda para la PC Windows de respaldo. También
`scripts/mac/instalar-mac.sh` y el paquete H. Nuevo manifiesto de paquete con
commits, migración de store, rutas administradas y capacidades.

1. Preparar paquete reproducible; registrar versiones compatibles y reversa.
   Añadir destinos administrados de agentes/plugins con validación y read-back.
   <!-- corr: C2 -->
   Si David decidió cambiar la política de rondas, incluir el recibo de esa
   decisión para su perímetro; sin él no cambiar reglas al instalar ni declarar
   completada esa adopción.
2. Instalar dos veces en entorno aislado; verificar convergencia, upgrade y reversa
   conservando tareas, permisos revocados, identidad y memoria.
3. Inventariar todas las entradas del vigía, cron y launchers. Poner la ruta nueva
   en sombra; detener admisión antigua; drenar y conciliar; cambiar dueño por CAS.
   <!-- corr: K4 -->
   <!-- corr: D14 -->
   El inventario parte del `coverage.json.modelWakes` ya rehecho en "Preparación
   antes de SUA-01", punto 2 (la foto del 2026-10-07 queda como historia), y de
   una lectura nueva de `openclaw cron list --json` el día del corte: M-09 del
   2026-10-13 dio 30 crons habilitados y un solo vigía, `bids-02-vigia`, que se borró ese mismo día, y
   `prompt-claw` §7 ya no crea `<loop>-vigia` en la ruta de encargos. El cambio
   de dueño usa el corte existente (`cutover_live.py`, `agent-work-cutover.v2`,
   subcomandos `prepare|inspect|apply|freeze|revert`; `rollback` es función sin
   subcomando), que dejó `loop:canario-encargos` con dueño `native` en la
   generación 2. No se escribe otro mecanismo de corte. David autorizó este
   cambio de dueño sin esperarlo (2026-10-13, "3. si"); cada instalación en la
   Mini sigue la "Regla de instalación en vivo".
4. Verificar antes de activar. Un apply sin attest no admite trabajo. Conservar las
   entradas no migradas; retirar un cron compartido sólo cuando migren todas.
5. Añadir alias futuro `SUA` al launcher y validador del plan; probar localización,
   dry-run y rechazo/redirección informativa de U3b/U4/U5/U6/F antiguos. El alias
   numérico 6 nunca significa U6. Actualizar runbook y prompt de Claw para leer
   este plan; un alias histórico no puede lanzar un segundo programa.

**Verificar:** I19/I22/I24 por host. Crash en cada borde del corte, dos generaciones
concurrentes, resultados pendientes y proceso adoptado. Exactamente un dueño
admite por entrada. Reversa incompatible mantiene pausa y reparación; no revive
el dueño viejo mientras el nuevo conserva trabajo. Cron de negocio sigue activo.

## SUA-10O y SUA-10H — Aceptación por computadora

**Dueño:** verifier independiente y responsable de publicación del host.

1. Reusar fixtures/CI válidos; ejecutar I01–I24 aplicables contra el paquete final.
   I23 requiere Orbit en SUA-10O; en Hermes se prueba contrato de efecto y se
   referencia el recibo Orbit, sin duplicar su despliegue por demostrar paridad.
2. Ejecutar un pedido nativo de dominio y un plan de ingeniería con CLI. Cubrir las
   tres entradas heredadas de U3b; no exige repetir tres veces todos los ensayos.
   <!-- corr: C3.1 -->
   Uno de los pedidos llega por Telegram en prosa a OpenClaw y termina con el
   cambio mergeado y desplegado. Los avisos y excepciones de ese pedido llegan por
   Telegram, sin preguntas fuera de una excepción tipada. Es el `FUNCIONA` que
   heredan 20.10 y U4.
3. Probar otro runtime inaccesible, pérdida de ACK, reinicio, pausa/cancelación,
   permiso revocado, sucesor de modelo, alta nueva y fallo de fuente de dominio.
4. Registrar capturas de panel, mensajes redactados, resultados, modelo/contexto
   efectivos, costes/latencias medidos y lectura de versiones instaladas.
5. Ejecutar checklist posterior al deploy una vez. Guardar aceptación del usuario
   cuando corresponda; no fabricar un `FUNCIONA` ni pedir repetirlo sin invalidación.

**Verificar:** recibo separado por host y por Orbit, cero bloqueantes abiertos,
criterios completos y límites explícitos. Fuentes desconocidas o ruta sin poteto
no cuentan como aprobadas. OpenClaw puede aceptarse antes que Hermes. No declarar
paridad o cierre total usando sólo el recibo de una computadora.

## SUA-11 — Cierre y retiro residual

**Dueño:** G, con recibos de R/H/O.

1. Conciliar cobertura de las 39 filas antiguas y criterios adicionales. Registrar
   cambios deliberados de política; una obligación omitida deja el programa abierto.
2. Confirmar cero consumidores de autoridades, wrappers y copias retiradas. Eliminar
   sólo los residuales ya migrados; conservar evidencia histórica y cron de negocio.
   <!-- corr: D13 -->
   La ruta de corrida y la sesión adoptada de encargos no esperaron a este bloque:
   David decidió retirarlas el 2026-10-13 y salieron en PR propios (#291 y #290).
   <!-- corr: D14 -->
   Lo que ese retiro dejó para aquí, según `followups.md` ("Retiro de corrida
   (residuales)"): `AgentesBackend` en `resources.py`, `Host.receipt` y la rama
   de `Host.apply` sin `adapter_id`, sin punto de entrada fuera de pruebas (las
   filas A11 a A13 de `acceptance.md` descansan en esas pruebas). Este bloque los
   retira con sus pruebas, o deja escrito por qué se quedan. Los otros restos de
   esa fila (`seguimiento.v1.md` nombra `corrida_mensaje`, `T12-runbook.md` B.4 y
   el plan de encargos `:287` nombran `review_tail_restart`, la tabla "Clases de
   comando" de `autopilot-runbook`, tres pesos de `ci-duraciones.tsv`) se
   corrigen cuando alguien toque esos archivos, no aquí.
3. Publicar un único cierre del programa con enlaces a recibos. No repetir baterías
   válidas para producir otra marca verde. Registrar mejoras observadas frente al
   baseline y lo que no mejoró; no prometer ahorro sin medición.

**Verificar:** cobertura sin huecos, aceptación OpenClaw/Hermes/Orbit, política única
instalada y leída de vuelta, ningún launcher antiguo activo para el mismo encargo.

## Ensayos integrados

| ID | Resultado que debe distinguir |
|---|---|
| I01 | Pedido natural, plan y fila importada conservan alcance, supuestos y criterios. |
| I02 | Ciclo, ID duplicado, dependencia o criterio faltante se rechazan antes de lanzar. |
| I03 | A+B→C con dos reconciliadores y ACK perdido crea exactamente una C bajo la raíz. |
| I04 | Caídas entre commit/admisión/consumo recuperan tareas y gasto; termina el turno y sigue el plan. |
| I05 | Pausa/cancelación contra permiso Started; envío posterior al ACK queda enumerado si ya estaba comprometido. Replay de control estable, Resume obsoleto rechazado, eventos tardíos sin resurrección. |
| I06 | Efecto confirmado no se repite; efecto incierto conserva estado y exige conciliación. |
| I07 | Autoridad negativa, revocación, otra sesión, diseño, mail borrador y SHA futuro restringen efectos. |
| I08 | Poteto completo llega y funciona en las cinco rutas vivas (turno nativo, hijo nativo, encargo nativo a un agente, encargo por CLI con un proceso de opencode por encargo, hijo de una CLI); ausencia impide admitir la ruta. <!-- corr: D14 --> |
| I09 | En la ruta por CLI el modelo efectivo es el pedido (cabecera del brief, `-m` lanzado, modelo que opencode usó); un intento nuevo conserva su snapshot; permisos efectivos medidos; opencode y sus hijos dentro del grupo del slot; reviewer sin escritura en fuente. <!-- corr: D14 --> |
| I10 | Sucesor estable se promueve automáticamente; preview/incompatible falla; intento activo conserva snapshot. |
| I11 | Alta nueva conecta ida/vuelta; perfil incompleto visible; competencia, caducidad y memoria preservada. |
| I12 | Corrección converge o detiene; nuevos hallazgos/relevo no reinician linaje. Cambiar la política vigente exige la decisión registrada de David; raíces previas conservan política; ningún paso pide revisión a un segundo modelo. <!-- corr: C2 K9 --> |
| I13 | Review/CI del head, criterio y entorno vigentes; LISTO, merge, rollback y criterio borrado no fabrican éxito. |
| I14 | Panel y aviso comparten estado/porcentaje; dos tareas, CI en espera y tareas sin PR se representan bien. |
| I15 | LobsterBoard original y ajustes probados en móvil/escritorio, teclado, vacío/error/offline y frescura. |
| I16 | PID reutilizado, sesión caída, datos corruptos y métricas ausentes no atribuyen ni matan recursos ajenos. |
| I17 | Secretos sintéticos, XSS y rutas/URLs maliciosas no se filtran por vista/evento/exportación. |
| I18 | Advisor con/sin eventos declara cobertura; caída no aprueba ni despacha. |
| I19 | Generaciones, apply sin attest, nuevo destino y reversa conservan autorización y tareas. |
| I20 | Presupuesto raíz, cupo global y escritor exclusivo; par atómico con dos/tres plazas ocupadas. |
| I21 | Batería íntegra, unión de shards, corpus real, logs y hooks; sin prueba omitida o duplicación inútil. |
| I22 | Corte por entrada deja un dueño; pending results/crash/reversa y cron mixto no pierden trabajo. |
| I23 | Orbit por SHA remoto, respaldo, copia, salud y reversa; autorización e incertidumbre comprobadas. |
| I24 | Cada host instala/reinstala/revierte y opera con el otro inaccesible; alias/runbook no duplican programas. |

<!-- corr: D14 -->
I08 e I09 se reescribieron el 2026-10-13 para las rutas que existen. Las seis
rutas del diseño eran cinco más "inicio" y "resume" de una CLI en tmux, que se
retiraron con la ruta de corrida (PR #291); la reproducción de argv de esas CLI
(`_check_argv_element`, `worker_argv`) se fue con ellas, y la de la ruta viva está
en SUA-03 paso 5. El manifiesto `scripts/tests/fixtures/sistema-agentes/manifiesto-ensayos.json`
copia el texto de esta tabla; `test-sistema-agentes-contrato.py` los compara.

## Comandos existentes y comandos futuros

Se confirmaron en fuente los siguientes puntos de entrada. Esta lista no afirma
que se hayan ejecutado como parte del diseño ni que acrediten contratos nuevos.

| Repositorio | Comando existente | Uso futuro |
|---|---|---|
| G | `bash scripts/tests/test-sistema-agentes-contrato.sh` | Validador del contrato contra sus fixtures, manifiesto de ensayos contra esta tabla e inventario de SUA-00. <!-- corr: D14 --> |
| G | `python3 scripts/tests/test-agent-work-modelos.py` | Política de proveedores, catálogo y `authorize`: la flota de la ruta por CLI. <!-- corr: D14 --> |
| G | `python3 scripts/tests/test-agent-work-sesion.py` | Cabecera del brief, argv de opencode, frontera del grupo. Sus clases `Live*` no corren con un encargo en vuelo. <!-- corr: D14 --> |
| G | `python3 scripts/tests/test-agent-work-encargo.py` y `test-agent-work-lanzar-encargos.py` | `preparar`, `estado`, `proveedores|permitir|cerrar` y el lanzador del host. <!-- corr: D14 --> |
| G | `bash scripts/tests/test-agent-work-e2e.sh acceptance` | Par de aceptación de encargos. Desde el 2026-10-11, por decisión de David, la CI no lo exige en cada bloque; corre una vez al cierre. <!-- corr: K1 --> Los casos `main_cli_loop`, `cutover_fencing` y `acceptance_pair` exigen `AGENT_WORK_RUNTIME_SOURCE` con R construido ("Preparación antes de SUA-01", punto 1). <!-- corr: D14 --> |
| G | `python3 scripts/tests/test-agent-work-routing.py` | Rutas de encargo (`CLI_ROUTES`, `taskKey`); da rojo si vuelve `key`. <!-- corr: K7 --> |
| G | `AGENT_WORK_RUNTIME_SOURCE=/ruta/R bash scripts/agent-work/test-runtime.sh handling_atomic` | Consumo/decisión nativos existentes; no prueba fan-in nuevo. |
| G | Mismo runner con `budget_tree`, `budget_evasion`, `admission_restart`, `result_receipt` | Guardas existentes de presupuesto, reinicio y resultado. |
| G | `bash scripts/run-checks.sh` | Batería completa; CI usa shards cuya unión se comprueba. |
| G | `pre-commit run --files <archivos-del-cambio>` | Hooks sin omitir. |
| R | `pnpm format:check`, `pnpm lint`, `pnpm tsgo:core` | Baseline de calidad del runtime inspeccionado. |
| R | `node scripts/run-vitest.mjs <archivo> --testNamePattern <caso>` | Casos concretos registrados al implementar. |

SUA-00 registra comandos reales para H; SUA-09 crea y verifica el launcher SUA.
<!-- corr: C5.1 -->
`director_handling` no está en la lista del runner `test-runtime.sh`, pero sí existe
como `DirectorHandlingTest` en `scripts/tests/test-agent-work-integration.sh`
(desde `77fafb0`). Se invoca por ese runner. `--help` de un perfil aislado prueba ayuda, no activación.
La aceptación guarda salida real del comando y artefacto al que corresponde.

## Evidencia y detenciones

Cada recibo incluye bloque/ensayo, host, commits o digest del paquete, versiones,
criterios, comando/procedimiento, entorno, resultado, fecha, verificador, costes
medidos y límites. Los registros se redactan antes de publicar. Las rutas locales
privadas y credenciales no se copian al panel.

Una falta de permiso detiene el efecto afectado. Una capacidad desconocida detiene
su integración. Un bloqueante detiene su bloque. Otra unidad independiente puede
seguir dentro de la autoridad y presupuesto; no se inventa un aprobado para
desbloquearla. La petición de operador incluye diagnóstico, artefacto revisable y
opciones concretas, sin convertir una preferencia de skill en permiso nuevo.
