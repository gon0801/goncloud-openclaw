# runbook-progress-events.v1

Este contrato gobierna **corridas nuevas**. El gateway guarda hechos por
`corrida` mediante `runbook.progress.event` (`operator.write`) y genera el
documento `runbook-progress.v1` que ya leen `get`, `list`, el HTML y las rutas
JSON. Un documento antiguo sin historial sigue usando `runbook.progress.set`;
una corrida con historial rechaza ese método con `event-managed`.

## Escritura

Cada comando lleva `kind`, `id`, `corrida` y `at` (ISO UTC). `id` es estable al
reintentar. Los comandos posteriores a `run.opened` llevan
`expectedRevision`; el gateway devuelve `{ok:true,revision,duplicate}`. Un ID
repetido con el mismo contenido devuelve la primera revisión, aunque el
`expectedRevision` del reintento sea distinto. Un ID repetido con contenido
distinto se rechaza. Una revisión obsoleta devuelve `revision conflict` y la
revisión actual, sin cambiar el historial. El cliente vuelve a leer y decide
si su transición sigue siendo válida. El gateway confirma el registro antes de
responder éxito; reconstruye la proyección si quedó atrás tras una caída.

| `kind` | Datos adicionales | Efecto |
|---|---|---|
| `run.opened` | `doc` validado, `roundBudget` por carril, `phaseAlias?:true` | Crea la corrida; el alias de fase es exclusivo. |
| `part.added` | `carril`, `queueItem?`, `roundBudget?` | Amplía el alcance declarado. |
| `round.started` | `carril`, `intento`, `ronda`, `baseSha` | Abre una ronda identificada. |
| `round.ready` | `carril`, `intento`, `ronda`, `sha`, `evidence` | Persiste LISTO para el SHA entregado. |
| `round.verdict` | los mismos identificadores, `verdict` (`aprobado` o `cambios`), `evidence` | Cierra esa ronda solo si revisó el SHA de LISTO. |
| `part.status` | `carril`, `estado`, `que?`, `pr?`, `nextStep?`, `evidence?` | Cambia el carril; mergeado exige aprobación/evidencia salvo un encargo manual declarado. |
| `part.worker` | `carril`, `worker`, `note`, `generation` para el productor nativo | Actualiza el trabajador sin sobrescribir otros carriles. La tenencia nativa crece en cada relevo y ordena dos cambios ocurridos en el mismo segundo. |
| `attention.changed` | `necesaria`, `motivo` | Actualiza la atención requerida. |
| `run.closed` | `resumen` | Cierra la corrida. |

`sha` y `baseSha` son commits hexadecimales completos de 40 caracteres;
`evidence` tiene `{ref,sha}` con una referencia relativa `evidence/...` y el
SHA-256 del archivo de evidencia inmutable. LISTO, VEREDICTO, intento y número
de ronda deben coincidir. El silencio del panel tmux y un aviso atendido no son
veredictos. El historial se consulta con
`runbook.progress.events.get({corrida,after,limit})` (`operator.read`).

Para `part.worker` con `source: "native"`, `generation` es un entero no negativo
que crece por tenencia del carril. El gateway rechaza una generación anterior o
repetida aunque llegue con una revisión vigente. Los otros productores que no
declaran generación conservan orden por instante; un empate se rechaza para
evitar reemplazar un trabajador sin saber cuál es posterior.

La proyección calcula `cola[].avance` como **estimación de actividad**:
mergeado vale 100; antes del merge, las rondas con veredicto se dividen por el
presupuesto declarado y se limitan a 99. Sin presupuesto, no se inventa un
porcentaje. El `%GLOBAL` visual sigue promediando los ítems elegibles de la
cola. El porcentaje de los avisos conserva otro significado: tareas del plan
o partes realmente mergeadas; una revisión cerrada no cuenta como entrega.

## Cliente de la Mac

`scripts/mac/progress-events.py queue-event --event-json <archivo>` guarda el
comando antes del envío; `record-ready` y `record-verdict` guardan una copia
inmutable de la evidencia y encolan el evento correspondiente. `publish
--corrida <id>` reintenta la cola con los mismos IDs incluso después de una
caída de red. `sync --corrida <id> --estado <estado.md> --phase-json
<fase.json>` lee la revisión aceptada y genera ambas vistas desde ella; el
JSON de fase conserva el formato `runbook-progress.v1` y su revisión/hora van
en `<fase.json>.revision.json`. Si las revisiones no coinciden tras una caída a
mitad de sincronización, repetir `sync` las repara.

Cuando el gateway sustituye una importación histórica, el cliente guarda en
`superseded/<id>.superseded.json` el motivo y el SHA-256 del evento original.
Después copia el evento a `superseded/<id>.json` y lo retira de `queue/`.
Tras una caída, `publish` valida el ID, la corrida y el hash guardados, y
termina el archivado antes de consultar el gateway. Un reintento conserva
la primera decisión y deja pasar los eventos siguientes. Si los metadatos
no permiten comprobar la identidad, el cliente conserva la cola y muestra
la ruta del registro que requiere reparación. Un rechazo sin decisión
guardada conserva la validación de los carriles actuales.

Los runbooks futuros abren el tablero con `run.opened` como primer comando,
antes de lanzar agentes. Cada nueva ronda se abre, entrega y revisa con los
comandos anteriores; cada cierre de bloque o atención se publica como evento.
Los runbooks históricos no se reescriben retroactivamente. Una migración activa
importa un documento validado, asigna una `corrida` y, si debe conservar la
ruta antigua, reclama su alias de fase explícitamente.
