# Brief para muse — fixes de la corrida nocturna de claw (2026-09-15)

Fecha: 2026-09-15. Lead: Claude (analizó, escribe este brief, revisa; **no implementa**).
Implementa: **muse**, en la Mac, en `/Users/dn/dev/goncloud-openclaw`.
Meta: cerrar las causas raíz que sí son nuestras de los 18 problemas que reportó claw tras la
corrida nocturna. Lo que es bug de OpenClaw se documenta para reportar; lo que es diseño no se toca.

## 0. Contexto (verificado por el lead, no asumido)

- Claw entregó 18 problemas. El lead los contrastó contra el código real de OpenClaw 2026.9.4
  (`~/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw/dist`), el kit de merge
  (`/Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh`), `cross-review.ps1`, los runbooks y la
  config viva del gateway. Resultado: 4 bugs de OpenClaw, 5 cosas de diseño, 4 diagnósticos
  equivocados y el resto entorno/proveedor.
- **Ya hecho, no repetir**: el candidato `glm` de `/Users/dn/quality-kit/cross-review.ps1` ahora
  invoca `zcode` (CLI del runtime ZCode de Z.AI) en modo plan (PR quality-kit #9, CI verde). El
  lanzador `~/bin/glm` de la Mac también ejecuta zcode; el viejo (Claude Code apuntado a Z.AI)
  quedó en `~/bin/glm-claude`.
- Hechos que este brief da por ciertos (medidos el 2026-09-15):
  - El exec del nodo Mac **sanea el PATH** (`sanitizeHostExecEnv({blockPathOverrides:true})` en
    `daemon-*.mjs`) e **ignora `pathPrepend`**. En la Mac el exec pasa por OpenClaw.app con el
    PATH de launchd: no trae `/opt/homebrew/bin`, `~/.local/bin` ni `~/bin`. Ahí viven `gh`,
    `tmux`, `grok`, `zcode`, `kimi`, `codex` (Homebrew), `pwsh` y `claude` (`~/.local/bin`),
    `glm`/`deepseek`/`kimi-claude` (`~/bin`).
  - El gate del kit lee `.saikit/autopilot.json` de `origin/<default>` (línea 273) y **rechaza
    cualquier PR que toque ese archivo** (línea 427). Es por diseño (un PR no puede reescribir su
    propio portón). El "círculo del bootstrap" lo causa el runbook, que dice lo contrario.
  - `summa-gate` bloquea el merge directo a `main` aunque haya preaprobación. Por diseño.
  - Config viva de modelos (`openclaw gateway call config.get`): `main`, `operaciones`,
    `ingenieria` y `verifier` tienen primary `opencode-go/glm-5.3-flash`; `implementer`
    `opencode-go/muse-spark-1.3-contributor`; `reviewer`, `adversary`, `scout`
    `opencode-go/deepseek-v4.1-flash`. **Los 8 agentes cuelgan de la misma llave `opencode-go`**:
    una cuota agotada frena toda la flota, y el cooldown por billing dura de 10 min a 24 h.
    `docs/patches/modelos-cadena-go-zen.json` (untracked) NO coincide con lo vivo.
  - `openclaw config get agents.entries.<id>.model` desde la Mac devuelve "unset" aunque esté
    puesto: quirk conocido (`docs/patches/README.md`). La lectura fiable es
    `~/.openclaw/bin/openclaw gateway call config.get --params '{}' --json`.
  - Docker no está en la Mac. Postgres sí (Homebrew).
  - `/saikit-update` es un slash command que ejecuta el binario `summonaikit`, que no existe en la
    Mac. El runbook fase 6 ya lo dice en su tabla de atores (línea ~180): no volver a tocarlo.

## 1. Guardrails (obligatorios)

1. `git fetch origin` y rama **desde `origin/main`**: `fix/corrida-nocturna-claw`. Antes del PR,
   `git log origin/main..HEAD` lista SOLO tus commits.
2. **Prohibido** tocar el gateway vivo, `openclaw.json`, `openclaw config patch` (ni `--dry-run`
   desde la Mac: escribe el `openclaw.json` local y, aplicado con runs en vuelo, los mata), los
   crons `packing-*`, `Plans.md`, `.saikit/`, `summa-gate/`. La corrida real es del lead.
3. `agents/*/agent/workshop-skills/` son artefactos que el gateway regenera cada 2 h, PERO la ruta
   correcta para cambiarlos es exactamente esta: editar en el repo, PR, merge a `main` (el sync los
   despliega). Así llegaron mac-tmux-control y mac-terminal-control (PRs #39 a #42). Nunca edites
   la copia del gateway a mano.
4. `docs/runbooks/autopilot-fase6.md` y `autopilot-fase7.md` están **untracked** (borradores).
   Edítalos en sitio y **súbelos en tu PR** (`git add` explícito). No los reescribas: cambios
   quirúrgicos, el resto del texto queda como está.
5. Cada tarea trae su **prueba que discrimina**: en rojo antes del fix, verde después, y lo
   demuestras en el PR con la salida de ambas corridas. Los tests van en `scripts/tests/` con
   el estilo de los que ya hay (bash, `fail()`, comentario de cabecera con el incidente) y se
   ejecutan desde `scripts/run-checks.sh` (revisa cómo registra los existentes).
6. Candados: el pre-commit corre; **jamás** `--no-verify`. Batería completa una sola vez, en el
   CI del PR (workflow `Quality`), no en tu máquina.
7. Cross-review sobre el SHA final del PR, desde el repo:
   `PATH=/opt/homebrew/bin:/Users/dn/.local/bin:$PATH pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto -Alcance last-commit`
   (muse no está en la cadena, no hay autorrevisión). Los hallazgos se corrigen en UNA ronda y se
   repite mientras la ronda anterior haya encontrado algo; lo que decides no atender se declara en
   el PR con razón.
8. Sin push a `main` y sin mergear el PR por ningún medio (ni CLI ni API): el lead mergea por la
   ruta del kit.
9. Todo comando que corras por tu cuenta en la Mac y necesite Homebrew: antepone
   `export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH`.

## 2. Tareas, en orden

### T1 — Runbooks fase 6 y 7: que no contradigan al kit ni al entorno
Archivos: `docs/runbooks/autopilot-fase6.md`, `docs/runbooks/autopilot-fase7.md`.

a) **Bootstrap explícito** (el atasco mayor de la noche). En fase 6, sección "Cómo se mergea,
   literalmente", el paso 1 dice que `saikit-setup-autopilot.sh` "va commiteado en el PR del
   carril, es lo que el gate lee de `origin/<default>`". Eso es imposible: el gate lee de
   `origin/<default>` y rechaza el PR que lo trae. Reemplazar por un **paso 0, antes de abrir
   cualquier carril**: por cada repo, un PR `bootstrap: .saikit/autopilot.json` con solo ese
   archivo (y `tests/run.sh` si `--wrap-runner si` lo genera), que **mergea David a mano** (el
   gate del kit lo rechaza por diseño y summa-gate bloquea el merge directo del lead). Hasta que
   esté en `origin/<default>`, ningún PR de ese repo entra a la cola. Agregar la fila
   correspondiente a la tabla "Cuando algo se atora": "config ausente en origin/<default>" →
   no es un ator del carril, es bootstrap pendiente; Telegram a David con la lista de repos.
b) **Sello de veredictos (D16/D18) visible**: en la misma sección, una línea que diga que
   `saikit-merge.sh` se corre desde la sesión viva armada con `-saikit:autopilot`, en el mismo
   host y con el mismo `project_root` (el estado del hook se llavea por `cksum` de esa ruta), y
   que un estado de otro host/otro revisor no sirve. Fase 6 ya dice parte de esto (línea ~156 y
   fila "sin estado del hook"); completa, no dupliques.
c) **Postgres sin Docker**: paso 6.6 y la fila "Postgres desechable" de la tabla de
   preaprobaciones (línea ~49) piden `docker run … postgres:16`. Sustituir por Postgres de
   Homebrew en `127.0.0.1:5433` con una base desechable (`createdb`/`dropdb` al terminar) y las
   mismas credenciales que `quality.yml`. Escribe el comando real y compruébalo en la Mac
   (`psql --version`, crear y borrar la base).
d) **glm = zcode**: fase 7, sección de roles, dice "GLM 5.3 … se lanza con `~/bin/glm` (Claude
   Code apuntado a `glm-5.3`)". Hoy `~/bin/glm` ejecuta `zcode`. Corregir ahí y en cualquier otra
   mención de "Claude Code apuntado a glm" en ambos runbooks. En las líneas del cross-review
   (`-Con auto -Excluir <ia>`), anotar que el candidato `glm` de la cadena es zcode.
e) **PATH en cada exec de la Mac**: donde los runbooks den comandos que claw ejecuta por `exec`
   en el nodo Mac (cross-review, `gh`, `pwsh`, `tmux`), que lleven el prefijo de PATH del
   guardrail 9 o ruta absoluta. No reescribas párrafos: agrega el prefijo.

**Prueba**: `scripts/tests/test-runbooks-no-contradicen-entorno.sh`. (1) Discrimina con
fixtures inline: marca "commiteado en el PR del carril", `docker run`, "Claude Code apuntado a
`glm`" y comandos `gh`/`pwsh`/`cross-review.ps1` sin prefijo de PATH ni ruta absoluta; deja
pasar las formas correctas y las prohibiciones ("nunca", "no usar"). (2) Corre el detector
sobre `docs/runbooks/*.md`. Debe estar en rojo con los runbooks de hoy y en verde después.
**Aceptación**: diff quirúrgico, prueba roja→verde con salida pegada en el PR, comando de
Postgres probado en la Mac.

### T2 — Skills de la Mac: la regla del PATH en un solo lugar
Archivos: `agents/main/agent/workshop-skills/mac-tmux-control/SKILL.md`,
`agents/main/agent/workshop-skills/mac-terminal-control/SKILL.md`,
`agents/implementer/agent/workshop-skills/mac-exec-detach-poll/SKILL.md`.

- Una regla, con su razón, en mac-tmux-control (sección de gotchas): "el exec del nodo sanea el
  PATH y **`pathPrepend` se ignora**; todo comando lleva
  `export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH;` al frente, o ruta
  absoluta". mac-terminal-control ya tiene una versión parcial (línea ~81, con
  `$PATH:/opt/homebrew/bin`, que deja fuera `~/.local/bin` y `~/bin`): unificar al mismo texto.
- Completar la lista "Tool paths on this node" (mac-tmux-control, paso 6): `/opt/homebrew/bin/gh`,
  `/opt/homebrew/bin/grok`, `/opt/homebrew/bin/zcode` (= `glm`), `/opt/homebrew/bin/qwen`,
  `/Users/dn/.local/bin/pwsh`, `/Users/dn/.local/bin/muse`, `/Users/dn/bin/glm`.
- Línea 8 de mac-tmux-control: "`glm`/`deepseek`/`kimi-claude` are Claude Code against other
  providers, so their pane runs `node` too" → `glm` ahora es zcode; verifica en la Mac qué
  `pane_current_command` muestra un pane de zcode (`/opt/homebrew/bin/tmux new-session -d -s
  glm-prueba /Users/dn/bin/glm` y `list-sessions -F '#{pane_current_command}'`; mátala después)
  y escribe lo medido, no lo supuesto.
- Los ejemplos con `gh pr checks` (líneas ~88 y ~91) llevan el prefijo.

**Prueba**: extender `scripts/tests/test-mac-tmux-control.sh` (o test nuevo, mismo estilo):
(1) la regla del PATH existe en las tres skills con el texto idéntico (ancla); (2) ninguna línea
de comando de esas skills invoca `gh`, `pwsh`, `grok`, `zcode`, `kimi`, `codex` o `tmux` sin
prefijo de PATH ni ruta absoluta (excepto dentro de prohibiciones); (3) discrimina con fixtures
inline. Rojo hoy, verde después.
**Aceptación**: prueba roja→verde; las skills siguen pasando `test-mac-tmux-control.sh` y
`test-browser-profile-flag.sh` (paso 3 de este último compara copias entre agentes: si tocas
una skill que existe en varios agentes, cámbiala en todas, idéntica).

### T3 — Cadena de modelos: repartir primaries (preparar, NO aplicar)
Archivos: `docs/patches/modelos-primaries-repartidos.json5` (nuevo), `docs/patches/README.md`,
`docs/patches/modelos-cadena-go-zen.json` (untracked, desactualizado).

- Propón una tabla donde **ningún proveedor sea primary de más de 2 agentes** y ninguna cadena
  repita proveedor entre primary y su primer fallback. Proveedores disponibles según la config
  viva: `opencode-go/*` (llave de pago, la que se agotó), `opencode/*` (free),
  `zai/glm-5.3`, `kimi/k3`, `xai/grok-4.6`, `anthropic/claude-sonnet-5`, `deepseek/*`. Regla de
  FASE B en `docs/patches/README.md`: leerla y respetarla. Regla nueva de David para esta
  tabla: `main` y `operaciones` (negocio) NO comparten primary con los agentes de pipeline.
- Cada id de modelo que uses debe existir: `~/.openclaw/bin/openclaw models list --json` (lectura
  remota, permitida). Pega la evidencia en el README (sección nueva, fechada) y en el PR.
- `modelos-cadena-go-zen.json`: reemplazarlo por lo vivo (salida real de `gateway call
  config.get`, solo `agents.entries.*.model` y `agents.defaults.model`) bajo el nombre
  `modelos-vivos-2026-09-15.json5`, o borrarlo; no dejes un archivo que diga lo que no es.
- **No apliques nada**: el patch se corre en Windows, en ventana muerta (memoria del lead:
  `config patch` con runs en vuelo mata los runs). Deja en el README el comando exacto de
  dry-run y de aplicación, y el rollback (`modelos-rollback.json5` ya existe; di si sigue
  vigente comparándolo con lo vivo).

**Prueba**: `scripts/tests/test-patch-modelos-repartidos.sh`: parsea el json5 (con `node -e` y
un strip de comentarios, o `python3` + `json5` si está; documenta cuál) y falla si un proveedor
es primary de >2 agentes, si `main`/`operaciones` comparten primary con un agente de pipeline,
o si una cadena repite proveedor en primary y primer fallback. Discrimina con un fixture malo.
**Aceptación**: archivo + tabla + evidencia de `models list` + prueba verde + comandos de
aplicación y rollback en el README. Cero cambios en el gateway.

### T4 — Borradores de issues upstream para OpenClaw 2026.9.4
Archivo: `docs/evidence/openclaw-2026.9.4-issues.md`. Cuatro issues, cada uno con: título,
versión, cadena exacta del error, archivo del `dist` donde nace, condición de disparo (leerla
en el código, no inventarla), impacto medido en la corrida y repro si se puede. Datos ya
encontrados por el lead:
1. `Session transcript projection is rebuilding: <sessionId>` —
   `session-accessor-*.mjs`, `withCurrentProjectionSnapshot`: se lanza si `needsRebuild`, si
   `indexedSeq != latestSeq` o si hay eventos sin clasificar; dispara
   `startSessionTranscriptIndexReconcile`. Impacto: ~8 latidos perdidos en la sesión del lead.
2. `execution identity admission envelope/token violates its bounded contract` —
   `execution-identity-admission-*.mjs`, `validateEnvelope`/`validateToken` (chequeo de esquema).
   Impacto: el primer spawn del lead murió; relanzamiento manual.
3. `incompatible Gateway bindings: bound and unbound owners` —
   `gateway-request-scope-*.mjs`, `getSharedGatewayContextResolver`: owners con y sin contexto
   de Gateway mezclados. Impacto: 2 fixers terminaron y su reporte no llegó.
4. Reportes de subagentes cortados por `MAX_LIVE_TOOL_RESULT_CHARS` (16e3/32e3/64e3 en
   `worker/worker.mjs`). Pedir que el resultado de `sessions_spawn` pueda devolver ruta a
   archivo; mientras, nuestra mitigación es que el subagente escriba el reporte a archivo.
No reportes `Task outside session tree`: es por diseño (el árbol de la sesión cambió al relanzar
el lead), no bug.
**Aceptación**: archivo con los 4, cada uno listo para pegar en GitHub. Sin prueba (es doc).

## 3. Fuera de alcance (no lo hagas)
- Correlacionar los cortes `COMPANION_APP_UNAVAILABLE` con los logs del gateway: lo hace el lead
  (requiere `openclaw logs` en Windows). Dato para el issue si aparece: OpenClaw.app de la Mac se
  reinició el 2026-09-15 a las 00:26 (los dos sockets de `~/.openclaw` datan de ahí).
- Instalar `summonaikit`, Docker, o cambiar plugins de zcode.
- Cualquier cambio en `/Users/dn/quality-kit` (ya está hecho y revisado).

## 4. Entrega
- Un PR contra `main` con título `fix(corrida-nocturna): runbooks sin contradicciones, PATH en
  skills de la Mac, patch de modelos repartidos, issues upstream`. Cuerpo: por tarea, qué cambió,
  la prueba (comando + salida roja y verde), y lo que decidiste no atender del cross-review.
- Reporte final al lead, en este orden y sin adornos: SHA del PR, URL, estado del CI, lista de
  tareas con `hecho`/`parcial`/`no hecho` y razón, hallazgos del cross-review atendidos y no
  atendidos, y cualquier cosa que hayas visto y no esté en este brief.
