# Runbook base de summonaikit-claude — lo que no cambia entre fases

Esto lo hereda **todo runbook de fase de `gon0801/summonaikit-claude`** desde la Fase 23. Vive en `goncloud-openclaw`, rama `main`, en `docs/runbooks/base-summonaikit.md`, y se lee con `git -C /Users/dn/dev/goncloud-openclaw show origin/main:docs/runbooks/base-summonaikit.md`. Un runbook de fase lo cita en su primer párrafo («Hereda `docs/runbooks/base-summonaikit.md` v<K>») y **no repite nada de lo que está aquí**: trae solo sus carriles con la DoD verbatim del plan, su tabla de archivos, su cola, sus atores propios y su inventario (≤ 120 líneas). Si una fase mide algo nuevo del repo, la corrección entra **aquí**, en el mismo PR que arregla la fase.

Versión 1, 2026-09-18. Lo que dice «medido» se midió en la Fase 23 de summonaikit-claude (PRs #331 a #342) o en las fases de Orbit y openclaw que se nombran.

**Cadena de mando**: `docs/runbooks/loop-autopilot.md` (salvo la tabla de preaprobaciones de cada fase y **salvo las desviaciones que este documento nombra en «Desviaciones»**) > `AGENTS.md` y `CLAUDE.md` de summonaikit-claude (con la misma salvedad) > `docs/spec/00-project-spec.md` > `Plans.md` > este documento > el runbook de la fase. El plan manda en el **qué** y en la DoD; los runbooks, en el **cómo**. Una contradicción entre el plan y un runbook la gana el plan y se declara en el PR; un runbook nunca edita el cuerpo de una fila, solo el ítem de cierre edita las celdas de estado.

---

## Quién

| Rol | Quién | Qué hace |
|---|---|---|
| **claw** | el agente `main` del gateway | Crea el worktree del lead, lo lanza, lo vigila por tmux (la sesión va marcada con `OPENCLAW_WATCH`) y lo relanza si se cae. Hace la limpieza del cierre que el lead no puede hacerse a sí mismo. Puede mergear y desplegar tras CI y CodeRabbit aprobados. |
| **lead** | un CLI en tmux de cualquier host del kit (sección 1 del loop), **sesión `<host>-wt-f<N>-saikit-lead` con cwd `/Users/dn/dev/wt-f<N>-saikit-lead`** | Escribe los encargos, implementa los carriles que la fase le asigna, audita, corre la cruzada, aprueba, despliega tras cada merge, mide en vivo, escribe progreso y cierra. |
| **implementador** | el token que la fase asigna al carril (`glm`, `cursor-agent`, `muse` o `grok`), **sesión `<token>-wt-f<N>-saikit-<carril>` con cwd `/Users/dn/dev/wt-f<N>-saikit-<carril>`**, un encargo a la vez por sesión | Escribe el código del carril en su rama, commitea con el pre-commit del repo y reporta con la línea de contrato. Puede abrir PRs, mergear y desplegar siguiendo las comprobaciones del repo. |
| **revisor cruzado** | otra IA por `cross-review.ps1` | Sección 4 del loop, con `-Excluir <token de quien implementó>` (cualquier nombre vale desde quality-kit #11; si implementó el lead, el nombre de su host). |
| **David** | el dueño | Recibe el resultado; los agentes completan merge y deploy sin pedir permisos adicionales. |

---

## Cómo se lanza cada cosa

Los scripts de openclaw se leen siempre de `origin/main`, porque su checkout suele estar en otra rama (medido: funcionan leídos por stdin):

```
OC=/Users/dn/dev/goncloud-openclaw; /opt/homebrew/bin/git -C $OC fetch -q origin
lanzar()  { /opt/homebrew/bin/git -C $OC show origin/main:scripts/lanzar-lead.sh      | bash -s -- "$@"; }
esperar() { /opt/homebrew/bin/git -C $OC show origin/main:scripts/esperar-contrato.sh | bash -s -- "$@"; }
T=/opt/homebrew/bin/tmux
```

**El lead** lo lanza claw, después de crear su worktree (`/opt/homebrew/bin/git -C /Users/dn/dev/summonaikit-claude worktree add --detach /Users/dn/dev/wt-f<N>-saikit-lead origin/master`):

```
lanzar -s <host>-wt-f<N>-saikit-lead -c /Users/dn/dev/wt-f<N>-saikit-lead \
  -m 'Lee docs/runbooks/autopilot-fase-saikit<N>.md en origin/main de goncloud-openclaw y ejecuta la Fase <N> de summonaikit-claude -saikit' \
  -p '<regex del prompt del host>' -- <cli-del-host> <flag-sin-preguntas>
```

Termina en `LISTO <sesión> <cwd>` o `ATORADO <razón>` (2: la sesión ya existía, `kill-session` y el mismo comando). El CLI, su flag y el regex de su prompt son los del lanzador de claw para ese host. `scripts/runbook.sh` del loop no localiza este runbook (solo acepta números): el lead lo lee con `git show`, como dice el mensaje.

**Un implementador** lo lanza el lead, con worktree propio y el encargo **fuera del repo** (`.saikit/` no está en el `.gitignore` de este repo y su rastro se versiona a propósito: un encargo adentro se commitea por error):

```
C=<carril>; W=/Users/dn/dev/wt-f<N>-saikit-$C; E=/tmp/f<N>-saikit/$C; mkdir -p $E
/opt/homebrew/bin/git -C /Users/dn/dev/summonaikit-claude worktree add $W -b fase<N>/$C origin/master
# escribir $E/BRIEF.md (sección 3 del loop, paso 1); después:
: > $E/contrato.txt
BIN=$(bash -c 'PATH=$HOME/bin:$HOME/.local/bin:$HOME/.grok/bin:/opt/homebrew/bin:$PATH; command -v <token>')
lanzar -s <token>-wt-f<N>-saikit-$C -c $W -m "Lee $E/BRIEF.md y haz lo que pide" -- "$BIN" <flag>
printf '%s %s %s\n' $C <token> <token>-wt-f<N>-saikit-$C >> /Users/dn/dev/wt-f<N>-saikit-lead/.saikit/progress/<N>-sesiones.txt
```

| Token | `<flag>` | Cómo se comprueba que entró, 10 s después (`$T capture-pane -p -t <sesión> -S -30`) |
|---|---|---|
| `glm` | `--mode yolo` | la barra de abajo dice `yolo` |
| `cursor-agent` | `-f --trust` | la pantalla no pregunta `Do you trust the contents of this directory?` |
| `muse` | `--yolo` | la barra termina en `YOLO` |
| `grok` | `--always-approve` | leído en `grok --help` el 2026-09-18; en tmux **no medido**: la pantalla no muestra un pedido de aprobación |

**Todo `BRIEF.md` y todo `BRIEF-r<K>.md` termina así**: «el rojo de una fila `[tdd:required]` va pegado en `/tmp/f<N>-saikit/<carril>/tdd.md`, fuera del repo; al terminar, imprime tu línea de contrato, `LISTO <sha>` o `ATORADO <razón en una línea>`, y escríbela, y solo esa, en `/tmp/f<N>-saikit/<carril>/contrato.txt`; commitea con rutas explícitas, nunca `git add -A` ni nada bajo `.saikit/`».

**Una corrección** (`BRIEF-r<K>.md`, sección 3 del loop, paso 5) va a la misma sesión viva: se escribe `$E/BRIEF-r<K>.md`, se vacía el contrato (`: > $E/contrato.txt`; `esperar` solo lee un archivo no vacío, y sin vaciarlo devuelve el `LISTO` viejo al instante, medido) y se manda `$T send-keys -t <sesión> -l "Lee $E/BRIEF-r<K>.md y haz lo que pide"` y **en llamada aparte** `$T send-keys -t <sesión> Enter`.

**La espera**: `esperar /tmp/f<N>-saikit/<carril>/contrato.txt -s <sesión> -t 1800`. Sale 0 con el contrato, 3 si la pantalla cambió (viva: se vuelve a esperar), 4 si quedó quieta y 5 si el archivo no trae `LISTO`/`ATORADO` (filas de atores). En un host sin segundo plano, la espera va en tramos de `-t 540` repetidos: ninguna herramienta espera más de 10 minutos seguidos.

---

## Dónde vive cada cosa

| Repo | Ruta local | Default | Copia desplegada |
|---|---|---|---|
| `gon0801/summonaikit-claude` | `/Users/dn/dev/summonaikit-claude` (checkout principal: durante la fase solo `fetch`, `worktree add/remove` y `branch -D`), `/Users/dn/dev/wt-f<N>-saikit-lead` (el lead y sus carriles), `/Users/dn/dev/wt-f<N>-saikit-deploy` (siempre en `origin/master`, solo para desplegar) y un worktree por carril de implementador | `master` | el hook en `~/.claude/hooks/` (claude; zcode y muse la reusan), `~/.grok/hooks/`, `~/.dsh/hooks/` y `~/.codex/hooks/`; el registro de Muse en `~/.config/muse/settings.json` y `~/.config/muse/agents/` |
| `gon0801/goncloud-openclaw` | `/Users/dn/dev/goncloud-openclaw` | `main` | el gateway, por sync: mergear ahí **es** desplegar (sección 7 del loop) |

Muse se mide con su binario versionado, nunca con la función `muse` del shell (abre tmux) ni con el lanzador (se actualiza solo): `M=/Users/dn/.local/bin/muse-bin-$(cat /Users/dn/.local/bin/.muse-version)`. Muse solo corre la copia desplegada del hook: todo lo vivo de una fila corre **después** de su merge y su deploy.

---

## Precondiciones comunes (paso 0.0 de toda fase)

```
test -r /Users/dn/dev/summonaikit-claude/tools/MANIFEST.sha256 || echo ATORADO kit ausente
/opt/homebrew/bin/git -C /Users/dn/dev/summonaikit-claude fetch -q origin
[ -d /Users/dn/dev/wt-f<N>-saikit-deploy ] || /opt/homebrew/bin/git -C /Users/dn/dev/summonaikit-claude worktree add --detach /Users/dn/dev/wt-f<N>-saikit-deploy origin/master
/opt/homebrew/bin/git -C /Users/dn/dev/wt-f<N>-saikit-deploy checkout -q --detach origin/master
cd /Users/dn/dev/wt-f<N>-saikit-deploy && bash tools/install-hook.sh --check | tail -1
cat /Users/dn/.local/bin/.muse-version
/opt/homebrew/bin/gh auth status 2>&1 | grep -c 'Logged in'
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw show origin/main:docs/runbooks/autopilot-fase-saikit<N>.md | head -1
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw show origin/main:docs/runbooks/loop-autopilot.md | grep -c 'Se repite mientras una ronda traiga un bloqueante'
[ -n "${TMUX_PANE:-}" ] && /opt/homebrew/bin/tmux display-message -p -t "$TMUX_PANE" '#S #{pane_current_path}'
F=/Users/dn/dev/wt-f<N>-saikit-lead/.saikit/progress/<N>-sesiones.txt; mkdir -p "${F%/*}"; { printf 'lead - %s\n' "$(/opt/homebrew/bin/tmux display-message -p -t "$TMUX_PANE" '#S')"; grep -v '^lead ' "$F" 2>/dev/null || true; } > "$F.tmp" && mv "$F.tmp" "$F"
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw show origin/main:scripts/arranque-de-fase.sh | REPO=/Users/dn/dev/summonaikit-claude REF=origin/master ARRANQUE_SIN_GATEWAY=1 bash -s <N>
```

Esperado, en orden: sin salida en las cuatro primeras; una línea que termina en `veredicto=ok (copias al dia; fuente = bytes de origin/master)`; la versión de Muse que la fase nombra; `1`; el título del runbook de la fase; `1`; `<host>-wt-f<N>-saikit-lead /Users/dn/dev/wt-f<N>-saikit-lead`; sin salida; y del arranque, `VERDE` en `plan`, `sesiones` y `lead`, `unknown` en `progreso` y `vigilantes` (ver «Desviaciones»). **Detienen la fase**: kit ausente, `gh` sin sesión, runbook o loop nuevos fuera de `main`, el lead fuera de tmux o con otro cwd (`ATORADO lead lanzado fuera de wt-f<N>-saikit-lead`: no se corrige con `cd`; claw relanza), o un `ROJO` del arranque. Un `--check` sin `veredicto=ok` no detiene: el lead despliega una vez (regla 6) y repite; si sigue, `ATORADO copias desalineadas`.

---

## Reglas de trabajo permanentes

1. **Una rama por carril, desde `origin/master` recién traído**: `fase<N>/<carril>`. Los carriles del lead van en su worktree (`/opt/homebrew/bin/git -C /Users/dn/dev/wt-f<N>-saikit-lead checkout -b fase<N>/<carril> origin/master`, con `git status --porcelain --untracked-files=no` sin salida antes: el progreso sin versionar no cuenta). Un carril que toca `hooks/summonaikit-harness.sh` arranca solo después de que el anterior que lo tocó quedó mergeado y desplegado, **o quedó `ATORADO`, con PR o sin él**: cada uno regraba el golden, y dos a la vez chocan. Al declarar `ATORADO` un carril de implementador, el lead mata la sesión de ese carril (`$T kill-session -t <token>-wt-f<N>-saikit-<carril>`) y deja su worktree y su rama para David, nombrados en el progreso. Un carril del lead no tiene sesión ni worktree propios: el lead commitea lo que haya, deja solo su rama (si existe) para David, nombrada en el progreso, y vuelve su worktree a `checkout --detach origin/master`. Un PR atorado queda abierto con su fila `blocked`, y el siguiente carril arranca desde `origin/master`. Antes de arrancar cada carril y antes del PR de cierre, el lead mira cada PR atorado (`/opt/homebrew/bin/gh pr view <pr> --repo gon0801/summonaikit-claude --json state --jq .state`); si dice `MERGED`, aplica deploy y limpieza (reglas 6 y 7), su fila se cierra por su DoD en el PR de cierre, y el carril que siga abierto mergea `origin/master` y regraba el golden (regla 4).
2. **Pruebas focalizadas contra el hook del árbol, no el desplegado** (medido en el #337: sin la variable, las pruebas usan `~/.claude/hooks/` y dan rojos falsos): `SAIKIT_HOOK_VIVO=$PWD/hooks/summonaikit-harness.sh bash tests/test_gate_behavior.sh` y, para las mutaciones nuevas, `SAIKIT_HOOK_VIVO=$PWD/hooks/summonaikit-harness.sh SAIKIT_MUTACIONES='<G>|<nombre>|<desc>' bash tests/test_gate_mutations.sh`. La batería completa la corre el CI del PR (el check `gate` agrega todos los jobs); en local nunca entera.
3. **Todo arreglo trae su caso y su mutación**: el caso en `tests/lib/gate_cases.sh` y **en su lista `CASOS_G<n>`** (un caso fuera de la lista no corre), la mutación en `tests/test_gate_mutations.sh`, y el caso falla contra `origin/master` antes del arreglo (se pega la salida roja en el PR).
4. **Golden, en este orden**: antes de regrabar, `bash tools/golden-harness.sh --check --hook "$PWD/hooks/summonaikit-harness.sh"` contra la línea base de `master` y se guarda su lista de `DIVERGENCIA`; después `bash tools/golden-harness.sh --record`. El PR pega esa lista y la clasifica: encabezado y las salidas que el cambio explica, nada más. (Un `--check` después de `--record` sale `OK` por construcción y no prueba nada, medido.)
5. **Commits**: pre-commit siempre, jamás `--no-verify`; el scope es un área (`fix(hook): …`), nunca un número de fila. Usa el flujo normal de GitHub. Los carriles del lead commitean su rastro (`.saikit/decisiones/fase<N>-<carril>.tsv` y `.saikit/findings/blast-fase<N>-<carril>.json`): el repo lo versiona.
6. **Deploy tras cada merge que toque `hooks/`, `tools/`, `agents/` o `recetas/`**, en `/Users/dn/dev/wt-f<N>-saikit-deploy`: `checkout -q --detach origin/master` tras un `fetch`, y en ese cwd `bash tools/install-hook.sh`, `--host grok`, `--host dsh`, `--host codex`, `--host muse`; después `--check` (`veredicto=ok`, cinco filas) y `bash tools/check-hook-registration.sh` (sin salida). Los nombres de backup que imprime el instalador se guardan en `/tmp/f<N>-saikit/deploys.txt` para el deploy-log del cierre.
7. **Merge por cualquier agente.** Con CI y CodeRabbit aprobados, ejecuta `gh pr merge <pr> --squash --match-head-commit <sha>`. Comprueba `MERGED`, despliega lo que corresponda por la regla 6 y limpia el worktree después de verificarlo. No esperes una orden del dueño.
8. **Medición viva en Muse** (solo el lead, con la preaprobación de la fase, y siempre después del merge y el deploy de lo que mide): repo desechable `R=/tmp/f<N>-saikit/vivo-<k>`, sembrado con `git init -q`, un `README.md`, un `tests/run.sh` ejecutable que corre la prueba del pedido, y un commit inicial; el prompt en archivo (Muse lee un prompt que empieza con `-` como opción); `cd $R && "$M" exec --trust-workspace --disable-approval --user-input-auto-resolve --max-model-steps 80 --json --prompt-file <archivo>`, más `--reasoning-effort <esfuerzo>` si la fila lo pide; y `"$M" export --session <id> --out <archivo>`. La evidencia se guarda redactada: ninguna ruta `/Users/` ni `/private/tmp/`.
9. **Rondas cruzadas**: sección 4 del loop, con cwd en el worktree del carril (el del lead para sus carriles): ronda 1 `/Users/dn/.local/bin/pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto -Excluir <token> -Alcance last-commit`; las siguientes `-Con <otro> -Excluir <token> -Desde <sha que vio la anterior>`. El «revisor fresco» que pida una fila es la ronda cruzada; si la fila pide los dos, se suma un subagente del host del lead con contexto limpio. CodeRabbit con cuota agotada («Review limit reached») se anota en el PR y se le pide `@coderabbitai review` cuando haya cuota; ese PR espera su aprobación y los demás carriles continúan. La promoción del paso 6 del loop es `/opt/homebrew/bin/gh pr ready <pr> --repo gon0801/summonaikit-claude`.
10. **Progreso**: en cada cambio de estado y al cierre, `/Users/dn/dev/wt-f<N>-saikit-lead/.saikit/progress/<N>.json` (`runbook-progress.v1`, con `"fase": "saikit-<N>"` para no chocar con la fase <N> de otro repo en el gateway), un intento que no bloquea (`/opt/homebrew/bin/timeout 60 ~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat …)" --json | head -c 200`) y el JSON como comentario en el PR del lead abierto más reciente (antes del primer PR, solo el archivo). El ítem de cierre commitea una copia en `.saikit/progress/<N>.json`, como pide el spec de `runbook-progress.v1`.
11. **Se reporta, no se relaya**: cada carril y la fase cierran con `LISTO <sha>` o `ATORADO <razón>` (sección 2 del loop).

---

## Desviaciones del loop y de `AGENTS.md`, nombradas

- **§1 del loop**: el lead implementa los carriles que la fase le asigna (la medición viva y los cambios del gate que se miden en el propio host).
- **§2**: el arranque corre con `ARRANQUE_SIN_GATEWAY=1` y el cierre con `CIERRE_SIN_GATEWAY=1`: estas fases no registran tablero en el gateway ni crean los crons de seguimiento (cambios de configuración del gateway que ninguna fase de este repo tiene aprobados; el seguimiento de la Fase 9 no está mergeado). Las líneas `progreso`, `vigilantes` y `tablero` salen `unknown`, declaradas. El aviso a David son los comentarios de merge en cada PR.
- **§3 paso 1**: el encargo va en `/tmp/f<N>-saikit/<carril>/`, no en la raíz del worktree (ver «Cómo se lanza»). **Paso 2**: el rojo de `[tdd:required]` va en `/tmp/f<N>-saikit/<carril>/tdd.md`, fuera del repo, por la misma razón. **Paso 3**: el lead no corre la batería entera en local; la corre el CI (regla 2).
- **§2 y §10**: la línea final del lead va antes de la limpieza de claw (su sesión y su worktree no los puede quitar él); claw corre el script tras su limpieza; si una línea nombra algo de la fase que el progreso no deja para David, lo quita (`kill-session`, `worktree remove` sin `--force`, `branch -D`) y lo corre otra vez, hasta tres vueltas; si un `worktree remove` se niega, guarda su `status --porcelain` en `/tmp/f<N>-saikit/restos-claw.txt` y lo deja para David en un comentario del PR de cierre.
- **§12**: la regla 7 quita sesión, worktree y rama local de cada carril tras su merge (`kill-session`, `git worktree remove`, `branch -D`, nunca `rm -rf`). Una corrección de la revisión de cierre del §10 va en una rama nueva `fase<N>/<carril>-r`, con worktree y sesión nuevos si el carril es de un implementador, o en el worktree del lead si es suyo, y con la fila de archivos de su carril. Las sesiones TUI de medición que una fase crea con `new-session` no se marcan: el lead las maneja en primer plano, anota su nombre en `/tmp/f<N>-saikit/tui.txt` y las mata al guardar la evidencia; la reanudación y el cierre matan (`$T kill-session`) las que ahí sigan vivas antes de crear otra.
- **§6**: merge normal de GitHub por cualquier agente (regla 7).
- **`AGENTS.md`, «Deploy tras merge»**: se despliega desde el worktree de deploy y no desde un `checkout master` del principal; el deploy-log se escribe una vez, en el cierre, con todos los deploys de la fase.

---

## Cierre

El ítem de cierre es un PR `fase<N>/cierre` del lead: las celdas de estado de `Plans.md` (`cc:完了` con PR, merge y run, o `cc:TODO — blocked: <razón>`), la entrada de `docs/deploy-log.md` con los deploys de `/tmp/f<N>-saikit/deploys.txt` (`bash tools/check-deploy-log.sh` → OK), la copia del progreso y `.saikit/progress/<N>-sesiones.txt`, y `bash tests/test_plans_ledger.sh` → OK. Tras verificar CI y CodeRabbit del SHA actual, cualquier agente mergea; confirmado `MERGED` y el SHA integrado, el lead corre:

```
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-openclaw show origin/main:scripts/cierre-de-fase.sh | REPO=/Users/dn/dev/summonaikit-claude REF=origin/master CIERRE_SIN_GATEWAY=1 bash -s <N>
```

El progreso que va en el PR de cierre corresponde al SHA actual del PR y registra sus checks de CI y revisión de CodeRabbit, con `cierre.at`; desde ese punto el progreso se escribe solo en `/tmp/f<N>-saikit/<N>.json`, de donde salen el envío al gateway y el comentario en el PR, nunca en el worktree del lead. Antes de la línea final, `git -C /Users/dn/dev/wt-f<N>-saikit-lead checkout -- .saikit/progress/`; si `status --porcelain` todavía imprime algo, se mueve con `mv` a `/tmp/f<N>-saikit/restos-lead/` (nunca `rm`) y se nombra en el progreso. Después, `git -C /Users/dn/dev/wt-f<N>-saikit-lead status --porcelain` no imprime nada, y va la línea `CIERRE PENDIENTE DE CLAW: <los dos worktrees del lead>, rama fase<N>/cierre, sesion <sesión del lead>`.
- `LISTO <sha del merge de cierre>` si `plan`, `despliegue` y `ci` salen `VERDE`, `tablero` `unknown`, y `ramas`, `worktrees` y `sesiones` en `ROJO` nombran **solo** `fase<N>/cierre`, `/Users/dn/dev/wt-f<N>-saikit-lead`, `/Users/dn/dev/wt-f<N>-saikit-deploy` y la sesión del lead. Si `ci` no sale `VERDE`, se espera la corrida del merge de cierre hasta que termine, sin tope propio (cada job del workflow tiene el suyo de 30 minutos): `R=$(/opt/homebrew/bin/gh run list --repo gon0801/summonaikit-claude --branch master --limit 1 --json databaseId --jq '.[0].databaseId'); /opt/homebrew/bin/gh run watch $R --repo gon0801/summonaikit-claude --exit-status`. Si termina `cancelled`, `gh run rerun $R --repo gon0801/summonaikit-claude --failed` una vez y otra vez `gh run watch`; cualquier otro resultado que no sea `success`, o un rerun que repite, es `ATORADO ci de master en rojo tras el cierre`, y la fila nueva que pediría la fila de `suite-lentos` queda como pendiente para David en el progreso, no en un PR.
- `ATORADO fase <N> con filas bloqueadas: <ids>` si `plan` sale `ROJO` por filas `blocked`, con `atencion_requerida` y la razón de cada una. La fase no se declara cerrada: esas filas, y sus ramas y worktrees, quedan para David, nombrados en el progreso.

Claw, después de la línea final y sin kit, en los dos casos: `$T kill-session -t <sesión del lead>`, `git -C /Users/dn/dev/summonaikit-claude worktree remove` de los dos worktrees del lead, `git -C /Users/dn/dev/summonaikit-claude branch -D fase<N>/cierre`, y el script otra vez.

---

## Cuando algo se atora (universales de summonaikit)

| Situación | Qué hace el lead |
|---|---|
| Una prueba local sale roja y en CI verde, o al revés | Se confirma `SAIKIT_HOOK_VIVO` (regla 2). `test_golden_baseline` y `test_hook_source` comparan con la copia instalada: dan rojo hasta el deploy, esperado. |
| Un job `suite-lentos` sale `cancelled` a los 30 min | `/opt/homebrew/bin/gh run rerun <id> --repo gon0801/summonaikit-claude --failed` una vez; si repite, `ATORADO ci` y una fila nueva en el plan (re-elegir N shards, sin recortar). |
| El hook niega un comando por `gh pr merge`, por `push` junto a `master` o por nombrar el script de merge | Se reescribe: literal partido (regla 7) o comandos separados. |
| `lanzar` sale 3 (cwd distinto), 4 (sin prompt) o 5 (el mensaje no entró) | `kill-session` y el mismo comando una vez; si repite, el carril queda `atorado` con la salida. |
| El mensaje quedó escrito en la caja del implementador sin enviarse (la captura lo muestra en la última línea) | `$T send-keys -t <sesión> Enter`, una vez. |
| `esperar` sale 3 | Se vuelve a esperar sin reenviar. |
| `esperar` sale 4 o 5 | `$T has-session -t <sesión>`: si la sesión no existe, se relanza con el mismo encargo (sección 12 del loop); si existe, se revisa el modo sin preguntas en la barra y se reenvía la instrucción una vez; si repite, el carril queda `atorado`. |
| Un implementador pide permiso | Se contesta con la tabla de preaprobaciones: lo aprobado se acepta, lo negado y lo que no está se rechazan y van al progreso. |
| Muse se actualizó solo (la versión no es la de la fase) | Se anota en la evidencia y se sigue; si un evento del hook cambió de forma, fila nueva en el plan. |
| `runbook.progress.set` contesta `ok: false` | Esperado (§2 en «Desviaciones»): el comentario en el PR es la fuente. |
| Reanudación: el lead murió | Claw relanza (tras `kill-session`) y el nuevo lead corre el 0.0. El estado: `gh pr list --repo gon0801/summonaikit-claude --search "head:fase<N>/" --state all --json number,headRefName,state`, el último comentario de progreso, `/tmp/f<N>-saikit/` y `<N>-sesiones.txt`. Un encargo con contrato vacío se espera con `esperar`. |

**La fuente es este archivo.** Cualquier copia en una página web es eso, una copia, y lo dice en su pie.
