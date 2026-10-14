# T12: recibo del despliegue en la Mac Mini

Este es el recibo que pide el plan (`:320`). Cierra la parte B de `T12-runbook.md`. La parte A está en `T12-parte-a.md`. Las cifras salen de los logs de `~/.local/state/encargos-loop/artifacts/T12/` y de consultas de solo lectura a la Mini y al gateway del 2026-10-11, entre las 19:44Z y las 20:21Z.

## Qué corre en vivo

- **Mini.** Al cierre, R `f8316c9c867ebef79cfb66f8104b7f589c93e93a` (B13), instalado el 2026-10-11 a las 15:15Z. Después del cierre se instaló `605aef7` (B17-R, 2026-10-12 02:46Z; fila de abajo). El resto de esta sección describe el estado al cierre. Esquema 27. `managedTasks.enabled` en `true`, con `requesters: ["main"]` y el host `mac-local` con un solo adaptador, `opencode`.
- **Mac.** El host corre G `2be0f55` desde `~/dev/wt/agent-work-host`, en `tmux -L agent-work`, sesión `host`. El host arrancó el 2026-10-11 a las 19:27:09Z, en el mismo segundo en que el checkout pasó a `2be0f55`. Spool `mac-local-c` (esquema 2), instancia `canario-3`, adaptador `opencode`, `--progress-state-dir ~/.local/state/runbook-progress-events`.

## Paquetes de R instalados en la Mini

Cada instalación la hizo un script desde la Mac (`t12-parte-a.sh` y `t12-actualizar-<sha>.sh`). Cada script copia los paquetes, compara su sha256 en la Mini antes de instalar, detiene el gateway, toma una foto, instala `openclaw` y `@openclaw/ai` juntos, arranca y relee `build-info.json`, el esquema, `managedTasks` y los crons habilitados. Los sha256 de abajo se volvieron a calcular hoy con `shasum -a 256` sobre `~/.local/state/encargos-loop/artifacts/paquete-<sha>/`.

| Fecha (UTC) | R | sha256 de `openclaw-2026.9.7.tgz` | Salida del script | Foto en la Mini |
|---|---|---|---|---|
| 2026-10-10 05:14 | `f1c5f34` (parte A) | `76c0883e2a8f6206ed63dc78b291effbfa6946cf9d4bcc646ae9b88365982e2c` | instalado, admisión cerrada | `pre-f1c5f34-20261009-2213` |
| 2026-10-10 16:04 | `19c2ed1` (B6) | `69de612d28c77dabdf62c214cd5e49247d5c5c8af8e926b75e460e3251e3d2b4` | `ACTUALIZADO OK`, admisión cerrada | `pre-19c2ed1-20261010-0903` |
| 2026-10-11 02:13 | `4b9785c` (B8) | `09d30e248e571ecb253c4d91314e99bfa55f1791858004f0382bec35bd5f0882` | `ACTUALIZADO OK`, admisión cerrada | `pre-4b9785c-20261010-1913` |
| 2026-10-11 10:37 | `ff1709f` (B11 y B12) | `ac1dceade49cf7fbb8071f47fce08728c4d1ab910e3b84d7d6d59efdc9a271db` | `ACTUALIZADO OK`, `managedTasks como estaba` | `pre-ff1709f-20261011-0337` |
| 2026-10-11 15:14 | `f8316c9` (B13) | `eb886e08905b21f597a412b261d21bc0c993e3dc202b5893e7f7c13d0b58c98d` | `ACTUALIZADO OK`, `managedTasks como estaba` | `pre-f8316c9-20261011-0814` |
| 2026-10-12 02:46 | `605aef7` (B17-R, después del cierre) | `d4497986c35086455a666dd2f38134fa12cc9cd5bd47a42a5c0a6f8888ca6514` | `ACTUALIZADO OK`, `managedTasks como estaba` | `pre-605aef7-20261011-1946` |

- `@openclaw/ai` es el mismo en los cinco: `0512fd870a86f40ea06f13931ef36a9ca9af07286d378fb1e717453ba6ffbcc8`.
- En `f8316c9`, `package-bundle.json` registra además `@openclaw/gateway-client` (`966aaae638ed6b962c18a7f6a895a89131b3738e10ef00e232ed65e98d497508`) y `@openclaw/gateway-protocol` (`eda8533d019e1e1f6606993f315b5dbf1339e3e8b8a1b2fdb19d97c414282050`). No se instalan aparte; van dentro del paquete raíz.
- `build-info.json` vivo: `commit` `f8316c9c867ebef79cfb66f8104b7f589c93e93a`, `buildId` `2026.9.7-release-f8316c9c867e-2026-10-11T11-15-14.185Z`. El empaquetado está en `artifacts/B13-empaquetar.log`, con el smoke `OpenClaw 2026.9.7 (f8316c9)`.
- Una segunda corrida de `t12-actualizar-19c2ed1.sh`, a las 16:04:37Z del 2026-10-10, salió con `PARO` porque la versión viva ya era `19c2ed1`. No tocó nada.
- Las dos últimas instalaciones se hicieron con la admisión abierta, porque el corte ya estaba hecho. No había encargos nuevos en esas ventanas: ninguna tarea de R se creó entre las 10:37 y las 10:38Z, ni entre las 15:14 y las 15:15Z. El host siguió capturando resultados durante las dos.
- Al cierre, `artifact-manifest.json` seguía fijando `4b9785c`. Después pasó a `605aef7` (B17) y a `4acb881` (PR #276, 2026-10-12), que es el que fija hoy (`followups.md`, secciones "Resueltos en B17" y "Resueltos en B20 y B21").

## El corte

`t12-corte-canario.sh` corrió el 2026-10-11 a las 02:38Z, con R `4b9785c` (log `corte-canario-20261011T023815Z.log`).

- `cutover_live.py inspect` devolvió `problems: []`. Esa revisión incluye la de dos emisores para la misma entrada.
- `apply` imprimió `transferred`.
- Estado del corte (`~/.local/state/agent-work-host/corte-canario.json`): `schema` `agent-work-cutover.v2`, `generation` **2**, `owner` **`native`**, `suspended: {}`.
- La entrada es `loop:canario-encargos`, con `legacyCrons: []`, host `mac-local`, adaptador `opencode`, `runTimeoutSeconds` 3600 y el spool `mac-local`.
- La config viva quedó con `enabled: true`, `requesters: ["main"]` y `mac-local` con `["opencode"]`. Ese es el único emisor.

## Canarios

Todos usaron el repo de prueba `/Users/dn/dev/canario-encargos`. Ninguno tocó un repo de negocio. Los mensajes a `main` están en `~/.local/state/encargos-loop/canario/mensaje-*.txt`. Las columnas de R salen de `managed_tasks`, `managed_task_handlings`, `managed_task_incidents`, `managed_task_cancellations` y `managed_task_host_closures` de la Mini.

| Canario | Tarea | Qué prueba | En R | Cierre del host en R |
|---|---|---|---|---|
| 1 | `1454c912`, `canario-encargo-1` | Primera entrega | El diálogo de actualización de opencode se comió la entrega. El host la dejó `abandoned` y `main` la canceló a las 03:35:22Z. | `ReleasedAdopted`, `delivery abandoned`, 19:43:50Z, con `--close-only` (B14). |
| 1b | `98431858`, `canario-encargo-1b` | Repetir la entrega | Resultado `ready.v1`, una incidencia `invalid-result` y una decisión `complete`. Necesitó cuatro intervenciones a mano (fila B9-host de `followups.md`). | `ReleasedAdopted`, `adopted mark cleared`, 19:43:58Z, con `--close-only` (B14). |
| 3 | `8b1146ba` y su hijo `985012e2` | Revisión con `Changes` y encargo de corrección | `8b1146ba` entregó `review.v1` con `verdict: changes`. `main` resolvió `continue` con un hijo de corrección. El hijo entregó y `main` lo resolvió `complete`. El `task_key` de `8b1146ba` quedó `***` (hueco B12). | `ReleasedAdopted`, 08:51:48Z y 09:39:10Z. |
| 4 | `7c276919`, `canario-encargo-4` | Operación sin SHA | `inputRevision` de tipo `artifact`, el mismo brief. Resultado y decisión `complete`, sin intervención, con R `ff1709f`. | `ReleasedAdopted`, 10:40:30Z. |
| 5 | `840c7532`, `canario-encargo-5` | Incidencia de permiso sin aprobar | Incidencias `permission-required` y, al vencer el plazo de 3600 s, `deadline-missed`. Nadie aprobó el permiso. `main` canceló la tarea a las 10:43:43Z. | `ReleasedAdopted`, 15:15:27Z. El host lo cerró solo en su primera pasada con B13: rechazó el diálogo con Esc, dejó el composer vacío y opencode vivo. |
| 6 | `feccbd30`, `canario-encargo-6` | `progressBinding` y tablero | Resultado con proyección y recibo de la proyección. Decisión `complete`. | `ReleasedAdopted`, 17:56:28Z. |

Tablero del canario 6, leído hoy con `runbook.progress.get` (`corrida: encargos-canario`): revisión 3, carril `canario` en `revision-cruzada` con head `31e541fdb8b852a0b154d92f175bc1d8a3f22925`, y dos eventos, `round.started` (15:18:18Z) y `round.ready` (17:56:32Z). Los eventos de apertura están en `~/.local/state/encargos-loop/canario/c6/`. El evento `round.ready` lo escribió el host, pero lo publicó David a mano: el host escribía en `~/.local/state/agent-work-host/progress`, un directorio que nadie publicaba.

### Errores míos en los canarios

- El mensaje del canario 5 (parte B de `mensaje-4.txt`) le pedía a `main` resolver la tarea con `{"kind": "blocked"}`. Eso no vale: `resolve` exige un resultado, y la tarea no tenía. Lo correcto es `managed_tasks_cancel`. `main` se detuvo, y `mensaje-5.txt` pidió la cancelación.
- Los canarios 1 a 5 no llevaban `progressBinding`. Hasta el canario 6, el tablero no se había ejercido en vivo.

### Canario 8: el alias `opencode@opencode-go/deepseek-v4-pro` (2026-10-12, después del cierre)

El canario 8 pasó en su cuarto intento, el 2026-10-12 de las 21:31:32Z a las 21:32:20Z (48 s), sin intervención del operador. David mandó `canario/mensaje-8.txt` a `main` por Telegram. La Mini corría R `4acb881` y los hosts de la Mac corrían G `73f76ee6`. La evidencia está en `~/.local/state/encargos-loop/canario/c8/`, y el resumen en la entrada "CANARIO 8 PASA" de `~/.local/state/encargos-loop/estado.md`. Las líneas de abajo son copia literal de `r-tarea.txt` y la última es la fila de la operación en `spool-deepseek-1.txt`.

```
task: dd407096-78ef-43e5-9859-66a1d7779acb | key: canario-saludo-20261012-1431 | creada 21:31:32Z actualizada 21:32:09Z gen 1
target: {'adapterId': 'opencode@opencode-go/deepseek-v4-pro', 'hostId': 'mac-local', 'kind': 'cli'}
inputRevision: {'kind': 'code', 'repository': '/Users/dn/dev/canario-encargos', 'sha': '31e541fdb8b852a0b154d92f175bc1d8a3f22925'}
resultContract: ready.v1 | continuation: {'kind': 'requester'}
admision: canario-saludo-20261012-1431-admit admitted 21:31:34Z
decision: {"evidenceRef":"saludo.py","kind":"complete"} 21:32:20Z
cierre host: ReleasedAdopted  21:32:10Z
cancelaciones: 0
e4c55db542664da48f037cfbcc354f5cf8f5412e19f73756b07c5a4bb0ce9943|acknowledged|dd407096-78ef-43e5-9859-66a1d7779acb|1|deepseek-1|deepseek|UserAdopted|ReleasedAdopted
```

Los tres criterios de `T12-runbook.md` (sección "Un host por alias de modelo", "Pasa si"):

| Criterio | Medido | Archivo de `canario/c8/` |
|---|---|---|
| Tarea en R | Tarea `dd407096-78ef-43e5-9859-66a1d7779acb`, `taskKey` `canario-saludo-20261012-1431`, solicitante `agent:main:main` con principal de remitente de Telegram. `target.adapterId` `opencode@opencode-go/deepseek-v4-pro` en `mac-local`. `inputRevision` de tipo `code` con `31e541fdb8b852a0b154d92f175bc1d8a3f22925`, que era el HEAD de `/Users/dn/dev/canario-encargos` y es el padre del commit de deepseek. Admitida a las 21:31:34Z. Resultado `ready.v1` de tipo `produced` con `evidenceRef` `saludo.py`. Decisión `complete` a las 21:32:20Z. 0 cancelaciones. | `r-tarea.txt` |
| Spool `deepseek-1` | Operación `e4c55db542664da48f037cfbcc354f5cf8f5412e19f73756b07c5a4bb0ce9943` en `acknowledged`, con `attempted_at` a las 21:31:36Z y `delivered_at` a las 21:31:54Z. Recurso `ReleasedAdopted`, y el cierre llegó a R a las 21:32:10Z. 0 incidencias. | `spool-deepseek-1.txt` |
| `saludo.py` | Deepseek hizo el commit `28693aa9b03ee1a456d53eff70ec10b892798746` a las 21:31:58Z, que agrega `saludo.py`. Su sha256 es `1a407d073ff3d0955ccf1cc83b5ae98bdd4bf2898989bc77247b35948d49c9c8`, igual al `digest` del resultado del CLI y al `evidenceContentHash` de R. `saludar("David")` regresa `Hola, David`. | `commit-28693aa.txt`, `result-sin-capability.json`, `saludo.py` |

El pane de opencode 1.18.35 (`pane-deepseek.txt`) muestra el temporal del resultado en la carpeta de `resultRef` y el resumen de deepseek, que dice que escribió el acuse en `acceptRef`. El turno de deepseek tardó 31,8 s.

Los tres intentos anteriores del mismo día fallaron. Las tres causas quedaron arregladas antes del intento 4, cada una con su PR mergeado o su paquete instalado. Las horas y los identificadores salen de las entradas del 2026-10-12 de `estado.md` y de `spool-deepseek-1.txt`.

| Intento | Hora | Qué pasó | Causa | Arreglo |
|---|---|---|---|---|
| 1 | Mensaje a las 17:38:24Z | `saludo.py` quedó escrito, pero no por la ruta gestionada. `main` llamó a `sessions_spawn` con el subagente `implementer` (corrida `ddb9cbf7`, modelo `opencode-go/deepseek-v4.1-flash`). El spool `deepseek-1` quedó con 0 operaciones. | `main` leyó `agent-dispatch`, nunca leyó `encargo-cli` y resolvió el pedido con subagentes. No se midió si el catálogo de esa sesión ya traía `encargo-cli`. | David decidió ese día que la ruta gestionada entra solo cuando el pedido dice "por CLI". La regla está en el PR #272, mergeado en `e260f300`. `mensaje-8.txt` se reescribió con esas palabras, y la copia anterior es `mensaje-8.pre-por-cli.txt`. |
| 2 | Mensaje a las 18:12:32Z | `main` siguió `encargo-cli`. `managed_tasks_submit` falló dos veces con `Managed task host identity does not match the admitted turn`. | R comparaba la sesión admitida, `agent:main:main`, solo contra la clave de política del turno. En un DM de canal a la sesión `main`, esa clave es la del remitente y nunca coincide. | R `4acb881` (B20-R, VEREDICTO-B20R-r1 APROBADO). Se instaló en la Mini a las 19:45Z (`artifacts/T12/actualizar-4acb881-20261012T194435Z.log`, `ACTUALIZADO OK`). |
| 3 | Entrega a las 19:54:16Z | Submit y admit pasaron. Tarea `3f7a8b01-dba0-4ecc-8152-fa187c6792ae`, operación `32dddc0896ae529c89fe4f0936f314b032fb70bad0f6c2b26d0254d9dbfd9ed0`. Deepseek escribió el temporal del acuse en `/tmp`, opencode abrió "Permission required" y el host no lo reportó. `main` dijo que no había host. El diálogo se rechazó con Esc a las 20:03:13Z y `main` canceló la tarea. La operación quedó `cancelled` y su recurso `ReleasedAdopted`. | El host leía el diálogo de permiso solo en operaciones `delivered`, y esta seguía `attempted`. `protocol.steps` tampoco decía en qué carpeta va el temporal. | PR #273 (B21, G `99a38b99`), mergeado en `73f76ee6`, VEREDICTO-B21-r1 APROBADO. |

### Los alias de opencode Go: certificado y cerrado el mismo día (2026-10-12)

El alias de deepseek quedó `certified` con el PR #276, y su host `deepseek-1` se relanzó sin `--canario` (entrada de las 22:13:23Z de `estado.md`). La entrada de las 22:40:55Z registra la decisión de David, en sesión: "open code go es solamente para main". Al preguntarle por el alcance eligió "Reservada para claw": la suscripción de opencode Go es solo para el modelo propio de `main` en la Mini, y los encargos "por CLI" que corren opencode en la Mac no la gastan. Confirma el alcance de su orden del 2026-10-03: "opencode debe usar solo [la suscripción de Z.AI], no la suscripción opencode go ni zen". B19 había abierto los cuatro alias `opencode@opencode-go/*` sin consultarlo.

Lo que se hizo en vivo ese día. Las horas son las de las entradas de `~/.local/state/encargos-loop/estado.md`, que no anota una hora aparte para cada paso:

- Entrada de las 22:40:55Z. El host `deepseek-1` y su sesión de opencode quedaron apagados, con 0 entregas en vuelo.
- Entrada de las 22:42:29Z. `managedTasks.hosts.mac-local.adapters` de R pasó de cinco entradas a `["opencode"]`, con `config.patch`, `baseHash` y `replacePaths: ["managedTasks.hosts.mac-local.adapters"]`, y con 0 crons corriendo. Releído después del reinicio del gateway: `enabled` en `true`, `requesters` con `main` y el mismo `deviceId`.

El repo registra el mismo cierre:

- En `coverage.json`, los alias de `deepseek-v4-pro`, `kimi-k3`, `grok-4.7` y `qwen3.8-max` están `disabled-operator-billing`. La `hostAdapterEvidence` de deepseek se conserva como historia: son las dos líneas del canario 8 de arriba.
- `host.py opencode-model` rechaza cualquier `opencode-go/*`, así que ni `lanzar-host.sh` ni `native_gateway.py` arrancan un host con uno de esos alias, aunque R lo vuelva a listar.
- La skill `encargo-cli` ofrece solo `opencode`. Si David nombra otro modelo con "por CLI", `main` le dice que hoy solo está GLM por la suscripción de Z.AI y que opencode Go está reservada para `main`.

El canario 8 queda como evidencia de que la ruta por alias funciona, no de un modelo en uso. Para "por CLI" queda un solo camino: `opencode`, con GLM 5.3 flash por `zai-coding-plan`.

Dos cosas no se hicieron. Nadie midió cuánto gastaron de opencode Go los cuatro intentos del canario 8. Y la copia de `encargo-cli` de la Mini no se publicó con este cambio (fila GO en `followups.md`).

## SUA-01 (2026-10-14)

Dos instalaciones de R en la Mini, sin cambio de esquema (sigue en 27) y sin tablas nuevas. La primera, R `073e2e5` (rebanada 7), de 04:50:41Z a 04:51:27Z. La segunda, R `65432d0` (rebanada 14), de 10:15:01Z a 10:15:33Z. Las dos con `ACTUALIZADO OK`, los mismos 30 crons y un canario por CLI con `kimi-code-plan-cn/k3` en `acknowledged` con `AbsenceVerified` (tareas `5589e361-97a2-4290-9ea0-62af837e957f` y `13d5e4d0-6a42-4ead-b892-d1b64716f08d`). Detalle, fotos y reversa en `docs/evidence/sistema-agentes-unificado/SUA-01.md`.

## Huecos encontrados en vivo

Cada hueco tiene su arreglo, su revisión y su PR o paquete de R.

| Hueco | Lo destapó | Arreglo |
|---|---|---|
| B9 | Canario 1 | Un diálogo de opencode deja la entrega `deferred`; `abandoned` libera instancia y cupo; sin cupo no se pide trabajo a R. PR #262. |
| B10 | Canario 3 | Enter solo cuando el composer muestra la referencia completa; la sesión adoptada se libera con el recibo del resultado. PR #263. |
| B11 | Canarios 3 y 4 | `managed_tasks_resolve` copia al store el brief de un hijo CLI. R `ff1709f`, VEREDICTO-B11-r1 APROBADO. |
| B12 | Canario 4 (`Managed task registration conflict`) | La redacción del transcript tapaba el campo `key` de submit, y `main` copiaba `***`. La entrada se llama ahora `taskKey`. R `ff1709f`. |
| B13 | Canario 5 | El host lee la cancelación de R (`managedTasks.host.cancellation`), rechaza el diálogo de permiso con Esc y suelta la sesión. PR #264 y R `f8316c9`, VEREDICTO-B13-r1 APROBADO. |
| B14 | Trabajadores 1 y 1b, anteriores a B9 | Un recurso adoptado cuya sesión lleva otra marca, o ninguna, queda `ReleasedAdopted`; `--close-only` cierra un spool viejo. PR #265, VEREDICTO-B14-r1 APROBADO. |
| B15 | El par de cierre (`cien_reenvios` y `crash_boundaries`: `Managed task submit input is invalid`) | `routing.py` seguía armando el submit con `key`; tras B12 R lo rechaza. Ingeniería y operaciones, que pasan ese JSON tal cual, habrían fallado al encargar. Ahora emite `taskKey`, y `test-agent-work-routing.py` da rojo con `key`. Commit `c60f689` en este PR. |

Dos derivas de despliegue se arreglaron a mano (fila B14, despliegue, de `followups.md`):
- `~/bin/progress-events.py` era una copia vieja sin los campos del ACK durable. La copia anterior quedó en `~/.local/state/agent-work-host/progress-events.py.pre-c6`.
- El host publicaba su progreso en un directorio que nadie publicaba. Ahora usa `~/.local/state/runbook-progress-events`. El comando anterior quedó en `host-cmd.txt.pre-latido`.

## Contadores

### Ventana de 30 minutos (plan `:316`)

Del 2026-10-11 19:44:31Z a las 20:14:37Z (30 min 6 s). Antes de abrirla, los 7 trabajadores de prueba estaban cerrados en R y no había turnos en vuelo. Las fotos las tomó `ventana-30/foto.sh`, y la atribución está en `ventana-30/atribucion.txt`.

| Contador | Inicio | Fin |
|---|---|---|
| Eventos de la sesión `agent:main:canario-encargos` | 302 | 302 |
| Eventos de todas las sesiones de `main` | 18356 | 18422 |
| `managed_tasks` | 7 | 7 |
| `managed_task_waits` | 0 | 0 |
| `managed_task_incidents` | 3 | 3 |
| `managed_task_host_closures` | 7 | 7 |
| Tokens de opencode en el pane `canario` | 41.0K | 41.0K |
| Líneas de `host.log` | 894 | 894 |
| Procesos `openclaw agent` en la Mac | 0 | 0 |
| PID del host | 84745 | 84745 |
| Crons vigía habilitados | `bids-02-vigia` | `bids-02-vigia` |

- Los 66 eventos nuevos de `main` son todos de `agent:main:cron:915213a2-c6f8-472c-b2c5-fedc49ed28bf`, que es `bids-02-vigia`, cada 5 min.
- Llamadas al proveedor en la ventana, contadas por los eventos `provider.payload.measured` de las bases de todos los agentes de la Mini: 16, todas de esa misma sesión de `bids-02-vigia`. Ninguna de la sesión del canario.
- Conclusión: cero inferencia atribuible a vigilar encargos.

### R al cierre

- 7 tareas: 6 raíces y un hijo de corrección.
- 5 decisiones: 4 `complete` y 1 `continue`.
- 3 incidencias: `invalid-result` en el canario 1b, y `permission-required` y `deadline-missed` en el canario 5.
- 2 cancelaciones: canarios 1 y 5.
- 7 cierres del host, todos `ReleasedAdopted`. Ninguno `CleanupPending`.
- 0 esperas abiertas.

## Recursos que quedan

- **R.** Ningún cupo tomado. Las 7 filas de `managed_task_admissions` siguen en `admitted`, y sus 7 reservas de admisión en `reserved`. No retienen cupo: `managedTaskAdmissionRetainsBudgetSlot` (R, `managed-task.host-closure.worker.ts`) solo cuenta una admisión CLI de la generación actual si no tiene cierre o si su cierre es `CleanupPending`.
- **Mac.** Los tres spools están en esquema 2, y todos sus recursos están `ReleasedAdopted`: `mac-local` (1, operación `abandoned`), `mac-local-b` (1, `acknowledged`) y `mac-local-c` (5; 4 `acknowledged` y 1 `cancelled`). La sesión `canario` de opencode sigue viva (`opencode.exe`). Es del operador; el host ya no la retiene.
- **Respaldos en la Mac.** `host.sqlite.pre-b14` en `mac-local` y `mac-local-b`, `respaldo-pre-b13-20261011T151514Z`, `respaldo-pre-b14-20261011T192709Z` y `host-b-antes-de-reabrir.sqlite`, todos en `~/.local/state/agent-work-host/`.
- **Mini.** Cinco fotos en `~/.openclaw/respaldos/` (2,5 GB): `pre-f1c5f34`, `pre-19c2ed1`, `pre-4b9785c`, `pre-ff1709f` y `pre-f8316c9`. Tienen conversaciones. Quedan los paquetes de la última instalación en `/tmp/openclaw*.tgz` y `/tmp/rold/`, y 7 briefs en `~/.openclaw/workspace/managed-instructions`.

## Despertares viejos (plan `:312`, `:317` y `:318`)

- La entrada del canario no tenía despertares viejos: `legacyCrons: []`, así que el corte no suspendió nada (`suspended: {}`) y no hay nada que retirar.
- Los 30 crons habilitados son los mismos antes y después de cada instalación y del corte. Ninguno estaba corriendo en la revisión de hoy.
- El único vigía del gateway es `bids-02-vigia`. Se conserva, porque la ruta de encargos no cubre a `bids-02`: su implementador es el CLI `muse`, fuera de la cobertura, y su revisor es la ventana abierta de Claude. Su `PROMPT.md` nombra el cron, pero no dice por qué no usa la ruta, porque se escribió el 2026-10-09, antes de que existiera.
- El recreador de vigías era la plantilla `prompt-claw`. Su §7 (`~/.claude/skills/prompt-claw/SKILL.md`) dice ahora que un loop sobre la ruta de encargos no crea `<loop>-vigia`, y que un loop que no la puede usar conserva su vigía y lo declara, como `bids-02`.

## Cobertura efectiva

- Certificado y en vivo: solo `main` → `mac-local`/`opencode`, en una sesión adoptada (B8). Al cierre era la única combinación con `certified` en `coverage.json` (`hostAdapterCoverage`).
- Después del cierre, el 2026-10-12, `main` → `mac-local`/`opencode@opencode-go/deepseek-v4-pro` quedó `certified` por el canario 8, y David lo cerró ese mismo día junto con los alias de `kimi-k3`, `grok-4.7` y `qwen3.8-max` (sección Canarios). Los cuatro están `disabled-operator-billing`, y `main` → `mac-local`/`opencode` vuelve a ser la única combinación `certified`.
- No habilitados, como limitación:
  - En `mac-local`, los adaptadores `claude_fable`, `claude_opus`, `kimi_k3`, `kimi_coding`, `codex`, `zcode` y `grok`.
  - Todo `windows-remote`.
  - Las rutas entre agentes nativos (`ingenieria` → `adversary`, `operaciones` → `ingenieria`) y `ingenieria` → `windows-remote/codex`. En `coverage.json` siguen con `certified: false`.
  - Los agentes con primario `opencode-go/deepseek-v4.1-flash`, porque R rechaza un plugin dentro de un encargo (fila B5/T12).
  - Ningún otro solicitante que `main`.
- Ningún loop real de claw corre todavía por la ruta. La entrada adoptada es el canario.

## Checklist posterior

Corrido una vez, el 2026-10-11 a las 20:20Z, solo con lecturas.

| Comprobación | Comando | Resultado |
|---|---|---|
| Versión en la Mini | `ssh gon@100.73.187.5 '~/.openclaw/bin/openclaw --version'` | `OpenClaw 2026.9.7 (f8316c9)` |
| Build instalado | `cat …/openclaw/dist/build-info.json` en la Mini | `commit` `f8316c9c867e…` |
| Esquema | `sqlite3 -readonly ~/.openclaw/state/openclaw.sqlite 'pragma user_version'` | `27` |
| Salud | `openclaw health --json` desde la Mac | `ok: true` |
| Config de encargos | `openclaw gateway call config.get`, solo `managedTasks` | `enabled: true`, `requesters: ["main"]`, `mac-local: ["opencode"]`, `runTimeoutSeconds: 3600` |
| Crons | `openclaw cron list --json` | 30 habilitados, 0 corriendo, vigía solo `bids-02-vigia` |
| Cierres en R | consulta a `managed_task_host_closures` | 7 de 7 `ReleasedAdopted` |
| Host vivo | `pgrep -fl 'native_gateway.py --openclaw-bin'` | PID 84745, checkout `2be0f55` |
| Spools | `sqlite3 -readonly <spool>/host.sqlite` | 3 en esquema 2, 7 recursos `ReleasedAdopted` |
| Cliente de progreso | `cmp ~/bin/progress-events.py scripts/mac/progress-events.py` | iguales |
| Directorio de progreso | `host-cmd.txt` | `--progress-state-dir /Users/dn/.local/state/runbook-progress-events` |
| Sesión adoptada | `tmux -L agent-work display-message -p -t '=canario:' '#{pane_current_command}'` | `opencode.exe` |

## Par de aceptación

Una sola corrida al cierre, sobre G `c60f689` y R `f8316c9` (con R recompilado a ese commit): 33 de 33 casos con rc=0, de 20:30:27Z a 21:30:22Z. La primera corrida, sobre `2be0f55`, se detuvo porque destapó B15. El recibo está en `acceptance-pair.json` y los logs en `par-final/`. `bash scripts/tests/test-agent-work-e2e.sh acceptance` da OK con el par nuevo en `acceptance.md`.

## Lo que no se pudo comprobar

- El contador del proveedor no es el panel web de opencode. Es la medida de cada llamada que R guarda en la Mini (`provider.payload.measured`), más el contador de tokens de opencode en su pane.
- El camino automático del host al tablero después del arreglo. El host publica ahora en el directorio del latido, pero ningún encargo con `progressBinding` corrió después de ese cambio.
- Cómo terminó el hijo `985012e2` del canario 3 con R `4b9785c`, antes del arreglo B11. La bitácora del loop no lo registra.
