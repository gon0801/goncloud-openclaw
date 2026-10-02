# Director de corrida.sh: transiciones, tipos y estado

Referencia del director de U3b (Fase 20). El porqué está en el
[diseño](2026-09-29-director-corrida-design.md). El orden de trabajo está en el
[plan](../plans/2026-09-29-director-corrida.md).

Este documento describe el objetivo. Los módulos nuevos no existen todavía en
`origin/main`. En 20.1 la tupla `director.TABLA` y las tablas de este documento
deben coincidir fila por fila, y una prueba lo comprueba.

La integración usa la base T0–T10 comprobada del
[plan de encargos durables](../plans/2026-09-30-encargos-agentes.md) para cada
entrada gestionada. No requiere T11–T12, despliegue total ni Hermes antes de
desarrollar U3b. `reconcile()` es el único decisor de ingeniería; el runtime
nativo conserva encargo, resultado y consumo. Una entrada sin cobertura permanece
fuera del perímetro gestionado hasta su adopción por generación.

## Convenciones

- La fase es calculada. `phase_of` es `fase_de_log` ajustada con las
  observaciones. No existe un campo `fase` en el registro.
- Cada efecto es un `PlannedEffect` cerrado. El wrapper lo ejecuta como
  `intent.X` bajo lock, luego el efecto externo sin lock, luego `observed.X.*`.
  Un `intent.X` de la tenencia actual sin su `observed` produce `wait`.
- Después de un efecto que cambia la fase de una fila, el wrapper corre
  `tablero-trabajo.sh paso <id> <fila> <estado>`, salvo que `observed.tablero` ya
  tenga ese estado.
- `F` es la fila vigente y `R` su ronda (`punto_vigente`).
- `claves_que_persisten` compara el veredicto actual con el de la ronda previa.
  El mismo bloqueante reproducible en ambas rondas detiene el bloque antes de
  crear otro encargo o relevar al implementador.
- `sondas(fase_de_log)` fija qué se observa en cada fase.
- Para una entrada gestionada, `report` y `resolve` del runtime nativo son la
  fuente de resultado y consumo. `task_handoffs.py` traduce el resultado tipado
  al mismo `reconcile()`. Un hook o una pantalla quieta nunca acreditan entrega.

## Constantes

| Nombre | Valor | Significado |
|---|---|---|
| `CUPO_GLOBAL` | 4 | Sesiones de CLI en toda la Mac. |
| `RENOTIFICAR_S` | 3600 | Intervalo mínimo entre avisos de una excepción abierta. |
| `BOT_CALLADO_S` | 3600 | Tiempo sin veredicto del revisor automático en el head, desde `ready`. |
| `SILENCIO_EMPUJON_S` | 1200 | Solo entradas CLI anteriores: sesión quieta sin LISTO ni VEREDICTO antes de un empujón. No aplica a tareas gestionadas. |
| `MAX_RONDAS_CI` | 2 | Filas `ci-rN` antes de `CI_ROJO`. |
| `INSPECT_TOPE` | 4 | `adaptador inspect` por pasada. |
| `INSPECT_TIMEOUT_S` | 10 | Tope de cada `inspect`. |
| `GH_TIMEOUT_S` | 30 | Tope de cada llamada a `gh`. |

## Ciclo de un bloque

Antes de aplicar una fila que abre otra revisión, un relevo o una fila automática,
comprueba si el mismo bloqueante reproducible apareció en las dos últimas rondas
del bloque. En ese caso, `BLOQUEANTE_REPETIDO` tiene prioridad y no se ejecuta el
otro efecto. El guard también rige para los veredictos del bot.

| Fase | Condición | Efecto | Nota |
|---|---|---|---|
| Pendiente | fila `F` con `necesita_david_antes` sin decisión | `raise_excepcion NECESITA_DAVID` | Tag `[lane:release]` o autorización operativa. |
| Pendiente | `cupo_usado + 2 <= 4` | `prepare_pair` | `preparar-carril --par`: implementador en `corrida/<id>/<b>` y `-rev` detached en `origin/<rama>`, bajo `cupo_lock`. |
| EsperandoCupo | siempre | `wait` | El par cabe entero o no cabe. |
| Reservado | sin `selection` del implementador | `select_worker role=write` | El request lo arma el wrapper. |
| Reservado | `selection.winner` vacío | `raise_excepcion SIN_CUOTA` | |
| Reservado | hay ganador | `launch_worker` del implementador | Marca `OPENCLAW_WATCH` y `OPENCLAW_WATCH_RUN`, entrada en `sesiones[]`. |
| Encargado | sin `observed.encargo.written(F,R)` | `write_encargo` | `<impl-wt>/.corrida/encargo-F-rR.md`, determinista por fila, ronda y origen. |
| Encargado | encargo escrito sin `observed.delivered` | `deliver` | Una línea y el Enter aparte, bajo `teclas_lock`. |
| Encargado | `observed.deliver.blocked` dos veces | `raise_excepcion INESPERADO` | |
| Implementando | `listo.valido` | `archive_handoff` y `observed.listo` | Pasa a Listo. |
| Implementando | LISTO inválido, sin empujón en `(F,R)` | `nudge` con el motivo | Una vez. |
| Implementando | LISTO inválido, con empujón | `raise_excepcion INESPERADO` | |
| Implementando | `silencio_s > 1200`, sin LISTO, sin empujón | `nudge` | El tiempo en un diálogo no cuenta. |
| Implementando | `silencio_s > 1200` después del empujón | `raise_excepcion INESPERADO` | |
| Implementando | `inspect` en `quota` o `failed` | lo propone `reconcile_lane` (resume o handoff) | Relevo anunciado. |
| Implementando | `inspect == auth-vencida` | `raise_excepcion AUTH_VENCIDA` | Destinatario David. |
| Listo | sin `selection` del `-rev` | `select_worker role=review denied_harnesses=[harness del implementador vigente]` | Filtro existente en `selector.py`. |
| Listo | `-rev` sin ganador | `raise_excepcion SIN_REVISOR` | |
| Listo | harness del revisor igual al del implementador vigente | `relevar_rev` | Solo pasa después de un relevo del implementador. |
| Listo | `rev_head` distinto de `listo.sha` | `move_review_tree at=listo.sha` | |
| Listo | `-rev` sin sesión | `launch_worker` del revisor | |
| Listo | sin `observed.brief.written(F,R)` | `write_brief` con base en el último aprobado, head en `listo.sha` y claves previas desde `R >= 2` | `<rev-wt>/.corrida/brief-F-rR.md`. |
| Listo | brief escrito sin entregar | `deliver` a la sesión `-rev` | |
| Revisando | veredicto presente, `arbol_confiable` falso, sin descarte previo | `discard_verdict` y `nudge` | Pide no tocar archivos y volver a escribir el VEREDICTO. |
| Revisando | lo mismo, con descarte previo | `raise_excepcion INESPERADO` | |
| Revisando | veredicto confiable | `archive_handoff` y `observed.veredicto` | Pasa a Cambios o Aprobado. |
| Revisando | `silencio_s > 1200` sin veredicto | `nudge`, luego `raise_excepcion INESPERADO` | |
| Cambios | el mismo bloqueante reproducible persiste en dos rondas seguidas | `raise_excepcion BLOQUEANTE_REPETIDO` | Detiene el bloque; no crea otra ronda ni releva al implementador. |
| Cambios | hay un bloqueante nuevo reproducible y no hay repetición | `write_encargo (F, R+1, origen=cambios)` | La siguiente revisión cubre solo el diff de la corrección y usa otro revisor. |
| Cambios | solo hay hallazgos no bloqueantes | `record_residual` | Escribe una fila del plan y continúa sin otra revisión. |
| Aprobado | hay fila siguiente | `write_encargo (siguiente, 1)` | |
| Aprobado | última fila, rama sin push en el head | `push` | |
| Publicando | push hecho, sin PR | `open_pr` en draft con `--body-file` | |
| CI | `checks == pending` | `wait` | |
| CI | `failure`, `ci_flake` y sin reruns | `rerun_ci` | |
| CI | `failure` y menos de 2 filas `ci-r*` | `add_fila_auto ci-rN` con el log resumido | Arreglo, revisión del delta, push. |
| CI | `failure` otra vez | `raise_excepcion CI_ROJO` | |
| CI | `success` y draft | `mark_ready` | El revisor automático revisa este head. |
| RevisorAuto | `bot == pending` y menos de 3600 s desde ready | `wait` | |
| RevisorAuto | `bot == pending` y 3600 s o más | `raise_excepcion BOT_CALLADO` | La compuerta exige veredicto en el head. |
| RevisorAuto | `bot == blocked` | `add_fila_auto revisor-rN` | Arreglo, revisión del delta, push, CI, bot. |
| RevisorAuto | `mergeable == conflict` | `add_fila_auto rebase-rN` | |
| RevisorAuto | `bot == clean` y `checks == success` | `gate_merge` con `evidence_for()` | |
| Mergeable | `gate.allow` | `merge method=<merge_method> --match-head-commit <head>` | Sin preaprobación. |
| Mergeable | `gate.deny` | `raise_excepcion INESPERADO` | Un deny con evidencia del director es un bug. |
| Mergeado | hook `al_cerrar` sin `observed.hooks` | `run_hooks al_cerrar` | Orbit: tarea EHV en Done. |
| Mergeado | primer paso aplicable pendiente sin operador | `deploy_step` | Comando en un checkout igual a `origin/<rama>`, luego `verify` contra `expect`. |
| Mergeado | primer paso aplicable pendiente con operador | `raise_excepcion NECESITA_DAVID` | Los pasos siguientes esperan. |
| Mergeado | `deploy_step` sin `expect` | `raise_excepcion DEPLOY_FALLO` | |
| Mergeado | pasos hechos, fuente `plans-md` | `open_ledger` | Vía rápida: CI y bot, sin revisión cruzada. |
| Mergeado | pasos hechos, sin ledger | `stop_sessions`, luego `close_lane mergeado` | Escribe `historial.jsonl`. |
| Ledger | PR de ledger `clean` con checks en `success` | `gate_merge`, luego `merge` | |
| Ledger | mergeado | `stop_sessions`, luego `close_lane mergeado` | |

Las filas automáticas `ci-rN`, `revisor-rN` y `rebase-rN` siguen el mismo ciclo,
con revisión solo del delta. No reinician el historial de bloqueantes de su bloque.

## Nivel corrida

| Situación | Efecto |
|---|---|
| Primer efecto de la corrida | `run_hooks al_abrir` (Orbit: tarea EHV en In progress). |
| Pedido grande con `repo-nuevo=si`, antes del bloque de planificación | `raise_excepcion NECESITA_DAVID` para crear el repo. |
| Bloque de planificación aprobado | `raise_excepcion CONFIRMAR_PLAN` con el resumen de `.corrida/PLAN.md` copiado al directorio de la corrida. No hay PR. |
| Todos los bloques cerrados, fuente `plans-md` | `cierre_fase`. VERDE: `close_run CERRADA`. ROJO: `raise_excepcion CIERRE_ROJO`. |
| Todos los bloques cerrados, fuente pedido | `close_run CERRADA`. |

## Excepciones tipadas

`raise_excepcion` escribe `excepciones/<id>.json` con tmp y rename, y reduce
`observed.excepcion.abierta`. La pasada siguiente propone `notify_excepcion` con
el mensaje completo. Después hay un re-aviso de una línea cada 3600 segundos como
mucho. `corrida.sh decidir <id> <exc-id> <decisión> [arg]` valida contra
`DECISIONES`, mueve el JSON a `resueltas/` y reduce `observed.excepcion.resuelta`.
`apply_decision` traduce la decisión a eventos del carril.

| Tipo | Destino | Decisiones y efecto |
|---|---|---|
| `SIN_REVISOR` | claw | `seguir`: nueva selección. `relevo <w>`: con harness distinto al implementador. `cancelar`. |
| `SIN_CUOTA` | claw | `seguir`: nueva selección en la próxima pasada. `relevo <w>`. `cancelar`. |
| `AUTH_VENCIDA` | David | `listo` o `hecho`: resume de la sesión. `cancela`. |
| `CI_ROJO` | claw | `seguir`: una fila `ci-rN` más. `omitir`. `cancelar`. |
| `BOT_CALLADO` | claw | `seguir`: vuelve a lanzar el workflow del bot. `cancelar`. |
| `CONFIRMAR_PLAN` | David | `sí`: `parse_plan` del `PLAN.md` generado y agrega los bloques. `cancela`. |
| `NECESITA_DAVID` | David | `listo`: `observed.deploy.paso.hecho` o fila habilitada. `salta`: paso omitido y anotado. `cancela`. |
| `BLOQUEANTE_REPETIDO` | David | El bloque queda detenido. `salta`: `close_lane omitido`. `cancela`: `close_run DETENIDA`. Reanudar exige una decisión explícita que cumpla quality-kit; no autoriza otra ronda automática. |
| `DEPLOY_FALLO` | claw | `seguir`: reintenta el paso. `hecho`: claw lo arregló a mano. `cancelar`. |
| `CIERRE_ROJO` | claw | `seguir`: vuelve a correr `cierre-de-fase`. `hecho`. `cancelar`. |
| `INESPERADO` | claw | `seguir`: vuelve a evaluar la fila que la abrió, con el contador en cero. `omitir`. `cancelar`. |

`PALABRAS_DAVID` traduce la palabra de Telegram a una decisión: `sí` y `si` son
`SI`, `listo` y `hecho` son `HECHO`, `salta` es `OMITIR` y `cancela` es `CANCELAR`.
`SI` no reanuda automáticamente `BLOQUEANTE_REPETIDO`.

El despertar de claw tiene 12 líneas como máximo:

```
corrida f19 · excepción f19-b2-ci-rojo-1 (ci-rojo)
Fila 19.1: CI sigue rojo después de un rerun y dos filas ci-rN.
Detalle: /Users/dn/.local/state/corridas/f19/excepciones/f19-b2-ci-rojo-1.json
Decide con UNA de:
	corrida.sh decidir f19 f19-b2-ci-rojo-1 seguir
	corrida.sh decidir f19 f19-b2-ci-rojo-1 omitir
	corrida.sh decidir f19 f19-b2-ci-rojo-1 cancelar
Luego termina con NO_REPLY.
```

## Lo que no es una transición

- El avance periódico a David. Lo manda `avance-tareas` sin modelo, leyendo el tablero.
- Leer la pantalla para saber si alguien terminó. El fin es un archivo LISTO o
  VEREDICTO. `inspect` se usa solo para cuota, auth, diálogo y silencio.
- Reintentar por reloj un efecto externo fallido. Queda `observed.*.blocked` y
  decide la tabla.

## Módulos y firmas

Todos los módulos nuevos van en `scripts/mac/corrida_worker/`. Los puros no tocan
disco, red, tmux ni reloj; el reloj llega en `GlobalObs.ahora`.

| Módulo | Estado | Contenido |
|---|---|---|
| `director.py` | nuevo, puro | `Phase`, `Sonda`, `fase_de_log`, `sondas`, `phase_of`, `punto_vigente`, `claves_que_persisten`, `next_effect`, `TABLA`, `TipoExcepcion`, `Decision`, `DECISIONES`, `PALABRAS_DAVID`, `excepcion_id`, `validar_decision`, `evidence_for`, `TABLERO_ESTADO`, `EFFECT_ARGS`. |
| `observe.py` | nuevo | Sale del heredoc de `reconciliar.sh`. Observa según `sondas`, produce `inspect`. |
| `plan.py` | nuevo, puro | `Plans.md` a `PLAN.md`, `clasificar` pedido, `preguntas_faltantes`, `plan_de_pedido`, celdas de estado. |
| `protocolo.py` | nuevo, puro | `render_encargo`, `render_brief`, `render_despertar`, `leer_listo`, `leer_veredicto`. Único dueño del formato LISTO y VEREDICTO. |
| `repos.py` | nuevo, puro | `load_repos`, `pasos_que_aplican`. |
| `reconcile.py` | cambia | `reconcile()` llama a `director.next_effect` después de `reconcile_lane`. |
| `state.py` | cambia | Catálogo de eventos nuevo y proyecciones. |
| `gates.py` | cambia | `ci-y-revisor` como único modo de merge; el bot exige check-run en el head. |
| `selector.py` | cambia | `exclude_authors` también en `role=write`, para un relevo permitido por cuota o fallo. |

### Tipos del plan y de los repos

| Tipo | Campos |
|---|---|
| `Row` | `id` (`19.1`, `T1`, `P` o `ci-r1`), `tarea` y `dod` verbatim, `deps`, `tags`, `sintetica`, `necesita_david_antes`. |
| `Block` | `id` (el revisor es `<id>-rev`), `repo`, `rows`, `kind` (`trabajo` o `planificacion`), `tamano` (`chico`, `grande` o `plans-md`). |
| `Plan` | `fuente` (`plans-md`, `pedido:chico` o `pedido:grande`), `fase_plans_md`, `blocks` en secuencia. |
| `DeployPaso` | `id`, `comando` y `verify` como argv sin shell, `expect`, `necesita_operador`, `globs` (vacío aplica siempre), `doc`. |
| `Repo` | `alias`, `path`, `slug`, `default_branch`, `merge_method`, `checks_requeridos`, `revisor_auto`, `revisor_check`, `deploy`, `hooks`, `plans_md`, `restricciones`. |

`pasos_que_aplican(repo, archivos_mergeados) -> tuple[DeployPaso, ...]` se calcula
cada vez desde el diff mergeado y nunca se guarda.

### Fases y sondas

| Fase (`Phase`) | Sondas |
|---|---|
| `pendiente`, `esperando-cupo`, `reservado` | ninguna |
| `encargado`, `implementando` | Entrada anterior: `archivos`, `sesion`. Entrada gestionada: `inspect` autenticado de la tarea. |
| `listo`, `revisando`, `cambios` | Entrada anterior: `archivos`, `sesion`, `rev-arbol`. Entrada gestionada: resultado tipado y revisión observada. |
| `aprobado`, `publicando`, `ci`, `revisor-auto`, `mergeable` | `pr` |
| `mergeado` | `pr`, `deploy` |
| `ledger` | `pr` |
| `detenido` | `sesion`, solo si la excepción es de sesión |
| `cerrado` | ninguna |

`phase_of` aplica esta precedencia; gana la primera que casa:

1. `observed.lane.closed`: `cerrado`.
2. Excepción abierta del carril: `detenido`.
3. `observed.merge.done`: `mergeado` o `ledger`.
4. PR en ready: `revisor-auto` o `mergeable`.
5. PR abierto: `ci`.
6. `observed.push.done` con todas las filas aprobadas: `publicando`.
7. Veredicto confiable de la fila y ronda vigentes: `aprobado` o `cambios`.
   `observed.residual` deja el carril `aprobado` después de escribir la fila del
   plan y antes de publicar el PR.
8. Brief entregado de la fila y ronda vigentes: `revisando`.
9. LISTO válido de la fila y ronda vigentes: `listo`.
10. Encargo entregado: `implementando`.
11. Implementador lanzado: `encargado`.
12. Par reservado: `reservado`.
13. Sin carriles: `esperando-cupo` si `cupo_usado + 2 > 4`, si no `pendiente`.

### Firmas de `director.py`

| Función | Firma | Descripción |
|---|---|---|
| `fase_de_log` | `(lane, rev, block) -> Phase` | Fase solo desde el log. Es la entrada de `sondas`. |
| `sondas` | `(fase_log) -> frozenset[Sonda]` | Qué observa `observe.py` para el carril. |
| `phase_of` | `(lane, rev, obs, rev_obs, block) -> Phase` | Fase ajustada con observaciones. |
| `punto_vigente` | `(lane, block) -> tuple[Row, int]` | Primera fila sin veredicto aprobado y su ronda. |
| `claves_que_persisten` | `(actual, previo) -> tuple[str, ...]` | Claves reproducibles marcadas `PERSISTE` que ya estaban abiertas. Proponen `BLOQUEANTE_REPETIDO` antes de otro encargo. |
| `excepcion_id` | `(corrida, lane, tipo, lane_events) -> str` | Id determinista; el mismo hecho produce el mismo id. |
| `validar_decision` | `(exc, decision, arg) -> str \| None` | `None` si vale; si no, el motivo. |
| `evidence_for` | `(lane, obs, repo, rev_worker) -> dict` | Evidencia de `compuerta merge`: head, repo, pr, CI, bot, review y autores. |
| `next_effect` | `(run, obs, global) -> tuple[PlannedEffect, ...]` | A lo sumo un efecto por pasada. |

`next_effect` sigue este orden:

1. Excepciones abiertas sin aviso o con aviso de hace 3600 segundos o más:
   `notify_excepcion`.
2. Excepciones resueltas sin aplicar: el efecto de su decisión.
3. Primer bloque no cerrado del plan: la primera fila de la tabla cuya fase y
   condición casan.
4. Plan agotado: `cierre_fase` si la fuente es `plans-md`, luego `close_run`.

Una combinación de fase y observación sin fila produce `raise_excepcion INESPERADO`.
En `director.modo == sombra` el cálculo es igual y el wrapper imprime el efecto sin
ejecutarlo.

### Tipos de observación

| Tipo | Campos |
|---|---|
| `Listo` | `fila`, `ronda`, `sha`, `valido`, `motivo`. |
| `Veredicto` | `fila`, `ronda`, `sha_revisado`, `aprobado`, `bloqueantes` (clave, texto y comando que reproduce), `seguimiento` (clave a `RESUELTO` o `PERSISTE`), `residuales`, `arbol_confiable`. |
| `PRObs` | `number`, `head`, `draft`, `merged`, `merge_commit`, `mergeable`, `checks`, `ci_flake`, `ci_log_resumen`, `bot`, `bot_hallazgos`, `ready_desde`, `archivos`. |
| `LaneObs` | `worktree_exists`, `head`, `session_alive`, `inspect`, `silencio_s`, `listo`, `veredicto`, `rev_head`, `rev_limpio`, `pr`, `remote_branch`, `deploy_verificado`. |
| `GlobalObs` | `cupo_usado`, `health`, `historial`, `ahora`. |

Un valor no observado es `None`, nunca `False`.

### Efectos

| Op | Argumentos |
|---|---|
| `prepare_pair` | `repo`, `block` |
| `select_worker` | `lane`, `role`, `task_type`, `denied_harnesses`, `exclude_authors` |
| `launch_worker` | `lane`, `worker`, `session`, `worktree`, `role` |
| `relevar_impl` | `lane`, `saliente`, `motivo` (`quota` o `failed`); nunca ante `BLOQUEANTE_REPETIDO` |
| `relevar_rev` | `lane`, `saliente` |
| `write_encargo` | `fila`, `ronda`, `origen`, `bloqueantes`, `path` |
| `move_review_tree` | `at_sha` |
| `write_brief` | `fila`, `ronda`, `base`, `head`, `claves_previas`, `path` |
| `deliver` | `session`, `path`, `linea` |
| `nudge` | `session`, `linea` |
| `discard_verdict` | `path`, `motivo` |
| `archive_handoff` | `lane`, `paths` |
| `push` | `branch`, `head` |
| `open_pr` | `repo`, `branch`, `title`, `body_path` |
| `rerun_ci` | `repo`, `pr`, `head` |
| `add_fila_auto` | `fila`, `motivo`, `bloqueantes` |
| `record_residual` | `fila`, `hallazgos`, `plan_row` |
| `mark_ready` | `repo`, `pr` |
| `gate_merge` | `sha`, `evidence_path` |
| `merge` | `repo`, `pr`, `head`, `method` |
| `deploy_step` | `repo`, `paso`, `command`, `verify`, `expect` |
| `run_hooks` | `repo`, `momento` |
| `open_ledger` | `repo`, `filas`, `status_cells` |
| `cierre_fase` | `repo`, `fase` |
| `raise_excepcion` | `tipo`, `lane`, `detalle` |
| `notify_excepcion` | `id`, `destinatario`, `completo` |
| `apply_decision` | `id`, `decision`, `arg` |
| `stop_sessions` | `lane` |
| `close_lane` | `lane`, `resultado` (`mergeado`, `omitido` o `atorado`) |
| `close_run` | `etiqueta` (`CERRADA` o `DETENIDA`) |
| `wait` | ninguno |

### Estado del tablero por fase

| Fases | Estado en el tablero |
|---|---|
| `pendiente`, `esperando-cupo`, `reservado` | `pendiente` |
| `encargado`, `implementando`, `cambios` | `implementando` |
| `listo`, `revisando` | `revision-cruzada` |
| `aprobado`, `publicando`, `ci`, `mergeable` | `en-cola` |
| `revisor-auto` | `coderabbit` |
| `mergeado`, `ledger`, `cerrado` | `mergeado` |
| `detenido` | `atorado` |

## Handoff por actor

| Archivo | Quién lo escribe | Contenido |
|---|---|---|
| `<impl-wt>/.corrida/encargo-<F>-r<R>.md` | director | Fila, DoD verbatim, bloqueantes previos, instrucciones del LISTO. |
| `<impl-wt>/.corrida/LISTO-<F>-r<R>.md` | implementador | Primera línea `SHA: <40 hex>`, comandos corridos con su salida, mutación en rojo. |
| `<rev-wt>/.corrida/brief-<F>-r<R>.md` | director | Base, head y claves previas desde la ronda 2. |
| `<rev-wt>/.corrida/VEREDICTO-<F>-r<R>.md` | revisor | `VEREDICTO: APROBADO` o `CAMBIOS`, `SHA: <head>`, secciones Bloqueantes, Seguimiento y Residuales. |

Un LISTO es válido si su SHA existe en el worktree y desciende del último aprobado
o de la base. Un LISTO de otra ronda no cuenta. Un VEREDICTO cuenta solo si, en la
misma lectura, `git status --porcelain` del `-rev` está vacío, su HEAD es el head
del brief y la línea `SHA:` coincide. Un bloqueante sin `archivo:línea` y sin el
comando que lo reproduce pasa a residual.

## Estado de una corrida

Directorio `~/.local/state/corridas/<id>/`:

| Ruta | Contenido |
|---|---|
| `registro.json` | `corrida.v2` con `director{}` y `lanes[]`; la verdad es `events[]`. |
| `PLAN.md` | Filas en formato `Plans.md`, agrupadas en bloques. |
| `pedido.json` | Solo pedidos: texto, hechos de clasificación y respuestas. |
| `SPEC.md` | Pedido grande: copia del `.corrida/SPEC.md` aprobado. |
| `director.lock` | Un `reconciliar` a la vez por corrida. |
| `director.otra-vez` | Lo toca un llamador que encontró el lock ocupado; el dueño hace otra pasada antes de soltar. |
| `obs.json` | Última observación, para diagnóstico. |
| `excepciones/<exc-id>.json` | Excepciones abiertas. |
| `excepciones/resueltas/` | Excepciones decididas; el rename es el reclamo. |
| `archivo/<lane>/` | Copia de cada encargo, brief, LISTO y VEREDICTO consumido. |

`~/.local/state/corridas/historial.jsonl` tiene una línea por carril cerrado con
`worker`, `harness`, `task_type`, `outcome`, `rondas`, `duracion_s` y `status`. Es el
historial del selector.

Campos nuevos del registro, todos opcionales:

| Campo | Valores |
|---|---|
| `director` | `activo`, `modo` (`sombra` o `vivo`), `plan`; `sesion_claw` y `turnos_claw` solo para corridas anteriores fuera del perímetro gestionado. |
| `sesiones[].dueno` | Nuevo valor `director`. `rol` sigue en `lead` o `carril`. |
| `lanes[].kind` | `trabajo`, `revisor` o `ledger`, con `par`, `revisa` o `cierra`. |

## Eventos nuevos en `state.py`

| Grupo | Eventos |
|---|---|
| Par y handoff | `intent.pair`, `observed.pair.reserved`, `intent.encargo`, `observed.encargo.written`, `intent.brief`, `observed.brief.written`, `intent.deliver`, `observed.delivered`, `observed.deliver.blocked`, `observed.nudge` |
| Entregas | `observed.listo`, `observed.listo.invalido`, `observed.veredicto`, `observed.veredicto.descartado`, `intent.review_tree`, `observed.review_tree` |
| Manejo nativo | Conserva `intent.task_handling` y `observed.task_handled` de la base integrada; no crea otra bandera de consumo. |
| Residuales | `intent.residual`, `observed.residual` con la fila del plan y el veredicto de origen. |
| Relevo por cuota o fallo | `intent.relevo`, `observed.relevo` con `motivo`, `saliente` y `entrante`; no elude `BLOQUEANTE_REPETIDO` |
| Publicación | `observed.fila.auto`, `intent.pr_ready`, `observed.pr.ready`, `intent.rerun_ci`, `observed.ci.rerun` |
| Deploy y cierre | `intent.deploy.paso`, `observed.deploy.paso.hecho`, `observed.deploy.paso.fallo`, `intent.hooks`, `observed.hooks.done`, `intent.ledger`, `observed.ledger.lane`, `intent.cierre_fase`, `observed.cierre_fase` |
| Tablero | `observed.tablero` |
| Excepciones | `observed.excepcion.abierta`, `intent.notify`, `observed.notify.sent`, `observed.excepcion.resuelta`, `observed.decision.aplicada` |
| Cierre de carril | `observed.lane.closed` con `resultado` |

`intent.push`, `observed.push.done`, `intent.pr`, `observed.pr.open`, `intent.merge`,
`observed.merge.done` y `observed.lane.stopped` ya existen.

## Locks

Se toman de arriba hacia abajo y nunca al revés.

| Lock | Ruta | Quién | Alcance |
|---|---|---|---|
| `director.lock` | `<id>/director.lock` | `reconciliar` | Toda la llamada. Ocupado: toca `director.otra-vez`, imprime `OCUPADO` y sale con 0. |
| `cupo_lock` | `$CORRIDA_STATE/.cupo.lock` | `preparar-carril` | Contar reservas de todos los registros y escribir la reserva. Nunca durante `git fetch` ni `git worktree add`. |
| lock del registro | `lock_tomar <reg>` | reducer y reservas | Leer y reducir. Se suelta durante los efectos externos. |
| `marcas_lock` | `$CORRIDA_STATE/.marcas.lock` | `adaptador start`, `lanzar-sesion`, `reconciliar-marcas` | Marcar y desmarcar `OPENCLAW_WATCH*`. |
| `teclas_lock <sesión>` | `$CORRIDA_STATE/.teclas/<sesión>.lock` | `adaptador deliver`, `nudge` y confianza, `responder.sh`, avisos con lead | Desde la relectura de pantalla hasta verificar el envío. Independiente de los demás. |

Todos usan el patrón de `marcas_lock_tomar` y `marcas_lock_soltar`: `mkdir`, token y
`lock_abandonado_romper` a los 60 segundos.

## Sesiones del gateway

| Clave | Uso |
|---|---|
| Sesión autenticada del solicitante | Ruta gestionada: recibe el resultado por la cola nativa y solo las excepciones que le corresponden. No nace una sesión supervisora. |
| `agent:main:dir-<id>` | Solo corridas anteriores fuera del perímetro gestionado: recibe excepciones de claw y sus re-avisos. `cerrar` solo la retira si es recurso propio y no tiene trabajo pendiente. |
| `agent:main:sim9-<id>` | Deja de recibir partes del latido cuando `director.activo`. |
| `agent:main:main` | El director nunca escribe ahí. Las respuestas de David por Telegram caen ahí. |

## `repos.v1.json`

Vive en `scripts/mac/corrida/repos.v1.json` y `instalar-mac.sh` lo copia a
`~/bin/corrida/`. `repos.py` lo valida estricto: una clave desconocida, un alias
duplicado, un comando con metacaracteres de shell o un paso sin operador y sin
comando invalidan todo el mapa.

| Alias | Rama | Merge | Revisor automático | Pasos de deploy | Hooks |
|---|---|---|---|---|---|
| `openclaw` (`/Users/dn/dev/goncloud-openclaw`) | `main` | `squash` | `deepseek`, check `review` | `mac`: `bash scripts/mac/instalar-mac.sh`, verifica con `--verificar` y espera `instalacion sana`, globs `scripts/mac/**`. `gateway`: con operador, globs `tablero-runbook/**`, `agents/**`, `plugins/**` y el directorio del sync seguro, doc `docs/runbooks/publicar-runtime-windows.md`. | ninguno |
| `orbit` (`/Users/dn/dev/goncloud-Orbit`) | `master` | `squash` | `deepseek`, check `review` | `goncloud`: con operador hasta que exista `scripts/deploy-goncloud.sh`; verifica `/health` en `127.0.0.1:8010` por ssh; doc `docs/DEPLOY.md`. | `al_abrir` y `al_cerrar` con `add_ehv_task.py` por ssh a goncloud (In progress y Done). |

## Verbos de `corrida.sh`

| Subcomando | Qué hace | Lógica pura |
|---|---|---|
| `plan <id> --repo <alias> --filas a,b [--bloques "b1=a;b2=b"]` | Lee `Plans.md` de `origin/<rama>`, escribe `<dir>/PLAN.md` e imprime el resumen. | `plan.py` |
| `pedido <id> --repo <alias o nuevo> --texto ... --archivos N --datos si/no --secretos si/no --repo-nuevo si/no [--dod ...] [--respuesta k=v]` | Clasifica chico o grande; con respuestas faltantes sale con código 3 y la lista. | `plan.clasificar`, `plan.preguntas_faltantes`, `plan.plan_de_pedido` |
| `abrir <id> --plan [--sombra] --vigia claw` | Exige `<dir>/PLAN.md`, escribe `director{}`, abre el tablero con una parte por fila y avisa ABIERTA. `--runbook` sigue para corridas sin director. | ninguna |
| `decidir <id> <exc-id> <decisión> [arg]` | Valida, mueve el JSON a `resueltas/`, reduce `observed.excepcion.resuelta` y lanza `reconciliar` en segundo plano. | `director.validar_decision` |
| `contestar <palabra> [--a <exc-id>]` | Sin `--a`, resuelve la única excepción abierta para David en todas las corridas. Con 0 o más de 1, las lista y sale con código 3. | `director.PALABRAS_DAVID` |
