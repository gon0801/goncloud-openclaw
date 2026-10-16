# SUA-06, seguimiento y panel: diseño y corte en rebanadas

Fecha: 2026-10-16. Estado: diseño propuesto, sin código. Ronda 2: con VEREDICTO-SUA06-diseno-r1 (B1 a B3, M1 a M8). Lo escribió el coordinador (Claude). Lo revisa el implementador asignado antes de implementar: no es autor de este documento. El panel lo decidió David el 2026-10-16, después del ensayo de LobsterBoard: la opción A del §8, una página en el gateway.

Bases leídas: G `origin/main` `560497f2`, R `feat/agent-work-integration` en `c7a58a6b` (la Mini corre `7b3db54226bf`), y LobsterBoard `7e47255` (v0.8.6) en el ensayo M-26. La hoja de terreno del coordinador está en `~/.local/state/sua-loop/prep/sua06-terreno.md`, y el resultado del ensayo en `~/.local/state/sua-loop/mediciones/m26-lobsterboard/RESULTADO.md`, con sus capturas.

Documentos que manda este diseño y que no cambia:
- El bloque "SUA-06" del [plan](../plans/2026-10-05-sistema-agentes-unificado.md) (líneas 803-832), con su "Verificar" y las invariantes I14 a I17.
- El [contrato](../../spec/sistema-agentes.v1.md): `sistema-agentes.proyeccion.v1` (líneas 311-331) y `sistema-agentes.excepcion.v1`.
- La decisión de David del 2026-09-26: probar LobsterBoard original antes de una UI propia, conservarlo si cumple y ajustar solo lo que falte medido ([diseño del centro de tareas](2026-09-22-centro-tareas-design.md), líneas 169-182).
- Los diseños de SUA-01 a SUA-05 y sus recibos.

| Palabra | Sentido |
|---|---|
| proyección | El documento `sistema-agentes.proyeccion.v1` de una raíz: derivado, redactado, nunca ordena trabajo. |
| snapshot | La foto de una raíz que R devuelve por `managedTasks.root.read` (`RootSnapshot`, `managed-root.types.ts:432`). |
| emisor | El único proceso de un host que manda avisos y publica el panel de ese host. |
| checkpoint | Lo último que el emisor da por avisado. Solo avanza después de un envío confirmado. |

## 1. Lo que existe hoy

### El ensayo de LobsterBoard (M-26, paso 1 del bloque)

- Licencia BSL 1.1 con un permiso adicional: "internal company use (not offered as a commercial product or service)". El uso interno de David entra en ese permiso.
- **No muestra nada de claw.** Lee OpenClaw del disco del equipo donde corre: `~/.openclaw/cron/jobs.json`, `logs/gateway.log` y `agents/main/agent/auth-profiles.json` (`server/routes/system.cjs`). En la Mini, OpenClaw 2026.9.7 no tiene ninguno de los tres: los crons viven en SQLite. Con la plantilla de OpenClaw salen Cron 0, Log 0, Auth "—" y "No activity yet today". El upstream lo dice en `WIDGETS-STATUS.md:36`: OpenClaw no expone REST y esos widgets necesitan un puente propio. El único widget verificado para mostrar algo propio es `iframe-embed`.
- **No sirve en el celular**: el lienzo es de tamaño fijo y en 390×844 los widgets y el botón salen cortados.
- Llama a terceros (clima, bolsa, citas, GitHub). Sin contraseña, sus POST no piden autenticación, y el `id` de plantilla entra a `path.join` sin normalizar.

### El seguimiento que hay

- `tablero-runbook` es un plugin del gateway: RPC `runbook.progress.*` y rutas autenticadas `/runbook/tablero` y `/runbook/progress`. Pinta `runbook-progress.v1/v2`, el documento de las corridas de los loops. Valida campos, longitudes y texto, y tiene una regex de secretos (`contrato.ts`, `progress-event.ts`).
- En la Mac, el host de encargos publica su cola de avance (`ProgressPublisher`, `native_gateway.py:888-977`) a ese plugin por `progress-events.py`. Una cola de una corrida que el tablero no conoce repite "get no devolvió documento y revisión aceptados" en `host.log` cada pasada, porque el plugin junta tres causas distintas en "desconocida" (`index.ts:319-325`; `T12-runbook.md:294`).
- **Nadie produce ni consume `proyeccion.v1`**: ni R ni G (solo fixtures y la prueba del contrato). R da el snapshot de una raíz por `managedTasks.root.read` (lectura de operador, `managed-tasks.ts:196`).
- Avisos: `avisar.py` (G, Telegram, con la compuerta `AGENT_WORK_AVISOS`), el cron `avance-tareas` con `avance-tick.mjs` y `seguimiento-clock.ts` (un Telegram como máximo cada 25 min, latido cada 4 h, checkpoint solo con `messageId`), y los vigías. No hay un emisor por host para las raíces.
- Las raíces de SUA-02 existen en R, pero no están encendidas en producción (`managedTasks.rootRequesters` apagado); se encienden en SUA-09O.

## 2. Lo que falta, contra el bloque

| Paso | Qué falta |
|---|---|
| 1. LobsterBoard original | Hecho como medición (M-26) y decidido por David (§8). Falta guardar la evidencia en el repo. |
| 2. Proyectar desde recibos nativos | El derivador `snapshot → proyeccion.v1`, con declarado/observado/aceptado/desconocido, la evidencia y la próxima comprobación por unidad. |
| 3. Avisos y panel sobre el mismo snapshot | El emisor de las raíces: una pasada lee el snapshot, deriva la proyección, decide avisos (consolidado y excepciones) y guarda el checkpoint después del envío confirmado. |
| 4. Allowlist, escape, límites y autenticación | La vista de solo lectura de la proyección, con esas cuatro cosas, en el panel que elija David. |
| 5. Ajustes ligados a faltantes | LobsterBoard no se adopta (§8); el ajuste es la página nueva del plugin. |

## 3. Quién es dueño de cada cosa

| Cosa | Dueño | Por qué |
|---|---|---|
| El snapshot de una raíz | R | Ya existe (`managedTasks.root.read`). |
| El derivador `snapshot → proyeccion.v1` | G, función pura | El contrato vive en G y el derivador se prueba sin gateway. |
| La lista de raíces | R, un método nuevo `managedTasks.root.list` | No existe ningún listado de raíces (solo `root.read` de una, con `operator.admin`, `core-descriptors.ts:764`); leer la tabla `managed_roots` desde fuera ataría G al esquema interno de R. |
| El emisor de avisos de raíces | El host de cada máquina | La Mac ya tiene un emisor, el host de encargos (plan, paso 3). La Mini lo corre como cron nativo de claw, sin modelo (SUA-02: el reloj vive en el scheduler nativo). |
| El panel | El plugin `tablero-runbook` del gateway | Decisión de David del 2026-10-16 (§8, opción A). |

## 4. El diseño elegido

### 4.1 El derivador

`scripts/agent-work/proyeccion.py derivar <snapshot.json>` y la función `derivar(snapshot, ahora, stale_after_ms, intervalo_ms) -> dict`, con biblioteca estándar, que corre en la Mac y en la Mini (Python 3.9). `stale_after_ms` y `intervalo_ms` los pasa quien llama (M1): no salen del snapshot.

- `rootId`, `planRevision` y `controlEpoch` salen de `meta`, y `generatedAt` es `ahora`.
- `progress`: con los criterios de aceptación de las unidades del plan vigente, `declared` = el porcentaje de unidades con al menos un intento reportado (`reported` o más); `observed` = el porcentaje con un claim `passed` en cada criterio de verificación; `accepted` = el porcentaje en estado `accepted` con aceptación integrada vigente. Sin criterios válidos, `null` (el desconocido), nunca 0. Los pesos son iguales por unidad, salvo que el plan los fije (diseño del sistema unificado, líneas 324-330).
- `units[]`: una fila por unidad del plan, con su último intento (M2):
  - `state`: el del último `UnitDocument`, o `pending`/`ready` para las de `unbound`.
  - `executor` y `host`: de `assignment.target`. Con `kind: "cli"`, `executor` es `cli:<adapterId>` y `host` es `hostId`; con `kind: "agent"`, `executor` es `agent:<agentId>` y `host` es el host del gateway (el que corre `leer`). Sin intento, `executor` `"sin-asignar"` y `host` el del gateway.
  - `modelId`: `null` (el snapshot no lo trae; vendrá cuando la flota llegue a R, fila en §7).
  - `error`: la clase del último incidente de esa unidad, o `null`.
  - `nextCheckAt` (B1: el contrato lo pide en cada fila y no admite `null`): es la próxima vez que el sistema mira esa unidad. Para una unidad con una excepción abierta sin respuesta, el reaviso que lleva el emisor en su checkpoint (`notadoEn + renoticeAfterMs`, 4.2), porque el `noticed_at` de R no viaja en el snapshot. Para cualquier otra, incluidas las cerradas mientras la raíz siga abierta, `ahora + intervalo_ms` (la siguiente pasada del emisor). Si la raíz trae `meta.authority.deadline` y es anterior, ese. Es grueso a propósito, y la prueba de 4.1 fija los tres casos.
- `freshness.staleAfterMs`: `stale_after_ms`, que `leer` y `pasar` toman de `managedTasks.runTimeoutSeconds` de la configuración del gateway (en milisegundos). Usar el tiempo de una tarea como frescura del panel es una decisión: una proyección sin pasar en más que eso ya no dice lo que pasa.
- Allowlist: solo los campos del contrato (la prueba del contrato ya rechaza un campo extra). Nada de prompts, argv, transcripciones ni rutas absolutas; los textos van recortados y sin caracteres de control.

`proyeccion.py leer --root <id>` llama a `managedTasks.root.read` (con `operator.admin`, el mismo scope que ya usa el host) con el `openclaw` del host y pasa el resultado por `derivar`. `proyeccion.py listar` llama a `managedTasks.root.list`.

### 4.1b La lista de raíces en R (B2)

Método nuevo de R, `managedTasks.root.list` (operator.admin, como `root.read`): `{ roots: [{ rootId, state, openedAt }] }`, solo raíces no cerradas por omisión y `{ all: true }` para todas. Lee `managed_roots` con su control. Sin él, el emisor no tiene de dónde sacar qué raíces mirar. Es la rebanada P0, en R, con su prueba y la compuerta de R.

### 4.2 El emisor de las raíces

Una pasada (`proyeccion.py pasar`), igual en la Mac y en la Mini:

1. Lista las raíces abiertas (`managedTasks.root.list`), las lee y deriva cada proyección.
2. **Consolidado**: si hay pendientes y pasaron 30 min desde el último consolidado avisado, arma un mensaje con todas las raíces vivas. Dos tareas comparten el mismo reloj y el mismo consolidado, y cerrar una no apaga la otra (plan, "Verificar").
3. **Excepciones**: una excepción nueva se avisa enseguida; una sin respuesta se vuelve a avisar pasado su `renoticeAfterMs` (mínimo una hora), contado desde el `notadoEn` que el emisor guarda en su checkpoint por `exceptionId`.
4. Envía por `avisar.py`, con la misma compuerta. `avisar` pasa a devolver el `messageId` que trae la salida `--json` de `openclaw message send` (M3), y el checkpoint (`<dir>/checkpoint.json`, escritura atómica) avanza solo con un `messageId` entero positivo, como ya lo exige `avance-tick.mjs:122-128`. Un envío fallido no lo adelanta, y la pasada siguiente reintenta.
5. Escribe la última proyección de cada raíz en `<dir>/proyecciones/<rootId>.json`, que es lo que lee el panel. `<dir>` (M5): en la Mini, `<stateDir del plugin tablero-runbook>/raices/`; el plugin gana `raicesDir` en su `configSchema`, con ese valor por omisión. En la Mac, `~/.local/state/agent-work-host/raices/`. El panel y los avisos leen el mismo snapshot de la misma pasada (plan, paso 3).

En la Mac, el host de encargos llama a la pasada en su bucle, como hoy a `ProgressPublisher`. En la Mini, un cron nativo de tipo comando (payload `command` con su argv, que corre desacoplado sin modelo ni sesión: `src/cron/persisted-shape.ts:180-215`, el mismo patrón del cron `avance-tareas`; M4) la corre cada 5 min (el latido del diseño del sistema unificado, líneas 333-336). Hasta que SUA-09O encienda las raíces, la pasada no encuentra ninguna raíz y no hace nada.

### 4.3 El ruido de "get no devolvió documento"

`progress-events.py publish` distingue una corrida que el tablero no conoce (con un `runbook.progress.get` que conteste `desconocida` tres veces seguidas en pasadas distintas) y archiva su cola en `archivo-<fecha>/` con una línea en el log, en vez de reintentar para siempre. El plugin no se toca. Esto cierra la fila B16 de `followups.md`.

### 4.4 La vista de solo lectura

Una página nueva del plugin `tablero-runbook`, `/runbook/tablero/raices` (la lista) y `/runbook/tablero/raices/<rootId>` (una raíz). El `rootId` de la URL se valida con una regex cerrada antes de tocar el disco, como `FASE_RE` y `CORRIDA_RE` (`contrato.ts:37-38`), y lo que no casa contesta 400 (B3); la ruta final se comprueba dentro de `raicesDir`. La página va con la misma autenticación del gateway que las rutas que ya tiene. Responsiva: se prueba en 390×844 y en escritorio. Lee las proyecciones que deja el emisor del host del gateway (la Mini). La vista de la proyección cumple con lo mismo: solo lee `proyecciones/<rootId>.json`, escapa todo texto (sin `innerHTML` con datos), no tiene URLs salvo las del propio panel, recorta largos, muestra la frescura (generada hace X; pasado `staleAfterMs` sale "vieja" en gris) y muestra vacío, error y sin conexión como estados con nombre. No tiene acciones: las acciones siguen en las entradas autenticadas que existen.

## 5. Cómo se prueba

| "Verificar" | Prueba |
|---|---|
| I14: actividad y porcentaje separados; el desconocido no es 0 | `derivar` con snapshots de fixture: sin criterios, `null`; una tarea viva no sube `accepted`; un merge o un `LISTO` no lo producen. |
| Dos tareas comparten reloj y consolidado; cerrar una no apaga la otra | `pasar` con dos raíces de fixture: un consolidado con las dos; se cierra una y el siguiente trae la otra. |
| Una sin PR puede cerrar por evidencia | Snapshot de una raíz con una unidad aceptada por un claim de verificación sin efecto de PR: `accepted` 100. |
| Fallos de envío sin ACK | `avisar` falso que contesta `enviado: false`: el checkpoint no avanza y la pasada siguiente reintenta. |
| Frescura, corrupción, PID reutilizado, métricas ausentes | Un snapshot viejo sale vencido; un JSON roto es un error con nombre; las métricas que faltan son `null`. El PID reutilizado ya lo cubre el host (SUA-03). |
| Secretos y XSS sintéticos | Un snapshot con `<script>`, una llave falsa y una ruta absoluta en un texto: la proyección los recorta o los rechaza y la vista los escapa. |
| Rutas maliciosas (I17) | `/runbook/tablero/raices/..%2F..%2Fx` y un `rootId` con `/` contestan 400 y no leen nada fuera de `raicesDir`. |
| `nextCheckAt` siempre definido | `derivar` con una unidad viva, una con excepción abierta (con y sin `notadoEn` en el checkpoint) y una cerrada: los tres valores esperados, ninguno `null`. |
| Teclado, móvil, error, offline, vacío | En el panel elegido (§8): capturas de escritorio y celular de cada estado, como en M-26. |
| Sin OpenGrokBot | Un grep de candado: ninguna rebanada lo instala ni lo nombra fuera de texto histórico. |

## 6. El corte en rebanadas

| Rebanada | Qué | Depende de |
|---|---|---|
| P0 | 4.1b, `managedTasks.root.list` en R, con su prueba y la compuerta de R. | — |
| P1 | 4.1, el derivador, con sus fixtures y la prueba del contrato. | — |
| P2 | 4.2, el emisor y su checkpoint (con el `messageId` de `avisar`), en la Mac (host) y la Mini (cron nativo de comando, sin efecto hasta SUA-09O). | P0, P1 |
| P3 | 4.3, el ruido de las colas desconocidas. | — |
| P4 | 4.4, la página del plugin `tablero-runbook`, con sus capturas de escritorio y celular. | P1, P2 |
| P5 | La evidencia de M-26 en el repo (`docs/evidence/sistema-agentes-unificado/SUA-06-lobsterboard.md` y sus capturas), el recibo `SUA-06.md` y las filas. | P1 a P4 |

P0, P1, P3 y la evidencia de M-26 van en paralelo; P4 sale cuando P1 y P2 están.

## 7. Lo que no entra en SUA-06

- Encender las raíces en producción (SUA-09O).
- Acciones desde el panel: el panel inicial es de lectura (plan, paso 4).
- Instalar LobsterBoard en la Mini o en cualquier host: no muestra datos de claw y lee archivos de credenciales; si David lo quiere igual, se decide en §8 con su encierro.
- Hermes (SUA-07).
- Las raíces de la Mac en el panel de la Mini: el panel lee el disco del gateway, así que solo ve las proyecciones que escribe el emisor de la Mini (M6). Hoy no hay raíces encendidas; si SUA-09O las abre en la Mac, se suben por RPC como hace `progress-events` (fila).
- Retirar `progress_bridge.py`, `ProgressPublisher` y `runbook-progress.v2` (la tabla de migración del contrato, línea 359, los asigna a SUA-06; M7): conviven con la proyección nueva hasta SUA-09O, porque hoy los usan los loops y el host de encargos y las raíces no están encendidas. El retiro va en SUA-09O, con su prueba de que nada los consume.
- `modelId` en la proyección: queda en `null` hasta que la flota llegue a R (fila).

## 8. La decisión de David: el panel

El paso 5 del bloque dice que, si LobsterBoard pide una reescritura amplia, la UI se detiene y se le presentan alternativas a David, sin sustituirla sola. M-26 muestra que LobsterBoard original no muestra datos de claw y no sirve en el celular. Las alternativas:

| Opción | Qué es | Costo y riesgo |
|---|---|---|
| A (recomendada) | Una página de solo lectura dentro del plugin `tablero-runbook` del gateway, que ya existe, ya está autenticada (`auth: "gateway"`) y ya pinta los loops: `/runbook/tablero/raices`. | Lo menos nuevo: ni otro proceso ni otro puerto, con la autenticación que ya hay. Hay que hacerla responsiva (la del tablero actual tampoco se probó en celular). |
| B | LobsterBoard con un `iframe-embed` que apunte a la página de A. | Es la página de A más un servidor ajeno con BSL, sin autenticación por omisión, que llama a terceros. No agrega datos. |
| C | LobsterBoard con un puente REST propio (lo que pide su `WIDGETS-STATUS.md:36`) para que sus widgets de OpenClaw lean los datos de verdad. | Un servicio nuevo que traduce OpenClaw a REST, y los widgets de LobsterBoard igual no conocen raíces, unidades ni excepciones; además sigue sin servir en el celular. |
| D | Sin panel: solo los avisos de 4.2 por Telegram. | Lo más barato. No cumple I15 (panel en móvil y escritorio) y deja el paso 4 sin entrega. |

**David eligió la opción A el 2026-10-16**, a la pregunta del coordinador después de M-26 ("Página en el gateway"). LobsterBoard no se adopta y no se instala.
