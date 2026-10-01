# Recuperar importaciones interrumpidas sin bloquear el tablero

> Ejecuta este plan con `superpowers:executing-plans`, tarea por tarea.
> Las casillas requieren evidencia antes de marcarse como terminadas.

El objetivo es que una importación sustituida deje pasar los eventos siguientes,
incluso después de una caída y un cambio de carriles en el gateway.
Implementa la recuperación local antes de cualquier consulta remota.
Conserva la decisión original y comprueba que corresponde al mismo evento.

Usa Python 3 y las funciones de persistencia existentes, sin nuevas dependencias.
Lee el [diseño de progreso por eventos](../specs/2026-09-30-progress-events-design.md)
y el [contrato del cliente](../../spec/runbook-progress-events.v1.md#cliente-de-la-mac).
Este plan completa el [plan general](2026-09-30-progress-events.md) del PR #232.

## Preparar el cambio

- [x] Trabaja en `.worktrees/fix-progress-events`, rama `fix/progress-events`.
      Ejecuta `git status --short` y `git rev-parse HEAD` desde ese directorio.
      Al redactar este plan, HEAD es `7a2a358` y hay cambios preparados sin commit.
- [x] Revisa `git diff --cached` antes de editar. Conserva los cambios anteriores.
      Usa el árbol actual como punto de reproducción del bloqueo pendiente.
- [x] Mantén el trabajo dentro del PR #232. No declares el arreglo terminado
      ni integres el PR mientras el bloqueo sea reproducible.

Aplica el cambio en estos archivos:

| Archivo | Trabajo |
|---|---|
| `scripts/mac/progress-events.py` | Vincular la decisión al evento y recuperar el archivado antes del envío. |
| `scripts/tests/test-progress-events-client.py` | Reproducir la caída, comprobar los reintentos y preservar eventos ajenos. |
| `docs/spec/runbook-progress-events.v1.md` | Documentar el orden de recuperación y el tratamiento de registros inválidos. |
| `docs/superpowers/plans/2026-09-30-progress-events.md` | Registrar la evidencia de cierre del bloqueo. |

No cambies la fórmula de avance ni el contrato RPC para resolver este bloqueo.
Conserva los IDs derivados del contenido en `scripts/mac/corrida/lib.sh`.
Reutiliza las pruebas de productores y del tablero durante la validación.
No inventes rondas históricas de U3a que carezcan de evidencia.

## Fijar las reglas de recuperación

- [x] Guarda una decisión con `schema: "progress-import-superseded.v1"`, `corrida`,
      `id`, `eventHash`, `reason`, `revision` y `at`.
      Calcula `eventHash` con SHA-256 sobre `encoded(evento_original)`.
      Lee ese evento de la cola, antes de añadir una revisión de envío.
- [x] Valida el esquema, la corrida, el ID, el tipo `run.opened` y el hash.
      Admite los motivos `legacy projection changed or invalid` y `corrida ya existe`.
      Exige `importLegacy: true` para el primer motivo.
      Conserva el motivo, la revisión y la fecha originales al reintentar.
- [x] Trata una decisión válida como definitiva para ese evento.
      No vuelvas a consultar el gateway para decidir si debes archivarlo.
      Sin decisión previa, conserva las validaciones remotas actuales.
- [x] Conserva una copia durable del evento antes de retirarlo de `queue/`.
      Evita que un archivado sobrescriba otro evento con el mismo ID.
      Usa `create_immutable` para crear la copia y sincroniza los directorios
      después de retirar la entrada de la cola.

Resuelve cada estado con estas reglas:

| Estado local | Acción |
|---|---|
| Cola sin decisión ni archivo | Publica y evalúa la respuesta del gateway. |
| Decisión válida y evento en cola | Completa el archivado sin consultar el gateway. |
| Archivo idéntico y copia en cola | Conserva el archivo y retira la copia de la cola. |
| Archivo idéntico y cola ya retirada | Termina el reintento sin publicar otra vez. |
| Decisión inválida, hash distinto o archivo con otro contenido | Devuelve un error que nombre el ID y la ruta. Conserva los archivos. |
| Metadatos antiguos sin hash y sin archivo que pruebe el contenido | Devuelve un error explícito. No deduzcas identidad solo por el ID. |

No presentes los metadatos antiguos incompletos como una recuperación exitosa.
Si aparecen en el estado real, registra sus rutas y resuelve su migración antes
de desplegar. El despliegue no debe dejar una cola conocida bloqueada.

## Reproducir el bloqueo pendiente

- [x] Añade `test_recovery_ignores_changed_remote_lanes` a `ProgressClientTest`.
      Encola `opened-old` con B3. Provoca una caída después de guardar la decisión.
      Al reintentar, prepara un gateway que ahora devuelve una corrida con B4.
      Comprueba que `opened-old` queda archivado y sale de la cola.
      Comprueba que la recuperación de ese evento no llama al gateway.
- [x] Encola después un evento vigente y comprueba que el mismo `publish`
      lo envía. Cuenta las llamadas por ID para distinguir ambos eventos.
- [x] Ejecuta `PYTHONDONTWRITEBYTECODE=1 python3 scripts/tests/test-progress-events-client.py ProgressClientTest.test_recovery_ignores_changed_remote_lanes`.
      Guarda el fallo observado antes de editar el cliente.
      El fallo esperado es el rechazo por carriles distintos o la llamada remota
      que la prueba prohíbe. Un error de preparación de la prueba no demuestra el bug.

## Implementar la recuperación antes del envío

- [x] Añade `recover_superseded_import(base: Path, path: Path, event: dict) -> bool`
      en `scripts/mac/progress-events.py`.
      Devuelve `True` cuando termina una sustitución y `False` cuando no hay
      decisión ni archivo previo. Rechaza los estados inconsistentes con `ValueError`.
- [x] Llama a esa función desde `publish`, después de validar corrida e ID
      y antes de leer intentos, consultar revisiones o llamar al gateway.
      Continúa con el evento siguiente cuando devuelva `True`.
      No cuentes una importación sustituida como un evento publicado.
- [x] Actualiza `supersede_import` para guardar la decisión vinculada al contenido
      antes de archivarlo. Reutiliza la misma recuperación para completar el trabajo.
      Elimina la lógica duplicada de recuperación que quede en esa función.
- [x] Haz que `queue_event` reconozca una decisión válida pendiente de archivado.
      No vuelvas a poner ese evento delante de una importación vigente.
      Rechaza el mismo ID con contenido distinto.
- [x] Tolera que otro publicador termine el mismo archivado durante el reintento.
      Considera éxito solo si el archivo final corresponde al mismo evento.
      Conserva la primera decisión válida cuando ambos publicadores intenten crearla.
- [x] Ejecuta de nuevo la prueba del bloqueo. Exige salida cero y las aserciones
      de archivo, cola y llamadas remotas satisfechas.

## Probar las caídas y los límites de identidad

Añade estos casos a `ProgressClientTest` y ejecútalos durante la implementación:

| Caso propuesto | Resultado exigido |
|---|---|
| `test_recovery_survives_each_archive_boundary` | Interrumpe después de la decisión, después de crear el archivo y después de retirar la cola. Cada reintento conserva el evento y termina. |
| `test_recovery_completes_without_gateway` | Una decisión válida se recupera con el gateway desconectado. Los eventos aún no enviados permanecen pendientes. |
| `test_recovery_rejects_mismatched_identity` | Otra corrida, otro ID, otro hash o un evento distinto producen error sin retirar ni sobrescribir archivos. |
| `test_recovery_rejects_unverifiable_metadata` | Metadatos incompletos o corruptos no autorizan el archivado. El error identifica el registro. |
| `test_recovery_converges_for_two_publishers` | Intercala dos publicadores con barreras controladas. Ambos convergen en el mismo archivo y conservan la primera decisión. |
| `test_requeue_during_pending_recovery_is_idempotent` | Encolar de nuevo el mismo evento no lo republica. Otro contenido con el mismo ID se rechaza. |

- [x] Conserva las pruebas de importación incompatible sin decisión previa.
      Deben seguir rechazando la corrida ajena.
- [x] Adapta la prueba existente de caída con carriles iguales al nuevo contrato.
      Comprueba que repetir la recuperación conserva los mismos bytes de decisión.
- [x] Ejecuta `bash scripts/tests/test-progress-events-client.sh`.
      Exige salida cero y ningún fallo de `unittest`.

## Verificar el comportamiento del tablero y cerrar el bloque

- [x] Ejecuta `bash scripts/tests/test-native-progress-worker.sh` y
      `bash scripts/tests/test-tablero-trabajo.sh` desde la raíz del worktree.
      Exige salida cero. Comprueba que la importación vigente deja pasar los eventos.
- [x] Ejecuta `node --test --test-name-pattern='eventos de rondas actualizan' tablero-runbook/index.test.ts`
      con la versión de Node que usa el repo.
      Exige 67% con B1 y B2 mergeados, y B3 activo.
      Exige 78% tras el veredicto de la primera ronda de B3, sin cerrar B3.
- [x] Conserva la cobertura de `sync`, LISTO y VEREDICTO en las pruebas del cliente.
      Comprueba la misma revisión y los mismos estados en JSON y `estado.md`.
      Comprueba que la evidencia sobrevive al reintento con el SHA correspondiente.
- [x] Documenta la recuperación en el contrato del cliente.
      Registra comandos, resultados y SHA en el plan general.
- [x] Solicita una revisión independiente del cambio de recuperación con un
      revisor distinto al de la última ronda. Adjunta la reproducción original.
      Agrupa los hallazgos y aplica la sección 4 de
      [loop-autopilot.md](../../runbooks/loop-autopilot.md).
      Si vuelve el mismo bloqueo en dos rondas seguidas, detén la implementación.
- [x] Ejecuta los hooks con `pre-commit run --files` y los archivos del commit.
      Corrige los fallos antes de crear el commit. No uses `--no-verify`.
- [x] Valida la batería completa una sola vez sobre el último SHA de código
      en CI. `d506ffc` pasó los tres shards, el contrato y el gate en
      [Quality run 36797045197](https://github.com/gon0801/goncloud-openclaw/actions/runs/36797045197).
      En este PR mixto, un commit documental posterior también activa la
      batería del PR completo porque el clasificador compara base y punta.
- [x] Informa por separado si el código está verificado, si el PR está integrado
      y si el gateway real usa el cambio. La prueba local no demuestra despliegue.

Ejecuta estas tareas en serie porque comparten el cliente y su prueba de recuperación.
Paraleliza únicamente las verificaciones independientes después de estabilizar el código.
Mantén los seguimientos de Quality y los demás hallazgos del plan general visibles.
Este plan termina con el bloqueo corregido y el PR verificado para integración.
El merge y el despliegue conservan las autorizaciones y los controles del trabajo original.
