# Autopilot de la Fase 7 — tablero de runbook

Escrito el 2026-09-15 sobre `Plans.md` Fase 7 (tareas 7.0 a 7.7) con la skill `autopilot-runbook`. Hereda el método de `docs/runbooks/autopilot-fase6.md`; lo que aquí no se repite (loop de cross-review, ventana segura, "qué es un turno a main", reglas del kit de merge) se lee allá y aplica igual. Lo que cambia respecto de la Fase 6: **el código lo escriben GLM 5.3 o Muse, no un subagente de Claude**, y este es el primer runbook que escribe su propio progreso como `runbook-progress.v1`.

Esta página es para ti, el agente lead que corre la Fase 7 en autopilot. David no está y no se le pregunta nada. Dos carriles en el mismo repo con archivos disjuntos, un spike tuyo al inicio, un despliegue al final con canary y reversa, y un Telegram al cierre.

**Quién**

- **lead**: tú (Claude, sesión en la Mac). Spike 7.0, briefs, entrega a los implementadores por tmux, loop de cross-review, APPROVE, merges, despliegue 7.6, cierre 7.7, Telegram final. No escribes código de producto.
- **David**: solo lee el Telegram del cierre y el enlace al tablero.
- **GLM 5.3** (implementer del carril P, el código): se lanza con `~/bin/glm` (Claude Code apuntado a `glm-5.3`) dentro de tmux. Es el más capaz para motores y lógica; se vigila su proceso: rojo antes que verde, no toca trackers.
- **Muse** (implementer del carril D, docs y tests de anclas): `~/.local/bin/muse-bin-1.3.0-R3057.1` con `--reasoning-effort max`; el modelo es el default del proveedor meta salvo que el brief diga otro.
- **revisor cruzado**: `pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto -Excluir <ia-que-implementó> -Alcance branch`. Carril P: `-Excluir glm`; preferencia kimi, grok, codex, qwen, claude. Carril D: Muse no está en la cadena del script, así que sin `-Excluir`; misma preferencia.
- **CodeRabbit**: igual que en Fase 6: 20 minutos, sin cuota = no bloquea.

---

## 0. Arranque · lo primero que haces

Partida: `Plans.md` Fase 7, este runbook y el spec viven en la rama `docs/fase7-tablero-runbook` (PR #46). **Paso 0.0, antes de todo:** `git fetch origin && git log -1 origin/main -- docs/runbooks/autopilot-fase7.md`. Si devuelve un commit, #46 ya está en `main` y sigues. Si no, #46 es el primer ítem de la cola (Q0): docs, misma ruta del kit, ventana segura; no creas otro PR ni copias archivos a mano. Si #46 no existe (cerrado sin merge o rama borrada), recreas el PR desde `origin/docs/fase7-tablero-runbook` con `gh pr create --head docs/fase7-tablero-runbook`; si la rama tampoco existe, la fase se detiene y se declara. Copias sin commitear de estos archivos en el working tree de otra rama (por ejemplo `feat/tmux-activity-watch` en el checkout principal) son restos de redacción y **no se usan**: la fuente es la rama remota o `main`, nunca el working tree. Repo: `/Users/dn/dev/goncloud-openclaw`, default `main`, copia en el gateway `C:\Users\ehven\.openclaw` (el sync la actualiza cada 2 h a los :10 de las horas impares, hora del Este). Kit de merge en `/Users/dn/dev/summonaikit-claude/tools/`.

- [ ] **0.1 Lee la Fase 7 de `Plans.md`, el spec `docs/spec/runbook-progress.v1.md` y las secciones 1, 2, 4 y 5 del runbook de la Fase 6.** Las preaprobaciones de esta fase son la tabla de abajo (misma regla de precedencia que en Fase 6: el registro del harness no acota la corrida; si deniega por tope o alcance, se sigue y se anota).
- [ ] **0.2 Escribe el primer progreso.** `.saikit/progress/7.json` con los dos carriles en `pendiente`, `siguiente_paso: "Midiendo qué ofrece el gateway instalado (spike 7.0)"`, `atencion_requerida.necesaria: false`. Envío: `~/.openclaw/bin/openclaw gateway call runbook.progress.set --params @.saikit/progress/7.json`. **Va a fallar con "método desconocido" hasta que 7.6 despliegue el plugin**: eso es lo esperado; se anota en `eventos` y se reintenta en cada cambio de estado. A partir de 7.6, el propio tablero muestra esta fase.
- [ ] **0.3 Abre los dos worktrees** (regla 1 de la sección 1) antes de cualquier otra cosa, para que el spike tenga dónde escribirse.
- [ ] **0.4 Corre el spike 7.0 tú mismo** (es solo lectura): los comandos están en la fila 7.0 de `Plans.md`. Escribe el resultado **directamente en** `/Users/dn/dev/wt-f7-D/docs/evidence/tablero-runbook-spike.md` con los veredictos `presente` / `ausente` / `unknown` y las dos decisiones (pestaña sí/no; `stateDir` medido o `configSchema.stateDir`). Ese archivo lo pule Muse en el carril D (formato, sin cambiar veredictos) y va en su PR; el brief de P lleva las dos decisiones pegadas en CONTEXT, no el archivo.
- [ ] **0.5 Lanza a los dos implementadores en la misma tanda** (sección 3). No esperas a uno para avanzar el otro.

**Quién manda si `Plans.md` dice otra cosa:** este runbook. En particular, la fila 7.7 de `Plans.md` menciona "David a mano si el gate no sella": en autopilot no hay David; si el gate del kit no sella, el PR queda abierto con su `APPROVE lead <sha>` y se lista en el Telegram (fila de atores heredada de Fase 6). El PR de cierre (Q5) corrige esa frase en `Plans.md`.

**Prohibido durante toda la corrida:** tocar `openclaw.json` en el repo, modelos, auth, crons o permisos del gateway fuera de `plugins.entries.tablero-runbook.*`; leer o imprimir cualquier secreto (el lanzador `~/bin/glm` contiene un token: se ejecuta, jamás se lee ni se pega); registrar hooks de agente o tools en el plugin; enviar Telegram antes del cierre salvo el caso marcado en atores; preguntarle algo a David.

### Preaprobaciones del dueño (Fase 7)

| Operación | Alcance | Decisión |
|---|---|---|
| git push + gh pr create en goncloud-openclaw | Dos PRs (docs y código) y los de reversa si hacen falta | Aprobado |
| Merge automatizado por la ruta del kit | Los dos PRs, docs primero; `--confirmado` con este runbook como el sí escrito | Aprobado |
| Turno de solo lectura a main y `openclaw gateway call` desde la Mac; `curl` sin credencial al puerto del gateway | Spike 7.0 y canarios de 7.6 | Aprobado |
| `openclaw config patch` de `plugins.entries.tablero-runbook.*` y reload con cero runs en vuelo; rollback `enabled: false` | 7.6 | Aprobado |
| Código nuevo vivo en el gateway (plugin sin hooks) y un `gh pr merge` de prueba desde un agente que debe salir bloqueado | 7.4, 7.5, 7.6 | Aprobado |
| Lanzar GLM y Muse en tmux sobre worktrees desechables, con aprobaciones de herramientas resueltas por el lead (Muse en modo sin aprobaciones dentro del worktree) | Carriles P y D | Aprobado |
| Un Telegram a David al cierre con el enlace al tablero | 7.6 y 7.7 | Aprobado |
| Instalar dependencias nuevas en `tablero-runbook/` | Nunca: sin dependencias, como summa-gate | **Negado** |

---

## 1. Reglas de trabajo del lead

1. **Un worktree por carril**, desde el remoto fresco: `git fetch origin && git worktree add /Users/dn/dev/wt-f7-<carril> -b <rama> origin/main`. Ramas: `fase7/tablero` (P) y `fase7/docs` (D).
2. **Los implementadores no son subagentes tuyos.** GLM es interactivo y vive en tmux; Muse corre en modo `exec`, sin pantalla ni tmux (regla 4). Para GLM: lanzas con `~/bin/agent-tmux.sh glm <worktree> [args]` (sesión `glm-wt-f7-P`), entregas el brief con `/opt/homebrew/bin/tmux send-keys -t glm-wt-f7-P -l 'Lee /Users/dn/dev/wt-f7-P/BRIEF.md y haz lo que pide'` y `Enter` en una llamada aparte, y confirmas la entrega leyendo la pantalla (`capture-pane`), no por el exit de tmux (skill `mac-tmux-control`, pasos 3 a 5). Marcas la sesión con `set-environment -t glm-wt-f7-P OPENCLAW_WATCH 1` para que el vigía de tmux te despierte cuando se calle; desmarcas al cerrar el carril. Para Muse no hay sesión que marcar: lanzas el proceso en segundo plano y esperas su fin (`wait` o polling del jsonl cada 5 min); su "pantalla" es el jsonl.
3. **GLM (carril P):** `~/bin/agent-tmux.sh glm /Users/dn/dev/wt-f7-P --permission-mode acceptEdits`. Las aprobaciones de comandos que queden las contestas tú por tmux (`Enter` a "Do you want to proceed? Yes"; skill `mac-tmux-control`, paso 4). Nunca David.
4. **Muse (carril D):** `cd /Users/dn/dev/wt-f7-D && mkdir -p .saikit/scratch/D && ( ~/.local/bin/muse-bin-1.3.0-R3057.1 exec --prompt-file BRIEF.md --json --reasoning-effort max --yolo --workspace /Users/dn/dev/wt-f7-D > .saikit/scratch/D/muse.jsonl 2> .saikit/scratch/D/muse.err & echo $! > .saikit/scratch/D/muse.pid )`. `--yolo` desactiva aprobaciones y sandbox **solo** para ese worktree desechable; el brief le prohíbe salir del worktree. El JSONL es la evidencia de la corrida y vive dentro de la zona del carril. **TIMEBOX real:** a las 4 h de lanzado, si el proceso sigue vivo (`kill -0 $(cat .saikit/scratch/D/muse.pid)`), el lead lo mata (`kill $(cat …/muse.pid)`), toma el jsonl parcial como el reporte y el commit local si existe; sin commit, el carril pasa a `atorado` con "timebox vencido sin commit". Si la corrida termina con una pregunta en vez de un commit (la última entrada del jsonl es una pregunta), se relanza **una vez** con `BRIEF-r1.md` = brief original + la respuesta del lead (la lectura más chica que cumple la DoD); una segunda pregunta seguida es `atorado`.
5. **El brief** (`BRIEF.md` en la raíz del worktree) lleva, en este orden: GOAL (la fila de `Plans.md` verbatim), SCOPE (archivos que puede tocar y que no, tabla de la sección 3), CONTEXT (rutas absolutas, rama, default `main`, decisiones del spike 7.0 pegadas, enlace a este runbook y al spec), ACCEPTANCE (la DoD verbatim), VERIFY (comandos exactos por carril: P corre `node --check tablero-runbook/*.ts`, `cd tablero-runbook && node --test` y `bash scripts/run-checks.sh`; D corre `bash scripts/tests/test-runbook-progreso.sh`, `bash scripts/tests/test-spec-tablero.sh` y `bash scripts/run-checks.sh`), TIMEBOX (4 h; al vencer, reporta lo que hay), FORBIDDEN (los prohibidos de arriba más "no hagas push", "no abras el PR", "no instales nada", "no preguntes: lo que no sepas escribe `unknown` con el comando que lo intentó"), REPORT (commit local en la rama con mensaje Conventional, rojos de TDD pegados en `.saikit/scratch/<carril>/tdd.md`, y la última línea de la pantalla `LISTO <sha>` o `ATORADO <razón>`).
6. **TDD donde la fila dice `[tdd:required]`**: rojo primero pegado. Sin rojo pegado no terminó.
7. **El push y el PR los haces tú**, desde el worktree, después de leer el commit del implementador: `git log -1`, `git diff --stat origin/main`, y la batería una vez: `bash scripts/run-checks.sh`. Cuerpo del PR en archivo (`--body-file`), `gh pr create` sin `--base`.
8. **Pre-commit se respeta.** El implementador commitea con el hook; si lo saltó, rehaces el commit tú con el hook. Nunca `--no-verify`.
9. **Progreso escrito, no contado.** Cada cambio de estado de un carril o de la cola actualiza `.saikit/progress/7.json` y lo envía (regla 8 del runbook de Fase 6). Este archivo sí se commitea en el PR de cierre.
10. **Lo desconocido se escribe `unknown`** con el comando que lo intentó.

---

## 2. Loop de cross-review

El de la Fase 6, sección 2, con dos ajustes: (a) el implementador no es un subagente: las correcciones se entregan como un brief nuevo `BRIEF-r<N>.md` (hallazgos verbatim con file:line); a GLM por tmux con la misma frase de la regla 2 apuntando al archivo nuevo, y su sesión se vuelve a marcar; a Muse con una nueva corrida `muse-bin ... exec --prompt-file BRIEF-r<N>.md ... > .saikit/scratch/D/muse-r<N>.jsonl` (mismos flags de la regla 4); (b) el paso 5 (auditoría del lead) incluye correr tú mismo los mutantes que la DoD nombra, no leer que el implementador dice haberlos corrido. Cierre: `APPROVE lead <sha>` como comentario en el PR. Rebase pre-merge y re-APPROVE según el paso 8 del loop de Fase 6.

---

## 3. Carriles

### P · Plugin — goncloud-openclaw · main · rama `fase7/tablero` · implementa GLM 5.3

- [ ] **7.1 Fixtures.** `tablero-runbook/fixtures/fase6-en-curso.json`, `fase6-cerrada.json`, `fase6-diez-prs.json`, `invalido.json` y `tablero-runbook/progress.test.ts` en rojo (sin validador). `omitido` no aparece en los fixtures.
- [ ] **7.3 Núcleo puro `tablero-runbook/lib.ts`.** `validarFase`, `validarProgreso`, `derivar`, `renderTablero` con una sola `esc()` en el punto de interpolación (truncar primero, escapar después), banner de `atencion_requerida`, `siguiente_paso` primero, rótulo "GitHub: sin verificar", `fusionarEventos` con la política de tope y rotación de `summa-gate/observer.ts`. Mutantes de la fila en verde-rojo. `scripts/run-checks.sh` gana el bloque `tablero-runbook` con guard de conteo; `scripts/tests/test-summa-gate-quality-entrypoints.sh` se extiende.
- [ ] **7.4 Cableado `tablero-runbook/index.ts` + `openclaw.plugin.json` + `package.json`.** Método `runbook.progress.set/get`, rutas HTTP con los tres headers, `stateDir` según el spike, pestaña solo si el spike la confirmó, cero hooks y cero tools; `.gitignore` y `scripts/tests/test-salida-del-observador-no-trackeada.sh` extendidos. Host simulado local en los tests.
- [ ] **7.5 Cruce con GitHub** apagado por defecto: `execFile` con argv literal, `ghPath` de config terminado en `.exe`, validación de `repo`/`pr`, presupuesto total 8 s, ≤10 PRs, concurrencia ≤4, `kill` real. Mutantes de la fila.

Orden dentro del carril: 7.1 → 7.3 → 7.4 → 7.5, un commit por tarea, mismo PR.

### D · Docs y anclas — goncloud-openclaw · main · rama `fase7/docs` · implementa Muse

- [ ] **7.0 Evidencia del spike** (`docs/evidence/tablero-runbook-spike.md`): el lead la escribió en 0.3; Muse la deja en el formato del repo (comandos, salida recortada, veredictos) sin cambiar ningún veredicto.
- [ ] **7.2 Test de anclas `scripts/tests/test-runbook-progreso.sh`** sobre `docs/runbooks/autopilot-fase6.md` (rojo contra `origin/main` solo si la regla 8 no está mergeada; si ya está, el rojo se demuestra contra `git show <commit-anterior>:docs/runbooks/autopilot-fase6.md` y se declara).
- [ ] **Spec delta**: sección "Tablero de runbook" en `docs/spec/00-project-spec.md` con las cuatro reglas de la Fase 7, más `scripts/tests/test-spec-tablero.sh` con anclas de las cuatro frases.

### Archivos por carril

| Carril | Puede tocar | No toca |
|---|---|---|
| P | `tablero-runbook/**`, `scripts/run-checks.sh`, `scripts/tests/test-summa-gate-quality-entrypoints.sh`, `scripts/tests/test-salida-del-observador-no-trackeada.sh`, `.gitignore`, `.saikit/scratch/P/**` | `docs/**`, `summa-gate/**`, `Plans.md`, `agents/**`, `workspace-*/**` |
| D | `docs/evidence/tablero-runbook-spike.md`, `docs/spec/00-project-spec.md`, `scripts/tests/test-runbook-progreso.sh`, `scripts/tests/test-spec-tablero.sh`, `.saikit/scratch/D/**` | `tablero-runbook/**`, `summa-gate/**`, `Plans.md`, `scripts/run-checks.sh`, `.gitignore` |
| cierre | `Plans.md` (solo celdas Status), `.saikit/progress/7.json`, `docs/evidence/tablero-runbook-canary.md` | todo lo demás |

Dependencia de texto, no de merge: P necesita las decisiones del spike (0.3), que van pegadas en su brief; no necesita que D mergee.

---

## 4. Cola de merge

Misma mecánica que la Fase 6, sección 4 (ruta del kit con `--confirmado`, `autopilot.json` ya existe en goncloud-openclaw desde el carril D de la Fase 6; si no existe, se genera con el comando de allá con `--despliega si`).

- [ ] **Q1 D primero**, en ventana segura. Solo docs y tests: el sync lo lleva sin riesgo.
- [ ] **Q2 P después de D**, en ventana segura, solo. Es código que corre vivo en el gateway. Tras el sync: `git -C C:\Users\ehven\.openclaw log -1 --format=%H` (vía exec del gateway) igual al SHA mergeado y el log del sync sin `CONFLICTO` ni `FALLO`. El plugin **todavía no está habilitado**: mergear no lo enciende.
- [ ] **Q3 Despliegue 7.6**, en ventana segura y con cero runs en vuelo verificados (salida verbatim de `openclaw cron runs` de los jobs con `Next` en menos de 2 h y `sessions_list` por agente). `openclaw config patch` con `plugins.entries.tablero-runbook.enabled: true` y `github.enabled: false`. Canary 1: `gateway call runbook.progress.set --params @tablero-runbook/fixtures/fase6-en-curso.json`; `gateway call runbook.progress.get --params '{"fase":"6"}'`, cuya respuesta trae `doc`, `derivado` y `html` (por eso el HTML se verifica por RPC, sin ningún curl autenticado: en `html` deben aparecer el `titulo` del fixture y "GitHub: sin verificar"); `curl -s -o /dev/null -w '%{http_code}' http://100.80.179.76:18789/runbook/tablero/6` sin credencial, que debe dar 401 o 403 (la ruta existe y está protegida); y **canary de summa-gate**: `openclaw plugins list` con los dos habilitados y un merge de prueba que debe salir bloqueado. El merge de prueba es un turno a **main** (no a implementer ni a ingenieria: esos dos están en la allowlist del guard nuevo de 6.5c y no probarían nada), con el mismo comando de turno del runbook de Fase 6 y `--session-key agent:main:canary-fase7`, cuyo mensaje dice literal: "Corre por exec este comando y pega la salida completa sin resumir: `gh pr merge 1 -R gon0801/goncloud-openclaw --squash`". Es inerte aunque el guard fallara: el PR 1 de ese repo ya está cerrado desde hace semanas, así que `gh` solo devolvería un error. La salida esperada contiene "Merge bloqueado por summa-gate". Tope 10 minutos; sin respuesta, `unknown` y se repite una vez. Después: `github.enabled: true` y canary 2 (una fila con estado rotulado "GitHub"). Por último: envía el progreso real de esta fase (`.saikit/progress/7.json`) y confirma que aparece en `/runbook/tablero/7`.
  **Compuerta:** si el plugin no carga (no aparece en `plugins list`) o summa-gate no bloquea el merge de prueba, rollback inmediato: `config patch enabled: false`, reload con cero runs, repetir el canary de summa-gate. Si summa-gate sigue sin bloquear después del rollback, es el único caso de esta fase que llega a David sin esperar al cierre: Telegram en ese momento con `atencion_requerida.necesaria: true`.
- [ ] **Q4 Telegram a David con el enlace** al tablero (`http://100.80.179.76:18789/runbook/tablero/6` y `/7`, o la pestaña "Runbook" de la Control UI si el spike la confirmó) y una línea de qué es. Va junto con el Telegram de cierre de Q5, no aparte.
- [ ] **Q5 Cierre 7.7**: rama `fase7/cierre` desde `origin/main` con `Plans.md` (Status y la frase de 7.7), `.saikit/progress/7.json` final con eventos clave y `docs/evidence/tablero-runbook-canary.md`; loop reducido (CI + CodeRabbit + APPROVE lead, sin cruzado); merge por la misma ruta y en la misma ventana segura que Q1; borrar los tres worktrees; desmarcar la sesión tmux de GLM (`set-environment -t glm-wt-f7-P -u OPENCLAW_WATCH`) y dejarla abierta (David decide si la cierra); Muse no tiene sesión: su proceso ya terminó y su jsonl queda en el PR de cierre como evidencia. Un solo Telegram: PRs con SHA, lo que quedó abierto, residuales, revertidos, y el enlace del tablero.

---

## 5. Cuando algo se atora

Aplican todas las filas de la tabla de la Fase 6 (sección 5) más estas:

| Situación | Qué hace el autopilot |
|---|---|
| El spike dice que `registerControlUiDescriptor` está `ausente` o `unknown` | 7.4 sin pestaña; el tablero se abre por URL; se declara en el PR y en el Telegram. |
| El spike dice que el directorio de estado cae dentro del clon, o `unknown` | 7.4 usa `configSchema.stateDir` con default `C:\Users\ehven\.openclaw-state\tablero-runbook` (fuera del clon); `.gitignore` igual incluye `tablero-runbook/*.jsonl` por si acaso. |
| `curl` sin credencial devuelve 200 en el spike | `auth: "gateway"` no protege como se asumía: 7.4 agrega verificación propia (rechaza sin `Authorization`) y se declara como hallazgo de seguridad en el PR y en el Telegram. |
| GLM se detiene en una pregunta | El lead responde por tmux con la lectura más chica que cumple la DoD literal y la anota en `.saikit/scratch/P/decisiones.md`. Nunca David. (Muse: regla 4, relanzamiento con la respuesta en el brief.) |
| GLM o Muse mueren, se cuelgan más de 30 min sin salida, o el lanzador falla, **sin** mensaje de cuota o rate limit en la pantalla o el jsonl | Relanzar una vez con el mismo brief (`agent-tmux.sh` reengancha la sesión de GLM; Muse con una corrida nueva). A la segunda, el carril queda `atorado` y se declara; el otro carril sigue. No se cambia de implementador en silencio: si se cambia (GLM ↔ Muse), se escribe en el PR y en `eventos`. |
| La pantalla de GLM o el jsonl de Muse muestran cuota agotada o rate limit | Manda la fila de cuota de la Fase 6: el carril se detiene sin relanzar, se declara con el mensaje verbatim, y el otro carril sigue. Esta fila gana sobre la de relanzamiento cuando las dos aplican. |
| El implementador hizo push o abrió el PR por su cuenta | No se castiga ni se rehace: se verifica el contenido igual que si lo hubieras hecho tú y se anota como desvío de proceso en el PR. |
| El implementador instaló una dependencia | Se revierte ese commit (`git revert`) y se le entrega un brief de corrección; `package.json` sin `dependencies` es parte de la DoD de 7.4. |
| `gateway call runbook.progress.set` falla antes de 7.6 | Esperado: "método desconocido". Se anota una vez en `eventos` y no se vuelve a anotar hasta que cambie el error. |
| El plugin carga pero `runbook.progress.set` responde algo distinto de `{ok:true}` con el fixture válido | No se despliega `github.enabled`; rollback `enabled: false`; el carril P vuelve a `implementando` con el error verbatim como brief. |
| El `gh pr merge` de prueba NO sale bloqueado tras habilitar el plugin | Rollback inmediato y repetir la prueba. Si sigue sin bloquear: Telegram inmediato con `atencion_requerida.necesaria: true`; la fase se detiene ahí. |
| El propio `openclaw config patch` de rollback (`enabled: false`) falla o el gateway lo rechaza | Reintentar una vez a los 60 s. Si sigue fallando, leer el estado real con `openclaw config get plugins.entries.tablero-runbook`: si el plugin quedó deshabilitado, listo; si quedó habilitado y summa-gate sí bloquea el merge de prueba, se deja así y se declara; si quedó habilitado y summa-gate no bloquea, segunda vía de reversa: rama `fase7/revert-tablero` desde `origin/main`, un solo commit `git revert <merge_commit_de_P>`, PR `revert: 7.4 tablero-runbook (rollback de config fallido)`, loop reducido de emergencia (CI + `node --test` de summa-gate pegado + APPROVE lead, sin cruzado ni CodeRabbit), merge con `--revert-de <merge_commit> --confirmado` (el sync retira el código en el siguiente ciclo) y Telegram inmediato con `atencion_requerida.necesaria: true`. Si ese `git revert` sale con conflicto: `git revert --abort` y segundo intento determinista `git checkout <merge_commit>^ -- tablero-runbook/ scripts/run-checks.sh scripts/tests/test-summa-gate-quality-entrypoints.sh scripts/tests/test-salida-del-observador-no-trackeada.sh .gitignore` en un solo commit; si el gate también lo rechaza, el Telegram ya salió y la fase se detiene ahí. |
| La sesión del lead se cae mientras GLM o Muse siguen en tmux | Reanudación de la Fase 6 más esto: `/opt/homebrew/bin/tmux list-sessions`; por cada sesión `glm-wt-f7-P` y la de Muse, `capture-pane -p -t <sesión> -S -200` para buscar la última línea `LISTO <sha>` o `ATORADO <razón>`; `git -C <worktree> status --short` y `log -1`; `.saikit/progress/7.json` local es el estado del lead. Si el implementador sigue trabajando, se vuelve a marcar `OPENCLAW_WATCH 1` y se espera; si ya imprimió `LISTO`, se sigue desde la regla 7; si la sesión no existe, se relanza según la fila de relanzamiento. Muse en `exec` no es interactivo: su estado es el final de `.saikit/scratch/D/muse.jsonl`. |
| El cruce con GitHub (7.5) deja procesos `gh.exe` vivos en el gateway | `github.enabled: false` por config patch; hallazgo alto para P; no se vuelve a habilitar hasta que el mutante del `kill` esté verde en CI. |
| Muse no acepta `--yolo` o el proveedor rechaza `--reasoning-effort max` | Se relanza con `--reasoning-effort high` o `--disable-approval --trust-workspace`, se anota, y la regla 4 se corrige en el PR de cierre. |

> Lo único que detiene toda la corrida: perder acceso a GitHub o a la Mac. Todo lo demás detiene un carril y deja evidencia.

---

## 6. Inventario y cierre

- **PRs**: dos de trabajo (D docs, P código) y uno de cierre. Docs se mergea primero.
- **Implementadores**: GLM 5.3 en P, Muse en D, ambos en tmux sobre worktrees desechables; el lead entrega, vigila, revisa y mergea.
- **Costo estimado**: 1,5 a 2,5 millones de tokens del lado del lead (spike, dos loops, canarios) más lo que consuman GLM y Muse en sus propias cuentas; 3 a 6 horas de reloj, dominadas por dos ciclos de sync y el despliegue.
- **Presupuesto**: nada que preparar; las cuotas de GLM y Muse no se pueden leer por adelantado; si una se agota, aplica la fila de relanzamiento y el otro carril sigue.
- **Sin David**: todo. Dos salidas hacia él como máximo: el Telegram de cierre con el enlace del tablero, y el caso de summa-gate sin bloquear.
- **Cómo termina**: el plugin vive en el gateway, apagado o encendido según el canary; el tablero muestra la Fase 6 (desde su cierre) y la Fase 7 (en vivo desde 7.6); `Plans.md` cerrado con SHAs y salvedades.

Para David, una sola línea: se lanza una sesión de Claude en `~/dev/goncloud-openclaw` con el modo de permisos que no pregunta y se le dice "-saikit:autopilot ejecuta la Fase 7 de Plans.md en autopilot siguiendo docs/runbooks/autopilot-fase7.md". GLM y Muse los lanza el lead; David no abre nada.
