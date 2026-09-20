# Autopilot de la Fase 13 — ocho escritores automáticos que no le hablan a nadie

Esto lo ejecutas tú, el lead, en autopilot; David no está y no se le pregunta nada. Hereda `docs/runbooks/base-openclaw.md` v1.0 (roles, lanzamiento, dónde vive cada cosa, precondiciones, reglas, compuertas, ventana segura y atores universales) y cita `docs/runbooks/loop-autopilot.md` por número de sección (ver Loop). Plan: filas 13.1 a 13.7 de `Plans.md` en `origin/main`; sus filas mandan en la DoD y este documento manda en el método. La fase deja el aviso donde los ocho relojes no se pueden tocar: el sync escribe líneas `SKILLS` (13.2a), el vigía `verif-sync-repos` las vuelve un Telegram con CASO D (13.2b), los textos que sostienen candados van marcados (13.1), la skill `verify` deja de mentir con un candado de comportamiento (13.3, 13.4), el aplicador deja de ser una mina con convención de dos copias (13.5) y el contrato de `ingenieria` dice lo que el código hace (13.6). No edita ni apaga ninguno de los ocho `skill-collection-review-*` (son del sistema y el gateway revierte el edit solo), no toca `config`, no da de alta relojes (los dos one-shot de Q2 se crean y se borran ahí mismo), no crea tokens, ningún repo lee al otro y no hay `ssh` a ningún lado. Versión 1.0, 2026-09-19 UTC.

**Cómo se lanza (slot 13 de la receta).** El dueño dice «claw, empieza la Fase 13» y claw corre `bash scripts/lanzar-fase.sh 13 -- <cli> <flag-sin-preguntas>` con el CLI y el flag del host que elija; el script encuentra esta rama (Q0 pendiente), crea `/Users/dn/dev/wt-f13-lead` y termina en `LISTO fase13-lead /Users/dn/dev/wt-f13-lead` o `ATORADO <razón>`. **Pantalla:** `/runbook/tablero/c/fase13-candados` desde el primer comando (la ruta vieja `/runbook/tablero/13` sirve el mismo documento).

**Antes de nada: Q0.** Naces parado en la rama de este PR (`docs/runbook-fase13`: los 3 commits del plan reescrito + este runbook, nada más), porque la DoD que obedeces vive ahí todavía. Tu primer trabajo es mergear Q0 en ventana segura; después `git fetch origin && git checkout --detach origin/main` y sigues. Si Q0 ya está mergeado cuando claw lanza, naces detached en `origin/main` y saltas a Q1. Si este archivo no estuviera en tu worktree, `bash scripts/runbook.sh 13` dice dónde está; la tabla de abajo ES la autorización: lo que no está en ella se rechaza, nunca se pregunta.

**Nacimiento (después del 0.0 del base y de Q0, antes de ningún carril).** Primero, si tu sesión se llama `fase13-lead`, renómbrate a `<cli>-wt-f13-lead` (`/opt/homebrew/bin/tmux rename-session -t fase13-lead <cli>-wt-f13-lead`, con tu token de CLI): el lanzador la nombra sin `wt-` y `arranque-de-fase.sh` la busca con `wt-f13-` (solo el nombre; si el cwd está mal, ningún rename lo arregla: claw relanza, base). El 0.0 suma tres comprobaciones: `~/.openclaw/bin/openclaw cron get 2d763be5-6390-4ccf-a3a4-621c91c41e94 --json` responde (si el vigía no existe, M queda atorado y lo demás sigue); `git -C /Users/dn/dev/goncloud-workspace-ingenieria rev-parse --verify origin/master` resuelve (si no, A queda atorado y lo demás sigue); `/Users/dn/.local/bin/pwsh --version` responde (13.2 lo exige hasta en CI). Primer comando de la fase, con `<host>` = tu token de CLI (`glm`, `muse`, `cursor-agent`: NO un agentId ni el nombre de sesión), los dos `<ISO>` (`date -u +%Y-%m-%dT%H:%M:%SZ`), el `<sha>` de Q0 y su `prs` completado (`[{"repo":"gon0801/goncloud-openclaw","pr":<n>}]`); después escribe `.saikit/progress/13-sesiones.txt` con `lead - <tu sesión ya renombrada>` y repite `bash scripts/arranque-de-fase.sh 13`: todo VERDE salvo `vigilantes` cierra Q0.

```
cat > .saikit/progress/13.json <<'JSON'
{"schema":"runbook-progress.v1","runbook":"docs/runbooks/autopilot-fase13.md","fase":"13","corrida":"fase13-candados","proyecto":"openclaw","titulo":"Autopilot de la Fase 13 (que el sync avise)","plan":{"repo":"gon0801/goncloud-openclaw","ruta":"Plans.md","seccion":"Fase 13"},"lead":{"agente":"<host>","inicio":"<ISO>","actualizado":"<ISO>"},"atencion_requerida":{"necesaria":false,"motivo":null,"desde":null},"siguiente_paso":"Q0 mergeado; arrancan R, M y A, luego V.","carriles":[{"id":"R","nombre":"Marcas","repo":"gon0801/goncloud-openclaw","rama":"fase13/marcas","tareas":["13.1"],"estado":"pendiente","paso_loop":0,"pr":null,"head":null,"approve_lead":null,"ci":"pendiente","coderabbit":"pendiente","residuales":[],"detenido_por":null},{"id":"V","nombre":"Verify","repo":"gon0801/goncloud-openclaw","rama":"fase13/verify","tareas":["13.3","13.4"],"estado":"pendiente","paso_loop":0,"pr":null,"head":null,"approve_lead":null,"ci":"pendiente","coderabbit":"pendiente","residuales":[],"detenido_por":null},{"id":"M","nombre":"Vigia","repo":"gon0801/goncloud-openclaw","rama":"fase13/vigia","tareas":["13.5","13.2"],"estado":"pendiente","paso_loop":0,"pr":null,"head":null,"approve_lead":null,"ci":"pendiente","coderabbit":"pendiente","residuales":[],"detenido_por":null},{"id":"A","nombre":"Contrato ingenieria","repo":"gon0801/goncloud-workspace-ingenieria","rama":"fase13/contrato","tareas":["13.6"],"estado":"pendiente","paso_loop":0,"pr":null,"head":null,"approve_lead":null,"ci":"pendiente","coderabbit":"pendiente","residuales":[],"detenido_por":null}],"cola":[{"id":"Q0","prs":[],"estado":"verificado","ventana":null,"merge_commits":["<sha>"],"verificado":"ok","detenido_por":null,"avance":100},{"id":"Q1","prs":[],"estado":"pendiente","ventana":null,"merge_commits":[],"verificado":null,"detenido_por":null,"avance":0},{"id":"Q2","prs":[],"estado":"pendiente","ventana":null,"merge_commits":[],"verificado":null,"detenido_por":null,"avance":0},{"id":"Q3","prs":[],"estado":"pendiente","ventana":null,"merge_commits":[],"verificado":null,"detenido_por":null,"avance":0},{"id":"Q4","prs":[],"estado":"pendiente","ventana":null,"merge_commits":[],"verificado":null,"detenido_por":null,"avance":0},{"id":"Q5","prs":[],"estado":"pendiente","ventana":null,"merge_commits":[],"verificado":null,"detenido_por":null,"avance":0}],"eventos":[],"cierre":{"at":null,"telegram_message_id":null,"resumen":null}}
JSON
~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat .saikit/progress/13.json)" --timeout 30000
```

## Preaprobaciones del dueño

| Operación | Alcance | Decisión |
|---|---|---|
| Crear worktrees y ramas `fase13/*` | `/Users/dn/dev/wt-f13-*` en openclaw; `/Users/dn/dev/wt-f13-A` vía `git -C /Users/dn/dev/goncloud-workspace-ingenieria` | Aprobado |
| Lanzar implementadores en tmux con su flag sin preguntas | los cuatro carriles | Aprobado |
| `gh pr create`, `gh pr comment`, `gh pr ready`, `gh api` de lectura | `gon0801/goncloud-openclaw` y `gon0801/goncloud-workspace-ingenieria` | Aprobado |
| Revisión cruzada por `cross-review.ps1` | cualquier revisor del conjunto | Aprobado |
| Mergear por la ruta del kit, en ventana segura | los ítems de la cola, incluido el de ingenieria | Aprobado |
| `runbook.progress.set` y `runbook.progress.get` | la corrida `fase13-candados` y lecturas de cualquier otra | Aprobado |
| `cron edit --message` + `.pre.json`/`.post.json` en `docs/cron-messages/backup/` | solo el vigía `2d763be5-…`; horario, agente, tools y habilitación intactos | Aprobado |
| Copias one-shot `--tools exec` y su `cron rm` | solo las dos de prueba del CASO D, que no pueden avisar por construcción | Aprobado |
| Escribir el log de prueba por exec en el gateway | solo `C:\Users\ehven\.openclaw-state\vigia-sync-prueba\sync-repos.log` | Aprobado |
| `cron list|get|runs` de solo lectura | cualquier cron | Aprobado |
| Tocar `scripts/sync-repos.ps1` | solo la función entre `# >>> skills-cambiadas` y `# <<< skills-cambiadas` y su llamado en `try/catch` | Aprobado |
| Borrar ramas y worktrees del plan al cierre | `docs/plan-fase13-candados-contratos`, `docs/fase13-aviso-del-sync`, `/Users/dn/dev/wt-f13-docs`, `/Users/dn/dev/wt-f13-aviso` | Aprobado |
| Un Telegram de cierre a David | forma `CERRADA` de `docs/spec/seguimiento.v1.md`, `--silent`, una sola vez | Aprobado |
| `cron edit|add|rm` sobre los ocho `skill-collection-review-*` | cualquiera | **Negado** — son del sistema; el gateway revierte el edit solo |
| `config patch` en el gateway | cualquier clave, incluida `skills.workshop.autonomous.mode` | **Negado** |
| Altas de crons (`corrida-vigia-13`, `corrida-empuje-13`) | cualquiera | **Negado** — el plan no trae reloj nuevo y el cierre es un solo Telegram |
| Tokens nuevos o lecturas entre repos | cualquiera | **Negado** — 13.6 lo prohíbe con fecha del dueño |
| `ssh` a cualquier lado, leer secretos | cualquiera | **Negado** |

## Prohibido

Preguntarle algo a David antes del cierre, salvo la única fila que lo permite (base, «la reversa que no entra»). Usar `--no-verify`. Mergear por cualquier ruta que no sea la del kit. Editar, apagar o borrar cualquiera de los ocho crons del sistema. Cambiar configuración del gateway. Dar de alta crons fuera de los dos one-shot de prueba. Tocar `scripts/sync-repos.ps1` fuera de las marcas. Mandar a David otro Telegram que no sea el de cierre. Leer o pegar secretos, tokens o lanzadores de `~/bin`.

## Loop

Cada tarea corre loop §3 entero (encargo en archivo, TDD con rojo pegado, auditoría del lead con mutación propia, PR draft, §4 con revisor rotado y `-Excluir` del implementador, promoción, CodeRabbit leído, `APPROVE lead <sha>`, merge §6 con base al día por merge, §8 en cada cambio); PRs por §5, merges por §6 en la ventana segura del base, reanudación por §9 y base, revisión de cierre por §10. En M y V, que traen dos commits por PR, cada commit se revisa parado en él (`git worktree add --detach /Users/dn/dev/wt-f13-rev <sha>`, cruzada desde ahí, `git worktree remove /Users/dn/dev/wt-f13-rev` al terminar; mecanismo de la regla 3 de `autopilot-fase9.md`): `-Alcance last-commit` solo ve el head y el primer commit quedaría sin cruzada. Tres desviaciones declaradas: (a) `arranque-de-fase.sh 13` queda ROJO solo en `vigilantes`, por diseño (Negado arriba; sin parte cada hora, el seguimiento es solo §8 en cada cambio); (b) V arranca cuando R mergea (Depends 13.1 de la fila 13.3; los dos tocan `docs/agent-skills/verify/**`); (c) la ventana segura se lee sin contar `corrida-vigia-9` ni `corrida-empuje-9` (Fase 9, todavía viva): solo miran y avisan, y el empuje cada 15 min impediría cualquier ventana.

## Carriles

**Rama base: `origin/main` fresco con Q0 dentro**, para R, M y A, que arrancan en paralelo (archivos disjuntos; worktrees `/Users/dn/dev/wt-f13-R|M|A`, sesiones `<token>-wt-f13-<carril>`). V arranca cuando R mergea (la prosa del plan dice que los cuatro arrancan en paralelo, pero la columna Depends de 13.3 dice 13.1 y manda Depends); su rama nace de `origin/main` con R dentro. M hace 13.5 primero y 13.2 después, dos commits de un PR. La DoD de cada tarea es su celda en `Plans.md`, verbatim.

| Carril | Rama | Tareas | Quién |
|---|---|---|---|
| **R · Marcas** | `fase13/marcas` | 13.1 | `glm`, si no `cursor-agent`, si no `muse` |
| **M · Vigía** | `fase13/vigia` | 13.5, 13.2 | `cursor-agent`, si no `glm`, si no `muse` |
| **A · Contrato** | `fase13/contrato` en ingenieria (`master`): `git -C /Users/dn/dev/goncloud-workspace-ingenieria worktree add /Users/dn/dev/wt-f13-A -b fase13/contrato origin/master` | 13.6 | `muse`, si no `cursor-agent`, si no `glm` |
| **V · Verify** | `fase13/verify`, tras Q1 (`/Users/dn/dev/wt-f13-V`) | 13.3, 13.4 | `glm`, si no `muse`, si no `cursor-agent` |

Lo que un usuario vería: R, nada (marcas en el repo); M, un Telegram cuando un agente reorganice sus skills, con archivos y porqué; V, nada (docs y tests); A, nada (una línea de contrato). Esta fase no trae agente `usuario`: 13.7 se cierra con `cierre-de-fase.sh`, sync y Telegram.

## Archivos por carril

| Carril | Puede tocar | No toca |
|---|---|---|
| **R** | `agents/**` y `docs/agent-skills/**` solo marcas `<!-- candado: … -->`, `scripts/tests/test-candados-declarados.sh`, `.saikit/scratch/R/**` | `summa-gate/**`, `Plans.md`, `docs/crons/**`, `docs/cron-messages/**`, `scripts/sync-repos.ps1` |
| **V** | `docs/agent-skills/verify/**`, `scripts/tests/test-skill-verify.sh`, `scripts/tests/test-drive-merge-guard.sh`, `.saikit/scratch/V/**` | `summa-gate/**`, `agents/**`, `Plans.md`, `docs/crons/**` |
| **M** | `docs/crons/**`, `docs/cron-messages/verif-*`, `docs/cron-messages/APLICAR_VIGIA_SYNC.sh`, `docs/cron-messages/backup/2d763be5-*`, `scripts/sync-repos.ps1`, `scripts/tests/test-crons-dos-copias.sh`, `scripts/tests/test-sync-avisa-skills.sh`, `.saikit/scratch/M/**` | `summa-gate/**`, `agents/**`, `docs/agent-skills/**`, `Plans.md` |
| **A** | en ingenieria: `AGENTS.md`, `tests/test-contrato-dispatch.ps1`, `.saikit/scratch/A/**` | todo este repo |
| **cierre** | `Plans.md` (solo celdas Status), `.saikit/progress/13.json`, `docs/evidence/**`, `docs/cron-messages/backup/**` | todo lo demás |

## Cola de merge

Cada ítem pasa la compuerta común del base (CI de su SHA, log solo con commits del carril + merges de regla 5, PR fuera de borrador) y va en ventana segura: mergear aquí **es** desplegar, también en ingenieria (`merge_despliega: publica`). Nunca hay más de tres PRs abiertos: V abre cuando R cierra. Una corrección tras el merge que no sea reversa va en `fase13/seguimiento-<carril>` desde `origin/main` (worktree `/Users/dn/dev/wt-f13-seg-<carril>`), loop reducido (CI + CodeRabbit + `APPROVE`), en ventana segura, antes de Q5, y respeta el tope de tres.

| # | Ítem | Compuerta propia | Fallback |
|---|---|---|---|
| Q0 | Plan reescrito + runbook (`docs/runbook-fase13`) | Loop reducido (CI + CodeRabbit leído + `APPROVE` + kit, sin cruzada: el plan es del dueño y el runbook llega verificado); `git show origin/main:Plans.md \| grep -c 'Que el sync avise'` → `1`, `git cat-file -e origin/main:docs/runbooks/autopilot-fase13.md`, y `bash scripts/arranque-de-fase.sh 13` en VERDE salvo `vigilantes` | Sin Q0 la fase no arranca: sin la DoD nueva no hay qué obedecer |
| Q1 | R · marcas | `bash scripts/tests/test-candados-declarados.sh` y `bash scripts/run-checks.sh` en verde sobre el head, con el rojo primero pegado | Vuelve a loop §3 con el log como encargo |
| Q2 | M · vigía | Los dos tests nuevos en verde; lo corre el implementador de M: `APLICAR_VIGIA_SYNC.sh` sale 0 con `.pre/.post.json` commiteados (`payload.message` idéntico al `.txt`, y `agentId`, `schedule`, `toolsAllow`, `enabled` intactos: el bookkeeping —`configRevision`, `nextRunAtMs`, sellos— cambia con cualquier edit y NO se compara) e imprime el id de cada copia; su modo `--test` (como el §4 del modelo) crea dos jobs distintos, `vigia-sync-prueba-D1` (log con la línea SKILLS: nombra `verifier` y sus archivos) y `vigia-sync-prueba-D2` (log sin ella: callado en D), `--at 30m` forzados con `cron run --wait --wait-timeout 10m`, evidencia `.runs.json` en `.saikit/scratch/M/` y `cron rm` de cada uno al terminar (el log de prueba lo arma el implementador: cola real + la línea del `43097da`); re-lectura fresca desde `wt-f13-M` (`cron get 2d763be5-…`, mismo mensaje que el `.post.json`); tras un ciclo de sync posterior al merge (marca `---- ciclo terminado` con fecha mayor + SHA ancestro, compuerta del sync del base), cola del log (`tail -40` del PASO 1 del vigía) sin `SKILLS error:` | Reversa del vigía con el comando listo en el PR (si falta, se reconstruye del `.pre.json` con el `cron edit` de la ruta probada); si el sync trae `SKILLS error:`, reversa de M por el camino de emergencia del base |
| Q3 | A · contrato (ingenieria) | `bash tests/run.sh` y CI verdes en ese repo, y el diff del test no quita anclas de 6.2 (el lead lo lee); `git -C /Users/dn/dev/goncloud-workspace-ingenieria fetch -q origin && git -C /Users/dn/dev/goncloud-workspace-ingenieria show origin/master:AGENTS.md \| grep -c 'orden textual de David con fecha'` → `1` o más; se sella aparte (otro proyecto, otro hook) | Loop §3 en ese repo, mismo implementador |
| Q4 | V · verify | Los dos tests nuevos en verde, `DRIVE VERDE: 10 casos` pegado en el PR, `bash scripts/run-checks.sh` verde, con el rojo primero pegado | Vuelve a loop §3 con el log como encargo |
| Q5 | cierre (`fase13/cierre`, `/Users/dn/dev/wt-f13-cierre`) | Revisión §10 contra la DoD literal; PR con el loop reducido del base; solo se verifica presencia en `origin/main` del `.post.json` y la evidencia (vinieron en Q2 y #95; no se re-tocan); tras un ciclo de sync: SHA mergeado ancestro + log sin `CONFLICTO`/`FALLO` (compuerta del sync del base; cubre lo desplegado por todos; la punta NO tiene que igualar: el snapshot la mueve; residual declarado en el PR, la DoD pide igualdad); `bash scripts/cierre-de-fase.sh 13` en VERDE con salida 0; un Telegram `CERRADA` (`cierre.telegram_message_id` en el progreso), lo último tras el VERDE | `cierre-de-fase.sh` es un bucle: su lista en ROJO es la lista de lo que falta |

## Cuando algo se atora (propias de esta fase)

| Situación | Qué hace el lead |
|---|---|
| `arranque-de-fase.sh 13` ROJO en `vigilantes` | Esperado (Negado arriba): se sigue. ROJO en otra línea: se arregla; sin VERDE ahí no hay arranque |
| El aplicador aborta por ventana cerrada | Se espera fuera de las tres franjas UTC de `APLICAR_VERIF_20H.sh:7` (`date -u +%H:%M`) y se repite; no se rodea |
| Un run del vigía empezó hace <5 min al momento de editar | Se repite pasados 10 min (`cron runs 2d763be5-… --limit 1 --json`, campo `runAtIso`) |
| El gateway no responde durante el alta de M | M espera y reintenta cada 30 min escribiendo progreso; al TIMEBOX queda atorado y lo demás sigue |
| El `.post.json` difiere del `.txt` o cambió `agentId`/`schedule`/`toolsAllow`/`enabled` | No se commitea: reversa con el comando listo en el PR de M y M vuelve a loop §3 |
| La primera copia one-shot no nombra a `verifier`, o la segunda avisa por D | El v2 está mal: M vuelve a loop §3 con los `.runs.json` como encargo |
| Un `cron add` one-shot falla | Se reintenta una vez; si no entra, M queda atorado (la DoD exige la prueba antes del alta) y lo demás sigue |
| Un one-shot sobrevivió a su `cron rm` | El lead lo borra (`cron rm <id>`, id impreso por el aplicador); si ya no existe, se verifica con `cron list` y se declara |
| Pasan 3 h sin ciclo nuevo tras un merge | El sync dejó de correr (C2 del vigía, que ya avisó a David): el ítem queda atorado con ese `detenido_por` y lo demás sigue |
| 13.5b dice «igual que verif-sync-repos» pero ese `.md` no trae id | M elige el formato, lo usa en los DOS `.md` y lo declara en el PR |
| `SKILLS error:` en la cola del log tras el merge de M | Reversa de M por el camino de emergencia del base; si no entra, `atencion_requerida` (base, la reversa que no entra) |
| V nació antes de que R mergee | Se borra su worktree y rama y se recrea desde `origin/main` con R dentro; los drafts pre-marcas no se rescatan |
| El PR de ingenieria se atora (CI, kit) | Loop §3 en ese repo con el mismo implementador; openclaw no espera: Q1/Q2/Q4 siguen |
| `wt-f13-docs` o `wt-f13-aviso` trae cambios sin commitear al cerrar | No se toca: `ATORADO worktree del plan sucio` + se declara; decide el dueño |
| `cierre-de-fase.sh 13` ROJO en ramas/worktrees por las ramas del plan | Por cada rama del plan: `git push origin --delete` (si el remoto dice que no existe —`docs/fase13-aviso-del-sync` nunca se pusheó— se sigue), `git branch -D` (fueron squash: `-d` se niega), `git worktree remove` en limpio, y se repite. La rama del runbook (`docs/runbook-fase13`) NO se borra |
| `message send` del cierre falla | Se reintenta dos veces; si no sale, se cierra con `telegram_message_id: null` y el error declarado en el PR y el progreso (`CHAT` vacío cae aquí mismo: sin destino no hay envío) |

## Inventario

**Cuentas:** 7 tareas, 4 carriles + cierre, 6 ítems de cola, 2 repos. **Presupuesto:** cuatro sesiones de implementador y sus rondas; si un proveedor se queda sin cuota, ese carril se detiene y los demás siguen (base). **Fuera de alcance:** todo el Reject del plan (noveno cron, `verify/` desde el gateway, baja de `scout`, bloqueos al jsonl, leer ingenieria desde aquí, conteo de hooks por `grep`, `propose`, editar los ocho). **Canal a David:** un solo Telegram de cierre, forma `CERRADA` de seguimiento.v1. `CHAT` (vale `6470689715` hoy, pero se lee, no se pega): `CHAT=$(~/.openclaw/bin/openclaw cron list --json 2>/dev/null | python3 -c "import sys,json; t=sys.stdin.read(); d=json.loads(t[t.index('{'):]); print(next(((j.get('delivery') or {}).get('to') or '' for j in d.get('jobs',[]) if j.get('name')=='verif-sync-repos'),''))")` y `test -n "$CHAT"`; `M=$(mktemp); cat > "$M" <<'MSG'` + las 4 líneas + `MSG`; envío `~/.openclaw/bin/openclaw message send --channel telegram -t "$CHAT" --silent --json -m "$(cat "$M")"`; al progreso solo el valor del campo `messageId` del `--json`, en `cierre.telegram_message_id`. **Lo que queda listo para David:** si un agente reorganiza sus skills, te llega un mensaje con qué cambió y por qué; los textos que sostienen candados van marcados; el contrato de ingenieria dice lo que hace. Pantalla: `/runbook/tablero/c/fase13-candados`.
