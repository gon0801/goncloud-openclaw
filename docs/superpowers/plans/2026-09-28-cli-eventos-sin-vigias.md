# Plan de implementación: avisos de CLI sin vigías de agente

> Histórico (2026-10-19): plan no adoptado; la ruta de corrida que usa (`scripts/mac/corrida/`) se retiró el 2026-10-13. No ejecutar sin rehacerlo.

> Para el ejecutor: sigue estas tareas en orden. Este archivo autoriza preparar y probar el cambio cuando David pida ejecutarlo. La solicitud que produjo este plan fue solo de documentación; ninguna tarea se ejecutó al escribirlo.

**Objetivo.** Mientras zcode, Codex, Grok, Claude u otro CLI trabaja sin novedades, la vigilancia de U3 y del loop revisor consume cero tokens. Una entrega, un bloqueo o una terminación inesperada llega a la sesión solicitante de `main` en cuanto los equipos están disponibles.

**Diseño.** La Mac registra cada encargo y guarda sus señales en archivos durables. Una bandeja del gateway recibe cada señal por identidad, programa como máximo una admisión inicial por lote y registra la decisión de `main`. Los CLI usan un informe de entrega común. El observador tmux conserva la detección de permisos y cierres.

**Fuente.** [Contrato y decisiones de arquitectura](../../spec/cli-eventos.v1.md). Si este plan contradice el contrato, corrige el plan en el mismo cambio antes de ejecutar la parte afectada. Para implementación, revisión, PR, merge y despliegue del repo, hereda [loop-autopilot.md](../../runbooks/loop-autopilot.md), secciones 3 a 10. Este plan define solo las diferencias del circuito de avisos.

**Estado inicial medido el 2026-09-28.** Los cron `u3-loop-vigia` y `revisor-loop-vigia` estaban habilitados cada 300000 ms, ambos con `systemEvent` hacia `main`. El observador tmux estaba cargado y tenía cuatro sesiones marcadas. Sus envíos fallaban porque el CLI de la Mac era OpenClaw 2026.9.4 y la base local requería esquema 18. El CLI de Windows era 2026.9.6. El instalador excluía `corrida-latido`, aunque la Mac aún tenía ese LaunchAgent cargado. Repite este inventario al iniciar la ejecución: los hechos pueden cambiar.

## Reglas que gobiernan todas las tareas

- No despiertes agentes ni envíes avisos reales para investigar o desarrollar. Usa dobles de transporte y tmux propio en las pruebas. Reserva los eventos reales para el canary acotado de la tarea 10.
- Conserva la sesión y el encargo de cada CLI activo. No reinicies el gateway ni una terminal por comodidad. Antes de cualquier recarga que pueda interrumpir trabajo, comprueba cron en vuelo y turnos activos según la sección 7 de `loop-autopilot.md`. Si hay trabajo activo o no puedes comprobarlo, deja la captura en modo observación y aplaza esa recarga.
- Ninguna quietud, pantalla repintada, salida cero ni hook Stop demuestra entrega. Solo un informe ligado al identificador del encargo da esa señal. Los avisos de permisos y terminaciones son incidentes distintos y se deduplican.
- La recepción del gateway, el inicio de un turno y la decisión registrada son tres estados diferentes. Un timeout no autoriza reenviar un turno. Tras una admisión incierta, exige una prueba nativa que excluya solicitudes anteriores en vuelo. En ausencia de esa prueba, conserva el lote en `NeedsReconciliation` y emite un aviso operativo sin modelo.
- Registra el destino como agente `main` más la clave real de la sesión que solicitó el encargo. No supongas `agent:main:main`, no abras otra sesión para observar y no hagas broadcast.
- El sobre de eventos añade como máximo 8 KiB por lote y 1 KiB por resumen. Mide aparte el prompt total de `main`; el límite del sobre no prueba bajo consumo del turno.
- Mantén una sola ruta capaz de despertar a `main` por estos dos loops. Los trabajos ajenos conservan su comportamiento. La promesa de cero tokens en reposo corresponde a estos loops, no a toda la cuenta.
- Cada bug corregido en el código del repo lleva una prueba discriminante en el mismo cambio. Corre pruebas focalizadas por tarea. Antes de cada commit corre todos los candados pre-commit, sin `--no-verify`. La unión de los shards de CI corre la batería completa una vez por SHA candidato final. No repitas pruebas sobre el mismo SHA que CI o los candados ya validaron.
- Presupuesto de prueba viva: dos entregas controladas y una incidencia de permiso no aprobada. Si el canary falla, detén nuevos despertares y concilia el lote antes de otro intento. No uses el canary como carga continua.

## Roles, lugares y archivos

| Rol | Trabajo |
|---|---|
| Lead | Coordina el bloque, revisa el diff y conserva el registro de decisiones. Puede ejecutarse en cualquier host que admita el kit |
| Implementador | Trabaja en un worktree aislado de `/Users/dn/dev/goncloud-openclaw`; solo toca los archivos asignados al bloque |
| Revisor | Revisa el conjunto del bloque y los cambios delicados de admisión; no reutiliza la identidad del autor |
| Main | Consume lotes dirigidos a su sesión solicitante y confirma la decisión; no vigila por reloj |
| David | Recibe el resultado y los incidentes que requieran decisión. El trabajo normal no depende de una respuesta suya |

| Lugar | Ruta o mecanismo |
|---|---|
| Repo en Mac | `/Users/dn/dev/goncloud-openclaw`, rama base `origin/main` al crear el worktree |
| Fuentes del plugin nuevo | `cli-events/` dentro del repo; en Windows se instala fuera del archivo de configuración vivo y se registra por ruta de plugin |
| Estado del gateway | Directorio privado fuera de `C:\Users\ehven\.openclaw`, siguiendo el patrón de `tablero-runbook`; se define como `C:\Users\ehven\.openclaw-state\cli-events` |
| Fuente del observador | `scripts/mac/cli_events.py`; copia instalada `~/bin/cli_events.py` |
| Estado del observador | `~/.local/state/cli-events/`, con archivos 0600 y escrituras atómicas |
| Servicio de observación | `ai.goncloud.cli-events`, instalado por `scripts/mac/instalar-mac.sh` |
| CLI del gateway | Host SSH `gwpc`, OpenClaw instalado allí. El script de transporte usa `openclaw gateway call` en ese host |
| Configuración viva | `C:\Users\ehven\.openclaw\openclaw.json`; solo el mecanismo oficial de patch toca ese archivo durante el despliegue |

No agregues secretos, destinos de Telegram ni volcados de terminal al repo. Los archivos de diseño ya creados bajo `/Users/dn/designs/openclaw-eventos-2026-09-28/` son material de revisión; `docs/spec/cli-eventos.v1.md` es la fuente del trabajo una vez versionada.

## Secuencia de trabajo

Cada bloque termina en un estado comprobable. Mantén una sola rama de implementación, `feat/cli-eventos-sin-vigias`, desde el `origin/main` vigente al abrir el worktree. Divide en PRs solo si un bloque puede pasar CI y revisión sin un adaptador a medias; nunca despliegues una versión intermedia que despierte a `main`. Los documentos de este plan y del contrato se incluyen en el primer commit del bloque. Los archivos ajenos que ya estén sin versionar en el checkout compartido no entran al worktree ni al commit.

### Tarea 1. Demostrar la admisión disponible en el gateway

**Archivos.** Crea `docs/evidence/cli-eventos/admission-2026.9.6.md`. Lee las declaraciones y la implementación de OpenClaw instalado en `gwpc`. No cambies código ni configuración.

**Contrato a probar.** `MainAdmission.submit(batch, stableKey, recoveryFence?)` debe guardar identidad, dirigir a la sesión solicitante real, serializar si main está ocupado y permitir conciliar la misma clave tras reiniciar. `lookup(stableKey)` solo puede devolver `NotStarted` reutilizable si excluye atómicamente una solicitud anterior aún en vuelo. Comprueba también si una herramienta registrada por el plugin puede leer la identidad verificable del run y de la sesión actual para reclamar y confirmar el lote. El `dispatchHookAgentTurn` declarado en la versión instalada no cumple por nombre este contrato: se declara como turno aislado y contenido externo `email`.

1. Documenta la firma instalada de cada posible API nativa, sus permisos, su persistencia y su ruta de ejecución. Anota ruta y línea de cada evidencia, sin imprimir valores secretos.
2. Ejecuta pruebas aisladas con gateway y sesión de ensayo, sin la configuración viva: admisión repetida con una clave, caída antes de guardar `runId`, reinicio con pendiente y sesión ocupada. Comprueba el contador real de peticiones al proveedor con un proveedor falso.
3. Escribe en la evidencia `NATIVA` si todas las garantías pasan, o `ADAPTADOR` si alguna falta. En modo `ADAPTADOR`, la integración propuesta debe persistir la intención antes de llamar al runtime y dejar las admisiones inciertas en `NeedsReconciliation`; nunca promete reintento automático de ese caso. Explica qué API permitida programa un pendiente al salir de ocupado.

**Salida exigida.** Una tabla `garantía | mecanismo | prueba | resultado` con siete casos: destino, deduplicación, carrera `NotStarted`, ocupado, reinicio, consulta sin modelo e identidad verificable de la herramienta de main. Si ninguna API puede dirigir a la sesión solicitante real, o main no puede reclamar y confirmar el lote con identidad verificable, marca `NO_APTO`. En `NO_APTO`, conserva los vigías activos y detén el plan antes de la tarea 3; no sustituyas la sesión por un hook aislado.

**Rama `NO_APTO`.** Abre un bloque propio para ampliar el runtime de OpenClaw o conseguir una versión que exponga la admisión a la sesión real, una clave estable conciliable, señal de sesión libre e identidad verificable para las herramientas del run. Documenta los archivos y la versión exactos tras inspeccionarlos; no inventes una ruta de SDK. En el bloque, crea pruebas que reproduzcan los siete casos de la tabla con proveedor falso, incluye la corrección del runtime y sus pruebas en el mismo cambio, y publica un artefacto instalable identificable por SHA. Despliega esa versión solo tras pasar su CI y comprobar que no interrumpe trabajo activo. Repite entonces la tarea 1 contra la versión instalada. Hasta obtener `NATIVA` o `ADAPTADOR` apto, no ejecutes las tareas 3 ni 9 a 11; el estado del proyecto es **bloqueado por capacidad del runtime**, con evidencia concreta.

### Tarea 2. Definir eventos y transiciones sin red

**Archivos.** Crea `cli-events/contract.ts`, `cli-events/ledger.ts`, `cli-events/contract.test.ts`, `cli-events/ledger.test.ts`, `cli-events/package.json` y `cli-events/openclaw.plugin.json`.

**Interfaz.** `parseDispatch(input: unknown): Dispatch`; `parseEvent(input: unknown): Event`; `recordEvent(event: Event): Receipt`; `reserveBatch(target: MainTarget): Batch | null`; `transition(batchId, observedRunState): BatchState`; `resolve(batchId, runIdentity, decision): HandlingReceipt`. Usa variantes cerradas para `WorkerDelivery`, `ReviewDelivery`, `Blocked`, `PermissionRequired`, `UnexpectedTermination` y `DeadlineMissed`. La capa de persistencia es la única escritora del ledger del gateway.

1. Escribe pruebas rojas para ID repetido con el mismo y con distinto digest; generaciones antiguas; token inválido; informe parcial; dos eventos simultáneos; lote inmutable; recibo posterior al reinicio; cuerpo de más de 8 KiB; resumen de más de 1 KiB; `resolve` desde otro run. Comprueba que una prueba falla si la función devuelve siempre `undefined` o acepta todo.
2. Implementa parser y transiciones hasta pasar `node --test cli-events/contract.test.ts cli-events/ledger.test.ts`. Mantén los cuerpos de texto fuera de la clave semántica cuando proceden de un spinner o reloj.
3. Prueba caídas antes y después de la escritura duradera. Un recibo solo sale después de persistir; la lectura tras reinicio devuelve el mismo ID.

**Salida exigida.** Cero llamadas a runtime o proveedor en estas pruebas. Cada estado de la especificación tiene una transición explícita; un estado `Unknown` no se traduce a `NotStarted`.

### Tarea 3. Integrar una única admisión con main

**Archivos.** Crea `cli-events/admission.ts`, `cli-events/index.ts`, `cli-events/admission.test.ts` y `cli-events/index.test.ts`. Declara el plugin con el mismo patrón de registro y configuración que `tablero-runbook`, sin agregar sus métodos al plugin del tablero.

**Interfaz.** `ingest(input: unknown, caller): Receipt`; `getStatus(ids, caller): StatusSnapshot`; `claim(batchId, runIdentity): AssignedBatch`; `ack(batchId, decision, runIdentity): HandlingReceipt`; `pumpPending(): void`. Exporta los métodos RPC `cli.events.ingest` y `cli.events.status` para el transporte y la operación. Registra herramientas de agente `cli_events_claim` y `cli_events_ack` para main; ambas llaman a la misma lógica del ledger. La identidad del run y de la sesión procede del contexto verificado por el gateway, nunca de argumentos redactados por el modelo. La herramienta solo ve lotes asignados al run actual. Si el SDK instalado no ofrece esa identidad, detén la tarea y vuelve a `NO_APTO` o amplía el runtime como cambio explícito. La autenticación y la asociación del `agentId` y `sessionKey` se validan en la frontera. `pumpPending` usa la admisión demostrada en la tarea 1, no invoca un modelo para consultar cola.

1. Escribe pruebas que envíen el mismo evento 100 veces, pierdan la respuesta RPC y consulten su recibo. Espera una sola admisión inicial. Inyecta una solicitud antigua todavía en vuelo cuando `lookup` devuelve un dato desactualizado; exige que no existan dos admisiones.
2. Simula main ocupado, caída del proceso, reinicio y `agent_end` sin `ack`. El lote queda pendiente o en conciliación hasta recibir evidencia suficiente. Al liberar la sesión, el runtime recibe el lote en la misma clave sin crear otra sesión ni otro vigía.
3. Implementa el adaptador `NATIVA` o `ADAPTADOR` registrado en la tarea 1. `ADAPTADOR` conserva `Submitting` antes de solicitar un turno y aparca el caso incierto. No cambies las garantías del contrato para acomodar la API disponible.
4. Ejecuta `node --test cli-events/*.test.ts`. Verifica que `pumpPending` con la bandeja vacía no solicita ningún turno ni ejecuta herramienta de agente.

**Salida exigida.** La prueba de ocupado y la de reinicio terminan con `claim` y `ack` del run correcto mediante las herramientas registradas. Un run de otra sesión y un argumento que suplante la identidad son rechazados. El caso ambiguo sin prueba atómica termina en `NeedsReconciliation`, visible por `cli.events.status`.

### Tarea 4. Guardar observaciones en la Mac

**Archivos.** Crea `scripts/mac/cli_events.py`, `scripts/tests/test_cli_events.py` y `scripts/tests/test-cli-events.sh`. La prueba shell llama `python3 -m unittest discover -s scripts/tests -p 'test_cli_events.py'` para entrar en el inventario de `scripts/run-checks.sh`.

**Interfaz.** El ejecutable ofrece `assign`, `report`, `observe --once`, `serve`, `status --json` y `flush --once`. `assign` devuelve un token y una ruta de resultado; `report` acepta un token y un archivo ya completo. `observe` concilia cambios de resultados, no abre ninguna sesión. `flush` transporta solo eventos pendientes. La librería usa un directorio por productor y un único consumidor, con archivo temporal más renombrado atómico.

1. Prueba archivo a medio escribir, `LISTO` viejo, `LISTO` del encargo vigente, nombre de tmux reutilizado, Stop duplicado, sesión cerrada, reinicio de Mac, ordenador dormido y dos productores simultáneos.
2. Prueba 72 horas simuladas con archivos y pantallas sin cambio: cero intentos de transporte. El vencimiento de un plazo crea una sola incidencia; la quietud sola no la crea.
3. Implementa la captura. `serve` revisa resultados a un intervalo máximo de cinco segundos cuando la Mac está despierta. Un fallo de transporte conserva los archivos y repite solo el ingreso con la misma identidad; no solicita directamente un turno.
4. Ejecuta `bash scripts/tests/test-cli-events.sh`. Comprueba permisos 0600 de estados y rechaza rutas de evidencia fuera del encargo autorizado.

**Salida exigida.** El CLI ficticio sin hooks entrega por informe igual que uno conocido. Ningún modelo aparece como condición de identidad.

### Tarea 5. Conectar tmux, Stop y corridas sin duplicar avisos

**Archivos.** Modifica `scripts/mac/tmux-activity-watch.sh`, `scripts/mac/claude-stop-openclaw-event.sh`, `scripts/mac/corrida/lanzar-sesion.sh`, `scripts/mac/corrida/latido.sh`, `scripts/tests/test-tmux-activity-watch.sh`, `scripts/tests/test-corrida-latido.sh` y `scripts/tests/test-corrida-nucleo.sh`.

1. Agrega pruebas rojas: Stop seguido de informe produce una entrega; pantalla quieta o repintada produce cero avisos a main; permiso reconocible produce una incidencia; cierre de sesión sin informe produce terminación inesperada; una corrida abierta usa el mismo ingreso durable.
2. Ajusta el observador y el hook para publicar hechos locales solo cuando el encargo esté registrado. Conserva la comprobación de marca `OPENCLAW_WATCH=1` y la comprobación de desaparición real del diálogo antes de considerarlo contestado. No añadas una segunda ruta de `system event`.
3. Registra el token y la instancia de terminal antes del primer `send-keys` de `corrida/lanzar-sesion.sh`. El latido conserva sus avisos deterministas a David y envía a la bandeja solo las acciones del mismo encargo. Su copia instalada en Mac se inventaría por separado porque el instalador actual excluye ese componente.
4. Ejecuta `bash scripts/tests/test-tmux-activity-watch.sh`, `bash scripts/tests/test-corrida-latido.sh` y `bash scripts/tests/test-corrida-nucleo.sh` como pruebas focalizadas.

**Salida exigida.** El observador y el hook no pueden llamar directamente a `openclaw system event` para los loops gestionados. Los CLI sin encargo registrado conservan la política previa hasta el corte, para no perder trabajo ajeno.

### Tarea 6. Registrar entregas de U3 y del loop revisor

**Archivos.** Modifica `~/.local/state/u3-loop/PROMPT.md` y `~/.local/state/revisor-loop/PROMPT.md` solo en el corte de la tarea 10. En el repo, agrega la plantilla versionada `docs/spec/cli-eventos-encargo.v1.md` y prueba su contrato con `scripts/tests/test-cli-event-contract.sh`.

1. Define un único bloque de encargo portable: token de generación, ruta de resultado, formato de entrega y comportamiento de `ATORADO`. Escribe pruebas de la plantilla con casos de zcode, Codex, Grok, Claude, OpenCode, Kimi, Muse, Qwen y un CLI ficticio. La prueba valida el informe escrito, no solo el texto de la pantalla.
2. Mantén un estado actual acotado por loop en `~/.local/state/<loop>/actual.json`. Define cómo `assign` actualiza revisión y siguiente paso. Guarda `estado.md` como historia consultable; no lo abras completo por cada evento.
3. Prepara una adopción de los cuatro encargos activos: identifica encargo, terminal, revisión y último resultado consumido. Cada dato dudoso queda `unknown` y bloquea la admisión de ese encargo hasta conciliarlo. La adopción no relanza zcode ni Claude. Registra por encargo quién sigue siendo dueño del aviso; ningún cron global se deshabilita mientras dependa de él un encargo activo sin identidad conciliada, salvo que se establezca antes una ruta única de aviso para ese encargo y se pruebe su recepción.
4. En las plantillas elimina la orden de recrear los cron de vigía. Indica a main que use `cli_events_claim` para recibir el lote del run actual y `cli_events_ack` tras registrar su decisión; una mera lectura no confirma atención. Cambia las instrucciones activas solo al cortar a la nueva ruta. Ejecuta `bash scripts/tests/test-cli-event-contract.sh` y la prueba focalizada de adopción de la tarea 4.

**Salida exigida.** Un evento lleva a main el encargo actual y una referencia de evidencia, no una orden de leer los 168 KB o los 105 KB de historial. El informe antiguo de otra generación no avanza la tarea nueva.

### Tarea 7. Instalar el observador y mantener un estado visible

**Archivos.** Crea `scripts/mac/ai.goncloud.cli-events.plist`. Modifica `scripts/mac/instalar-mac.sh`, `scripts/tests/test-instalar-mac.sh` y la documentación de operación `docs/runbooks/cli-eventos.md`.

1. Prueba `instalar-mac.sh --dry-run` y `--verificar` con un HOME falso. La instalación incluye el observador nuevo, conserva respaldo `.anterior`, revisa bytes y crea su LaunchAgent con el UID y HOME correctos.
2. Implementa un transporte SSH con argumento codificado y script remoto fijo. No interpolas pantalla, ruta libre ni secreto en la línea del shell. Usa el CLI de Windows compatible con el estado del gateway; comprueba versión y resultado del RPC antes de marcar recibo.
3. Agrega `status --json` que distinga `Pending`, `Running`, `Handled`, `NeedsReconciliation`, gateway inaccesible y main ocupado. Un caso sin avance durante dos minutos deja un estado operativo visible; un canal a David utiliza el destino ya configurado, sin guardarlo en el repo ni llamar a un modelo.
4. Ejecuta `bash scripts/tests/test-instalar-mac.sh`, `bash scripts/tests/test-cli-events.sh` y una prueba de transporte con SSH falso. Un error de esquema local no puede borrar un evento.

**Salida exigida.** Repetir la instalación converge al mismo resultado. El verificador detecta una copia instalada antigua o un servicio adicional que aún pueda despertar a main.

### Tarea 8. Cerrar el bloque de código y revisar el SHA final

**Archivos.** Solo los anteriores y `docs/evidence/cli-eventos/` para pruebas reproducibles. No incluyas historiales ni credenciales.

1. Agrupa hallazgos de revisión en una sola ronda. Un bloqueante necesita comando reproducible. Corrige los bloqueantes y revisa después solo el diff de esos arreglos; aplica las reglas de quality-kit del `AGENTS.md` de este repo. Considera revisión cruzada con `/Users/dn/quality-kit/cross-review.ps1` porque el cambio controla despertares y cuotas.
2. Corre los candados pre-commit antes del commit final. Crea el PR desde el SHA revisado, deja correr los tres shards de `scripts/run-checks.sh` en CI y verifica que su unión es la batería completa. El trabajo del repo no se considera completo con solo pruebas focalizadas.
3. Comprueba que ningún script de producción del circuito gestionado puede invocar todavía por sí mismo un turno periódico de main. El inventario incluye cron, hook Stop, observador tmux, latido instalado, instrucciones de ambos loops y heartbeats relacionados. Usa búsqueda de fuentes más inspección de la instalación real.

**Salida exigida.** PR y CI verdes sobre el mismo SHA que se instala, con evidencia de los casos de caída y de cero llamadas al proveedor sin novedades. Si se cambia el SHA, CI valida el nuevo SHA una vez; no reutilices un resultado de otro commit.

### Tarea 9. Preparar captura en producción sin despertar a main

**Lugar.** Mac y gateway Windows. Esta es la primera tarea que instala o modifica servicios. Las tareas anteriores no cambian producción.

1. Comprueba que el código instalado coincide con el SHA aprobado. Registra el inventario de los dos cron exactos, heartbeats, scripts instalados, cuatro sesiones marcadas, encargos activos, LaunchAgents y último evento recibido por main. Guarda las configuraciones previas en un respaldo fuera del repo y sin exponer claves. Anota para cada encargo activo su generación y el propietario actual del aviso; si falta un dato, no declares listo ese loop para el corte.
2. Verifica trabajo en vuelo antes de cualquier cambio del gateway. Si una recarga puede abortarlo, instala solo la captura de Mac y pospone la activación del plugin hasta una ventana sin trabajo. No uses `gateway restart` como paso implícito ni repitas la orden si se queda pendiente.
3. Instala copias del SHA aprobado de `cli_events.py`, `tmux-activity-watch.sh`, `claude-stop-openclaw-event.sh` y los componentes de `corrida` que sigan activos. Comprueba bytes, rutas invocadas por los LaunchAgents y hook, y versiones mediante lectura de vuelta. Activa `cli_events.py serve` en modo `capture-only`. Adopta las generaciones activas y compara resultados históricos con el estado registrado por main. Las dudas quedan pendientes, no se convierten en entregas nuevas. Durante esta etapa, las copias instaladas capturan hechos pero conservan el propietario anterior de cada aviso hasta el corte; no envían avisos duplicados.
4. Instala el plugin del gateway por la ruta nueva y registra su configuración mediante el mecanismo oficial que se haya comprobado en la tarea 1 y escrito en `docs/evidence/cli-eventos/deploy-commands.md`. Ensaya el comando exacto, aplícalo y lee de vuelta la configuración. El cambio contiene rutas y flags, nunca claves API. Si el mecanismo oficial no termina, detén el despliegue y conserva el sistema anterior; no edites `openclaw.json` a mano.
5. Comprueba que `cli.events.status` funciona sin inferencia y que la captura contiene los hechos observados. El gateway conserva `enabled=false` para admisión durante esta etapa.

**Salida exigida.** Cada evento nuevo tiene identidad durable y solo la ruta antigua puede todavía despertar a main. Los CLI activos siguen en la misma sesión y el mismo proceso.

### Tarea 10. Cambiar el dueño del despertar y probarlo una vez

**Condición de entrada.** Tarea 9 en verde, ingreso durable comprobado y MainAdmission apto. Todos los encargos activos de cada loop que se vaya a cortar tienen identidad conciliada y dueño de aviso registrado; los demás conservan su único dueño anterior y ese loop no se corta aún. Si hay una admisión antigua incierta para el mismo encargo, concíliala antes de cortar.

1. Registra un punto de corte por loop. Para cada loop que cumpla la condición de entrada, deshabilita su cron por el ID leído en el inventario y comprueba estado por nombre e ID. Corta los envíos directos de observador, Stop y cualquier heartbeat de ese loop. Inspecciona el LaunchAgent `corrida-latido` instalado, que el instalador actual no reemplaza: si aún envía eventos directos, migra primero su aviso determinista al transporte nuevo y luego descarga la copia antigua; comprueba que no queda cargada. No cortes los avisos operativos a David. Actualiza las instrucciones activas para que no recreen los vigías. Confirma con inspección de las copias instaladas que ninguna ruta real del loop cortado puede despertar a main fuera de la bandeja antes de habilitar su admisión.
2. Vuelve a conciliar los eventos capturados mientras cambiaba el dueño. Solo la bandeja del gateway queda habilitada para admitir lotes. Si se detecta otra ruta de despertar, deja admisión deshabilitada y conserva la captura durable hasta corregirla.
3. Ejecuta un canary con un `LISTO` de zcode o CLI ficticio controlado y un veredicto de Claude ligado a otro encargo. Comprueba detección, recibo, run en la sesión real de main, decisión y `ack`. Repetir el mismo informe no crea otro run. Ejecuta una pregunta de permiso de prueba sin aprobarla y verifica una única incidencia.
4. Observa 30 minutos sin novedades mientras las sesiones siguen vivas. Usa contadores de invocaciones del gateway y del proveedor filtrados por estos loops. Espera cero turnos de vigilancia. Comprueba que un informe nuevo llega en hasta cinco segundos a la Mac y, con ambos equipos despiertos y red sana, en hasta cinco segundos adicionales al gateway.
5. Guarda en `docs/evidence/cli-eventos/canary.md` los tiempos, IDs recortados, SHA instalado, pruebas, estado de cada lote y contadores. No incluyas secretos ni texto completo de terminal.

**Salida exigida.** Dos entregas y una incidencia tratadas sin vigías por reloj, cero despertares cuando no pasa nada y cero duplicados tras repetir un informe. La latencia de razonamiento de main se informa aparte. No declares el cambio completo si el `ack` o la medición de consumo faltan.

### Tarea 11. Cerrar, recuperar o detener de forma visible

| Situación observada | Acción determinista |
|---|---|
| La Mac o Windows no entrega recibo | Conserva el evento y reintenta solo el ingreso con el mismo ID. Marca transporte caído antes de dos minutos |
| El gateway recibió el evento, pero no hay run atribuible | Consulta por la clave estable. Usa `NotStarted` solo con garantía atómica; de otro modo deja `NeedsReconciliation` y alerta sin modelo |
| Main está ocupado | Mantén el lote en cola nativa. Consulta estado sin modelo y no abras otra sesión |
| Main terminó sin `ack` | Conserva el lote; busca decisión o efectos por identidad antes de ofrecer recuperación. Nunca repitas un merge o despliegue por timeout |
| Un CLI no escribió informe | Conserva la tarea activa hasta su plazo. Al vencer, emite una sola incidencia, sin inventar `LISTO` |
| Se detecta cron, hook o latido que despierta fuera de la bandeja | Deshabilita la admisión nueva, conserva la captura y repara esa ruta antes de reanudar |
| La recarga del gateway encuentra un turno activo o no puede comprobarlo | Posponla. Los eventos siguen en captura; no reinicies procesos activos |
| El canary no llega a la sesión real o duplica una llamada | Detén la admisión nueva, conserva los eventos, restaura la única ruta de avisos previamente comprobada y documenta los pendientes; no reactives automáticamente los cron de cinco minutos |
| La recuperación tampoco tiene un transporte de aviso válido | Mantén todos los pendientes y publica `status --json` con error. Detén el corte y reporta el impedimento; no borres trabajos ni declares éxito |

Tras un canary verde, deja el observador activo, los dos cron deshabilitados y el estado de cada loop en su archivo actual acotado. Haz una comprobación posterior en un único momento acordado con el tiempo de trabajo, sin repetir canarys pagados sobre el mismo SHA. Un PR de cierre registra el SHA, la evidencia y cualquier residual no bloqueante en el tracker; conserva los bloqueantes abiertos fuera del merge. Retira respaldos solo cuando ya no hagan falta para reconciliar generaciones pendientes.

## Clases de comando

| Clase | Uso en este plan | Comprobación antes del primer uso |
|---|---|---|
| `ssh` | Consultas de solo lectura e ingreso autenticado a `gwpc` | `ssh -o BatchMode=yes gwpc 'openclaw --version'` devuelve versión; si falla, la etapa viva no empieza |
| `red externa` | PR y CI del repo | La autenticación y el origen se verifican con `gh auth status` y `git remote -v`, sin imprimir secretos |
| `gh` | Abrir PR y leer checks | `gh auth status` sale 0; si no, guarda el diff y pospone publicación sin alterar producción |

Los comandos de instalación, configuración y cron se extraen de las versiones comprobadas de OpenClaw durante las tareas 1 y 9, se guardan verbatim con su salida esperada en `docs/evidence/cli-eventos/deploy-commands.md` antes de ejecutarlos, y se validan en modo de ensayo. Una versión nueva que cambie esas opciones obliga a actualizar ese archivo y repetir la prueba aislada de capacidad. No copies comandos de esta guía que no existan aún como interfaz instalada.

## Comprobación de cobertura del plan

| Promesa del contrato | Tareas que la prueban |
|---|---|
| Cero inferencia sin novedades | 4, 5, 8 y 10 |
| Cualquier CLI mediante informe común | 4, 6 y 10 |
| Destino real de main y ocupado | 1, 3 y 10 |
| Recibo durable, duplicados y caídas | 2, 3, 4 y 10 |
| Estado actual pequeño | 6 y 10 |
| Permisos sin autoaprobación | 5, 6 y 10 |
| Sin rutas viejas de despertar | 5, 7, 8 y 10 |
| Captura y corte sin perder trabajos activos | 6, 9, 10 y 11 |

La prueba de aceptación humana es concreta: un trabajador termina y main se entera sin que David lo pregunte; durante una espera sin novedades, ningún vigía de estos loops consume cuota. Si falta una de esas dos evidencias, el cierre permanece pendiente.
