# SUA-05, ingeniería y calidad: diseño y corte en rebanadas

Fecha: 2026-10-16. Estado: diseño propuesto, sin código. Ronda 3: con los hallazgos de VEREDICTO-SUA05-diseno-r1 (B1 a B4, M1 a M9) y de VEREDICTO-SUA05-diseno-r2 (B5, M10 a M15). Lo escribió el coordinador (Claude). Lo revisa el implementador asignado (GLM 5.3 Flash, relevo de Muse Wonder sin cuota) antes de implementar: no es autor de este documento.

Bases leídas: G `origin/main` `994243f6` (SUA-04 G5 mergeado). R `/Users/dn/dev/wt/r-sua02-c-gate`, HEAD `7b3db54226bf`. `gon0801/goncloud-pr-review` en el sha que fijan los workflows de G, `f255b738`. Los hechos con su línea están en la hoja de terreno del coordinador (`~/.local/state/sua-loop/prep/sua05-terreno.md`); aquí van los que deciden el diseño.

Documentos que manda este diseño y que no cambia:
- El bloque "SUA-05" del [plan](../plans/2026-10-05-sistema-agentes-unificado.md) (líneas 719-800), con su "Verificar" y las invariantes I12, I13 e I21.
- El [contrato](../../spec/sistema-agentes.v1.md) `sistema-agentes.v1`: `meta.qualityPolicy` (línea 127) y "Política de rondas" (líneas 370-372).
- Las reglas de `~/.claude/CLAUDE.md`: "REGLAS DE CALIDAD" (regla 4) y "Revisión cruzada" (quitada en todos los repos).
- Los diseños de SUA-01 a SUA-04 y sus recibos.

Palabras con un solo sentido en este documento:

| Palabra | Sentido |
|---|---|
| ronda | Una corrección de una unidad después de un intento fallido. R la cuenta como `rondas:<unitId>` (SUA-02). |
| bloqueante | Un hallazgo de seguridad, datos, regla innegociable, conducta pedida rota o prueba que no discrimina, con el comando que lo reproduce (regla 4). La severidad que pone un bot no lo hace bloqueante: lo hace la adjudicación. |
| adjudicar | Decir de cada hallazgo de un bot si es bloqueante, no bloqueante o no aplica, con su porqué, en el PR. |
| head | El SHA de la punta del PR en el momento del merge. |
| completo | Una revisión que vio todos los archivos del diff que no excluye una regla declarada. |

## 1. Lo que existe hoy

### La política de rondas ya vive en R, y en G solo como texto

- R tiene la tabla: `ROOT_QUALITY_POLICIES = {"quality-kit.regla4": {version: "quality-kit.regla4", roundsPerImplementer: 5, relays: 1}}` (`src/agents/tasks/managed-root.decide.ts:36-38`). El paso 6 del decidir cuenta `rondas:<unitId>` y, al llegar a `5 * (1 + relays + bloques)`, levanta `NECESITA_DAVID` con `seguir`, `omitir` y `cancelar` (`:549-568`). La apertura de una raíz rechaza una versión fuera de la tabla: `managed-root.worker.ts:149` llama a `rootQualityPolicy` (`managed-root.decide.ts:40-44`), y `managed-root.store.ts:88-100` es el envoltorio del host que despacha hacia el worker.
- R guarda el resultado de cada intento (la proyección de cada tarea lleva su `evidenceRef` o `findingsRef`, `managed-task.projection.ts:29, 108`), pero la necesidad de corrección que levanta el decidir lleva solo el `findingsRef` del último intento fallido (`managed-root.decide.ts:580`, mapa `failedByResult` de `:189`). Nada junta los hallazgos de las rondas anteriores.
- En G no hay archivo de política. `qualityPolicy` solo lo valida el contrato como un objeto con `version` de texto (`scripts/sistema_agentes/contrato.py:252`): cualquier texto pasa.
- La frase de David está en `docs/evidence/sistema-agentes-unificado/revision-2026-10-12/decisiones-para-david.md:27`: "regla 4 de quality-kit con tope 5+5. La propuesta de cuatro ciclos queda inactiva."
- `docs/runbooks/loop-autopilot.md` §4 (líneas 86-121) sigue con lo que la política no trae: `cross-review.ps1` (:19, :91, :106), cambio de revisor en cada ronda (:102), rondas sin tope (:111), paro por bloqueante repetido (:112) y el subagente propio cuando el script falla (:115). Las líneas :201 y :227 todavía mandan contestar "con la tabla de preaprobaciones".

### El merge es una orden a mano

- Se mergea con `gh pr merge --squash --match-head-commit <SHA>` cuando CI y CodeRabbit aprueban y los bloqueantes están resueltos (`loop-autopilot.md:138`, SKILLs `saikit-cierre-pr`, `saikit-merge-route`, `post-merge-closure`). Todos los agentes y el coordinador usan la misma cuenta de GitHub (`docs/runbooks/base-openclaw.md:156`: "Merge y deploy sin permiso adicional"). Ningún script lee los checks del head, el resultado del bot ni compara el SHA.
- En el head de un PR quedan check-runs de `github-actions` (`clasificador`, `shards (1/5, 1)` a `shards (5/5, 5)`, `ci-contract`, `gate` y `reconcile`; este último se salta en drafts, `ai-review-publish.yml:39-45`) y un **commit status** de CodeRabbit (medido en el head `a3967285` de #321). El bot ai-review **no deja check-run** (solo crea y edita comentarios, `review.py:2600-2619`): su resultado es el comentario fijo que firma `github-actions[bot]`, con `<!-- ai-review:sticky -->`, `<!-- ai-review:completion=<sha40>:(complete|partial) -->` y el bloque `<!-- ai-review:findings={json} -->` (schema 3: `completion`, `findings[].severity` y `findings[].status.kind` `open|resolved|dismissed`; existe también una forma legada sin schema, `review_domain.py:439-459`). Ese bloque es la memoria del PR: guarda los hallazgos de todos los pushes con su estado.
- Un hallazgo se descarta con un comentario `ai-review: descartar F<n>` (`review.py:154-161`); descartado no vuelve, y el bot solo acepta el descarte de alguien con permiso de escritura verificado por la API (`review.py:436-447, 495-497`).
- Lo que se vio en esta sesión: el worker de #321 terminó la revisión y murió al cerrar su proxy (`litellm ... timed out after 10 seconds`); el comentario fijo se quedó con la revisión del head anterior (y la solicitud nueva en `pending_requests`) hasta que el coordinador re-corrió el job. Un merge que solo mirara checks verdes no se habría enterado.
- El mismo día #322 se mergeó con dos hallazgos `Major` de CodeRabbit en comentarios en línea que nadie leyó; uno era de datos (una reversa que borraba una edición del dueño) y se arregló después en #323. Y #321 se mergeó con un `Medium` del bot abierto, triado en un comentario pero sin descarte.

### El diff se recorta y la marca dice completo

- El worker fija `MAX_DIFF_BYTES=1500000` y `strict_budget=False` (`review.py:1060-1063`). Con eso, un archivo que no cabe sale con causa `budget` (`review_context.py:936-951`), y la cobertura queda `COMPLETE_CLAIM` porque solo `presupuesto` la baja a `PARTIAL` (`review_context.py:963-968`). El comentario avisa "N archivo(s) quedaron fuera por tamaño del diff" (`review.py:669-672`), pero la marca que lee una máquina dice `complete`.

### CI y corpus

- `quality.yml`: clasificador, shards (5, `SHARDS_N` fijo, reparto por `scripts/ci-duraciones.tsv`), ci-contract y gate. El gate exige la unión exacta de los cinco shards contra el inventario (`scripts/valida-union-shards.sh`).
- El carril rápido deja pasar el corpus sin su checker: `docs/evidence/corpus-rendiciones.tsv` casa con `docs/evidence/**/*.tsv` (`scripts/ci-fast-allowlist.txt:32`), un cambio solo a ese archivo es `fast`, y en `fast` no corren los shards, donde vive `verify-corpus` (`run-checks.sh:96`).
- `scripts/tests/test-ci-coverage-contract.sh` corre dos veces por PR: en el job `ci-contract` (`quality.yml:326`) y como entrada del glob de los shards (`run-checks.sh:82-85`).

### El revisor por CLI no escribe la fuente

- En opencode, un perfil sin `writesSource` corre con `permission.edit: "deny"` y en un clon desechable, desprendido en `inputRevision.sha` (`sesion.py:231-272, 326-330`; `native_gateway.py:379-400, 710-719`). En claude, con `--restricted --tools` sin Edit ni Write y el sandbox (SUA-04 G7, M-23 y M-24). El shell de opencode no está confinado (`sesion.py:331-339`): escribe en su corrida, que se borra.
- `review.v1` es `{"verdict":"approved","evidenceRef"}` o `{"verdict":"changes","findingsRef"}` (`host.py:345-348`). El archivo de `findingsRef` no tiene forma: es texto.
- `progress_bridge.py:74-97` acepta `aprobado` y `cambios`, mientras el contrato dice `approved` y `changes`.

## 2. Lo que falta, punto por punto contra el bloque

| Paso del plan | Qué falta |
|---|---|
| 1. Revisión independiente, resultados tipados, diff completo, escritura restringida | Hallazgos con forma en `findingsRef`; un `approved` con un bloqueante en su evidencia no aprueba; el recorte del bot baja la marca a `partial`; `progress_bridge` con los veredictos del contrato. La escritura restringida ya está (SUA-03/04): se cita, no se rehace. |
| 2. Rondas como datos | El archivo versionado en G, su paridad con la tabla de R, el contrato que rechaza una versión desconocida y el recibo para cambiarla. Los hallazgos acumulados de la unidad (R hoy pasa solo el último). El contador por linaje y la escalación ya están en R. |
| 3. Merge del head exacto | Un comando que lee checks, status de CodeRabbit, comentario del bot del mismo SHA y la adjudicación, y mergea con `--match-head-commit`. Retirar el texto de preaprobaciones. |
| 4. Push, draft, reintento, corrección, rebase, ready | La receta por repo y el reintento acotado de un job de infraestructura. Separar la autoridad de merge de las respuestas a diálogos del CLI. Push, corrección y ready siguen el flujo normal de GitHub (`docs/runbooks/base-openclaw.md:156`) y la política de rondas: no piden pieza nueva. |
| 5. Corpus y duplicado | El corpus sale del carril rápido; `test-ci-coverage-contract` corre una vez; pruebas de inventario y de shard vacío. |
| 6. Retiro de `cross-review` | Reescribir `loop-autopilot.md` §4 con la política nueva. |

## 3. Quién es dueño de cada cosa

| Cosa | Dueño | Por qué |
|---|---|---|
| Tabla de políticas y contador de rondas | R | Ya está ahí (SUA-02) y es donde vive la raíz. |
| El archivo de política versionada | G | Es el que leen los humanos y los instaladores; su paridad con R se prueba. |
| La marca de completitud del bot | goncloud-pr-review | El recorte se decide ahí. G solo fija el sha nuevo. |
| El comando de merge y la receta por repo | G | Es el repo que hoy mergea a mano; las recetas de otros repos viven en G como datos. |
| Carril rápido, shards y corpus | G | `quality.yml`, `clasificar-cambio.sh` y `run-checks.sh` son de G. |

## 4. El diseño elegido

### 4.1 La política de calidad como datos

Archivo nuevo `docs/evidence/agent-work/politica-calidad.json`, al estilo de `proveedores-permitidos.json`:

```json
{
  "schema": "agent-work.calidad.v1",
  "activa": "quality-kit.regla4",
  "versiones": {
    "quality-kit.regla4": {
      "roundsPerImplementer": 5,
      "relays": 1,
      "agrupar": "los hallazgos se juntan y se corrigen en una ronda por bloque",
      "reabre": "solo un bloqueante, con el comando que lo reproduce",
      "bloqueanteNuncaEnFila": true,
      "noBloqueante": "se corrige en la misma ronda si es de una línea; si no, fila del plan nombrada en el PR",
      "revisorExcluyeAutores": true,
      "segundoModelo": false,
      "decision": {"by": "David", "on": "2026-10-12", "ref": "docs/evidence/sistema-agentes-unificado/revision-2026-10-12/decisiones-para-david.md:27", "quote": "regla 4 de quality-kit con tope 5+5. La propuesta de cuatro ciclos queda inactiva."}
    }
  }
}
```

- No trae rotación de revisor ni paro por bloqueante repetido: un bloqueante que vuelve cuenta como otra ronda, hasta el tope (plan, paso 2).
- `contrato.py` valida `meta.qualityPolicy.version` contra `versiones` del archivo: una versión que no está ahí es `quality-policy-unknown`, como en R.
- Paridad con R: una prueba lee `ROOT_QUALITY_POLICIES` de `managed-root.decide.ts` en `AGENT_WORK_RUNTIME_SOURCE` y exige las mismas versiones con los mismos números. Sin R (los runners de CI no lo tienen), se salta con su motivo, como las de ruta viva; por eso el recibo de H1 trae su salida verde corrida en la Mac.
- Hallazgos acumulados (plan, paso 2). Por PR los guarda el bot en su memoria (todos los pushes, con su estado) y la adjudicación del lead en el PR (4.4): no se copian a otro lado. Por unidad de una raíz, R pasa de `findingsRef` (el último) a `findingsRefs`: la lista ordenada de los refs de hallazgos de todos los intentos fallidos de la unidad. Se recuperan con una consulta nueva sobre `managed_root_attempts` (`managed-root.db.ts:69-78`) y las proyecciones de sus tareas, donde el ref viaja como `evidenceRef` (`managed-task.projection.ts:108`); el listado de proyecciones de hoy no sirve porque filtra las ya acusadas (`projection.worker.ts:41`). Un intento fallido sin resultado producido no deja proyección y no aporta ref. `findingsRef` se queda como el último, para no romper a quien lo lee. Prueba en R: tres rondas con hallazgos distintos dejan la lista de tres en la necesidad de la cuarta, y un bloqueante que vuelve suma una ronda sin reiniciar el contador.
- Cambiar la activa, o sumar una versión, pide el recibo del plan: `decision` con principal, alcance (qué raíces: solo las nuevas del perímetro adoptado), versión y digest anterior y nuevo, fecha y el read-back del archivo publicado. Una prueba fija que `activa` cambie solo junto con una `decision` nueva cuya fecha y frase no son las de otra versión. Implementarlo no activa nada: la única versión es la vigente.

### 4.2 El veredicto con forma

- `findingsRef` apunta a un `hallazgos.v1`: `{"schema": "hallazgos.v1", "findings": [{"id", "bloqueante": bool, "archivo", "linea", "resumen", "reproduce"}]}`. `reproduce` es obligatorio cuando `bloqueante` es verdadero (regla 4: sin reproducción no bloquea). `reporte.py` y el host lo validan antes de aceptar el resultado; un archivo que no parsea es `resultado-invalido`.
- Un `approved` cuya evidencia (`evidenceRef`) es un `hallazgos.v1` con un bloqueante se rechaza como `aprobado-con-bloqueante` (plan, "Verificar": código cero con texto BLOCKER no aprueba). Ese es el criterio. Como red de seguridad, una evidencia de texto con una línea que empieza con `BLOQUEANTE` o `BLOCKER` también se rechaza; puede dar falsos positivos con una plantilla citada y no ve un bloqueante a mitad de línea, y por eso no reemplaza al tipado.
- `progress_bridge.py` acepta `approved` y `changes` (y sigue leyendo `aprobado`/`cambios` de entregas viejas, sin emitirlos).

### 4.3 La marca de completitud del bot

En goncloud-pr-review: un archivo excluido por `budget` baja la cobertura a `PARTIAL`, igual que `presupuesto`. La marca pública sale `partial` y el aviso de "quedaron fuera por tamaño" se queda. G sube el sha fijado en los dos workflows. No se sube `MAX_DIFF_BYTES`: un diff más grande que 1,5 MB se parte en PRs o se revisa a mano, y eso lo decide el lead con la marca a la vista.

### 4.4 El merge del head exacto

Comando nuevo `scripts/agent-work/merge.py listo <PR> --sha <head>` y `merge.py mergear <PR> --sha <head>`. `listo` contesta una línea JSON `{"listo": bool, "faltan": [...], "avisos": [...]}` con estas compuertas, todas contra el mismo SHA:

1. El PR no es draft y su head es `<head>` (si no, `es-draft` o `head-movido`).
2. CI: los check-runs `clasificador`, `ci-contract` y `gate` de ese SHA salieron `success`, y ningún check-run del SHA salió `failure`, `cancelled` o `timed_out`. Los shards no se piden uno por uno: `gate` ya exige la unión exacta en el carril completo y deja `skipped` solo en el carril rápido (`quality.yml:339-498`; los pares con `skipped` en `:414-429`), así que `gate` verde es el veredicto de CI de los dos carriles. `reconcile` (del bot) se pide `success` porque el PR no es draft.
3. CodeRabbit: su status de ese SHA es `success` y no hay hilos de revisión de CodeRabbit sin resolver (GraphQL `reviewThreads.isResolved`, que también trae los comentarios en línea). Un `success` con "Review rate limited" cuenta como revisión ausente: pasa, y `listo` lo dice en `avisos`.
4. El bot: el comentario fijo existe y **su autor es `github-actions[bot]`** (un comentario con los mismos marcadores escrito por otra cuenta no cuenta: los marcadores son texto que cualquiera puede escribir). Su marca es `completion=<head>:complete`, y su bloque de hallazgos parsea como schema 3. Una marca de otro SHA es `evidencia-de-otro-head` (es lo que pasa cuando el worker muere antes de publicar); `partial` es `revision-parcial`; la forma legada sin schema o un bloque que no parsea también es `revision-parcial`. Esta compuerta suple el check-run que el bot no deja (plan, "Verificar": comentario de bot sin check-run falla; aquí, sin la firma del bot y la marca del head falla).
5. Hallazgos: cada hallazgo `open` del bot de severidad `Critical`, `High` o `Medium`, y cada comentario en línea de CodeRabbit marcado `Major` o `Critical`, está descartado con `ai-review: descartar F<n>` (el bot ya verifica el permiso) o adjudicado en un comentario con la línea `adjudicado <F<n>|cr:<id del comentario>> @<head corto>: no-bloqueante|no-aplica — <porqué>`. La adjudicación nombra el head: una de un push anterior no vale para el siguiente si el hallazgo sigue abierto. Un `open` sin adjudicar es `hallazgo-sin-adjudicar`. Los `Low` y los `Minor` no frenan: van a filas del plan.

Sobre quién adjudica. En este sistema todos (coordinador e implementadores) usan la misma cuenta de GitHub, así que GitHub no puede distinguir al lead de un implementador. La separación es de procedimiento y **es nueva: la escribe este bloque** (hasta hoy los briefs de implementador prohíben tocar la Mini, el gateway, el host vivo y ~/bin, no comentar en GitHub). H6 la entrega: el runbook (4.7) y las SKILLs de cierre dicen "solo el coordinador comenta, descarta y adjudica", y la plantilla de briefs de implementador lo prohíbe desde SUA-05. `merge.py` deja además en su recibo cada adjudicación con su autor de commit local (`Co-Authored-By` del último commit del implementador frente a la sesión del coordinador). Lo que sí ata la máquina: la evidencia del bot la firma `github-actions[bot]`, que ninguna sesión puede imitar.

`mergear` corre `listo` y, solo si da `true`, `gh pr merge <PR> --squash --match-head-commit <head>`, y relee el PR: `MERGED` con su `mergeCommit`. No hay tabla de preaprobaciones ni orden extra: la autoridad de merge es permanente para los agentes (`loop-autopilot.md:3`) y la compuerta es la de arriba.

### 4.5 La receta por repo

Archivo `docs/evidence/agent-work/recetas-repos.json`, una entrada por repo que el sistema mergea hoy (goncloud-openclaw, goncloud-hermes, goncloud-pr-review): rama base, método (`squash`), checks requeridos por nombre, bots que deben contestar (`coderabbit`, `ai-review`), si el PR nace en draft, cómo se trae la base (`merge`, que es lo que se hace hoy; nunca `rebase` con `--force` sin decisión), qué checks pide cada carril (los de la compuerta 2 para G; los suyos para los otros repos) y el reintento de infraestructura: un job que murió por una firma conocida (`timed out after`, `ECONNRESET`, `rate limit`) se re-corre una vez con `gh run rerun --failed`; la segunda vez es un fallo de verdad. `merge.py reintentar <PR> --sha <head>` hace ese reintento y nada más.

Las respuestas a un diálogo del CLI de un trabajador (un "¿sigo?", un permiso) nunca valen como autoridad de merge o deploy: `merge.py` no lee transcripts ni respuestas del host, solo GitHub.

### 4.6 Corpus y duplicado

- `clasificar-cambio.sh` ya fuerza `completo` para sus archivos de control con `ruta_es_control` (`:139-144, 228-230`). Ese mecanismo se extiende: además de los de control, los archivos que lee un checker de la batería (`docs/evidence/corpus-rendiciones.tsv` hoy) salen de una lista en datos junto a la allowlist, y clasifican `completo` aunque casen la allowlist. La prueba del clasificador fija que tocar el corpus da `completo`.
- `run-checks.sh` saca `test-ci-coverage-contract.sh` del glob de los shards (corre en `ci-contract`), y el inventario del gate lo saca también; `valida-union-shards.sh` sigue exigiendo la unión exacta. Prueba: el inventario no lo trae dos veces; una prueba nueva de `scripts/tests/` que nadie corre hace fallar la unión; un shard sin resumen hace fallar el gate.

### 4.7 El runbook

`loop-autopilot.md` §4 se reescribe en corto con lo de 4.1 y 4.4: la regla 4, el tope 5+5 con relevo, el revisor que excluye autores, los bots y CI, sin `cross-review`, sin cambio de revisor por ronda, sin paro por bloqueante repetido, sin el subagente propio de :115. Las líneas :201 y :227 dejan de mandar a la tabla de preaprobaciones. Un barrido con `git grep -n "gh pr merge\|test-merge-sin-kit\|kit-merge-route\|preaprobaciones"` sobre `agents/`, `docs/runbooks/` y `scripts/` da la lista que se cambia a `merge.py mergear`; hoy incluye las SKILLs `saikit-cierre-pr` (implementer e ingenieria), `saikit-merge-route` y `post-merge-closure` de main, `test-merge-sin-kit.sh`, y `agents/ingenieria/agent/workshop-skills/mac-node-ops/kit-merge-route.md` (con las líneas de su SKILL.md que lo citan). Además de ese patrón, el barrido busca la autoridad de merge escrita sin el comando ("merge y deploy sin permiso", "kit de merge"): hoy `git-commit-push/SKILL.md:22`, `docs/runbooks/camino-feliz-producto.md:15`, `goncloud-ssh-ops/SKILL.md:29` y `scripts/tests/test-runbooks-no-contradicen-entorno.sh:3`; y H6 corre la batería completa después del barrido, porque ese test de runbooks ve lo que el grep no.

## 5. Cómo se prueba

Cada pieza con su prueba roja antes y su mutación roja, como en SUA-03/04. Las del plan, con su nombre:

| "Verificar" del plan | Prueba |
|---|---|
| Código cero con texto BLOCKER no aprueba | 4.2: un `approved` con un `hallazgos.v1` bloqueante, y otro con una línea `BLOCKER`, salen `aprobado-con-bloqueante`. |
| Evidencia de otro head falla | 4.4: comentario del bot con la marca de otro SHA: `evidencia-de-otro-head`. |
| Comentario de bot sin check-run falla | 4.4: comentario sin la firma de `github-actions[bot]` (los mismos marcadores escritos por otra cuenta), sin marca de completitud o con la forma legada: no listo. |
| Un bloqueante nuevo en cada ronda no reinicia límites | 4.1: la prueba nueva de R (tres rondas con hallazgos distintos, la lista acumulada y el contador que sigue) y la paridad. |
| Activar otra política sin la decisión de David falla | 4.1: `activa` distinta sin `decision` nueva falla; `contrato.py` rechaza una versión que no está. |
| Ningún paso pide revisión a un segundo modelo | 4.1: `segundoModelo: false` y un grep de candado sobre runbooks y SKILLs administradas: `cross-review` no aparece salvo en texto histórico marcado. |
| Cambiar corpus dispara su checker | 4.6, prueba del clasificador. |
| Shard vacío o prueba omitida hace fallar cobertura | 4.6, pruebas de la unión. |
| Reviewer sin acceso de escritura a fuente | Ya probado en SUA-03 (`revisor-con-escritura`, clon desechable) y SUA-04 G7 (`--tools` sin Edit/Write, banco "claude-revision-rota"); se cita. |

`merge.py` se prueba con un `gh` de juguete que contesta JSON grabado de PRs reales, sin red: #321 (head `a3967285`, con su F4 `Medium` abierto y sin adjudicar: `listo` tiene que dar `false`), #322 (dos `Major` de CodeRabbit en línea sin adjudicar: `false`), un PR de carril rápido con shards `skipped` y `gate` verde (`true`), un draft (`es-draft`) y un comentario con los marcadores escritos por la cuenta del usuario (`false`). La prueba de H3 va por la ruta schema 3 del bot, que es la de producción: por la ruta legada el aviso ya baja la marca a `partial` (`review.py:623-627`) y la prueba no discriminaría. Una medición viva (M-25) corre `merge.py listo` contra un PR abierto de verdad antes de usar `mergear` en el cierre.

## 6. El corte en rebanadas

| Rebanada | Qué | Depende de |
|---|---|---|
| H1 | 4.1: `politica-calidad.json`, contrato, paridad con R, prueba de activación; en R, `findingsRefs` acumulados y su prueba. | — |
| H2 | 4.2: `hallazgos.v1`, `aprobado-con-bloqueante`, `progress_bridge`. | — |
| H3 | 4.3 en goncloud-pr-review (PR allí) y el sha nuevo en los workflows de G. | — |
| H4 | 4.4 y 4.5: `merge.py` con sus compuertas, recetas, reintento; M-25. | H3 para la marca `partial` |
| H5 | 4.6: corpus fuera del carril rápido, duplicado fuera de los shards, pruebas de unión. | — |
| H6 | 4.7: runbook, SKILLs, `test-merge-sin-kit.sh`, la regla "solo el coordinador comenta, descarta y adjudica" en el runbook, las SKILLs de cierre y la plantilla de briefs; recibo `SUA-05.md`, filas, aviso a David. | H1 a H5 |

H1, H2, H3 y H5 van en paralelo. Desde H4, los PRs del bloque se mergean con `merge.py mergear`.

## 7. Lo que no entra en SUA-05

- Deploy de Orbit y su autoridad (SUA-08).
- Panel y avisos (SUA-06).
- Cambiar el tope 5+5 o el número de rondas: es una decisión de David, no de este bloque.
- Subir `MAX_DIFF_BYTES` o cambiar el modelo del bot.
- Hermes (SUA-07): su receta entra en 4.5 como datos, pero su flujo de merge no se toca.

## 8. Riesgos y decisiones pendientes

### Riesgos

- La compuerta 3 trata "rate limited" de CodeRabbit como revisión ausente que pasa. Es lo que se hace hoy; si David prefiere esperar a CodeRabbit, es un cambio de una línea en la receta.
- La adjudicación (compuerta 5) es texto en un comentario de la misma cuenta que usan todos: la separación entre lead e implementador es de procedimiento (4.4). `merge.py` exige la forma literal, el head nombrado y un autor con permiso de escritura, para que un comentario de un tercero no adjudique.
- El cambio en goncloud-pr-review toca otro repo; si su PR no entra, H4 sigue con la marca de hoy y `listo` lee además el aviso "quedaron fuera por tamaño" del texto del comentario como `revision-parcial`.

### Decisiones pendientes de David

Ninguna. La política que se activa es la vigente (regla 4 con 5+5); el bloque no cambia números ni alcance.
