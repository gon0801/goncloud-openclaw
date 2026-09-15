# Autopilot de la Fase 6

Escrito el 2026-09-15 sobre `Plans.md` Fase 6 (tareas 6.0 a 6.9), validado por tres revisores independientes (producto, seguridad+QA, arquitectura). Versión web (solo para Claude con la cuenta de David): https://claude.ai/artifact/QvGTLqa8KeEu5dvGpeYe2B

Esta página es para ti, el agente lead que corre la Fase 6 en autopilot. David no está y no se le pregunta nada: todo lo que necesitas decidir ya está decidido aquí. Siete carriles corren en paralelo, cada uno en su repo y su worktree, sin que ninguno espere a otro. Todo código cierra su loop de cross-review, espera a CodeRabbit, y se mergea solo en el orden de la cola. Al final mandas un Telegram.

**Quién**

- **lead**: tú. Briefs, evidencia, APPROVE, merges, Telegram final.
- **David**: solo lee el Telegram del cierre.
- **implementer**: subagente de Claude que escribe el código de cada carril. En esta corrida los siete carriles los implementa Claude (subagente `implementer` del lead); por eso el revisor cruzado excluye a `claude`. Si otro lead relanza con otra IA implementando, cambia la exclusión en el paso 2 del loop.
- **revisor cruzado**: otra IA vía `pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto`.
- **CodeRabbit**: revisa cada PR en GitHub; no bloquea si no tiene cuota.

---

## 0. Arranque · lo primero que haces

Partida: `Plans.md` Fase 6 (tareas 6.0 a 6.9) en `/Users/dn/dev/goncloud-openclaw`, hoy sin commitear en el working tree del checkout principal (rama `feat/tmux-activity-watch`); el carril D la commitea a `main` como docs. Esta página y esa fase son tu brief completo. **Quién mergea:** el autopilot, por la ruta del kit, en el orden de la cola (§4); David no mergea nada en esta fase. Esta regla manda sobre cualquier texto de `Plans.md` 6.9 que diga otra cosa (la fila se corrige en el commit de D).

**Rutas locales de los repos (todos en la Mac):**

| Repo | Ruta local | Default | Ruta en el gateway (para comparar el SHA tras el sync) |
|---|---|---|---|
| goncloud-openclaw | `/Users/dn/dev/goncloud-openclaw` | `main` | `C:\Users\ehven\.openclaw` |
| goncloud-workspace-main | `/Users/dn/dev/goncloud-workspace-main` | `master` | `C:\Users\ehven\.openclaw\workspace` |
| goncloud-workspace-ingenieria | `/Users/dn/dev/goncloud-workspace-ingenieria` | `master` | `C:\Users\ehven\.openclaw\workspace-ingenieria` |
| goncloud-workspace-operaciones | `/Users/dn/dev/goncloud-workspace-operaciones` | `master` | `C:\Users\ehven\.openclaw\workspace-operaciones` |
| goncloud-Orbit | `/Users/dn/dev/goncloud-Orbit` | `master` | no aplica (no se despliega en esta fase) |
| goncloud-accounting | `/Users/dn/dev/goncloud-accounting` | `main` | no aplica (no se despliega en esta fase) |

Las rutas del gateway de main y operaciones están verificadas; la de ingenieria sigue el mismo patrón y se confirma con `git -C <ruta> remote -v` (vía exec del gateway) antes de comparar SHAs. Si no coincide, la celda queda `unknown` y la compuerta usa solo el log del sync.

- [ ] **0.1 Lee la Fase 6 y da por concedidas las preaprobaciones.** Busca `.claude/state/plan-preapprovals.json`. Si existe, es el registro del harness y lo respetas. Si no existe, no preguntes ni lo escribas: la tabla "Preaprobaciones del dueño" de abajo es la autorización escrita de David para exactamente esas operaciones, dada el 15 de septiembre de 2026 y permanente (sin vencimiento; el dueño ya no da permisos puntuales). Nada fuera de esa lista se hace, y nada dentro de ella se consulta.
- [ ] **0.2 Abre los siete worktrees y lanza los siete implementers en una tanda.** Uno por carril (tabla de carriles), cada uno desde `origin/<default>` recién traído. Cada brief lleva: la fila de Plans.md verbatim, la ruta de este archivo, la ruta absoluta del worktree, la rama, los archivos que puede tocar y los que no, y la orden "no preguntes: lo que no sepas se escribe unknown con el comando que lo intentó". Después atiendes a cada carril conforme reporta; nunca esperas a uno para avanzar otro.

**Prohibido durante toda la corrida:** tocar `openclaw.json`, modelos, auth, crons o permisos del gateway; leer cualquier secreto; instalar un framework de test en Orbit o accounting; correr un Drive contra `10.13.13.1` o por ssh; enviar Telegram antes del cierre; preguntarle algo a David.

### Preaprobaciones del dueño

| Operación | Alcance | Decisión |
|---|---|---|
| git push + gh pr create | Los 6 repos de la fase; lecturas con gh api y gh pr view | Aprobado |
| Merge automatizado por la ruta del kit | Los 7 PRs, en el orden y con las compuertas de la cola; despliega al gateway por el sync | Aprobado |
| Merge por orden del dueño (6.5b) | Las corridas en curso y futuras dentro de esta fase; esta fila es la orden del dueño, vigente hasta el 22-9-2026, no se pide aparte | Aprobado |
| Cambio de código de summa-gate vivo | 6.5(c); revert automático si bloquea el exec de la flota | Aprobado |
| Lecturas en el gateway | openclaw audit, cron list, sessions_history; un turno de solo lectura a main como canary | Aprobado |
| ssh gonserver de solo lectura | `ss -lnt` filtrado por puerto, sin `-p`, salida redactada | Aprobado |
| Postgres desechable y apps en 127.0.0.1 en la Mac | Para el Drive de 6.6 y 6.7; contenedor borrado al terminar | Aprobado |
| Un Telegram a David al cierre | Uno solo, con PRs, merges, residuales y lo detenido | Aprobado |
| Instalar framework de test en Orbit o accounting | Aunque el generador diga PROPONGO | **Negado**: queda n/a declarado |

---

## 1. Reglas de trabajo del lead · aplican a todos los carriles

1. **Un worktree por carril**, siempre desde el remoto fresco: `git fetch origin && git worktree add ../wt-<carril> -b <rama> origin/<default>`. Default: `master` en workspace-main, workspace-ingenieria, workspace-operaciones y Orbit; `main` en openclaw y accounting. Los workspaces reciben commits `auto: snapshot` cada 2 h desde el gateway, así que se rebasea justo antes del PR y justo antes del merge.
2. **Implementa un subagente implementer por carril**, con el brief = la fila de Plans.md + este archivo + rutas absolutas + rama base. El lead no escribe código: escribe briefs, audita y decide. Los siete carriles se lanzan en la misma tanda; se atienden conforme reportan.
3. **TDD donde la fila dice `[tdd:required]`**: el test se escribe primero y su rojo contra `origin/<default>` queda pegado en el PR. Sin rojo pegado, el implementer no terminó.
4. **Evidencia en el repo, no en el chat**: salidas de tests, mutantes y comandos van en el cuerpo del PR o en `.saikit/scratch/<task>/`. Toda imposibilidad trae comando, salida y código de salida.
5. **Cada PR nace de `origin/<default>` y toca solo los archivos de su carril** (tabla de carriles). Dos carriles del mismo repo (D y E) tienen archivos disjuntos por diseño.
6. **Pre-commit se corre y se respeta.** Nunca `--no-verify`. Si un candado bloquea un comando legítimo, se busca la ruta que el candado permite; si no existe, es un residual declarado, no un rodeo.
7. **Lo que la fila deja como `unknown` se escribe `unknown`** con el comando que lo intentó. Nunca se rellena con una suposición para "cerrar".

---

## 2. Loop de cross-review · aplica a todo código

Cada carril con código (A, B, C, D, E, F, G: todos) pasa por esto antes de entrar a la cola. Una ronda cuesta 100 a 150k tokens; se repite mientras la anterior haya encontrado algo. Sin tope de rondas.

1. **El implementer termina**: rama pusheada, PR abierto desde `origin/<default>`, CI verde, rojos pegados, evidencia en el repo.
2. **Revisor cruzado sobre el SHA del PR**: desde el worktree, `pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto -Excluir <ia-que-implementó> -Alcance branch`. La IA excluida es la que escribió el código de ese carril (claude si el implementer fue un subagente de Claude; glm o cursor si fueron ellos). Preferencia de revisor, en este orden: kimi, grok, codex, qwen; GLM y Cursor no revisan (son implementadores). Si sale con código 3 (ningún revisor externo disponible), el lead lanza un subagente reviewer propio y lo declara en el PR como "revisión interna, sin cruzada". El revisor recibe el SHA exacto, la fila de Plans.md y la orden de re-mutar los tests, no solo leer el diff.
3. **Si encuentra algo**, el implementer lo corrige en el mismo PR con un test que lo atrape, y el revisor cruzado vuelve al paso 2 sobre el SHA nuevo. Hallazgos que se deciden no atender se listan en el PR como residuales con razón.
4. **CodeRabbit**: en cuanto el PR existe, se consulta cada 3 minutos con `gh api repos/gon0801/<repo>/pulls/<n>/reviews` y los comentarios de `coderabbitai` sobre el head actual, hasta 20 minutos. Lo accionable se corrige en el mismo PR (vuelve al paso 2). Si no responde en 20 minutos, o responde "rate limit" o cuota agotada, se anota "CodeRabbit sin respuesta o sin cuota: no bloqueante" y se sigue. Se repite tras cada push hasta que no deje nada accionable nuevo o no tenga cuota.
5. **Cuando el cruzado y CodeRabbit salen limpios**, entra el lead: audita el poder discriminante de los tests (¿pasan igual sin el cambio?), muta por su cuenta la rama principal del cambio, y cruza contra la DoD literal de la fila.
6. **Si el lead encuentra algo**, vuelve al implementer y el loop reinicia desde el paso 2.
7. **APPROVE del lead sobre un SHA** es lo único que mete el PR a la cola. Se escribe como comentario en el PR: `APPROVE lead <sha>` con la lista de residuales.
8. **El rebase pre-merge no invalida el APPROVE si no cambia el contenido.** Tras rebasear, el lead corre `git diff <sha-aprobado> <sha-nuevo> -- <archivos del carril>`; si está vacío, publica `APPROVE lead <sha-nuevo> (rebase de <sha-aprobado>, diff vacío)` y el PR sigue en cola. Si no está vacío (hubo conflicto resuelto a mano), el loop vuelve al paso 2 sobre el SHA nuevo.

> Ni el verde de CI, ni CodeRabbit, ni el revisor cruzado por sí solos meten un PR a la cola. Solo el APPROVE del lead, y el lead no aprueba lo que no mutó él mismo.

---

## 3. Carriles en paralelo · nada bloquea a nada

Las dependencias de Plans.md (6.1 → 6.4, 6.3 → 6.4b, etc.) son de *texto*, no de merge: la regla de ruteo, las filas de la tabla y los nombres de skills ya están en el plan, así que cada carril escribe con ese texto sin esperar a que otro mergee. Lo que un carril no puede saber lo escribe `unknown`.

**Rama base de todos los carriles:** cada worktree parte de `origin/<default>` tal como está en el momento de abrirlo, nunca de la rama de otro carril. D y E parten los dos de `origin/main` de goncloud-openclaw; el orden en que abran sus PRs no importa porque sus archivos son disjuntos (tabla de abajo). E no necesita que `Plans.md` esté en el remoto: su brief lleva la fila verbatim. Si al rebasear antes del merge aparece un conflicto entre dos carriles, la tabla de archivos tiene un error: se resuelve a favor del carril que mergea segundo, conservando el contenido del que ya mergeó, y se declara en el PR.

**6.1 y el umbral de 6.0b:** A no espera a D. Si 6.0b produce un umbral, D lo entrega como un PR aparte contra goncloud-workspace-main (`fase6/umbral-ruteo`), con su propio loop de cross-review, después de Q3; no se mete en el PR de A ni bloquea Q2.

### A · Director — goncloud-workspace-main · master · rama `fase6/director`

- [ ] **6.0a CI pwsh + `tests/run-all.ps1`.** Workflow `quality.yml` con `shell: pwsh` en pull_request. Antes de cerrar: un test con `throw` forzado pone el job rojo; se quita y queda verde. Las dos corridas pegadas en el PR.
- [ ] **6.1 Ruteo con desempate (a–e) y roster de 8 líneas en SOUL.md.** Texto literal de la fila. Test `test-ruteo-y-roster.ps1` con recorte por encabezado, anclas de (c), (e), "main nunca mergea" y las 8 líneas id + cuándo; anti-ancla de la frase vieja. Si 6.0b (carril D) no ha terminado, la regla (a) se escribe sin umbral y se anota que D puede abrir un PR chico después.
- [ ] **6.3 Extender la tabla de máquinas.** Columnas URL:puerto, rama de deploy, verificación, unidad en gonserver. Datos de goncloud-ssh-ops y de `ssh gonserver ss -lnt` filtrado por puerto; si ssh falla, la celda dice `unknown` + el error verbatim. Salida sin PIDs en el PR.

### B · Ingeniería — goncloud-workspace-ingenieria · master · rama `fase6/contrato`

- [ ] **6.0a CI pwsh + `tests/run-all.ps1`.** Igual que en A.
- [ ] **6.2 `## Contrato de dispatch` + poda de plantilla.** ≤8 líneas: único trabajo, nunca, reporta solo a main, ejecuta en la Mac, rutinas. Se podan Group Chats, React Like a Human, Voice storytelling, Platform formatting y Local notes de cámaras/TTS. Test: anti-anclas fuera de bloques "Medido el"; conteo de "Medido el" ≥ el de `git show origin/master:AGENTS.md`; `wc -l` ≤.

### C · Operaciones — goncloud-workspace-operaciones · master · rama `fase6/contrato`

- [ ] **6.0a CI pwsh + `tests/run-all.ps1`.** Igual que en A. Ya tiene dos tests `.ps1`: el runner los toma.
- [ ] **6.2 `## Contrato de dispatch` + poda de plantilla.** Igual que en B; ejecuta en el gateway Windows; rutinas = los tres crons de packing. El conteo previo de "Medido el" es 0 y el test lo declara.

### D · Docs de claw — goncloud-openclaw · main · rama `fase6/docs`

- [ ] **plan Commit de la Fase 6 en `Plans.md`.** Primer commit del carril: `docs(plans): Fase 6 y guía de autopilot`. De dónde sale el contenido: del working tree del checkout principal `/Users/dn/dev/goncloud-openclaw` (no de ninguna rama): se copia al worktree la sección completa desde `## Fase 6` hasta el final de `Plans.md` (se agrega al final del `Plans.md` del worktree) y el archivo `docs/runbooks/autopilot-fase6.md` entero. En ese mismo commit se corrige la DoD de 6.9 para que diga "el merge lo hace el autopilot según docs/runbooks/autopilot-fase6.md". Nada más del `git status` del checkout principal (`.claude/`, `docs/patches/`, `out/`, ni otros cambios de `feat/tmux-activity-watch`) entra en este carril. Así el resto de la corrida referencia filas que ya existen en el remoto.
- [ ] **6.0b Medir el ruteo con el audit.** `~/.openclaw/bin/openclaw audit --kind agent_run --limit 500 --json` (solo lectura). Tabla en `docs/evidence/ruteo-ingenieria-vs-cadena.md`. Si la ventana no alcanza, `unknown` con el tope del CLI. Si el número dice que la mayoría son ediciones únicas, se abre un PR chico contra A con el umbral.
- [ ] **6.2 (.sh) Completar "nunca / reporta a" en los 4 workspace-* + test.** Solo en el bloque `## Contrato de dispatch` que ya existe. `scripts/tests/test-contrato-dispatch.sh` rojo primero. scout no tiene workspace versionado: se declara en el PR.
- [ ] **6.4 Mapa de una página del camino feliz.** `docs/runbooks/camino-feliz-producto.md`: cada paso nombra la skill y no repite sus pasos; un go/no-go "merge y deploy" para openclaw y workspaces, dos para Orbit y accounting; "Live <SHA> en <URL>"; regresión vuelve al brief; tablas de variantes y de bloqueos. Test: skills existen, `grep -c GraphQL` = 0, ninguna línea duplica las 4 skills. Las líneas nuevas de agent-dispatch (go/no-go, regresión) las escribe E, no D.
- [ ] **6.4b Deploy uniforme en goncloud-ssh-ops.** Backup con timestamp y smoke con código HTTP en las dos ramas del paso 5; precondición "SHA ya en la rama de deploy"; cierre "Live <SHA> en <URL>". Test de anclas. Sin cambiar comandos ssh ni hosts.
- [ ] **6.8 Spec delta "Fleet roles and routing".** Las 4 reglas en términos de David + D2 registrada, en `docs/spec/00-project-spec.md`, enlazando al mapa. Test: grep de las 4 frases exactas y el enlace resuelve.

### E · Main no mergea — goncloud-openclaw · main · rama `fase6/merge-guard`

- [ ] **6.5a Quitar el merge de agent-dispatch; agregar go/no-go y regresión.** Sección "Merging approved PRs" fuera y las dos cláusulas de merge del `description` fuera. En su lugar, las líneas que 6.4 necesita: los dos tipos de go/no-go y "regresión vuelve al brief". Test grep sobre el archivo entero.
- [ ] **6.5b Sección "Merge por orden del dueño" en saikit-cierre-pr.** Texto movido verbatim (re-target, `expectedHeadOid`, carrera `UNPROCESSABLE`, apilados). La autorización del merge por orden del dueño está implícita y permanente en la tabla "Preaprobaciones del dueño" (fila "Merge por orden del dueño (6.5b)"), dada el 15 de septiembre de 2026: el lead NO solicita ni exige ninguna orden adicional de David, nunca, ni en el brief ni durante la corrida. Aun así, la sección movida conserva su texto sobre re-target, `expectedHeadOid`, carrera `UNPROCESSABLE` y apilados, y declara el bypass conocido del guard (`query=@archivo`).
- [ ] **6.5c Merge-guard con `agentId` opcional.** `mergeGuardVerdict(command, agentId?)`: bloquea la mutación GraphQL de merge, la ruta REST de merge de ramas y `api.github.com` con path de merge, salvo `implementer` e `ingenieria`; `index.ts` pasa `ctx.agentId`. `node --test` rojo primero con los 6 casos de la fila (incluido el negativo `gh pr view` y el bypass documentado). Smoke de import verde. Mutante: borrar la rama nueva deja rojo.

### F · Orbit — goncloud-Orbit · master · rama `fase6/verify`

- [ ] **6.6 `verify/` con Drive aislado.** `bash ~/.claude/skills/saikit-verificar-app/verificar.sh generar .`. Si dice `PROPONGO`: no se instala nada, queda `verify_app: n/a` con la razón y el PR lo dice; se sigue. Postgres desechable: `docker run -d --name orbit-verify -e POSTGRES_PASSWORD=… -p 127.0.0.1:5433:5432 postgres:16` con las mismas credenciales que `quality.yml`; `ORBIT_SECRETS_DIR` vacío; se borra el contenedor al terminar. LEEME con sello, 3–5 funciones en español y la nota de convivencia con `.cursor/skills/verify-orbit`. `grep` de `10.13.13.1` y `gonserver` en `verify/` vacío.

### G · Accounting — goncloud-accounting · main · rama `fase6/verify`

- [ ] **6.7 `verify/` con sqlite temporal.** Mismo procedimiento que F. La variable de la base apunta a un sqlite en `$TMPDIR`, `HOST=127.0.0.1`, las funciones de Amazon Ads quedan fuera del mapa. Nunca por ssh. Evidence.txt sin sockets a `amazon` ni a `10.13.13.1`.

### Archivos por carril

| Carril | Puede tocar | No toca |
|---|---|---|
| A | `SOUL.md`, `AGENTS.md` (solo la tabla de máquinas), `tests/`, `.github/` | USER.md, MEMORY.md, memory/ |
| B, C | `AGENTS.md`, `tests/`, `.github/` | SOUL.md, USER.md, memory/, reports/ |
| D | `Plans.md`, `docs/`, `scripts/tests/`, `workspace-*/AGENTS.md`, `agents/ingenieria/…/goncloud-ssh-ops/` | summa-gate/, agents/main/, agents/implementer/ |
| E | `summa-gate/`, `agents/main/…/agent-dispatch/`, `agents/implementer/…/saikit-cierre-pr/`, `scripts/tests/test-agent-dispatch-*.sh` | docs/, workspace-*/, Plans.md |
| F, G | `verify/`, `.saikit/autopilot.json` | app/, tests/, migrations/, .env*, secrets/ |
| cierre (Q5) | `Plans.md` (solo celdas Status) | todo lo demás |

---

## 4. Cola de merge · automática, en orden, con compuertas

Un PR entra a la cola con el `APPROVE lead <sha>`. Antes de cada merge: rebase sobre `origin/<default>`, push, esperar CI verde del SHA nuevo, re-APPROVE según el paso 8 del loop.

**Cómo se mergea, literalmente (la "ruta del kit").** El kit vive en `/Users/dn/dev/summonaikit-claude/tools/`. Su gate está diseñado para preparar y parar: `--confirmado` es "el sí del operador". Para esta fase, ese sí ya está dado por escrito en la fila "Merge automatizado" de las preaprobaciones: el lead invoca `--confirmado` sin preguntar. Secuencia, desde el worktree del PR, con el PR en cola:

1. Una sola vez por repo (va commiteado en el PR del carril, es lo que el gate lee de `origin/<default>`): `bash /Users/dn/dev/summonaikit-claude/tools/saikit-setup-autopilot.sh --merge si --despliega <si|no> --salud-url - --sin-verify-app si --telegram no --rama <default> --ci-minimo no --wrap-runner si`. `--despliega si` en openclaw y los 3 workspaces (mergear despliega por el sync); `--despliega no` en Orbit y accounting. `--wrap-runner si` genera `tests/run.sh` como envoltorio de la batería real (el gate solo reconoce `tests/run.sh`, pytest o jest); en los workspaces envuelve a `tests/run-all.ps1`, en openclaw a `scripts/run-checks.sh`.
2. `bash /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh --dry-run`, luego sin flags: debe terminar en `LISTO`. Cualquier otra salida es un rechazo con razón nombrada: ver la tabla "Cuando algo se atora".
3. `bash /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh --confirmado`: repite el gate y mergea en squash con `--match-head-commit <sha>`. El merge commit queda en `.saikit/veredictos/<sha>.merge`.
4. `bash /Users/dn/dev/summonaikit-claude/tools/saikit-postmerge.sh --merge-commit <merge_commit> --rama <default>`: `VERDE` cierra; `ROJO` trae el comando de revert listo, que el lead ejecuta según Q4; `UNKNOWN` se anota y se aplica la compuerta propia del ítem de la cola.

El gate exige un veredicto sellado por el harness saikit de la sesión: por eso la instrucción de arranque del lead lleva el sentinel `-saikit:autopilot` (ver pie de página). Si el gate responde "sin estado del hook" o "sin veredicto sellado", no hay otra ruta de merge: fila correspondiente de la tabla de atores.

- [ ] **Q1 F y G primero, en cuanto cierren.** Orbit y accounting no despliegan nada con este merge (solo `verify/`). Entran cuando su loop cierra, sin esperar a los demás.
- [ ] **Q2 A, B y C en una ventana segura.** Mergear un workspace despliega al gateway en el siguiente ciclo de sync. Ventana: `~/.openclaw/bin/openclaw cron list` sin ningún `Next` en los próximos 15 minutos, y fuera de los minutos :05 a :15 de las horas impares en **hora del Este de EE. UU. (`America/New_York`, el reloj del host Windows del gateway)**: el sync corre a los :10 de esas horas. La hora se toma del sistema, no de cabeza: `TZ=America/New_York date`. Si no hay ventana, se espera; no se fuerza.
  **Compuerta:** tras el siguiente ciclo, el log del sync (`C:\Users\ehven\.openclaw\logs\sync-repos.log`, cola de 40 líneas vía exec del gateway) sin `CONFLICTO` ni `FALLO` para ese repo, y `git -C <ruta en el gateway> log -1 --format=%H` igual al SHA mergeado, usando la ruta de la tabla de repos del §0 para cada uno de A, B y C. Si hay CONFLICTO, no se toca el gateway: se anota como residual y el vigía verif-sync-repos ya avisa.
- [ ] **Q3 D después de A, B y C.** Docs y tests de openclaw. Misma ventana segura. Después del sync, canary de ruteo de solo lectura: un turno a main preguntando "¿a quién mandarías 'arregla el favicon de Orbit'? Responde solo el nombre del agente o cadena, no despaches nada"; la respuesta debe nombrar la cadena implementer. Si no, residual declarado (no se revierte por esto).

**Qué es "un turno a main" (Q3 y Q4):** un turno normal por la CLI remota desde la Mac, igual que un mensaje cualquiera, con el texto en un archivo: `~/.openclaw/bin/openclaw agent --agent main --session-key agent:main:canary-fase6 --message-file <archivo> --json`. El mensaje solo pide leer y responder; no crea crons, no toca config ni git, no manda Telegram. Tarda 1 a 3 minutos; tope de espera 10 minutos.
- [ ] **Q4 E al final, solo, con reversa automática.** summa-gate corre vivo en todos los agentes y el sync no lo valida. Se mergea último, en ventana segura, y se espera el ciclo.
  **Compuerta:** tras el sync, un turno de solo lectura a main que corra `gh pr view 1 -R gon0801/goncloud-openclaw` por exec y pegue la salida. Si el exec vuelve bloqueado por summa-gate o main no responde en 10 minutos, reversa automática: rama `fase6/revert-merge-guard` desde `origin/main`, un solo commit `git revert <merge_commit>` sin cambios a mano, PR con título `revert: 6.5 merge-guard (exec bloqueado tras el sync)` y el error verbatim en el cuerpo. Loop reducido, es una emergencia: CI verde del head + `node --test` de summa-gate pegado + `APPROVE lead <sha>`; sin revisor cruzado y sin esperar a CodeRabbit. Merge con `bash /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh --revert-de <merge_commit> --confirmado` (modo sin estado del hook: exige un solo commit, árboles idénticos y CI verde). Esperar el ciclo, repetir el canary, y anotar "6.5 revertido" en el Telegram con el error verbatim. Nada de esto se pregunta.
- [ ] **Q5 Cierre: Plans.md, worktrees y un Telegram.** El cierre de `Plans.md` es un PR más de goncloud-openclaw, rama `fase6/cierre` desde `origin/main` ya con D y E mergeados, que toca solo `Plans.md`: marcar filas `cc:完了` solo con evidencia (SHA de squash, CI verde, canary), o dejarlas con su salvedad escrita en la celda Status. Es docs: su loop es CI verde + CodeRabbit (misma regla de 20 min) + APPROVE del lead, sin revisor cruzado; se mergea por la misma ruta y en la misma ventana segura que Q3. Después: borrar los ocho worktrees (los siete carriles y el de cierre) con `git worktree remove`. Por último, un solo mensaje por Telegram (skill telegram-send): PRs mergeados con SHA, PRs que quedaron abiertos y por qué, residuales, y lo que se revirtió. En palabras de David, detalle técnico al final.

---

## 5. Cuando algo se atora · qué haces en lugar de preguntar

| Situación | Qué hace el autopilot |
|---|---|
| El generador de `verify/` dice PROPONGO framework | No instala nada. `verify_app: n/a` con la razón, Drive manual/pendiente, y el PR lo declara. Sigue. |
| El audit no cubre la ventana de 6.0b | Escribe `unknown` con el tope del CLI; la regla (a) de 6.1 va sin umbral. |
| `ssh gonserver` falla en 6.3 | Celdas `unknown` + error verbatim; no reintenta más de una vez. |
| `cross-review.ps1` sale 3 | Subagente reviewer interno; "revisión interna, sin cruzada" en el PR. |
| CodeRabbit sin cuota, rate limit o sin respuesta en 20 min | No bloquea. Línea en el PR; se vuelve a consultar tras el próximo push. |
| CI rojo tres rondas seguidas por el mismo hallazgo | Ese carril se detiene: PR abierto con etiqueta `autopilot:atorado` y el diagnóstico. Los demás siguen. Va en el Telegram. |
| La ruta de merge del kit rechaza (hash del manifiesto, sin CI reconocido, "sin estado del hook", "sin veredicto sellado", lock ajeno con exit 3) | Una vez: `/saikit-update` y reintento del gate. Si sigue: ese PR queda abierto con su `APPROVE lead <sha>` y la razón textual del gate, y se lista en el Telegram. No se usa ninguna otra ruta de merge (ni `gh pr merge`, ni API, ni `--liberar-lock` de un lock que no es tuyo). |
| Un candado del repo bloquea un comando | Se usa la ruta que el candado nombra. Sin ruta: residual declarado; jamás `--no-verify`. |
| El candado léxico de goncloud-openclaw bloquea un comando que solo *menciona* `main` o merge en su texto (medido: `gh pr create --base main` fue rechazado como push a main) | No es un merge: se reescribe el comando sin la palabra. Cuerpos de PR y mensajes largos van en archivo (`--body-file`), y `gh pr create` va sin `--base` (usa la rama por defecto). |
| Sync con CONFLICTO tras mergear un workspace | No toca el gateway. Residual; el vigía avisa por su lado. |
| Exec bloqueado tras mergear E | Revert automático (Q4). Va en el Telegram con el error. |
| Un cron con `Next` en menos de 15 min | Espera. Vuelve a mirar cada 5 min. |
| Haría falta leer un secreto (DSN, token, .env) | Nunca. Lo que dependa de eso queda `n/a` declarado. |
| Un subagente no responde o entrega vacío | Se relanza una vez con el mismo brief; a la segunda, el carril se detiene y se declara. No se sustituye en silencio. |
| Cuota agotada o rate limit de un proveedor por más de 30 min | Ese carril se detiene y se declara; los demás siguen. No se cambia de modelo ni de proveedor por cuenta propia. |
| La sesión del lead se corta o se relanza | Reanudación: el estado vive en los worktrees y los PRs. Un relanzamiento con la misma instrucción lee `gh pr list` de los 6 repos, los comentarios `APPROVE lead`, y retoma cada carril donde quedó. No se repite trabajo ya aprobado. |
| Duda de alcance no cubierta aquí | La lectura más chica que cumple la DoD literal de la fila; la elección se escribe en el PR. |

> Lo único que detiene toda la corrida: perder acceso a GitHub o a la Mac. Todo lo demás detiene un carril y deja evidencia.

---

## 6. Inventario de la corrida

- **PRs**: siete: A, B, C (workspaces), D y E (openclaw), F y G (producto). Todos con APPROVE del lead antes de la cola.
- **Merges**: automáticos, en orden Q1 → Q4, cada uno con rebase, CI verde y ventana segura. E con reversa automática.
- **Revisiones**: por PR: cruzada (otra IA) + CodeRabbit + lead, en loop sin tope hasta que una ronda no encuentre nada.
- **Costo estimado**: 3 a 5 millones de tokens (siete carriles, dos o tres rondas cada uno) y de 4 a 8 horas de reloj, dominadas por los ciclos de sync de 2 h.
- **Presupuesto**: no hay nada que preparar antes de lanzar; los tokens salen de las suscripciones ya activas y la mayoría de las cuotas no se pueden leer por adelantado. Si una se agota a mitad de la corrida, aplica la fila "cuota agotada" de la tabla y la reanudación retoma después.
- **Sin David**: todo. Una sola salida hacia él: el Telegram del cierre.
- **Lo que no cubre**: deploy de Orbit y accounting (no cambia código de app); el cron opcional del verifier; el umbral de 6.1 si el audit no da número.

## 7. Cómo termina si todo fluye

- **Gateway**: main rutea por la regla nueva, no mergea, y cada agente tiene su contrato; summa-gate bloquea el merge a todo agente salvo implementer e ingenieria.
- **Producto**: Orbit y accounting tienen `verify/` con Drive corrido o `n/a` honesto.
- **Docs**: mapa del camino feliz, spec delta y evidencia del ruteo en el repo.
- **David**: un Telegram con todo. Si algo quedó abierto, dice cuál y por qué.

> Tres reglas que no se negocian: todo código cierra su loop hasta el APPROVE del lead, sin tope de rondas; lo que se decide no atender se declara en el PR; y lo que no se pudo verificar se escribe `unknown`, nunca como hecho.

Para David, una sola línea: se lanza una sesión del agente en `~/dev/goncloud-openclaw` con el modo de permisos que no pregunta y se le dice "-saikit:autopilot ejecuta la Fase 6 de Plans.md en autopilot siguiendo docs/runbooks/autopilot-fase6.md". El sentinel `-saikit:autopilot` al inicio arma el harness que sella los veredictos que el gate de merge exige; sin él, los PRs quedan en cola con APPROVE y nadie los mergea.
