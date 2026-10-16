# SUA-05, ingeniería y calidad: diseño y corte en rebanadas

Fecha: 2026-10-16. Estado: diseño propuesto, sin código. Lo escribió el coordinador (Claude). Lo revisa el implementador asignado (Muse Wonder) antes de implementar: no es autor de este documento.

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

- R tiene la tabla: `ROOT_QUALITY_POLICIES = {"quality-kit.regla4": {roundsPerImplementer: 5, relays: 1}}` (`src/agents/tasks/managed-root.decide.ts:36-38`). El paso 6 del decidir cuenta `rondas:<unitId>` y, al llegar a `5 * (1 + relays + bloques)`, levanta `NECESITA_DAVID` con `seguir`, `omitir` y `cancelar` (`:549-568`). `openManagedRoot` rechaza una versión fuera de la tabla (`managed-root.worker.ts:149`).
- En G no hay archivo de política. `qualityPolicy` solo lo valida el contrato como un objeto con `version` de texto (`scripts/sistema_agentes/contrato.py:252`): cualquier texto pasa.
- La frase de David está en `docs/evidence/sistema-agentes-unificado/revision-2026-10-12/decisiones-para-david.md:27`: "regla 4 de quality-kit con tope 5+5. La propuesta de cuatro ciclos queda inactiva."
- `docs/runbooks/loop-autopilot.md` §4 (líneas 86-121) sigue con lo que la política no trae: `cross-review.ps1` (:19, :91, :106), cambio de revisor en cada ronda (:102), rondas sin tope (:111), paro por bloqueante repetido (:112). Las líneas :201 y :227 todavía mandan contestar "con la tabla de preaprobaciones".

### El merge es una orden a mano

- Se mergea con `gh pr merge --squash --match-head-commit <SHA>` cuando CI y CodeRabbit aprueban y los bloqueantes están resueltos (`loop-autopilot.md:136`, SKILLs `saikit-cierre-pr`). Ningún script lee los checks del head, el resultado del bot ni compara el SHA.
- En el head de un PR quedan check-runs de `github-actions` (clasificador, shards 1-5, ci-contract, gate, reconcile) y un **commit status** de CodeRabbit (medido en el head `a3967285` de #321). El bot ai-review **no deja check-run**: su resultado es el comentario fijo `<!-- ai-review:sticky -->` con `<!-- ai-review:completion=<sha40>:(complete|partial) -->` y el bloque `<!-- ai-review:findings={json} -->` (schema 3: `completion`, `findings[].severity` y `findings[].status.kind` `open|resolved|dismissed`).
- Un hallazgo se descarta con un comentario `ai-review: descartar F<n>` (`review.py:154-161`); descartado no vuelve.
- Lo que se vio en esta sesión: el worker de #321 terminó la revisión y murió al cerrar su proxy (`litellm ... timed out after 10 seconds`); el comentario se quedó en `pending` hasta que el coordinador re-corrió el job. Un merge que solo mirara checks verdes no se habría enterado.

### El diff se recorta y la marca dice completo

- El worker fija `MAX_DIFF_BYTES=1500000` y `strict_budget=False` (`review.py:1060-1063`). Con eso, un archivo que no cabe sale con causa `budget`, y la cobertura queda `COMPLETE_CLAIM` porque solo `presupuesto` la baja a `PARTIAL` (`review_context.py:936-962`). El comentario avisa "N archivo(s) quedaron fuera por tamaño del diff" (`review.py:669-672`), pero la marca que lee una máquina dice `complete`.

### CI y corpus

- `quality.yml`: clasificador, shards (5, `SHARDS_N` fijo, reparto por `scripts/ci-duraciones.tsv`), ci-contract y gate. El gate exige la unión exacta de los cinco shards contra el inventario (`scripts/valida-union-shards.sh`).
- El carril rápido deja pasar el corpus sin su checker: `docs/evidence/corpus-rendiciones.tsv` casa con `docs/evidence/**/*.tsv` (`scripts/ci-fast-allowlist.txt:13`), un cambio solo a ese archivo es `fast`, y en `fast` no corren los shards, donde vive `verify-corpus` (`run-checks.sh:96`).
- `scripts/tests/test-ci-coverage-contract.sh` corre dos veces por PR: en el job `ci-contract` (`quality.yml:326`) y como entrada del glob de los shards (`run-checks.sh:82-85`).

### El revisor por CLI no escribe la fuente

- En opencode, un perfil sin `writesSource` corre con `permission.edit: "deny"` y en un clon desechable del head (`sesion.py:231-272, 326-330`; `native_gateway.py:379-400, 710-719`). En claude, con `--restricted --tools` sin Edit ni Write y el sandbox (SUA-04 G7, M-23 y M-24). El shell de opencode no está confinado (`sesion.py:331-339`): escribe en su corrida, que se borra.
- `review.v1` es `{"verdict":"approved","evidenceRef"}` o `{"verdict":"changes","findingsRef"}` (`host.py:345-348`). El archivo de `findingsRef` no tiene forma: es texto.
- `progress_bridge.py:74-97` acepta `aprobado` y `cambios`, mientras el contrato dice `approved` y `changes`.

## 2. Lo que falta, punto por punto contra el bloque

| Paso del plan | Qué falta |
|---|---|
| 1. Revisión independiente, resultados tipados, diff completo, escritura restringida | Hallazgos con forma en `findingsRef`; un `approved` con un bloqueante en su evidencia no aprueba; el recorte del bot baja la marca a `partial`; `progress_bridge` con los veredictos del contrato. La escritura restringida ya está (SUA-03/04): se cita, no se rehace. |
| 2. Rondas como datos | El archivo versionado en G, su paridad con la tabla de R, el contrato que rechaza una versión desconocida y el recibo para cambiarla. El contador por linaje y la escalación ya están en R. |
| 3. Merge del head exacto | Un comando que lee checks, status de CodeRabbit, comentario del bot del mismo SHA y la adjudicación, y mergea con `--match-head-commit`. Retirar el texto de preaprobaciones. |
| 4. Push, draft, reintento, corrección, rebase, ready | La receta por repo y el reintento acotado de un job de infraestructura. Separar la autoridad de merge de las respuestas a diálogos del CLI. |
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
- Paridad con R: una prueba lee `ROOT_QUALITY_POLICIES` de `managed-root.decide.ts` en `AGENT_WORK_RUNTIME_SOURCE` y exige las mismas versiones con los mismos números. Sin R, se salta con su motivo (como las de ruta viva).
- Cambiar la activa, o sumar una versión, pide el recibo del plan: `decision` con principal, alcance (qué raíces: solo las nuevas del perímetro adoptado), versión y digest anterior y nuevo, fecha y el read-back del archivo publicado. Una prueba fija que `activa` cambie solo junto con una `decision` nueva cuya fecha y frase no son las de otra versión. Implementarlo no activa nada: la única versión es la vigente.

### 4.2 El veredicto con forma

- `findingsRef` apunta a un `hallazgos.v1`: `{"schema": "hallazgos.v1", "findings": [{"id", "bloqueante": bool, "archivo", "linea", "resumen", "reproduce"}]}`. `reproduce` es obligatorio cuando `bloqueante` es verdadero (regla 4: sin reproducción no bloquea). `reporte.py` y el host lo validan antes de aceptar el resultado; un archivo que no parsea es `resultado-invalido`.
- Un `approved` cuya evidencia (`evidenceRef`) es un `hallazgos.v1` con un bloqueante, o un texto con una línea que empieza con `BLOQUEANTE` o `BLOCKER`, se rechaza como `aprobado-con-bloqueante` (plan, "Verificar": código cero con texto BLOCKER no aprueba).
- `progress_bridge.py` acepta `approved` y `changes` (y sigue leyendo `aprobado`/`cambios` de entregas viejas, sin emitirlos).

### 4.3 La marca de completitud del bot

En goncloud-pr-review: un archivo excluido por `budget` baja la cobertura a `PARTIAL`, igual que `presupuesto`. La marca pública sale `partial` y el aviso de "quedaron fuera por tamaño" se queda. G sube el sha fijado en los dos workflows. No se sube `MAX_DIFF_BYTES`: un diff más grande que 1,5 MB se parte en PRs o se revisa a mano, y eso lo decide el lead con la marca a la vista.

### 4.4 El merge del head exacto

Comando nuevo `scripts/agent-work/merge.py listo <PR> --sha <head>` y `merge.py mergear <PR> --sha <head>`. `listo` contesta una línea JSON `{"listo": bool, "faltan": [...]}` con estas compuertas, todas contra el mismo SHA:

1. El head del PR es `<head>` (si no, `head-movido`).
2. Todos los check-runs de ese SHA terminaron y ninguno salió `failure`, `cancelled` o `timed_out`; los requeridos de la receta (4.5) están todos.
3. El status de CodeRabbit de ese SHA es `success`, y no hay hilos de revisión de CodeRabbit sin resolver (GraphQL `reviewThreads.isResolved`). Un `success` con "Review rate limited" cuenta como revisión ausente: pasa, y `listo` lo dice en `avisos`.
4. El comentario fijo del bot existe, su marca es `completion=<head>:complete` y su `findings` no está `pending`. Un comentario de otro SHA es `evidencia-de-otro-head`; uno `partial` es `revision-parcial`. Esta compuerta suple el check-run que el bot no deja (plan, "Verificar": comentario de bot sin check-run falla; aquí, comentario sin la marca del head falla).
5. Cada hallazgo `open` del bot de severidad `Critical`, `High` o `Medium` está descartado con `ai-review: descartar F<n>` o adjudicado en un comentario del lead con la línea `adjudicado F<n>: no-bloqueante|no-aplica — <porqué>`. Un `open` sin adjudicar es `hallazgo-sin-adjudicar`. Los `Low` no frenan: van a filas del plan.

`mergear` corre `listo` y, solo si da `true`, `gh pr merge <PR> --squash --match-head-commit <head>`, y relee el PR: `MERGED` con su `mergeCommit`. No hay tabla de preaprobaciones ni orden extra: la autoridad de merge es permanente para los agentes (`loop-autopilot.md:3`) y la compuerta es la de arriba.

### 4.5 La receta por repo

Archivo `docs/evidence/agent-work/recetas-repos.json`, una entrada por repo que el sistema mergea hoy (goncloud-openclaw, goncloud-hermes, goncloud-pr-review): rama base, método (`squash`), checks requeridos por nombre, bots que deben contestar (`coderabbit`, `ai-review`), si el PR nace en draft, cómo se trae la base (`merge`, que es lo que se hace hoy; nunca `rebase` con `--force` sin decisión), y el reintento de infraestructura: un job que murió por una firma conocida (`timed out after`, `ECONNRESET`, `rate limit`) se re-corre una vez con `gh run rerun --failed`; la segunda vez es un fallo de verdad. `merge.py reintentar <PR> --sha <head>` hace ese reintento y nada más.

Las respuestas a un diálogo del CLI de un trabajador (un "¿sigo?", un permiso) nunca valen como autoridad de merge o deploy: `merge.py` no lee transcripts ni respuestas del host, solo GitHub.

### 4.6 Corpus y duplicado

- `clasificar-cambio.sh` gana una lista de archivos que lee un checker de la batería (`docs/evidence/corpus-rendiciones.tsv` hoy) y que clasifican `completo` aunque casen la allowlist. La lista vive junto a la allowlist y la prueba del clasificador fija que tocar el corpus da `completo`.
- `run-checks.sh` saca `test-ci-coverage-contract.sh` del glob de los shards (corre en `ci-contract`), y el inventario del gate lo saca también; `valida-union-shards.sh` sigue exigiendo la unión exacta. Prueba: el inventario no lo trae dos veces; una prueba nueva de `scripts/tests/` que nadie corre hace fallar la unión; un shard sin resumen hace fallar el gate.

### 4.7 El runbook

`loop-autopilot.md` §4 se reescribe en corto con lo de 4.1 y 4.4: la regla 4, el tope 5+5 con relevo, el revisor que excluye autores, los bots y CI, sin `cross-review`, sin cambio de revisor por ronda, sin paro por bloqueante repetido. Las líneas :201 y :227 dejan de mandar a la tabla de preaprobaciones. `test-merge-sin-kit.sh` y las SKILLs `saikit-cierre-pr` pasan a nombrar `merge.py mergear`.

## 5. Cómo se prueba

Cada pieza con su prueba roja antes y su mutación roja, como en SUA-03/04. Las del plan, con su nombre:

| "Verificar" del plan | Prueba |
|---|---|
| Código cero con texto BLOCKER no aprueba | 4.2: un `approved` con un `hallazgos.v1` bloqueante, y otro con una línea `BLOCKER`, salen `aprobado-con-bloqueante`. |
| Evidencia de otro head falla | 4.4: comentario del bot con la marca de otro SHA: `evidencia-de-otro-head`. |
| Comentario de bot sin check-run falla | 4.4: comentario sin marca de completitud, o con `findings` pendiente: no listo. |
| Un bloqueante nuevo en cada ronda no reinicia límites | 4.1: la paridad con R; el conteo vive en R y su prueba (`managed-root.decide.test.ts`) se cita en el recibo. |
| Activar otra política sin la decisión de David falla | 4.1: `activa` distinta sin `decision` nueva falla; `contrato.py` rechaza una versión que no está. |
| Ningún paso pide revisión a un segundo modelo | 4.1: `segundoModelo: false` y un grep de candado sobre runbooks y SKILLs administradas: `cross-review` no aparece salvo en texto histórico marcado. |
| Cambiar corpus dispara su checker | 4.6, prueba del clasificador. |
| Shard vacío o prueba omitida hace fallar cobertura | 4.6, pruebas de la unión. |
| Reviewer sin acceso de escritura a fuente | Ya probado en SUA-03 (`revisor-con-escritura`, clon desechable) y SUA-04 G7 (`--tools` sin Edit/Write, banco "claude-revision-rota"); se cita. |

`merge.py` se prueba con un `gh` de juguete que contesta JSON grabado de PRs reales (#321 y uno con hallazgo pendiente), sin red. Una medición viva (M-25) corre `merge.py listo` contra un PR abierto de verdad antes de usar `mergear` en el cierre.

## 6. El corte en rebanadas

| Rebanada | Qué | Depende de |
|---|---|---|
| H1 | 4.1: `politica-calidad.json`, contrato, paridad con R, prueba de activación. | — |
| H2 | 4.2: `hallazgos.v1`, `aprobado-con-bloqueante`, `progress_bridge`. | — |
| H3 | 4.3 en goncloud-pr-review (PR allí) y el sha nuevo en los workflows de G. | — |
| H4 | 4.4 y 4.5: `merge.py` con sus compuertas, recetas, reintento; M-25. | H3 para la marca `partial` |
| H5 | 4.6: corpus fuera del carril rápido, duplicado fuera de los shards, pruebas de unión. | — |
| H6 | 4.7: runbook, SKILLs, `test-merge-sin-kit.sh`; recibo `SUA-05.md`, filas, aviso a David. | H1 a H5 |

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
- La adjudicación del lead (compuerta 5) es texto en un comentario: `merge.py` exige la forma literal y el autor con permiso de escritura en el repo, para que un comentario de un tercero no adjudique.
- El cambio en goncloud-pr-review toca otro repo; si su PR no entra, H4 sigue con la marca de hoy y `listo` lee además el aviso "quedaron fuera por tamaño" del texto del comentario como `revision-parcial`.

### Decisiones pendientes de David

Ninguna. La política que se activa es la vigente (regla 4 con 5+5); el bloque no cambia números ni alcance.
