# SUA-06, seguimiento y panel: diseño y corte en rebanadas

Fecha: 2026-10-16. Estado: diseño propuesto, sin código. Lo escribió el coordinador (Claude). Lo revisa el implementador asignado antes de implementar: no es autor de este documento. **Tiene una decisión pendiente de David** (§8): qué panel, después del ensayo de LobsterBoard.

Bases leídas: G `origin/main` `7755ae54`, R `feat/agent-work-integration` en `c7a58a6b` (la Mini corre `7b3db54226bf`), y LobsterBoard `7e47255` (v0.8.6) en el ensayo M-26. La hoja de terreno del coordinador está en `~/.local/state/sua-loop/prep/sua06-terreno.md`, y el resultado del ensayo en `~/.local/state/sua-loop/mediciones/m26-lobsterboard/RESULTADO.md`, con sus capturas.

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
| 1. LobsterBoard original | Hecho como medición (M-26). Falta guardar la evidencia en el repo y la decisión de David (§8). |
| 2. Proyectar desde recibos nativos | El derivador `snapshot → proyeccion.v1`, con declarado/observado/aceptado/desconocido, la evidencia y la próxima comprobación por unidad. |
| 3. Avisos y panel sobre el mismo snapshot | El emisor de las raíces: una pasada lee el snapshot, deriva la proyección, decide avisos (consolidado y excepciones) y guarda el checkpoint después del envío confirmado. |
| 4. Allowlist, escape, límites y autenticación | La vista de solo lectura de la proyección, con esas cuatro cosas, en el panel que elija David. |
| 5. Ajustes ligados a faltantes | Depende de §8. |

## 3. Quién es dueño de cada cosa

| Cosa | Dueño | Por qué |
|---|---|---|
| El snapshot de una raíz | R | Ya existe (`managedTasks.root.read`). |
| El derivador `snapshot → proyeccion.v1` | G, función pura | El contrato vive en G y el derivador se prueba sin gateway. R no cambia. |
| El emisor de avisos de raíces | El host de cada máquina | La Mac ya tiene un emisor, el host de encargos (plan, paso 3). La Mini lo corre como cron nativo de claw, sin modelo (SUA-02: el reloj vive en el scheduler nativo). |
| El panel | Lo decide David (§8) | Es el paso 5 del bloque. |

## 4. El diseño elegido

### 4.1 El derivador

`scripts/agent-work/proyeccion.py derivar <snapshot.json>` y la función `derivar(snapshot, ahora) -> dict`, con biblioteca estándar, que corre en la Mac y en la Mini (Python 3.9):

- `rootId`, `planRevision` y `controlEpoch` salen de `meta`, y `generatedAt` es `ahora`.
- `progress`: con los criterios de aceptación de las unidades del plan vigente, `declared` = el porcentaje de unidades con al menos un intento reportado (`reported` o más); `observed` = el porcentaje con un claim `passed` en cada criterio de verificación; `accepted` = el porcentaje en estado `accepted` con aceptación integrada vigente. Sin criterios válidos, `null` (el desconocido), nunca 0. Los pesos: iguales por unidad, salvo que el plan los fije (diseño del sistema unificado, líneas 324-330).
- `units[]`: una fila por unidad del plan, con su último intento: `state`, `host`, `executor`, `modelId` (o `null`), `nextCheckAt` (el próximo vencimiento conocido: el plazo de la tarea viva o el reaviso de su excepción) y `error` (la clase del último incidente, o `null`). Las unidades sin intento salen `pending` o `ready` (de `unbound`).
- `freshness.staleAfterMs`: el `runTimeoutSeconds` de la configuración de tareas gestionadas, en milisegundos.
- Allowlist: solo los campos del contrato (la prueba del contrato ya rechaza un campo extra). Nada de prompts, argv, transcripciones ni rutas absolutas; los textos van recortados y sin caracteres de control.

`proyeccion.py leer --root <id>` llama a `managedTasks.root.read` con el `openclaw` del host y pasa el resultado por `derivar`. Lo usan el emisor y el panel.

### 4.2 El emisor de las raíces

Una pasada (`proyeccion.py pasar`), igual en la Mac y en la Mini:

1. Lista las raíces abiertas, las lee y deriva cada proyección.
2. **Consolidado**: si hay pendientes y pasaron 30 min desde el último consolidado avisado, arma un mensaje con todas las raíces vivas. Dos tareas comparten el mismo reloj y el mismo consolidado, y cerrar una no apaga la otra (plan, "Verificar").
3. **Excepciones**: una excepción nueva se avisa enseguida; una sin respuesta se vuelve a avisar pasado su `renoticeAfterMs` (mínimo una hora).
4. Envía por `avisar.py`, con la misma compuerta. El checkpoint (`<state_root>/proyeccion-checkpoint.json`, escritura atómica) avanza solo si `avisar` contesta `enviado: true`. Un envío fallido no lo adelanta, y la pasada siguiente reintenta.
5. Escribe la última proyección de cada raíz en `<state_root>/proyecciones/<rootId>.json`, que es lo que lee el panel. El panel y los avisos leen el mismo snapshot de la misma pasada (plan, paso 3).

En la Mac, el host de encargos llama a la pasada en su bucle, como hoy a `ProgressPublisher`. En la Mini, un cron nativo sin modelo (`--no-deliver`) la corre cada 5 min (el latido del diseño del sistema unificado, líneas 333-336). Hasta que SUA-09O encienda las raíces, la pasada no encuentra ninguna raíz y no hace nada.

### 4.3 El ruido de "get no devolvió documento"

`progress-events.py publish` distingue una corrida que el tablero no conoce (con un `runbook.progress.get` que conteste `desconocida` tres veces seguidas en pasadas distintas) y archiva su cola en `archivo-<fecha>/` con una línea en el log, en vez de reintentar para siempre. El plugin no se toca. Esto cierra la fila B16 de `followups.md`.

### 4.4 La vista de solo lectura

Cualquiera que sea el panel (§8), la vista de la proyección cumple con lo mismo: solo lee `proyecciones/<rootId>.json`, escapa todo texto (sin `innerHTML` con datos), no tiene URLs salvo las del propio panel, recorta largos, muestra la frescura (generada hace X; pasado `staleAfterMs` sale "vieja" en gris) y muestra vacío, error y sin conexión como estados con nombre. No tiene acciones: las acciones siguen en las entradas autenticadas que existen.

## 5. Cómo se prueba

| "Verificar" | Prueba |
|---|---|
| I14: actividad y porcentaje separados; el desconocido no es 0 | `derivar` con snapshots de fixture: sin criterios, `null`; una tarea viva no sube `accepted`; un merge o un `LISTO` no lo producen. |
| Dos tareas comparten reloj y consolidado; cerrar una no apaga la otra | `pasar` con dos raíces de fixture: un consolidado con las dos; se cierra una y el siguiente trae la otra. |
| Una sin PR puede cerrar por evidencia | Snapshot de una raíz con una unidad aceptada por un claim de verificación sin efecto de PR: `accepted` 100. |
| Fallos de envío sin ACK | `avisar` falso que contesta `enviado: false`: el checkpoint no avanza y la pasada siguiente reintenta. |
| Frescura, corrupción, PID reutilizado, métricas ausentes | Un snapshot viejo sale vencido; un JSON roto es un error con nombre; las métricas que faltan son `null`. El PID reutilizado ya lo cubre el host (SUA-03). |
| Secretos y XSS sintéticos | Un snapshot con `<script>`, una llave falsa y una ruta absoluta en un texto: la proyección los recorta o los rechaza y la vista los escapa. |
| Teclado, móvil, error, offline, vacío | En el panel elegido (§8): capturas de escritorio y celular de cada estado, como en M-26. |
| Sin OpenGrokBot | Un grep de candado: ninguna rebanada lo instala ni lo nombra fuera de texto histórico. |

## 6. El corte en rebanadas

| Rebanada | Qué | Depende de |
|---|---|---|
| P1 | 4.1, el derivador, con sus fixtures y la prueba del contrato. | — |
| P2 | 4.2, el emisor y su checkpoint, en la Mac (host) y la Mini (cron nativo apagado hasta SUA-09O). | P1 |
| P3 | 4.3, el ruido de las colas desconocidas. | — |
| P4 | 4.4, la vista, en el panel que elija David. | P1, §8 |
| P5 | La evidencia de M-26 en el repo (`docs/evidence/sistema-agentes-unificado/SUA-06-lobsterboard.md` y sus capturas), el recibo `SUA-06.md` y las filas. | P1 a P4 |

P1, P3 y la evidencia de M-26 van en paralelo. P4 espera la decisión.

## 7. Lo que no entra en SUA-06

- Encender las raíces en producción (SUA-09O).
- Acciones desde el panel: el panel inicial es de lectura (plan, paso 4).
- Instalar LobsterBoard en la Mini o en cualquier host: no muestra datos de claw y lee archivos de credenciales; si David lo quiere igual, se decide en §8 con su encierro.
- Hermes (SUA-07).

## 8. Decisión pendiente de David: el panel

El paso 5 del bloque dice que, si LobsterBoard pide una reescritura amplia, la UI se detiene y se le presentan alternativas a David, sin sustituirla sola. M-26 muestra que LobsterBoard original no muestra datos de claw y no sirve en el celular. Las alternativas:

| Opción | Qué es | Costo y riesgo |
|---|---|---|
| A (recomendada) | Una página de solo lectura dentro del plugin `tablero-runbook` del gateway, que ya existe, ya está autenticada (`auth: "gateway"`) y ya pinta los loops: `/runbook/tablero/raices`. | Lo menos nuevo: ni otro proceso ni otro puerto, con la autenticación que ya hay. Hay que hacerla responsiva (la del tablero actual tampoco se probó en celular). |
| B | LobsterBoard con un `iframe-embed` que apunte a la página de A. | Es la página de A más un servidor ajeno con BSL, sin autenticación por omisión, que llama a terceros. No agrega datos. |
| C | LobsterBoard con un puente REST propio (lo que pide su `WIDGETS-STATUS.md:36`) para que sus widgets de OpenClaw lean los datos de verdad. | Un servicio nuevo que traduce OpenClaw a REST, y los widgets de LobsterBoard igual no conocen raíces, unidades ni excepciones; además sigue sin servir en el celular. |
| D | Sin panel: solo los avisos de 4.2 por Telegram. | Lo más barato. No cumple I15 (panel en móvil y escritorio) y deja el paso 4 sin entrega. |

Mientras David decide, P1, P2, P3 y la evidencia de M-26 avanzan, porque no dependen del panel.
