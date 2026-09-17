# Autopilot de la Fase 8 — cimientos del motor de precios (Orbit)

Esto lo ejecutas tú, el **lead**, en autopilot. **David no está y no se le pregunta nada**: lo que necesitarías consultarle ya está decidido en la tabla de preaprobaciones, o es una fila de la tabla de atores. Si algo no está escrito aquí ni en `docs/runbooks/loop-autopilot.md`, se declara como residual en el PR y la corrida sigue.

La fase construye los **cimientos** del motor de precios de Orbit: el esquema, las reglas puras, el camino de escritura con su reversa, y la medición del costo de envío. **No despliega nada, no toca producción con escrituras y no cambia un solo precio en Amazon.** El primer cambio real de precio es de David, en la fila A.4 del plan, y queda fuera de esta fase.

Versión 2, 2026-09-16. La versión 1 fue ejecutada en seco por dos lectores de contexto fresco que devolvieron 37 hallazgos; los 24 redactables están incorporados aquí y los cuatro bloqueos quedaron resueltos con las decisiones que están en «Bloqueos levantados». El rastro completo, con los comandos y sus salidas, está en `autopilot-fase8-hallazgos.md`.

---

## Bloqueos levantados (por qué esta versión sí se lanza)

| Bloqueo de la v1 | Cómo quedó |
|---|---|
| El tablero de progreso no existe: el plugin `tablero-runbook` no está instalado, el gateway responde `unknown method: runbook.progress.set`, y `--params @<archivo>` no lo acepta la CLI (`--params must be valid JSON`) | **La fase corre sin tablero**, por decisión de David («arranca»). Ver la regla 10: el progreso se escribe en un archivo local y en los PRs. **Desviación declarada** de la sección 8 del loop y del slot de progreso de la skill `autopilot-runbook`, por causa medida y no por omisión. La forma `--params @<archivo>` está mal escrita también en `loop-autopilot.md` §8 y en `docs/spec/runbook-progress.v1.md`: es un arreglo de una línea que no pertenece a esta fase y queda declarado aquí para quien lleve esos documentos. |
| El plan dice que Repricing no arranca antes de cerrar D.3 de `fabrica-02` (19-sep) | **David lo adelantó**, con su palabra literal: «arranca deja listo para empezar repricing y manda revision» (2026-09-16). La restricción del plan era de atención del dueño, no técnica, y el dueño la levantó. |
| El carril de medición implementa una fila de la fase E, que no pasó la ronda de cinco perspectivas | **La ronda está corriendo** sobre las fases E, B y M, lanzada por David en el mismo mensaje. El carril D puede avanzar porque es `[stage:verificacion]`, solo lectura, y **no produce código de producto**: su salida es la evidencia que esa misma ronda y el acta E.2 necesitan como insumo. **Las filas E.3 en adelante no se implementan hasta que la ronda cierre**, y ninguna está en esta fase. |
| No se sabía si muse trabaja en un worktree | **Medido 2026-09-16**: `tmux display-message -p -t muse-goncloud-Orbit '#{pane_current_path}'` devuelve `/Users/dn/dev/goncloud-Orbit`, y lo mismo las sesiones `claude-` y `kimi-`: **una sesión por repo, parada en el checkout principal**. Por eso los carriles de muse son **secuenciales**, no paralelos, y el lead trabaja en su propio worktree. Ver «Carriles». |

---

## Quién

| Rol | Quién | Qué hace en esta fase |
|---|---|---|
| **claw** | el agente `main` del gateway | Lanza al lead y lo vigila por tmux. Relanza si se cae. No mergea ni despliega. |
| **lead** | un CLI en tmux, de cualquier host que el kit de merge conozca; la lista vive en la sección 1 del loop y claw elige por preferencia y cuota | Escribe los encargos, audita, corre la cruzada, aprueba, mergea por la ruta del kit, escribe progreso y cierra. **Además implementa el carril D**, que el plan le asigna. No escribe código de producto. |
| **implementador** | **muse**, en los carriles A, B y C, **uno a la vez** | Escribe el código en el checkout principal de Orbit y reporta con la línea de contrato. No hace push ni abre PR. |
| **revisor cruzado** | otra IA por `cross-review.ps1` | Segunda opinión sobre el SHA del PR. En A, B y C implementa muse, que no es candidato a revisor: se pasa `-Excluir ''` y se anota en el PR quién implementó. En el carril D implementa el lead: se excluye **al host del lead** con `-Excluir <host>`. |
| **David** | el dueño | **Ninguna acción durante la corrida.** Al cierre lee el reporte. Lo que queda listo para él son las filas A.4 y E.2 del plan, que esta fase prepara y no ejecuta. |

**Cómo se lanza a muse.** Una sesión de tmux por repo, ya viva, parada en el checkout principal: `muse-goncloud-Orbit`. El lead deja el `BRIEF.md` en la raíz de ese checkout, manda el encargo a la sesión con `/opt/homebrew/bin/tmux send-keys -t muse-goncloud-Orbit '<instrucción>' Enter`, y lee la respuesta con `/opt/homebrew/bin/tmux capture-pane -p -t muse-goncloud-Orbit | tail -40`, buscando la línea de contrato de la sección 2 del loop. Un encargo a la vez: la sesión y el checkout son uno solo.

---

## Arranque

**Paso 0.0 — precondiciones.** Corre esto antes de nada, con el directorio de trabajo en `/Users/dn/dev/goncloud-Orbit`.

```
test -r /Users/dn/dev/summonaikit-claude/tools/MANIFEST.sha256 || echo ATORADO kit ausente
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit fetch -q origin
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit show origin/master:.saikit/autopilot.json
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit status --porcelain | head -5
/opt/homebrew/bin/pg_isready -h localhost -p 5432
/opt/homebrew/bin/psql "postgresql://orbit:orbit@localhost:5432/postgres" -Atc "select 1"
/opt/homebrew/bin/tmux display-message -p -t muse-goncloud-Orbit '#{pane_current_path}'
```

**Lo que 0.0 no puede comprobar, y hay que saber antes de prometer seis merges.**
La sección 6 del loop pide dos cosas que ningún comando responde desde aquí: que
el hook del kit esté instalado **en el host que vaya a ser lead**, y que haya
pasado un merge de prueba por host. Tampoco se puede comprobar de antemano que el
veredicto sellado se cree y se consuma **en la misma sesión viva, mismo host y
misma ruta de proyecto**, que es lo que el kit exige.

Por eso el primer merge de la cola es el de este runbook (paso 0.1), y va **con
`--dry-run` antes que nada**: si el sello no funciona en tu host, ahí sale, antes
de haber lanzado un solo carril. Un `sin estado del hook` en ese dry-run detiene
la fase; no se sigue esperando que el siguiente merge sí pase.

La credencial `orbit:orbit` de esas líneas es la del Postgres **local y desechable** de desarrollo, ligada a `localhost`, y no abre nada más: no se reutiliza contra otro destino, no se copia a un archivo de configuración y no aparece en ningún comando que salga de esta máquina. Producción se toca solo por el camino del carril D, que lee su cadena de conexión del contenedor y nunca la escribe en el runbook.

Esperado, en orden: sin salida; sin salida; la línea `{"merge":true,"merge_despliega":"no","salud_url":null,"revert_si_rojo":true,"rama":"master","sin_verify_app":false,"telegram":false}`; **sin salida** (el checkout principal limpio); `localhost:5432 - accepting connections`; `1`; `/Users/dn/dev/goncloud-Orbit`.

**Detienen la fase**: el kit ausente, y `autopilot.json` ausente de `origin/master`. **Detiene el arranque de los carriles de muse, no la fase**: un checkout principal sucio; el carril D del lead puede avanzar igual mientras se resuelve.

**Paso 0.1 — el runbook está en git.** Este documento vive en `gon0801/goncloud-openclaw`, rama `docs/runbook-fase8`, worktree `/Users/dn/dev/wt-fase8`, y **se mergea a `main` de openclaw antes de lanzar la fase**, con la ventana segura de la sección 7 del loop, porque mergear ahí es desplegar. Sin eso, un lead que reemplace al primero no tiene de dónde leerlo (sección 9 del loop). Ese PR no cuenta contra el tope de tres PRs de Orbit: es otro repo.

**Paso 0.2 — la tarea del tracker.** El `CLAUDE.md` de Orbit lo hace obligatorio. Al arrancar, con la skill `appflowy-ehv-task`, se marca `In progress` la tarea `AUTO-07 Repricing (plan formal)` con una nota que diga que corre la Fase 8 y qué filas cubre. Al cierre se anota el resultado. No se crea tarea nueva: `AUTO-07` es la del plan formal y `ORBIT 09` cierra cuando cierre el módulo entero, que no es esta fase.

**Paso 0.3 — lee el plan.** `plans/repricing-01.md` en `origin/master` de Orbit, v1.1, y su spec `docs/superpowers/specs/2026-09-15-repricing-01-design.md` v1.2. Las filas que esta fase implementa son **A.0, A.2, A.3 y E.1**, y sus DoD van verbatim al encargo de cada carril.

**Qué documento manda.** La cadena completa, de mayor a menor: `docs/runbooks/loop-autopilot.md` (salvo la tabla de preaprobaciones de abajo, que es la excepción que el propio loop reconoce) > `docs/CONTEXTO.md` reglas 1–10 > el spec `2026-09-15-repricing-01-design.md` v1.2 > `plans/repricing-01.md` > este runbook. Dentro de esa cadena: el plan y el spec mandan en **qué** se construye y en la DoD; este runbook manda en **cómo** corre la fase (quién, ramas, archivos, cola, atores). Si el plan y el spec se contradicen, gana el spec, que es lo que el propio plan declara. Si algo de esta fase contradice al plan, gana el plan y el lead lo escribe como residual en el PR; **ninguna tarea de esta fase edita el plan salvo el ítem de cierre Q5**, y solo sus celdas de estado.

**Dónde vive cada cosa.**

| Repo | Ruta local | Default | Copia desplegada |
|---|---|---|---|
| `gon0801/goncloud-Orbit` | `/Users/dn/dev/goncloud-Orbit` (checkout de muse) y `/Users/dn/dev/wt-fase8-lead` (worktree del lead) | `master` | `/mnt/data/appdata/orbit` en el host `goncloud` — **fuera de alcance**: `merge_despliega` es `no` y esta fase no despliega |
| `gon0801/goncloud-openclaw` | `/Users/dn/dev/goncloud-openclaw` y el worktree `/Users/dn/dev/wt-fase8` | `main` | el gateway, por sync — **solo** para mergear este runbook en el paso 0.1 |

---

## Preaprobaciones del dueño

| Operación | Alcance | Decisión |
|---|---|---|
| Arrancar la fase antes del 19-sep | Esta fase | **Aprobado**, palabra literal de David 2026-09-16: «arranca deja listo para empezar repricing y manda revision» |
| Crear ramas, worktrees y PRs en `gon0801/goncloud-Orbit` | Las cinco ramas `fase8/*` de este runbook | **Aprobado** |
| Mergear a `master` de Orbit por la ruta del kit | Los cinco PRs de esta fase, con su `APPROVE lead <sha>` y CI verde | **Aprobado** |
| Mergear este runbook a `main` de goncloud-openclaw | Solo `docs/runbooks/autopilot-fase8*.md` | **Aprobado** |
| Lanzar implementadores y revisores cruzados con costo de tokens | Hasta el presupuesto del inventario | **Aprobado** |
| Crear una migración nueva en `migrations/` | Solo la siguiente libre (hoy `0039_precio.sql`), sin aplicarla a ninguna base que no sea la local de pruebas | **Aprobado** |
| Leer producción de Orbit por `ssh goncloud` con consultas de **solo lectura** | Solo el carril D, solo `SELECT`, solo por el rol lector, y **solo el lead** | **Aprobado** |
| Editar **las celdas de estado** de las cuatro filas del plan y `docs/CHAT-CONTEXT.md` | Solo en el ítem de cierre Q5, solo esas celdas, con el SHA de squash | **Aprobado** |
| Marcar la tarea `AUTO-07` en el tracker | Al arrancar y al cerrar | **Aprobado** |
| Aplicar la migración a la base de producción | — | **Negado**: es la fila D.1 del plan y la corre David |
| Desplegar código de Orbit | — | **Negado**: `merge_despliega` es `no`; el deploy es de David |
| Escribir un precio en Amazon o en Mercado Libre, aunque sea un centavo | — | **Negado**: es la fila A.4 del plan y lleva go literal de David |
| Sembrar goals en `precio_goal` de producción | — | **Negado**: es la fila D.1 |
| Tocar `.saikit/autopilot.json` en cualquier repo | — | **Negado**: el kit lo lee de `origin/master` y rechaza el PR que lo toque |
| Editar el cuerpo de una fila del plan, o el spec | — | **Negado**: una discrepancia se declara, no se corrige aquí |
| Implementar cualquier fila de la fase E que no sea E.1 | — | **Negado**: la ronda de cinco perspectivas sobre E, B y M todavía no cierra |

---

## Prohibido

> **Prohibido en esta fase, sin excepción:** preguntarle algo a David; aplicar la migración a producción; desplegar Orbit; escribir cualquier cosa en Amazon o en Mercado Libre; ejecutar `tools/precio_reversa.py` contra datos reales; escribir en la base de producción (solo `SELECT`); tocar `.saikit/autopilot.json`; editar el cuerpo de una fila del plan o el spec; implementar filas de la fase E distintas de E.1; mergear por cualquier vía que no sea la del kit; usar `--no-verify`; **cambiar de rama en el checkout principal mientras muse tiene trabajo sin commitear**; borrar ramas o worktrees ajenos; abrir un cuarto PR simultáneo en Orbit; inventar la forma del parche de precio de Amazon (se entrega marcada `pendiente_sonda`); lanzar dos encargos a muse a la vez.

---

## Reglas de trabajo

1. **Muse trabaja en el checkout principal, uno a la vez.** Medido: su sesión de tmux está parada en `/Users/dn/dev/goncloud-Orbit`. Antes de cada carril de muse, el lead deja ese checkout en la rama del carril, y **solo** si está limpio:

   ```
   /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit status --porcelain | head -5
   /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit fetch -q origin
   /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit checkout -b fase8/<rama> origin/master
   ```

   Si la primera línea imprime algo, **no se cambia de rama**: se aplica la fila de atores. Al terminar el carril, el checkout se queda en esa rama hasta que su PR mergee.

2. **El lead trabaja en su propio worktree**, uno para toda la fase, y ahí hace el carril D, las auditorías, las compuertas y los merges:

   ```
   /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit worktree add /Users/dn/dev/wt-fase8-lead -b fase8/envio-medicion origin/master
   ln -s /Users/dn/dev/goncloud-Orbit/.venv /Users/dn/dev/wt-fase8-lead/.venv
   ```

   **El enlace del entorno de Python no es opcional**: el candado `pytest-pre-push` busca `./.venv/bin/python` relativo a la raíz del worktree, y un worktree recién creado no lo tiene; sin el enlace el primer `git push` muere con «failed to push some refs» y sin más explicación. El checkout principal ya lo tiene, así que los carriles de muse no lo necesitan.

3. **Las pruebas de base tienen que correr de verdad, no saltarse.** Orbit salta sus pruebas de PostgreSQL cuando no hay base utilizable, así que un carril puede verse verde sin haber probado nada. En la Mac **no hay Docker**; la base es la de Homebrew, ya arriba. Todo comando de pruebas lleva el DSN, idéntico al de CI, y se corre con el directorio de trabajo en el árbol del carril:

   ```
   cd <árbol del carril> && ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" \
     ./.venv/bin/python -m pytest <archivos> -q
   ```

   El encargo exige pegar en el reporte la línea final del pytest, con el conteo de `passed` y el de `skipped`. **Si las pruebas de base del carril salen `skipped`, el carril no terminó.**

4. **Mutar una prueba que se está saltando no prueba nada.** Antes de auditar, el lead confirma `/opt/homebrew/bin/pg_isready -h localhost -p 5432` en `accepting connections`.

5. **Número de migración, releído con `fetch`.** Solo el carril A crea migración. El número es el siguiente libre, y se relee **con la referencia fresca** al abrir el PR y otra vez en la compuerta:

   Para **elegir** el número, antes de escribir la migración:

   ```
   /opt/homebrew/bin/git fetch -q origin
   ULT=$(/opt/homebrew/bin/git ls-tree --name-only origin/master migrations/ \
       | sed -n 's|migrations/\([0-9]\{4\}\)_.*|\1|p' | sort | tail -1)
   echo "libre: $(printf '%04d' $((10#$ULT + 1)))"
   ```

   Hoy `ULT` es `0038`, así que el libre es `0039`. **El máximo más uno, no el último de la lista ordenada**: si existen `0039` y `0040`, el libre es `0041`, y una lectura que solo mire "no es 0038" se lleva un número tomado.

   Y en la compuerta, para **comprobar** que sigue libre, que es otra pregunta:

   ```
   /opt/homebrew/bin/git fetch -q origin
   NUEVA=$(/opt/homebrew/bin/git diff --name-only --diff-filter=A origin/master...HEAD -- migrations/ | head -1)
   NUM=$(echo "$NUEVA" | sed -n 's|migrations/\([0-9]\{4\}\)_.*|\1|p')
   /opt/homebrew/bin/git ls-tree --name-only origin/master migrations/ \
       | grep -q "^migrations/${NUM}_" && echo "COLISION: $NUM ya aterrizó en master" || echo "LIBRE $NUM"
   ```

   Esa es la que puede salir mal de verdad: el carril eligió `0039` cuando estaba libre, y mientras su PR esperaba revisión aterrizó un `0039` ajeno. **Comprobar el máximo más uno en la compuerta no sirve**, porque ese número nunca puede estar tomado por construcción y la rama de colisión jamás se ejecutaría. `COLISION` manda al carril a renumerar con el primer bloque, en el mismo PR, y volver al paso 3 del loop.

6. **`tests/test_architecture.py` tiene dueño y orden: primero el carril B, después el C.** C no toca ese archivo hasta que B esté en `master`. **Desviación declarada**: la tabla de propiedad de archivos del plan asigna ese archivo a la fila A.1, que no está en esta fase; como B y C lo necesitan para sus DoD, esta fase se lo reparte con ese orden y lo escribe en el PR.

7. **Un candado que no puede salir rojo no cuenta.** Cada candado nuevo se entrega con su fuga sembrada en `tmp_path` demostrando el rojo; sin esa demostración, vuelve al paso 1 del loop. El candado de pureza de `app/precio/*` solo discrimina si esa carpeta existe con archivos: por eso vive en el carril B, que la crea.

8. **La forma del parche de precio de Amazon no se inventa.** El carril C entrega `app/spapi/precio_write.py` con el cuerpo del parche marcado `pendiente_sonda` **en el código que construye el cuerpo**, no en un comentario ni en el nombre de un test, y sus pruebas contra un cliente falso. Sellarlo es la fila A.4 del plan, de David.

9. **El carril D solo lee, y lo corre el lead.** El plan se lo asigna: «E.1 … (lead, solo lectura)». Sus consultas viven versionadas en `docs/evidencia/repricing-01/E.1/consultas/*.sql` y se corren así, desde el worktree del lead:

   ```
   { echo 'BEGIN READ ONLY;'; cat docs/evidencia/repricing-01/E.1/consultas/envio-por-producto.sql; } \
     | ssh goncloud 'set -eu
         DSN=$(docker exec orbit-app-1 printenv ORBIT_DSN_READ)
         test -n "$DSN" || { echo "ATORADO: ORBIT_DSN_READ vacio"; exit 1; }
         docker exec -i orbit-db-1 psql "$DSN" -X -P pager=off -tA -v ON_ERROR_STOP=1'
   ```

   **El `test -n` tampoco es adorno.** Si `printenv` falla o devuelve vacío, sin esa
   línea el shell sigue y corre `psql ""`, y libpq entonces arma la conexión con sus
   valores por defecto: usuario del sistema, base con ese mismo nombre, socket local.
   O sea la consulta se ejecuta, devuelve algo, y **no es de la base que creías**. El
   `set -eu` cubre el otro lado, que `printenv` reviente y el fallo no se note.

   **El `BEGIN READ ONLY` no es adorno.** El nombre de la variable dice `READ` pero es solo un nombre: si el rol no trae `default_transaction_read_only` puesto, cualquier escritura que se cuele en un archivo de consulta corre contra producción. La transacción de solo lectura la rechaza, y `ON_ERROR_STOP` hace que se note en vez de seguir con la siguiente línea. Esto es lo único de esta fase que toca la base de producción: el costo de equivocarse no es un carril atorado.

   Si `ssh` no responde, el dato queda `unknown` con la consulta que lo resolvería escrita al lado, y el carril entrega lo que sí midió.

10. **El progreso se escribe, sin tablero.** El plugin que serviría `runbook.progress.set` no existe en esta máquina y la CLI no acepta la forma `--params @<archivo>` (ver «Bloqueos levantados»). Por eso, **desviación declarada de la sección 8 del loop**: en cada cambio de estado de un carril o de la cola, y al cierre, el lead escribe `/Users/dn/dev/goncloud-Orbit/.saikit/progress/8.json` con el formato `runbook-progress.v1` y **no lo envía a ningún lado**. Ese archivo **no se commitea**: `.saikit/` está en el `.gitignore` de Orbit (línea 22) por diseño, y esta fase no lo fuerza. Es una ruta única, la del checkout principal, y ningún carril lo lista en su tabla de archivos. Se respeta la forma del spec, incluido `atencion_requerida` como objeto `{necesaria, motivo, desde}` y `siguiente_paso` de ≤160 caracteres en lenguaje llano; `paso_loop` se escribe `8` para cualquier carril que ya pasó la aprobación, porque el spec lo cierra en 0–8 y el loop tiene once pasos. **Ese archivo vive en una sola máquina y no basta para un relevo.** Está en el checkout principal, no se commitea porque `.saikit/` está en el `.gitignore` de Orbit, y no se envía a ningún lado: un lead que arranque en otro host no puede leerlo, y sin él repetiría carriles o perdería `detenido_por` y `siguiente_paso`. Por eso, en cada cambio de estado, el lead **también pega el JSON completo como comentario en el PR abierto del carril activo**, o en el del último si ninguno está abierto:

   ```
   /opt/homebrew/bin/gh pr comment <pr> --body-file /Users/dn/dev/goncloud-Orbit/.saikit/progress/8.json
   ```

   Eso lo vuelve legible desde cualquier host sin pelearse con el `.gitignore` y sin inventar una ruta trackeada. **Lo que un tercero puede verificar son los PRs, sus comentarios `APPROVE lead <sha>`, y el último comentario de progreso**; el archivo local es la copia de trabajo, no la fuente.

11. **El cierre se reporta, no se relaya.** Al cerrar cada carril y la fase, la última línea en pantalla es `LISTO <sha>` o `ATORADO <razón>`, según la sección 2 del loop; claw la lee de tmux y hace lo que tenga que hacer con ella. **No hay comando de Telegram en esta fase**: `autopilot.json` de Orbit trae `telegram: false` y el kit no avisa. Donde la sección 5 del loop manda poner una línea «en el Telegram» (por ejemplo, CodeRabbit sin cuota), en esta fase esa línea va **en el cuerpo del PR y en el archivo de progreso**. Desviación declarada.

12. **Nada en esta fase despliega Orbit.** `merge_despliega` es `no`: mergear a `master` no lleva el código al servidor. Por eso la sección 7 del loop no aplica a los PRs de Orbit, y no hay ventana segura ni canary para ellos. **Sí aplica** al merge del runbook en openclaw del paso 0.1.

13. **El candado léxico del kit deniega por el nombre, no por el hash.** Medido: el basename del script de merge dentro de un `echo`, aun con la ruta entera, devuelve `merge denied: … hash does not match the kit manifest` aunque el hash sí casa y aunque el comando no mergee nada. La regla real: ese basename **no puede aparecer en un comando salvo como ruta absoluta que resuelva a un archivo**; nada de `echo`, banners, cuerpos de PR ni variables en la misma línea. El mensaje engaña porque dice «merge denied» incluso para un `ls`: no se interpreta como que el kit esté roto.

---

## Loop de entrega

Rige `docs/runbooks/loop-autopilot.md` de goncloud-openclaw, completo y sin repetirlo aquí: el loop por tarea (sección 3), la política de rondas cruzadas (4), PRs y CodeRabbit (5), la ruta del kit para mergear (6), la reanudación si el lead muere (9), la revisión de cierre de fase (10) y los atores universales (12).

**Desviaciones de esta fase, nombradas.** De la **sección 7** (despliegue y gateway): no aplica a los PRs de Orbit, porque `merge_despliega` es `no`; sí aplica al merge del runbook en openclaw del paso 0.1. De la **sección 8** (progreso): el archivo se escribe pero no se envía, porque el método del gateway no existe en esta máquina; el detalle y la medición están en «Bloqueos levantados» y en la regla 10. De la **sección 5**, la línea «CodeRabbit sin cuota» va al PR y al archivo de progreso, no al Telegram, porque esta fase no tiene Telegram. De la **sección 4**, `-Excluir` va vacío en los carriles A, B y C, porque implementa muse y muse no está en la cadena de revisores; en el carril D implementa el lead, así que se excluye a su propio host.

---

## Carriles

Cinco ramas, todas nacidas de `origin/master` de Orbit. **Los carriles de muse (A, B, C) van uno a la vez**, porque su sesión y su checkout son uno solo. **El carril D corre en paralelo**, en el worktree del lead, porque lo implementa el lead y no toca código.

```
muse  (checkout principal):   A ──────► B ──────► C
lead  (worktree propio):      D ─────────────────────► Q5
cola:                         Q1(A)  Q2(D)  Q3(B)  Q4(C)  Q5(cierre)
```

### A · Migración del motor — rama `fase8/precio-migracion` · muse

Fila **A.0** del plan, verbatim en el encargo. Crea `migrations/0039_precio.sql` con el enum `precio_mode` y las tablas `precio_goal`, `precio_decision`, `precio_cotizacion`, `precio_envio_muestra` y `precio_cambio`, con sus CHECK, índices parciales, triggers de append-only y de transiciones, los GRANT por columna, y `apply_cap_de_config` ampliado con `precio:amazon_mx`, `precio:amazon_us` y `precio:meli`.

**DoD**: la de la fila A.0 del plan, entera. Además: el test de 0002 sobre `apply_cap_de_config` sigue verde, y el bloque `DO` de prueba bajo `SET ROLE` revierte lo que inserta.

### D · Medición del envío — rama `fase8/envio-medicion` · lead

Fila **E.1** del plan. Solo lectura sobre producción. Produce `docs/evidencia/repricing-01/E.1/` con: las consultas versionadas y sus salidas literales; por producto y plataforma, `envios, mediana, p75, p90, max` de los últimos 180 días; el conteo de órdenes descartadas por traer más de un producto o por no ligar a una venta, con su razón; y el efecto de p50, p75 y p90 sobre el margen de al menos diez productos FBM.

**DoD**: la de la fila E.1. Además: ninguna consulta escribe; cada tabla del documento cita el archivo `.sql` que la produjo; y el documento dice en su encabezado que es el insumo del acta E.2 y de la ronda de cinco perspectivas en curso.

### B · Reglas puras — rama `fase8/precio-reglas` · muse

Fila **A.2** del plan. Crea `app/precio/{tipos,reglas,objetivo,ventas,config}.py` y la función `cotizar_a_precio` en `app/estimacion_fees.py`, con el banco de pruebas y el catálogo de mutantes.

**DoD**: la de la fila A.2, con todos sus bordes. Además: el candado de pureza de `app/precio/*` en `tests/test_architecture.py`, con su fuga sembrada.

### C · Escritura y reversa — rama `fase8/precio-escritura` · muse

Fila **A.3** del plan. Crea `app/spapi/write_client.py`, `app/spapi/precio_write.py` y `tools/precio_reversa.py`, en ese orden de commits: primero el cliente, después la reversa, después la escritura.

**DoD**: la de la fila A.3. Además: los tres candados con fuga sembrada, `SpapiClient` sin verbo de escritura, y el marcador `pendiente_sonda` en el código que construye el cuerpo del parche.

### Q5 · Cierre — rama `fase8/cierre` · lead

No es un carril de trabajo: es el ítem que cierra la fase después de la revisión de la sección 10 del loop. Marca `cc:完了` las celdas de estado de A.0, A.2, A.3 y E.1 con su SHA de squash y sus salvedades, y actualiza `docs/CHAT-CONTEXT.md`, que el CI exige en el mismo PR.

### Archivos por carril

| Carril | Puede tocar | No toca |
|---|---|---|
| **A** | `migrations/0039_precio.sql`, `tests/test_precio_migracion.py`, `tests/test_schema.py`, `docs/DATABASE.md`, `docs/DEPLOY.md` | `app/**`, `tools/**`, `tests/test_architecture.py`, `plans/**`, `docs/superpowers/**`, `docs/evidencia/**` |
| **D** | `docs/evidencia/repricing-01/E.1/**`, incluidas sus `consultas/*.sql` | todo lo demás del repo |
| **B** | `app/precio/{tipos,reglas,objetivo,ventas,config}.py`, `app/estimacion_fees.py` (solo agrega `cotizar_a_precio`), `tests/test_precio_reglas.py`, `tests/test_architecture.py`, `docs/evidencia/repricing-01/A.2/mutantes.md` | `migrations/**`, `app/spapi/**`, `tools/**`, `app/cycle.py`, `app/apply.py`, `plans/**` |
| **C** | `app/spapi/write_client.py`, `app/spapi/precio_write.py`, `tools/precio_reversa.py`, `tests/test_spapi_write_client.py`, `tests/test_precio_write.py`, `tests/test_architecture.py` (después de que B mergee), `docs/evidencia/repricing-01/A.3/mutantes.md` | `migrations/**`, `app/precio/**`, `app/spapi/client.py`, `app/apply.py`, `plans/**` |
| **Q5** | `plans/repricing-01.md` (**solo las celdas de estado** de A.0, A.2, A.3 y E.1), `docs/CHAT-CONTEXT.md` | todo lo demás, incluido el cuerpo de cualquier fila y el spec |

**Fuera de toda tabla, y nunca se commitea**: el `BRIEF.md` de cada encargo, que vive en la raíz del árbol del carril; el rojo de TDD en `.saikit/scratch/<carril>/tdd.md`; y `.saikit/progress/8.json`. Los tres están cubiertos por el `.gitignore` de Orbit o se borran antes del push, y el lead lo verifica en la compuerta de cada ítem. El **catálogo de mutantes** sí se commitea, en `docs/evidencia/repricing-01/<fila>/mutantes.md`, porque es la evidencia que la DoD pide.

---

## Cola de merge

En este orden. Cada ítem se mergea por la ruta del kit de la sección 6 del loop, **desde el árbol de ese carril**. Ninguno de Orbit lleva compuerta de despliegue.

**El número de PR** de cada ítem se obtiene así, nunca a mano:

```
pr=$(/opt/homebrew/bin/gh pr list --repo gon0801/goncloud-Orbit --head fase8/<rama> --json number --jq '.[0].number')
```

**Q1 · Carril A** (`fase8/precio-migracion`, árbol `/Users/dn/dev/goncloud-Orbit`).

```
cd /Users/dn/dev/goncloud-Orbit
/opt/homebrew/bin/gh pr checks $pr | head -3
/opt/homebrew/bin/git fetch -q origin && /opt/homebrew/bin/git ls-tree --name-only origin/master migrations/ | sort | tail -1
ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" ./.venv/bin/python -m pytest tests/test_precio_migracion.py tests/test_schema.py -q | tail -2
/opt/homebrew/bin/git status --porcelain | grep -E 'BRIEF\.md|\.saikit/' || echo LIMPIO
```

Esperado: `quality` en `pass`; la última migración de `master` **no** es `0039`; `N passed` con `N ≥ 1` y **sin** `skipped`; y `LIMPIO`. Fallback: si ya hay un `0039`, el carril renumera a `0040` en el mismo PR y vuelve al paso 3 del loop; si hay `skipped`, aplica la fila «Las pruebas de base se saltan»; si el último comando imprime rutas, se sacan con un commit propio antes del merge.

**Q2 · Carril D** (`fase8/envio-medicion`, árbol `/Users/dn/dev/wt-fase8-lead`).

```
cd /Users/dn/dev/wt-fase8-lead
/opt/homebrew/bin/gh pr checks $pr | head -3
/opt/homebrew/bin/git diff --name-only origin/master...HEAD
/opt/homebrew/bin/git diff --name-only origin/master...HEAD | grep -qE '^docs/evidencia/repricing-01/E\.1/' && echo TIENE-EVIDENCIA || echo SIN-EVIDENCIA
/opt/homebrew/bin/git diff --name-only origin/master...HEAD | grep -vE '^docs/evidencia/repricing-01/E\.1/' | head -3
/opt/homebrew/bin/git status --porcelain | head -5
```

Esperado: `quality` en `pass`; `TIENE-EVIDENCIA`; y los dos últimos comandos **sin salida**. El de estado va aparte del diff a propósito: un `BRIEF.md` residual no está trackeado, así que **el diff no lo ve**, y la regla de trabajo prohíbe conservarlo. Esta misma línea va en cada compuerta que mergea, no solo aquí: lo que un ítem anterior dejó suelto aparece en el árbol del siguiente. Fallback: `SIN-EVIDENCIA` significa que el entregable no está y el ítem no mergea; cualquier ruta intrusa se saca con un commit propio.

**Q3 · Carril B** (`fase8/precio-reglas`, árbol `/Users/dn/dev/goncloud-Orbit`).

```
cd /Users/dn/dev/goncloud-Orbit
/opt/homebrew/bin/gh pr checks $pr | head -3
ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" ./.venv/bin/python -m pytest tests/test_precio_reglas.py tests/test_architecture.py -q | tail -2
/opt/homebrew/bin/git status --porcelain | grep -E 'BRIEF\.md|\.saikit/' || echo LIMPIO
```

Esperado: `quality` en `pass`; `N passed` sin `skipped`; `LIMPIO`. Fallback: `skipped` → fila de atores; rojo en los candados → vuelve al paso 3 del loop.

**Q4 · Carril C** (`fase8/precio-escritura`, árbol `/Users/dn/dev/goncloud-Orbit`). **Precondición**: el carril C está rebasado **con el merge de Q3 dentro**, porque comparten `tests/test_architecture.py`. Se comprueba contra el SHA de squash de Q3, que el lead anotó al mergearlo, no contra `origin/master` genérico:

```
cd /Users/dn/dev/goncloud-Orbit
/opt/homebrew/bin/git fetch -q origin
/opt/homebrew/bin/git merge-base --is-ancestor <sha-squash-de-Q3> HEAD && echo CON-Q3 || echo FALTA-Q3
/opt/homebrew/bin/gh pr checks $pr | head -3
ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" ./.venv/bin/python -m pytest tests/test_precio_write.py tests/test_spapi_write_client.py tests/test_architecture.py -q | tail -2
/opt/homebrew/bin/git grep -n pendiente_sonda -- app/spapi/precio_write.py | grep -vE ':[[:space:]]*#' | head -5
/opt/homebrew/bin/git status --porcelain | head -5
```

Esperado, y son **cinco salidas distintas, una por comando**: `CON-Q3`; `quality` en `pass`; `N passed` sin `skipped`; del `git grep`, **al menos una línea, dentro del código que arma el cuerpo del parche**; y del `git status`, **ninguna**. Las dos últimas se leen por separado a propósito: juntas, una ruta sin trackear se puede confundir con la línea del marcador, y la compuerta acabaría rechazando un árbol limpio o aceptando una ruta como si fuera el marcador. Eso es lo que prueba que la forma quedó sin sellar para la fila A.4 de David.

**Se muestran las líneas en vez de contarlas porque un `grep -q` a secas no distingue el marcador real de un comentario o de un test que lo menciona**, y con esa forma una fase que ya resolvió el parche pasaba la compuerta igual. El filtro quita los comentarios; que la línea que queda esté en la construcción del cuerpo y no en otra parte del archivo lo confirma el lead leyéndola, y la cita en el PR. Fallback: `FALTA-Q3` → rebase y otra vez a la compuerta; **sin líneas, o solo en comentarios o tests** → el carril inventó la forma del parche y vuelve al paso 1 del loop con encargo de corrección.

**Q5 · Cierre** (`fase8/cierre`, árbol `/Users/dn/dev/wt-fase8-lead`). Va **después** de la revisión de cierre de la sección 10 del loop, con sus hallazgos ya corregidos y mergeados.

```
cd /Users/dn/dev/wt-fase8-lead
/opt/homebrew/bin/gh pr checks $pr | head -3
/opt/homebrew/bin/git fetch -q origin || { echo "ATORADO: git fetch fallo"; exit 1; }
/opt/homebrew/bin/git diff --name-only origin/master...HEAD | grep -vE '^(plans/repricing-01\.md|docs/CHAT-CONTEXT\.md)$'
/opt/homebrew/bin/git status --porcelain | head -5
for f in A.0 A.2 A.3 E.1; do
  printf '%s ' "$f"
  /opt/homebrew/bin/git diff origin/master...HEAD -- plans/repricing-01.md \
    | grep -cE "^\+.*\b${f}\b.*cc:完了"
done
ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" ./.venv/bin/python tools/check_chat_context_fresh.py origin/master
```

Esperado: `quality` en `pass`; los dos primeros comandos **sin salida**; **las cuatro filas con `1`**; y el candado de frescura en verde.

**El `fetch` va primero, corta si falla, y no se hereda del ítem anterior.** El corte es explícito y no un `set -e` para todo el bloque: los `grep -vE` de abajo esperan cero coincidencias, o sea salida distinta de cero, y un `errexit` general los tomaría por fallos. Q5 compara contra
`origin/master`, que es una referencia local: sin traerla, compara contra lo que
`master` era cuando alguien hizo fetch por última vez. Entre Q4 y Q5 median un
merge y una revisión, tiempo de sobra para que `master` avance, y entonces el diff
muestra rutas ajenas como si fueran del carril y los cuatro conteos miran un
archivo viejo.

**El conteo por fila es la compuerta, no el diff de nombres.** Que los dos archivos cambiaron no dice que las cuatro celdas se cerraron, ni que no se editó una quinta: un PR de cierre equivocado pasaba igual. Una fila en `0` es una celda sin cerrar; en `2` o más, la celda se tocó dos veces y hay que mirar por qué. Fallback: si el candado sale rojo, falta la entrada en `CHAT-CONTEXT.md` y se agrega en el mismo PR; cualquier otra ruta en el diff se saca con un commit propio. Este ítem lleva un loop reducido: auditoría del lead y una ronda cruzada, sin CodeRabbit obligatorio, porque son celdas de estado y prosa.

---

## Cuando algo se atora

Estas son las de esta fase. Las universales están en la sección 12 del loop y no se repiten.

| Situación | Qué hace el lead |
|---|---|
| El kit no está en `/Users/dn/dev/summonaikit-claude/tools` | `ATORADO kit ausente en /Users/dn/dev/summonaikit-claude/tools` y **la fase para**. No se busca el script por el disco ni se mergea por otra vía. |
| `.saikit/autopilot.json` no está en `origin/master` de Orbit | `ATORADO bootstrap ausente` y **la fase para**; `atencion_requerida.necesaria = true` en el archivo de progreso. |
| La ruta del kit rechaza por sello, por estado del hook o por lock | Una vez: re-sellar con un revisor propio desde la sesión viva, en el mismo host y la misma ruta de proyecto, y reintentar. Si sigue: el PR queda abierto con su `APPROVE lead <sha>` y la razón textual, y va al archivo de progreso. Ninguna otra ruta de merge. |
| Un comando es denegado por nombrar el script del kit | Es el candado léxico, no una falla del kit: se reescribe el comando para que ese basename solo aparezca como ruta absoluta resoluble. El mensaje dice «merge denied» aunque el comando no mergee. |
| El checkout principal está sucio al arrancar un carril de muse | **No se cambia de rama.** El carril de muse espera; el carril D del lead sigue. Se anota en el progreso con `siguiente_paso` diciendo qué archivo lo bloquea. A la segunda espera, el carril queda `atorado` y se declara. |
| PostgreSQL local caído | `/opt/homebrew/bin/brew services start postgresql@16`, esperar y reintentar una vez. Si sigue caído: los carriles A, B y C quedan `atorado` con `detenido_por` textual; el carril D no depende de eso y sigue. No se usa Docker: no está en la Mac. |
| Las pruebas de base salen `skipped` | El carril no terminó. Encargo de corrección con el comando del DSN de la regla 3. Un `skipped` nunca cuenta como DoD cumplida. |
| El primer `git push` de un carril del lead muere sin explicación | Falta el enlace del entorno de Python en el worktree; se crea con el `ln -s` de la regla 2 y se reintenta. |
| `origin/master` de Orbit avanzó | Rebase del carril y vuelta a la compuerta. Es esperable: otras sesiones mergean en este repo. |
| Ya existe la migración con el número elegido | El carril A renumera al siguiente libre en el mismo PR y vuelve al paso 3 del loop. |
| El carril C necesita `tests/test_architecture.py` y B no ha mergeado | C trabaja en todo lo demás y deja ese archivo para el final. La regla 6 fija el orden. |
| `ssh goncloud` no responde en el carril D | Lo que falte queda `unknown` con la consulta al lado. No se detiene la fase. |
| Un implementador entrega la forma del parche resuelta | Encargo de corrección: se marca `pendiente_sonda` en el código que construye el cuerpo. Sellar esa forma es la fila A.4 de David. |
| La ronda de cinco perspectivas sobre E, B y M devuelve algo que toca a E.1 | Se corrige en el carril D si ya está abierto, o se declara como residual en su PR si ya mergeó. Ninguna otra fila de la fase E se implementa en esta fase. |
| El plan y este runbook se contradicen | Gana el plan. Residual en el PR, sin editar el plan fuera de Q5. |
| Se necesita un cuarto PR abierto en Orbit | No se abre: se cierra uno primero. Con muse secuencial, lo normal es tener dos: el suyo y el del lead. |

---

## Inventario y cierre

**Cuentas.** Cinco ramas, cinco PRs, cinco ítems de cola, cuatro filas del plan (A.0, A.2, A.3, E.1). Una migración nueva. Cero despliegues de Orbit, cero escrituras en Amazon, cero escrituras en la base de producción.

**Presupuesto.** Hasta tres rondas cruzadas por PR según la sección 4 del loop. Con cuatro PRs de trabajo son doce rondas, **más una vuelta extra del carril C**: sus tres candados se agregan después de su aprobación, cuando B ya mergeó, y el loop obliga a volver al paso 5 si el diff no es vacío. Presupuesto de la fase: **hasta quince rondas**, a 100–150 mil tokens cada una. El ítem Q5 lleva una sola ronda. No hay nada que instalar antes de lanzar; las precondiciones son las del paso 0.0.

**Fuera de alcance**, y por qué: las filas **A.1** y **A.7** del plan, que van a una fase siguiente para no pasar del tope de PRs y porque muse va secuencial; **A.5** y **A.6**, que dependen de ellas; **A.4**, **E.2** y **D.1**, que llevan decisión o go literal de David; y **todas las filas de las fases E (salvo E.1), B y M**, que esperan a que cierre la ronda de cinco perspectivas lanzada el 2026-09-16.

**Cómo reporta el lead.** Al cerrar cada carril y la fase, la última línea es `LISTO <sha>` o `ATORADO <razón>`, según la sección 2 del loop. El cierre incluye la revisión completa de la sección 10 contra la DoD literal de las cuatro filas, con mutación de las pruebas nuevas, y solo entonces se abre Q5. El estado final queda en `.saikit/progress/8.json` y en la tarea `AUTO-07` del tracker, con `siguiente_paso` diciendo en lenguaje llano que lo que sigue es de David: la sonda de escritura de A.4 y el acta del percentil de envío de E.2.

**La fuente es este archivo.** Cualquier copia en una página web es eso, una copia, y lo dice en su pie.
