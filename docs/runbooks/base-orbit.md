# Runbook base de Orbit — lo que no cambia entre fases

Esto lo hereda **todo runbook de fase de `gon0801/goncloud-Orbit`** desde la Fase 11. Un runbook de fase lo cita en su primer párrafo («Hereda `docs/runbooks/base-orbit.md`») y **no repite nada de lo que está aquí**: trae solo sus carriles con la DoD verbatim del plan, su tabla de archivos, su cola con compuertas, sus atores propios y su inventario (≤ 120 líneas). Si una fase mide algo nuevo del repo, la corrección entra **aquí**, en el mismo PR que arregla la fase.

Versión 1.1, 2026-09-18 UTC (reglas 3 y 5 ajustadas por la Fase 11), destilada del runbook de la Fase 10 (`autopilot-fase10.md` v5.1, el último completo, que pasó por tres lectores frescos, un verificador y un revisor). Todo lo que dice «medido» se midió en la Fase 8 o en la 10; la fecha y el lugar están en aquel documento.

**Cadena de mando**: `docs/runbooks/loop-autopilot.md` (salvo la tabla de preaprobaciones de cada fase) > `docs/CONTEXTO.md` de Orbit, reglas 1–10 > el spec del módulo > el plan del módulo (`plans/<plan>.md`) > este documento > el runbook de la fase. El plan y el spec mandan en el **qué** y en la DoD; este documento y el de la fase mandan en el **cómo**. Una contradicción entre el plan y un runbook la gana el plan y se declara como residual en el PR; un runbook nunca edita el cuerpo de una fila del plan, solo el ítem de cierre edita celdas de estado.

---

## Quién

| Rol | Quién | Qué hace |
|---|---|---|
| **claw** | el agente `main` del gateway | Lanza al lead con `scripts/lanzar-lead.sh`, lo vigila por tmux y lo relanza si se cae. Hace la limpieza que el lead no puede hacerse a sí mismo al cierre (ver «Cierre»). Si un runbook de fase no está en `main`, lo mergea David desde GitHub o claw lanza una sesión aparte para ese solo merge (ver «Runbook en main»). No mergea PRs de Orbit ni despliega. |
| **lead** | un CLI en tmux de cualquier host del kit (sección 1 del loop), **sesión `fase<N>-lead` con cwd `/Users/dn/dev/wt-fase<N>-lead`** | Escribe los encargos, audita, corre la cruzada, aprueba, mergea por la ruta del kit, escribe progreso y cierra. Implementa solo carriles de lectura que el plan le asigne. No escribe código de producto. |
| **implementador** | **muse**, sesión `muse-goncloud-Orbit`, en el checkout principal `/Users/dn/dev/goncloud-Orbit`, **un encargo a la vez** | Escribe el código en la rama del carril y reporta con la línea de contrato por archivo. No hace push ni abre PR. |
| **revisor cruzado** | otra IA por `cross-review.ps1` | Segunda opinión sobre el SHA del PR. Con muse de implementador va `-Excluir ''` (muse no es candidato). Cuando implementa el lead, se excluye su host con el valor del conjunto cerrado de `cross-review.ps1` (`claude`, `codex`, `grok`, `kimi`, `qwen`, `glm`): `zcode` → `-Excluir glm`; `dsh` no está en el conjunto → `-Excluir ''` y se anota en el PR. |
| **David** | el dueño | Ninguna acción durante la corrida, salvo mergear él mismo un runbook o un PR de docs antes del arranque. Lo que lleva su go literal o su `!` queda fuera de toda fase y se lista al cierre. |

---

## Cómo se lanza cada cosa

**El lead** lo lanza claw con el script, nunca a mano (medido: el hook del kit usa como clave el cwd del **proceso** del CLI, y un `cd` de una herramienta no lo mueve; y un `send-keys` a un TUI que no tomó el teclado se pierde con el sentinel dentro):

```
bash scripts/lanzar-lead.sh -s fase<N>-lead -c /Users/dn/dev/wt-fase<N>-lead \
  -m 'Lee docs/runbooks/autopilot-fase<N>.md en origin/main de goncloud-openclaw y ejecuta la Fase <N> -saikit' \
  -p '<regex del prompt del host>' -- <cli-del-host> <flag-sin-preguntas>
```

Termina en `LISTO fase<N>-lead /Users/dn/dev/wt-fase<N>-lead` o en `ATORADO <razón>` (código 2: la sesión ya existía y hay que `kill-session` antes de relanzar). El CLI, su flag sin preguntas y el regex de su prompt son los del lanzador de claw para ese host; este documento no los repite. Relanzar por muerte o por cwd equivocado es siempre `kill-session` + el mismo comando.

**Muse** ya está vivo: una sesión por repo, parada en el checkout principal (`/opt/homebrew/bin/tmux display-message -p -t muse-goncloud-Orbit '#{pane_current_path}'` → `/Users/dn/dev/goncloud-Orbit`). Antes del primer encargo de una fase, el lead baja el esfuerzo (`/opt/homebrew/bin/tmux send-keys -t muse-goncloud-Orbit '/effort high' Enter`; medido: con `max` la sesión moría a los 180 s) y confirma `high` en la barra. El encargo se entrega como `BRIEF.md` en la raíz del checkout principal y se manda con `/opt/homebrew/bin/tmux send-keys -t muse-goncloud-Orbit -l 'Lee BRIEF.md en la raiz y ejecutalo completo'` y un `Enter` en llamada aparte. **Todo `BRIEF.md` termina así**: «al terminar, imprime tu línea de contrato, `LISTO <sha>` o `ATORADO <razón en una línea>`, **y escríbela, y solo esa, en `.saikit/scratch/<carril>/contrato.txt`** de la raíz del checkout (`mkdir -p` antes); no borres `BRIEF.md`». `<carril>` es `fase<N>-<letra>` (los `A/`, `B/` sueltos ya existen de fases viejas y no se pisan). Muse no se marca con `OPENCLAW_WATCH` (corre en `YOLO`).

**La espera del contrato** es por archivo, con el script (medido: muse imprime con sangría y la pantalla guarda ecos; un `grep` del `capture-pane` no sirve de compuerta):

```
rm -f /Users/dn/dev/goncloud-Orbit/.saikit/scratch/<carril>/contrato.txt   # antes de mandar el encargo
bash scripts/esperar-contrato.sh /Users/dn/dev/goncloud-Orbit/.saikit/scratch/<carril>/contrato.txt -s muse-goncloud-Orbit
```

Devuelve la línea de contrato (código 0), `SIN-CONTRATO VIVA` (3: la pantalla cambió en dos minutos, muse sigue; se vuelve a esperar sin reenviar), `SIN-CONTRATO QUIETA` (4: se confirma `high` en la barra y se reenvía la instrucción **una** vez; si repite, el carril queda `atorado`) o `ATORADO sin reporte: …` (5: el archivo no empieza por `LISTO`/`ATORADO`; se lee la pantalla y se trata como QUIETA). El tope es de tres horas por encargo. Al leer el contrato, el lead borra el `BRIEF*.md` del checkout principal.

---

## Dónde vive cada cosa

| Repo | Ruta local | Default | Copia desplegada |
|---|---|---|---|
| `gon0801/goncloud-Orbit` | `/Users/dn/dev/goncloud-Orbit` (checkout de muse) y `/Users/dn/dev/wt-fase<N>-lead` (worktree del lead, uno por fase) | `master` | `/mnt/data/appdata/orbit` en el host `goncloud` — **fuera de alcance de toda fase**: `merge_despliega` es `no` y el deploy es de David |
| `gon0801/goncloud-openclaw` | `/Users/dn/dev/goncloud-openclaw` | `main` | el gateway, por sync — mergear ahí **es** desplegar (sección 7 del loop) |

El kit de merge: `/Users/dn/dev/summonaikit-claude/tools/`; su estado por sesión, en `~/.claude/hooks/state/<host>/<cksum del cwd>/`. El Postgres de pruebas es el de Homebrew en `localhost:5432` (no hay Docker en la Mac), con el DSN `postgresql://orbit:orbit@localhost:5432/postgres`, idéntico al de CI, **local y desechable**: no sale de esta máquina.

---

## Precondiciones comunes (paso 0.0 de toda fase)

Las corre el lead antes de nada; la fase agrega las suyas después.

```
test -r /Users/dn/dev/summonaikit-claude/tools/MANIFEST.sha256 || echo ATORADO kit ausente
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit fetch -q origin
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit show origin/master:.saikit/autopilot.json
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit status --porcelain | head -5
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit ls-tree --name-only origin/master migrations/ | sort | tail -1
/opt/homebrew/bin/pg_isready -h localhost -p 5432
/opt/homebrew/bin/psql "postgresql://orbit:orbit@localhost:5432/postgres" -Atc "select 1"
/opt/homebrew/bin/tmux display-message -p -t muse-goncloud-Orbit '#{pane_current_path}'
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit worktree list | grep -c wt-fase<N>-lead
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw fetch -q origin; /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw show origin/main:docs/runbooks/autopilot-fase<N>.md 2>/dev/null | head -1
[ -n "${TMUX_PANE:-}" ] && /opt/homebrew/bin/tmux display-message -p -t "$TMUX_PANE" '#S #{pane_current_path}'
```

Esperado, en orden: sin salida; sin salida; `{"merge":true,"merge_despliega":"no","salud_url":null,"revert_si_rojo":true,"rama":"master","sin_verify_app":false,"telegram":false}`; **sin salida** (principal limpio); la última migración de `master` (la fase dice cuál espera); `accepting connections`; `1`; `/Users/dn/dev/goncloud-Orbit`; `1`; el título del runbook de la fase; `fase<N>-lead /Users/dn/dev/wt-fase<N>-lead`.

**Detienen la fase**: kit ausente; `autopilot.json` ausente; el lead fuera de tmux (`ATORADO lead fuera de tmux`) o con otra sesión u otro cwd (`ATORADO lead lanzado fuera de wt-fase<N>-lead`: no se corrige con `cd` ni con `rename-session`; claw relanza). **Runbook fuera de `main`**: `ATORADO runbook fuera de main`; ver «Runbook en main». **Worktree del lead ausente**: el lead lo crea (`worktree add /Users/dn/dev/wt-fase<N>-lead -b fase<N>/<rama del primer ítem del lead> origin/master` y `ln -s /Users/dn/dev/goncloud-Orbit/.venv /Users/dn/dev/wt-fase<N>-lead/.venv`) y **después** reporta `ATORADO lead sin cwd` para que claw relance: su proceso nació con un cwd que no existía. **No detiene la fase, solo a muse**: un checkout principal sucio (fila de atores).

**Runbook en main.** Un runbook de fase se mergea a `main` de openclaw antes de lanzar la fase, con la ventana segura de la sección 7 del loop (`~/.openclaw/bin/openclaw cron list` sin `Next` en 15 minutos; `TZ=America/New_York date` fuera de :05–:15 de las horas impares). **La sesión del lead no puede hacerlo** (su cwd es el worktree de Orbit y la clave del hook es ese cwd). Lo mergea David desde GitHub, o claw lanza con `lanzar-lead.sh` una sesión `fase<N>-runbook` con `-c <worktree de openclaw de esa rama>` y el mensaje «Lee docs/runbooks/autopilot-fase<N>.md de este arbol y ejecuta solo el merge de su PR por la ruta del kit; al terminar escribe LISTO <merge_commit> en /tmp/fase<N>-runbook.contrato -saikit», y espera ese archivo con `esperar-contrato.sh`. Canary: la línea del título en el 0.0. Reversa: rama `docs/runbook-fase<N>-revert` desde `origin/main` con `git revert --no-edit <merge_commit>`, push, PR, y el script de merge del kit con `--revert-de <merge_commit> --confirmado` desde ese árbol. La ronda cruzada de un PR de runbook va con `-Excluir <host del autor>`. Después del `LISTO`, claw desmarca y mata `fase<N>-runbook` y borra su worktree y su rama local; la sesión nunca borra su propio cwd.

---

## Reglas de trabajo permanentes

1. **La rama de muse vive en el checkout principal hasta el `APPROVE lead`.** Antes de cada encargo, con el principal limpio: `/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit fetch -q origin && /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit checkout -b fase<N>/<rama> origin/master`. Si `status --porcelain` imprime algo, **no se cambia de rama** (fila de atores). Al contrato `LISTO`, el lead empuja sin mover la rama de árbol (`/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit push -u origin fase<N>/<rama>`), abre el PR con `/opt/homebrew/bin/gh pr create --repo gon0801/goncloud-Orbit --head fase<N>/<rama> --base master --draft --title '<título>' --body-file <archivo>` (con `--head` explícito: el cwd del lead está en otra rama), y corre las rondas cruzadas con cwd en el principal (`cd /Users/dn/dev/goncloud-Orbit && export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH; /Users/dn/.local/bin/pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto -Excluir '' -Alcance last-commit`; un `cd` sirve aquí porque la cruzada no usa el hook del kit). Cada corrección es un `BRIEF-r<K>.md` a muse en ese mismo checkout y rama, con su `contrato.txt`. **Solo con el `APPROVE lead <sha>` puesto** la rama pasa al worktree del lead para la compuerta y el merge: `/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit checkout --detach` y `/opt/homebrew/bin/git -C /Users/dn/dev/wt-fase<N>-lead checkout fase<N>/<rama>`. Muse no recibe el siguiente encargo antes de ese `APPROVE`. Una corrección **antes del merge** con la rama ya en el worktree hace el camino inverso (`checkout --detach` en el worktree, `checkout` en el principal limpio) y vuelve con `APPROVE` nuevo; un hallazgo de la revisión de cierre (§10) va a una rama nueva `fase<N>/<carril>-cierre-r<K>` (ítem «bis» de la cola de la fase).

2. **El worktree del lead es uno por fase, muchas ramas, una ruta de proyecto**: `/Users/dn/dev/wt-fase<N>-lead`, con `.venv` enlazado al del principal (sin el enlace el primer `git push` muere con «failed to push some refs»: el candado `pytest-pre-push` busca `./.venv/bin/python`). Antes de cada `checkout` en ese worktree, `git status --porcelain` tiene que salir vacío: el trabajo del lead se commitea en su rama antes de traer otra.

3. **Las pruebas de base corren de verdad, no se saltan**: todo `pytest` lleva `ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres"`, corre con el directorio de trabajo en el árbol del carril con `./.venv/bin/python -m pytest <archivos> -q -p no:cacheprovider`; una **re-mutación** lleva además `PYTHONPYCACHEPREFIX=$(mktemp -d)` delante (medido: `-p no:cacheprovider` solo apaga la caché de pytest, no `__pycache__`, y un `.pyc` viejo dio muertes falsas), y el reporte pega la última línea con el conteo de `passed` y de `skipped`. **`skipped` en pruebas de base = el carril no terminó.** Antes de auditar, el lead confirma `pg_isready`.

4. **Migraciones**: solo el carril que el plan designe crea una; el número es el máximo más uno de `origin/master`, releído con `fetch` al abrir el PR y otra vez en la compuerta (`git diff --name-only --diff-filter=A origin/master...HEAD -- migrations/` contra `ls-tree origin/master migrations/`: `COLISION` renumera en el mismo PR). Una fase que no crea migraciones lo dice, y su compuerta común exige `git diff --name-only origin/master...HEAD -- migrations/ | head -1` sin salida.

5. **Un candado que no puede salir rojo no cuenta**: cada candado nuevo llega con su fuga sembrada en `tmp_path` demostrando el rojo. El candado de pureza de `app/precio/` mide con `rglob` y **solo admite excepciones por nombre de archivo, las que la fila del plan nombre para ese carril, cada una con candado propio**; exceptuar la carpeta, quitar el `rglob` o mover los módulos puros devuelve el carril al paso 1 del loop.

6. **Producción se lee, nunca se escribe, y solo el lead**, con las consultas versionadas en `docs/evidencia/<plan>/<fila>/consultas/*.sql` y este camino (medido: sin el `test -n`, un `printenv` vacío deja a libpq conectarse a otra base; sin `BEGIN READ ONLY`, una escritura colada corre contra producción):

   ```
   { echo 'BEGIN READ ONLY;'; cat docs/evidencia/<plan>/<fila>/consultas/<archivo>.sql; } \
     | ssh goncloud 'set -eu
         DSN=$(docker exec orbit-app-1 printenv ORBIT_DSN_READ)
         test -n "$DSN" || { echo "ATORADO: ORBIT_DSN_READ vacio"; exit 1; }
         docker exec -i orbit-db-1 psql "$DSN" -X -P pager=off -tA -v ON_ERROR_STOP=1'
   ```

   Si el host del lead niega `ssh goncloud` (medido con el host `claude`), no se rodea con un subagente: la salida queda `unknown` con el comando al lado y la fase sigue. El código de una rama no está desplegado (`merge_despliega` es `no`): un readback en producción corre las consultas del módulo por este camino y alimenta la función pura en local, con los valores de config que producción no tenga todavía pasados explícitos y declarados.

7. **Herramientas con ceremonia**: dry-run por omisión de `--acepto-mutacion-real` (no existe flag `--dry-run` en las herramientas del motor); escribir es `--acepto-mutacion-real --huella <huella>` más `--go <literal>` donde el plan pida go. Ninguna herramienta corre contra el DSN del contenedor en una fase; la base local con nombre para reproducir a mano es `orbit_fase<N>_manual` (`createdb -h localhost -U orbit` y las migraciones que la fase liste, en orden, con `psql -v ON_ERROR_STOP=1 -q -f`), y **se deja** (un `DROP DATABASE` es una pregunta del vigilante).

8. **El progreso se escribe y el tablero lo recibe sin leer `cfg.fases`** (medido en `origin/main` sobre `tablero-runbook/index.ts`. `manejarSet` persiste cualquier `fase` que pase `validarFase` y no lee `cfg.fases`. `faseDeUrl`, `servirTablero`, `servirJson` y `runbook.progress.get` validan `fase` y leen `stateDir`. `cfg.fases` entra solo en `renderTablero` para la barra de navegación, y 12.2 la descubre del disco). En cada cambio de estado de un carril o de la cola, y al cierre, el lead escribe `/Users/dn/dev/goncloud-Orbit/.saikit/progress/<N>.json` (`runbook-progress.v1`, `atencion_requerida` como objeto, `siguiente_paso` ≤ 160 caracteres, `paso_loop` saturado en 8), hace un intento que no bloquea (`/opt/homebrew/bin/timeout 60 ~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat …)" --json | head -c 200`) y pega el JSON como comentario en el PR abierto del carril activo (`/opt/homebrew/bin/gh pr comment <pr> --repo gon0801/goncloud-Orbit --body-file …`). El archivo no se commitea (`.saikit/` está en el `.gitignore`); **lo verificable son los PRs, sus `APPROVE lead <sha>` y el último comentario de progreso**.

9. **Se reporta, no se relaya**: al cerrar cada carril y la fase, la última línea es `LISTO <sha>` o `ATORADO <razón>` (sección 2 del loop). `autopilot.json` de Orbit trae `telegram: false`: la línea «CodeRabbit sin cuota» y similares van al cuerpo del PR y al progreso.

10. **Nada despliega Orbit**: mergear a `master` no lleva código al servidor. La sección 7 del loop aplica solo a los merges en openclaw.

11. **El candado léxico del kit deniega por el nombre**: el basename del script de merge solo puede aparecer en un comando como ruta absoluta resoluble; nada de `echo`, banners, cuerpos de PR ni variables en la misma línea. El mensaje dice «merge denied» aunque el comando no mergee.

12. **Un turno de merge** (medido: el hook solo anota evidencia en un turno cuyo mensaje trae el literal `-saikit`; cualquier prompt sin la marca lo borra, incluido el reporte de regreso de un subagente; las `<task-notification>` no): todo merge de Orbit sale de `/Users/dn/dev/wt-fase<N>-lead` con la rama del ítem traída ahí (regla 1). En orden y sin lanzar ningún otro subagente hasta terminar: el Drive (`verify/` con el `.venv` del repo), el blast del kit (`saikit-blast.sh --write`), el rastro de decisiones, **un solo** revisor de larga vida que escribe `.saikit/veredictos/<sha>.json` y espera archivos-marca en bucles de ≤ 8 minutos, el lead sondeando `harness-state.env` hasta que `veredicto_sha256` iguale el `shasum -a 256` del archivo, y los tres comandos de la sección 6 del loop. El `--dry-run` pasa cuando imprime `DRY-RUN: gate en verde` y sale 0 (no imprime `LISTO`; desviación de la sección 6, declarada). El revisor se libera **después** del postmerge. Detalle de cada comando: `/Users/dn/dev/summonaikit-claude/README.md`.

13. **Re-APPROVE tras un merge de base** (sección 3 paso 9): se guarda `git diff origin/master...HEAD` antes del merge de base y se compara con el mismo diff después; idéntico → `APPROVE lead <sha nuevo>` sin ronda; distinto → ronda. Un commit del lead que solo agrega evidencia bajo `docs/evidencia/<plan>/<fila>/` se re-marca sin ronda si `git diff <sha aprobado> HEAD --name-only` no lista otra cosa.

14. **Rondas cruzadas por la sección 4 del loop, sin desviación**: solo un bloqueante con reproducción abre ronda, cada ronda siguiente revisa solo los arreglos (`-Desde <sha que vio la ronda anterior>`), se repite hasta la primera ronda sin bloqueantes, y un bloqueante nunca va al plan ni se promueve abierto. Solo el `APPROVE lead <sha>` mete el PR a la cola. Los PRs de docs (plan, cierre) llevan CI verde + una ronda + `APPROVE`, sin CodeRabbit obligatorio. (La regla del 2026-09-15, «sin tope, se repite mientras la ronda anterior haya encontrado algo», se reemplazó el 2026-09-18: volvía la revisión una cadena sin fin.)

---

## Compuertas comunes y cola

**El número de PR** se obtiene con `pr=$(/opt/homebrew/bin/gh pr list --repo gon0801/goncloud-Orbit --head fase<N>/<rama> --state all --json number --jq '.[0].number')` (`--state all`: sin él un ítem mergeado desaparece). **El SHA de squash** de un ítem mergeado: `/opt/homebrew/bin/gh pr view $pr --repo gon0801/goncloud-Orbit --json mergeCommit --jq .mergeCommit.oid`.

**En toda compuerta**, además de lo propio del ítem: `cd /Users/dn/dev/wt-fase<N>-lead && /opt/homebrew/bin/git rev-parse --abbrev-ref HEAD` → la rama del ítem; `/opt/homebrew/bin/gh pr checks $pr --repo gon0801/goncloud-Orbit | head -3` → `quality` en `pass`; `ls /Users/dn/dev/goncloud-Orbit/BRIEF*.md 2>/dev/null && echo SUCIO || echo LIMPIO` → `LIMPIO`; `/opt/homebrew/bin/git diff --name-only origin/master...HEAD -- migrations/ | head -1` → sin salida si la fase no crea migraciones; y **mientras la forma del parche de precio siga sin sellar** (fila A.4 del plan de repricing), `/opt/homebrew/bin/git grep -h -cE '^FORMA_PARCHE = "pendiente_sonda"' -- app/spapi/precio_write.py` → exactamente `1` (salida vacía = un carril selló la forma: paso 1 del loop). El diff de nombres de cada ítem se filtra contra su fila de la tabla de archivos y tiene que quedar **sin salida**; una ruta intrusa se saca con un commit propio.

**El ítem de cierre** marca `cc:完了` las celdas de estado con su SHA de squash y salvedades, deja `cc:TODO — blocked: <razón>` en las filas que no cerraron, y actualiza `docs/CHAT-CONTEXT.md` (el CI lo exige cuando aparecen `cc:完了` nuevos); su compuerta cuenta una línea `+` por celda con `grep -cE "^\+\| <fila> \|.*cc:(完了|TODO)"` y corre `tools/check_chat_context_fresh.py origin/master`.

---

## Cierre: qué hace el lead y qué hace claw

Después del postmerge del kit en el ítem de cierre, el lead, **con cwd en el checkout principal**, comprueba que está limpio, lo suelta en `origin/master` (`checkout --detach origin/master`), borra las ramas locales de la fase que ya mergearon (todas menos la del ítem de cierre, que es la del propio worktree: `branch -D fase<N>/… $(git for-each-ref --format='%(refname:short)' 'refs/heads/fase<N>/*-cierre-r*')`), hace `fetch --prune`, y corre el script de cierre leído de `origin/main` porque el checkout de openclaw suele estar en otra rama:

```
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw show origin/main:scripts/cierre-de-fase.sh | REPO=/Users/dn/dev/goncloud-Orbit REF=origin/master bash -s <N>
```

Imprime siete líneas de comprobación (`plan`, `ramas`, `worktrees`, `sesiones`, `despliegue`, `tablero`, `ci`), una en blanco y un veredicto final `ROJO: …` con salida 1. **Desviación de las secciones 2 y 10 del loop, declarada para todas las fases de Orbit**: `plan` sale `ROJO` porque Orbit no tiene `Plans.md` (lo sustituye el conteo por celda del ítem de cierre), y el lead escribe su `LISTO <sha>` con `ramas`, `worktrees` y `sesiones` en `ROJO` **solo si nombran exactamente** `fase<N>/cierre`, `/Users/dn/dev/wt-fase<N>-lead` y `fase<N>-lead` (lo suyo, que no puede borrar: es su cwd y su sesión), y con `despliegue`, `tablero` y `ci` en `VERDE` (`ci` en `in_progress` es la corrida del squash: se espera 5 minutos y se repite, hasta 3 veces). Antes del `LISTO` va una línea `CIERRE PENDIENTE DE CLAW: worktree wt-fase<N>-lead, rama fase<N>/cierre, sesion fase<N>-lead`. **Claw**, después del `LISTO` y sin kit: `tmux set-environment -u -t fase<N>-lead OPENCLAW_WATCH`, `tmux kill-session -t fase<N>-lead`, `git -C /Users/dn/dev/goncloud-Orbit worktree remove /Users/dn/dev/wt-fase<N>-lead`, `git -C /Users/dn/dev/goncloud-Orbit branch -D fase<N>/cierre`, y el script otra vez hasta que esas tres líneas salgan `VERDE`. Nada que el script nombre y no sea de la fase se toca.

---

## Cuando algo se atora (universales de Orbit)

Las universales del loop están en su sección 12 y no se repiten. Estas son las de Orbit; una fase agrega solo las suyas.

| Situación | Qué hace el lead |
|---|---|
| El kit no está en `/Users/dn/dev/summonaikit-claude/tools` | `ATORADO kit ausente …` y la fase para. No se busca el script ni se mergea por otra vía. |
| `.saikit/autopilot.json` no está en `origin/master` | `ATORADO bootstrap ausente`, la fase para, `atencion_requerida.necesaria = true`. |
| La ruta del kit rechaza por sello, estado del hook o lock | Una vez: se confirma el cwd del proceso (`tmux display-message -p -t "$TMUX_PANE" '#{pane_current_path}'` = el worktree del lead), se pide a claw un turno con el literal `-saikit` y se repite sello + merge en ese turno. Si sigue: el PR queda abierto con su `APPROVE lead <sha>` y la razón, y va al progreso. |
| Un comando es denegado por nombrar el script del kit | Candado léxico (regla 11): se reescribe con la ruta absoluta sola. |
| El checkout principal está sucio al arrancar un encargo o al limpiar | No se cambia de rama y no se borra nada; muse espera, los carriles del lead siguen; `siguiente_paso` nombra el archivo; a la segunda espera, `atorado`. |
| `esperar-contrato.sh` sale con 3 (VIVA) | Se anota en `eventos` y se vuelve a esperar; nunca se reenvía a una sesión viva. |
| `esperar-contrato.sh` sale con 4 (QUIETA), 5 (sin reporte) o la pantalla muestra `model stream idle timeout` | Se confirma `high` en la barra (si dice `max`, `/effort high`) y se reenvía la instrucción una vez con otra espera; si repite, el carril queda `atorado` con `detenido_por` = «muse sin respuesta». |
| PostgreSQL local caído | `/opt/homebrew/bin/brew services start postgresql@16`, 30 s, un reintento; si sigue, los carriles de código quedan `atorado` y los de lectura siguen. |
| Las pruebas de base salen `skipped` | El carril no terminó: encargo de corrección con el DSN de la regla 3. |
| `origin/master` avanzó | Merge de la base (no rebase, no push con fuerza), CI, compuerta otra vez, re-APPROVE por la regla 13. |
| Un carril agrega una migración que la fase no previó, relaja el candado de pureza, o sella la forma del parche | Paso 1 del loop con encargo de corrección (reglas 4 y 5; la forma del parche es de A.4, de David). |
| Un carril necesita `tests/test_architecture.py` y el anterior no ha mergeado | Trabaja en todo lo demás y deja ese archivo para el final; merge de `origin/master` antes de su compuerta. |
| `ssh goncloud` no responde o el host lo niega | `unknown` con la consulta al lado; no se rodea con un subagente. |
| La skill `appflowy-ehv-task` (tracker) es negada por el host | El comando literal va al cuerpo del PR de cierre y a `siguiente_paso`; David lo corre con `!`. |
| `runbook.progress.set` contesta `ok: false` | Esperado (regla 8): el comentario en el PR es la fuente. |
| Se necesita un cuarto PR abierto en Orbit | No se abre; se cierra uno antes. |
| Reanudación: el lead murió | Claw relanza con `lanzar-lead.sh` (tras `kill-session`) y el nuevo lead corre el 0.0 entero. El estado está en el último comentario de progreso (`gh pr list --repo gon0801/goncloud-Orbit --search "head:fase<N>/" --state all --json number,headRefName,state`) y en `.saikit/progress/<N>.json` si el host es el mismo. Un `BRIEF*.md` en el principal es un encargo en vuelo: se espera con `esperar-contrato.sh`. Antes de cualquier compuerta se mira dónde está la rama del ítem (`rev-parse --abbrev-ref HEAD` en los dos árboles): sin `APPROVE` está en el principal; con `APPROVE` se trae al worktree (regla 1). Un PR con `APPROVE lead <sha>` sin merge se retoma en la compuerta. |

---

## Qué trae un runbook de fase (y nada más)

1. Primer párrafo: qué construye la fase, qué **no** hace, y «Hereda `docs/runbooks/base-orbit.md` v<K>». 2. Su tabla de **preaprobaciones** (aprobado y negado). 3. Su **prohibido**. 4. **Carriles**: por carril, rama `fase<N>/<nombre>`, la fila del plan con la DoD verbatim más lo que la fase agrega, y «lo que un usuario vería si funcionó»; y el diagrama de orden. 5. **Archivos por carril** (puede tocar / no toca). 6. **Cola**: ítems en orden con su compuerta propia (lo común está aquí) y su fallback. 7. **Atores propios** (solo los que no están arriba). 8. **Inventario**: cuentas, presupuesto, fuera de alcance, «lo que queda listo para David». Tope: **120 líneas**. Verificación: un lector fresco que ejecuta y un revisor del diff; otra pasada solo mientras salga un bloqueante; lo no bloqueante que no se corrige va a una fila del plan (receta `autopilot-runbook`).

**La fuente es este archivo.** Cualquier copia en una página web es eso, una copia, y lo dice en su pie.
