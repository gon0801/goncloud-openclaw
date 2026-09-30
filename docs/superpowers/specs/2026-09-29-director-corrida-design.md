# Director de corrida.sh

Estado: diseño de U3b (Fase 20). No inicia implementación ni instala nada.
Sale de una arena de tres diseños del 2026-09-29 y de las decisiones de David de
ese mismo día. [Plan de trabajo](../plans/2026-09-29-director-corrida.md).
[Tabla de transiciones, tipos y estado en disco](2026-09-29-director-corrida-transiciones.md).
[Ledger](../../../Plans.md), Fase 20.

## Por qué hace falta un director

`corrida.sh` ya tiene las piezas de una corrida: reserva de carril, selector,
adaptadores de CLI, registro `corrida.v2` append-only, compuertas, latido sin
modelo y, con U3a, avisos durables de fin de turno. Nadie las encadena. Hoy lo
hace claw a mano, siguiendo un `PROMPT.md` de unas 229 líneas que relee en cada
despertar. Cada turno de claw cuesta entre 60k y 290k tokens según el historial
de la sesión, y en un prompt tan largo claw olvida pasos.

El vigía de U3a es un cron del gateway con modelo. Corre en una sesión
`isolated` y cuesta unos 63k tokens por despertar (medido el 2026-09-29; antes de
aislarlo eran unos 360k). Despierta cada 5 minutos aunque no haya nada que hacer.

Ya existe una función de decisión pura, `reconcile(state, obs) -> effects` en
`scripts/mac/corrida_worker/reconcile.py`. El wrapper `corrida/reconciliar.sh`
ejecuta un efecto cerrado por pasada y vuelve a llamar. Hoy solo sabe de relevos
por cuota. El director extiende esa función. Un director aparte, con su propia
máquina de estados, sería un segundo decisor sobre el mismo registro.

El diseño cierra también defectos que se comprobaron en el código de `origin/main`:

- `adaptador start` no marca `OPENCLAW_WATCH` ni registra la sesión en
  `sesiones[]`, así que el vigilante, el latido y los avisos no la ven.
- El carril del revisor nace de `origin/main` y no contiene los commits del
  implementador.
- `adaptador deliver` teclea el brief entero en el panel, con riesgo de que se
  pierda el Enter.
- La independencia del revisor se mide por `worker.id`. Hoy `claude_opus` puede
  revisar a `claude_fable`, que usan el mismo harness `claude-code`.
- `gates.py` acepta cualquier comentario de `github-actions` como veredicto del
  revisor automático.
- El tope de 4 sesiones se cuenta por registro, no en toda la Mac.
- `reconciliar` automático no produce `inspect`, así que el relevo por cuota solo
  ocurre si claw pasa `--observations` a mano.
- Los avisos de U3a despiertan a una sesión `rol: lead`, que una corrida dirigida
  no tiene.

## Cómo se usa

### Lo que escribe David

David escribe en prosa por Telegram. Tres ejemplos:

```
claw, implementa 19.1 y 19.2 de la fase 19 en openclaw
cambia el color del botón Guardar de orbit a verde
crea un sistema para trackear mi consumo de tokens
```

Después solo contesta cuando un aviso `[NECESITO TU RESPUESTA]` se lo pide, con
una de cinco palabras: `sí`, `listo`, `hecho`, `salta` o `cancela`. El aviso
siempre termina en la lista de palabras que acepta, por ejemplo "Contesta solo:
sí / cancela".

Sin pedirlo recibe `[ABIERTA]` al abrir la corrida, `[AVANZA]` cada 30 minutos
(lo manda `avance-tareas` sin modelo leyendo el tablero, una parte por fila) y
`[DETENIDA]` o `[CERRADA]` al final. Nadie le pregunta "¿lo hago?".

### Los verbos de claw

claw usa cinco verbos. Los corre por `exec host=node` en la Mac.

```bash
corrida.sh plan f19 --repo openclaw --filas 19.1,19.2 --bloques "b1=19.1;b2=19.2"
corrida.sh pedido orbit-boton --repo orbit --texto "botón Guardar en verde" \
	--archivos 2 --datos no --secretos no --repo-nuevo no \
	--dod "el botón Guardar se ve verde en /campanas"
corrida.sh abrir f19 --plan --vigia claw
corrida.sh decidir f19 <exc-id> seguir
corrida.sh contestar sí
```

`plan` copia filas de `Plans.md` a un `PLAN.md` en el directorio de la corrida.
`pedido` hace lo mismo para un encargo sin plan. La regla que separa un pedido
chico de uno grande es código. Los hechos que alimentan esa regla (cuántos
archivos, si toca datos o secretos, si pide un repo nuevo) los estima claw, porque
solo un modelo puede estimarlos. Si a un pedido grande le faltan respuestas,
`pedido` sale con código 3 y la lista de lo que falta, y claw pregunta todo en un
solo mensaje.

`abrir --plan` arranca la corrida con el director activo. Desde ahí claw no hace
nada hasta que lo despierta una excepción. `decidir` contesta esa excepción con una
decisión de un conjunto cerrado. `contestar` pasa la palabra de David al director.

claw ya no escribe encargos, briefs, el `request.json` del selector, evidencia de
compuertas, `gh pr create`, `gh pr merge`, deploys ni el tablero. Todo eso lo hace
el director como efecto de una transición.

### Tres sitios de llamada sin modelo

El director corre en tres lugares. Ninguno usa un modelo.

1. `corrida/latido.sh`, al final de `latido_de`. El vigilante de la Mac corre el
   latido cada 300 segundos. Si el registro tiene `director.activo`, el latido
   lanza `corrida.sh reconciliar <id>` con tope de tiempo. Este es el vigía de 5
   minutos, a 0 tokens.
2. `corrida/avisos.sh`, en `avisos_despertar_dueno`. Con `director.activo`, en vez
   de teclear en una sesión `lead` que no existe, lanza `corrida.sh avisos atender`
   en segundo plano. `atender` reclama los avisos pendientes y corre `reconciliar`
   una vez. Es el camino que tarda segundos. El implementador escribe
   `.corrida/LISTO-19.1-r1.md`, el vigilante ve la pantalla quieta, emite el aviso
   de fin de turno y el director entrega el brief al revisor.
3. El despertar de claw por una excepción. Es el único turno de modelo que inicia
   el sistema. Va a la sesión corta `agent:main:dir-<id>` con un texto de 12
   líneas como máximo: qué pasó, dónde está el detalle y los comandos `decidir`
   que acepta, y termina en "Luego termina con NO_REPLY".

## Forma

### Datos

- `PLAN.md` en `~/.local/state/corridas/<id>/` es la única fuente de qué se hace.
  Se genera desde `Plans.md` o desde un pedido, y nunca vive en el repo destino.
  Un bloque es un par de carriles: `<b>` para escribir y `<b>-rev` para revisar.
  Un bloque es una rama y un PR. Los bloques de una corrida van en secuencia. El
  paralelismo sale de tener varias corridas bajo el tope global.
- `repos.v1.json` describe cada repo: rama, `merge_method`, checks requeridos,
  check-run del revisor automático, hooks `al_abrir` y `al_cerrar`, y el deploy
  como una lista ordenada de pasos con `necesita_operador` y `globs` sobre el diff
  mergeado.
- La fase de un carril no se guarda. `fase_de_log()` la calcula desde `events[]`
  del carril y `phase_of()` la ajusta con las observaciones de la pasada. El
  tablero, el parte y el director leen el mismo cálculo.
- Una excepción es un registro tipado con id determinista
  `<corrida>-<carril>-<tipo>-<n>`, un destinatario (claw o David), las decisiones
  que admite, un texto para David y el detalle. Se escribe a disco antes de avisar.
- Cada CLI escribe solo en `.corrida/` de su propio worktree: el implementador
  escribe `LISTO-<fila>-r<ronda>.md` y el revisor `VEREDICTO-<fila>-r<ronda>.md`.
  `.corrida/` va en `info/exclude`, así que nunca entra a un commit.

### Un solo decisor, un efecto por pasada

`reconcile(state, obs)` sigue siendo la única función de decisión. Primero corre
`reconcile_lane` como hoy. Después llama a `director.next_effect(run, obs, global)`,
que devuelve a lo sumo un efecto de la tabla de transiciones. `reconciliar.sh` lo
ejecuta con la disciplina de siempre: escribe `intent.*` bajo lock, hace el efecto
externo sin lock y escribe `observed.*`. Luego re-observa y repite, con un tope de
8 pasadas. Un `intent` sin su `observed` nunca se repite.

`observe.py` sale del heredoc de `reconciliar.sh` y observa solo lo que pide
`sondas(fase_de_log)`. Mientras se implementa no se llama a `gh`. Durante CI no se
lee la pantalla. `inspect` sí se produce en automático, hasta 4 por pasada y 10
segundos cada uno.

### Rondas de revisión y relevo del implementador

Todo bloque, chico o grande, tiene hasta 5 rondas de revisión cruzada con el mismo
implementador. Si la quinta sigue en CAMBIOS, el director releva al implementador a
otro modelo por la ruta de `handoff_lane` que ya existe, y ese modelo tiene otras 5
rondas. Si el segundo modelo tampoco llega a APROBADO, sale la excepción
`RONDAS_AGOTADAS` para David.

El revisor siempre es de un harness distinto al del implementador vigente. El
selector ya tiene el filtro `denied_harnesses` en `selector.py`, que nadie llenaba.
Si el relevo trae un implementador del mismo harness que el revisor, el director
también cambia al revisor.

El veredicto usa claves de bloqueante (`B1`, `B2`). Desde la ronda 2 el revisor
marca cada clave previa como `RESUELTO` o `PERSISTE`. Un bloqueante que persiste ya
no detiene el trabajo. Se cuenta dentro de las rondas, va literal en el siguiente
encargo y queda en el detalle si la excepción llega a David. Para las corridas del
director, esta decisión de David reemplaza la regla 4 de quality-kit ("si el mismo
bloqueante vuelve en dos rondas seguidas, se para y decide el operador"). El
operador ya decidió de antemano el relevo a las 5 rondas y la pregunta a las 10.

### Excepciones tipadas

Antes de molestar a alguien, el director intenta lo que no requiere modelo. Un
LISTO inválido o una sesión quieta reciben un empujón. CI roja recibe un rerun si
parece flake y luego hasta 2 filas automáticas `ci-rN`. Un bloqueante del revisor
automático abre una fila `revisor-rN`. Un conflicto abre una fila `rebase-rN`. Solo
después sale una excepción.

Once tipos de excepción cubren todo lo que despierta a claw o pregunta a David.
Cuatro van a David: `CONFIRMAR_PLAN` (pedido grande, una vez), `NECESITA_DAVID`
(publicar el gateway, deploy de Orbit mientras no tenga script, filas
`[lane:release]` y un repo nuevo), `AUTH_VENCIDA` y `RONDAS_AGOTADAS`. Los otros
siete van a claw. `corrida.sh decidir` rechaza cualquier decisión fuera del conjunto
de cada tipo, así que claw no improvisa transiciones. Una excepción abierta se
vuelve a avisar como mucho cada 60 minutos. La lista completa está en la
[referencia](2026-09-29-director-corrida-transiciones.md#excepciones-tipadas).

### Merge

El merge es libre. La compuerta `merge` de `compuerta.sh` tiene un único modo,
`ci-y-revisor`: checks del head releídos en GitHub, revisor automático sin
High ni Critical para ese head con su check-run concluido, revisor cruzado distinto
del autor y sin bloqueantes abiertos. La evidencia la arma `evidence_for()` desde
observaciones, nunca claw. Si la compuerta permite, el director corre
`gh pr merge --<merge_method> --match-head-commit <head>`.

No hay preaprobación. Se borran `scripts/mac/corrida/preaprobaciones.v1.json` y
`scripts/mac/corrida/autoridad-merge.sh`. Sin ese borrado junto con el cambio de
`compuerta.sh`, toda compuerta de merge negaría con `modo-recibo-invalido`, porque
hoy `compuerta.sh` lee el modo de esa tabla. Se borra también la regla "Main nunca
mergea ni despliega" de la skill `native-harness-orchestration`. claw mergea a
través del director.

### Deploy por repo

Después del merge, el director toma el primer paso de deploy pendiente cuyo glob
casa con el diff mergeado. Si el paso no necesita operador, corre su comando en un
checkout igual a `origin/<rama>` y verifica que `verify` imprima `expect`. Si lo
necesita, abre `NECESITA_DAVID` y los pasos siguientes esperan.

En openclaw el primer paso es `mac` (`scripts/mac/instalar-mac.sh`, si el diff tocó
`scripts/mac/**`). El segundo es `gateway`, que siempre necesita a David porque
publicar con sync seguro se hace en la PC. En Orbit el paso `goncloud` necesita a
David hasta que exista `scripts/deploy-goncloud.sh`. Con fuente `Plans.md`, el
director abre el PR de ledger por la vía rápida y, al terminar la fase, corre
`scripts/cierre-de-fase.sh <fase>`.

### Cupo global

El tope de 4 sesiones de CLI es para toda la Mac. `preparar-carril --par` reserva
el implementador y su revisor juntos bajo `cupo_lock`. Se reservan los dos cupos o
ninguno. Así nunca hay 4 implementadores sin un revisor posible. Con tope 4 corren
dos bloques a la vez. El conteo cubre las reservas de todos los registros abiertos
y las sesiones lanzadas a mano con `OPENCLAW_WATCH_RUN`.

### Sesiones y teclas

`adaptador start` marca la sesión con `OPENCLAW_WATCH` y `OPENCLAW_WATCH_RUN` antes
de la primera tecla y la registra en `sesiones[]` con `rol: carril` y
`dueno: director`. Así el vigilante, el latido y los avisos la ven.

`deliver` teclea una sola línea ("Lee .corrida/encargo-19.1-r2.md y hazlo") y el
Enter aparte, bajo `teclas_lock <sesión>`. `responder.sh` toma el mismo lock, así
que el director y el vigilante nunca teclean a la vez en el mismo panel.

El revisor arranca con permiso de escritura en su worktree para poder escribir el
VEREDICTO. La garantía de que no tocó código no es el modo de la CLI. `observe.py`
cuenta el veredicto solo si, en la misma lectura, el worktree `-rev` está limpio y
su HEAD es el head del brief.

Las excepciones para claw van a `agent:main:dir-<id>`, una sesión por corrida. Se
crea con la primera excepción y `cerrar` la barre con `sessions cleanup delete`. Al
sexto turno la siguiente excepción rota a `agent:main:dir-<id>-2`. Una sesión por
excepción agregaría registro, transcript y eventos al gateway, y la memoria del
gateway crece con los eventos de sesión sin liberarse con `restart --safe`.

### Respuestas de David por Telegram y sus límites

Un mensaje de David al bot entra a `agent:main:main`. Ahí un turno llegó a costar
unos 290k tokens porque el costo lo pone el historial de esa sesión. El director no
controla esa ruta. Por eso el diseño baja cuántas respuestas hacen falta, no cuánto
cuesta cada una:

1. Solo cuatro tipos de excepción van a David. Un pedido chico en openclaw que no
   toca el gateway termina con cero preguntas. Avisarle no cuesta tokens, porque
   `corrida_mensaje` manda el texto directo. Solo su respuesta cuesta.
2. La respuesta es una palabra fija. La regla de claw en `main` cabe en una línea.
   Si David contesta solo `sí`, `listo`, `hecho`, `salta` o `cancela`, claw corre
   `corrida.sh contestar <palabra>` y responde lo que imprima. Si hay más de una
   pregunta abierta, `contestar` las lista y claw pregunta cuál.

Estas dos medidas no bajan el costo por turno. Una respuesta de David en
`agent:main:main` sigue costando lo que pese su historial. David usa `/new` para
empezar esa conversación de cero. Falta medir cuánto pesa la base de un turno recién
abierto con `/new`, y esa medición va en 20.0. Hoy no existe un camino de 0 tokens
para un mensaje entrante: `tablero-runbook` no registra hooks por diseño y el
tablero por HTTP no es alcanzable desde el celular. Presupuesto esperado de
respuestas: 0 en un pedido chico, 1 en uno grande y 1 más si hay que publicar el
gateway.

## Decisiones de David

Estas decisiones no se vuelven a discutir en la implementación.

| # | Decisión | Dónde queda |
|---|---|---|
| 1 | Merge libre con CI verde en el head y revisor sin bloqueantes, con `--match-head-commit`. Sin preaprobaciones. claw mergea directo a través del director. Se borra la regla "main nunca mergea". | `gate_merge` y `merge`; se borran `autoridad-merge.sh` y `preaprobaciones.v1.json`; `ci-y-revisor` es el único modo; se reescribe la skill `native-harness-orchestration`. |
| 2 | Construir sobre `corrida.sh`. | `reconcile()` y `reconciliar.sh`. No hay orquestador aparte. |
| 3 | El sistema elige el revisor, siempre de otro harness. | `denied_harnesses` desde el registro; el relevo lo vuelve a validar. |
| 4 | El vigía de 5 minutos cuesta 0 tokens y claw despierta solo por excepción. El aviso de fin de turno y el latido pasan al director. | El latido llama a `reconciliar`; los avisos lanzan `atender`; `notify_excepcion` es el único despertar. El vigía con modelo de U3a se borra cuando el director esté listo. |
| 5 | Pedidos chico y grande con mini-plan en el directorio de la corrida. | `pedido` y `plan.clasificar`; `PLAN.md` y `SPEC.md` en `~/.local/state/corridas/<id>/`. |
| 6 | Mapa de repos que incluye Orbit (rama `master`, quality y ai-review, docker en goncloud, tarea EHV en AppFlowy). | `repos.v1.json`. |
| 7 | Tope global de 4 sesiones de CLI. | `cupo_lock` y conteo en todos los registros abiertos; par implementador y revisor. |
| 8 | Tablero con una parte por fila; el avance lo manda `avance-tareas`. | `abrir` crea una parte por fila; el director publica `paso` y nunca manda `[AVANZA]`. |
| 9 | Hasta 5 rondas con el mismo implementador; relevo a otro modelo con otras 5; después pregunta a David. Vale también para bloques chicos. | `RONDAS_POR_TANDA = 5`, `TANDAS_ANTES_DE_DAVID = 2`, efecto `relevar_impl`, excepción `RONDAS_AGOTADAS`. |
| 10 | Un pedido grande con repo nuevo siempre pregunta antes de crearlo. | `NECESITA_DAVID` antes del bloque de planificación. |
| 11 | El chat dedicado de Telegram se pospone. David usa `/new`. | Sin slice de chat dedicado; 20.0 mide la base de un turno tras `/new`. |

## Alternativas descartadas

La arena comparó tres diseños. La base elegida fue el candidato 2 (25 puntos, contra
23 del candidato 1 y 13 del candidato 3). Un juez cruzado independiente coincidió en
la base y en el orden. El candidato 2 mantiene un solo decisor, calcula la fase desde
el log append-only y conserva la disciplina `intent.*`, efecto, `observed.*` que ya
protege los relevos.

**Candidato 1: un director aparte.** Proponía `dirigir.sh` con un `director.json`
mutable, su propia función `aplicar()` y un bucle `dirigir tick`. Tenía buenas piezas
de dominio y el diseño final las tomó: excepciones tipadas, handoff por archivo en el
worktree de cada actor, `sondas()` por fase, deploy por glob del diff y
`cierre-de-fase`. Se descartó su forma. Dos decisores sobre el mismo registro, con
el lock suelto durante cada efecto, se desfasan. La fase guardada se aleja del mundo
y además habría que reconciliar el estado del director. Se descartaron también dos
reglas suyas: "el bot callado 30 minutos cuenta como aprobado" y "el bot cuenta una
vez por bloque". La compuerta `ci-y-revisor` exige el veredicto del bot para el head
actual, así que el director se habría negado a sí mismo. En su lugar quedó la
excepción `BOT_CALLADO`.

**Candidato 3: el implementador empuja y el veredicto se lee de la pantalla.** Traía
hallazgos verificados en el código que el diseño final adoptó: `cupo_lock` global,
`denied_harnesses` ya existente, deploy como receta ordenada, `merge_method` por repo
y el borrado de la tabla junto con la compuerta. Se descartó su forma. Leer un
`VEREDICTO-JSON` del panel depende del repintado de cada TUI. El push dentro del
encargo del implementador es un efecto externo sin `intent`, que no se puede
reintentar sin duplicar. Clasificar el pedido por texto en código mezcla la regla
con los hechos, que solo un modelo estima. Tratar el sync seguro como comando del
paso gateway ignora que lo corre David en la PC.

Otras dos formas quedaron fuera. Calcular la fase solo desde archivos, sin reducer,
no distingue un push intentado de uno pendiente y pierde idempotencia. La bandeja de
eventos en el gateway (plan cli-eventos-sin-vigias) necesita un plugin, RPCs y una
API de admisión que la versión instalada no ha probado. Queda como posible
transporte futuro de `notify_excepcion`.

## Lo que el director no hace

No guarda la fase. No lee la pantalla para saber si alguien terminó, porque el fin
es un archivo LISTO o VEREDICTO. No manda avances periódicos. No crea cron ni servicio
nuevo. No deja que claw escriba evidencia. No mergea con CI pendiente, con el bot sin
veredicto en el head o con un bloqueante abierto. No publica al gateway. No cambia
de harness sin anunciarlo.

## Riesgos y mediciones pendientes

- Falta elegir el verbo que despierta a `agent:main:dir-<id>`:
  `openclaw system event --mode now --session-key ...` o
  `openclaw agent --agent main --session-key ... --message ...`. Un comentario en
  `scripts/mac/tmux-activity-watch.sh` registra un `system event` que cayó en una
  sesión en modo `steer` y se mezcló con otra corrida. Se mide en 20.0.
- Falta saber si una clave de sesión nueva nace sin el historial de `main`. Se mide
  en 20.0.
- Falta medir cuánto cuesta el primer turno de `agent:main:main` después de `/new`.
  Se mide en 20.0.
- Falta confirmar que cada CLI del registro escribe `.corrida/VEREDICTO-*` sin
  diálogo de permisos cuando arranca con permiso de escritura en un worktree
  detached. Grok y Kimi son los más dudosos. Se mide en 20.4.
- El relevo por rondas necesita que el selector excluya al implementador vigente en
  el rol `write`. Hoy `exclude_authors` se aplica solo al rol `review`. 20.6 extiende
  esa condición con su prueba.
- Los nombres de las decisiones de `RONDAS_AGOTADAS` (`sí` para otra tanda de 5 con
  un tercer modelo, `salta` y `cancela`) son de este documento. La decisión de David
  fija solo que la pregunta llega a él. Se confirma con David antes de 20.8.
- `LATIDO_TOPE` es de 240 segundos. Un `reconciliar` con `gh` y un deploy largo como
  `instalar-mac.sh` puede no caber. El deploy va en segundo plano con su propio
  `intent` y se observa en la pasada siguiente.
- La memoria dice que `sessions cleanup` desde la Mac es local. Barrer
  `agent:main:dir-<id>` puede requerir `exec` en el gateway. Se comprueba en 20.8.
- Reservar 2 cupos por bloque desde el inicio deja al revisor ocupando cupo aunque
  todavía no trabaje. Es el precio de no tener nunca un implementador sin revisor.
- Lo que no llega por aviso (CI, bot, respuesta de David) puede tardar hasta 300
  segundos, que es la cadencia del latido. No se agrega otro reloj.

## Qué se borra

- `scripts/mac/corrida/autoridad-merge.sh` y `scripts/mac/corrida/preaprobaciones.v1.json`,
  con sus copias instaladas en `~/bin/corrida/`.
- En `gates.py`: `KIT_RECEIPT`, `RECEIPT_MODES`, `receipt_mode()`, el camino de recibo
  de `_decide_merge()`, `_receipt_error_code()` y la rama `state.receipt_mode`.
- En `compuerta.sh`: `compuerta_kit_merge`, la llamada a `receipt-mode`, la variable
  `tabla` y los códigos `modo-recibo-invalido`, `kit-no-disponible` y `recibo-ilegible`.
- En `corrida-worker.py`: el subcomando `receipt-mode` y las opciones `--receipt*` y
  `--preaprobaciones` de `gate`.
- En `instalar-mac.sh`: la verificación y la copia de la tabla de preaprobaciones.
- `scripts/tests/test-autonomous-merge-authority.sh`, los casos de `autoridad-merge`
  en `test-merge-allowlist-cierre-pr.sh` y `autoridad-merge` en las listas de
  `test-instalar-mac.sh`.
- En `latido.sh`, el `system event` a `agent:main:sim9-<id>` para corridas con
  director. Las corridas sin director lo conservan.
- En la skill `native-harness-orchestration`, la regla "Main nunca mergea ni
  despliega" y la secuencia manual de compuertas.
- El cron vigía con modelo de U3a en el gateway, cuando la primera corrida completa
  con director termine en 20.10.

Se quedan, aunque sus nombres se parecen: `registro.preaprobaciones[]`, que es la
política de diálogos de `responder.sh`, y el verbo `corrida.sh responder`, que
contesta diálogos de las CLI. Por eso el verbo para David se llama `contestar`.
