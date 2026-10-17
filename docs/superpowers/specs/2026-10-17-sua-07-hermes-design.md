# SUA-07, Hermes independiente: diseño y corte en rebanadas

Fecha: 2026-10-17. Bloque SUA-07 del
[plan](../plans/2026-10-05-sistema-agentes-unificado.md) (sección "SUA-07 — Hermes
independiente"), que verifica I01–I14, I16, I18 e I20 contra H. Contrato:
[sistema-agentes.v1](../../spec/sistema-agentes.v1.md). H es Hermes en la PC "Gon"; su
configuración versionada es `gon0801/goncloud-hermes` (rama `feat/hermes-team`).

Fuentes medidas el 2026-10-16, fuera del repo, en `~/.local/state/sua-loop/mediciones/sua07/`:
`inventario-pc-2026-10-16.md` (paso 1, solo lectura en la PC) y
`capa-durable-vs-contrato.md` (lectura de goncloud-hermes en `a8722f1`). Este diseño
cita sus resultados. Las citas de código se re-verificaron en `origin/feat/hermes-team` `4e4112e`.

## 1. Lo que hay hoy (paso 1 del bloque)

| Pregunta del paso 1 | H hoy |
|---|---|
| Instalación | Hermes Agent `0.21.5+5822.g266f11c` (upstream `e4635a16`), instalado por git en `%LOCALAPPDATA%\hermes\hermes-agent`, venv con Python 3.11.16. Se actualiza solo: el repo todavía documenta 0.21.2 (`team.json`, `README.md:40`). |
| Plataforma | Windows 11 Pro 22631. WSL2 Ubuntu (ahí vive el CLI de Muse), detenida al medir. |
| Entradas | Telegram (`claw:telegram`, un solo usuario en `home_channel`), el gateway `hermes_cli.main gateway run` en `127.0.0.1:51155`, el CLI `hermes.cmd`, y el dashboard en `0.0.0.0:9119`. |
| Store | `kanban.db` (tareas, dependencias, corridas, eventos, más la tabla propia `goncloud_local_workflows`), `state.db` del upstream y `subscription-router.db` del router de suscripciones. |
| Scheduler | Tarea de Windows `\Hermes_Gateway` (al iniciar sesión), el cron propio de Hermes (`cron\`, ticker vivo) y el despachador kanban dentro del gateway (`max_in_progress` 3, uno por perfil). |
| Identidad y autoridad | Un solo dueño en Telegram. `PERMISOS.md` de claw (matriz v2): efecto externo = Preguntar, pagos = Preguntar fijo. |
| Procesos y transporte | El gateway (PID estable desde el arranque) lanza un hijo CLI por tarjeta. Salen Telegram y ssh a gonserver. |
| Trabajo durable | Una cadena fija de 7 etapas sobre el kanban (`WorkflowService`, `LocalOrchestrator`, plugin `goncloud-team`). |

Contra el contrato (tabla completa en `capa-durable-vs-contrato.md`):

- **No hay** raíz con plan variable ni criterios, autoridad con `efecto_admisible`, control con época y recibo, `committedEffects`, `excepcion.v1`, `proyeccion.v1`, poteto, ni la política `quality-kit.regla4`.
- **Hay algo parecido:** la tarea raíz con `idempotency_key`, las etapas como unidades, los *leases* del router como claim, el sobre JSON de resultado y el `status` redactado.
- **Choca:** la cadena actual corta en 2 rondas de revisión (`workflow.py:887,961-992`, `shared/CONTRACT.md:25`). Además, sus campos `request_key` e `idempotency_key` son nombres que el contrato prohíbe.
- **Ninguna prueba de H** usa los fixtures de G, y las que importan `hermes_cli` solo corren en la PC.

## 2. Lo que no cambia

- La cadena `GONCLOUD_ENGINEERING_V1` sigue igual, con sus 2 rondas, hasta que SUA-09H decida su transición. Las raíces nuevas conviven con ella y no la reescriben.
- H no comparte con OpenClaw credenciales, sesiones, cola ni RPC (plan, paso 3). Nada de SUA-07 llama al gateway de la Mini ni necesita `openclaw` en el PATH.
- El dashboard en `0.0.0.0:9119` queda fuera del bloque, como fila (sección 7).

## 3. El diseño elegido

### 3.1 Dónde vive

El código nuevo va en un paquete `plugins/goncloud-team/raices/` de goncloud-hermes, en dos capas:

- **Núcleo:** solo biblioteca estándar y Python 3.11. Trae el validador, `decidir`, el store y la proyección. Corre en la Mac y en la CI de H, sin `hermes_cli`.
- **Adaptador kanban:** `raices/kanban.py`, la única pieza que importa `hermes_cli.kanban_db`. Sus pruebas reales corren en la PC. En la Mac usa un doble con la misma interfaz.

Así, la mayor parte de los ensayos corre en la Mac. La PC solo certifica el adaptador.

### 3.2 Lo compartido con G: copia fijada

Lo de G se copia a `shared/sistema-agentes/g/` de H, en espejo de sus rutas en G: `scripts/sistema_agentes/contrato.py`, `scripts/sistema_agentes/derivar.py`, los fixtures de `scripts/tests/fixtures/sistema-agentes/` (con `manifiesto-ensayos.json`) y `docs/evidence/agent-work/politica-calidad.json`. Junto va un `pin.json` con el commit de G y el `sha256` de cada archivo.

Hay dos razones para copiar en espejo:

- `contrato.py` busca `politica-calidad.json` por su ruta relativa en G (`contrato.py:657`), así que se copia sin editarlo.
- `derivar` hoy vive en `scripts/agent-work/proyeccion.py`, que importa `fcntl`, y `fcntl` no existe en Windows. Por eso H0 empieza en G: saca `derivar` y sus ayudantes a `scripts/sistema_agentes/derivar.py`, un módulo puro sin `fcntl`, `subprocess` ni `socket`. `proyeccion.py` lo importa y no cambia de conducta. La copia de H solo trae ese módulo puro.

- Una prueba de H recalcula los digests.
- Un job de la CI de H baja esos archivos de G (repo público) en el commit fijado y los compara byte a byte.
- Actualizar la copia es un PR que cambia el pin y los archivos juntos.

No es un submódulo ni una dependencia en vivo: H instala y opera con G inaccesible (plan: "romper su acceso no altera Hermes").

### 3.3 Store y frontera transaccional

H lleva una base propia, `%HERMES_HOME%\sistema-agentes.db`, aparte de `kanban.db` (que es del upstream y se actualiza solo). Sus tablas siguen el modelo de R, no su código:

- raíces y revisiones de plan;
- unidades con su *binding* `rootId/planRevision/unitId/attempt`;
- intentos, controles con su recibo por `commandId`, efectos, excepciones y evidencia.

Cada mutación es una transacción `BEGIN IMMEDIATE`. Un reintento exacto de un control devuelve el recibo original con `replayed: true`, y uno distinto da conflicto.

Entre `sistema-agentes.db` y `kanban.db` no hay transacción común. La frontera la cierra una bandeja de salida (*outbox*):

1. Decidir una unidad escribe, en la misma transacción, la intención "lanzar `unitId` intento `n`".
2. El adaptador busca la tarjeta por `idempotency_key = sa:<rootId>:<unitId>:<n>` y, si no existe, la crea, todo dentro de un solo `write_txn` de `kanban.db`. Es el patrón que ya usan `start` y `start_contract` (`workflow.py:340-372`, `:396-405`). No se da por hecho que `create_task` deduplique solo: H2 mide si lo hace en 0.21.5.
3. Recién entonces el adaptador marca la intención como cumplida.

Una caída entre los pasos 1 y 3 termina en reintentar con la misma clave: exactamente una tarjeta por intento (I03, I04). `idempotency_key` es la API nativa del kanban, no un campo del contrato, así que la regla de nombres no aplica ahí.

### 3.4 El controlador

`raices/decidir.py` es una función pura, `decidir(vista) -> necesidades`, con la misma semántica que `managed-root.decide.ts` de R:

- **Necesidades:** `first`, `correction`, `relay` y `verify` (un criterio sin claim pide su verificación, con su `criterionId` y su intento, como `managed-root.decide.ts:100,512-519`), con `findingsRef` y `findingsRefs`.
- **Política:** las rondas salen de `politica-calidad.json`. Las rondas 1 a 5 son de corrección con el mismo implementador. La ronda 6 es el relevo, que abre las 5 del implementador nuevo (rondas 6 a 10). Si a la ronda 10 la unidad no converge, se levanta `NECESITA_DAVID`. Así lo fija R (`managed-root.decide.test.ts`, el bucle de rondas 0 a 10 de SUA-05 H1R): el relevo sí consume una ronda, y en total son 10, no 11. El contador va por linaje y no se reinicia con hallazgos nuevos (I12).
- **Revisor y segundo modelo:** el revisor de una unidad excluye a todos sus autores efectivos (`revisorExcluyeAutores`), y ningún paso pide revisión a un segundo modelo (`segundoModelo: false`). En H esto es vivo: las etapas corren por el router de suscripciones, que puede dar el reviewer en otra posición u otro modelo. `decidir` fija el revisor por perfil y el router no puede sumar una segunda revisión. Un relevo cambia de implementador, nunca agrega revisores.
- **Cambio de política:** la política vigente es la copia fijada de `politica-calidad.json`, con la decisión fechada de David que la sostiene. H no tiene otra forma de cambiarla que un PR que mueve el pin. Una raíz conserva la versión de política con la que abrió (`meta.qualityPolicy.version`).
- **Aceptación:** una unidad se acepta solo con un claim `passed` por cada criterio, del head y el entorno vigentes (I13).
- **Autoridad:** la autoridad embebida en `meta` se intersecta con los permisos de H en tres puntos: al arrancar, al reanudar y antes de cada efecto (contrato, "Autoridad"). Los permisos de H son la matriz de `PERMISOS.md` de claw, los toolsets del perfil que corre la unidad y la allowlist de comandos del config. Un efecto procede solo si `efecto_admisible` lo admite **y** H también lo permite. Si la autoridad lo admite pero H lo niega, el efecto no corre y se levanta una excepción con la razón de H. Un prompt no amplía ninguna de las dos (I07). Se prueba con `autoridad/efectos.json` y con un caso de cada punto en el que la autoridad admite y H niega.

El trabajo lo corre un cron de H con `--script` y `--no-agent`, como `respaldo-diario-hermes` (`README.md:73`), cada minuto si el ticker lo admite (se mide en H2). En cada vuelta concilia las tarjetas con sus intentos, decide y despacha. El gateway no gana código nuevo en su proceso.

### 3.5 Entradas, control y excepciones

El plugin `goncloud-team` gana `goncloud_root_submit`, `goncloud_root_read`, `goncloud_root_control` y `goncloud_root_resolve`, solo para claw y con los nombres de campo del contrato.

- **Control:** sigue `control.v1`. `cancel` es terminal. `pause` deja seguir los efectos que ya tenían permiso de inicio y los enumera en `committedEffects` (I05, I06).
- **Excepciones:** salen como `excepcion.v1` por el canal de Telegram de claw (el de `home_channel`). La respuesta del dueño entra por `goncloud_root_resolve`. El reaviso sigue `renoticeAfterMs`.

### 3.6 Proyección, flota y poteto

- **Proyección:** `goncloud_root_read` devuelve un snapshot con la forma de `managedTasks.root.read` de R. La proyección sale de la copia fijada de `derivar` de G (`sistema_agentes/derivar.py`), así que H y el panel cuentan el porcentaje igual (I14). Los documentos `proyeccion.v1` se escriben en `%HERMES_HOME%\raices\proyecciones`. Subirlos al panel de la Mini es de SUA-09H (fila).
- **Flota:** cada intento lleva `flota.v1` con el perfil de H como `specialist`, `host: "gon-pc"`, el modelo exacto o `null`, y la generación de configuración (`goncloud-managed.json`, `source_revision`).
- **Poteto:** `configure_team.py` copia el contexto canónico de poteto (fijado con su digest) al SOUL de los perfiles de equipo. La atestación de flota cita ese digest (I08). Una sonda por perfil, como las de `probe_route.py`, mide que llegó.
- **Advisor:** si un perfil no emite eventos, la cobertura se declara `unknown`, y su caída no aprueba ni despacha (I18).

### 3.7 Versión y capacidades

La versión de H se acredita como par exacto. `raices/certificadas.json` en el repo lista los pares `(versión, code_sha)` certificados en la PC. Un par entra ahí solo después de pasar en esa PC las pruebas reales del adaptador (H2):

- deduplicación por `idempotency_key`;
- exclusión de `write_txn` con dos escritores;
- `link_tasks`, `complete_task` y `block_task`.

`raices/capacidades.py` lee el par vivo (`hermes --version` y `code_sha` de `gateway_state.json`) y la ruta de raíces abre solo si ese par está certificado. La presencia de las cuatro funciones queda como fallo rápido previo, no como permiso.

Como H se actualiza solo (vigía de las 8:35), tras cada subida la ruta de raíces queda cerrada, con la causa `version-no-certificada`, hasta que `raices/certificar.py` (H4) corra en la PC y un PR agregue el par nuevo. Lo mismo vale para una capacidad que se movió: es una capacidad que falta. La cadena actual sigue intacta en los dos casos (plan: "una capacidad faltante impide aceptar esa ruta"). El repo deja de afirmar 0.21.2 y documenta los pares certificados.

## 4. Cómo se prueba

Cada ensayo del bloque se parte en las cláusulas de su `distingue` del manifiesto. `tests/ensayos-h.json` de H guarda una fila por cláusula, con la prueba que la cubre o `no-aplica` y su razón. La batería recorre `manifiesto-ensayos.json` y ese archivo, y se pone roja si a una cláusula le falta prueba, si una prueba citada no existe o si un `no-aplica` no trae razón. Contar un caso por ensayo no basta.

| Ensayo | Cláusulas | Dónde |
|---|---|---|
| I01 | Pedido natural, plan y fila importada conservan alcance, supuestos y criterios | Mac/CI |
| I02 | Ciclo, ID duplicado, dependencia faltante y criterio faltante se rechazan antes de lanzar | Mac/CI |
| I03 | A+B→C con dos tickers y el ACK perdido: exactamente una C bajo la raíz | Mac (doble) y PC (kanban real en copia de `HERMES_HOME`) |
| I04 | Caída entre commit y admisión, y entre admisión y consumo: recupera tareas y gasto; termina el turno y sigue el plan | Mac y PC |
| I05 | Pausa y cancelación contra un permiso `started`; un envío posterior al ACK que ya estaba comprometido queda en `committedEffects`; el replay del control da el recibo original; un `resume` con época vieja se rechaza; un evento tardío no resucita la unidad | Mac |
| I06 | Un efecto confirmado no se repite; uno incierto conserva su estado y exige conciliación | Mac |
| I07 | Autoridad negativa, revocación, otra sesión, diseño, borrador de mail y SHA futuro restringen efectos (`autoridad/efectos.json`); en los tres puntos (arranque, reanudación y antes del efecto), una autoridad que admite y un permiso de H que niega no ejecutan nada | Mac |
| I08 | Poteto completo llega a cada ruta viva de H (turno de claw, hijo CLI por tarjeta); sin poteto, la ruta no se admite | PC |
| I09 | El modelo efectivo es el pedido (perfil y router contra el modelo que corrió); un intento nuevo conserva su snapshot; permisos efectivos medidos (toolsets del hijo); el reviewer no escribe en la fuente. `no-aplica`: "opencode dentro del grupo del slot" (H no usa opencode ni grupos de macOS; el aislamiento equivalente es el cupo por perfil, I20) | PC |
| I10 | Un par certificado nuevo entra solo por `certificar.py` más PR; uno sin certificar cierra la ruta; un intento abierto conserva su snapshot tras la subida | PC |
| I11 | Un perfil nuevo da ida y vuelta; uno incompleto se ve; su competencia, caducidad y memoria se conservan | PC |
| I12 | La corrección converge o se detiene a las 10 rondas (el relevo es la ronda 6); hallazgos nuevos y el relevo no reinician el linaje; la política solo cambia con el pin (decisión de David); una raíz vieja conserva su política; ningún paso pide revisión a un segundo modelo; el revisor excluye a los autores | Mac |
| I13 | Revisión y CI del head, criterio y entorno vigentes; un `LISTO`, un merge, un rollback o un criterio borrado no fabrican éxito | Mac |
| I14 | La proyección de H da el mismo estado y porcentaje que `derivar` de G; dos raíces, CI en espera y unidades sin PR | Mac |
| I16 | Un PID reutilizado, una sesión caída, datos corruptos y métricas ausentes no atribuyen ni matan nada ajeno | Mac y PC |
| I18 | Un perfil sin eventos declara cobertura `unknown`; su caída no aprueba ni despacha | Mac |
| I20 | Presupuesto raíz, cupo global (`max_in_progress`) y por perfil, y escritor exclusivo; el par atómico con dos y tres plazas ocupadas | Mac y PC |
| Excepción | Una excepción sale por el Telegram de claw, la respuesta entra por `goncloud_root_resolve` y un reaviso vencido vuelve a salir | PC (H5, forzada dentro de la raíz chica) |
| Aislamiento | La batería corre sin `openclaw` en el PATH y con la Mini inalcanzable | Mac y PC |

## 5. Quién es dueño de cada cosa

| Pieza | Dueño |
|---|---|
| Contrato, fixtures, `derivar` | G (origen); H tiene la copia fijada |
| `raices/`, herramientas y ticker | goncloud-hermes |
| Instalación en la PC, ventana viva, certificación | El coordinador, con `configure_team.py --check` primero y respaldo |
| Transición de la cadena actual y del panel | SUA-09H |

## 6. El corte en rebanadas

| Rebanada | Qué | Depende de |
|---|---|---|
| H0a | En G: `derivar` a `scripts/sistema_agentes/derivar.py`, puro y sin `fcntl`; `proyeccion.py` lo importa; una prueba lo importa con `fcntl` bloqueado | — |
| H0b | En H: la copia en espejo (`shared/sistema-agentes/g/`, `pin.json`), su prueba de digests, el job de CI que compara con G, `tests/ensayos-h.json` con su recorrido, e I01 e I02 | H0a |
| H1 | Store y frontera transaccional (bandeja de salida), `decidir` con regla4, control y efectos, con el doble del kanban (I03–I06, I12, I13, I20) | H0b |
| H2 | Adaptador kanban, ticker y herramientas `goncloud_root_*` en `goncloud-team`; pruebas reales en la PC sobre una copia de `HERMES_HOME`, y el primer par `(versión, code_sha)` en `certificadas.json` | H1 |
| H3 | Autoridad (I07), excepciones por Telegram y proyección (I14, I16) | H1 |
| H4 | Flota, poteto, capacidades, `certificar.py` y la puerta por par certificado (I08–I11, I18); instalador y reversa para SUA-09H | H2, H3 |
| H5 | Ventana viva en la PC, una raíz chica de punta a punta con una excepción forzada por Telegram, recibo `SUA-07.md` y filas | H4 |

H1 y H3 pueden ir en paralelo una vez que esté H0b. Cada rebanada es un PR en goncloud-hermes; el recibo va en G.

## 7. Lo que no entra en SUA-07

- Retirar o migrar la cadena `GONCLOUD_ENGINEERING_V1` y su tope de 2 rondas: SUA-09H.
- Raíces de H en el panel de la Mini: SUA-09H (subirlas por un canal que no sea el RPC de OpenClaw).
- El dashboard en `0.0.0.0:9119`: escucha en todas las interfaces. Fila para revisar con David si debe quedar solo en loopback o detrás de WireGuard.
- `pywin32` ausente (`concurrent-log-handler` en `errors.log`) y el respaldo previo a la actualización con `WinError 5`: filas de operación de H.
