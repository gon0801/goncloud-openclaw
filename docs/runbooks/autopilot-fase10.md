# Autopilot de la Fase 10 — goals y cobertura del motor de precios (Orbit)

Esto lo ejecutas tú, el **lead**, en autopilot. **David no está y no se le pregunta nada**: lo que necesitarías consultarle ya está decidido en la tabla de preaprobaciones, o es una fila de la tabla de atores. Si algo no está escrito aquí ni en `docs/runbooks/loop-autopilot.md`, se declara como residual en el PR y la corrida sigue.

La fase construye las **dos piezas que faltan antes de que David pueda correr la sonda de escritura**: la herramienta de goals (fila A.1 del plan) y el recuadro de cobertura (fila A.7), y produce el **veredicto sobre las fuentes del envío** (fila E.0a) hasta donde los datos de Orbit alcancen. **No despliega nada, no aplica la migración 0039, no siembra goals en producción y no cambia un solo precio en Amazon.** Lo que queda listo para David al cierre son las filas E.2, D.0, el goal del producto controlado y A.4 del plan, en ese orden, y esta fase no las ejecuta.

Versión 5.1, 2026-09-18 UTC (el runbook ya está en `main`; el PR #302 del plan ya mergeó, así que Q0 arranca en `1` + `MERGED`). Un tercer lector fresco (sobre la v3) devolvió 21 ítems, 19 de una oración; están incorporados. **Aquí se detiene la verificación** (regla de la receta: se entrega cuando una pasada trae solo ítems de una oración); los residuales quedan declarados en el PR #72. La versión 3 pasó por un verificador (que cazó dos nombres de migración inventados) y un revisor (20 hallazgos, 7 bloqueantes, todos de texto), incorporados aquí. La versión 1 fue ejecutada en seco por un lector de contexto fresco que devolvió 22 hallazgos; la versión 2, por un segundo lector que devolvió 20 (entre ellos dos medidos que cambian el mecanismo: el `cd` de una herramienta no mueve el cwd del proceso del CLI, que es la clave del hook del kit, y muse imprime con sangría, así que su línea de contrato no se lee de la pantalla). Todos están incorporados aquí. Hereda de `autopilot-fase8.md` (versión 2) todo lo que ahí se midió y sigue igual: muse en el checkout principal, uno a la vez; el lead en su worktree; pruebas con la base local de Homebrew; el candado léxico del kit; el progreso en archivo más comentario de PR. Lo que cambia respecto de la Fase 8 está marcado **(nuevo en la 10)**.

---

## Qué runbook manda

Manda **este archivo tal como está en `origin/main` de goncloud-openclaw**. Llega ahí por su propio PR (paso 0.2) antes de lanzar un solo carril.

La cadena completa, de mayor a menor: `docs/runbooks/loop-autopilot.md` (salvo la tabla de preaprobaciones de abajo, que es la excepción que el propio loop reconoce) > `docs/CONTEXTO.md` de Orbit, reglas 1–10 > el spec `docs/superpowers/specs/2026-09-15-repricing-01-design.md` v1.3 > `plans/repricing-01.md` **v1.3** > este runbook. El plan y el spec mandan en **qué** se construye y en la DoD; este runbook manda en **cómo** corre la fase (quién, ramas, archivos, cola, atores). Si el plan y este runbook se contradicen, gana el plan y el lead lo escribe como residual en el PR; **ninguna tarea de esta fase edita el cuerpo de una fila del plan; el ítem de cierre Q4 edita solo las celdas de estado**.

**El plan v1.3 tiene que estar en `origin/master` antes de arrancar los carriles** (nuevo en la 10). Vive en el PR #302 de Orbit (rama `fase10/plan-v1.3`), y es el primer ítem de la cola (Q0). Las DoD de A.1 y A.7 que van al encargo son las de la v1.3, no las de la v1.2: la v1.3 quita la migración y `app/listings.py` de A.7, mete `app/precio/fuentes.py` y `tools/precio_cobertura.py`, y define la lista de excepciones del candado de pureza que A.1 y A.7 necesitan. Con la v1.2 en `master`, un carril entregaría contra una DoD que ya no es la del plan.

---

## Quién

| Rol | Quién | Qué hace en esta fase |
|---|---|---|
| **claw** | el agente `main` del gateway | Lanza al lead (sesión `fase10-lead`, marcada con `OPENCLAW_WATCH`) y lo vigila por tmux. Relanza si se cae. **Nuevo en la 10**: si el runbook no está en `main`, lanza la sesión aparte `fase10-runbook` del paso 0.2 (la marca, la cierra y la desmarca al terminar); y después del `LISTO` de la fase hace la limpieza que el lead no puede hacerse a sí mismo (postmerge de Q4: desmarcar y matar `fase10-lead`, borrar `wt-fase10-lead` y `fase10/cierre`, y correr el script de cierre hasta `VERDE`). No mergea ni despliega. |
| **lead** | un CLI en tmux, de cualquier host que el kit de merge conozca; la lista vive en la sección 1 del loop y claw elige por preferencia y cuota. **Sesión `fase10-lead`, con cwd `/Users/dn/dev/wt-fase10-lead`** (nuevo en la 10: la clave del estado del hook del kit es la ruta de proyecto de la sesión, así que todos los merges de Orbit salen de ahí; ver regla 14) | Escribe los encargos, audita, corre la cruzada, aprueba, mergea por la ruta del kit, escribe progreso y cierra. **Además implementa el carril D** (E.0a), que el plan le asigna. No escribe código de producto. |
| **implementador** | **muse**, en los carriles A y B, **uno a la vez** | Escribe el código en el checkout principal de Orbit y reporta con la línea de contrato. No hace push ni abre PR. |
| **revisor cruzado** | otra IA por `cross-review.ps1` | Segunda opinión sobre el SHA del PR. En A y B implementa muse, que no es candidato a revisor: se pasa `-Excluir ''` y se anota en el PR quién implementó. En el carril D y en Q4 implementa el lead: se excluye **al host del lead** con `-Excluir <host>`, donde `<host>` es el valor del conjunto cerrado de `cross-review.ps1` (`claude`, `codex`, `grok`, `kimi`, `qwen`, `glm`): si el lead es `zcode` se pasa `-Excluir glm`; si es `dsh`, no está en el conjunto, se pasa `-Excluir ''` y se anota en el PR. En Q0 el autor es `claude` (el lead de la revisión de la Fase 8): `-Excluir claude`, sea quien sea el lead de esta fase. |
| **David** | el dueño | **Ninguna acción durante la corrida** (salvo, si quiere, mergear él mismo el runbook o el PR #302 antes del 0.0; el 0.0 lo detecta). Al cierre lee el reporte. Lo que queda listo para él son las filas E.2, D.0, el goal del producto controlado y A.4 del plan, que esta fase prepara y no ejecuta. |

**Cómo lanza claw al lead** (nuevo en la 10; medido el 2026-09-17 que el cwd del proceso del CLI es el que lee el hook del kit —`#{pane_current_path}` y `lsof` no cambian con un `cd` de la herramienta—, así que el cwd se fija al crear la sesión y no después):

```
T=/opt/homebrew/bin/tmux
$T has-session -t fase10-lead 2>/dev/null && echo YA-EXISTE || \
  $T new-session -d -s fase10-lead -x 200 -y 50 -c /Users/dn/dev/wt-fase10-lead "PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:\$PATH <cli-del-host> <flag-sin-preguntas>"
$T set-environment -t fase10-lead OPENCLAW_WATCH 1
$T display-message -p -t fase10-lead '#{pane_current_path}'
n=0; until [ $n -ge 10 ]; do n=$((n+1)); sleep 2; done
$T capture-pane -p -t fase10-lead | grep -v '^[[:space:]]*$' | tail -4
$T send-keys -t fase10-lead -l 'Lee docs/runbooks/autopilot-fase10.md en origin/main de goncloud-openclaw y ejecuta la Fase 10 -saikit'
$T send-keys -t fase10-lead Enter
n=0; until [ $n -ge 5 ]; do n=$((n+1)); sleep 2; done
$T capture-pane -p -t fase10-lead | grep -v '^[[:space:]]*$' | tail -6
```

`<cli-del-host>` y `<flag-sin-preguntas>` son los que claw usa hoy para ese host (el flag sin preguntas de cada host del kit vive en el lanzador de claw, no aquí: `unknown` en este documento, y se lee de ahí); la línea de `display-message` debe imprimir `/Users/dn/dev/wt-fase10-lead`; la primera captura, 20 s después, tiene que mostrar la caja de texto del CLI antes de mandar nada (si no, se espera otros 20 s: un `send-keys` a un TUI que no tomó el teclado se pierde sin rastro, con el literal `-saikit` dentro); el `Enter` va en llamada aparte y la segunda captura confirma que el mensaje entró (si sigue en la caja, un `Enter` más); el mensaje lleva el literal `-saikit` (regla 14). Que el flag sin preguntas surtió efecto se comprueba con `ps -o args= -p "$($T display-message -p -t fase10-lead '#{pane_pid}')"`, que debe mostrar el flag en la línea del proceso. Sin flag sin preguntas, el primer diálogo de permiso a mitad de un turno de merge lo contesta el vigilante con un mensaje sin `-saikit` y borra el estado del sello.

**Cómo se lanza a muse.** Una sesión de tmux por repo, ya viva, parada en el checkout principal: `muse-goncloud-Orbit`. Medido el 2026-09-17: `/opt/homebrew/bin/tmux display-message -p -t muse-goncloud-Orbit '#{pane_current_path}'` imprime `/Users/dn/dev/goncloud-Orbit`. El lead deja el `BRIEF.md` en la raíz de ese checkout, manda el encargo a la sesión con `/opt/homebrew/bin/tmux send-keys -t muse-goncloud-Orbit 'Lee BRIEF.md en la raiz y ejecutalo completo; al terminar imprime la linea de contrato' Enter`, y lee la respuesta con `/opt/homebrew/bin/tmux capture-pane -p -t muse-goncloud-Orbit -S -60 | tail -40`, buscando la línea de contrato de la sección 2 del loop. Un encargo a la vez: la sesión y el checkout son uno solo. **Antes del primer encargo**, y medido el 2026-09-17 que la barra de muse dice `muse-spark-1.3 · max · ~/dev/goncloud-Orbit · YOLO`, el lead baja el esfuerzo: `/opt/homebrew/bin/tmux send-keys -t muse-goncloud-Orbit '/effort high' Enter` y confirma con el `capture-pane` de arriba que la barra dice `high` (con `max` la sesión murió a los 180 s en la Fase 8). **Cómo se espera la línea de contrato** (nuevo en la 10; medido el 2026-09-17 que muse imprime todo con dos espacios de sangría y que la pantalla conserva el eco del brief y el `LISTO` del encargo anterior, así que un `grep` de la pantalla o no ve nada o ve una línea falsa). Por eso **la línea de contrato se lee de un archivo, no de la pantalla**: cada `BRIEF.md` termina con «al terminar, escribe tu línea de contrato, y solo esa, en `.saikit/scratch/<carril>/contrato.txt` de la raíz del checkout, además de imprimirla». `<carril>` es `fase10-A`, `fase10-B` o `fase10-D` en todo este documento (medido: `.saikit/scratch/A/` y `B/` ya existen con el `tdd.md` de la Fase 8 y no se pisan). Antes de cada encargo el lead borra el archivo anterior (`rm -f /Users/dn/dev/goncloud-Orbit/.saikit/scratch/<carril>/contrato.txt`) y deja en segundo plano, releyéndolo al volver,

```
/opt/homebrew/bin/timeout 10800 bash -c 'until test -s /Users/dn/dev/goncloud-Orbit/.saikit/scratch/<carril>/contrato.txt; do sleep 120; done'; echo "muse rc=$?"; cat /Users/dn/dev/goncloud-Orbit/.saikit/scratch/<carril>/contrato.txt
```

`rc=0` es la respuesta: se lee con `sed -n 1p <archivo> | sed 's/^ *//'` (muse puede sangrar) y tiene que empezar por `LISTO ` o `ATORADO `; cualquier otra cosa es `ATORADO sin reporte` y aplica la prueba de vida de la fila de atores; `rc=124` es el tope de **tres horas** sin archivo (un carril de código son horas, no minutos) y aplica la fila de atores «Muse no responde», que **antes de reenviar nada exige una prueba de vida**: dos `capture-pane` separados por dos minutos; si la pantalla cambió, muse sigue trabajando, se renueva el bucle y se anota en el progreso; solo con pantalla idéntica **y** sin archivo se reenvía la instrucción, una vez. Probado en seco con `printf 'LISTO abc123\n' > <archivo>` (rc=0) y con el archivo ausente (rc=124); un `touch` no sirve, `test -s` exige contenido. La pantalla (`capture-pane`) se usa para leer qué está haciendo y como prueba de vida, nunca como compuerta. Muse **no se marca** con `OPENCLAW_WATCH` (corre en `YOLO`, no abre diálogos de permiso). Los dos encargos de esta fase están escritos abajo, en «Carriles», y se copian al `BRIEF.md` tal cual, con la DoD de la fila pegada verbatim desde `origin/master:plans/repricing-01.md` en el momento de lanzar.

---

## Arranque

**Paso 0.0 — precondiciones.** Corre esto antes de nada (todas las líneas llevan `-C` o ruta absoluta; el cwd de tu proceso es `/Users/dn/dev/wt-fase10-lead` y no se cambia).

```
test -r /Users/dn/dev/summonaikit-claude/tools/MANIFEST.sha256 || echo ATORADO kit ausente
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit fetch -q origin
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit show origin/master:.saikit/autopilot.json
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit status --porcelain | head -5
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit ls-tree --name-only origin/master migrations/ | sort | tail -1
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit show origin/master:plans/repricing-01.md | grep -c '^Version: 1.3'
/opt/homebrew/bin/gh pr view 302 --repo gon0801/goncloud-Orbit --json state --jq .state
/opt/homebrew/bin/pg_isready -h localhost -p 5432
/opt/homebrew/bin/psql "postgresql://orbit:orbit@localhost:5432/postgres" -Atc "select 1"
/opt/homebrew/bin/tmux display-message -p -t muse-goncloud-Orbit '#{pane_current_path}'
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit worktree list | grep -c wt-fase10-lead
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw fetch -q origin; /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw show origin/main:docs/runbooks/autopilot-fase10.md 2>/dev/null | head -1
ls /Users/dn/dev/orbit-insumos/E.0/ 2>/dev/null | wc -l
[ -n "${TMUX_PANE:-}" ] && /opt/homebrew/bin/tmux display-message -p -t "$TMUX_PANE" '#S #{pane_current_path}'
```

Esperado, en orden: sin salida; sin salida; la línea `{"merge":true,"merge_despliega":"no","salud_url":null,"revert_si_rojo":true,"rama":"master","sin_verify_app":false,"telegram":false}`; **sin salida** (el checkout principal limpio); `migrations/0039_precio.sql`; `1` si el plan v1.3 ya está en `master` o `0` si todavía no; `MERGED` u `OPEN`; `localhost:5432 - accepting connections`; `1`; `/Users/dn/dev/goncloud-Orbit`; `1`; la línea `# Autopilot de la Fase 10 — goals y cobertura del motor de precios (Orbit)` (si sale vacío, el runbook no está en `main` y el paso 0.2 va **antes** que todo lo demás); `0` hoy (la carpeta de insumos de E.0a no existe; un número mayor que cero significa que David dejó documentos y el carril D los usa); y `fase10-lead /Users/dn/dev/wt-fase10-lead`. **Si la sesión o el cwd no son esos, no se corrige con `cd` ni con `rename-session`** (medido: el `cd` de una herramienta no mueve el cwd del proceso, y renombrar la sesión por repo del host la secuestra): es `ATORADO lead lanzado fuera de wt-fase10-lead` y claw relanza con la línea de «Quién», **después de `/opt/homebrew/bin/tmux kill-session -t fase10-lead`** (la línea empieza con `has-session … && echo YA-EXISTE` y con la sesión viva no hace nada). Sin `TMUX_PANE` no estás en tmux: `ATORADO lead fuera de tmux`. Lo mismo para `ATORADO lead sin cwd`.

**Cómo se lee el par «plan» / «PR #302».** `1` + `MERGED` es lo normal cuando la fase arranca después de Q0: sigue al 0.1. `0` + `OPEN` es lo esperado si la fase arranca antes de que David lo haya mergeado: Q0 es tuyo, ve a la cola. `0` + `MERGED` o `1` + `OPEN` no pueden ocurrir juntos; si ocurre, `ATORADO plan v1.3 en estado inconsistente` y la fase para. `CLOSED` sin merge: `ATORADO plan v1.3 cerrado sin mergear` y la fase para, porque las DoD de los carriles serían las de la v1.2.

**Detienen la fase**: el kit ausente; `autopilot.json` ausente de `origin/master`; el PR #302 cerrado sin mergear; el lead lanzado fuera de tmux o fuera de `wt-fase10-lead`. **Worktree del lead ausente (línea 11 en `0`), una sola regla**: la sesión que corre el 0.0 está viva con ese cwd borrado, así que el lead **lo crea y después se detiene** para que claw relance: si Q0 está `OPEN`, `/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit worktree add /Users/dn/dev/wt-fase10-lead fase10/plan-v1.3` (la rama existe local y remota; sin `-b`); si Q0 ya mergeó, `… worktree add /Users/dn/dev/wt-fase10-lead -b fase10/envio-veredicto origin/master`; en los dos casos el `ln -s` de la regla 2; y entonces `ATORADO lead sin cwd`. La fase no avanza en esa sesión. Este 0.0 lo corre **solo** la sesión `fase10-lead`; la sesión `fase10-runbook` del paso 0.2 no lo corre. **Detiene el arranque de los carriles de muse, no la fase**: un checkout principal sucio; el carril D del lead puede avanzar igual mientras se resuelve.

La credencial `orbit:orbit` de esas líneas es la del Postgres **local y desechable** de desarrollo, ligada a `localhost`, y no abre nada más: no se reutiliza contra otro destino, no se copia a un archivo de configuración y no aparece en ningún comando que salga de esta máquina. Producción se toca solo por el camino de la regla 9, que lee su cadena de conexión del contenedor y nunca la escribe en el runbook.

**Paso 0.1 — Q0, el plan v1.3.** Si el 0.0 dio `0` + `OPEN`, el primer merge de la cola es el PR #302 (Orbit, rama `fase10/plan-v1.3`, árbol `/Users/dn/dev/wt-fase10-lead`), por la ruta del kit y **con `--dry-run` antes que nada**: es a la vez el ajuste del plan y la prueba de que el sello del kit funciona en tu host y tu ruta de proyecto. Un `sin estado del hook` en ese dry-run detiene la fase; no se sigue esperando que el siguiente merge sí pase. La compuerta está en la cola. Ningún carril de muse arranca hasta que el 0.0 diga `1` + `MERGED`.

**Paso 0.2 — el runbook está en git, y va antes que Q0.** Este documento vive en `gon0801/goncloud-openclaw`, rama `docs/runbook-fase10`, worktree `/Users/dn/dev/wt-fase10`, con su PR abierto por el autor (`claude`, 2026-09-17), y **se mergea a `main` de openclaw antes de lanzar la fase**, porque mergear ahí es desplegar (sección 7 del loop). Si el 0.0 ya lo encontró en `main` (David lo mergeó), este paso no existe. Si no, **no lo puede mergear la sesión del lead** (medido: la clave del estado del hook es el cwd del proceso del CLI, `/Users/dn/dev/wt-fase10-lead`, y un `cd` de la herramienta no la cambia). **Orden para claw**: antes de lanzar `fase10-lead`, claw corre la línea 12 del 0.0; si sale vacía, primero resuelve este paso y solo después lanza al lead. Lo mergea **David desde GitHub** antes de lanzar (es un PR de docs en su repo y el kit solo obliga al lead), o claw lanza una sesión aparte `fase10-runbook` cuyo único encargo es este paso, con este bloque (no el de «Quién»: aquella sesión, aquel cwd y aquel mensaje son otros, y este archivo todavía no está en `main`, así que el encargo va pegado en el mensaje):

```
T=/opt/homebrew/bin/tmux
$T has-session -t fase10-runbook 2>/dev/null && echo YA-EXISTE || \
  $T new-session -d -s fase10-runbook -x 200 -y 50 -c /Users/dn/dev/wt-fase10 "PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:\$PATH <cli-del-host> <flag-sin-preguntas>"
$T set-environment -t fase10-runbook OPENCLAW_WATCH 1
$T display-message -p -t fase10-runbook '#{pane_current_path}'
n=0; until [ $n -ge 10 ]; do n=$((n+1)); sleep 2; done
$T capture-pane -p -t fase10-runbook | grep -v '^[[:space:]]*$' | tail -4
$T send-keys -t fase10-runbook -l 'Lee docs/runbooks/autopilot-fase10.md de este arbol (rama docs/runbook-fase10) y ejecuta solo su paso 0.2: mergea el PR 72 de gon0801/goncloud-openclaw por la ruta del kit; no toques nada mas; al terminar escribe LISTO <merge_commit> en /tmp/fase10-runbook.contrato -saikit'
$T send-keys -t fase10-runbook Enter
```

(`display-message` debe imprimir `/Users/dn/dev/wt-fase10`; la espera y las capturas son las mismas de «Quién»; claw espera el archivo con `/opt/homebrew/bin/timeout 7200 bash -c 'until test -s /tmp/fase10-runbook.contrato; do sleep 120; done'` y lo lee.) En esa sesión: ronda cruzada con `export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH; /Users/dn/.local/bin/pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto -Excluir claude -Alcance last-commit`, `APPROVE lead <sha>`, ventana segura leída con `~/.openclaw/bin/openclaw cron list` (ningún `Next` en 15 minutos) y `TZ=America/New_York date` (fuera de :05–:15 de las horas impares), y los tres comandos de la sección 6 del loop desde ahí, en el mismo turno que el sello; el dry-run del kit pasa cuando imprime `DRY-RUN: gate en verde` y sale 0 (no imprime `LISTO`). **Canary**: la línea 12 del 0.0 imprime el título del runbook. **Reversa** (solo si el canary falla o el sync del gateway se queja): en esa misma sesión, rama `docs/runbook-fase10-revert` desde `origin/main` con `git revert --no-edit <merge_commit>`, push, PR, y desde ese árbol el script de merge del kit por ruta absoluta con `--revert-de <merge_commit> --confirmado` (el modo exige un solo commit cuyo árbol iguale `<merge_commit>^`; medido en el script, l.395–406). openclaw no tiene `verify/`: su `autopilot.json` trae `sin_verify_app: true` y el Drive no aplica. La sesión termina escribiendo `LISTO <merge_commit>` en `/tmp/fase10-runbook.contrato` y **no borra su propio worktree** (es su cwd; misma regla que el postmerge de Q4). **Lo que sigue es de claw**, después de ese `LISTO`: `/opt/homebrew/bin/tmux set-environment -u -t fase10-runbook OPENCLAW_WATCH`, `/opt/homebrew/bin/tmux kill-session -t fase10-runbook`, `/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw worktree remove /Users/dn/dev/wt-fase10` y `/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw branch -D docs/runbook-fase10`, siempre que el 0.0 ya imprima el título. Si David lo mergeó desde GitHub, claw hace esas dos últimas líneas igual, antes de lanzar al lead. Sin eso, un lead que reemplace al primero no tiene de dónde leerlo (sección 9 del loop). Ese PR no cuenta contra el tope de tres PRs abiertos de Orbit: es otro repo.

**Paso 0.3 — la tarea del tracker.** El `CLAUDE.md` de Orbit lo hace obligatorio. Al arrancar, con la skill `appflowy-ehv-task`, se marca `In progress` la tarea `AUTO-07 Repricing (plan formal)` con una nota que diga que corre la Fase 10 y qué filas cubre (A.1, A.7, E.0a). Al cierre se anota el resultado. No se crea tarea nueva. **Si el host del lead niega el `ssh goncloud` de la skill** (nuevo en la 10: en la Fase 8 el clasificador de permisos del host `claude` lo negó como lectura de producción), el comando literal de la skill queda pegado en el cuerpo del PR de cierre y en `siguiente_paso` del progreso, y David lo corre; no se insiste ni se rodea con un subagente.

**Paso 0.4 — lee el plan.** `plans/repricing-01.md` en `origin/master` de Orbit, **v1.3**, y su spec v1.3. Las filas que esta fase implementa son **A.1, A.7 y E.0a**, y sus DoD van verbatim al encargo de cada carril. Antes de escribir el primer `BRIEF.md`, relee la fila desde `origin/master` con `git show`, no desde ningún árbol abierto: la celda de A.7 cambió entre la v1.2 y la v1.3.

**Paso 0.5 — primer progreso.** Escribe `/Users/dn/dev/goncloud-Orbit/.saikit/progress/10.json` con los tres carriles en `pendiente` y Q0 en la cola, con la regla 10, y pégalo como comentario en el PR #302 si sigue abierto o en el primer PR que abras.

**Dónde vive cada cosa.**

| Repo | Ruta local | Default | Copia desplegada |
|---|---|---|---|
| `gon0801/goncloud-Orbit` | `/Users/dn/dev/goncloud-Orbit` (checkout de muse) y `/Users/dn/dev/wt-fase10-lead` (worktree del lead; ya existe, nació para el PR #302 en la rama `fase10/plan-v1.3`) | `master` | `/mnt/data/appdata/orbit` en el host `goncloud` — **fuera de alcance**: `merge_despliega` es `no` y esta fase no despliega |
| `gon0801/goncloud-openclaw` | `/Users/dn/dev/goncloud-openclaw` y el worktree `/Users/dn/dev/wt-fase10` | `main` | el gateway, por sync — **solo** para mergear este runbook en el paso 0.2 |

---

## Preaprobaciones del dueño

| Operación | Alcance | Decisión |
|---|---|---|
| Arrancar la Fase 10 | Esta fase, con las filas A.1, A.7 y E.0a | **Aprobado**: esta fila es la autorización (regla de la skill `autopilot-runbook`: la tabla es el permiso; no se pregunta). Antecedente: el «si» de David del 2026-09-17 a «escribo el ajuste del plan y el runbook» y su encargo previo de dejar listo lo que sigue de Repricing. Si claw recibe de David un go distinto, ese manda. |
| Mergear el PR #302 (plan v1.3) a `master` de Orbit por la ruta del kit | Solo ese PR, con su CI verde y `APPROVE lead <sha>`; loop reducido de docs | **Aprobado** |
| Crear ramas, worktrees y PRs en `gon0801/goncloud-Orbit` | Las cuatro ramas `fase10/*` de este runbook, la `fase10/plan-v1.3` que ya existe, y las de corrección de la revisión de cierre `fase10/<carril>-cierre-r<N>` | **Aprobado** |
| Mergear a `master` de Orbit por la ruta del kit | Los PRs de esta fase, con su `APPROVE lead <sha>` y CI verde | **Aprobado** |
| Mergear este runbook a `main` de goncloud-openclaw | Solo `docs/runbooks/autopilot-fase10.md` | **Aprobado** |
| Lanzar implementadores y revisores cruzados con costo de tokens | Hasta el presupuesto del inventario | **Aprobado** |
| Leer producción de Orbit por `ssh goncloud` con consultas de **solo lectura** | Solo el carril D y el readback de A.7, solo `SELECT`, solo por el rol lector, y **solo el lead** | **Aprobado** |
| Editar **las celdas de estado** de las filas A.1, A.7 y E.0a del plan y `docs/CHAT-CONTEXT.md` | Solo en el ítem de cierre Q4, solo esas celdas, con el SHA de squash | **Aprobado** |
| Marcar la tarea `AUTO-07` en el tracker | Al arrancar y al cerrar | **Aprobado** |
| Agregar `goals_write.py` y `fuentes.py` a la lista de excepciones del candado de pureza de `app/precio/` | Solo esos dos módulos, cada uno con su candado propio, como dice el plan v1.3 | **Aprobado** |
| Aplicar la migración 0039 a la base de producción | — | **Negado**: es la fila D.0 del plan y la corre David |
| Sembrar claves `precio_*` en la config de producción | — | **Negado**: es la fila D.0 |
| Sembrar goals en `precio_goal` de producción, en cualquier modo | — | **Negado**: el goal del producto controlado lo siembra David con la herramienta de A.1, después de D.0 |
| Desplegar código de Orbit | — | **Negado**: `merge_despliega` es `no`; el deploy es de David |
| Escribir un precio en Amazon o en Mercado Libre, aunque sea un centavo | — | **Negado**: es la fila A.4 del plan y lleva go literal de David |
| Tocar `.saikit/autopilot.json` en cualquier repo | — | **Negado**: el kit lo lee de `origin/master` y rechaza el PR que lo toque |
| Editar el cuerpo de una fila del plan, o el spec | — | **Negado**: la v1.3 ya es el ajuste; una discrepancia nueva se declara, no se corrige aquí |
| Implementar cualquier fila que no sea A.1, A.7 o E.0a | — | **Negado**: A.5 y A.6 esperan a que A.1 y A.7 estén en `master`; E.0b espera el veredicto de E.0a; el resto de E, 0, B y M espera |
| Cambiar la configuración del gateway (por ejemplo, registrar la fase 10 en el tablero) | — | **Negado**: el tablero no conoce la fase 10 (medido, ver regla 10) y se corre sin él, como en la Fase 8 |

---

## Prohibido

> **Prohibido en esta fase, sin excepción:** preguntarle algo a David; aplicar la migración a producción; sembrar claves o goals en producción; desplegar Orbit; escribir cualquier cosa en Amazon o en Mercado Libre; ejecutar `tools/precio_goal.py` o `tools/precio_reversa.py` contra cualquier base que no sea la local de pruebas; escribir en la base de producción (solo `SELECT`); tocar `.saikit/autopilot.json`; editar el cuerpo de una fila del plan o el spec; implementar filas distintas de A.1, A.7 y E.0a; mergear por cualquier vía que no sea la del kit; usar `--no-verify`; **cambiar de rama en el checkout principal mientras muse tiene trabajo sin commitear**; borrar ramas o worktrees ajenos (los de esta fase se borran solo en el postmerge de Q4); abrir un cuarto PR simultáneo en Orbit; tocar `app/spapi/precio_write.py` (la forma del parche es de A.4, de David); tocar la configuración del gateway; lanzar dos encargos a muse a la vez.

---

## Reglas de trabajo

1. **Muse trabaja en el checkout principal, uno a la vez.** Medido: su sesión de tmux está parada en `/Users/dn/dev/goncloud-Orbit`. Antes de cada carril de muse, el lead deja ese checkout en la rama del carril, y **solo** si está limpio:

   ```
   /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit status --porcelain | head -5
   /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit fetch -q origin
   /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit checkout -b fase10/<rama> origin/master
   ```

   Si la primera línea imprime algo, **no se cambia de rama**: se aplica la fila de atores. **La rama vive en el checkout principal hasta el `APPROVE lead`** (nuevo en la 10, corrige la v2): al `LISTO` de muse, el lead empuja la rama **sin cambiarla de árbol** (`/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit push -u origin fase10/<rama>`; un push no necesita el checkout), abre el PR con `/opt/homebrew/bin/gh pr create --repo gon0801/goncloud-Orbit --head fase10/<rama> --base master --draft --title '<título>' --body-file <archivo>` (con `--head` explícito: el cwd del lead está en otra rama), y corre las rondas cruzadas **con cwd en el checkout principal** (`cd /Users/dn/dev/goncloud-Orbit && export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH; /Users/dn/.local/bin/pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto -Excluir '' -Alcance last-commit`; un `cd` de la herramienta sí sirve para esto, porque la cruzada no usa el hook del kit); cada corrección es un `BRIEF-r<N>.md` a muse en ese mismo checkout y esa misma rama, con su `contrato.txt` (loop §3 paso 5). **Solo con el `APPROVE lead <sha>` puesto**, la rama pasa al worktree del lead para la compuerta y el merge (regla 14): `/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit checkout --detach` la libera y `/opt/homebrew/bin/git -C /Users/dn/dev/wt-fase10-lead checkout fase10/<rama>` la trae. **Muse no recibe el siguiente encargo hasta ese momento**: B arranca después del `APPROVE lead` de A, no después de su `LISTO`. Si un merge de base o una corrección **antes del merge del ítem** exige tocar la rama con ella ya en el worktree del lead, el camino inverso es el mismo con los papeles cambiados (`checkout --detach` en el worktree, `checkout fase10/<rama>` en el principal), solo con el principal limpio, y de vuelta con el `APPROVE` nuevo. Un hallazgo de la revisión de cierre (§10) llega con los carriles ya mergeados y va por Q3 bis, nunca por este camino. Hoy el checkout principal está en `HEAD` suelto sobre `b2c7474` (la rama `fase8/precio-escritura`, ya mergeada); eso no es suciedad y el `checkout -b` lo resuelve.

2. **El lead trabaja en su propio worktree**, uno para toda la fase, y ahí hace el carril D, el readback de A.7, las auditorías, las compuertas y los merges. **Ya existe** (nuevo en la 10): `/Users/dn/dev/wt-fase10-lead`, en la rama `fase10/plan-v1.3` del PR #302, con el enlace del entorno de Python puesto. Cuando Q0 haya mergeado, el mismo worktree cambia a la rama del carril D (y después, ítem por ítem, a la rama que toque: `fase10/precio-goals` para Q1, `fase10/precio-cobertura` para Q3, `fase10/cierre` para Q4; un worktree, muchas ramas, una ruta de proyecto):

   ```
   /opt/homebrew/bin/git -C /Users/dn/dev/wt-fase10-lead fetch -q origin
   /opt/homebrew/bin/git -C /Users/dn/dev/wt-fase10-lead checkout -b fase10/envio-veredicto origin/master
   test -e /Users/dn/dev/wt-fase10-lead/.venv/bin/python && echo VENV-OK || ln -s /Users/dn/dev/goncloud-Orbit/.venv /Users/dn/dev/wt-fase10-lead/.venv
   ```

   Si el worktree no existe (línea 11 del 0.0 en `0`), se crea como dice el 0.0 según el estado de Q0, y el `ln -s` de arriba. **Antes de cada `checkout` en este worktree, `git status --porcelain` tiene que salir vacío**: el trabajo del carril D se commitea en `fase10/envio-veredicto` antes de traer la rama de A o de B, y Q2 se corre con el worktree de vuelta en `fase10/envio-veredicto`. **El enlace del entorno de Python no es opcional**: el candado `pytest-pre-push` busca `./.venv/bin/python` relativo a la raíz del worktree; sin el enlace el primer `git push` muere con «failed to push some refs» y sin más explicación.

3. **Las pruebas de base tienen que correr de verdad, no saltarse.** Orbit salta sus pruebas de PostgreSQL cuando no hay base utilizable, así que un carril puede verse verde sin haber probado nada. En la Mac **no hay Docker**; la base es la de Homebrew, ya arriba. Todo comando de pruebas lleva el DSN, idéntico al de CI, y se corre con el directorio de trabajo en el árbol del carril:

   ```
   cd <árbol del carril> && ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" \
     ./.venv/bin/python -m pytest <archivos> -q -p no:cacheprovider
   ```

   El encargo exige pegar en el reporte la línea final del pytest, con el conteo de `passed` y el de `skipped`. **Si las pruebas de base del carril salen `skipped`, el carril no terminó.** El `-p no:cacheprovider` es por lo medido en la Fase 8: un `.pyc` viejo dio dos muertes falsas de mutantes en la primera vuelta.

4. **Mutar una prueba que se está saltando no prueba nada.** Antes de auditar, el lead confirma `/opt/homebrew/bin/pg_isready -h localhost -p 5432` en `accepting connections`.

5. **Esta fase no crea migraciones** (nuevo en la 10). La última en `origin/master` es `0039_precio.sql` y A.1 y A.7 trabajan sobre ella. Un carril que agregue un archivo en `migrations/` vuelve al paso 1 del loop con encargo de corrección: el plan v1.3 quitó la migración de A.7 a propósito (hecho 5) y A.1 no la necesita.

6. **`tests/test_architecture.py` tiene dueño y orden: primero el carril A, después el B.** B arranca con el `APPROVE lead` de A (regla 1); Q1 puede estar mergeando mientras muse ya trabaja en B, pero B **no toca ese archivo hasta que A esté en `master`**, y antes de su compuerta hace merge de `origin/master` (Q3 lo comprueba con `CON-Q1`). Los dos agregan un módulo a la **lista de excepciones del candado de pureza** de `app/precio/` (nuevo en la 10; plan v1.3, sección «Diseño»): A agrega `goals_write.py`, B agrega `fuentes.py`. La forma es una tupla explícita en el candado, con el nombre del archivo y un comentario de una línea con lo que ese módulo puede importar; **el `rglob` sigue cubriendo todo lo demás de la carpeta**, y cada módulo exceptuado trae su propio candado (qué importa y qué escribe). Un carril que relaje el candado de otra manera —quitar el `rglob`, exceptuar la carpeta entera, mover los módulos puros— vuelve al paso 1 del loop.

7. **Un candado que no puede salir rojo no cuenta.** Cada candado nuevo se entrega con su fuga sembrada en `tmp_path` demostrando el rojo; sin esa demostración, vuelve al paso 1 del loop. Los de esta fase: `_IDENT_PRECIO_GOAL` (solo `goals_write.py` escribe `precio_goal`; falla con un `UPDATE precio_goal` crudo sembrado en `tools/`) en el carril A, y el candado de `fuentes.py` (solo lee; falla con un `INSERT` o `UPDATE` sembrado en ese módulo) en el carril B.

8. **La herramienta de goals no toca producción en esta fase.** `tools/precio_goal.py` se prueba contra la base local: los tests crean y tiran la suya (`db_39`), y para la reproducción a mano del lead hay una base con nombre que **se deja** (el `DROP DATABASE` es una pregunta del vigilante, sección 12 del loop): `/opt/homebrew/bin/createdb -h localhost -U orbit orbit_fase10_manual` y, desde `/Users/dn/dev/wt-fase10-lead`, `for m in 0001_initial 0002_apply 0028_estimacion_venta 0033_ingest_run_llamadas 0034_ingest_run_llamadas_grant 0035_spapi_listings_inventario 0039_precio; do /opt/homebrew/bin/psql "postgresql://orbit:orbit@localhost:5432/orbit_fase10_manual" -v ON_ERROR_STOP=1 -q -f migrations/$m.sql; done`; la herramienta se corre con `ORBIT_DSN_ADMIN="postgresql://orbit:orbit@localhost:5432/orbit_fase10_manual"`. Nunca se corre con el DSN del contenedor. Sembrar el goal del producto controlado en producción es de David, después de D.0, y queda escrito en «Lo que queda listo para David».

9. **El carril D y el readback de A.7 solo leen, y los corre el lead.** Las consultas viven versionadas en `docs/evidencia/repricing-01/E.0/consultas/*.sql` (carril D) y `docs/evidencia/repricing-01/A.7/consultas/*.sql` (readback de B) y se corren así, desde el worktree del lead:

   ```
   { echo 'BEGIN READ ONLY;'; cat docs/evidencia/repricing-01/E.0/consultas/<archivo>.sql; } \
     | ssh goncloud 'set -eu
         DSN=$(docker exec orbit-app-1 printenv ORBIT_DSN_READ)
         test -n "$DSN" || { echo "ATORADO: ORBIT_DSN_READ vacio"; exit 1; }
         docker exec -i orbit-db-1 psql "$DSN" -X -P pager=off -tA -v ON_ERROR_STOP=1'
   ```

   **El `test -n` y el `BEGIN READ ONLY` no son adorno** (medido en la Fase 8, regla 9 de aquel runbook): sin el primero, un `printenv` vacío deja a libpq conectarse con sus valores por defecto y la consulta corre contra una base que no es la que crees; sin el segundo, una escritura que se cuele en un archivo de consulta corre contra producción. **El readback de A.7 no corre `tools/precio_cobertura.py` en el servidor** (nuevo en la 10): el código no está desplegado (`merge_despliega` es `no`), así que el lead corre las consultas de `app/precio/fuentes.py` por este camino **desde el árbol que tenga la rama `fase10/precio-cobertura`** (su worktree, después de tomarla con la regla 1), guarda las salidas en `docs/evidencia/repricing-01/A.7/salidas/`, y alimenta con ellas el recuadro **puro** (`app/precio/cobertura.py`) en local con un script versionado en esa misma carpeta, pasándole explícito `--max-dias-sin-reportar 3` (el valor inicial del plan; producción no tiene la clave hasta D.0) y declarándolo en `readback.md`. La DoD pide «264 MX, 106 US, con 284 y 109 al lado»: esos son los números del 2026-09-16 y **pueden haber cambiado**; lo que se exige es que el recuadro cuadre exacto con lo que la fuente canónica diga el día del readback, y que la diferencia con el bridge quede avisada si pasa del 5 %.

   **Si el host del lead niega `ssh goncloud`** (lo hizo en la Fase 8 con el host `claude`, por su clasificador de lecturas de producción), no se rodea con un subagente: las consultas quedan versionadas, la salida queda `unknown` con el comando al lado, y el carril entrega lo que sí midió; la fila de atores lo cubre.

10. **El progreso se escribe, y el tablero no conoce esta fase.** Medido el 2026-09-17: el plugin `tablero-runbook` ya está encendido en el gateway con `fases: ["6", "7"]`, `runbook.progress.get` responde `ok: true` para la fase 7 y `{"ok": false, "razon": "desconocida"}` para la fase 10. Registrarla es un cambio de configuración del gateway, negado arriba. Por eso, **desviación declarada de la sección 8 del loop, igual que en la Fase 8**: en cada cambio de estado de un carril o de la cola, y al cierre, el lead escribe `/Users/dn/dev/goncloud-Orbit/.saikit/progress/10.json` con el formato `runbook-progress.v1` (spec `docs/spec/runbook-progress.v1.md`), con `atencion_requerida` como objeto `{necesaria, motivo, desde}` y `siguiente_paso` de ≤160 caracteres en lenguaje llano, `paso_loop` saturado en `8`; hace **un** intento de envío que no bloquea:

    ```
    /opt/homebrew/bin/timeout 60 ~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat /Users/dn/dev/goncloud-Orbit/.saikit/progress/10.json)" --json | head -c 200
    ```

    y, responda lo que responda, pega el JSON completo como comentario en el PR abierto del carril activo, o en el del último si ninguno está abierto:

    ```
    /opt/homebrew/bin/gh pr comment <pr> --repo gon0801/goncloud-Orbit --body-file /Users/dn/dev/goncloud-Orbit/.saikit/progress/10.json
    ```

    Ese archivo **no se commitea**: `.saikit/` está en el `.gitignore` de Orbit por diseño. **Lo que un tercero puede verificar son los PRs, sus comentarios `APPROVE lead <sha>`, y el último comentario de progreso**; el archivo local es la copia de trabajo, no la fuente. Si algún día `runbook.progress.set` contesta `ok: true` para la fase 10, se anota en `eventos` y se sigue igual: el comentario en el PR no se quita.

11. **El cierre se reporta, no se relaya.** Al cerrar cada carril y la fase, la última línea en pantalla es `LISTO <sha>` o `ATORADO <razón>`, según la sección 2 del loop; claw la lee de tmux. **No hay comando de Telegram en esta fase**: `autopilot.json` de Orbit trae `telegram: false`. Donde la sección 5 del loop manda poner una línea «en el Telegram» (CodeRabbit sin cuota), en esta fase esa línea va **en el cuerpo del PR y en el archivo de progreso**. Desviación declarada.

12. **Nada en esta fase despliega Orbit.** `merge_despliega` es `no`: mergear a `master` no lleva el código al servidor. Por eso la sección 7 del loop no aplica a los PRs de Orbit, y no hay ventana segura ni canary para ellos. **Sí aplica** al merge del runbook en openclaw del paso 0.2.

13. **El candado léxico del kit deniega por el nombre, no por el hash.** Medido en la Fase 8: el basename del script de merge dentro de un `echo`, aun con la ruta entera, devuelve `merge denied: … hash does not match the kit manifest` aunque el hash sí casa y aunque el comando no mergee nada. La regla real: ese basename **no puede aparecer en un comando salvo como ruta absoluta que resuelva a un archivo**; nada de `echo`, banners, cuerpos de PR ni variables en la misma línea.

14. **Qué es un turno de merge, y por qué todos salen de `/Users/dn/dev/wt-fase10-lead`.** Medido en la Fase 8 (dos merges seguidos) y en el script del kit (líneas 130–132 y 497–523 de la ruta de merge): la clave del estado del hook es `cksum` de la raíz del proyecto del cwd de la sesión (`goncloud-Orbit` y `wt-fase10-lead` dan claves distintas), el hook solo anota evidencia en un turno **armado**, es decir, uno cuyo mensaje de entrada trae el literal `-saikit`, y cualquier prompt entrante sin esa marca borra el estado; las `<task-notification>` de tareas en segundo plano no lo borran, pero el reporte de regreso de un subagente sí (llega como mensaje): por eso el revisor de larga vida se libera con un archivo-marca **después** del postmerge, no antes. Por eso: **claw lanza al lead con cwd `/Users/dn/dev/wt-fase10-lead` y su mensaje de lanzamiento lleva el literal `-saikit`**, y cada mensaje de claw que abra un turno en el que el lead vaya a mergear lo lleva también; todo merge de Orbit se corre desde ese cwd, con la rama del ítem traída a ese worktree (regla 1); ninguno desde el checkout principal. Un turno de merge, en orden y sin lanzar ningún otro subagente hasta terminar: el Drive (la batería `verify/` del repo, con el `.venv` del repo, sección 3 del loop), el blast del kit (`saikit-blast.sh --write` en `/Users/dn/dev/summonaikit-claude/tools/`), el rastro de decisiones, **un solo** subagente revisor de larga vida que escribe el veredicto en `.saikit/veredictos/<sha>.json` y espera archivos-marca en bucles de ≤ 8 minutos, el lead sondeando `harness-state.env` hasta que `veredicto_sha256` iguale el `shasum -a 256` del archivo, y entonces los tres comandos de la sección 6 del loop (`--dry-run`, `--confirmado`, postmerge). Para dos PRs seguidos, el mismo revisor atiende ambos. El detalle de cada comando del kit está en `/Users/dn/dev/summonaikit-claude/README.md`; este runbook no lo repite.

15. **El `git grep` de `pendiente_sonda` es una compuerta de todos los ítems** (nuevo en la 10): ningún carril de esta fase toca `app/spapi/precio_write.py`, y la forma del parche sigue sin sellar hasta A.4. En cada compuerta se corre `/opt/homebrew/bin/git grep -h -cE '^FORMA_PARCHE = "pendiente_sonda"' -- app/spapi/precio_write.py` y se espera **exactamente `1`** (medido: sin `-h` imprime `app/spapi/precio_write.py:1`, con prefijo; sin el ancla `^` el docstring de la línea 9 también cuenta y da `2`; un `grep` de la palabra suelta pasaría con la forma sellada); **salida vacía** (rc 1; `git grep -c` no imprime ceros) significa que un carril selló la forma y vuelve al paso 1 del loop con encargo de corrección.

---

## Loop de entrega

Rige `docs/runbooks/loop-autopilot.md` de goncloud-openclaw, completo y sin repetirlo aquí: el contrato de reporte (sección 2), el loop por tarea (3), la política de rondas cruzadas (4), PRs y CodeRabbit (5), la ruta del kit para mergear (6), la reanudación si el lead muere (9), la revisión de cierre de fase (10) y los atores universales (12).

**Desviaciones de esta fase, nombradas.** De la **sección 2** (`scripts/cierre-de-fase.sh`): ese script lee `Plans.md` del repo y busca filas `| 10.N |`; Orbit lleva su plan en `plans/repricing-01.md` con filas `A.1`, `A.7`, `E.0a`, así que la línea `plan` del script sale `ROJO` por construcción. Se corre igual, apuntado a Orbit y leído de `origin/main` porque el checkout `/Users/dn/dev/goncloud-openclaw` está en otra rama (medido): `/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw show origin/main:scripts/cierre-de-fase.sh | REPO=/Users/dn/dev/goncloud-Orbit REF=origin/master bash -s 10`; imprime siete líneas de comprobación (`plan`, `ramas`, `worktrees`, `sesiones`, `despliegue`, `tablero`, `ci`; la de `tablero` sale `VERDE` porque la fase no declara plugin), una en blanco y un veredicto final `ROJO: la fase 10 NO esta cerrada (N comprobacion(es) en rojo)` con salida 1. **Desviación de las secciones 2 y 10 del loop, declarada**: en esta fase el `LISTO` del lead **no** espera al `VERDE` del script, porque el lead no puede borrar su propio worktree ni desmarcar su propia sesión (medido, ver regla 14 y el postmerge de Q4). Compuerta del lead: `despliegue` y `ci` en `VERDE`, `plan` en `ROJO` (Orbit no tiene `Plans.md`; lo sustituye el conteo por fila de Q4), y `ramas`, `worktrees` y `sesiones` en `ROJO` **con exactamente** los tres nombres del cierre pendiente (`fase10/cierre`, `/Users/dn/dev/wt-fase10-lead`, `fase10-lead`) y nada más. El bucle hasta `VERDE` de las secciones 2 y 10 lo cierra **claw** después del `LISTO`, como dice el postmerge de Q4. **De la sección 6**: el `--dry-run` del kit **no** imprime `LISTO`; imprime `DRY-RUN: gate en verde` y sale 0 (medido en el script de merge, l.350 y l.355); el `LISTO` de la sección 6 es la forma sin `--dry-run` ni `--confirmado`. De la **sección 7** (despliegue y gateway): no aplica a los PRs de Orbit, porque `merge_despliega` es `no`; sí aplica al merge del runbook en openclaw del paso 0.2. De la **sección 8** (progreso): el archivo se escribe y se intenta enviar una vez, pero el tablero no conoce la fase 10 (regla 10); la fuente verificable es el comentario en el PR. De la **sección 5**, la línea «CodeRabbit sin cuota» va al PR y al archivo de progreso, no al Telegram. De la **sección 4**, `-Excluir` va vacío en los carriles A y B, porque implementa muse y muse no está en la cadena de revisores; en el carril D y en Q4 implementa el lead, así que se excluye a su propio host; en Q0 el autor es `claude` y va `-Excluir claude` sea quien sea el lead. De la **sección 4, el tope de tres rondas**: no aplica; regla del dueño del 2026-09-15 (quality-kit, regla 4): la cruzada se repite mientras la ronda anterior haya encontrado algo, y solo el `APPROVE lead <sha>` mete el PR a la cola. De la **sección 3 paso 5 y la sección 4**: el PR #302 (Q0) y el de cierre (Q4) son docs; su loop es CI verde + una ronda cruzada + `APPROVE lead <sha>`, sin CodeRabbit obligatorio. **Re-APPROVE tras un merge de base** (sección 3 paso 9): se guarda `git diff origin/master...HEAD` antes del merge de base y se compara con el mismo diff después; si son idénticos, se re-marca `APPROVE lead <sha nuevo>` sin ronda; si no, ronda nueva. Comparar contra `<sha aprobado>` no sirve en Q0/Q4: todo PR de cierre toca `docs/CHAT-CONTEXT.md` y el diff nunca saldría vacío. **El commit del readback de A.7** (regla 9) lo hace el lead después del `APPROVE lead` y solo agrega `docs/evidencia/repricing-01/A.7/`: se re-marca `APPROVE lead <sha nuevo>` sin ronda si `git diff <sha aprobado> HEAD --name-only` lista únicamente rutas bajo `docs/evidencia/repricing-01/A.7/`. **Q0 trae tres commits** (`6fd3a61`, `da3102e`, `5023406`): los tres pasaron por un revisor y un verificador en la sesión del 2026-09-18 que los escribió (15 hallazgos aplicados en `da3102e`); la ronda cruzada de Q0 corre `-Alcance last-commit` sobre el último y el PR declara esa revisión previa de los dos anteriores.

---

## Carriles

Cuatro ramas de trabajo más la del plan, todas nacidas de `origin/master` de Orbit. **Los carriles de muse (A, B) van uno a la vez**, porque su sesión y su checkout son uno solo. **El carril D corre en paralelo**, en el worktree del lead, porque lo implementa el lead y no toca código.

```
cola:   Q0(plan v1.3, #302)
muse    (checkout principal):        A ──────────► B
lead    (worktree propio):   Q0 ──►  D ─────────────────► Q4
cola:                        Q0   Q1(A)  Q2(D)  Q3(B)  Q4(cierre)
```

**Rama base de cada carril**: `origin/master` en el momento de crear la rama, **después** de que Q0 haya mergeado (el plan v1.3 tiene que estar dentro). B nace de `origin/master` cuando A tiene su `APPROVE lead` y el lead se llevó esa rama a su worktree (regla 1); no espera el merge de Q1, pero deja `tests/test_architecture.py` para el final y hace merge de `origin/master` con Q1 dentro antes de su compuerta (regla 6). D nace en cuanto Q0 mergea, en paralelo con A.

### A · Goals — rama `fase10/precio-goals` · muse

Fila **A.1** del plan v1.3, verbatim en el encargo. Crea `app/precio/goals_write.py` (el único escritor de `precio_goal`, solo `app_admin`) y `tools/precio_goal.py` (sembrar un goal, lote CSV deduplicado, `--mode live` con ceremonia completa, `--mode shadow` sin ceremonia, `--cerrar`; dry-run con `m_actual` y `P*` por fila y aborto si `abs(P* − P_actual) > 25 %` salvo `--confirmar-salto`), con `tests/test_precio_goals.py`, el candado `_IDENT_PRECIO_GOAL` en `tests/test_architecture.py`, la excepción de pureza para `goals_write.py`, y `docs/evidencia/repricing-01/A.1/mutantes.md`.

**DoD**: la de la fila A.1 del plan v1.3, entera. Además: (a) la ceremonia es la de `tools/precio_reversa.py` **con una sola diferencia declarada**: en la reversa, `--acepto-mutacion-real` sin `--go` aborta (l.193–194); aquí `shadow` = dry-run + huella + `--acepto-mutacion-real` **sin** `--go`, y `--go` en shadow se rechaza con mensaje (el CHECK `precio_goal_live_exige_go` de la 0039 exige `go_literal` vacío fuera de `live`; «shadow sin ceremonia» del plan quiere decir sin go literal, no sin huella). En `live`: `--acepto-mutacion-real --huella <huella> --go <literal>`. No hay flag `--dry-run` en `precio_reversa.py` ni en `goals_modo_grupo.py`: el dry-run es la omisión de `--acepto-mutacion-real` e imprime el plan y su huella (`tools/contabilidad_costo_historico_0011.py` sí tiene `--dry-run`; no es el patrón). `--esperado N` no va; (b) el goal se escribe como fracción de dos decimales de porcentaje (`30.00` → `0.3000`); `--goal-pct 0.30` se rechaza con mensaje que diga que el argumento va en por ciento; (c) la banda del goal se lee de la `config_version` vigente (`precio_goal_min_pct`, `precio_goal_max_pct`) **dentro de `goals_write.py`**, copiando la forma de `_fraccion` de `app/precio/config.py` sin tocar ese archivo (medido: `leer_config` no conoce esas claves y los dos carriles tienen prohibido editarlo), y se replica el CHECK de la base; si la config no trae las claves, la herramienta aborta con `config sin precio_goal_min_pct`, nunca con un default; los tests siembran su `config_version` con el patrón `_config_version(conn, settings)` de `tests/test_api.py` l.149; (d) `m_actual` y `P*` del dry-run salen del escenario `disponible` más reciente del listing y de su `fee_observation` (`derivar_ref_fijo` + `precio_estrella` de `app/precio/objetivo.py`), **sin cotizar a Amazon**; si no hay escenario, el dry-run imprime `sin_escenario` en las dos columnas, el chequeo del 25 % no corre, y **`--mode live` aborta** con `sin_escenario` (un goal encendido sobre un producto que el motor no puede evaluar no se siembra) mientras `--mode shadow` sigue con aviso — decisión del lead, declarada en el PR; (e) `--cerrar` solo fija `valid_to` del goal vigente (el trigger de la base ya rechaza cualquier otro `UPDATE`); (f) `live` exige `go_literal` no vacío y la base rechaza `live` sin él (CHECK de la 0039): el test lo prueba en los dos lados; (g) el lote CSV con dos filas del mismo `(listing_id, platform)` aborta **antes** de calcular la huella, con el número de línea; (h) todo dinero en `Decimal`, cero `float`; (i) el candado de pureza de `app/precio/` exceptúa `goals_write.py` por nombre y **el resto de la carpeta sigue bajo `rglob`**; `goals_write.py` solo importa `psycopg`, `app.precio.*` y stdlib, y su candado propio lo prueba con una fuga sembrada; (j) catálogo de mutantes propio, uno por regla de la DoD, con base real y sin sobrevivientes.

**Lo que un usuario vería si funcionó**: David, desde el contenedor app y con `ORBIT_DSN_ADMIN`, corre `python tools/precio_goal.py --listing-id <id> --platform amazon_mx --goal-pct 30.00 --mode shadow`, ve una tabla con el SKU, `m_actual`, `P*`, `P_actual` y la huella, repite con `--acepto-mutacion-real --huella <huella>`, y la fila aparece en `precio_goal` con `mode = shadow`, `go_literal` nulo y `valid_to` nulo. **En esta fase nadie lo hace en producción** (D.0 no está); lo hace el test contra la base local y el lead lo reproduce a mano en la auditoría.

### D · Veredicto del envío — rama `fase10/envio-veredicto` · lead

Fila **E.0a** del plan v1.3. Solo lectura sobre producción, por la regla 9. Produce `docs/evidencia/repricing-01/E.0/veredicto.md` con las consultas versionadas en `E.0/consultas/*.sql` y sus salidas literales en `E.0/salidas/*.txt`.

**Qué hace el lead, en orden.** (0) Lee `ls /Users/dn/dev/orbit-insumos/E.0/`: si hay archivos, son los documentos de origen que David dejó (exportes de Seller Central o de la contabilidad) y el veredicto se dicta contra ellos, como manda el plan; si no hay (hoy: la carpeta no existe), **ningún par recibe `duplicado` ni `componentes distintos`**: todos quedan `sin veredicto` con la razón y el documento exacto que lo resolvería, y lo que esta fase entrega es la preparación completa para que el veredicto sea de una tarde cuando el documento exista. (1) Lista las órdenes de US con tres cargos de `shipping_fee` en la ventana `[hoy − 90, hoy]` en UTC (`hoy` = `date -u +%F` al correr; eran 18 el 2026-09-16 y el número que salga es el que se escribe, hecho 14) y, para cada una, sus cargos con `source_event_id` completo, `fee_type`, `amount`, `event_date`, `currency` y la venta ligada; y lo mismo para los 54 pares `finance:LabmanLabelPurchase`/`shipping_label` y una muestra de 20 pares `finance:ShippingHB`/`shipping_label` (hecho 22). (2) Lee en el repo de Orbit y en la documentación pública de la SP-API (Finances: `ShipmentEvent`, `ServiceFeeEvent`, tipos de cargo `ShippingHB`, `ShippingChargeback`, `MFNPostageFee`; y el reporte de etiquetas de Buy Shipping que alimenta `shipping_label`) qué representa cada identidad de `source_event_id`, y lo escribe **como hipótesis con la cita**; si no hay red, la hipótesis queda `unknown` con la URL al lado y la fase sigue. (3) Con los documentos del paso (0) si existen, dicta el veredicto **por par de fuentes**: `duplicado` (mismo cobro por dos caminos), `componentes distintos`, o `sin veredicto` con la razón exacta y **qué documento lo resolvería** (la vista de transacciones de Seller Central de **cada** orden de la lista del paso 1, con su `order_id`, exportada a `/Users/dn/dev/orbit-insumos/E.0/`; la lista literal completa va en el documento, como pide el plan). (3 bis) El veredicto se escribe en una tabla con este encabezado literal, una fila por par, y la segunda columna con una sola de las tres palabras: `| par | veredicto | razón y fuente |` → `| finance:LabmanLabelPurchase vs shipping_label | duplicado | … |`; la compuerta Q2 cuenta esas filas. (4) Escribe la regla de costo por orden que resulta, como tabla `fuente → cuenta / descarta / otros`, y la lista de descartes por convención de signos con plataforma y `fee_type` (los ~109 diarios del hecho 14), para que E.0b la implemente sin volver a medir.

**DoD**: la de la fila E.0a. Además: ninguna consulta escribe; cada tabla del documento cita el `.sql` que la produjo; el documento dice en su encabezado que es el insumo de E.0b y de la acta E.2; y **si el veredicto de algún par queda `sin veredicto`, la fila no se cierra**: el PR mergea igual con la evidencia, la celda queda `cc:TODO — blocked: falta <documento>` (así se escribe el `blocked` del plan; la compuerta Q4 cuenta `cc:TODO`), y `siguiente_paso` le dice a David qué exportar y dónde dejarlo: `/Users/dn/dev/orbit-insumos/E.0/` (carpeta fuera de cualquier repo, que no existe hoy y que la siguiente fase leerá).

**Lo que un usuario vería si funcionó**: David abre `docs/evidencia/repricing-01/E.0/veredicto.md` en `master` y encuentra, para cada par de fuentes, una palabra —`duplicado`, `componentes distintos` o `sin veredicto`— con las órdenes de la ventana desglosadas debajo (eran 18 el 2026-09-16) y una tabla de una página que dice qué cuenta y qué no. No hay pantalla ni mensaje: es un documento.

### B · Cobertura — rama `fase10/precio-cobertura` · muse

Fila **A.7** del plan v1.3, verbatim en el encargo. Crea `app/precio/cobertura.py` (puro: recibe filas y produce el recuadro de S10 por plataforma: `activas = evaluadas + no_evaluadas + sin_goal + fuera_de_alcance`, con `fuera_de_alcance` desglosado por motivo y fase), `app/precio/fuentes.py` (lectura de la fuente canónica `spapi_listing_estado_observation` —«activa» es la última observación por `(seller_sku, platform)` cuyo `status` contiene `BUYABLE`, cruzada con `listing` por `seller_sku` y `platform`—, del canal en `estimacion_oferta_observation` (columna `canal`, ya mapeada con `mapear_canal` de `app/estimacion_insumos.py`), de los goals vigentes y de las decisiones del día; solo `SELECT`; en la lista de excepciones del candado con candado propio), `tools/precio_cobertura.py --platform <p>` (imprime el recuadro contra la base como lector, `ORBIT_DSN_READ`), `tests/test_precio_cobertura.py`, y `docs/evidencia/repricing-01/A.7/mutantes.md`.

**DoD**: la de la fila A.7 del plan v1.3, entera. Además: (a) **sin migración y sin tocar `app/listings.py`** (regla 5); (b) el recuadro es una función pura probada con el fixture de 12 publicaciones repartidas en los cuatro estados y **cuadra exacto**; un mutante que cuente dos veces una publicación con dos ASINs muere; (c) canal desconocido → `canal_sin_dato`, nunca un default; publicación sin reportar más de `precio_catalogo_max_dias_sin_reportar` días → `catalogo_desactualizado` contada (la clave la lee `fuentes.py` de la `config_version` vigente con la forma de `_entero` de `app/precio/config.py`, sin tocar ese archivo, `ValueError` si falta o sale de cota 1–14, y `cobertura.py` la recibe como argumento); (d) `fuera_de_alcance` nombra la fase (`fase_E_envio_fbm` para FBM sin motor, `fase_M_meli` para MeLi), nunca un genérico; (e) la cuenta del bridge (`listing` activas por plataforma) se muestra **al lado** y la diferencia se marca `aviso` si pasa del 5 %; (f) `fuentes.py` solo importa `psycopg`, `app.precio.*`, `app.estimacion_insumos` (solo `mapear_canal`; medido: ahí vive, no en `app/listings.py`) y stdlib; su candado propio falla con un `INSERT` sembrado; (g) el readback en producción **lo corre el lead** por la regla 9, no muse: muse entrega las consultas de `fuentes.py` como archivos en `docs/evidencia/repricing-01/A.7/consultas/*.sql` (las mismas que el módulo ejecuta, sin parámetros ocultos) y un script `docs/evidencia/repricing-01/A.7/recuadro_desde_salidas.py` que alimenta `cobertura.py` con esas salidas y acepta `--max-dias-sin-reportar N` explícito (el lead lo corre con `3`); la base temporal de `tests/test_precio_cobertura.py` aplica, en este orden, `0001_initial, 0002_apply, 0028_estimacion_venta, 0033_ingest_run_llamadas, 0034_ingest_run_llamadas_grant, 0035_spapi_listings_inventario, 0039_precio` (medido: `ORDEN39` no trae la 0035, que crea la fuente canónica; la 0035 solo referencia `ingest_run (id)` de la 0001, y la 0033/0034 van porque es el `ORDEN` que ya usa `tests/test_spapi_listings.py` l.27–30; nombres reales verificados en `origin/master`), sin tocar `ORDEN39`; **las ~8 líneas de `_motivo_universo` NO van**: la celda A.7 v1.3 (desde su tercer commit, `5023406`) las asigna a E.3/0.3 y la fila de archivos de A.7 no incluye `app/estimacion_insumos.py`; (h) catálogo de mutantes propio, sin sobrevivientes.

**Lo que un usuario vería si funcionó**: David corre `python tools/precio_cobertura.py --platform amazon_mx` desde el contenedor app con `ORBIT_DSN_READ` y ve un recuadro de cinco líneas que suma exacto a las activas de Orbit, con la cuenta del bridge al lado y, hoy, todo en `sin_goal` o `fuera_de_alcance` porque no hay goals. En esta fase lo ve el lead, en el readback de la compuerta Q3, con las salidas leídas de producción.

### Q4 · Cierre — rama `fase10/cierre` · lead

No es un carril de trabajo: es el ítem que cierra la fase después de la revisión de la sección 10 del loop. Marca `cc:完了` las celdas de estado de A.1 y A.7 con su SHA de squash y sus salvedades; la de E.0a la marca `cc:完了` solo si el veredicto quedó completo, y si no, la deja `cc:TODO` con la nota de veredicto parcial y el SHA de su evidencia; y actualiza `docs/CHAT-CONTEXT.md`, que el CI exige en el mismo PR.

### Archivos por carril

| Carril | Puede tocar | No toca |
|---|---|---|
| **Q0** | `plans/repricing-01.md`, `plans/manifest.json`, `docs/CHAT-CONTEXT.md` (ya commiteados en `fase10/plan-v1.3`, tres commits; el ítem solo mergea) | todo lo demás |
| **A** | `app/precio/goals_write.py`, `tools/precio_goal.py`, `tests/test_precio_goals.py`, `tests/test_architecture.py` (la excepción de `goals_write.py` y el candado `_IDENT_PRECIO_GOAL`, en paralelo a los existentes), `docs/evidencia/repricing-01/A.1/mutantes.md` | `migrations/**`, `app/precio/{tipos,reglas,objetivo,ventas,config}.py`, `app/spapi/**`, `app/listings.py`, `app/cycle.py`, `app/apply.py`, `plans/**`, `docs/superpowers/**` |
| **D** | `docs/evidencia/repricing-01/E.0/**`, incluidas sus `consultas/*.sql` y `salidas/*.txt` | todo lo demás del repo |
| **B** | `app/precio/cobertura.py`, `app/precio/fuentes.py`, `tools/precio_cobertura.py`, `tests/test_precio_cobertura.py`, `tests/test_architecture.py` (después de que A mergee: la excepción de `fuentes.py` y su candado), `docs/evidencia/repricing-01/A.7/**` | `migrations/**`, `app/precio/{tipos,reglas,objetivo,ventas,config,goals_write}.py`, `app/spapi/**`, `app/listings.py`, `app/estimacion_insumos.py` (las ~8 líneas de `_motivo_universo` que el plan menciona son de **E.3**, no de A.7), `app/api_dashboard.py`, `plans/**`, `docs/superpowers/**` |
| **Q4** | `plans/repricing-01.md` (**solo las celdas de estado** de A.1, A.7 y E.0a), `docs/CHAT-CONTEXT.md` | todo lo demás, incluido el cuerpo de cualquier fila y el spec |

**Fuera de toda tabla, y nunca se commitea**: el `BRIEF.md` y los `BRIEF-r<N>.md` de cada encargo, que viven en la raíz del checkout principal y **los borra el lead** al leer el `contrato.txt` del encargo (mientras existen, la reanudación los toma como «encargo en vuelo»); el rojo de TDD en `.saikit/scratch/<carril>/tdd.md`; `.saikit/scratch/<carril>/contrato.txt`; y `.saikit/progress/10.json`. Los cuatro están cubiertos por el `.gitignore` de Orbit o se borran antes del push, y el lead lo verifica en la compuerta de cada ítem. El **catálogo de mutantes** sí se commitea, en `docs/evidencia/repricing-01/<fila>/mutantes.md`, porque es la evidencia que la DoD pide.

---

## Cola de merge

En este orden. Cada ítem se mergea por la ruta del kit de la sección 6 del loop, **siempre desde `/Users/dn/dev/wt-fase10-lead` con la rama del ítem traída a ese worktree** (reglas 1 y 14; nunca desde el checkout principal: su ruta de proyecto no es la de la sesión del lead y el kit contesta `sin estado del hook`). Ninguno de Orbit lleva compuerta de despliegue.

**El número de PR** de cada ítem se obtiene así, nunca a mano:

```
pr=$(/opt/homebrew/bin/gh pr list --repo gon0801/goncloud-Orbit --head fase10/<rama> --state all --json number --jq '.[0].number')
```

(`--state all` porque sin él `gh` solo lista los abiertos y, mergeado el ítem, el comentario final de progreso y la reanudación no lo encuentran; medido con `fase8/cierre`). **El SHA de squash de un ítem mergeado** se lee con `/opt/homebrew/bin/gh pr view $pr --repo gon0801/goncloud-Orbit --json mergeCommit --jq .mergeCommit.oid`; ese es el `<sha-squash-de-Q1>` de Q3.

**En todas las compuertas**, además de lo propio de cada una, se corren estas tres líneas y se esperan estas salidas: `ls /Users/dn/dev/goncloud-Orbit/BRIEF*.md 2>/dev/null && echo SUCIO || echo LIMPIO` → `LIMPIO` (los `BRIEF*.md` viven en el checkout principal, no en el worktree del lead, así que un `git status` del worktree no los vería; `.saikit/` está en el `.gitignore` y no hace falta mirarlo); `/opt/homebrew/bin/git grep -h -cE '^FORMA_PARCHE = "pendiente_sonda"' -- app/spapi/precio_write.py` → `1` (regla 15); `/opt/homebrew/bin/git diff --name-only origin/master...HEAD -- migrations/ | head -1` → **sin salida** (regla 5).

**Q0 · Plan v1.3** (`fase10/plan-v1.3`, PR #302, árbol `/Users/dn/dev/wt-fase10-lead`). Solo si el 0.0 dio `0` + `OPEN`.

```
cd /Users/dn/dev/wt-fase10-lead
/opt/homebrew/bin/gh pr checks 302 --repo gon0801/goncloud-Orbit | head -3
/opt/homebrew/bin/git fetch -q origin
/opt/homebrew/bin/git diff --name-only origin/master...HEAD | grep -vE '^(plans/repricing-01\.md|plans/manifest\.json|docs/CHAT-CONTEXT\.md)$'
/opt/homebrew/bin/git show HEAD:plans/repricing-01.md | grep -c '^Version: 1.3'
```

Esperado: `quality` en `pass`; el diff filtrado **sin salida**; `1`. Loop reducido: una ronda cruzada con `-Excluir claude` (el autor del #302) y `APPROVE lead <sha>`; primero el merge con `--dry-run`, que pasa cuando imprime `DRY-RUN: gate en verde` y sale 0, y si sale `sin estado del hook` la fase para (paso 0.1). Fallback: si `origin/master` avanzó, merge de la base en la rama (no rebase, no push con fuerza), CI de nuevo y re-APPROVE por la regla del «Loop de entrega» (el diff `origin/master...HEAD` idéntico antes y después del merge de base).

**Q1 · Carril A** (`fase10/precio-goals`, tomada en el worktree del lead con la regla 1).

```
cd /Users/dn/dev/wt-fase10-lead && /opt/homebrew/bin/git rev-parse --abbrev-ref HEAD
/opt/homebrew/bin/gh pr checks $pr --repo gon0801/goncloud-Orbit | head -3
ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" ./.venv/bin/python -m pytest tests/test_precio_goals.py tests/test_architecture.py tests/test_precio_migracion.py -q -p no:cacheprovider | tail -2
/opt/homebrew/bin/git diff --name-only origin/master...HEAD | grep -vE '^(app/precio/goals_write\.py|tools/precio_goal\.py|tests/test_precio_goals\.py|tests/test_architecture\.py|docs/evidencia/repricing-01/A\.1/)' | head -3
grep -n "goals_write" tests/test_architecture.py | head -3
```

Esperado: la rama del ítem (`fase10/precio-goals`, o `fase10/A-cierre-r<N>` en Q3 bis); `quality` en `pass`; `N passed` con `N ≥ 1` y **sin** `skipped`; el diff filtrado **sin salida**; y del último `grep`, al menos una línea, que el lead lee para confirmar que la excepción es por nombre de archivo y no por carpeta (regla 6). Fallback: `skipped` → fila de atores; rutas fuera de la tabla → se sacan con un commit propio; excepción por carpeta o `rglob` quitado → paso 1 del loop con encargo de corrección.

**Q2 · Carril D** (`fase10/envio-veredicto`, árbol `/Users/dn/dev/wt-fase10-lead`).

```
cd /Users/dn/dev/wt-fase10-lead
/opt/homebrew/bin/gh pr checks $pr --repo gon0801/goncloud-Orbit | head -3
/opt/homebrew/bin/git diff --name-only origin/master...HEAD | grep -qE '^docs/evidencia/repricing-01/E\.0/veredicto\.md$' && echo TIENE-VEREDICTO || echo SIN-VEREDICTO
/opt/homebrew/bin/git diff --name-only origin/master...HEAD | grep -vE '^docs/evidencia/repricing-01/E\.0/' | head -3
grep -cE '^\| .* \| (duplicado|componentes distintos|sin veredicto) \|' docs/evidencia/repricing-01/E.0/veredicto.md
```

Esperado: `quality` en `pass`; `TIENE-VEREDICTO`; el diff filtrado **sin salida**; y del último conteo, **al menos 2** (un renglón por par de fuentes: `Labman`/`shipping_label` y `ShippingHB`/`shipping_label`; el tercer par, `Labman`/`ShippingHB`, si el lead lo midió). Un `sin veredicto` **no bloquea el merge**: bloquea la celda en Q4. Fallback: `SIN-VEREDICTO` → el entregable no está y el ítem no mergea; si `ssh goncloud` fue negado y todo quedó `unknown`, el documento mergea igual con las consultas versionadas y la celda queda `cc:TODO` con «sin lectura de producción: correr `E.0/consultas/*.sql` con la regla 9».

**Q3 · Carril B** (`fase10/precio-cobertura`, tomada en el worktree del lead con la regla 1). **Precondición**: la rama trae **el merge de Q1 dentro**, porque comparten `tests/test_architecture.py`. Se comprueba contra el SHA de squash de Q1, que el lead anotó al mergearlo:

```
cd /Users/dn/dev/wt-fase10-lead && /opt/homebrew/bin/git rev-parse --abbrev-ref HEAD
/opt/homebrew/bin/git fetch -q origin
/opt/homebrew/bin/git merge-base --is-ancestor <sha-squash-de-Q1> HEAD && echo CON-Q1 || echo FALTA-Q1
/opt/homebrew/bin/gh pr checks $pr --repo gon0801/goncloud-Orbit | head -3
ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" ./.venv/bin/python -m pytest tests/test_precio_cobertura.py tests/test_architecture.py -q -p no:cacheprovider | tail -2
/opt/homebrew/bin/git diff --name-only origin/master...HEAD | grep -vE '^(app/precio/cobertura\.py|app/precio/fuentes\.py|tools/precio_cobertura\.py|tests/test_precio_cobertura\.py|tests/test_architecture\.py|docs/evidencia/repricing-01/A\.7/)' | head -3
ls docs/evidencia/repricing-01/A.7/salidas/ 2>/dev/null | wc -l
```

Esperado: la rama del ítem (`fase10/precio-cobertura`, o `fase10/B-cierre-r<N>` en Q3 bis); `CON-Q1`; `quality` en `pass`; `N passed` sin `skipped`; el diff filtrado **sin salida**; y el último conteo **mayor que 0**, porque el readback en producción lo corre el lead **antes** de mergear (regla 9) y sus salidas van en este mismo PR, en un commit del lead sobre la rama de muse, junto con el recuadro reproducido en `docs/evidencia/repricing-01/A.7/readback.md` (activas de la fuente canónica por plataforma, cuenta del bridge al lado, diferencia en por ciento y la palabra `aviso` si pasa del 5 %). Fallback: `FALTA-Q1` → merge de `origin/master` en la rama y otra vez a la compuerta; `0` salidas con `ssh goncloud` negado → el PR mergea con `readback.md` diciendo `unknown` y el comando al lado, y la celda de A.7 en Q4 queda `cc:完了` con esa salvedad, porque el readback es evidencia de la DoD y no código.

**Q3 bis · Correcciones de la revisión de cierre** (solo si la sección 10 del loop encuentra algo): cada hallazgo sobre A o B es un encargo `BRIEF-r<N>.md` a muse en una rama `fase10/<carril>-cierre-r<N>` nacida de `origin/master` en el checkout principal, con el loop y la compuerta del carril al que corrige (Q1 para A, Q3 para B; en su primera línea se espera **la rama del ítem**, no el nombre fijo del carril); un hallazgo sobre el carril D lo corrige el lead en `fase10/D-cierre-r<N>` con la compuerta de Q2. Todos se mergean **antes** de Q4 y ninguno queda abierto al abrirla.

**Q4 · Cierre** (`fase10/cierre`, árbol `/Users/dn/dev/wt-fase10-lead`). Va **después** de la revisión de cierre de la sección 10 del loop, con sus hallazgos ya corregidos y mergeados (Q3 bis).

```
cd /Users/dn/dev/wt-fase10-lead
/opt/homebrew/bin/gh pr checks $pr --repo gon0801/goncloud-Orbit | head -3
/opt/homebrew/bin/git fetch -q origin || { echo "ATORADO: git fetch fallo"; exit 1; }
/opt/homebrew/bin/git diff --name-only origin/master...HEAD | grep -vE '^(plans/repricing-01\.md|docs/CHAT-CONTEXT\.md)$'
for f in A.1 A.7; do
  printf '%s ' "$f"
  /opt/homebrew/bin/git diff origin/master...HEAD -- plans/repricing-01.md \
    | grep -cE "^\+\| ${f} \|.*cc:完了"
done
printf 'E.0a '; /opt/homebrew/bin/git diff origin/master...HEAD -- plans/repricing-01.md | grep -cE '^\+\| E\.0a \|.*cc:(完了|TODO)'
ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" ./.venv/bin/python tools/check_chat_context_fresh.py origin/master
```

Esperado: `quality` en `pass`; el diff filtrado **sin salida**; `A.1 1`, `A.7 1`, `E.0a 1`; y el candado de frescura en verde. Una fila en `0` es una celda sin cerrar; en `2` o más, la celda se tocó dos veces y hay que mirar por qué. Fallback: el candado de frescura en rojo → falta la entrada en `CHAT-CONTEXT.md` y se agrega en el mismo PR; cualquier otra ruta en el diff se saca con un commit propio. Este ítem lleva un loop reducido: auditoría del lead y una ronda cruzada, sin CodeRabbit obligatorio, porque son celdas de estado y prosa.

**El `fetch` va primero, corta si falla, y no se hereda del ítem anterior.** Q4 compara contra `origin/master`, que es una referencia local: sin traerla, compara contra lo que `master` era cuando alguien hizo fetch por última vez.

**Postmerge de Q4: limpieza y bucle de cierre** (nuevo en la 10; medido en la Fase 8 que sin esto quedan cinco ramas locales, un worktree y una sesión marcada). El kit borra solo la rama remota. **El lead no borra su propio worktree ni desmarca su propia sesión**: `/Users/dn/dev/wt-fase10-lead` es el cwd del proceso de su sesión y borrarlo deja al CLI sin directorio para los hooks (medido). Después del postmerge del kit en Q4, el lead hace lo suyo, **con cwd `/Users/dn/dev/goncloud-Orbit`**:

```
cd /Users/dn/dev/goncloud-Orbit
/opt/homebrew/bin/git status --porcelain | head -3
/opt/homebrew/bin/git checkout --detach origin/master
/opt/homebrew/bin/git branch -D fase10/plan-v1.3 fase10/precio-goals fase10/envio-veredicto fase10/precio-cobertura $(/opt/homebrew/bin/git for-each-ref --format='%(refname:short)' 'refs/heads/fase10/*-cierre-r*')
/opt/homebrew/bin/git fetch -q --prune origin
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw show origin/main:scripts/cierre-de-fase.sh | REPO=/Users/dn/dev/goncloud-Orbit REF=origin/master bash -s 10
```

Esperado: `status` **sin salida** (si imprime algo, muse dejó trabajo sin commitear y **no se borra nada**: fila de atores); el `branch -D` con una línea `Deleted branch …` por rama (una que no exista solo avisa); y del script de cierre, siete líneas de comprobación (con `tablero VERDE`) más el veredicto final `ROJO: …` con salida 1 (que en esta fase no es compuerta: desviación declarada en «Loop de entrega»): `plan ROJO` (esperado), `ramas ROJO` con **solo** `fase10/cierre` (la rama del propio worktree del lead; las de Q3 bis ya cayeron con el `for-each-ref` de arriba), `worktrees ROJO` con **solo** `/Users/dn/dev/wt-fase10-lead`, `sesiones ROJO` con **solo** `fase10-lead`, `despliegue VERDE`, y `ci VERDE` (si dice `ultima corrida: in_progress`, es la corrida del squash de Q4: se espera 5 minutos y se repite, hasta 3 veces). Con exactamente eso, el lead escribe el `LISTO <sha>` de la fase con una línea antes: `CIERRE PENDIENTE DE CLAW: worktree wt-fase10-lead, rama fase10/cierre, sesion fase10-lead`. **Lo que sigue es de claw, después del `LISTO`, sin kit**: `/opt/homebrew/bin/tmux set-environment -u -t fase10-lead OPENCLAW_WATCH`, `/opt/homebrew/bin/tmux kill-session -t fase10-lead`, `/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit worktree remove /Users/dn/dev/wt-fase10-lead`, `/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit branch -D fase10/cierre`, y el script de cierre otra vez hasta que `ramas`, `worktrees`, `sesiones`, `despliegue` y `ci` salgan `VERDE` (o `unknown` con su razón). Cualquier otra rama, worktree o sesión que el script nombre no es de esta fase y **no se toca** (los residuales de la Fase 8 se limpiaron el 2026-09-18: `bash -s 8` da `ramas`, `worktrees` y `sesiones` en `VERDE`).

---

## Cuando algo se atora

Estas son las de esta fase. Las universales están en la sección 12 del loop y no se repiten.

| Situación | Qué hace el lead |
|---|---|
| El kit no está en `/Users/dn/dev/summonaikit-claude/tools` | `ATORADO kit ausente en /Users/dn/dev/summonaikit-claude/tools` y **la fase para**. No se busca el script por el disco ni se mergea por otra vía. |
| `.saikit/autopilot.json` no está en `origin/master` de Orbit | `ATORADO bootstrap ausente` y **la fase para**; `atencion_requerida.necesaria = true` en el archivo de progreso. |
| El PR #302 está `CLOSED` sin merge, o el 0.0 da `1` + `OPEN` / `0` + `MERGED` | `ATORADO plan v1.3 <estado>` y **la fase para**: las DoD de A.1 y A.7 serían las de la v1.2. `atencion_requerida.necesaria = true`. |
| El PR #302 tiene conflicto con `origin/master` | Merge de `origin/master` en `fase10/plan-v1.3` (no rebase), resolver **solo** en `plans/repricing-01.md` y `docs/CHAT-CONTEXT.md`, CI, re-APPROVE, y otra vez a Q0. Si el conflicto está en el cuerpo de una fila que otra sesión editó, gana lo que esté en `master` y la diferencia se declara en el PR. |
| La ruta del kit rechaza por sello, por estado del hook o por lock | Una vez: re-sellar con un revisor propio desde la sesión viva, en el mismo host y la misma ruta de proyecto, y reintentar (regla 14). Si sigue: el PR queda abierto con su `APPROVE lead <sha>` y la razón textual, y va al archivo de progreso. Ninguna otra ruta de merge. |
| Un comando es denegado por nombrar el script del kit | Es el candado léxico, no una falla del kit: se reescribe el comando para que ese basename solo aparezca como ruta absoluta resoluble. |
| El checkout principal está sucio al arrancar un carril de muse, o al limpiar en el postmerge de Q4 | **No se cambia de rama y no se borra nada.** El carril de muse espera; el carril D del lead sigue. Se anota en el progreso con `siguiente_paso` diciendo qué archivo lo bloquea. A la segunda espera, el carril queda `atorado` y se declara; en el postmerge de Q4, el `LISTO` de la fase espera a que ese árbol quede limpio. |
| El bucle de espera de muse devuelve `rc=124` (tres horas sin `contrato.txt`), o su pantalla muestra `model stream idle timeout` | Prueba de vida: `/opt/homebrew/bin/tmux capture-pane -p -t muse-goncloud-Orbit -S -40 > /tmp/muse-a.txt; sleep 120; /opt/homebrew/bin/tmux capture-pane -p -t muse-goncloud-Orbit -S -40 > /tmp/muse-b.txt; cmp -s /tmp/muse-a.txt /tmp/muse-b.txt && echo QUIETA \|\| echo VIVA`. `VIVA` → se renueva el bucle de tres horas y se anota en `eventos`, sin reenviar. `QUIETA` (o el `idle timeout` en pantalla) → se confirma que la barra dice `high` (si dice `max`: `/opt/homebrew/bin/tmux send-keys -t muse-goncloud-Orbit '/effort high' Enter`) y se reenvía la instrucción **una** vez con otro bucle; si vuelve `QUIETA` sin archivo, el carril queda `atorado` con `detenido_por` = «muse sin respuesta» y el carril D sigue. |
| PostgreSQL local caído | `/opt/homebrew/bin/brew services start postgresql@16`, esperar 30 s y reintentar una vez. Si sigue caído: los carriles A y B quedan `atorado` con `detenido_por` textual; el carril D no depende de eso y sigue. No se usa Docker: no está en la Mac. |
| Las pruebas de base salen `skipped` | El carril no terminó. Encargo de corrección con el comando del DSN de la regla 3. Un `skipped` nunca cuenta como DoD cumplida. |
| El primer `git push` de un carril del lead muere sin explicación | Falta el enlace del entorno de Python en el worktree; se crea con el `ln -s` de la regla 2 y se reintenta. |
| `origin/master` de Orbit avanzó | Merge de la base en el carril (no rebase, no push con fuerza), CI y vuelta a la compuerta; re-APPROVE por la regla del «Loop de entrega» (el diff `origin/master...HEAD` idéntico antes y después del merge de base). Es esperable: otras sesiones mergean en este repo. |
| Un carril agrega un archivo en `migrations/` | Regla 5: paso 1 del loop con encargo de corrección. Esta fase no crea migraciones. |
| Un carril toca `app/spapi/precio_write.py` o el `git grep` de la regla 15 sale vacío | Regla 15: paso 1 del loop con encargo de corrección. La forma del parche es de A.4, de David. |
| Un carril exceptúa del candado de pureza la carpeta entera, quita el `rglob` o mueve los módulos puros | Regla 6: paso 1 del loop con encargo de corrección. La excepción es por nombre de archivo, uno por carril, con candado propio. |
| La config vigente de la base local no trae `precio_goal_min_pct`/`_max_pct` o `precio_catalogo_max_dias_sin_reportar` en un test | Los tests siembran su propia `config_version` en la base temporal con esas claves, con `_config_version(conn, settings)` de `tests/test_api.py` l.149 (medido: `BASE_CONFIG` de `tests/test_precio_reglas.py` es un dict para `leer_config`, no siembra en base). En producción esas claves las siembra D.0, no esta fase; el readback local de A.7 pasa el valor inicial del plan explícito (regla 9). |
| El carril B necesita `tests/test_architecture.py` y Q1 no ha mergeado | B trabaja en todo lo demás y deja ese archivo para el final; cuando Q1 mergea, merge de `origin/master` en `fase10/precio-cobertura` y recién ahí la excepción de `fuentes.py`. La regla 6 fija el orden. |
| `ssh goncloud` no responde o el host lo niega, en el carril D o en el readback de A.7 | Lo que falte queda `unknown` con la consulta al lado, en el documento de evidencia. No se detiene la fase ni se rodea con un subagente. Q2 y Q3 tienen su fallback escrito. |
| El veredicto de un par de fuentes queda `sin veredicto` (hoy es lo esperado: no hay documento de origen) | El PR de D mergea con la evidencia; la celda E.0a queda `cc:TODO — blocked: falta <documento>` en Q4 y `siguiente_paso` dice qué exportar y que va en `/Users/dn/dev/orbit-insumos/E.0/`. |
| La skill `appflowy-ehv-task` es negada por el host | El comando literal va al cuerpo del PR de cierre y a `siguiente_paso`; David lo corre. No se insiste. |
| `runbook.progress.set` responde `ok: false` | Es lo esperado (regla 10): el comentario en el PR es la fuente. Se anota una vez en `eventos`. |
| Muse entrega A.1 con `--goal-pct` como fracción o con defaults de goal | Vuelve al paso 1 del loop: el plan rechaza «goal como fracción» y «defaults de goal» (sección Reject). |
| El runbook no está en `origin/main` de openclaw al arrancar (0.0 sin la línea del título) | El lead **no** lo mergea y no hace `cd`: reporta `ATORADO runbook fuera de main` y claw aplica el paso 0.2 (lo mergea David desde GitHub o claw lanza `fase10-runbook`), y relanza al lead. Si la rama `docs/runbook-fase10` tampoco existe en el remoto, `ATORADO runbook ausente` y la fase para. |
| El `--dry-run` del kit contesta `sin estado del hook` | El cwd de la sesión no es el del sello, o el turno no está armado con `-saikit`, o un mensaje ajeno borró el estado (regla 14). Una vez: se confirma el cwd del proceso con `/opt/homebrew/bin/tmux display-message -p -t "$TMUX_PANE" '#{pane_current_path}'` (`/Users/dn/dev/wt-fase10-lead` para los ítems de Orbit; `/Users/dn/dev/wt-fase10` para el paso 0.2 en su sesión aparte), se pide a claw un turno con el literal y se repite sello + merge en ese turno; lectura de vuelta: tras el sello existe `~/.claude/hooks/state/<host>/<cksum del cwd>/*/harness-state.env`. Si sigue: el PR queda abierto con su `APPROVE lead <sha>` y la razón, y va al progreso. |
| El plan y este runbook se contradicen | Gana el plan v1.3. Residual en el PR, sin editar el plan fuera de Q4. |
| Se necesita un cuarto PR abierto en Orbit | No se abre: se cierra uno primero. Con muse secuencial, lo normal es tener dos: el suyo y el del lead, más el #302 mientras Q0 no mergee. |
| Reanudación: el lead murió | Sección 9 del loop. Claw relanza una sesión `fase10-lead` con cwd `/Users/dn/dev/wt-fase10-lead` y el literal `-saikit` en el mensaje (regla 14); el nuevo lead corre el 0.0 entero. El estado está en el último comentario de progreso de los PRs `fase10/*` (`/opt/homebrew/bin/gh pr list --repo gon0801/goncloud-Orbit --search "head:fase10/" --state all --json number,headRefName,state`) y en `/Users/dn/dev/goncloud-Orbit/.saikit/progress/10.json` si el host es el mismo; la sesión de muse es `muse-goncloud-Orbit` y su pantalla se lee con el comando de captura de «Quién»; un encargo de muse en vuelo se reconoce por el `BRIEF.md` en la raíz del checkout principal y se espera con el bucle de «Quién». Antes de cualquier compuerta, el lead nuevo mira dónde está la rama del ítem (`/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit rev-parse --abbrev-ref HEAD` y lo mismo con `-C /Users/dn/dev/wt-fase10-lead`): sin `APPROVE` va en el principal; con `APPROVE` la trae al worktree con el traspaso de la regla 1. Un carril con PR abierto y `APPROVE lead <sha>` sin merge se retoma en la compuerta, no en el paso 1. |

---

## Inventario y cierre

**Cuentas.** Cuatro ramas de trabajo más la del plan y las de corrección de la revisión de cierre si las hay, cinco ítems de cola más Q3 bis, tres filas del plan (A.1, A.7, E.0a). Cero migraciones nuevas. Cero despliegues de Orbit, cero escrituras en Amazon, cero escrituras en la base de producción, cero goals sembrados.

**Presupuesto.** Sin tope de rondas cruzadas por PR (desviación de la sección 4 del loop, declarada en «Loop de entrega»: regla del dueño desde el 2026-09-15), a 100–150 mil tokens cada una. Referencia medida en la Fase 8: tres rondas por carril de código y cinco en el de medición. Estimación de la fase: **entre diez y dieciséis rondas**, más una vuelta extra del carril B por el orden de `tests/test_architecture.py`. Q0 y Q4 llevan una ronda cada uno. No hay nada que instalar antes de lanzar; las precondiciones son las del paso 0.0.

**Fuera de alcance**, y por qué: **A.5** (corrida diaria) y **A.6** (pantalla y avisos), que dependen de A.1 y A.7 en `master` y llevan los cinco detalles anotados en la celda de A.3 v1.3 (limitador en `cambiar_precio`, `repartir_cupo` por plataforma, virtuales como `confirmado`, `pendiente` huérfana, `L` por canal); **E.0b**, que espera el veredicto de E.0a; **A.4**, **D.0** y **E.2**, que llevan decisión o go literal de David; y **todas las filas de las fases E (salvo E.0a), 0, B y M**.

**Lo que queda listo para David, en orden.** (1) **E.2, parte 1**: el acta de la ventana del envío, con los hechos 20–22 del plan v1.3 y `docs/evidencia/repricing-01/E.1/medicion.md`; sella ventana, mínimo 6 con salida en 3 y qué pasa sin historia (el valor y el ingreso por envío, parte 2, esperan al veredicto de E.0a). (2) **D.0**: aplicar la 0039 con `docs/DEPLOY.md` §«Migración 0039» y sembrar las 20 claves `precio_*` de la tabla del plan (todas menos las cinco `precio_envio_*`, que esperan a E.2) **como una `config_version` nueva copiando la vigente** (`settings || jsonb_build_object(...)`, patrón de `docs/DEPLOY.md` §caps de harvest): una fila con solo las claves `precio_*` dejaría sin caps a Ads y su cuota reventaría; el readback confirma los caps de Ads vivos; y no en la misma ventana de despliegue que D.3 de `fabrica-02`. (3) **El goal del producto controlado**: con `tools/precio_goal.py --mode live --go <literal>` desde el contenedor app, sobre un listing MX donde no importe subir un centavo. (4) **A.4**: la sonda, con la decisión `subir` insertada a mano como dice la celda A.4 v1.3, y el PR `fase<N>/a4-forma-parche` que sella la forma del parche. Nada de eso lo hace esta fase, y el `siguiente_paso` final del progreso lo dice en lenguaje llano.

**Cómo reporta el lead.** Al cerrar cada carril y la fase, la última línea es `LISTO <sha>` o `ATORADO <razón>`, según la sección 2 del loop. El cierre incluye la revisión completa de la sección 10 contra la DoD literal de las tres filas, con mutación de las pruebas nuevas, y solo entonces se abre Q4. El `LISTO` de la fase se escribe solo después del bucle de cierre del postmerge de Q4. El estado final queda en `.saikit/progress/10.json`, en el último comentario de progreso del PR de cierre, y en la tarea `AUTO-07` del tracker, con `siguiente_paso` diciendo que lo que sigue es de David: E.2, D.0, el goal del producto controlado y A.4.

**La fuente es este archivo.** Cualquier copia en una página web es eso, una copia, y lo dice en su pie.
