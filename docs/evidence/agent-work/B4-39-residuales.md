# B4-39-r1 residuales: cuatro filas B4-28 de `followups.md`

Copia: `b439res.ia9M/g`, worktree detached en `e72027a2ed58735729fc2ddbb2eb9571253cb6ae`, sin commit.
Todo se corrió con `LANG=en_US.UTF-8`. Cada log empieza con su comando y, en las mutaciones, con el
diff completo contra HEAD que estaba aplicado; termina con `rc=<código>`.
`residuales.patch` es `git -C <copia> diff` al final, sin ninguna mutación aplicada.

## 1. `test-corrida-latido.sh` escribía en el estado real de `progress-events`

Causa medida: el `unset PROGRESS_EVENTS_BIN PROGRESS_EVENTS_LOG` del caso (1) dejaba los ticks
siguientes con el default de `scripts/mac/corrida/latido.sh:353` (`$HOME/bin/progress-events.py`,
que corre `publish-all` sobre `$HOME/.local/state/runbook-progress-events`). Además, el primer tick
del caso (1) corría antes de exportar el binario de mentira, así que también usaba el del HOME.

- Arreglo: `scripts/tests/test-corrida-latido.sh:106-113` (el `progress-events` de mentira se crea y
  se exporta en la preparación, antes de cualquier tick) y `:215` (`: > "$PROGRESS_EVENTS_LOG"`, para
  que la aserción del reintento siga midiendo el segundo tick). Se quitó el `unset`.
- Casos nuevos: un HOME señuelo `$T/senuelo` con su propio `bin/progress-events.py` que anota en
  `tocado.log` (`:93-105`). El primer tick del caso (1) corre con `HOME="$SENUELO"` y lo sigue
  `senuelo_intacto "(1)"` (`:211-212`); el caso nuevo `(18)` (`:848-852`) cierra todas las corridas
  y corre un tick con el mismo HOME señuelo después de todos los demás casos.
- Rojo (`1-rojo.log`): `FAIL: (1) el latido de la prueba corrio el progress-events del HOME de quien la lanza: publish-all`, rc=1.
- Verde (`1-verde.log`): `TODO VERDE: test-corrida-latido`, rc=0. Corrido con el HOME real. Antes y
  después, `find ~/.local/state/runbook-progress-events -newer <helper>` dio 0 archivos, así que la
  corrida no escribió en el estado real.
- Mutación 1 (`1-mutacion-1.log`): vuelve el `unset PROGRESS_EVENTS_BIN PROGRESS_EVENTS_LOG` después del
  caso (1). Falla `FAIL: (18) el latido de la prueba corrio el progress-events del HOME de quien la lanza: publish-all`, rc=1.
- Mutación 2 (`1-mutacion-2.log`): el `export PROGRESS_EVENTS_BIN=...` vuelve a quedar después del primer
  tick, como estaba antes. Falla `FAIL: (1) el latido de la prueba corrio el progress-events del HOME de quien la lanza: publish-all`, rc=1.
- Las dos mutaciones corrieron con `HOME=<scratchpad>/home-externo`, un directorio vacío, para que los
  ticks mutados no tocaran el estado real. El rojo no lo necesitó: falla en el primer tick, que ya corre
  con el HOME señuelo.

## 2. El candado del inventario de B4-21 no veía `OPENCLAW_WATCH  1`

Ubicación: `scripts/tests/test-agent-work-routing.py`, en
`test_model_wakes_inventory_lists_every_repo_wake_source` (lo agregó `2802b17`, B4-21). Usaba BRE con
`OPENCLAW_WATCH 1` literal. El de B4-22 ya usaba `OPENCLAW_WATCH[[:space:]=]+[\"']?1`.

- Arreglo: `scripts/tests/test-agent-work-routing.py:21-27`. La búsqueda pasa a una función de módulo
  `repo_wake_sources(root)` que la prueba existente llama en `:237`, y se cambia a ERE (`-E`) con
  `OPENCLAW_WATCH[[:space:]]+1` (`:24`). Al pasar a ERE, el `$` de `"$vigia"` se escapa como `\$`.
  Sobre el repo real, la lista vieja y la nueva son idénticas: los mismos 16 archivos, con el mismo md5.
- Caso nuevo: `test_wake_source_search_sees_the_mark_with_any_spacing` (`:270`). Arma un repo git
  temporal con la marca escrita con un espacio, con dos y con un tabulador; además pone las otras tres
  fuentes (`--vigia`, `vigia-mac`, `"$vigia" = "claw"`), un `OPENCLAW_WATCH_RUN` que no cuenta y un
  archivo en `scripts/tests/`, que queda excluido. Afirma la lista literal
  `["scripts/claw.sh", "scripts/dos.sh", "scripts/mac.sh", "scripts/tab.sh", "scripts/una.sh", "scripts/vigia.sh"]`.
- Rojo (`2-rojo.log`, con el patrón viejo ya extraído a `repo_wake_sources` sin cambios):
  `AssertionError: Lists differ: ...`, con `- ['scripts/claw.sh', 'scripts/mac.sh', 'scripts/una.sh', 'scripts/vigia.sh']`.
  Faltan `dos.sh` y `tab.sh`. `FAILED (failures=1)`, rc=1.
- Verde (`2-verde.log`): `Ran 16 tests`, `OK`, rc=0.
- Mutación 1 (`2-mutacion-1.log`): `[[:space:]]+` vuelve a ser un espacio literal. Falla la misma
  aserción: faltan `dos.sh` y `tab.sh`. rc=1.
- Mutación 2 (`2-mutacion-2.log`): `[[:space:]]+` pasa a ` +`, solo espacios. Falla la aserción porque
  falta `scripts/tab.sh`. rc=1.
- Mutación 3 (`2-mutacion-3.log`): el `$` de `"$vigia"` queda sin escapar en ERE, donde funciona como
  ancla. Falla la aserción porque falta `scripts/claw.sh`. rc=1.

## 3. `scripts/lanzar-lead.sh` saltaba un `registro.json` ilegible

- Arreglo: `scripts/lanzar-lead.sh:54-55`. Se quitó el `try/except Exception: continue`. Un registro
  ilegible hace fallar el python, que entonces no imprime nada. El `case` existente lleva esa salida
  vacía al `ATORADO` que el script ya usa: `ATORADO no pude comprobar si <sesion> es una sesion gestionada`,
  con `exit 6`.
- Caso nuevo: `5d` en `scripts/tests/test-lanzar-lead.sh:122-129`. Usa su propio `CORRIDA_STATE`, con
  un único registro `{no es json`. Afirma rc 6, que la última línea sea exactamente
  `ATORADO no pude comprobar si s15 es una sesion gestionada` y que no exista la sesión `s15`.
- Cambio de una fila existente: el caso (5) tenía un `r-roto` ilegible que debía lanzar
  ("registro ilegible ajeno, como siempre"). Contradice este cierre, así que se quitó esa fila y se
  ajustaron su comentario y su `ok`. El registro ilegible ahora vive solo en `5d`.
- Rojo (`3-rojo.log`): `FAIL: (5d) un registro ilegible debia frenar el lanzamiento: rc=0 marca=OPENCLAW_WATCH=1 ... LISTO s15 ...`, rc=1.
- Verde (`3-verde.log`): `TODO VERDE: lanzar-lead`, rc=0.
- Mutación 1 (`3-mutacion-1.log`): vuelve el `try/except Exception: continue`. Falla la misma aserción
  de `5d`, rc=1.

## 4. El `[ -n "$gest" ]` de `avisos atender` no lo fijaba ninguna prueba

No hay arreglo de código. La guarda sigue en `scripts/mac/corrida/avisos.sh:246`, sin cambios.

- Caso nuevo: `(r)` en `scripts/tests/test-corrida-avisos.sh:515-525`. La corrida `t25` está abierta y
  no tiene gestionadas. Tiene un pendiente `{"schema":"corrida-aviso.v1","tipo":"cierre"}` sin `sesion`.
  Afirma `avisos: 0 atendidos, 1 descartados` y el motivo literal `la sesion  ya no esta registrada`
  (con doble espacio, porque la sesión está vacía).
- Verde (`4-verde.log`): `avisos.sh` sin tocar más el caso nuevo. `TODO VERDE: test-corrida-avisos (U1 + U3 hook)`, rc=0.
- Rojo = mutación 1 (`4-rojo.log`, que es copia literal de `4-mutacion-1.log` con una línea de cabecera):
  se quita el `[ -n "$gest" ] &&` de `avisos.sh:246`. Falla
  `FAIL: (r) el pendiente sin sesion no quedo descartado como no registrado: la sesion  es gestionada: la reporta su host`, rc=1.
  La lista vacía de gestionadas produce una línea vacía, y esa línea casa con la sesión vacía. La
  mutación se deshizo.

## Suites y pre-commit

- `suites.log`: con bash 5 corrieron `test-corrida-latido.sh`, `test-agent-work-routing.py -v`,
  `test-lanzar-lead.sh`, `test-corrida-avisos.sh` y `test-corrida-nucleo.sh`. Con `/bin/bash` 3.2.57
  primero en el `PATH` corrieron las cuatro suites bash, que son las que tienen variante bash32 en
  `docs/evidence/agent-work/`; la del routing es python. Cada suite deja su `rc_suite=`. El total va
  en la última línea.
- El diff no trae `declare -A`, `local -A`, `mapfile`, `readarray`, `${var,,}` ni `${var^^}`.
- `pre-commit.log`: `pre-commit run --files` sobre las cinco rutas. Todos los hooks pasaron, rc=0, y no
  se corrigió ningún archivo.

## Hallazgo nuevo, fuera de estas cuatro filas: `test-corrida-nucleo.sh` tiene la misma fuga

Al correr `suites.log`, el estado real cambió:
`~/.local/state/runbook-progress-events/publish-all.cursor` pasó de mtime `Oct 7 13:21` a
`Oct 8 22:26:58`, con contenido `smoke-grok-82094`. Es el único archivo de ese árbol con mtime posterior
a las 22:16, cuando arrancó `suites.log`. El directorio también cambió de mtime, por el
`replace_atomic`. La hora cae dentro de la corrida de suites, en la parte de bash 3.2.

La causa está en el código, en `scripts/tests/test-corrida-nucleo.sh:1211`:
`( cd "$T" && CORRIDA_STATE="$T/lat" bash "$CORR_ABS" latido )` corre con el HOME real y sin
`PROGRESS_EVENTS_BIN`. Por eso `latido.sh:353-355` ejecuta `~/bin/progress-events.py publish-all`
sobre el outbox real, que tiene 41 corridas con un evento en `queue/`. El `OPENCLAW_BIN` de esa prueba
es su stub (`:131`), así que no salió nada al gateway. `get()` falla antes de escribir `attempts/`, así
que las colas siguen con su evento. El único efecto fue que el cursor de rotación de `publish-all`
avanzó.

Las corridas de verde y de mutación de `test-corrida-latido.sh` no tocaron ese árbol: lo comprobé con
`find -newer` antes y después de `1-verde.log`, y las mutaciones corrieron con HOME vacío. No arreglé
nucleo porque está fuera de las cuatro filas. Hay que anotarlo como fila nueva: aislar el
`latido` de `test-corrida-nucleo.sh:1211` con un `PROGRESS_EVENTS_BIN` de prueba, con su señuelo de HOME.
