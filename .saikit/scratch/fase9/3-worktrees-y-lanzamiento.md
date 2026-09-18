# Fase 9 — Worktrees y lanzamiento de implementadores (guía del lead en la Mac)

Todo comando se corre desde `/Users/dn/dev/wt-f9-lead` salvo donde diga otra ruta.
`openclaw` = `~/.openclaw/bin/openclaw`. tmux = `/opt/homebrew/bin/tmux`.

## Arranque (runbook "Dónde te paras")

```bash
cd /Users/dn/dev/goncloud-openclaw && git fetch origin
git worktree list                      # ANTES de crear nada
git worktree add /Users/dn/dev/wt-f9-lead --detach origin/main
cd /Users/dn/dev/wt-f9-lead
```

Tras **cada** merge de la cola: `git fetch origin && git checkout --detach origin/main`
(los no-trackeados —progreso, evidencia— sobreviven). `git worktree add` falla si la ruta
existe: **nunca `--force`**. Ruta de la tabla con `rev-parse --abbrev-ref HEAD` = su rama
(o `HEAD` en detached) → se reúsa con lo que tenga. Otra rama → trabajo ajeno (fila de atores).
Comprobación de limpieza de `wt-f9-lead` (debe salir vacía):

```bash
git -C /Users/dn/dev/wt-f9-lead status --porcelain | grep -v -E '^\?\? (\.saikit/|docs/evidence/fase9-|BRIEF)'
```

| Worktree | Ruta | Rama |
|---|---|---|
| lead | `/Users/dn/dev/wt-f9-lead` | detached en `origin/main` |
| N | `/Users/dn/dev/wt-f9-N` | `fase9/nucleo` |
| M | `/Users/dn/dev/wt-f9-M` | `fase9/mensajes` |
| P | `/Users/dn/dev/wt-f9-P` | `fase9/politica` |
| D | `/Users/dn/dev/wt-f9-D` | `fase9/docs` |
| revisión por commit | `/Users/dn/dev/wt-f9-rev` | detached en el SHA (se crea y borra por revisión; si existe al crear, usar `wt-f9-rev-b`) |
| corrección | `/Users/dn/dev/wt-f9-fix` | `fase9/fix-<carril>` |
| reversa | `/Users/dn/dev/wt-f9-revert` | `fase9/revert-<carril>` |
| cierre | `/Users/dn/dev/wt-f9-cierre` | `fase9/cierre` |

Orden: **N solo primero** (`git worktree add /Users/dn/dev/wt-f9-N -b fase9/nucleo origin/main`).
**M y P en paralelo cuando N mergee** (archivos disjuntos). **D cuando M y P cierren**
(mergeados o `atorado`). Nunca más de tres PRs propios abiertos. Al quedar mergeado/`atorado`:
desmarcar su sesión (`set-environment -t <sesión> -u OPENCLAW_WATCH`) y dejarla abierta.

## Cómo se lanza un implementador (literal del runbook)

| Token | Flag sin preguntas | Comprobación a los 10 s |
|---|---|---|
| `glm` (zcode) | `--mode yolo` | la barra dice `yolo` (sin flag dice `build`) |
| `cursor-agent` | `-f --trust` | la pantalla **no** trae `Do you trust the contents of this directory?` y sí muestra su caja |
| `muse` | `--yolo` | la barra termina en `YOLO` |

```bash
T=/opt/homebrew/bin/tmux
BIN=$(bash -c 'PATH=$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH; command -v <token>')
S=<token>-wt-f9-<carril>
$T has-session -t "$S" 2>/dev/null && echo YA-EXISTE || \
  $T new-session -d -s "$S" -x 200 -y 50 -c /Users/dn/dev/wt-f9-<carril> "PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:\$PATH $BIN <flag>"
$T has-session -t "$S"; echo viva=$?
$T set-environment -t "$S" OPENCLAW_WATCH 1
n=0; until [ $n -ge 5 ]; do n=$((n+1)); sleep 2; done
$T capture-pane -p -t "$S" | grep -v '^[[:space:]]*$' | tail -4
```

`<token>` = primero de la preferencia del carril con `command -v` válido. Preferencias:
N → `glm`, `cursor-agent`, `muse`. M → `cursor-agent`, `glm`, `muse`.
P → `glm`, `cursor-agent`, `muse`. D → `muse`, `cursor-agent`, `glm`.
(`muse`/`cursor-agent` no son candidatos a revisor: con ellos `-Excluir ''`.)
`YA-EXISTE` + sesión en `9-sesiones.txt` → se reúsa; si no está → nombre con `-b`.
`viva != 0` → correr `"$BIN" --help` para leer el error, no reintentar a ciegas.
Captura sin comprobación → matar esa sesión recién creada y recrear; a la segunda, siguiente token.
Anotar `<carril> <token> <sesión>` en `.saikit/progress/9-sesiones.txt` + espejo (regla 4),
entregar el encargo **como archivo** (`encargo-<carril>.md` de este mismo directorio):

```bash
$T send-keys -t "$S" -l 'Lee /Users/dn/dev/wt-f9-<carril>/BRIEF.md y haz lo que pide'
$T send-keys -t "$S" Enter
n=0; until [ $n -ge 5 ]; do n=$((n+1)); sleep 2; done
$T capture-pane -p -t "$S" | grep -v '^[[:space:]]*$' | tail -6
```

`Enter` en llamada aparte; si la caja sigue con la frase → **un** `Enter` más. Arrancó cuando la
captura muestra que leyó el archivo. Después: armar la espera ("Quién te despierta").

## Cláusulas obligatorias de todo encargo (a–k del runbook)

(a) no limpies: nada de `rm -rf` ni borrados recursivos, ni bajo `/tmp`; usa `mktemp -d` y deja
lo que crees · (b) ninguna prueba manda Telegram real ni evento real: `OPENCLAW_BIN` apunta a un
stub que solo anota argumentos, tmux propio con servidor propio (`-L`) · (c) compatible con
`/bin/bash` 3.2 de macOS · (d) cada prueba imprime `TODO VERDE: <nombre>` al pasar · (e) todo
script encuentra a sus hermanos relativo a sí mismo (`$(dirname "$0")`): instalado vive en
`~/bin/corrida.sh` + `~/bin/corrida/`, no en el repo · (f) el rojo de cada tarea va en
`.saikit/scratch/<carril>/tdd.md` · (g) correcciones como commits nuevos `fix(9.x): …`, nunca
amend · (h) no instalar ni tocar `~/bin`, `~/Library/LaunchAgents`, `launchctl` (instala el lead
en Q4) · (i) lanzadores `~/bin` con 700 (`glm`, `glm-claude`, `deepseek`, `kimi-claude`) tienen
tokens: se ejecutan, jamás se leen ni se pegan · (j) no hacer push ni abrir PR · (k) la fila de
su carril de la tabla de archivos (abajo), copiada.

## Archivos por carril (k)

- **N** puede: `scripts/mac/corrida.sh`, `scripts/mac/corrida/{lib,abrir,lanzar-sesion,cerrar,preflight}.sh`,
  `scripts/mac/cli-modos.tsv`, `docs/spec/corrida.v1.md`, `docs/spec/seguimiento.v1.md`, sección
  "Corridas autónomas" de `docs/spec/00-project-spec.md`, `scripts/tests/test-corrida-nucleo.sh`,
  `test-corrida-preflight.sh`, `test-cli-modos.sh`, `scripts/tests/fixtures/corrida/`,
  `scripts/tests/fixtures/tui-falso.sh`. No toca: vigilante, loop, skills, `Plans.md`.
- **M** puede: `scripts/mac/corrida/{estado,latido}.sh`,
  `scripts/mac/ai.goncloud.corrida-latido.plist`, `test-corrida-estado.sh`, `test-corrida-latido.sh`,
  `scripts/tests/fixtures/estado/`. No toca: lo de N/P (solo **usa** `lib.sh` y `cli-modos.tsv`),
  vigilante, `scripts/sync-repos.ps1`. Además: el latido ignora directorios de
  `~/.local/state/corridas/` sin registro `corrida.v1` válido; reloj y binario openclaw inyectables.
- **P** puede: `scripts/mac/corrida/responder.sh`, `scripts/mac/tmux-activity-watch.sh`,
  `test-corrida-responder.sh`, `test-tmux-activity-watch.sh` (**solo agregar** casos),
  `scripts/tests/fixtures/dialogos/`. No toca lo de N/M (solo usa `lib.sh` y `cli-modos.tsv`).
  Además: `responder` nace apagado (`responder.on`); enganche del vigilante de este carril (con
  apagado/ausente el vigilante se comporta como hoy); vigilante anexa eventos a
  `~/.local/state/tmux-activity-watch/eventos.jsonl`; fixtures
  `dialogos/confianza.txt` y `dialogos/permiso-push.txt` (permiso `git push origin main`).
- **D** puede: `docs/runbooks/loop-autopilot.md`, `docs/runbooks/guia-del-vigia.md`,
  `docs/agent-skills/autopilot-runbook/SKILL.md` + copia `~/.claude/skills/autopilot-runbook/SKILL.md`,
  `agents/main/agent/workshop-skills/{agent-dispatch,mac-tmux-control}/SKILL.md`,
  `test-loop-autopilot.sh`, `test-runbooks-no-contradicen-entorno.sh`,
  `test-skill-autopilot-runbook.sh`, `test-guia-del-vigia.sh`, parte (4) de anclas de
  `test-tmux-activity-watch.sh`, y solo si un ancla suya cambió: los
  `test-{mac-tmux-control,agent-dispatch-no-merge,agent-dispatch-spawn,mac-path-regla,camino-feliz,saikit-cierre-pr-merge-owner}.sh`.
  No toca: código bajo `scripts/mac/`, ningún `docs/runbooks/autopilot-*.md`.
  **Cada vez que D edite la skill del repo, la copia entera a `~/.claude/…` antes de commitear.**
- Todos pueden escribir además `.saikit/scratch/<su carril>/` (sí se commitea, loop §3 paso 2).

Si un carril necesita archivo fuera de su fila: no lo toca, lo reporta; el lead manda
`BRIEF-r<N>.md` al carril dueño (2 h, sin TIMEBOX nuevo); si el dueño mergeó → corrección tras
merge (`wt-f9-fix`, `fase9/fix-<carril>`, loop §3 completo, máx 2 por fase).
