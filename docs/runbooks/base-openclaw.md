# Runbook base de openclaw — lo que no cambia entre fases

Esto lo hereda **todo runbook de fase de `gon0801/goncloud-openclaw`**. Un runbook de fase lo cita en su primer párrafo («Hereda `docs/runbooks/base-openclaw.md` v<K>») y **no repite nada de lo que está aquí**: trae solo sus carriles con la DoD verbatim del plan, su tabla de archivos, su cola con compuertas, sus atores propios y su inventario (≤ 120 líneas). Si una fase mide algo nuevo del repo, la corrección entra **aquí**, en el mismo PR que arregla la fase.

Versión 1.2, 2026-09-22 UTC. Destilada de las fases 6, 7 y 9 y actualizada tras integrar entrega-sin-sello A en SummonAIKit (`81aa8ff`); la 1.2 aclara el `-Alcance last-commit` que conservan como historia los runbooks de las fases 6 y 7. Todo lo que dice «medido» conserva su fecha y lugar en los documentos citados.

**Cadena de mando**: `docs/runbooks/loop-autopilot.md` (salvo la tabla de preaprobaciones de cada fase) > el spec del módulo > `Plans.md` > este documento > el runbook de la fase. El plan manda en el **qué** y en la DoD; este documento y el de la fase mandan en el **cómo**. Una contradicción entre el plan y un runbook la gana el plan y se declara como residual en el PR; un runbook nunca edita el cuerpo de una fila del plan, solo el ítem de cierre edita celdas de estado.

---

## Quién

| Rol | Quién | Qué hace |
|---|---|---|
| **claw** | el agente `main` del gateway | Elige al lead de su lista de preferencia y lo lanza con `scripts/lanzar-lead.sh`. Lo vigila por tmux y lo relanza si se cae. Le presta su exec para los comandos del host Windows. **No mergea, no despliega y no toca la configuración del gateway por su cuenta.** |
| **lead** | **un rol, nunca un nombre de modelo**: cualquier CLI que Claw pueda lanzar de forma verificada en tmux; Claw elige por preferencia y disponibilidad y puede relevarlo a mitad de fase | Spike, encargos (`BRIEF.md`), lanzar implementadores, auditar, revisión cruzada, publicar el recibo, mergear por la ruta del kit, desplegar, escribir progreso, cerrar y mandar los mensajes a David. **No escribe código de producto**; sí implementa los carriles de solo lectura que el plan le asigne. |
| **implementador** | un CLI propio en su propia sesión de tmux y su propio worktree, **uno por carril**; con modo sin preguntas medido: `glm` (zcode), `cursor-agent`, `muse` | Escribe el código de su carril en su rama y reporta con la línea de contrato (`LISTO <sha>` / `ATORADO <razón>`). **No hace push ni abre PR.** Dos carriles pueden usar el mismo token a la vez: son sesiones y worktrees distintos. |
| **revisor cruzado** | otra IA por `/Users/dn/quality-kit/cross-review.ps1` | Segunda opinión sobre el SHA del PR. **Nunca el modelo que implementó.** Quién implementó cada carril se escribe con esa palabra exacta en el cuerpo de su PR: de ahí sale el `-Excluir`. |
| **CodeRabbit** | bot en GitHub | Revisa cada PR. Sin cuota o sin respuesta **no bloquea**, pero se declara en el PR. |
| **David** | el dueño | No está al teclado y no se le pregunta nada para decidir. Lee los mensajes. **Su única acción posible: contestar un `NECESITO TU RESPUESTA`** — y aun así la corrida **no lo espera parado**: sigue con todo lo demás. |

**Por qué el lead es un rol** (medido, `loop-autopilot.md` §1): disponibilidad y cuota cambian durante una corrida. La entrega vive en el PR como recibo persistente, así que otro host puede retomar el mismo head sin repetir una revisión válida.

---

## Cómo se lanza cada cosa

**El lead** lo lanza claw con el script, nunca a mano (medido: el cwd correcto permite localizar worktrees y contratos, y un `send-keys` a un TUI que todavía no tomó el teclado se pierde sin rastro):

```
bash scripts/lanzar-lead.sh -s fase<N>-lead -c /Users/dn/dev/wt-f<N>-lead \
  -m 'Lee docs/runbooks/autopilot-fase<N>.md en origin/main de goncloud-openclaw y ejecuta la Fase <N>; tu primer paso es 0.0 -saikit:autopilot' \
  -p '<regex del prompt del host>' -- <cli-del-host> <flag-sin-preguntas>
```

Imprime, en orden: `marca=OPENCLAW_WATCH=1`, `cwd=<ruta>` (el del **proceso**), `proceso=<args del pane_pid>` (aquí se ve si el flag entró), `prompt=ok (<n>s)`, y `LISTO <sesion> <cwd>` o `ATORADO <razón>`. Códigos: `0` ok · `1` uso o cwd inválido · `2` la sesión ya existía (`kill-session` antes de relanzar) · `3` cwd del proceso distinto · `4` sin prompt en `-t` segundos (default 60) · `5` el mensaje no salió en pantalla en 20 s. `TMUX_BIN` (default `/opt/homebrew/bin/tmux`) y `PATH_LEAD` se fijan por entorno.

**El sentinel `-saikit:autopilot`** arma las instrucciones de ejecución del turno. No acredita revisión ni merge: esa autoridad es el último comentario aplicable `APPROVE lead <sha>` con recibo `saikit-entrega.v1` en el PR.

**Los implementadores.** El binario se resuelve **en `bash`, no en la shell propia** (medido: el arranque de zsh define una función con el nombre de cada herramienta, exista o no el ejecutable, así que ahí `glm`, `cursor` y `muse` siempre responden 0 y la rama «AUSENTE» nunca se alcanza):

```
BIN=$(bash -c 'PATH=$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH; command -v <token>')
T=/opt/homebrew/bin/tmux; S=<token>-wt-f<N>-<carril>
$T has-session -t "$S" 2>/dev/null && echo YA-EXISTE || \
  $T new-session -d -s "$S" -x 200 -y 50 -c /Users/dn/dev/wt-f<N>-<carril> "PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:\$PATH $BIN <flag>"
$T set-environment -t "$S" OPENCLAW_WATCH 1
$T capture-pane -p -t "$S" | grep -v '^[[:space:]]*$' | tail -4
```

El `PATH=` va **dentro** del comando de la sesión, con el `$` escapado (medido desde el PATH mínimo del exec del gateway: con `"$BIN"` a secas la sesión nace con rc=0 y muere en segundos, porque `~/bin/glm` arranca con `env node`). La captura va sin líneas en blanco: tmux devuelve la pantalla entera y con `tail -4` a secas sale vacía. El encargo se entrega **siempre como archivo**, con el `Enter` en llamada aparte (en el mismo envío se lo traga el TUI):

```
$T send-keys -t "$S" -l 'Lee /Users/dn/dev/wt-f<N>-<carril>/BRIEF.md y haz lo que pide'
$T send-keys -t "$S" Enter
```

**El flag sin preguntas de cada CLI, y el observable que prueba que entró** (leído de la ayuda de cada binario el 2026-09-17):

| Token | Binario | Flag | Observable a los 10 s |
|---|---|---|---|
| `glm` | zcode, por el lanzador `~/bin/glm` | `--mode yolo` | la barra de abajo dice `yolo`; **sin flag dice `build`** |
| `cursor-agent` | el CLI de Cursor — **no `cursor`**, que muere con «No Cursor IDE installation found» | `-f --trust` | la pantalla **no** trae `Do you trust the contents of this directory?` y sí su caja de texto |
| `muse` | `/Users/dn/.local/bin/muse` | `--yolo` | la barra **termina en `YOLO`** |
| host del lead | el CLI que claw eligió | `unknown`: los runbooks solo dicen «el modo de permisos que no pregunta de ese host» | `unknown` |

Si el flag no aparece, se mata esa sesión recién creada (todavía no tiene contexto que perder) y se recrea con el flag; a la segunda, siguiente token. **Nunca se adivina un flag**: `<token> --help 2>&1 | grep -i -E 'permission|approve|force|yolo|sandbox|trust'` (la palabra `trust` va a propósito: sin ella la búsqueda encuentra los de `glm` y `muse` pero **no** el de `cursor-agent`). Si de verdad no ofrece ninguno, el carril se lanza sin flag y el lead contesta las aprobaciones con `send-keys` usando la tabla de preaprobaciones. Por qué es regla y no estilo (medido 2026-09-17, primera corrida de la Fase 7): los dos carriles arrancaron sin flag, `glm` quedó en `build` pidiendo permiso por cada lectura, `muse` pidió permiso **25 veces** para el mismo destino de red, y **un carril pasó 7 horas detenido en un prompt**.

**La espera del contrato** es por archivo, con el script (medido: el implementador imprime con sangría y la pantalla conserva el eco del brief y el `LISTO` del encargo anterior, así que un `grep` del `capture-pane` o no ve nada o ve una línea falsa):

```
rm -f /Users/dn/dev/wt-f<N>-<carril>/.saikit/scratch/<carril>/contrato.txt   # antes de mandar el encargo
bash scripts/esperar-contrato.sh /Users/dn/dev/wt-f<N>-<carril>/.saikit/scratch/<carril>/contrato.txt -s <sesión tmux>
```

Devuelve la línea de contrato (código 0), `SIN-CONTRATO VIVA` (3: la pantalla cambió, sigue vivo; se renueva la espera, **no se reenvía**), `SIN-CONTRATO QUIETA` (4: se reenvía la instrucción **una** vez; si repite, el carril queda `atorado`), `ATORADO sin reporte: <línea>` (5: el archivo no empieza por `LISTO`/`ATORADO`), `SIN-CONTRATO` (124: venció el tope sin `-s`, sin prueba de vida). Tope `-t 10800` (3 h). Todo `BRIEF.md` termina pidiendo escribir esa línea, y solo esa, en `.saikit/scratch/<carril>/contrato.txt` (con `mkdir -p` antes).

**La revisión cruzada**, desde el worktree del carril y siempre con ruta absoluta (`pwsh` no está en el PATH que hereda un CLI lanzado en tmux):

```
/Users/dn/.local/bin/pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto -Excluir <modelo> -Base <sha de la base del bloque>
```

`<sha de la base del bloque>` es `git merge-base HEAD origin/main`. `-Base` manda ese diff hasta HEAD. Ronda 2, solo sobre los arreglos y con **otro** revisor: `-Con <otro> -Excluir <modelo> -Desde <sha que vio la ronda 1>`. **`-Alcance branch` no existe** y `-Desde` en la ronda 1 la convierte en revisión de arreglos: el conjunto de `-Alcance` es `staged`, `working`, `last-commit` (medido, `loop-autopilot.md` §4). Los runbooks de las fases 6 y 7, ya cerradas, escriben `-Alcance last-commit` en sus rondas de revisión: queda como historia y no se reescribe. Ese valor está en el conjunto y corre; el script aborta si el valor de `-Alcance` no está en ese conjunto, y combinado con `-Desde` o `-Base` aborta igual. `-Excluir` acepta cualquier nombre desde quality-kit #11, así que se pasa `muse` o `cursor` aunque no sean candidatos. `glm` en esa cadena **es** zcode.

**Un turno a main / «por exec del gateway»** son el mismo mecanismo: un turno normal por la CLI remota desde la Mac, con el texto en un archivo.

```
~/.openclaw/bin/openclaw agent --agent main --session-key agent:main:<etiqueta> --message-file <archivo> --json
```

El mensaje dice, literal: «Corre por exec en el host gateway este comando y pega la salida completa sin resumir: `<comando>`». Tarda 1 a 3 minutos; tope 10 minutos, pasado el cual el dato queda `unknown` y se anota. **Todo `openclaw` desde la Mac es `~/.openclaw/bin/openclaw`**: no está en el PATH (`command -v openclaw` sale 1) y escrito pelado da «command not found», que parece un fallo del gateway y no lo es. **Y tmux siempre es `/opt/homebrew/bin/tmux`.**

---

## Dónde vive cada cosa

| Repo | Ruta local en la Mac | Default | Ruta en el destino (gateway Windows) |
|---|---|---|---|
| `gon0801/goncloud-openclaw` | `/Users/dn/dev/goncloud-openclaw` | `main` | `C:\Users\ehven\.openclaw` (runtime vivo, **no** es clon git; la fuente es `C:\Users\ehven\src\goncloud-openclaw`) — mergear a `main` **no** despliega: se publica a mano con [publicar-runtime-windows.md](publicar-runtime-windows.md) |
| `gon0801/goncloud-workspace-main` | `/Users/dn/dev/goncloud-workspace-main` | `master` | `C:\Users\ehven\.openclaw\workspace` (verificada) |
| `gon0801/goncloud-workspace-ingenieria` | `/Users/dn/dev/goncloud-workspace-ingenieria` | `master` | `C:\Users\ehven\.openclaw\workspace-ingenieria` — **no verificada** (ver el párrafo de abajo) |
| `gon0801/goncloud-workspace-operaciones` | `/Users/dn/dev/goncloud-workspace-operaciones` | `master` | `C:\Users\ehven\.openclaw\workspace-operaciones` (verificada) |

**No hay sync automático.** Desde la separación del runtime (22 de septiembre de 2026, `docs/spec/00-project-spec.md` «Propiedad del runtime Windows») la tarea `GoncloudRepoSync` está deshabilitada y `scripts/sync-repos.ps1` es obsoleto: nada baja solo al gateway. `goncloud-openclaw` se publica a mano, con autorización del dueño, por [publicar-runtime-windows.md](publicar-runtime-windows.md). Los tres `workspace-*` de la tabla **ya no son clones git en el runtime** (leído 2026-09-24: `workspace` es un git vacío sin remote, los otros dos no son repos) y no se publican: son memoria viva de los agentes y van **del runtime al repo**, una vez al día, a la rama `respaldo/runtime` (`scripts/mac/respaldo-workspaces.sh`). **Lo que el respaldo no guarda:** el `.git` vivo, los archivos de más de 50 MB (se nombran en `~/Library/Logs/respaldo-workspaces.log`), lo que excluyen los `.gitignore` que OpenClaw pone dentro del vivo (p. ej. `media/inbound`), y un workspace que llegó sin `IDENTITY.md` ese día (su rama queda en el respaldo anterior). El `master` de esos repos es el snapshot del 21/9 y ya no avanza; ninguna compuerta compara SHAs con ellos.

| Qué | Dónde |
|---|---|
| **Worktrees** | `/Users/dn/dev/wt-f<N>-lead` (detached en `origin/main`) y `wt-f<N>-<carril>` (uno por carril, rama `fase<N>/<nombre>`), más `wt-f<N>-cierre` y `wt-f<N>-revert` cuando la cola los pide. **Nunca `--force`**: pisaría el trabajo de otra sesión. |
| **Progreso** | `.saikit/progress/<N>.json` (`runbook-progress.v1`, `paso_loop` saturado en 8) y `.saikit/progress/<N>-sesiones.txt` (primera línea `lead - <sesión>`, luego `<carril> <token> <sesión>`), los dos en el worktree del lead. **En este repo `.saikit/` NO está en `.gitignore`** (a diferencia de Orbit): los dos archivos entran al repo en el PR de cierre. |
| **Encargos** | `BRIEF.md` (y `BRIEF-r<K>.md` para las correcciones) en la raíz del worktree del carril. **`BRIEF*.md` no se commitea.** |
| **Evidencia y rojos de TDD** | `.saikit/scratch/<carril>/` (incluye `tdd.md`) y `docs/evidence/…` en el repo. |
| **Kit de merge** | `/Users/dn/dev/summonaikit-claude/tools/` (scripts, librerías y `MANIFEST.sha256`). La entrega durable es el recibo `saikit-entrega.v1` del PR; el registro postmerge local no autoriza nada. |
| **Recibo de entrega** | Último comentario aplicable `APPROVE lead <sha>` del autor esperado, con bloque JSON `saikit-entrega.v1`; un `REVOKE lead <sha>` posterior lo invalida. Sobrevive a reinicios y relevos. |
| **Preaprobaciones del harness** | `.claude/state/plan-preapprovals.json`, **solo en el clon principal**, bajo `state/` que el `.gitignore` excluye: no existe en ningún worktree. Manda la tabla «Preaprobaciones» del runbook de la fase sobre sus contadores `max_uses`; **«no hay fila» no es una denegación.** |
| **Estado de un plugin en el gateway** | `C:\Users\ehven\.openclaw-state\<plugin>`, deliberadamente **fuera** del clon desplegado. El `gh` del gateway: `C:\Users\ehven\.openclaw\tools\bin\gh.exe` (**debe terminar en `.exe`**; un `.cmd` reabre el bug de comillas de Windows). Reinicio: `C:\Users\ehven\.openclaw\scripts\restart-openclaw-gateway.ps1`. |
| **Vigilante de tmux** | `scripts/mac/tmux-activity-watch.sh`; vivo con `pgrep -f 'bin/tmux-activity-watch.sh'`. Una sesión entra a su radar con `tmux set-environment -t <sesión> OPENCLAW_WATCH 1` y se comprueba con `tmux show-environment -t <sesión> OPENCLAW_WATCH` → `OPENCLAW_WATCH=1`. |
| **Lanzadores con token** | `~/bin/glm`, `~/bin/glm-claude`, `~/bin/deepseek`, `~/bin/kimi-claude`, permisos 700: **se ejecutan, jamás se leen ni se pegan.** |

---

## Precondiciones comunes (paso 0.0 de toda fase)

Las corre el lead antes de nada, **una comprobación por línea, para saber cuál falla** (un bloque encadenado no dice cuál de siete se cayó). La fase agrega las suyas después.

```
cd /Users/dn/dev/goncloud-openclaw && git fetch -q origin
git worktree list                                                     # mira qué hay ANTES de crear nada
git worktree add /Users/dn/dev/wt-f<N>-lead --detach origin/main
cd /Users/dn/dev/wt-f<N>-lead
bash scripts/arranque-de-fase.sh <N>
bash scripts/runbook.sh <N>
bash scripts/tests/test-skill-autopilot-runbook.sh
git cat-file -e origin/main:docs/runbooks/loop-autopilot.md 2>/dev/null; echo loop=$?
git show origin/main:.saikit/autopilot.json
test -r /Users/dn/dev/summonaikit-claude/tools/MANIFEST.sha256; echo manifiesto=$?
[ -n "${TMUX_PANE:-}" ] && /opt/homebrew/bin/tmux display-message -p -t "$TMUX_PANE" '#S #{pane_current_path}'
```

Una fase que delega todo su seguimiento al watchdog global puede sustituir solo esa línea por `bash scripts/arranque-de-fase.sh <N> --solo-watchdog-global`, siempre que su runbook prohíba crear `corrida-empuje-<N>`. El modo sigue exigiendo `avance-tareas` sano y rechazando `corrida-vigia-<N>` legado; no es una forma de omitir vigilancia.

**El runbook y sus filas del plan tienen que estar en `origin/main` ANTES de arrancar.** `arranque-de-fase.sh` lee `REF=origin/main` por default y el paso 0.0 crea el worktree del lead desde ahí: con el runbook todavía en una rama, las cinco comprobaciones salen `ROJO` y el lead no tiene ni el documento que ejecuta ni las filas cuya DoD obedece. A diferencia de Orbit, aquí **el lead puede mergearlo él mismo**: su cwd ya es un worktree de este repo. Por eso toda fase abre su cola con un **Q0** — el PR de plan y runbook — y el lead se lanza con su worktree parado en **la rama de ese PR**, no en `main`; después de mergear Q0 en ventana segura hace `git fetch origin && git checkout --detach origin/main` y sigue. Si Q0 ya está mergeado cuando claw lanza, el worktree nace detached en `origin/main` y el lead salta a Q1.

**La copia de la Mac del skill se comprueba en el 0.0, no al final**: `bash scripts/tests/test-skill-autopilot-runbook.sh`. Una copia derivada bloquea **todo commit del repo** por pre-commit, así que descubrirla en la última compuerta significa que los carriles trabajaron la noche entera contra un candado que ya estaba rojo. Se arregla copiando la canónica del repo sobre la de la Mac (esa dirección, nunca la inversa) y se repite la prueba.

**Detienen la fase**: kit ausente; `.saikit/autopilot.json` ausente en `origin/main`; el lead fuera de tmux (`ATORADO lead fuera de tmux`) o con otro cwd (`ATORADO lead lanzado fuera de wt-f<N>-lead`: no se corrige con `cd` ni con `rename-session`; claw relanza). **Un runbook se localiza con `bash scripts/runbook.sh <N>`, nunca con una ruta fija ni con un enlace** (medido 2026-09-18, Fase 9: a los implementadores se les dio el enlace de GitHub, el repo es privado, y la ruta de los documentos era la de otra máquina). En el gateway Windows hay bash pero no en el PATH: `"C:\Program Files\Git\bin\bash.exe" scripts/runbook.sh <N>`.

---

## Reglas de trabajo permanentes

1. **Un worktree por carril, todos desde `origin/main` fresco**, nunca de la rama de otro carril: `git worktree add /Users/dn/dev/wt-f<N>-<carril> -b fase<N>/<nombre> origin/main`. Si te relanzaron y la rama ya existe, `-b` falla: se omite. **Jamás `--force`**, ni al agregar ni al quitar. El clon principal puede estar en otra rama y con cambios de otra sesión: **ahí no se trabaja.** Tras cada merge de la cola, el lead se pone al día con `git fetch origin && git checkout --detach origin/main`.
2. **El encargo viaja como archivo y el `Enter` va en llamada aparte** (sección anterior). `BRIEF.md` y `BRIEF-r<K>.md` se borran antes del push y no cuentan como archivo fuera de tabla; el encargo que importa queda citado en el cuerpo del PR.
3. **Toda sesión que la corrida lanza se marca al lanzarla, la del lead incluida** (loop §12): `tmux set-environment -t <sesión> OPENCLAW_WATCH 1`. Sin marca el vigilante la ignora por diseño. Cuando un carril queda mergeado o `atorado` se **desmarca** y se deja abierta (`-u OPENCLAW_WATCH`): marcada seguiría mandándole a claw un recordatorio de silencio cada 30 minutos.
4. **Un commit por tarea; las correcciones son commits nuevos `fix(<N>.x): …`.** Nunca amend, nunca rebase, nunca force-push: la ronda 1 lee `merge-base..HEAD` (`-Base`, loop §4) y un rebase reescribe esa historia.
5. **Base al día con merge, nunca con rebase** (loop §3 paso 9). Si `main` avanzó mientras el PR esperaba, el kit contesta «base avanzada»: `git fetch origin && git merge origin/main`, push normal, CI otra vez, y re-APPROVE si `git diff <sha aprobado> HEAD -- <archivos de la fila>` sale vacío. El commit de merge no cuenta como commit ajeno en la compuerta.
6. **Pre-commit se corre y se respeta. Jamás `--no-verify`.** Si un candado bloquea un comando legítimo, se usa la ruta que el candado nombra; si no existe, es un residual declarado, no un rodeo.
7. **El candado léxico de este repo deniega por el nombre, no por el hash.** El basename del script de merge del kit solo puede aparecer en un comando como **ruta absoluta resoluble**: nada de `echo`, banners, cuerpos de PR ni variables en la misma línea. Medido dos de dos veces: dentro de un `echo`, con la ruta entera, devuelve `merge denied: … hash does not match the kit manifest` **aunque el hash sí case y aunque el comando no mergee nada**. El mismo candado rechaza comandos que solo *mencionan* `main` o merge en su texto (medido: `gh pr create --base main` fue rechazado como push a `main`): los cuerpos largos van en archivo (`--body-file`) y `gh pr create` va **sin** `--base`. Para diagnosticar si es falso positivo, con la ruta partida en variables, que esa forma sí pasa: `K=/Users/dn/dev/summonaikit-claude/tools; F="$K/saikit-merge"".sh"; shasum -a 256 "$F"`, comparado contra `MANIFEST.sha256`.
8. **El recibo pertenece al PR y al head exacto.** El lead publica, fuera del código, `APPROVE lead <sha>` con un bloque JSON `saikit-entrega.v1`: coordenadas, clase, evidencia durable de implementer/verifier/reviewer según el carril, workflow de CI, bloqueantes vacíos y residuales declarados. Si cambia el head, publica un recibo nuevo; si retira la aprobación, publica `REVOKE lead <sha>`. Cambiar de sesión, host o cwd no obliga a repetir evidencia que sigue válida para ese head.
9. **El progreso se escribe, no se cuenta** (loop §8). En cada cambio de estado de un carril o de la cola, y al cierre, el lead escribe `.saikit/progress/<N>.json` (`runbook-progress.v1`, spec `docs/spec/runbook-progress.v1.md`; `atencion_requerida` es **objeto**, `siguiente_paso` en lenguaje llano, `paso_loop` **saturado en 8** porque el spec cierra ese campo en 0–8 y el loop tiene once pasos) y lo envía:
   ```
   ~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat .saikit/progress/<N>.json)" --timeout 30000
   ```
   **La CLI no acepta la forma arroba-archivo**: `--params @<archivo>` contesta `--params must be valid JSON` (medido dos veces, 2026-09-16 y 17). El JSON va en línea. Un envío fallido **no bloquea**: se anota en `eventos` y se reintenta en el siguiente cambio. Los nombres de sesión **no caben en ese JSON** (valores cerrados): van en `.saikit/progress/<N>-sesiones.txt`, primera línea `lead - <sesión>`, después una por carril (`<carril> <token> <sesión>`) y los crons como `cron <id>`; al relanzar, la línea `lead` se **reemplaza**. **En este repo `.saikit/` NO está en `.gitignore`** (a diferencia de Orbit): los dos archivos entran al repo en el PR de cierre. El nombre es `<N>.json`; `fase6.json` es la forma vieja y no se repite.
10. **Enviar el progreso no lo hace alcanzable de un clic** (loop §8). La ruta del tablero es **por prefijo**: `/runbook/tablero/<N>` sirve cualquier fase en cuanto su documento existe, y `runbook.progress.set` acepta cualquier fase válida — ni la escritura ni la lectura consultan la config (medido 2026-09-18: la Fase 11 responde completa sin estar listada, y una fase sin documento contesta `desconocida`). Lo que **sí** depende de la config es la barra «Fases:», el único clic desde la aplicación: se pinta con `plugins.entries.tablero-runbook.config.fases` y el plugin la lee **una sola vez, al registrarse**. Publicar ese clic son dos pasos en la ventana de publicación: `config.patch` con `replacePaths` sobre esa clave (un arreglo se reemplaza, no se fusiona) y **reiniciar el gateway** — no hay RPC que recargue un plugin. Se comprueba en el tablero de **otra** fase, porque la barra excluye la que estás viendo. **La lectura de vuelta de la configuración es un falso verde por sí sola** (medido 2026-09-18 cerrando la Fase 7: la lista ya traía la fase y el plugin seguía sirviendo la que cargó al arrancar).
11. **No se limpia durante la corrida** (loop §12). Ni el lead ni sus subagentes. El hook de seguridad convierte en pregunta cualquier borrado destructivo, aunque sea bajo `/tmp`. Los directorios de trabajo se crean con `mktemp -d` y no se borran. **El cierre declara qué quedó, con rutas y nombres.** Medido 2026-09-17, Fase 8: un `rm -rf` bajo `/tmp` se volvió pregunta a las 00:20 y nadie la contestó hasta las 07:15 — 6 h 54 min — porque la sesión del lead no estaba marcada.
12. **Lo que no se pudo medir se escribe `unknown`, con el comando que lo intentó**, nunca como hecho y nunca rellenado para «cerrar». Un `unknown` no bloquea: se declara.
13. **Se reporta, no se relaya** (loop §2). Todo proceso que el lead o claw vigilan termina imprimiendo, como última línea, `LISTO <sha>` o `ATORADO <razón en una línea>`. Claw la busca en la pantalla; no interpreta spinners, colores ni mensajes propios de ningún producto. Un proceso que termina sin esa línea se trata como `ATORADO sin reporte`.
14. **El `LISTO` de una fase no se escribe de memoria: se gana con un comando** (loop §2 y §10). Antes de imprimirlo, y antes de que nadie le diga a David que la fase terminó: `bash scripts/cierre-de-fase.sh <N>`. **No es una compuerta de una pasada: es un bucle.** La primera corrida normalmente sale `ROJO` y su lista **es** la lista de lo que falta; se hace lo que dice cada línea y se repite hasta `VERDE: la fase <N> puede declararse cerrada` con salida 0. Medido 2026-09-17: la Fase 7 se reportó terminada con todo su código mergeado y CI en verde, y le faltaban las ocho celdas del plan, el plugin sin encender, dos sesiones todavía marcadas y un worktree abierto.
15. **TIMEBOX: 6 horas de reloj por carril**, desde su lanzamiento hasta su `LISTO`. Un carril detenido en un diálogo **reinicia su TIMEBOX** cuando vuelve a trabajar: ese tiempo lo perdió el lanzamiento, no el implementador. Un `BRIEF-r<K>.md` no abre otro TIMEBOX: tiene 2 horas. A su tope, el carril pasa a `atorado` con lo que tenga y los demás siguen.
16. **Escribe quién implementó cada carril en el cuerpo de su PR, con esa palabra exacta**: de ahí sale el `-Excluir` de la cruzada (loop §4). `muse` y `cursor-agent` no son candidatos a revisor: con ellos se pasa `-Excluir ''`.
17. **Rutas absolutas siempre.** En la Mac el exec pasa por OpenClaw.app con el PATH de launchd (sin `/opt/homebrew/bin`, `~/.local/bin` ni `~/bin`): todo comando que claw corra por exec lleva ruta absoluta o el prefijo `export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH;`.

**El loop de entrega no se reescribe aquí: se cita por número.** Secciones de `docs/runbooks/loop-autopilot.md`, en orden: 1 Roles · 2 El contrato de reporte · 3 El loop por tarea · 4 Política de rondas de revisión cruzada · 5 PRs y CodeRabbit · 6 Merge: la ruta del kit · 7 Despliegue y configuración del gateway · 8 Progreso escrito, no contado · 9 El lead es reemplazable · 10 Revisión de cierre de fase · 11 Lo que lleva un runbook de fase, y lo que no · 12 Atores universales · 13 Cómo se prueba este documento. Manda **el loop que esté en `origin/main` cuando lo consultas**; se prueba con `bash scripts/tests/test-loop-autopilot.sh`.

---

## Compuertas comunes y cola

**El número de PR**: `pr=$(gh pr list --repo gon0801/goncloud-openclaw --head fase<N>/<rama> --state all --json number --jq '.[0].number')` (`--state all`: sin él un ítem mergeado desaparece). **El SHA de squash**: `gh pr view $pr --repo gon0801/goncloud-openclaw --json mergeCommit --jq .mergeCommit.oid`.

**Compuerta común de todo ítem**, además de lo suyo: el CI **de ese SHA**, no la última corrida de `main`, y `git log origin/main..HEAD` con solo commits de ese carril más, si los hubo, los merges de la regla 5.

```
SHA=<sha del squash>
for i in 1 2 3 4 5 6 7 8 9 10; do
  r=$(gh run list --workflow quality.yml --commit "$SHA" --limit 5 --json status,conclusion \
        --jq '.[] | "\(.status) \(.conclusion)"' | head -1)
  echo "intento $i: ${r:-sin-corrida}"
  case "$r" in "completed success"|"completed failure") break ;; esac
  sleep 60
done
```

El filtro va en `--commit`, de la propia herramienta, **no en el `jq`**: `--limit` se aplica **antes** de filtrar, así que con diez corridas más nuevas en `main` la del SHA se queda fuera y el ítem se marcaría `sin-corrida` con el CI en verde. `completed success` cierra el ítem; `completed failure` manda el carril a loop §3 con el log del job como encargo y **el siguiente ítem no se mergea** hasta que `main` esté verde; `sin-corrida` o `in_progress` a los diez intentos queda `unknown` y el siguiente **tampoco** se mergea ese ciclo.

**El merge es siempre el del kit. Ninguna otra ruta: ni la interfaz de GitHub, ni la API, ni a mano.** El script opera sobre la rama del worktree en el que estás parado, no toma número de PR, y toma un lock por clon; se corre con `cd` a ese worktree, en orden, **con la ruta escrita entera, nunca en una variable** (medido 2026-09-16: escrito como `$K/<script>` el token no resuelve, el hash no casa y el candado deniega aunque el kit esté intacto). El script vive en `644` y se invoca por `bash`: comprobar su existencia con `test -x` da falso negativo.

| Salida | Qué significa | Qué hace el lead |
|---|---|---|
| `DRY-RUN: gate en verde; haria: …`, código 0 | El gate pasaría. **El `--dry-run` NO imprime `LISTO`** — `loop-autopilot.md` §6 dice que sí; es una imprecisión del loop, medida leyendo el script (línea 350 contra 355), declarada aquí | Sigue a la corrida sin flags |
| `LISTO: todas las condiciones del gate estan en verde para <sha> (PR <pr>)`, código 0 | Es la corrida **sin flags**, la que sí imprime `LISTO` | Corre `--confirmado`, que repite el gate y mergea en squash con `--match-head-commit <sha>` |
| Código 1, `NO-MERGE` con la razón nombrada | El gate rechaza | Fila de atores de esa razón. **No se rodea** |
| Código 3, lock ajeno | El lock vive en `$(git rev-parse --git-common-dir)/saikit-merge.lock`, **el mismo archivo para todos los worktrees del clon**, y jamás se borra solo | Se mira pid, host y hora. Si es de una corrida **tuya** ya muerta en esta máquina, `--liberar-lock` y se reintenta. Si es de otro host, de otro pid vivo, o no se puede saber: se espera 15 min y se reintenta **una** vez; después el ítem queda `atorado`. Liberar un lock ajeno puede pisar un merge en curso |
| `postmerge` código 0 `VERDE` / 1 `ROJO` / 3 `UNKNOWN` | CI del merge commit | `VERDE` cierra el ítem. `ROJO`: el propio script imprime el bloque **PARA REVERTIR** listo, se usa ese comando. `UNKNOWN`: se anota y se repite con el comando que el aviso imprime |

**Antes de tocar la ruta del kit, el PR no puede estar en borrador**: `gh pr view <pr> --json isDraft -q .isDraft` tiene que decir `false`. GitHub rechaza mergear un borrador y el script del kit **no mira ese campo** (lee `mergeable`, que en un borrador dice `MERGEABLE` igual), así que llegaría hasta el final y fallaría ahí.

**Mergear no despliega, así que el merge no necesita ventana.** La ventana es de la **publicación** ([publicar-runtime-windows.md](publicar-runtime-windows.md)): ningún cron con `Next` en los próximos 15 minutos según `~/.openclaw/bin/openclaw cron list` (con `--json` el campo es `nextRunAtMs`, en milisegundos). **Los crons que la propia fase crea no cuentan** (con uno cada 15 minutos la ventana no se abriría nunca). Si no hay ventana se vuelve a mirar cada 5 minutos; **no se fuerza**.

**Compuerta de publicación**, cuando la fase deja algo en el runtime: la salida del paso 5 del runbook de publicación (`N selected files published; …` o `N selected files already published`) y la fuente del host conteniendo el SHA: `git -C C:\Users\ehven\src\goncloud-openclaw merge-base --is-ancestor <SHA> HEAD; if ($LASTEXITCODE -eq 0) { 'PRESENTE' } else { 'AUSENTE' }` (sintaxis de Windows PowerShell 5.1: sin `&&` ni `||`). Un cambio que solo toca `scripts/` o `docs/` no pasa por la allowlist: su compuerta es solo la fuente `PRESENTE`. **Sin autorización del dueño para publicar, la fase cierra con el merge y la publicación queda como fila pendiente**, no como hecha.

**El camino de emergencia: la reversa.** Worktree `/Users/dn/dev/wt-f<N>-revert`, rama **`fase<N>/revert-<carril>`** desde `origin/main`, **un solo commit** y sin cambios a mano: `git revert --no-edit <merge_commit>`, PR con `--body-file` que lleva el error verbatim, y la ruta del kit con `--revert-de <merge_commit> --confirmado`. Ese modo mecánico no exige el recibo normal: exige un solo commit, árboles idénticos, CI verde **y que el merge revertido siga siendo la punta de `origin/main`**. Si ya no es la punta, se usa un PR normal con recibo. Si el `git revert` sale con conflicto: `git revert --abort`; el segundo intento determinista restaura las rutas del padre en un solo commit. **Máximo dos correcciones tras un merge por fase**; la tercera se declara.

**El ítem de cierre** cierra las celdas `Status` de `Plans.md` con el token literal **`cc:完了`** y el SHA de squash, **solo con evidencia**: una tarea con PR lleva `cc:完了 [PR #n, merge <sha>]`; una sin PR propio, `cc:完了 [evidencia: <ruta>, PR de cierre #n]` (el PR de cierre no puede citar su propio SHA); lo que no se hizo lleva qué quedó y por qué. Antes va la **aceptación y cierre de fase** de loop §10: la promesa de cada fila recorrida como la recorrería David, la comprobación de instalación y el simulacro; el cierre no repite la revisión de código, que cada bloque ya tuvo en sus rondas. Su loop es reducido (CI verde + CodeRabbit con la regla de §5 + `APPROVE lead <sha>`); si publica al runtime, va en la ventana de publicación.

---

## Cuando algo se atora (universales de openclaw)

Las universales del loop están en su §12 y no se repiten. Una fase agrega solo las suyas.

| Situación | Qué hace el lead |
|---|---|
| **Reanudación: el lead murió, se colgó o se quedó sin cuota** | Claw relanza el siguiente host disponible y el lead nuevo corre el 0.0 entero. **El estado vive en git y en los PRs, nunca en la memoria del lead.** Lee tmux, contratos, PRs y su último recibo aplicable, luego el progreso. Un `BRIEF*.md` en un worktree es un encargo en vuelo: se espera, no se reenvía. No se repite trabajo ni revisión ya acreditados para el mismo head. |
| **Hay que relanzar a un implementador** (calló 30 min, o volvió a preguntar tras cambiarle el modo) | Dos sesiones no pueden commitear en la misma rama, así que **primero se comprueba que de verdad no trabaja**: dos `capture-pane` con 60 s de diferencia. Pantallas **idénticas** = parada: se mata y se relanza en el mismo worktree, mismo token, mismo `BRIEF.md`, nombre con sufijo `-b`. Distintas: sigue trabajando, **no se relanza**, 2 h más de TIMEBOX. Se relanza **una vez**; a la segunda el carril queda `atorado`. |
| **Cuota agotada, auth, binario ausente o fallo de arranque de un proveedor** | Detener el proceso anterior y relevar al siguiente candidato compatible, conservando worktree, rama, brief y commits. Una prueba o revisión roja no permite cambiar de trabajador. **CodeRabbit no es un proveedor de modelo**: su fila es la de abajo y nunca detiene un carril. |
| **CI en rojo** | Del PR: el carril vuelve a loop §3 con el log del job como encargo al mismo implementador. **Rojo tres rondas seguidas por el mismo hallazgo**: ese carril se detiene, su PR queda abierto con la etiqueta `autopilot:atorado`, los demás siguen. Del merge commit: el comando de reversa que el propio postmerge imprime. Si el rojo es de `main` y no lo trajo la fase, se declara y **no se mergea el siguiente ítem** hasta que `main` esté verde. |
| **CodeRabbit sin cuota, rate limit o sin respuesta en 20 minutos** | **No bloquea**: se anota «CodeRabbit sin cuota: no revisó este PR» en el cuerpo del PR y en el progreso, y se vuelve a consultar tras el próximo push. **Los comentarios se leen, no solo el check**: medido 2026-09-16, el PR #48 se mergeó con el check en verde y trece comentarios accionables sin leer, seis altos, y cuatro eran candados que daban verde con el defecto puesto. |
| El revisor cruzado sale con **código 3** (ningún revisor externo disponible) | Revisión con un subagente propio, declarada en el PR como «revisión interna, sin cruzada». **Nunca se espera a que la cadena vuelva.** Medido 2026-09-18: la cadena entera salió en código 3 el mismo día. |
| Un candado responde algo sobre el kit («hash does not match the kit manifest», «path must end exactly at .sh») | Es el candado **léxico** reaccionando al texto del comando, no un fallo del kit (regla 7): se diagnostica con la ruta partida en variables y, si el hash coincide, se reescribe el comando y se sigue. |
| **Una prueba pasa igual sin el arreglo** | Encargo de corrección al mismo implementador. **El arreglo no existe hasta que la prueba lo atrape.** Medido 2026-09-16, cierre de la Fase 6: en los siete carriles, al menos una prueba pasaba igual con el defecto puesto; ningún implementador lo detectó solo. |
| Un archivo fuera de la tabla del carril | Se descarta antes del push con un commit propio. Si el carril **necesita** un archivo que no es suyo, no lo toca: lo dice en su reporte y el lead manda un `BRIEF-r<K>.md` al carril dueño. |
| Una sesión queda esperando a una persona (permiso, confianza de la carpeta, límite de uso) | Llega sola por el vigilante y se recuerda cada 30 minutos a toda sesión **marcada** que siga callada. **No se contesta de uno en uno: se pasa a modo sin preguntas.** `glm`: `C-c`, 2 s, otro `C-c` hasta `Turn cancelled.` (un `/mode` a medio turno se rechaza con «Wait for the active turn»), luego `-l '/mode yolo'` con el `Enter` aparte, comprobar la barra, y «Continúa el encargo donde te quedaste. El modo ya es yolo.» — medido 2026-09-17: retoma con su contexto y cero prompts. `muse` y `cursor-agent`: se contesta con la tabla de preaprobaciones (lo `Aprobado` se acepta, lo `Negado` se rechaza, lo que no está se rechaza y se anota como residual) y, si vuelve a preguntar, se relanza el carril con su flag; **ese relanzamiento no cuenta** como el de loop §9. **Nunca se despierta a David por una aprobación.** |
| **Una `workshop-skill` editada en vivo en el gateway** | Ya no hay snapshot automático que la suba al repo (el sync está deshabilitado). Al publicar, el paso 5 la reporta como `SKIPPED live-edit <ruta>` y **no la pisa**: se lleva la edición a un PR o se acepta la de `main` después de conciliar ([publicar-runtime-windows.md](publicar-runtime-windows.md)). |
| `runbook.progress.set` contesta `unknown method` u `ok: false` | No bloquea (regla 9): se anota **una vez** mientras el error no cambie y el **intento** se repite en cada cambio de estado. |
| El exec a main queda denegado («approval cannot safely bind this command», «Approved executables: none») | Es el binder, no el gateway. **Una denegación es una respuesta, no un silencio, y vale lo mismo**: el dato queda `unknown` desde el primer turno y **no se reintenta el mismo comando esperando otra cosa**. |
| El egress al puerto del gateway está negado desde donde corres | El dato queda `unknown` y **la fase sigue**. Toda compuerta que dependa de un `curl` tiene su equivalente por RPC, y ese es el camino principal. |
| Haría falta leer un secreto (DSN, token, `.env`) | **Nunca.** Los lanzadores de `~/bin` se ejecutan, jamás se leen ni se pegan; `~/.ssh` no se abre. Lo que dependa de eso queda `n/a` declarado. |
| Se necesita un cuarto PR propio abierto | No se abre; se cierra uno antes (loop §5). Los PRs ajenos no cuentan y no se cierran por esto. |
| Duda de alcance no cubierta | La lectura más chica que cumple la DoD literal de la fila; la elección se escribe en el PR. |
| **El único caso al que se le permite llegar al humano antes del cierre** | **La reversa que no entra**: el `git revert` sale con conflicto y el segundo intento determinista **también** lo rechaza el gate. Se manda el aviso a David **en ese momento**, con el error verbatim y el comando listo, `atencion_requerida.necesaria: true`, y la fase se detiene ahí. **Ese aviso adelantado ES el de cierre, no uno extra.** El resto de carriles sigue: un carril atorado nunca detiene a los demás. |
| Lo único que detiene **toda** la corrida | Perder acceso a GitHub o a la Mac, o un gateway que no responde tras un reinicio. Todo lo demás detiene un carril y deja evidencia. |

**El canal de aviso a David lo fija cada fase**, no este documento: `loop-autopilot.md` §1 dice «solo lee el Telegram de cierre» y la Fase 9 lo desvió a mensajes continuos en lenguaje de usuario por pedido del dueño del 2026-09-17. El `"telegram": false` de `.saikit/autopilot.json` es del **kit de merge** y no aplica a los avisos que una fase mande por su cuenta.

---

## Qué trae un runbook de fase (y nada más)

1. Primer párrafo: qué construye la fase, qué **no** hace, y «Hereda `docs/runbooks/base-openclaw.md` v<K>». 2. Su tabla de **preaprobaciones** (aprobado y negado). 3. Su **prohibido**. 4. **Carriles**: por carril, rama `fase<N>/<nombre>`, la fila del plan con la DoD verbatim, y «lo que un usuario vería si funcionó» con la ruta que un humano tomaría para verlo. 5. **Archivos por carril** (puede tocar / no toca). 6. **Cola**: ítems en orden con su compuerta propia y su fallback. 7. **Atores propios**, solo los que no están arriba. 8. **Inventario**: cuentas, presupuesto, fuera de alcance, y qué queda listo para David. Tope: **120 líneas**. Verificación: un lector fresco que ejecuta, un revisor del diff, una ronda; residuales declarados en el PR (receta `autopilot-runbook`).

**La fuente es este archivo.** Cualquier copia en una página web es eso, una copia, y lo dice en su pie.
