# Plan: Sistema unificado de agentes

Fecha: 2026-10-05. Identificador: **SUA**. Estado: **SUA-00 autorizado el 2026-10-13; los demás bloques siguen en diseño**.
<!-- corr: K1 -->
Revisado el 2026-10-12 contra G `6e01ec0` y R `605aef7`, después del cierre de encargos.
<!-- corr: B22 -->
Bases y contacto con B22 actualizados el 2026-10-13 contra G `c11d74ed` y R `4acb881`.

<!-- corr: C1.6 K9 K10 -->
Este plan propone el único programa futuro para U3b, U4, U5, U6 y flota. Rige
cuando David apruebe su orden; hasta entonces es diseño. Integra la adopción
selectiva de OpenCode. Retira los restos de coordinación de quality-kit que siguen
en G: la rotación forzada de revisor y el paro por bloqueante repetido de
`scripts/mac/corrida_worker/gates.py`, y su copia en la §4 de
`docs/runbooks/loop-autopilot.md`. La revisión con otro modelo ya la quitó David
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

La solicitud actual permite diseñar y revisar documentos. No permite implementar,
lanzar trabajadores, instalar, cambiar modelos vivos, enviar mensajes, mergear ni
desplegar. Una autorización futura se interpreta con su alcance real y se conserva;
no se vuelve a pedir para cada paso que ya cubra. Escribir este plan no la concede.
<!-- corr: C1.6 C2 -->
Dos cosas no las cubre nunca una autorización genérica del programa: el orden SUA
frente al orden vigente en main y la política de rondas de corrección. Las dos
son decisiones explícitas de David, con fecha y registro.

<!-- corr: B22 -->
**Decisiones de David vigentes.**

- 2026-10-13: "1. sí solo SUA-00 2. claude y glm". Autoriza SUA-00 y nada más. Lo
  implementa Claude y lo revisa GLM. El orden de SUA-01 en adelante se decide con el
  inventario de SUA-00 en la mano.
<!-- corr: D13 -->
- 2026-10-13, después del inventario: "1. si 2. es en gon pc 3, se wuita 4. se quita".
  Contesta las cuatro preguntas que dejó SUA-00. Uno: autoriza las mediciones vivas
  sobre el gateway; se corrieron ese día y están en
  `docs/evidence/sistema-agentes-unificado/SUA-00-mediciones.md`. Dos: Hermes corre
  en la PC de Gon (`gon-pc` en la red privada, Windows). Tres: la ruta de corrida
  (`scripts/mac/corrida.sh`, `corrida/`, `corrida_worker/`, `workers.v1.json`) se
  retira; no se migra a SUA. Cuatro: la ruta de sesión adoptada de encargos se
  borra con sus pruebas. Los dos retiros van en PR propios. Las marcas
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
| G | origin/main `c11d74ed5a0b239ed4bd61c4d8a20c1f76dc2dda` (PR #285) | Encargos B0–B19 y B22 mergeados. Host de la Mac (`scripts/agent-work/`): desde B22 un solo host lanza un `opencode run -m <modelo>` por encargo (`lanzar-encargos.sh`, `sesion.py`), el modelo viaja en la cabecera del brief (`brief.py --model`) y `proveedores-permitidos.json` dice qué proveedores se pueden pedir. La ruta por alias y `lanzar-host.sh` ya no existen. Corte `cutover_live.py` (`agent-work-cutover.v2`), publicación propia del avance al tablero (B16) y `--close-only` (B14). El diseño se escribió en `~/dev/wt/flota-poteto` sobre `e5cae2d`, cabeza del PR #247, que se cerró sin entrar a main. |
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
- El latido (`ai.goncloud.corrida-latido`) está descargado desde el 2026-09-27 y no
  se enciende para publicar avance: el host publica el suyo.

<!-- corr: C5.2 K2 -->
Antes de implementar se reconcilian estas bases con los commits aprobados.
<!-- corr: B22 -->
El PR #247 se cerró el 2026-10-12 por decisión de David. Su código previo, que
este diseño no acepta, no entró a main. Lo que sí entró, por un PR aparte, es su
rechazo de caracteres de control: `_check_argv_element` llama a `has_control`
(`scripts/mac/corrida_worker/registry.py`), `worker_argv` revisa cada argumento ya
sustituido (`scripts/mac/corrida/lib.sh`) y `scripts/tests/test-worker-model-binding.sh`
está en main. SUA-03 vuelve a correr esos dos casos sobre main antes de admitir
esa ruta, y solo corrige lo que todavía falle. U1/U3/U3a/Fase14 y encargos conservan sus
recibos; sólo se repite evidencia invalidada o de un perímetro nuevo.

<!-- corr: C1.1 C1.2 C1.3 K10 -->
**Orden con encargos.** T11 y T12 los terminó el loop de encargos; SUA no los
absorbe ni los repite. Los seguimientos abiertos están en
`docs/evidence/agent-work/followups.md` y los cierra ese loop (B18-G en G y B18-R
en R sobre `605aef7`). SUA-01, y cualquier bloque que escriba en
`src/agents/tasks/` o en las herramientas `managed_tasks_*` de R, empieza después
de que B18-R esté mergeado o cerrado. El plan de encargos (`:67`) prohíbe dos
escritores en paralelo sobre `R.taskStore` y `R.scheduler`. Si David lo aprueba,
SUA-00 corre antes, en solo lectura, desde G `c11d74ed` y R `4acb881`
(autorizado el 2026-10-13). B18-G y B18-R ya están mergeados e instalados, así
que esa condición de SUA-01 está cumplida. Su
inventario incluye las incidencias de host (`managedTasks.host.incident`;
`record_incident` y `flush_incidents` en `scripts/agent-work/host.py` y
`spool.py`), `CLI_ROUTES` (`routing.py`), `coverage.json.modelWakes`,
`main_cli_loop`, `detect_silent_failures`, `managedTasks.host.cancellation`, el
corte `cutover_live.py` y la publicación del host (`ProgressPublisher`).

## Orden y dependencias

Un bloque puede integrar código sin activar producción. Cada integración registra
el par de versiones G/R o el paquete Hermes que la acredita. Las dependencias son
de artefactos; compartir contratos no crea dependencia de disponibilidad entre hosts.

| Bloque | Entrega | Depende de | Estado |
|---|---|---|---|
| SUA-00 | Inventario residual, contratos y fixtures comunes | — | autorizado el 2026-10-13 |
| SUA-01 | Estado, DAG y control atómicos en OpenClaw | SUA-00; B18-R de encargos mergeado o cerrado <!-- corr: C1.1 --> | pendiente |
| SUA-02 | Controlador, autoridad y excepciones | SUA-01 | pendiente |
| SUA-03 | Poteto, perfiles y rutas nativo/CLI/OpenCode | SUA-02 | pendiente |
| SUA-04 | Catálogo, promoción y alta automática | SUA-03 | pendiente |
| SUA-05 | Ingeniería y calidad propias del sistema | SUA-02, SUA-03 | pendiente |
| SUA-06 | Proyección, avisos y LobsterBoard | SUA-02 | pendiente |
| SUA-07 | Implementación Hermes independiente | SUA-00 | pendiente |
| SUA-08 | Automatización de deploy de Orbit | SUA-05 | pendiente |
| SUA-09O | Paquete y transición exclusiva OpenClaw | SUA-04, SUA-05, SUA-06 | pendiente |
| SUA-09H | Paquete y transición exclusiva Hermes | SUA-04, SUA-05, SUA-06, SUA-07 | pendiente |
| SUA-10O | Aceptación OpenClaw y Orbit | SUA-08, SUA-09O | pendiente |
| SUA-10H | Aceptación Hermes | SUA-09H | pendiente |
| SUA-11 | Retiro residual y cierre del programa | SUA-10O, SUA-10H | pendiente |

SUA-07 puede empezar con el contrato sin esperar el código de R. SUA-09H consume
formatos, políticas y fixtures de SUA-03–06; no llama sus servicios OpenClaw.
La parte OpenClaw de SUA-10O puede emitir su recibo antes del ensayo Orbit; el
bloque completo espera ambos. Hermes no bloquea ese recibo ni el de Orbit.

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
SUA-05 implementa la política de rondas que fije David. Hasta esa decisión rige la
regla 4 de quality-kit tal como está en `~/.claude/CLAUDE.md`: se agrupan los
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

## SUA-01 — Frontera durable OpenClaw

**Dueño:** R. **Archivos:** `src/agents/tasks/managed-task.{db,store,types}.ts`,
handling, admission, budget, recovery y sus tests; entrada gateway correspondiente.
<!-- corr: C4 -->
Módulo nuevo sólo si SUA-00 decide no reutilizar `SessionGoal`; nombre provisional
`src/agents/goals/`, con decisiones separadas del store.

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

**Dueño:** R para control local; G para adaptadores/recetas. **Archivos:** módulo
de metas que fije SUA-00 (`SessionGoal` o `src/agents/goals/`) <!-- corr: C4 -->; `scripts/mac/corrida_worker/{reconcile,task_handoffs,state}.py`,
entradas `corrida.sh` y skill `native-harness-orchestration` como consumidores.

<!-- corr: D13 -->
La ruta de corrida se retira (David, 2026-10-13). `corrida_worker/{reconcile,task_handoffs,state}.py`,
`corrida.sh` y la skill `native-harness-orchestration` dejan de ser consumidores de
este bloque. La última frase del paso 5, la de reemplazar el decisor legacy por
adaptadores de entrada, queda sin objeto: ese decisor se borra y no se envuelve. El verbo con que se despierta al controlador se elige con las
mediciones del 2026-10-13 (`SUA-00-mediciones.md`, "Qué deciden estas mediciones"):
un `system event` a `main` espera detrás de cualquier turno de `main` en vuelo, y
un `agent --message` a una sesión distinta de la ocupada no esperó en la única
muestra que se tomó.

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
   Reemplazar el decisor legacy por adaptadores de entrada al nuevo dueño.

**Verificar:** I01–I07/I12. Tres entradas: pedido pequeño, fila importada y pedido
compuesto. El turno termina y la meta continúa. Respuestas con cero/una/varias
excepciones no se aplican a otra. Un pedido grande autorizado no pregunta por
ritual; crear repo o enviar mail sin autoridad sí queda detenido.

## SUA-03 — Poteto y trabajadores especializados

**Dueño:** G/R. **Archivos:** `scripts/mac/workers.v1.json`,
`corrida_worker/{registry,selector}.py`, `scripts/mac/corrida/lib.sh`, adaptadores
nativos/CLI, configuración efectiva de perfiles y manifiestos administrados.

<!-- corr: D13 -->
La ruta de corrida se retira (David, 2026-10-13). `workers.v1.json`,
`corrida_worker/{registry,selector}.py`, `corrida/lib.sh` y los adaptadores que
abren una CLI en tmux dejan de existir, y este bloque no los migra. De las seis
rutas del paso 2, "inicio" y "resume" de una CLI en tmux eran de esa ruta. La
reproducción de argv del paso 5 era sobre `_check_argv_element` y `worker_argv`,
que se van con ella. La única ruta por CLI que queda es un proceso de opencode por
encargo. Qué queda de cada paso se decide al abrir este bloque, con el inventario
al día.

1. Materializar contexto de poteto canónico, perfil, skills y evidencia por tarea.
   Preservar memoria y archivos del usuario. Versionar contenido y adaptación.
2. Certificar seis rutas: turno, hijo y encargo nativo; inicio, resume e hijo CLI.
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
5. Reproducir y corregir discrepancias de argv/modelo, incluido `--model\nwrong`
   dentro de un argumento. Reanudar conserva el snapshot. Una ruta opaca no miente
   sobre el modelo y queda inelegible donde se necesita versión exacta.
   <!-- corr: C5.2 K2 -->
   <!-- corr: B22 -->
   La reproducción corre sobre main, que desde el 2026-10-12 ya trae el rechazo de
   caracteres de control en `_check_argv_element` y en `worker_argv`. Si los dos
   casos pasan, este punto se cierra con su recibo y sin cambio de código.
6. Registrar y marcar sesiones antes de entregar instrucciones; serializar teclas
   por sesión propia. Conservar `.corrida/` fuera de Git y separar fuente del
   directorio autorizado donde el reviewer entrega su resultado.

**Verificar:** I08/I09/I11/I18. Quitar poteto, permitir escritura al reviewer o
deshabilitar una herramienta necesaria del hijo debe impedir esa admisión. Perfil
Meli pasa su tarea y rechaza una ajena; skill irrelevante no entra; memoria sobrevive.
Entregar un digest sin conducta observable no completa este bloque.

## SUA-04 — Modelos y agentes que se actualizan

**Dueño:** política de flota local; G distribuye manifiestos. **Archivos:** ampliar
registro/selector y el scheduler anfitrión; nuevo manifiesto versionado de catálogo,
perfiles y generaciones. No crear daemon ni store de tareas nuevo.

1. Consultar fuentes oficiales y acceso por cuenta. Mantener sucesión, estabilidad,
   capacidades y causa de inelegibilidad, independientes de nombres comerciales.
2. Probar un sucesor y promoverlo automáticamente dentro de plantilla/autorización.
   Mantener el intento activo; un relevo hereda raíz, gasto y restricciones.
3. Descubrir altas y retiros; validar perfil y conexiones ida/vuelta; publicar nuevos
   destinos mediante manifiesto autorizado, no una allowlist abierta de carpetas.
   <!-- corr: K6 -->
   Las rutas certificadas parten de `coverage.json` de G. Antes de usarlo como
   fuente se alinea consigo mismo: hoy dice `status: inventory-only` y `mac-local`
   `sandbox-tested-uncertified`, y no tiene la ruta `main` → `mac-local/opencode`
   en `managedRequesterRoutes`, aunque `hostAdapterCoverage` la da por
   `certified` (fila T12 `coverage.json` de `followups.md`). Si el loop de
   encargos la alinea antes, se usa su resultado.
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

**Dueño:** G/R y cada repo consumidor. **Archivos:** `corrida_worker/gates.py`,
`scripts/ci-fast-allowlist.txt`, `scripts/run-checks.sh`, `.github/workflows/`,
verificadores de cobertura/corpus, hooks, recetas de repos y reglas administradas.
Nuevos: política de calidad versionada y catálogo de efectos por repo.

<!-- corr: D13 -->
`corrida_worker/gates.py` se va con la ruta de corrida (David, 2026-10-13). Las
reglas `mismo-revisor` y `bloqueante-repetido` desaparecen con él y no hay que
retirarlas aparte. La política de rondas como datos se escribe nueva, no se migra
de ese archivo.

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
   segundo modelo. De `gates.py` se conserva lo que coincide con la regla vigente:
   revisión aprobada del head exacto antes del push, revisor que no es autor y
   cero bloqueantes para merge. Se retiran las piezas que ya no rigen: la rotación
   forzada `mismo-revisor` y el paro `bloqueante-repetido` (`rounds_seen >= 2`),
   junto con su copia en `loop-autopilot.md` §4. El kit puede seguir como
   bootstrap opcional externo.

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
   avance (B16, `ProgressPublisher` en `native_gateway.py`). El LaunchAgent
   `ai.goncloud.corrida-latido` sigue descargado: además de publicar, manda
   mensajes de seguimiento (`T12-runbook.md`). El reloj de SUA vive en el
   scheduler nativo, no en ese latido.
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
   El inventario parte de `coverage.json.modelWakes` (foto del 2026-10-07, ya
   fechada) y de una lectura nueva de `openclaw cron list --json`. Al cierre de
   encargos el único vigía del gateway era `bids-02-vigia`, y `prompt-claw` §7 ya
   no crea `<loop>-vigia` en la ruta de encargos. El cambio de dueño usa el corte
   existente (`cutover_live.py`, `agent-work-cutover.v2`), que dejó
   `loop:canario-encargos` con dueño `native` en la generación 2. No se escribe
   otro mecanismo de corte.
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
   La ruta de corrida y la sesión adoptada de encargos no esperan a este bloque:
   David decidió retirarlas el 2026-10-13 y salen antes, en PR propios.
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
| I08 | Poteto completo llega y funciona en las seis rutas; ausencia impide admitir la ruta. |
| I09 | CLI/modelo/argv, resume y permisos efectivos; OpenCode y sus hijos, reviewer sin escritura. |
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

## Comandos existentes y comandos futuros

Se confirmaron en fuente los siguientes puntos de entrada. Esta lista no afirma
que se hayan ejecutado como parte del diseño ni que acrediten contratos nuevos.

| Repositorio | Comando existente | Uso futuro |
|---|---|---|
| G | `bash scripts/tests/test-worker-registry.sh` | Compatibilidad de registro. |
| G | `bash scripts/tests/test-worker-selector.sh` | Elegibilidad y selección actuales. |
| G | `bash scripts/tests/test-worker-model-binding.sh` | Está en main desde el 2026-10-12, con el rechazo de caracteres de control. <!-- corr: K2 B22 --> |
| G | `bash scripts/tests/test-agent-work-e2e.sh acceptance` | Par de aceptación de encargos. Desde el 2026-10-11, por decisión de David, la CI no lo exige en cada bloque; corre una vez al cierre. <!-- corr: K1 --> |
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
