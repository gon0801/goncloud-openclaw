# Autopilot de la Fase 7 — tablero de runbook

Esta página es para ti, **el lead** que corre la Fase 7 en autopilot. David no está y no se le pregunta nada: todo lo que necesitas decidir ya está decidido aquí o en el loop. Dos carriles en el mismo repo con archivos disjuntos, un spike tuyo al inicio, un despliegue al final con canary y reversa, y un Telegram al cierre.

**Lo que no está escrito aquí está en `docs/runbooks/loop-autopilot.md`**, la parte invariante de todo runbook: el loop por tarea (§3), las rondas de revisión con su comando literal (§4), PRs y CodeRabbit (§5), la ruta del kit (§6), ventana segura y configuración del gateway (§7), progreso (§8), reanudación (§9), revisión de cierre (§10) y los atores universales (§12). Este runbook **no los repite**; solo nombra sus desviaciones, y hay una sección entera para eso.

**Dos convenciones que valen para todo el documento.** Primera: **todo `openclaw` que corras desde la Mac es `~/.openclaw/bin/openclaw`**. Ahí no está en el PATH (`command -v openclaw` sale 1) y escrito pelado da "command not found", que parece un fallo del gateway y no lo es. La excepción es la lista cerrada de comandos por exec: esos corren en el host del gateway, donde el binario sí está en el PATH, y por eso van pelados ahí y solo ahí. Segunda: **todo comando se corre desde `wt-f7-lead`** salvo donde diga otra cosa, y ahí es donde se resuelven las rutas relativas.

---

## Qué runbook manda, y cómo llegó hasta ti

`origin/main` trae hoy una versión **superada** de este archivo: dice que el lead es Claude, fija dos implementadores por nombre, apunta a un binario que ya no existe, y pone como Q0 un PR que se mergeó hace días. Esa versión no se ejecuta.

Manda **este texto**, el que claw te entregó al lanzarte. Ya está escrito y subido: es el **PR #54**, rama `docs/fase7-runbook`, y ponerlo en `main` es **Q0b**, el segundo ítem de la cola. No lo vuelves a escribir ni vuelves a abrir su PR; lo mergeas.

**No intentes comparar este texto con el de `main` archivo contra archivo.** Tu worktree nace en `origin/main`, así que la copia en disco **es** la de `main` y cualquier `cmp` entre las dos sale igual siempre. Lo que se consulta es el estado del PR.

Fuente del plan: `Plans.md`, Fase 7, tareas 7.0 a 7.7. Si el plan y este runbook difieren en el **método**, manda este runbook. Si difieren en la **DoD de una tarea**, manda `Plans.md`: la revisión de cierre (loop §10) se hace contra la DoD literal del plan. Las tres DoD que este runbook declara desactualizadas están nombradas una por una en la sección "Desviaciones", con la celda exacta que Q5 tiene permitido corregir.

---

## Quién

| Rol | Quién | Qué hace en esta fase |
|---|---|---|
| **lead** | tú: un CLI en tmux, de cualquier host del kit, elegido y lanzado por claw | Spike 7.0, encargos, entrega, revisión, APPROVE, merges, despliegue 7.6, cierre 7.7, Telegram. **No escribes código de producto.** |
| **implementador P** | el que claw lanzó; preferencia: glm, cursor-agent, muse | El plugin: 7.1, 7.3, 7.4, 7.5 |
| **implementador D** | el que claw lanzó; preferencia: muse, cursor-agent, glm | Docs y anclas: 7.0 (formato), 7.2 y el Spec delta |
| **claw** | el agente `main` del gateway | Te lanzó, te vigila por tmux, te presta su exec para los comandos del host Windows. No mergea ni decide configuración por su cuenta. |
| **David** | el dueño | Solo lee el Telegram de cierre con el enlace al tablero. Preaprobó lo de la tabla de abajo. |

Los hosts que el kit sella están en loop §1; no se repiten aquí.

**Escribe quién implementó cada carril** en el cuerpo de su PR, con esa palabra exacta. De ahí sale el `-Excluir` de la revisión cruzada, que tiene un conjunto cerrado de seis nombres (loop §4): si implementó muse o cursor-agent, que no son candidatos a revisor, se pasa `-Excluir ''` y el nombre queda solo en el PR.

---

## Arranque

Repo único: `/Users/dn/dev/goncloud-openclaw`, default `main`, copia desplegada en el gateway `C:\Users\ehven\.openclaw`, que el sync actualiza cada 2 h a los :10 de las horas impares en `America/New_York`.

**Dónde te paras.** El clon principal puede estar en otra rama y con cambios de otra sesión: no trabajas ahí. Abres tu propio worktree de lectura y te quedas en él:

```
cd /Users/dn/dev/goncloud-openclaw && git fetch origin
git worktree list                      # mira qué hay ANTES de crear nada
git worktree add /Users/dn/dev/wt-f7-lead --detach origin/main
cd /Users/dn/dev/wt-f7-lead
```

**Los worktrees no son idempotentes y este clon ya tiene varios.** `git worktree add` falla si la ruta existe, y falla con "already checked out" si esa rama vive en otro worktree del mismo clon. Por eso `git worktree list` va primero. Si la ruta que necesitas ya existe y está limpia (`git -C <ruta> status --porcelain` vacío), la reúsas y lo anotas. Si existe y está sucia, vas a la fila de atores. **Nunca `--force`**: pisaría el trabajo de otra sesión.

Rutas literales de los worktrees de esta fase, para que Q5 sepa qué borrar:

| Worktree | Ruta | Rama |
|---|---|---|
| lead | `/Users/dn/dev/wt-f7-lead` | detached en `origin/main` |
| P | `/Users/dn/dev/wt-f7-P` | `fase7/tablero` |
| D | `/Users/dn/dev/wt-f7-D` | `fase7/docs` |
| cierre | `/Users/dn/dev/wt-f7-cierre` | `fase7/cierre` |
| reversa (solo si hace falta) | `/Users/dn/dev/wt-f7-revert` | `fase7/revert-tablero` |

- [ ] **0.0 Precondiciones.** Siete comprobaciones independientes, una por línea, para saber cuál falla:

```
G=~/.openclaw/bin/openclaw
git cat-file -e origin/main:docs/runbooks/loop-autopilot.md  2>/dev/null; echo loop=$?
git cat-file -e origin/main:.saikit/autopilot.json           2>/dev/null; echo autopilot=$?
git cat-file -e origin/main:docs/spec/runbook-progress.v1.md 2>/dev/null; echo spec=$?
test -r /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh; echo kit=$?
bash scripts/tests/test-runbooks-no-contradicen-entorno.sh >/dev/null 2>&1; echo candado=$?
gh pr view 54 --json state -q .state;                                     # Q0b
$G gateway call status --timeout 30000 >/dev/null 2>&1; echo gateway=$?
```

En las seis líneas que imprimen un número, cero es presente y **cualquier valor distinto de cero es ausente**: `git cat-file -e` sale `128` cuando la ruta no está, no `1`, así que la comprobación es contra cero, nunca contra uno. La séptima imprime un estado de PR, no un número.

Lectura de cada uno:

- `loop` distinto de cero: el PR #53 sigue abierto. Es **Q0a** y nada más se mergea antes. Mientras tanto lees el loop con `git show origin/feat/loop-autopilot:docs/runbooks/loop-autopilot.md`.
- El PR #54 en `OPEN`: este runbook todavía no está en `main`. Es **Q0b**. Es lo normal al arrancar. En `MERGED`, Q0b ya está hecho y se salta. En `CLOSED` sin mergear, la fase se detiene: estarías ejecutando un texto que el repo rechazó.
- `gateway` distinto de cero: el gateway no responde. **Detiene la fase**: sin él no hay spike, ni despliegue, ni canary.
- `autopilot`, `spec`, `kit` o `candado` distintos de cero **detienen la fase**: son precondiciones que esta fase no produce.

**Toda detención de la fase, aquí o en cualquier compuerta de la cola, hace estas tres cosas y en este orden:** se declara con la salida verbatim en el progreso, se manda el Telegram de detención (§ Telegram), y se imprime `ATORADO <razón>` como último acto del turno. Las tres, siempre. Sin la línea `ATORADO`, claw lee el silencio como un lead muerto y te relanza sobre el mismo repo roto (loop §2 y §12); sin el Telegram, David no se entera hasta que abre el tablero, que puede estar apagado.

`test-loop-autopilot.sh` **no se corre aquí**: vive en la rama del PR #53 y no existe en `origin/main`. Su compuerta es Q0a; después de ese merge sí se corre y tiene que salir verde.

Lo que 0.0 **no** puede comprobar: que el hook del kit selle en tu host. Loop §6 lo pide como precondición y no hay comando que lo verifique sin mergear algo. Se descubre en el `--dry-run` de Q0a, que es el primer merge de la fase y por eso va primero: si ahí sale "sin estado del hook", la fase se detiene antes de haber lanzado a nadie.

- [ ] **0.1 Lee** la Fase 7 de `Plans.md`, `docs/spec/runbook-progress.v1.md` y el loop entero.

  Sobre `.claude/state/plan-preapprovals.json`: vive solo en el clon principal, está bajo `state/` que el `.gitignore` excluye, y por eso **no existe en tu worktree**; además el lead puede ser un host que ni siquiera lo lea. No lo busques. Si lo abres de todos modos, hoy sus filas son todas de la Fase 6: **"no hay fila" no es una denegación**. La tabla de abajo es la autorización de esta fase, punto.

- [ ] **0.2 Abre los dos worktrees de carril**, cada uno desde `origin/main`, respetando la regla de idempotencia de arriba:

```
git worktree add /Users/dn/dev/wt-f7-P -b fase7/tablero origin/main
git worktree add /Users/dn/dev/wt-f7-D -b fase7/docs   origin/main
```

Si te relanzaron (loop §9) y la rama ya existe, `-b` falla: usa `git worktree add <ruta> <rama>` sin `-b`.

- [ ] **0.3 Corre el spike 7.0 tú mismo.** Es tuyo y es de solo lectura. Lo que produce está en su propia sección, abajo. Las **dos decisiones** que salen de ahí van pegadas en el encargo de P, no el archivo.

- [ ] **0.4 Escribe el primer progreso** (loop §8) en `.saikit/progress/7.json`, con los dos carriles en `pendiente` y `atencion_requerida.necesaria: false`. El envío va a fallar con "método desconocido" hasta que 7.6 despliegue el plugin: eso es lo esperado. Se anota **una vez** en `eventos` mientras el error no cambie; el **intento** sí se repite en cada cambio de estado, como manda loop §8.

  Los nombres de sesión de tmux **no caben en ese JSON**: el spec tiene valores cerrados y no hay campo para ellos, y meterlos inventando una clave volvería inválido el documento que el canary de Q3 envía. Van en `.saikit/progress/7-sesiones.txt`, una línea por carril (`P <token> <sesión>`), en el mismo worktree, y esa ruta está en la fila "cierre" de la tabla de archivos.

- [ ] **0.5 Lanza a los dos implementadores en la misma tanda.** Ver "Cómo se lanza un implementador", que trae los comandos.

### Qué es un turno a main, y su lista cerrada

Varios pasos dicen "por exec del gateway". Es siempre el mismo mecanismo: un turno por la CLI remota desde la Mac, con el texto en archivo:

```
~/.openclaw/bin/openclaw agent --agent main --session-key agent:main:<etiqueta> \
  --message-file <archivo> --json
```

El mensaje dice, literal: "Corre por exec en el host gateway este comando y pega la salida completa sin resumir: `<comando>`". Tarda de 1 a 3 minutos; tope 10; sin respuesta, el dato queda `unknown`.

**Una denegación del binder también es `unknown`, desde el primer turno.** Si main contesta algo como "approval cannot safely bind this command" o "Approved executables: none", eso es una respuesta, no un silencio, pero vale lo mismo: el dato queda `unknown` y se sigue por la fila de atores del binder. No se reintenta el mismo comando esperando otra cosa.

**Ese exec corre en Windows.** No expande `$(…)` ni rutas POSIX: los comandos de abajo ya están escritos en la forma que ese host acepta, y esa es la razón de que ninguno lleve sustitución de comando.

Lista cerrada de comandos por exec en esta fase. Los primeros son de lectura; los tres marcados **(escribe)** tienen su propia fila de preaprobación:

```
openclaw --version
powershell -Command "npm root -g"
powershell -Command "Select-String -Path 'C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist\*' -Pattern '<UNA_FUNCION>' -List -Recurse | Select-Object -First 3"
powershell -Command "Get-ChildItem C:\Users\ehven\.openclaw -Directory | Select-Object Name"
powershell -Command "Get-Content C:\Users\ehven\.openclaw\logs\sync-repos.log -Tail 40"
git -C C:\Users\ehven\.openclaw log -1 --format=%H
git -C C:\Users\ehven\.openclaw merge-base --is-ancestor <SHA> HEAD
openclaw cron list --all
openclaw plugins list
openclaw config get plugins.entries.tablero-runbook
gh pr merge 1 -R gon0801/goncloud-openclaw --squash
powershell -Command "Set-Content -Path $env:TEMP\tablero-runbook.json5 -Value '<JSON5>'"    (escribe)
openclaw config patch --file %TEMP%\tablero-runbook.json5 --dry-run                          (escribe)
openclaw config patch --file %TEMP%\tablero-runbook.json5                                    (escribe)
powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -File C:\Users\ehven\.openclaw\scripts\restart-openclaw-gateway.ps1' -WindowStyle Hidden"   (escribe)
```

El reinicio del último renglón **solo** se corre desde la fila de atores que lo autoriza, nunca por iniciativa propia.

El `Select-String` va **una función por turno**, no los seis patrones juntos: una búsqueda con alternancia imprime el archivo que casa *cualquiera* de ellos, y de ahí no sale el veredicto por función que pide la DoD. Si la ruta de `node_modules` que imprime `npm root -g` no es la escrita arriba, se sustituye por la real y se anota.

El `gh pr merge 1` tiene forma de escritura pero es **inerte por diseño**: ese PR ya está mergeado desde hace semanas, así que `gh` devuelve un error aunque el guard fallara. Verificado hoy: `gh pr view 1` da `MERGED`.

Desde tu worktree, **sin** pasar por el gateway, esta fase usa además: `~/.openclaw/bin/openclaw gateway call status|config.get|config.schema.lookup|sessions.list|runbook.progress.set|runbook.progress.get`, `git`, `gh` y `curl` sin credencial.

**`openclaw config patch` NO se corre desde la Mac.** Escribe `~/.openclaw/openclaw.json`, el archivo local, y nunca toca el gateway; la lectura de vuelta con `openclaw config get` desde aquí contesta `unset` para rutas que sí están puestas. Las dos cosas están medidas en `docs/patches/README.md`, que está en `origin/main`. Por eso el patch de Q3 va por exec, en el host donde el CLI es local a la configuración.

---

## Preaprobaciones del dueño

| Operación | Alcance | Decisión |
|---|---|---|
| `git push` + `gh pr create` | Todo PR de esta fase: Q0a (#53), Q0b (este runbook), docs (D), código (P), cierre, y los de reversa | Aprobado |
| Merge por la ruta del kit (loop §6) | Todo PR de esta fase, en el orden Q0a a Q5; `--confirmado` con este runbook como el sí escrito | Aprobado |
| Turno de **lectura** a main por exec, con la lista cerrada de arriba | Spike 7.0, compuerta de Q2, canarios de Q3 | Aprobado |
| Turno de **escritura** a main por exec, **solo** los tres comandos marcados (escribe) y, en su fila de atores, el reinicio del gateway | 7.6 y su reversa | Aprobado |
| Desde la Mac: `gateway call` de los métodos listados, `git`, `gh`, y `curl` sin credencial al puerto del gateway | Spike, compuertas y canarios | Aprobado |
| Código nuevo vivo en el gateway (plugin sin hooks) y un `gh pr merge` de prueba que debe salir bloqueado | 7.4, 7.5, 7.6 | Aprobado |
| Lanzar implementadores en tmux sobre worktrees desechables, con aprobaciones resueltas por el lead | Carriles P y D | Aprobado |
| Un Telegram a David: el de cierre con el enlace al tablero, o el de detención que lo sustituye | 0.0, 7.6 y 7.7 | Aprobado |
| `tablero-runbook/package.json` con script `check` y **sin** `dependencies` | 7.3, igual que summa-gate | Aprobado |
| Instalar dependencias en `tablero-runbook/` | El `package.json` de arriba no cuenta: lo negado son dependencias | **Negado** |
| Registrar hooks de agente o tools en el plugin | Mezcla guard con interfaz; es el motivo de que sea un plugin aparte | **Negado** |

---

> **Prohibido toda la corrida:** tocar `openclaw.json` en el repo, modelos, auth, crons o permisos del gateway fuera de `plugins.entries.tablero-runbook.*`; correr por exec cualquier comando que no esté en la lista cerrada; leer o imprimir cualquier secreto (el lanzador `~/bin/glm` contiene un token: se ejecuta, jamás se lee ni se pega); registrar hooks de agente o tools en el plugin; `git worktree remove --force` o `git worktree add --force`; enviar Telegram antes del cierre salvo las cuatro salidas que este documento autoriza (la detención en 0.0 y las tres filas de atores que lo dicen); preguntarle algo a David.

---

## Cómo se lanza un implementador

Para cada carril, en este orden. Los dos carriles llevan lo mismo, incluido el marcador.

**1. Elegir el binario.** Se prueban **por nombre**, y la sonda tiene que resolver como resuelve el lanzador: en `bash`, con el PATH que él mismo se pone.

```
for t in glm cursor-agent muse; do
  if bash -c 'PATH=$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH; command -v '"$t" >/dev/null 2>&1
  then echo "$t=ok"; else echo "$t=AUSENTE"; fi
done
```

**Los dos detalles de esa línea son medidos, no estilo.** Primero, `command -v` **en tu propia shell no sirve**: el arranque de zsh define una función con el nombre de cada herramienta de la lista, exista o no el ejecutable, así que ahí `glm`, `cursor` y `muse` siempre responden 0 y la rama "AUSENTE" nunca se alcanza. En `bash` esas funciones no existen y lo que queda es el ejecutable, que es lo que el lanzador va a buscar: si no lo encuentra sale `exit 4` con `tool not found: <tool>`. Segundo, la forma `test -x "$b"; echo "$(basename $b)=$?"` imprime `0` siempre, porque la sustitución de comando corre antes de que se expanda `$?` y reporta el estado de `basename`.

**2. Abrir la sesión, desacoplada.** El lanzador `~/bin/agent-tmux.sh` **no puede desacoplarse**: termina llamando a tmux en modo attach, sin la bandera de desacople, y no acepta esa bandera por ningún lado. Desde dentro de tmux, que es donde vives, eso sale `open terminal failed: not a terminal` con rc=1, y `TMUX=` no lo arregla: quita el error de anidamiento, no da un tty. Así que la sesión se crea directo:

```
T=/opt/homebrew/bin/tmux
BIN=$(bash -c 'PATH=$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH; command -v <token>')
$T has-session -t <token>-wt-f7-P 2>/dev/null && echo YA-EXISTE || \
  $T new-session -d -s <token>-wt-f7-P -c /Users/dn/dev/wt-f7-P "$BIN"
```

El nombre se escribe igual que lo armaría el lanzador, `<token>-<basename del directorio>`, para que cualquier skill que busque por ese patrón lo encuentre. `YA-EXISTE` manda a su fila de atores. **Anota el token y el nombre** en `.saikit/progress/7-sesiones.txt`: Q5 los necesita y el `-Excluir` depende del token.

**3. Entregar el encargo y confirmar.**

```
/opt/homebrew/bin/tmux send-keys -t <sesión> -l 'Lee /Users/dn/dev/wt-f7-P/BRIEF.md y haz lo que pide'
/opt/homebrew/bin/tmux send-keys -t <sesión> Enter
/opt/homebrew/bin/tmux capture-pane -p -t <sesión> -S -30
/opt/homebrew/bin/tmux set-environment -t <sesión> OPENCLAW_WATCH 1
```

El `Enter` va en llamada aparte: en el mismo envío se lo traga el TUI. **Arrancó** cuando la captura muestra que el CLI leyó el archivo (su propia línea de lectura o el primer paso del plan); **no arrancó** si la captura sigue mostrando el prompt vacío pasados 60 s.

**4. El modo sin preguntas, medido para los tres.** Leído de la ayuda de cada binario el 2026-09-17:

| Token | Binario | Modo sin preguntas | Modo sin interfaz |
|---|---|---|---|
| `glm` | zcode, vía el lanzador de la Mac | `--mode yolo`, que además es el default cuando se le pasa un prompt | `-p` |
| `cursor-agent` | el CLI de Cursor | `-f` (alias `--yolo`), más `--trust` para no preguntar por el directorio | `-p`, con `--output-format json` |
| `muse` | el CLI de muse | `--permission-profile <id>`, con el id en `unknown` (ver abajo) | el subcomando `exec`, con `--json` |

**El flag va en el lanzamiento, y por eso el comando de arriba no lo trae escrito.** El bloque que abre la sesión termina en `"$BIN"` a secas porque el flag depende de qué binario ganó la sonda: el lead le agrega el de la fila que le tocó, y solo se lanza sin flag en el caso de la última frase de esta sección. Lanzar con flag disponible y además contestar a mano no es la intención; el flag es lo que evita las preguntas.

**El id del perfil de muse es `unknown`, y se queda `unknown`.** El flag existe, pero muse no lista sus perfiles: ni `muse config status` ni su configuración local los nombran, comprobado hoy. Así que para muse el lead **no inventa un id**. Se lo pregunta a muse en el primer turno ("qué perfiles de permiso acepta") y lo anota junto al nombre de sesión, o lo lanza sin el flag y contesta las aprobaciones a mano, que es la ruta de la última frase. Un id inventado se rechaza en el arranque y el carril nace muerto sin decir por qué.

**Ojo con el token de Cursor: es `cursor-agent`, no `cursor`.** En esta Mac, `cursor` es un envoltorio que busca el IDE de escritorio y muere con "No Cursor IDE installation found"; el agente de verdad es el otro. Verificado hoy corriendo los dos.

Si en el futuro un binario cambia y el flag ya no existe, se averigua igual, no se adivina:

```
<token> --help 2>&1 | grep -i -E 'permission|approve|force|yolo|sandbox|trust'
```

`trust` va en el patrón a propósito: es el flag de `cursor-agent` para no preguntar por el directorio, y sin esa palabra la comprobación encuentra los de `glm` y `muse` pero **no** el suyo, así que un cambio en él pasaría por un binario sin flags. Si agregas una herramienta a la lista, agrega también la palabra de su flag aquí, o la comprobación mentirá para ella.

Y si de verdad no ofrece ninguno, el carril se lanza **sin flag** y el lead contesta las aprobaciones él mismo con `/opt/homebrew/bin/tmux send-keys`, usando la tabla de preaprobaciones como respuesta: lo `Aprobado` se acepta, lo `Negado` se rechaza, y lo que no está en la tabla se rechaza y se anota como residual. Un flag adivinado puede abrir la sesión en un modo que el dueño no aprobó.

**Los tres traen además modo sin interfaz**, que no es el camino de este runbook pero conviene saberlo: el lead vigila por pantalla porque así puede intervenir y porque la sesión sobrevive si el lead se muere, cosa que un proceso sin interfaz no hace.

**5. TIMEBOX.** Cada carril tiene **6 horas** de reloj desde el lanzamiento hasta su `LISTO`. A las 6 h el carril pasa a `atorado` con lo que tenga, y el lead cierra con el otro. Dentro de ese tope, la regla de silencio es la de loop §12: 30 minutos sin mensaje dispara la comprobación de cuota y el relanzamiento.

**6. VERIFY, los comandos exactos que van en cada encargo.**

| Carril | VERIFY |
|---|---|
| P | `cd /Users/dn/dev/wt-f7-P && bash scripts/run-checks.sh` en verde, y `cd tablero-runbook && node --test` con el conteo de `pass` pegado |
| D | los dos comandos de 7.2, con las dos salidas (ROJO y VERDE) pegadas |

---

## El spike 7.0

Lo corres tú, en 0.3. Produce `/Users/dn/dev/wt-f7-D/docs/evidence/tablero-runbook-spike.md` con **cada comando y su salida verbatim recortada**, como pide la DoD.

**Seis veredictos, uno por función**, cada uno de su propio turno con el `Select-String` de la lista cerrada: `registerGatewayMethod`, `registerControlUiDescriptor`, `registerHttpRoute`, `backupResources`, `stateDir`, `dataDir`. Cada uno queda `presente`, `ausente` o `unknown`.

**El directorio de estado**, que es la decisión 2: `powershell -Command "Get-ChildItem C:\Users\ehven\.openclaw -Directory | Select-Object Name"` dice si un plugin instalado guarda su estado dentro del clon desplegado. Si el listado no lo aclara, el veredicto es `unknown` y aplica la fila de atores, que ya trae el default.

**Las dos sondas desde la Mac** que la tarea 7.0 nombra en `Plans.md`, y que también van en la evidencia:

```
G=~/.openclaw/bin/openclaw
$G gateway call status --timeout 30000                                  # debe responder
$G gateway call runbook.progress.get --params '{"fase":"6"}' --timeout 30000
```

La segunda **debe fallar por método desconocido, no por auth**: eso es lo que prueba que la autenticación del gateway ya está pasada y que lo único que falta es el plugin.

**El código HTTP sin credencial.** La URL del spike es la de la Control UI, porque el plugin todavía no existe:

```
curl -s -o /dev/null -w '%{http_code}' http://100.80.179.76:18789/__openclaw__/a2ui/
```

**Si el egress a esa IP te lo niega tu entorno** (la tailnet no siempre está disponible desde donde corre el lead, y algunos hosts exigen aprobación humana para salir a red), el dato queda `unknown` y **la fase sigue**: no se pide ninguna aprobación. Las dos compuertas que dependen de ese `curl`, esta y el canary (b) de Q3, tienen su equivalente por RPC, que es el camino principal; el `curl` es confirmación, no requisito.

**El formato de la línea de veredicto es fijo**, porque de él depende la única comprobación que protege el spike. Una línea por función, exactamente así, y D no puede cambiarlas de forma:

```
veredicto registerGatewayMethod: presente
```

**D no cambia veredictos.** Guardas tus seis líneas antes de entregarle el archivo y después comparas las seis, no un conteo:

```
E=/Users/dn/dev/wt-f7-D/docs/evidence/tablero-runbook-spike.md
grep -E '^veredicto [A-Za-z]+: (presente|ausente|unknown)$' $E | sort > /tmp/f7-despues.txt
diff /tmp/f7-antes.txt /tmp/f7-despues.txt && echo VEREDICTOS-INTACTOS || echo VEREDICTOS-CAMBIADOS
```

Un conteo no sirve: seis líneas siguen siendo seis aunque las seis palabras cambien. `VEREDICTOS-CAMBIADOS` manda el carril D de vuelta al loop con la salida del `diff` como encargo.

---

## Carriles

Los dos parten de `origin/main` tal como esté al abrirlos, nunca de la rama del otro. Sus archivos son disjuntos, así que el orden en que abran sus PRs no importa.

**Sobre la dependencia que declara el plan.** `Plans.md` marca 7.2 con `Depends: 7.1`. Ya está saldada: 7.2 escribe un test de anclas sobre `docs/runbooks/autopilot-fase6.md`, cuya regla 8 ya está en `origin/main`, y sobre el spec, que también. No necesita los fixtures de P.

### P · El plugin — rama `fase7/tablero`

- [ ] **7.1 Fixtures, en rojo.** `tablero-runbook/fixtures/` con `fase6-en-curso.json`, `fase6-cerrada.json`, `fase6-diez-prs.json` e `invalido.json`, más `progress.test.ts` sin validador todavía. Los válidos deben pasar y `invalido.json` fallar con **cinco razones nombradas**. `omitido` no aparece en los fixtures y se declara. Los PRs de los fixtures son **reales y ya mergeados**: `gon0801/goncloud-openclaw` #43, #44, #45; `gon0801/goncloud-workspace-main` #15; `gon0801/goncloud-workspace-ingenieria` #8; `gon0801/goncloud-workspace-operaciones` #5. `fase6-diez-prs.json` llega a diez repitiendo esos seis entre `carriles[]` y `cola[].prs[]`. Ningún número inventado.
- [ ] **7.3 Núcleo puro `tablero-runbook/lib.ts`**, sin dependencias, más `tablero-runbook/package.json` con script `check` y sin `dependencies`: `validarFase`, `validarProgreso`, `derivar`, `renderTablero` con **una sola `esc()` en el punto de interpolación**, truncando primero y escapando después; banner de `atencion_requerida` arriba de todo; `siguiente_paso` como primera frase; rótulo "GitHub: sin verificar"; `fusionarEventos` append-only con el tope y la rotación de `summa-gate/observer.ts`. Mutantes que deben dejar rojo: quitar `esc()`, invertir truncar/escapar, quitar el truncado, aceptar un `estado` fuera de lista, aceptar `fase` con `/` o `..`, aceptar `repo` con `;` o que empiece con `-`, y perder eventos previos al fusionar. `scripts/run-checks.sh` gana su bloque `tablero-runbook` con guard de conteo (0 `pass` = FALLA) y `scripts/tests/test-summa-gate-quality-entrypoints.sh` se extiende para exigir lo mismo de ese `package.json`.
- [ ] **7.4 Cableado `index.ts` + manifest.** `runbook.progress.set` (scope `operator.write`) pasa `fase` por `validarFase` **antes de tocar disco**; `runbook.progress.get` devuelve `{doc, derivado, html}`. Rutas con `auth: "gateway"` y los tres headers. `stateDir` según el spike. Pestaña solo si el spike la confirmó. **Cero `registerHook`, cero `registerTool`.** En el mismo PR: `.gitignore` con `tablero-runbook/*.jsonl` y `*.log`; la tercera entrada, la ruta de estado, **solo si el estado cae dentro del clon** — si cae fuera, no se escribe y se declara en el PR, porque una ruta absoluta de Windows no es un patrón de `.gitignore`. `scripts/tests/test-salida-del-observador-no-trackeada.sh` se extiende. Tests con host simulado local (patrón de `summa-gate/role.test.ts`).
- [ ] **7.5 Cruce con GitHub, apagado por defecto.** `execFile` con argv literal y `shell:false`; `ghPath` de configuración, default `C:\Users\ehven\.openclaw\tools\bin\gh.exe`, **debe terminar en `.exe`** (un `.cmd` reabre el bug de comillas de Windows); subcomando fijo `pr view`. Presupuesto **total** 8 s por render, ≤10 PRs, concurrencia ≤4, caché 60 s, `kill()` real al vencer; cualquier fallo pinta "GitHub: unknown" en esa fila. Mutantes: quitar el flag, `repo="a/b; calc.exe"`, `repo="--template x"`, `ghPath` en `.cmd`, y quitar el `kill`.

### D · Docs y anclas — rama `fase7/docs`

- [ ] **7.0 Evidencia del spike con formato.** Tú la escribiste; D la deja en el formato del repo **sin cambiar ningún veredicto**, y el lead lo comprueba con el `grep` de arriba.
- [ ] **7.2 Test de anclas `scripts/tests/test-runbook-progreso.sh`** sobre `docs/runbooks/autopilot-fase6.md`: anclas de `runbook.progress.set`, `.saikit/progress/`, "no detiene nada", `atencion_requerida`, "eventos clave" y el enlace al spec; anti-ancla que falla si el runbook dice que la interfaz "calcula" o "infiere" el progreso. El test toma la ruta del archivo por variable de entorno (`RUNBOOK=<ruta>`, default el del repo).

  **El rojo no se demuestra contra "el commit anterior".** Tres commits tocaron ese archivo y el penúltimo ya traía las seis anclas. Se localiza por contenido:

```
INTRO=$(git log --format=%H -S'runbook.progress.set' origin/main -- docs/runbooks/autopilot-fase6.md | tail -1)
git show $INTRO^:docs/runbooks/autopilot-fase6.md > /tmp/fase6-previo.md
RUNBOOK=/tmp/fase6-previo.md bash scripts/tests/test-runbook-progreso.sh   # debe salir ROJO
bash scripts/tests/test-runbook-progreso.sh                                 # debe salir VERDE
```

  Medido hoy: `INTRO` es `7fbcb9a` (el PR #46) y su padre `f8acd56` trae **cero** de las seis anclas. Si `INTRO` sale vacío, el carril lo declara en vez de inventar un SHA. Las dos salidas van pegadas en el PR.

  El "Slot 12 Progreso" que `Plans.md` menciona para la skill `autopilot-runbook` ya está escrito, y la copia canónica de esa skill entra en este repo por Q0b: no es trabajo de este carril y se declara así en el PR.
- [ ] **Spec delta**: sección "Tablero de runbook" en `docs/spec/00-project-spec.md` con las **cinco** declaraciones del plan: las cuatro reglas más la quinta que la DoD de 7.4 exige, que `get` y la ruta `.json` exponen `residuales` y `eventos` a quien pase la auth del gateway. Más `scripts/tests/test-spec-tablero.sh` con anclas de las cinco frases.

### Archivos por carril

| Carril | Puede tocar | No toca |
|---|---|---|
| runbook (Q0b) | `docs/runbooks/autopilot-fase7.md`, `docs/agent-skills/autopilot-runbook/SKILL.md`, `scripts/tests/test-skill-autopilot-runbook.sh` | todo lo demás |
| P | `tablero-runbook/**`, `scripts/run-checks.sh`, `scripts/tests/test-summa-gate-quality-entrypoints.sh`, `scripts/tests/test-salida-del-observador-no-trackeada.sh`, `.gitignore`, `.saikit/scratch/P/**` | `docs/**`, `summa-gate/**`, `Plans.md`, `agents/**`, `workspace-*/**` |
| D | `docs/evidence/tablero-runbook-spike.md`, `docs/spec/00-project-spec.md`, `scripts/tests/test-runbook-progreso.sh`, `scripts/tests/test-spec-tablero.sh`, `.saikit/scratch/D/**` | `tablero-runbook/**`, `summa-gate/**`, `Plans.md`, `scripts/run-checks.sh`, `.gitignore` |
| cierre | `Plans.md` (celdas Status, y **solo** las tres celdas de DoD nombradas en Desviaciones), `.saikit/progress/7.json`, `.saikit/progress/7-sesiones.txt`, `docs/evidence/tablero-runbook-canary.md` | todo lo demás |
| reversa | hereda la columna de P, y nada más: solo puede **quitar** lo que P puso | todo lo demás |

`BRIEF.md` y `BRIEF-r<N>.md` no entran en ninguna columna a propósito: viven en la raíz del worktree y **se borran antes del push**, así que no cuentan como "archivo fuera de la tabla" (loop §12). El encargo que importa queda citado en el cuerpo del PR.

---

## Reglas propias de esta fase

1. **El spike es tuyo.** 7.0 lo corres tú, no un implementador.
2. **El encargo de P lleva las dos decisiones del spike pegadas** en su CONTEXT, no el archivo: ese vive en el worktree de D.
3. **Un commit por tarea dentro del carril**, mismo PR. Es lo que hace posible la revisión cruzada, que solo sabe revisar un commit (loop §4). Orden en P: 7.1 → 7.3 → 7.4 → 7.5. En D: 7.0 → 7.2 → Spec delta.
4. **El progreso y la evidencia del canary se escriben en `wt-f7-lead`** y se copian al worktree de cierre en Q5 con un `cp` explícito. Los dos están en la fila "cierre" de la tabla, así que la copia no es un archivo fuera de tabla.
5. **El archivo del progreso es `.saikit/progress/7.json`**: la fase es `7`, como en `runbook.progress.set --params '{"fase":"7"}'`. El precedente `fase6.json` quedó con otro nombre; el spec manda `<fase>.json` y esta fase lo cumple.
6. **`paso_loop` se satura en 8.** El spec cierra ese campo en el rango 0 a 8 y el loop tiene once pasos, así que los pasos 9, 10 y 11 (merge, despliegue, progreso) se escriben también como `8`: el estado real de esos tres ya lo dice `carriles[].estado`, que pasa a `mergeado`. Es lo que hizo la Fase 6 y es lo que un validador que respete los valores cerrados va a aceptar. No se inventa un 9.

### Desviaciones del loop y del plan, nombradas

**Del loop:**

- **§3 paso 5 y §4 no aplican a Q0a, Q0b, Q5 ni al PR de reversa.** Los tres son documentación ya revisada: su loop es CI verde + CodeRabbit con la regla de §5 + `APPROVE lead <sha>`. Q0a es el propio loop, ya revisado en su PR; Q0b es este documento, revisado por cuatro lecturas con contexto fresco; Q5 son celdas de estado con evidencia ya producida. El de reversa deshace código que ya pasó por el loop completo, y esperar una ronda cruzada mientras el gateway está en mal estado cuesta más de lo que protege.
- **§5, tope de tres PRs abiertos:** cuenta **solo los de esta fase**, y Q0 son **dos** PRs, no uno. Por eso el orden de apertura es: Q0a y Q0b primero, se mergean, y **después** se abren D y P. Así nunca hay más de tres propios abiertos. Los PRs ajenos no cuentan y no se cierran por esto.
- **§7, "el cambio de configuración lo hace el lead desde la Mac":** aquí el patch va **por exec en el host del gateway**, porque `openclaw config patch` desde la Mac escribe el JSON local y no llega al gateway. La razón de §7 sigue en pie y **no se minimiza**: un `config patch` recarga la configuración y **mata las corridas en vuelo** por el mecanismo *superseded*, medido en este gateway y escrito tanto en `docs/patches/README.md` como en la fila 7.6 de `Plans.md`. De ahí salen dos consecuencias que este runbook sí escribe. Una: las cero corridas en vuelo se verifican antes, y por eso la lectura autoritativa es `cron list --all`. Dos: **el turno que dispara el patch puede morir con las demás**. Si ese turno no responde, eso **no** significa que el patch falló: se lee el estado con un turno nuevo antes de concluir nada, y solo el read-back decide.

**Del plan** — las tres celdas de DoD que Q5 tiene permitido corregir, y nada más:

| Celda | Qué dice hoy | Qué corrige Q5, y por qué |
|---|---|---|
| 7.2 DoD | "`test-runbook-progreso.sh` **rojo contra `origin/main`**" | Las seis anclas ya están en `origin/main` desde el PR #46. El rojo válido es contra `f8acd56`, el padre del commit que las introdujo. |
| 7.4 DoD | pide la quinta declaración del spec sin asignarla a nadie | Se asigna al carril D, junto a las otras cuatro. |
| 7.3 DoD | pide `tablero-runbook/package.json` mientras la tabla de preaprobaciones niega "instalar dependencias" | No hay conflicto: lo negado son dependencias, no el archivo. La celda se aclara. |

Cualquier otra diferencia entre el plan y este runbook se **declara** en el PR de cierre, no se edita.

---

## Cola de merge

Ruta y comando del merge: loop §6. La cola tiene siete ítems y **cinco son merges**: Q0a, Q0b, Q1, Q2 y Q5. Q3 es un cambio de configuración y Q4 es una comprobación; ninguno de esos dos mergea nada. **Los cinco merges van en la ventana segura de loop §7**, sin excepción: mergear a `main` es desplegar, y eso vale igual para docs que para código. Q3 agrega además la verificación de cero runs, porque toca la configuración. **Cada merge se corre desde el worktree de esa rama.**

**El lock del kit es uno solo para todo el clon.** Se toma en el directorio común de git, el mismo archivo para los cinco worktrees de esta fase y para cualquier otro del mismo clon. Un lock ajeno **bloquea con código 3** y solo `--liberar-lock` explícito lo quita: nunca se borra solo, ni con el pid muerto. Ver su fila de atores.

- [ ] **Q0a · El PR #53, el loop**, si 0.0 lo encontró abierto. Loop reducido.
  **Compuerta:** `git cat-file -e origin/main:docs/runbooks/loop-autopilot.md` sale 0, y después `bash scripts/tests/test-loop-autopilot.sh` sale verde. Si #53 se cerró sin mergear, la fase se detiene: este runbook lo referencia por sección y sin él no hay reglas. Si el test sale **rojo** después del merge, la fase también se detiene y se declara con la línea del FAIL: el loop llegó a `main` roto y ninguna regla de abajo es confiable.
- [ ] **Q0b · Este runbook: el PR #54**, rama `docs/fase7-runbook`, si 0.0 lo encontró `OPEN`. Loop reducido. Ese PR ya trae los cuatro archivos de su fila en la tabla, ya commiteados: este runbook, la copia canónica de la skill `autopilot-runbook`, el candado de esa skill, y el detector del lead como rol en `test-runbooks-no-contradicen-entorno.sh`. No hay nada que escribir.

  **Primero se promueve, luego se mergea.** `gh pr view 54 --json isDraft -q .isDraft` tiene que decir `false` antes de tocar la ruta del kit: GitHub rechaza mergear un borrador, y el script del kit no mira ese campo (lee `mergeable`, que en un borrador dice `MERGEABLE` igual), así que llegaría hasta el final y fallaría ahí. Si sale `true`: `gh pr ready 54`, esperar a que CodeRabbit termine su única pasada, atender lo que traiga con la regla de loop §5, y recién entonces mergear. Lo mismo vale para cualquier PR de esta fase que encuentres en borrador. Su worktree se abre ad hoc como cualquier otro PR sin worktree propio (loop §6) en `/Users/dn/dev/wt-f7-q0b`.
  **Compuerta:** `gh pr view 54 --json state -q .state` sale `MERGED`, y después `bash scripts/tests/test-runbooks-no-contradicen-entorno.sh` y `bash scripts/tests/test-skill-autopilot-runbook.sh` salen verdes contra `main`. Si cualquiera sale rojo, la fase se detiene y se declara con la línea del FAIL, por la misma razón que en Q0a.
- [ ] **Q1 · D primero.** Solo docs y tests, así que el sync lo lleva sin riesgo de romper nada vivo; **la ventana segura de loop §7 aplica igual**, como a todo merge a `main` de esta cola, porque el sync no distingue qué trae el commit.
  **Compuerta:** la corrida de CI **de ese SHA**, no la última de `main`:

```
SHA=<sha del squash>
for i in 1 2 3 4 5 6 7 8 9 10; do
  r=$(gh run list --workflow quality.yml --commit "$SHA" --limit 5 \
        --json status,conclusion --jq '.[] | "\(.status) \(.conclusion)"' | head -1)
  echo "intento $i: ${r:-sin-corrida}"
  case "$r" in "completed success"|"completed failure") break ;; esac
  sleep 60
done
```

  El filtro va en `--commit`, que es de la propia herramienta, **no en el `jq`**: `--limit` se aplica **antes** de filtrar, así que con diez corridas más nuevas en `main` la del SHA se queda fuera de la lista y el ítem se marcaría `sin-corrida` con el CI en verde. Y `--limit 1` sin filtro devuelve la última corrida de `main`, que en el minuto siguiente al merge todavía es la anterior, o la nueva con `conclusion: null`. Tres salidas: `completed success` cierra el ítem; `completed failure` manda el carril de vuelta al loop §3 con el log del job como encargo y **P no se mergea** hasta que `main` esté verde; `sin-corrida` o `in_progress` a los diez intentos queda `unknown`, se anota y **P tampoco se mergea** ese ciclo.
- [ ] **Q2 · P después de D**, solo, en ventana segura. Mergear **no** lo enciende: el plugin queda deshabilitado hasta Q3. Misma compuerta de CI que Q1, y además:
  **Compuerta del sync:** tras el siguiente ciclo, por exec, el SHA mergeado tiene que estar **en la historia** del clon del gateway, no ser su punta:

```
git -C C:\Users\ehven\.openclaw merge-base --is-ancestor <SHA> HEAD && echo PRESENTE || echo AUSENTE
```

  La punta casi nunca es el SHA mergeado: el sync hace `add -A` y commitea su propio snapshot **antes** del pull, así que cuando el árbol del gateway está sucio su último commit es ese snapshot. Cinco de los últimos doce commits de `main` son snapshots del sync. Leerlo por igualdad de punta bloquearía el despliegue por una causa que no existe. Se pide además la cola del log del sync sin `CONFLICTO` ni `FALLO`. Si sale `AUSENTE` y el log no muestra error, el sync aún no corrió: se espera un ciclo más y se repite **una** vez. Si a la segunda sigue `AUSENTE`, **no se pasa a Q3** y se declara. Si el log muestra `CONFLICTO`, **tampoco**: se anota como residual y la fase cierra sin despliegue. Si el log no existe, el dato es `unknown` y se trata igual que un `AUSENTE`.
  **Cómo se espera un ciclo de sync de dos horas:** no con un `sleep` de dos horas. El lead sigue con lo que tenga pendiente y vuelve a esta compuerta cada 30 minutos con la lectura por exec; entre lecturas escribe progreso, así que su silencio nunca pasa de 30 minutos y no dispara la regla de carril muerto de loop §12.
- [ ] **Q3 · Despliegue 7.6.** Solo si Q2 cerró con el SHA confirmado.

  **Refresca tu worktree primero.** `wt-f7-lead` nació `--detach` en el `origin/main` del arranque, así que `tablero-runbook/fixtures/` no existe ahí hasta que lo muevas:

```
git -C /Users/dn/dev/wt-f7-lead fetch origin
git -C /Users/dn/dev/wt-f7-lead checkout --detach origin/main
```

  **Cero runs en vuelo, verificados.** La lectura autoritativa es `openclaw cron list --all` por exec: `cron runs <id>` **solo muestra entradas ya terminadas**, así que un job corriendo es invisible ahí. Se exige: ningún job en estado `running`, ninguno con `Next` en menos de 15 minutos, y ninguna sesión con actividad reciente:

```
G=~/.openclaw/bin/openclaw
$G gateway call config.get --params '{"path":"agents.entries"}' --timeout 30000
$G gateway call sessions.list --params '{"agentId":"<agente>","limit":20}' --timeout 30000
```

  Uno por cada agente que el gateway declare vivo (hoy ocho: `main`, `operaciones`, `ingenieria`, `implementer`, `verifier`, `reviewer`, `adversary`, `scout`, aunque el repo solo versione cinco directorios bajo `agents/`). El RPC **exige** `agentId`: sin él falla con "unable to open database file", que no es corrupción. Un `agentId` que el gateway no declara no se consulta. Se compara `updatedAt` contra `date +%s000`: **reciente son 10 minutos**, el mismo umbral que usa la Fase 6. Sin ese campo el dato es `unknown` y se esperan 15 minutos sin lanzar nada; al terminar esa espera **se repite la lectura completa una vez**, y si sigue `unknown` se aplica el patch igual, anotándolo en `eventos`: quedarse esperando para siempre por un campo ausente detiene la fase por algo que no es un fallo.

  **El patch**, por exec, con los tres comandos marcados (escribe) de la lista cerrada, en ese orden: escribir el JSON5 en `%TEMP%`, `--dry-run`, y aplicar solo si el dry-run pasó ("Dry run successful"). Contenido del primero:

```
{ plugins: { entries: { "tablero-runbook": {
    enabled: true,
    config: { fases: ["6","7"], github: { enabled: false } }
} } } }
```

  Esa forma es válida: medido hoy, `plugins.entries` acepta ids arbitrarios, y cada entrada admite exactamente `enabled`, `hooks`, `subagent`, `llm` y `config`. El segundo patch cambia solo `github.enabled` a `true`.

  **Lectura de vuelta: `openclaw config get plugins.entries.tablero-runbook` por exec**, en el host del gateway. Desde la Mac ese mismo comando contesta `unset` para rutas que sí están puestas, y sería un verde falso.

  **Canarios, en orden.** Desde la Mac, por RPC:

```
G=~/.openclaw/bin/openclaw
$G gateway call runbook.progress.set --params @tablero-runbook/fixtures/fase6-en-curso.json --timeout 30000
$G gateway call runbook.progress.get --params '{"fase":"6"}' --timeout 30000
```

  (a) La respuesta de `get` trae `doc`, `derivado` y `html`. **Toda la evidencia del HTML sale de ahí**, por RPC, sin ninguna petición autenticada: en `html` deben aparecer el `titulo` del fixture y "GitHub: sin verificar", y `doc` es el cuerpo que la DoD llama `GET /runbook/progress/6.json`. Eso se declara en la evidencia como la sustitución que es.
  (b) `curl -s -o /dev/null -w '%{http_code}' http://100.80.179.76:18789/runbook/tablero/6` **sin credencial**, que debe dar 401 o 403. Si el egress está negado desde donde corres, queda `unknown` y la fase sigue: (a) ya probó que la ruta responde y que la auth está en su sitio.
  (c) summa-gate sigue vivo: `openclaw plugins list` con los dos habilitados, y el `gh pr merge 1` de prueba por exec, cuya salida esperada contiene "Merge bloqueado por summa-gate". **Va a main porque main es el agente que este runbook ya usa para exec.** La allowlist del guard existe, pero no cubre este comando: leído hoy en `origin/main`, `gh pr merge` se bloquea para **todo** agente sin consultarla, y lo que la allowlist abre a `implementer` e `ingenieria` son la mutación GraphQL de merge y las rutas de merge de la API. Así que este canary prueba el guard desde cualquier agente, y main es el que ya está en la lista cerrada. Un canary con la ruta de la API sí tendría que evitar esos dos, y este no la usa. Tope 10 minutos; sin respuesta, `unknown`, se repite una vez, y si sigue `unknown` se trata como "summa-gate no bloquea".

  Después `github.enabled: true` y canary 2, donde una fila debe pintar un estado rotulado "GitHub".

  **Devuelve la Fase 6 a su estado real antes de seguir.** Los canarios dejaron el tablero de la fase 6 mostrando un fixture, y el spec es last-writer-wins: si nadie lo corrige, David abre el tablero y ve una Fase 6 con un carril atorado que no existe. El cierre verdadero está versionado:

```
$G gateway call runbook.progress.set --params @.saikit/progress/fase6.json --timeout 30000
$G gateway call runbook.progress.get --params '{"fase":"6"}' --timeout 30000   # debe traer el cierre, no el fixture
```

  Por último, envías el progreso real de **esta** fase y confirmas que aparece en `runbook.progress.get --params '{"fase":"7"}'`.

  **La evidencia que exige la DoD de 7.6**, en `docs/evidence/tablero-runbook-canary.md`: cada comando con su salida verbatim; el `doc` de la respuesta de `get` (el cuerpo que la DoD llama `/runbook/progress/6.json`, con su sustitución declarada); las primeras 30 líneas del `html`; la salida de `cron list --all` de antes y después del patch, que debe mostrar que ninguna corrida nueva empezó en medio; `plugins list` con los dos habilitados y el merge de prueba bloqueado; y el `message_id` del Telegram, que por orden se resuelve como dice la sección Telegram.

  **Compuerta:** si el plugin no aparece en `plugins list`, o summa-gate no bloquea, o el `curl` sin credencial devuelve 200, **rollback inmediato**: patch `enabled: false` por la misma vía, y repetir el canary de summa-gate. El 200 además abre un encargo para P (verificación propia de `Authorization` en las rutas) y no se vuelve a habilitar hasta que ese test esté verde en CI.
- [ ] **Q4 · El enlace para David.** Es `http://100.80.179.76:18789/runbook/tablero/7`. La pestaña "Runbook" de la Control UI **no** sirve como sustituto: el descriptor que `Plans.md` 7.4 especifica lleva `path:"/runbook/tablero/6"` clavado, así que abre la Fase 6. Si el spike confirmó la pestaña, se menciona como atajo a la Fase 6 y nada más; el enlace de esta fase es el de arriba. Esa IP es de la tailnet y está detrás de la auth del gateway.
  **Compuerta:** el último paso de Q3, el que envía el progreso real de esta fase y lo lee de vuelta con `runbook.progress.get --params '{"fase":"7"}'`, trajo un `html` donde aparece el `siguiente_paso` que tú escribiste en ese documento. **La comprobación va contra el `html`, no contra el `doc`**: el `doc` es el mismo objeto que acabas de mandar y compararlo contigo mismo no prueba nada; el `html` es lo que el plugin construyó, y es lo único que dice que se renderiza. Si ese paso quedó `unknown` o falló, Q4 no se da por cumplido: el Telegram sale igual pero dice que el tablero de la Fase 7 no se pudo confirmar, y queda como residual. **No se hace ninguna petición autenticada**: no hay credencial preaprobada y el bloque Prohibido veta leer secretos. El Telegram dice el enlace y dice, en una frase, que para verlo hay que estar en la tailnet y pasar la autenticación del gateway.
- [ ] **Q5 · Cierre 7.7.** Worktree `/Users/dn/dev/wt-f7-cierre`, rama `fase7/cierre` desde `origin/main` con lo que haya mergeado de D y P.

  **Primero los archivos, cada uno con su condición.** Solo uno es obligatorio:

```
L=/Users/dn/dev/wt-f7-lead; C=/Users/dn/dev/wt-f7-cierre
cp $L/.saikit/progress/7.json $C/.saikit/progress/7.json                       # obligatorio
test -r $L/.saikit/progress/7-sesiones.txt && cp $L/.saikit/progress/7-sesiones.txt $C/.saikit/progress/
test -r $L/docs/evidence/tablero-runbook-canary.md && cp $L/docs/evidence/tablero-runbook-canary.md $C/docs/evidence/
if ! git -C $C cat-file -e origin/main:docs/evidence/tablero-runbook-spike.md 2>/dev/null; then
  test -r /Users/dn/dev/wt-f7-D/docs/evidence/tablero-runbook-spike.md \
    && cp /Users/dn/dev/wt-f7-D/docs/evidence/tablero-runbook-spike.md $C/docs/evidence/
fi
```

  El de sesiones no existe si ningún carril se lanzó, y el del canary no existe si la fase cerró sin llegar a Q3: en los dos casos **no se copia y se declara en el PR**, no se inventa un archivo vacío. La evidencia del spike se copia **solo si D nunca la mergeó**, porque la DoD de 7.0 la exige y sin PR de D su único ejemplar vive en un worktree que el paso 6 borra; si D sí la mergeó, ya está en `main` y copiarla duplicaría. La pregunta se le hace a `main`, no al worktree de D: después de un squash el commit de D no es antepasado de nada, así que comparar SHAs ahí no responde. Y va como `if`, no encadenado con `&&` y `||`: en esa forma, cuando la primera condición falla, la rama del `||` corre igual, que es justo lo contrario de lo que se quiere. Las celdas Status de `Plans.md` se cierran con el token literal **`cc:完了`** y el SHA de squash, solo con evidencia; las filas de 7.6 y 7.7 se cierran igual. Antes de cerrar: la **revisión de cierre de fase** del loop §10, contra la DoD literal de cada fila.
  **Compuerta:** CI verde sobre el SHA de cierre, con el mismo bucle por SHA de Q1.

  **Cómo termina tu turno, en orden:**
  1. Merge de Q5 desde `/Users/dn/dev/wt-f7-cierre`, por la ruta del kit.
  2. Telegram (§ Telegram).
  3. Último envío de progreso por RPC, ya con el `message_id`. **Si el plugin quedó apagado** (rollback, reversa, o Q2 cerrado sin despliegue), ese envío vuelve a fallar con "método desconocido", igual que en 0.4: se anota y se sigue. El archivo `.saikit/progress/7.json` que Q5 ya mergeó es entonces el registro, y el Telegram lo dice.
  4. `cd /Users/dn/dev/goncloud-openclaw` — **fuera de todo worktree de la fase**, porque no puedes borrar aquel en el que estás parado.
  5. Desmarcar **cada** sesión que hayas marcado, dejándolas abiertas (pueden ser dos, una, o ninguna si ningún carril se lanzó): `/opt/homebrew/bin/tmux set-environment -t <sesión> -u OPENCLAW_WATCH`, con los nombres de `7-sesiones.txt`.
  6. `git worktree remove <ruta>` para los que hayas abierto. Si uno se niega por sucio, se mira qué quedó: si son `.saikit/scratch/` o `BRIEF*.md`, se borran esos archivos y se repite; si es otra cosa, **no se fuerza**, se deja el worktree y se declara como residual. `git worktree prune` al final.
  7. Imprimes la línea de cierre que pide loop §2: **`LISTO <sha>`**, donde `<sha>` es el squash de Q5. Si algo quedó abierto, `ATORADO <razón>` en su lugar.

### Telegram

Se manda con la skill `telegram-send`, en `~/.claude/skills/telegram-send/SKILL.md`: script de Python en tu scratchpad, `scp` a `/tmp/` de goncloud y `ssh goncloud "python3 /tmp/<script>.py; rm -f /tmp/<script>.py"`. El script lee el token y el chat de un archivo de entorno en ese host; **tú no lo abres ni lo imprimes**, solo lo referencias, que es lo que el bloque Prohibido exige. Si tu host no lee `~/.claude/skills/`, la skill igual es un archivo: se lee con `cat`. La skill verifica `enviado: True` por mensaje; esta fase pide además que el script imprima el `message_id` del resultado, porque la DoD de 7.6 lo exige. Lo mandas tú, no claw. Que `.saikit/autopilot.json` traiga `"telegram": false` no aplica aquí: ese flag es del kit de merge, no de esta salida.

Contenido: PRs con SHA, lo que quedó abierto y por qué, residuales, lo revertido, el enlace del tablero y qué hace falta para abrirlo. En palabras de David, detalle técnico al final.

**El `message_id` no puede estar dentro del commit que lo precede.** El Telegram se manda **después** del merge de cierre, así que el archivo de evidencia que ya se mergeó lleva en esa línea: "message_id: se envía después del merge de cierre; queda en el progreso vivo". El id real viaja en el último envío de progreso por RPC, que es estado del gateway y no un archivo del repo. Esa sustitución se declara en el PR de cierre y en la revisión de cierre.

---

## Cuando algo se atora

Aplican todas las filas del loop §12. Estas son propias de la Fase 7.

| Situación | Qué hace el lead |
|---|---|
| Un worktree que 0.2 o Q5 necesita ya existe | Limpio, se reúsa y se anota. Sucio, se deja intacto, ese carril arranca en una ruta con sufijo `-b` (`/Users/dn/dev/wt-f7-P-b`) y se declara. Jamás `--force`. |
| La rama de un carril ya existe (relanzamiento) | `git worktree add <ruta> <rama>` sin `-b`. Si la rama está checkouteada en otro worktree del mismo clon, se usa ese worktree. |
| **Ningún binario de la lista de un carril existe** | Ese carril nace `atorado`, con `detenido_por` igual al texto de esta fila, y el otro sigue. La fase cierra con un solo carril. |
| **Ningún binario existe para ninguno de los dos** | Es el mismo conjunto para los dos carriles, así que es un caso real, no teórico. No hay nada que implementar ni nada que mergear: se mergean Q0a y Q0b si estaban pendientes, los dos carriles quedan `atorado`, se saltan Q1 a Q4, y Q5 cierra con `Plans.md` intacto y el progreso declarando por qué. El lead **no implementa en su lugar**. |
| Un implementador no arranca: la captura sigue en el prompt a los 60 s | Un `Enter` más. Si sigue igual, se cierra la sesión con `kill-session` y se relanza con el siguiente binario de la preferencia. Si se acaba la lista, aplica la fila de arriba. |
| Un implementador se queda parado pidiendo una aprobación | El lead la contesta por `/opt/homebrew/bin/tmux send-keys`, con la tabla de preaprobaciones como respuesta: lo `Aprobado` se acepta, lo `Negado` se rechaza, y lo que no está se rechaza y se anota como residual. No se despierta a David por una aprobación. |
| Un carril pasa su TIMEBOX de 6 h | Pasa a `atorado` con lo que tenga; si su trabajo es mergeable se mergea, si no se declara. El otro carril sigue. |
| **D queda atorado y P está listo** | P se mergea igual: sus archivos son disjuntos y su compuerta de CI es propia. La fase cierra con el código puesto y el docs declarado pendiente. |
| El spike dice que `registerControlUiDescriptor` está `ausente` o `unknown` | 7.4 sin pestaña; el tablero se abre por URL. Se declara en el PR y en el Telegram. |
| El spike dice que `registerGatewayMethod` o `registerHttpRoute` están `ausente` | Sin ellos no hay plugin: **P no se lanza**, D sí, la fase cierra con solo el PR de docs, y el Telegram dice que el tablero requiere actualizar el gateway. `atencion_requerida.necesaria: false`. |
| El spike dice `unknown` para esos dos | P se lanza con la firma de la documentación pegada en el encargo; el canary de Q3 decide. Si el plugin no carga, rollback y la fase cierra como en la fila anterior. |
| El directorio de estado cae dentro del clon, o `unknown` | 7.4 usa `configSchema.stateDir` con default `C:\Users\ehven\.openclaw-state\tablero-runbook`, fuera del clon; el `.gitignore` igual cubre `.jsonl` y `.log`. |
| El `curl` sin credencial devuelve 200 en el spike | La ruta del spike es la de la Control UI, que el plugin no sirve. Un 200 ahí significa que `auth: "gateway"` no protege como se asumía: 7.4 agrega verificación propia y se declara como hallazgo de seguridad. |
| El egress al puerto del gateway está negado desde donde corres | Ese dato queda `unknown` y **la fase sigue**. No se pide aprobación a nadie. Las dos compuertas que lo usaban, el código HTTP del spike y el canary (b) de Q3, tienen su equivalente por RPC y ese es el camino principal. Q4 no lo usa. |
| El dry-run del patch responde "Refusing to replace … it would remove existing entries" | Se repite el dry-run agregando `--replace-path plugins.entries.tablero-runbook` — la ruta **exacta** de esta fase, nunca `plugins.entries`, que sería un alcance más ancho del preaprobado. El flag sugerido `--replace` no existe. Si el guard sigue disparando con la ruta exacta, no se aplica nada y se declara. |
| Después del patch, `plugins list` no refleja el cambio a los 2 minutos | Se reinicia el gateway por exec, **desacoplado**, que aquí significa: el comando arranca el reinicio en un proceso aparte y devuelve enseguida, porque el script en primer plano espera hasta 40 s y el reinicio mata al nodo que lo dispara. Comando literal: `powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -File C:\Users\ehven\.openclaw\scripts\restart-openclaw-gateway.ps1' -WindowStyle Hidden"`, con `--session-key agent:main:reload-fase7`, y cero runs verificados con `cron list --all` justo antes. Es el único comando de escritura que esta fase agrega fuera de los tres del patch. Se espera hasta 5 min a que `gateway call status` responda. |
| Tras ese reinicio, el exec a main queda denegado ("approval cannot safely bind this command", "Approved executables: none") | Es el binder, no el gateway. **Ese documento no te sirve aquí**: su fallback verificado es entregarle un script a David para que lo corra él, y esta fase tiene prohibido pedirle algo. Léelo por si aporta otra vía, pero si no la hay, el estado del plugin queda `unknown` y aplica la fila de abajo. La ruta del documento es `agents/operaciones/agent/workshop-skills/openclaw-cron-jobs/exec-locked-fallback.md`. |
| El gateway no responde 5 min después del reinicio, o responde y el plugin sigue sin aparecer | Un patch `enabled: false` más. Si el gateway sigue mudo, es **el primero de los tres casos que llegan a David antes del cierre**: Telegram inmediato con `atencion_requerida.necesaria: true` y motivo "gateway sin respuesta tras reinicio". La fase se detiene ahí. |
| El plugin carga pero `runbook.progress.set` responde algo distinto de `{ok:true}` con un fixture válido | No se despliega `github.enabled`; rollback `enabled: false`; P vuelve a implementar con el error verbatim como encargo. |
| El `gh pr merge` de prueba **no** sale bloqueado tras habilitar el plugin | Rollback inmediato y repetir. Si sigue sin bloquear, es **el segundo caso que llega a David antes del cierre**: Telegram en ese momento con `atencion_requerida.necesaria: true`, la fase se detiene, y **ese Telegram es el de cierre**. |
| El patch de rollback falla o el gateway lo rechaza | Reintentar una vez a los 60 s. Luego leer el estado real por exec: si quedó deshabilitado, listo; si quedó habilitado y summa-gate **sí** bloquea, se deja y se declara; si quedó habilitado y summa-gate **no** bloquea, se va a la reversa por git de la fila siguiente. |
| Reversa por git de 7.4 | Worktree `/Users/dn/dev/wt-f7-revert`, rama `fase7/revert-tablero` desde `origin/main`, un solo commit `git revert <merge_commit_de_P>`, PR `revert: 7.4 tablero-runbook`, loop de emergencia (CI verde + `node --test` de summa-gate pegado + `APPROVE lead <sha>`, sin cruzado ni CodeRabbit), y merge con `--revert-de <merge_commit> --confirmado`. **Ese modo exige que el merge de P siga siendo la punta de `origin/main`**: si algo aterrizó después, el kit reporta y no revierte. Como esta fase mergea Q5 después de P, y hay PRs ajenos abiertos, ese caso es probable: entonces no se usa `--revert-de` sino un PR normal con el revert, que sí necesita veredicto sellado como cualquier otro. Telegram inmediato en los dos casos. |
| Ese `git revert` sale con conflicto | `git revert --abort`; segundo intento determinista: `git checkout <merge_commit>^ -- tablero-runbook/ scripts/run-checks.sh scripts/tests/test-summa-gate-quality-entrypoints.sh scripts/tests/test-salida-del-observador-no-trackeada.sh .gitignore` en un solo commit, por la ruta normal del kit. Si el gate también lo rechaza, el Telegram ya salió y la fase se detiene. |
| El merge sale con **código 3**: lock ajeno del kit | No se libera a ciegas. Se mira quién lo tiene: el directorio del lock guarda pid, host y hora de inicio. Si es de una corrida **tuya** ya muerta en esta misma máquina, se libera con `--liberar-lock` y se reintenta. Si es de otro host, de otro pid vivo, o no se puede saber, se espera 15 minutos y se reintenta **una** vez; después ese ítem queda `atorado` y se declara. Liberar un lock ajeno puede pisar un merge en curso. |
| Un candado del repo responde algo sobre el kit ("hash does not match the kit manifest", "path must end exactly at .sh") | Es el candado **léxico** del repo reaccionando al texto del comando, no un fallo del kit. Se diagnostica en una forma que ese mismo candado no bloquea, con la ruta partida en variables: `K=/Users/dn/dev/summonaikit-claude/tools; F="$K/saikit-merge"".sh"; shasum -a 256 "$F"`, comparado contra el manifiesto del kit. Si el hash **coincide**, es falso positivo: se reescribe el comando y se sigue. Si **no** coincide, la ruta de merge está rota y aplica la fila del kit de loop §12. |
| El Telegram falla: `scp`/`ssh` cae, el bot responde error, o sale `enviado: False` | Se reintenta **dos** veces con 60 s entre intentos. Si las tres fallan, la fase **cierra igual**: el merge ya está hecho y el trabajo no se deshace por una notificación. Queda como residual con la salida verbatim, y el último envío de progreso lleva `atencion_requerida.necesaria: true` con motivo "cierre sin Telegram". Si el tablero quedó encendido, eso es lo que David verá ahí; si quedó apagado, el registro es el `7.json` mergeado y nadie se entera hasta que alguien lo abra, y eso también se declara. |
| Un implementador no acepta un flag del encargo | Se relanza con el flag equivalente de su CLI, se anota en el PR, y el encargo se corrige para la próxima. |

---

## Inventario y cierre

| | |
|---|---|
| **PRs propios de la fase** | Cinco en el camino normal (Q0a #53, Q0b #54, D, P y el de cierre) y hasta seis si hace falta el de reversa. Q0a y Q0b se mergean antes de abrir D y P, así que nunca hay más de tres abiertos a la vez. Los ajenos no cuentan. |
| **Implementadores** | Dos, en worktrees desechables. El lead entrega, vigila, revisa y mergea. |
| **Costo estimado** | 1.5 a 2.5 millones de tokens del lado del lead, más lo que consuman los implementadores en sus cuentas. De 4 a 8 horas de reloj, dominadas por dos ciclos de sync y el despliegue. |
| **Presupuesto** | Nada que preparar antes de lanzar. Las cuotas de los implementadores no se pueden leer por adelantado; si una se agota, manda la fila de cuota del loop §12 y el otro carril sigue. |
| **Fuera de alcance** | El widget `show_widget` del tablero de sesión, los parches parciales en `runbook.progress.set` (v2), e inferir progreso leyendo PRs o transcripts: eso último está rechazado en el plan. |
| **Sin David** | Todo. Como máximo **un** mensaje: el de cierre. Lo adelantan cuatro casos, y en cada uno ese mensaje adelantado **es** el de cierre, no uno extra: una detención en 0.0, el gateway mudo tras el reinicio, el guard que no bloquea, y la reversa por git. |
| **Cómo termina** | El plugin vive en el gateway, encendido o apagado según el canary; el tablero muestra la Fase 6 desde su cierre y la Fase 7 en vivo desde 7.6; `Plans.md` cerrado con `cc:完了` y SHAs; y tú imprimes `LISTO <sha>`. |

**Cómo se lanza, en una línea:** claw elige un lead de su lista de preferencia, lo abre en tmux sobre `/Users/dn/dev/goncloud-openclaw` con el modo de permisos que no pregunta de ese host, y le entrega **este archivo** junto con la instrucción: "ejecuta la Fase 7 de `Plans.md` en autopilot siguiendo este runbook; la copia que está en `origin/main` está superada y ponerla al día es Q0b". Si el host del lead necesita un sentinel para que el kit selle, la instrucción lo lleva. Los implementadores los lanza el lead; David no abre nada.

*Este archivo es la fuente. Cualquier tablero web es una copia y lo dice en su pie.*
