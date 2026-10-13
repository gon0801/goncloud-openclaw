# T12: instalación en vivo en la Mac Mini

Este paso a paso es para David, o para quien él autorice, y se corre en la Mac Mini del gateway vivo (`gon@100.73.187.5`). La parte A se hizo el 2026-10-10 y la parte B el 2026-10-11 (plan `:305-:320`). Desde el 2026-10-11 a las 15:15Z, la Mini corre R `f8316c9`. Antes pasó por `f1c5f34` (parte A), `19c2ed1`, `4b9785c` y `ff1709f`. Los hashes de cada paquete, el corte, los canarios y los contadores están en `deploy-receipt.md`. Cada comando de abajo se ensayó en la Mac de desarrollo sobre una copia de la Mini (T11, `deploy-commands.md`). Los pasos que dependen de la Mini (cómo arranca y se detiene su gateway) se leen en la Mini antes de empezar.

## Qué trabajadores pueden recibir un encargo

Desde B6 (`B6.md`), R certifica el presupuesto según el servidor y la API, no según el nombre del proveedor:
- `https://api.openai.com/v1`, con Chat Completions y Responses;
- `https://opencode.ai/zen/go/v1`, solo con Responses.

En la Mini eso cubre a `main`, `ingenieria` e `implementer`, cuyo primario es `opencode-go-resp/muse-spark-1.3-contributor`. No cubre a los agentes con primario `opencode-go/deepseek-v4.1-flash` (`adversary`, `operaciones`, `reviewer`, `verifier`, `scout`): ese proveedor pasa por el plugin `opencode-go`, y R rechaza un plugin dentro de un encargo.

Un encargo que cae a un fallback por CLI (claude-cli) o a un plugin (codex) se rechaza antes de gastar. La única ruta a un CLI de la Mac que está `certified` en `coverage.json` es `mac-local/opencode` (matriz A10), con un proceso de opencode por encargo y para opencode 1.18.35 (sección "El host de encargos" en la parte B). Las otras 15 siguen cerradas, y los loops que las usarían conservan su vigía y lo declaran (plan `:318`). Un pedido "por CLI" corre solo en `opencode`, y el modelo viaja en el brief. opencode Go está cerrado para encargos desde el 2026-10-12 por decisión de David (`proveedores-permitidos.json`).

## Actualizar la Mini a R `19c2ed1` (B6)

La parte A instaló `f1c5f34` y sus tablas de abajo son el registro de esa instalación. Esta sección es el registro de la actualización a `19c2ed1`. Las siguientes (`4b9785c`, `ff1709f` y `f8316c9`) usaron un script igual, `t12-actualizar-<sha>.sh`, en el mismo directorio; sus resultados están en `deploy-receipt.md`. Para instalar `19c2ed1`:

```
bash ~/.local/state/encargos-loop/artifacts/T12/t12-actualizar-19c2ed1.sh
```

El script corre en la Mac de desarrollo; su texto está en `B6.md`, sección Script de actualización. Hace lo siguiente:
1. Copia por scp los paquetes de `19c2ed1` y, para volver atrás, los de `f1c5f34`.
2. Revisa los hashes, que la versión viva sea `f1c5f34` y que no haya crons corriendo.
3. Detiene el gateway, toma una foto, instala, arranca y comprueba `build-info`, el esquema 27, la admisión cerrada y los mismos crons habilitados.

Los dos builds usan el esquema 27, así que volver atrás es reinstalar `f1c5f34` sin restaurar la base. Si el gateway no se detiene, la reversa se para sin tocar nada. Salidas: `ACTUALIZADO OK`, `PARO` (no se tocó nada) o `REVERSA`.

## Antes de la ventana (sin tocar nada vivo)

| # | Qué | Comando | Salida esperada | Si no |
|---|---|---|---|---|
| 0.1 | El artefacto es el revisado | En la Mac de desarrollo: `python3 scripts/agent-work/artifact.py verify` | `artifact OK: openclaw 2026.9.7 from <sourceSha del manifiesto>` (en la parte A, `f1c5f34…`) | No hay T12. |
| 0.2 | Copiar los paquetes a la Mini (parte A, ya hecha con `f1c5f34`; para `19c2ed1` el script de la sección de arriba copia y compara solo) | `scp ~/.local/state/encargos-loop/artifacts/paquete-f1c5f34/openclaw-2026.9.7.tgz ~/.local/state/encargos-loop/artifacts/paquete-f1c5f34/openclaw-ai-2026.9.7.tgz gon@100.73.187.5:/tmp/` y, en la Mini, `shasum -a 256 /tmp/openclaw*.tgz` | los dos sha256 de `artifact-manifest.json` | Copiar otra vez; no instalar con otro hash. |
| 0.3 | Cómo arranca el gateway en la Mini | En la Mini: `launchctl list \| grep -i openclaw; ps -axo pid,command \| grep -i "openclaw.*gateway" \| grep -v grep` | Una etiqueta launchd (anótala como `<etiqueta>`) y un proceso `openclaw-gateway` | Si no hay etiqueta launchd, anota cómo se lanza (proceso padre con `ps -o ppid=`) y úsalo en 1.2 y 1.4. |
| 0.4 | Versión viva | `~/.openclaw/bin/openclaw --version` | `OpenClaw 2026.9.7 (c074824)` | Si es otra versión, el manifiesto (`previousRuntime`) ya no aplica: parar. |
| 0.5 | La ventana | Ningún encargo ni loop corriendo: `~/.openclaw/bin/openclaw gateway call sessions.list --params '{"agentId":"main"}' --json` sin turnos activos, `cron list --json` sin `runningAtMs`, y David avisado | nada corriendo | Posponer (plan `:309`). |

## Parte A: instalar con la admisión cerrada (plan `:309` a `:311`)

Hecha el 2026-10-10 con el script `t12-parte-a.sh` (sección Script de `T12-parte-a.md`), que corre 0.4, 0.5 y 1.1 a 1.6 desde la Mac. Detiene el gateway antes de la foto y revierte solo si algo falla (`T12-parte-a.md`).

| # | Qué | Comando (en la Mini) | Salida esperada | Duración | Si falla |
|---|---|---|---|---|---|
| 1.1 | Foto completa | `F=~/.openclaw/respaldos/pre-f1c5f34-$(date +%Y%m%d-%H%M); mkdir -p "$F"; sqlite3 ~/.openclaw/state/openclaw.sqlite ".backup $F/openclaw.sqlite"; for f in ~/.openclaw/agents/*/agent/openclaw-agent.sqlite; do sqlite3 "$f" ".backup $F/agent-$(basename "$(dirname "$(dirname "$f")")").sqlite"; done; cp ~/.openclaw/openclaw.json "$F/"` y luego `sqlite3 "$F/openclaw.sqlite" 'PRAGMA user_version; PRAGMA quick_check;'` | `19` y `ok` | 1 min (medido: 564 MB) | Sin foto válida no se instala. |
| 1.2 | Detener el gateway | `launchctl bootout gui/$(id -u)/<etiqueta>`; si a los 60 s el proceso sigue (`ps`), `kill -9 <pid>` | sin proceso `openclaw-gateway` | 1 min | En el ensayo, un apagado normal tarda 2 s; uno colgado necesitó SIGKILL (VEREDICTO-T11-c-r1). |
| 1.3 | Instalar los dos paquetes juntos | `~/.openclaw/tools/node/bin/npm install -g --allow-scripts=/tmp/openclaw-2026.9.7.tgz /tmp/openclaw-ai-2026.9.7.tgz /tmp/openclaw-2026.9.7.tgz` y `~/.openclaw/bin/openclaw --version` | `added … packages`; `OpenClaw 2026.9.7 (f1c5f34)` | 2 min | Reversa (sección Reversa). Este comando no corre los scripts de instalación de `koffi`, `protobufjs`, `esbuild` y `@google/genai` (fila T12-A de `followups.md`). |
| 1.4 | Arrancar | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<etiqueta>.plist` (o como se lanzaba en 0.3) | en el log, la migración y `[gateway] ready`; `openclaw --version` vía el CLI de la Mac: `(f1c5f34)` | 2 min (la migración 19 → 27 de la copia tardó segundos) | Reversa. |
| 1.5 | Admisión cerrada | `openclaw gateway call config.get --params '{}' --json` | sin `managedTasks`, o `managedTasks.enabled` en `false` | 1 min | Si está abierta: `cutover_live` no corrió, algo la cambió; congelarla (`config.patch` con `{"managedTasks":{"enabled":false}}` y `baseHash`) y avisar. |
| 1.6 | Releer lo instalado | `cat ~/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw/dist/build-info.json`; `openclaw health --json` | `commit` = `f1c5f34…`; `ok: true` | 1 min | Reversa. |
| 1.7 | Resultados previos (`:311`) | En la ruta nativa todavía no hay resultados: el host de encargos nunca corrió en vivo, porque la admisión nunca se abrió. Los resultados de los loops viejos son archivos `LISTO-*` y `VEREDICTO-*` en `~/.local/state/<loop>/`, y se listan con `ls -lt ~/.local/state/*/LISTO-* ~/.local/state/*/VEREDICTO-*` | cada uno ya consumido, pendiente o antiguo; ninguno se reenvía | 2 min | Anotar en el recibo. |
| 1.8 | Captura de resultados cuando exista el host (parte B) | En la Mac: `python3 scripts/agent-work/native_gateway.py --openclaw-bin ~/.openclaw/bin/openclaw --host-id mac-local --expect-url ws://127.0.0.1:18789 --host-state-dir <dir del host> --flush-results`, y para clasificar, `sqlite3 <dir del host>/host.sqlite "select status, count(*) from operations group by status"` | consumidos (`acknowledged`), pendientes (con resultado y sin recibo) y en vuelo; los `deferred` (nada tecleado) se reintentan solos; los `attempted` y `uncertain` se dejan sin reenviar | 1 min | Los resultados quedan en el spool; nunca se reenvía uno incierto. Para cerrar uno, mira el pane: si el CLI tomó la referencia, `python3 scripts/agent-work/host.py resolve-delivery mac-local <dir del host> <taskId> <generation> delivered "<qué viste>"`; si no la tomó, borra el texto del composer, usa `abandoned` en lugar de `delivered` y cancela la tarea en R. `abandoned` libera la sesión adoptada (`ReleasedAdopted`, con opencode vivo) y la instancia, que toma trabajo nuevo con el mismo `--cli-instance-id`; la adopción siguiente borra la marca que quedó en la sesión. Un spool de antes de B9 libera sus `abandoned` la primera vez que lo abre el host nuevo. Si R rechaza el resultado tardío de la tarea cancelada, ese resultado se queda en el spool con `report failed:` en los errores del inbox, y los demás se reportan igual. Mientras la tarea no se cancele en R, cada pasada que R la ofrezca sale con `resource has no launch to attach`, sin teclear nada. Mirar el pane y `resolve-delivery` son de la sesión adoptada, que este código ya no arranca (sección "La ruta anterior"). En el host de encargos una entrega que no se acusó se cierra cancelando la tarea en R. |

Después de la parte A, la Mini corre el runtime nuevo con la admisión cerrada, exactamente como antes para los agentes, y registra en la trayectoria el tamaño de cada llamada (`provider.payload.measured`).

## Medición en sombra de `maxContextTokens`

Con uno o dos días de tráfico real:

En la Mini no está el repo, así que el script corre en la Mac de desarrollo sobre una copia de las bases hecha con el mismo `.backup` de 1.1. En la Mini:

```
S=/tmp/sombra; for a in main ingenieria implementer; do mkdir -p $S/agents/$a/agent; sqlite3 ~/.openclaw/agents/$a/agent/openclaw-agent.sqlite ".backup $S/agents/$a/agent/openclaw-agent.sqlite"; done
```

En la Mac, desde el repo:

```
scp -r gon@100.73.187.5:/tmp/sombra /tmp/sombra && python3 scripts/agent-work/runtime/medir-contexto-sombra.py /tmp/sombra main ingenieria implementer
```

Al terminar, borra `/tmp/sombra` en las dos máquinas: son bases con conversaciones.

Mide solo a los agentes que pueden recibir un encargo, y solo sus llamadas por Responses (B6). Imprime el máximo, el p95 y n por agente. Su `maxContextTokens` propuesto (el máximo × 1,5) es solo el piso: desde B7, el valor de `limits.json` es la ventana del modelo en bytes. Es decir, `contextWindow` × bytes por token, y los bytes por token salen de `medir-bytes-por-token.py` (mismos argumentos) como el máximo medido × 1,5 (B7.md). `test_the_repo_context_limit_is_the_model_window_with_the_profile_margin` comprueba esa relación. Volver a medir sirve para subir el factor si un agente nuevo trae más bytes por token, nunca para bajar el valor al máximo × 1,5. Que la medición es fiel se comprobó en la copia: el evento y el cuerpo que recibió el proveedor tuvieron los mismos bytes (39.555 y 54.632, `B5-logs.md`).

## Parte B: abrir una entrada (plan `:312` a `:318`)

Solo con R `4b9785c` o posterior instalado (el corte escribe `managedTasks.requesters: ["main"]`, y un R anterior rechaza esa clave), un trabajador certificable de la sección de arriba (por ejemplo, la ruta `operaciones → ingenieria`) y `maxContextTokens` medido.

| # | Qué | Comando | Resultado |
|---|---|---|---|
| B.1 | La entrada | Un archivo `entry.json` con `id`, `legacyCrons` (sus crons de vigilancia, por nombre o id), `host`, `adapter`, `deviceId`, `instructionRoot`, `runTimeoutSeconds` y `spools` | — |
| B.2 | Preparar e inspeccionar | `python3 scripts/agent-work/cutover_live.py prepare --state <estado> --entry entry.json` y `… inspect --state <estado> --wait-seconds 60` | `problems: []` |
| B.3 | Suspender, drenar y transferir (`:312`, `:313`) | `python3 scripts/agent-work/cutover_live.py apply --state <estado> --wait-seconds 120` | `transferred`; un reinicio del gateway de unos 6 s; un solo emisor |
| B.4 | Las dos entregas, la incidencia, la revisión con `Changes`, la operación sin SHA, cancelar y cerrar (`:313`, `:314`) | Con la ruta abierta, el flujo de `main_cli_loop` y `review_tail_restart` en vivo | Lo que esos casos prueban en `T10-*.md` |
| B.5 | Tablero y cierre de trabajadores (`:315`) | `openclaw gateway call managedTasks.projections.list`; en la Mac, `corrida.sh terminar-sesion` o `cerrar` (sección siguiente) | proyección y cierres verificados |
| B.6 | 30 minutos sin novedades (`:316`) | Una foto al inicio y otra al final con `~/.local/state/encargos-loop/artifacts/T12/ventana-30/foto.sh`: eventos de las sesiones de `main` en la Mini, tablas `managed_task*` de R, crons vigía, tokens de opencode en su pane, líneas de `host.log` y procesos `openclaw agent` en la Mac. Las llamadas al proveedor se cuentan por los eventos `provider.payload.measured` de cada agente de la Mini | cero inferencia atribuible a vigilancia |
| B.7 | Retirar los despertares viejos (`:317`, `:318`) | Borrar los crons suspendidos (sus ids están en el estado del corte) y sus recreadores; cambiar `~/.claude/skills/prompt-claw/SKILL.md` para que un loop sobre la ruta adoptada no cree `<loop>-vigia` | — |

### El brief de `main` en la Mini

`main` encarga un paso a un CLI de la Mac con `managed_tasks_submit` y luego `managed_tasks_admit`. R lee el brief de `<instructionRoot>/<sha256>`: un archivo real (no un enlace), de 1 MB como máximo, cuyo sha256 es su nombre. `<instructionRoot>` es el valor de `entry.json` (B.1). `routing.py` no sirve en la Mini, porque necesita el repo y `coverage.json`. Para eso está `scripts/agent-work/brief.py`, que solo usa la biblioteca estándar de Python.

Instalarlo, desde la Mac de desarrollo y en la raíz de G:

```
ssh gon@100.73.187.5 'mkdir -p -m 700 ~/.local/share/agent-work <instructionRoot>'
scp scripts/agent-work/brief.py gon@100.73.187.5:.local/share/agent-work/brief.py
shasum -a 256 scripts/agent-work/brief.py; ssh gon@100.73.187.5 'shasum -a 256 ~/.local/share/agent-work/brief.py'
ssh gon@100.73.187.5 'R=$(mktemp -d); printf "prueba\n" | python3 ~/.local/share/agent-work/brief.py --root "$R" --host mac-local --adapter claude_opus; rm -rf "$R"'
```

Los dos sha256 tienen que coincidir. La última línea imprime un JSON con `instructionRef` y `target`. `<instructionRoot>` no puede ser un enlace simbólico: R y `brief.py` lo rechazan.

Cómo lo usa `main`, con su tool de exec en la Mini:

```
python3 ~/.local/share/agent-work/brief.py --root <instructionRoot> --host mac-local --adapter <adapterId> <<'BRIEF'
<texto del brief>
BRIEF
```

También acepta `--file <archivo>` en lugar de la entrada estándar. Imprime una línea, por ejemplo:

```
{"instructionRef": {"digest": "sha256:<sha256>", "ref": "artifact:<sha256>"}, "target": {"adapterId": "<adapterId>", "hostId": "mac-local", "kind": "cli"}}
```

Desde la fase 3 de B22 acepta `--model <proveedor>/<modelo>`, que llega en los `briefArgs` de `encargo.py preparar`. Con él escribe, delante del texto, la cabecera que lee el host de encargos:

```
agent-work.launch.v1
model: <proveedor>/<modelo>
---
<texto del brief>
```

La cabecera es parte del archivo, así que el sha256 de `instructionRef` la cubre. Sin `--model` el archivo es el texto tal cual, y el host corre el modelo por omisión. Un valor que no es `<proveedor>/<modelo>` sale con 2 y no escribe nada. `brief.py` no decide si el modelo está permitido: lo contesta `encargo.py preparar` antes, y el host lo comprueba otra vez al reclamar.

`main` pega `instructionRef` y `target` tal cual en `managed_tasks_submit`, junto con su `taskKey`, `inputRevision`, `resultContract` y `continuation`, y después llama a `managed_tasks_admit`. Desde B19 los pasos completos, sin que nadie se los dicte, están en la skill `encargo-cli` de `main` (`agents/main/agent/workshop-skills/encargo-cli/SKILL.md`). Escribir el mismo brief dos veces es seguro: el archivo ya está y la salida es la misma. Si sale con 1, el motivo va en stderr y no hay nada que enviar: brief vacío o de más de 1 MB, raíz inexistente o enlazada, o un archivo con ese nombre y otro contenido. `brief.py` no certifica la ruta; un adaptador sin certificar (matriz A10) lo sigue rechazando R.

### La ruta anterior: sesión adoptada y alias de modelo (retirada en la fase 4 de B22)

Hasta el corte del 2026-10-13, un encargo "por CLI" llegaba a una sesión de opencode que el operador abría a mano y que un host adoptaba. El host tecleaba en esa sesión la referencia de la asignación. B8 certificó así `mac-local/opencode` (`B8-opencode-adapter-e2e.md`). B19 agregó un host por modelo, con el modelo en el `adapterId` (`opencode@<proveedor>/<modelo>`), y abrió cuatro alias de opencode Go. David los cerró el 2026-10-12 con "open code go es solamente para main" (`deploy-receipt.md`, sección Canarios).

La fase 4 de B22 borró esa ruta del repo:

- `scripts/agent-work/lanzar-host.sh` y `host.py opencode-model`, que arrancaban un host por alias y traducían el alias a un modelo.
- Las banderas `--cli-adapter-id`, `--cli-session`, `--cli-workspace-root`, `--cli-canary` y `--cli-deadline-seconds` de `native_gateway.py`. Con ellas se fueron el host que adopta una sesión y la pasada `--close-only` sobre un spool de sesiones adoptadas.
- `cutover_live.py adapters`, que abría alias en R.
- Las filas `opencode@…` de `coverage.json`.

Lo que sigue vigente de entonces:

- En R, `managedTasks.hosts.mac-local.adapters` es `["opencode"]`. El modelo viaja en la cabecera del brief (sección "El brief de `main` en la Mini").
- opencode Go sigue cerrado para encargos. El cierre está en `proveedores-permitidos.json`, con la cita de David, y lo fija `test_the_closed_providers_are_exactly_these_three_each_with_davids_words`.
- Los spools de esa ruta están cerrados y quedan como evidencia. `mac-local` y `mac-local-b` se cerraron el 2026-10-11 (`deploy-receipt.md`, sección Canarios). `deepseek-1` quedó el 2026-10-12 con su única operación `acknowledged` y su recurso `ReleasedAdopted` (mismo recibo). `mac-local-c` se cerró el 2026-10-13 (`B22-canarios.md`, paso 1 del corte).
- La sesión adoptada `canario` no la mata nadie. El host nunca fue su dueño, y David la cierra cuando quiera.

Este código ya no arranca el host B8 ni un host por alias. `native_gateway.py` rechaza su comando con `unrecognized arguments`. Quien necesite esa ruta la corre desde el commit `bff085d7`, el último sobre el que corrió el host B8. Su comando exacto está en `~/.local/state/encargos-loop/B22/corte/host-b8-cmd.txt`. Cómo se operaba está en este runbook tal como quedó en ese commit: `git show bff085d7:docs/evidence/agent-work/T12-runbook.md`, secciones "La sesión de opencode que adopta el host", "El host en la Mac" y "Un host por alias de modelo (B19)".

El código que entregaba a una sesión adoptada (`claim_cli_once`, `TmuxTransport`, la lectura del composer y `detect_silent_failures`) y sus pruebas e2e se borraron el 2026-10-13, por decisión de David ("se quita"; `followups.md`, fila "B22 (ruta adoptada sin punto de entrada)"). Queda lo que cierra un spool de esa ruta (sección "Cerrar un spool viejo").

### Proveedores permitidos y `encargo.py` (B22)

Qué proveedor puede correr un encargo "por CLI" lo dice `docs/evidence/agent-work/proveedores-permitidos.json`. Cada permiso y cada cierre lleva las palabras de David, su fecha y su número de prompt. Lo escriben `permitir` y `cerrar`. La única edición a mano es reabrir un proveedor cerrado, que ningún comando hace. Lo que no tiene permiso está negado. Una entrada mal escrita deja el archivo sin efecto y no corre ningún encargo.

Qué protegen `permitir` y `cerrar`. Que una entrada de la política no le atribuya a David, por descuido, algo que no dijo, y que un proveedor que él cerró no se reabra por un comando. Protegen contra los errores de quien opera y contra un agente que pide por un canal, por ejemplo `main` por Telegram (fila B22-S6 de `followups.md`).

Qué no protegen, ni pretenden. A quien corre el comando en la Mac con intención de falsear: esa persona o ese agente también puede editar el JSON o el código. Contra eso la integridad de la política la dan el PR revisado, la prueba que fija los cierres y el historial de git, no este comando.

Esta política la lee el host de encargos de la sección siguiente, que corre desde el corte del 2026-10-13 (`B22-canarios.md`).

```
python3 scripts/agent-work/encargo.py proveedores [--refrescar]
python3 scripts/agent-work/encargo.py preparar [--repo <ruta>] [--modelo "<palabras o id>"]
python3 scripts/agent-work/encargo.py estado [--tarea <taskId>]
python3 scripts/agent-work/encargo.py permitir <nombre> [--proveedor <id>] [--cobro subscription|per-token] [--solo <patrón>] [--menos <patrón>] [--ref P#### --cita "<palabras de David>"]
python3 scripts/agent-work/encargo.py cerrar <proveedor> --ref P#### --cita "<palabras de David>"
python3 scripts/agent-work/encargo.py cerrar <proveedor> --por "<quién cierra>" --motivo "<por qué>"
```

- `proveedores` imprime una fila por permiso, una por cierre y una por cada proveedor que opencode lista sin decisión de David. `lista` es cuántos modelos lista opencode con ese id y `entran` cuántos cubre el permiso. `con-sesion` significa que opencode lista al menos un modelo. Una fila `sin-decision` trae el id con el que opencode nombra a un proveedor recién iniciado. `--refrescar` corre `opencode models --refresh`, para un modelo recién salido que no aparece.
- `preparar` contesta una línea JSON y sale con 0 o con 3. Juzga el pedido antes que el host: primero la política y el modelo, después la carpeta, la ruta certificada y el latido del host. Un rechazo trae `causa`, `frase` y `accion`. Con `accion` `preguntar-a-david`, `candidatos` trae los ids exactos y la frase dice cómo cobra cada proveedor. Si la Mac tiene una versión de opencode que `coverage.json` no tiene certificada, un pedido válido contesta `ruta-no-certificada`, salvo que viva un host lanzado con `--canario`.
- `preparar` termina en 30 s o menos: opencode tiene 25 s entre todas sus llamadas y git 5 s. Si alguno no contesta a tiempo sale con 1 y lo dice por stderr, sin JSON. Una política ilegible se contesta antes de llamar a opencode.
- `--modelo` acepta las palabras de David ("glm 5.3 highspeed") o un id exacto (`zai-coding-plan/glm-5.3`). Las palabras tienen que aparecer todas en el id de un modelo permitido. Si casan con varios, gana el que se llama igual, y si no hay uno solo se pregunta.
- `estado` contesta el latido del host de encargos (`host.json` del directorio de estado), y `estado --tarea <taskId>` lo que ese host sabe de una tarea. Los dos están en la sección siguiente.
- `permitir` y `cerrar` se corren en una rama, en un checkout que no sea el del host, y el cambio entra por un PR. Se niegan en el checkout que nombra `host.json`, y lo vuelven a mirar justo antes de escribir. No los corre `main`: quien pide los encargos no es quien se los autoriza.
- `cerrar` escribe aunque opencode no conteste: es el freno de emergencia. La fila sale `sin-catalogo` y un aviso por stderr. `permitir` también escribe sin opencode, salvo cuando liga un id o pone un filtro: esas dos comprobaciones leen el catálogo, y sin él el comando sale con 1 y no escribe.
- `--cita` tiene que ser una subcadena literal del prompt `--ref` en `~/.claude-mem/claude-mem.db`, y la fecha sale de ese prompt. El comando no imprime el texto del prompt. Solo una cita cotejada atribuye algo a David: sin esa base, o con una referencia que no es `P####`, `permitir` se niega. La línea de comandos no tiene forma de apuntar el cotejo a otra base.
- Dos comandos que escriben a la vez no se pisan. El que llega segundo espera y aplica su cambio sobre lo que dejó el primero. Si el primero cerró el proveedor que el segundo iba a permitir, o cambió el mismo permiso, el segundo se niega.
- Un permiso nuevo o una frase nueva sobre un permiso que existe pide `--cobro` con `--ref` y `--cita`. Ligar el id de un permiso que ya existe pide solo `--proveedor`, y el comando se niega si opencode no lista ningún modelo con ese id: un id se liga después de `opencode auth login`, no antes.
- `--solo` y `--menos` ponen un filtro de modelos en un permiso que existe, con su propia cita. Los patrones se comparan con la parte del id que sigue a `<proveedor>/`, y `*` vale por cualquier tramo. El permiso `qwen` usa `--solo 'qwen*' --menos 'qwen-image*'`: de los 27 modelos de `alibaba-token-plan` entran seis. Un modelo que opencode lista y el filtro deja fuera contesta `modelo-fuera-del-permiso`. Un filtro que no cubre ninguno de los modelos que opencode lista de ese proveedor se rechaza.
- `permitir` nunca abre un proveedor cerrado. Si el nombre o el id está en `closed`, se niega antes de mirar nada más, con cualquier combinación de argumentos. `opencode-go` y `opencode` están cerrados ("open code go es solamente para main", P10845), y `zai` desde el 2026-10-03.
- `claude` está permitido y sin sesión: opencode solo ofrece llave de API para Anthropic y David no va a usar llave. Su ruta propia es la fila B22-S5 de `followups.md`.
- Los comandos ejecutan de opencode solo `--version` y `models`, por ruta absoluta y con 20 s de tope por llamada. El catálogo queda en `catalogo.json` del directorio de estado y se vuelve a pedir a las 6 h, cuando cambia la versión de opencode, o cuando un proveedor permitido no lista nada y el catálogo tiene más de 60 s. Una salida vacía, o con una línea que no es un id, cuenta como opencode sin contestar: el comando sale con 1 y no la guarda.

Abrir un proveedor nuevo:

1. David lo dice, y su frase queda como prompt con número.
2. En una rama, corre `encargo.py permitir <nombre> --cobro subscription --ref P#### --cita "<sus palabras>"`. El permiso queda sin id y no autoriza nada.
3. David corre `opencode auth login` y elige el proveedor.
4. Corre `encargo.py proveedores`. Una fila `sin-decision` trae el id con el que opencode lo lista. Lígalo con `encargo.py permitir <nombre> --proveedor <id>`.
5. Abre el PR. El host toma el cambio con su `git pull`.

Reabrir un proveedor cerrado no es un comando. Es un PR que edita `proveedores-permitidos.json` a mano: quita la entrada de `closed` y agrega el permiso con la frase nueva de David (`by`, `on`, `ref`, `quote`). El mismo PR cambia `test_the_closed_providers_are_exactly_these_three_each_with_davids_words` en `scripts/tests/test-agent-work-modelos.py`, que fija los tres cierres con sus citas, y las cuentas de la partición del catálogo. Sin ese cambio la batería sale roja, así que la reapertura queda a la vista de quien revisa.

Cerrar de emergencia:

1. En una rama, corre `encargo.py cerrar <id> --por "<quién cierra>" --motivo "<por qué>"`. No espera a opencode. Quita el permiso y deja el cierre.
2. El cierre no lleva el nombre de David: dice quién cerró, por qué, y `sin-cotejar` donde iría el número de prompt. `encargo.py proveedores` lo muestra así en la columna `cita`, y el rechazo de `preparar` también dice `sin-cotejar`. `--por` no puede nombrar a David de ninguna forma.
3. Abre el PR. La prueba que fija los cierres sale roja hasta que el mismo PR agregue el cierre nuevo.
4. `cerrar` no reemplaza un cierre vigente. Cuando David diga su frase, cambiar el cierre de emergencia por uno con sus palabras es otra edición a mano en un PR.

### El host de encargos, con una sesión de opencode por encargo (B22)

Este host es la única forma de lanzar un encargo "por CLI". Reemplazó al host B8 el 2026-10-13, y el recibo del corte es `B22-canarios.md`. Desde la fase 4 de B22, `coverage.json` tiene `mac-local/opencode` en `certified`. La certificación es de la ruta entera, una vez, y no de cada modelo: el host `mac-local`, el CLI `opencode`, la forma `run-per-task` y la versión 1.18.35 de opencode (`hostAdapterRoute.mac-local.opencode`, con `B22-fase0.md` y `B22-canarios.md` como evidencia).

Un solo host atiende todos los modelos. Por cada encargo reclama la tarea, lee la cabecera del brief y autoriza el modelo con la misma `authorize` de `preparar`. Si el brief no trae cabecera, corre `zai-coding-plan/glm-5.3-flash`. Después lanza `opencode run -m <modelo>` en una sesión tmux nueva, `enc-<12 hex de la operación>`, con la carpeta del encargo como cwd y como `PWD`, y con `TMPDIR` en `runs/<op>/tmp/`. El host no adopta ninguna sesión, no teclea y no aprueba permisos.

Lo que queda fuera del repo y de la carpeta de la corrida lo niega una regla `deny`. El modelo recibe el error de esa llamada y la sesión sigue. Un `external_directory` que opencode pregunta en lugar de negar por regla lo rechaza opencode solo, porque `opencode run` corre sin `--auto` y sin teclado, y entonces la sesión termina (M2 y M6 de `B22-fase0.md`). Ningún otro tipo de permiso está medido. Las dos mediciones de la regla `deny` son M7 de `B22-canarios.md`.

El proceso corre con el grupo `agent-work-enc1` como grupo real, en la cuenta de David. Ese grupo es la frontera del slot: al cerrar, el host mata la sesión, manda TERM y después KILL a todo proceso de David con ese `rgid`, y reporta `AbsenceVerified` solo si no queda ninguno. Si queda alguno, el recurso sigue `CleanupPending`, retiene el cupo y cada pasada vuelve a barrer. La prueba no cubre a quien llame a un binario setuid que cambia de grupo (`newgrp`, `su`) ni a quien le pida el trabajo a launchd (`open`, `launchctl`). El grupo es de uso exclusivo del host: no lances nada a mano con `newgrp agent-work-enc1`, porque el host lo ve como slot ocupado y su siguiente cierre lo mata.

No corras las clases `Live*` de `scripts/tests/test-agent-work-sesion.py` mientras el host tenga un encargo en vuelo. Lanzan procesos en `agent-work-enc1`, el mismo grupo del host (`followups.md`, fila "B22 (pruebas con el grupo real)").

Antes de lanzarlo:

- El grupo existe y `dn` pertenece a él. `id -Gn | tr ' ' '\n' | grep -x agent-work-enc1` imprime `agent-work-enc1`. Si no imprime nada, David lo crea una vez: `sudo dseditgroup -o create agent-work-enc1 && sudo dseditgroup -o edit -a dn -t user agent-work-enc1`.
- No corre ningún host de antes del corte, como la sesión `host` de `tmux -L agent-work`. Reclamaría `mac-local/opencode` igual que este, y R le da cada tarea al primero que pregunta.
- `cmp ~/bin/progress-events.py scripts/mac/progress-events.py` no imprime nada.

Para lanzarlo, desde el checkout del host (`~/dev/wt/agent-work-host`):

```
bash scripts/agent-work/lanzar-encargos.sh
```

- Abre la sesión `host-encargos` en `tmux -L agent-work`, con el spool `~/.local/state/agent-work-host/enc-1` y su log en `enc-1/host.log`. Imprime `host: host-encargos arrancó` y una línea `HOST enc-1 opencode sesión=host-encargos spool=… grupo=agent-work-enc1`.
- El host corre dentro de un ciclo. Si el proceso muere, o si recibe `kill -TERM`, el ciclo lo vuelve a levantar a los 5 s y el host retoma del spool.
- Correrlo dos veces con los mismos argumentos no arranca nada: contesta `host: host-encargos ya corre`. Con otros argumentos se niega y dice cómo apagarlo antes. El lanzador no mira la tabla de procesos de la máquina. El candado de un host por spool lo pone el propio host (`enc-1/host.lock`): un segundo proceso sobre el mismo spool sale con `another host already runs on the spool …`.
- El arranque normal va sin opciones. El host lanza solo con una versión de opencode que `coverage.json` tiene certificada. Con otra versión rechaza cada encargo con `launch-refused` (`ruta-no-certificada`, "Ruta certificada para 1.18.35, la Mac tiene opencode <versión>."), y `preparar` contesta lo mismo antes de registrar la tarea.
- `--canario` queda para recertificar una versión nueva de opencode ("Recertificar", más abajo). Pasa `--canary` al host, que entonces también lanza con una versión que `coverage.json` todavía no tiene medida, o sobre una ruta `sandbox-tested-uncertified`. `preparar` contesta que sí mientras ese host viva.
- Antes de reiniciar el host sobre un cambio de `protocol.steps` (`cli_protocol` en `host.py`), comprueba que su spool no tiene operaciones sin asentar: `sqlite3 -readonly ~/.local/state/agent-work-host/enc-1/host.sqlite "select count(*) from operations where status not in ('acknowledged','abandoned','cancelled')"` tiene que imprimir `0`. El texto de `protocol.steps` entra en el digest de la asignación. Si cambia con un encargo en vuelo, cada pasada del host termina en `operation key conflicts with different content` hasta que esa operación se asiente, y mientras tanto el host no toma trabajo nuevo. La operación se asienta con su recibo (`acknowledged`) o al cancelar la tarea en R (`cancelled`).
- Para apagarlo: `tmux -L agent-work kill-session -t host-encargos`. Un encargo en vuelo no se pierde: su sesión `enc-…` sigue viva y el host la retoma al volver.

Cómo se lee el estado, desde el mismo checkout:

```
python3 scripts/agent-work/encargo.py estado
python3 scripts/agent-work/encargo.py estado --tarea <taskId>
```

- Sin tarea contesta el latido (`~/.local/state/agent-work-host/host.json`, que el host escribe al empezar cada pasada): `pid`, `latidoHace`, `slot` (`free`, `running` o `blocked`), `bloqueadoPor`, `tarea`, `modelo`, `checkout`, `commit`, `politica`, `cli` y `canario`. Un latido de más de 120 s contesta `sin-host` y sale con 3.
- `slot` `blocked` significa que el grupo tiene procesos que no son de ningún encargo. `bloqueadoPor` los lista como `pid hora-de-inicio comando`. El host no reclama mientras sigan ahí. Mátalos tú, por pid.
- Con `--tarea` contesta lo que el host sabe de esa tarea: `modelo` (el `-m` que el host lanzó de verdad, leído de `sessions/<op>/argv.json`), `cobro`, `estado` (el de la operación en el spool), `cierre` (`AbsenceVerified`, `CleanupPending` o nada), `carpetaDeSesion` (la que opencode dijo en sus logs; tiene que ser el repo del encargo), `proveedoresLlamados` (tiene que ser solo el proveedor del modelo), `permisosNegados` (cada uno como `<permiso>:<patrón>`), `salida` (el código de salida, cuando el host vio salir el proceso sin resultado) y `logTail`. Si la tarea tuvo una incidencia, `explicacion` trae `causa`, `frase` y `accion`. Nada de lo que imprime lleva la capacidad de la tarea.
- `permisosNegados` no es una incidencia. Lista también lo que negó la regla `deny` en un encargo que terminó bien. El estreno de grok terminó `acknowledged` con dos entradas (`B22-canarios.md`).
- Una `salida` 96, 97 o 98 es de `launch.sh`, que salió antes de llegar a opencode. Si la tarea tuvo una incidencia, la `frase` termina con la causa:

  | `salida` | Lo que agrega la `frase` |
  |---|---|
  | 96 | "El host no pudo crear la carpeta temporal del encargo." |
  | 97 | "El host no pudo entrar a la carpeta del encargo." |
  | 98 | "El proceso no quedó en el grupo del slot y el host no lanzó opencode." |

- Una tarea que el host no ha reclamado contesta `tarea-desconocida`, con `accion` `esperar`, y sale con 3.

Dónde queda cada cosa de un encargo, con `<op>` igual al id de la operación (64 hex):

| Carpeta | Dueño | Contenido |
|---|---|---|
| El repo del encargo | El modelo | El trabajo y el artefacto del resultado. El brief ya no se copia a `<repo>/managed-briefs/`. |
| `enc-1/runs/<op>/` | El host escribe `assignment.json` y `brief` (los dos en modo 0400). El CLI escribe `accept.json` y `result.json`, y deja sus temporales en `tmp/`. | Es la única carpeta fuera del repo que `external_directory` le permite a la sesión. La regla tiene dos llaves, `"*": "deny"` y `"<corrida>/**": "allow"`, donde `<corrida>` es la ruta de esta carpeta. Van en ese orden porque opencode aplica la última que coincide. `tmp/` es el `TMPDIR` de la sesión. `launch.sh` la crea con modo 700 antes de lanzar opencode. |
| `enc-1/sessions/<op>/` | El host | `launch.sh`, `argv.json`, `events.jsonl` (el flujo de `--format json`), `stderr.log` (los logs de opencode), y, según el caso, `exit.json` y `blocked.json`. La sesión no tiene permiso ahí. |

`external_directory` no confina el shell. Cubre las herramientas de archivo de opencode y las rutas que opencode reconoce en un comando. Una redirección o un script escriben donde la cuenta de David pueda (`B22-canarios.md`, "Límite medido", y `followups.md`, fila B22-S7).

Qué incidencia deja cada falla. Las dos primeras viajan a R como `transport-unavailable`, igual que `session-closed` y `delivery-unaccepted`. Esta ruta nunca emite `permission-required`.

| Qué pasó | Incidencia | Cuándo |
|---|---|---|
| El host no va a lanzar el encargo: proveedor cerrado o sin permiso, modelo que no existe, cabecera mal formada, carpeta fuera de `~/dev`, ruta sin certificar u opencode que no contesta su versión | `launch-refused` | En la pasada del reclamo |
| opencode salió sin acusar recibo, con cualquier código. O la sesión abrió en otra carpeta, y el host la mató. O el slot estuvo ocupado 300 s por procesos ajenos | `launch-failed` | En la pasada siguiente a la salida |
| El modelo no acusó recibo | `delivery-unaccepted` | A los 300 s del lanzamiento |
| El modelo acusó recibo y el proceso salió sin resultado. Por un permiso, pasa solo cuando opencode pregunta uno distinto de `external_directory`: lo rechaza solo y sale con 0 | `session-closed` | En la pasada siguiente a la salida |
| El resultado llegó mal formado | `invalid-result` | Al leerlo |
| El modelo acusó recibo y no entregó | `deadline-missed` | A los 3600 s del acuse |

Un permiso que niega la regla `deny` no termina la sesión y no deja incidencia. `estado --tarea` lo lista en `permisosNegados`, aunque el encargo termine bien.

En todos los casos `main` corre `estado --tarea`, repite la `frase` y cancela la tarea. Con la cancelación de R el host mata su sesión, barre el grupo y libera el cupo. El host no cierra nada por un plazo vencido.

Un spool `enc-1` que ya no corre ningún host se cierra con una pasada `--close-only` (sección "Cerrar un spool viejo"). Esa pasada sí mata las sesiones `enc-…` de las tareas con recibo o canceladas.

Cómo publica el host su avance:

- El host encola cada resultado en `~/.local/state/runbook-progress-events` y él mismo lo publica en el tablero (desde B16).
- Al final de cada pasada corre `progress-events.py publish --corrida <c>`, con su `--openclaw-bin`, para cada corrida que tiene archivos en `runs/<c>/queue/`. Hace una llamada por corrida y como máximo cuatro por pasada, empezando por la cola más reciente, cada una con 30 s de tope. Con las colas vacías no lanza ningún proceso. Si una publicación falla, el evento sigue en la cola, la pasada lo anota en sus errores como `progress publish rejected corrida <c>: <stderr del cliente>` y la pasada siguiente lo reintenta. Si vuelve a fallar con la misma cola, espera 30 s, luego 60 s y así hasta 5 min. Un evento nuevo en esa cola lo vuelve a intentar en la pasada siguiente. Un evento que el cliente manda a `rejected/` sale una sola vez en los errores y no se reintenta.
- Para encargos no hace falta el latido. El LaunchAgent `ai.goncloud.corrida-latido` (`corrida.sh latido`) no está cargado desde el 2026-09-27 y tiene que seguir así: además de publicar, manda mensajes de seguimiento de las corridas. No lo cargues para que el tablero se mueva.
- Una cola de una corrida que el tablero no conoce no se publica nunca. El host la reintenta hasta una vez cada 5 min y deja en `host.log` una línea `progress publish rejected corrida <c>: progress-events: get no devolvió documento y revisión aceptados` por intento. `publish` no la manda sola a `rejected/`, porque `runbook.progress.get` contesta `desconocida` tanto a una corrida que no existe como a un candado ocupado o a un registro ilegible (`followups.md`, fila B16). Una cola así se archiva a mano, sin borrar nada: `mkdir -p ~/.local/state/runbook-progress-events/archivo-<fecha> && mv ~/.local/state/runbook-progress-events/runs/<c> ~/.local/state/runbook-progress-events/archivo-<fecha>/`. Las 49 colas de las pruebas de humo del 2026-10-04 (`smoke-*` y `r14`) se archivaron así el 2026-10-11 en `archivo-2026-10-11/`.

Recertificar una versión nueva de opencode. Una actualización de opencode cierra la ruta sola, porque el host compara `opencode --version` con `certifiedCliVersions` en cada lanzamiento. Lo que la fase 0 midió vale para la versión medida: que `run` niega un permiso y termina, que toma su carpeta de `PWD` y la forma de sus logs.

1. Apaga el host y relánzalo con `bash scripts/agent-work/lanzar-encargos.sh --canario`. `encargo.py estado` contesta `"canario": true` y la versión nueva en `cli`.
2. Repite las mediciones de `B22-fase0.md` con esa versión (`~/.local/state/encargos-loop/B22/fase0/medir-run.sh`).
3. Manda un canario: un pedido real a `main` que diga "por CLI". Avísale antes a David, porque `main` le reporta el resultado por Telegram.
4. Con las mediciones y el canario en un recibo, un PR agrega la versión a `hostAdapterRoute.mac-local.opencode.certifiedCliVersions`, con ese recibo como valor.
5. Con el PR en `main` y el checkout del host actualizado, apaga el host y relánzalo sin `--canario`.

Reversa de la fase 4 y de la certificación. Revierte en `main` el merge de su PR y actualiza el checkout del host. No hay estado vivo que deshacer. Con la ruta otra vez en `sandbox-tested-uncertified`, el host solo lanza si se relanza con `--canario`.

Reversa al host B8. Este código ya no puede relanzarlo, porque no tiene las banderas de la sesión adoptada ni `lanzar-host.sh` (sección "La ruta anterior"). Se hace desde el commit `bff085d7`:

1. Apaga el host nuevo: `tmux -L agent-work kill-session -t host-encargos`.
2. Si `sqlite3 -readonly ~/.local/state/agent-work-host/enc-1/host.sqlite "select count(*) from resources where state not in ('AbsenceVerified','ReleasedAdopted')"` no imprime `0`, cancela esas tareas en R y corre la pasada `--close-only` de "Cerrar un spool viejo" hasta que imprima `0`. Córrela antes del paso 3: el commit `bff085d7` no tiene `--slot-group`.
3. Pon el checkout del host en el commit sobre el que corría el host B8: `git -C ~/dev/wt/agent-work-host checkout --detach bff085d7`. El sha quedó guardado en `~/.local/state/encargos-loop/B22/corte/host-b8-sha.txt`. En ese commit `coverage.json` tiene `mac-local/opencode` en `certified` sobre la sesión adoptada.
4. Relanza el host B8 en la sesión `host` de `tmux -L agent-work`, con su comando exacto. Quedó guardado en `host-b8-cmd.txt`, en la misma carpeta.
5. Regresa la Mini a lo anterior a la fase 3. Restaura `brief.py` y la skill `encargo-cli` de `main` desde el respaldo de la Mini: `ssh gon@100.73.187.5 'B=~/.openclaw/respaldos/pre-b22f3-20261013T050317Z; cp -p $B/brief.py ~/.local/share/agent-work/brief.py && cp -p $B/encargo-cli.SKILL.md ~/.openclaw/agents/main/agent/workshop-skills/encargo-cli/SKILL.md'`.
6. Si la reversa es definitiva, revierte en `main` los commits de las fases 2 a 4.

### El túnel ssh del CLI de R

Cada llamada del host al CLI de R (`~/.openclaw-r/openclaw`, con `transport: ssh`, `sshTarget gon@100.73.187.5` y `sshIdentity ~/.ssh/id_gateway` en `~/.openclaw-r/openclaw.json`) abre su propio `ssh -N -L` y lo cierra al terminar. Un bloque `ControlMaster` en `~/.ssh/config` no cambia eso. R arma el comando en `src/infra/ssh-tunnel.ts` (`startSshPortForward`) con `-o ControlMaster=no -o ControlPath=none -o ControlPersist=no`, a propósito ("This exact child owns the route; aliases must not delegate to a shared master"). El paquete instalado trae las mismas opciones (`~/.openclaw-r/prefix/lib/node_modules/openclaw/dist/ssh-tunnel-*.mjs`). ssh se queda con el primer valor que encuentra para cada opción, y la línea de comandos se lee antes que `~/.ssh/config`. El CLI sí lee `~/.ssh/config` para el resto (no pasa `-F`), pero esas tres opciones nunca salen de ahí.

Para comprobarlo sin conectarse a la Mini y sin tocar `~/.ssh/config`, con un archivo de prueba que trae el bloque (`ssh -G` solo imprime la configuración que usaría):

```
printf 'Host 100.73.187.5
  ControlMaster auto
  ControlPath /tmp/cm-%%C
  ControlPersist 60
' > /tmp/cm.conf
ssh -F /tmp/cm.conf -G gon@100.73.187.5 2>/dev/null | grep -E '^control(master|path|persist) '
ssh -F /tmp/cm.conf -G -o ControlMaster=no -o ControlPath=none -o ControlPersist=no gon@100.73.187.5 2>/dev/null | grep -E '^control(master|path|persist) '
```

El primer `ssh` imprime `controlmaster auto`, `controlpath /tmp/cm-…` y `controlpersist 60`: el bloque funciona solo. El segundo, con las opciones que pasa el CLI de R, imprime `controlmaster false` y `controlpersist no`, sin `controlpath`: el bloque no cuenta (medido el 2026-10-11).

Los 255 de `host.log` no son fallos al abrir el túnel. Las 29 líneas del 2026-10-11 dicen `gateway closed (1006 abnormal closure (no close frame)): ssh exited (255)`: el websocket ya estaba abierto cuando ssh murió, y R no guarda el stderr de ssh en ese caso. La causa no está medida. Antes de cambiar nada, hay que medirla desde la Mac (esto sí abre conexiones a la Mini, así que lo decide David).

La prueba abre el mismo túnel que abre el CLI de R, con las mismas opciones de `startSshPortForward`, y lo mantiene 10 min. El puerto local 18799 es solo de la prueba; el CLI de R toma uno libre en cada llamada. Imprime cuánto duró y con qué código salió ssh, y su stderr queda en `/tmp/ssh-tunel.log`:

```
log=/tmp/ssh-tunel.log; /usr/bin/ssh -N -L 127.0.0.1:18799:127.0.0.1:18789 -o ExitOnForwardFailure=yes -o BatchMode=yes -o ControlMaster=no -o ControlPath=none -o ControlPersist=no -o ForkAfterAuthentication=no -o StrictHostKeyChecking=yes -o UpdateHostKeys=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -i ~/.ssh/id_gateway -- gon@100.73.187.5 2>>"$log" & pid=$!; for s in $(seq 600); do sleep 1; kill -0 $pid 2>/dev/null || break; done; if kill -0 $pid 2>/dev/null; then kill $pid; echo "el túnel siguió vivo los 600 s"; else wait $pid; echo "ssh salió con $? a los $s s"; fi; cat "$log"
```

Si ssh sale antes de los 10 min, `/tmp/ssh-tunel.log` trae su mensaje, y en la Mini `log show --last 1h --predicate 'process == "sshd"'` dice si sshd cortó la conexión. El túnel de la prueba no lleva tráfico: si dura los 10 min, descarta cortes del transporte ssh, no cortes con el websocket abierto. En ese caso el siguiente paso es repetirla mientras el host corre, para ver si los 255 coinciden con un corte del túnel de la prueba.

Hay dos caminos, y ninguno está hecho:

- En G, `GatewayProjectionClient._call` repite una vez la llamada que sale con `ssh exited (255)`. Los métodos `managedTasks.host.*` y `managedTasks.projections.*` que usa el host repiten sin efecto doble (el reclamo devuelve la misma asignación y el ACK, el cierre y el reporte llevan su id), pero hay que comprobarlo método por método, con prueba.
- En R, una opción para que `gateway call` reuse una conexión propia: un `ControlPath` privado bajo `OPENCLAW_STATE_DIR` con `ControlPersist` corto. Necesita paquete nuevo de R y que el CLI siga siendo dueño de la ruta, que es lo que protege hoy `ControlPath=none`.

No sirve un túnel largo aparte con `transport: direct`: R toma un `ws://127.0.0.1` sin ruta ssh como no ligado, y el alcance de la credencial del dispositivo cambia (`resolveGatewayDeviceAuthRoute` en `src/gateway/connection-details.ts`), así que las llamadas `--device-auth` del host necesitarían otro emparejamiento.

### Cerrar un spool viejo

Un spool que ya no corre ningún host puede seguir reteniendo cupo en R: R guarda un lugar de presupuesto para cada admisión cuyo cierre del host no es terminal. `native_gateway.py --close-only` hace una sola pasada de cierre sobre ese spool y sale. Reporta los resultados pendientes, cierra las tareas con recibo y las que R canceló, reintenta los `CleanupPending` y manda los cierres a R. Para cerrar mata la sesión `enc-…` de cada una de esas tareas y barre el grupo del slot. Una sesión adoptada que quede viva en un spool anterior al corte no se mata ni se teclea: su fila queda `CleanupPending` (`adopted identity uncertain`) mientras el pane conserve la marca del host, y `ReleasedAdopted` cuando alguien quita la marca (`tmux -L agent-work set-option -u -t =<sesión>: @agent_work_resource_nonce`) o el pane muere. Nunca reclama trabajo y nunca entrega. Toma las instancias de las filas del spool, así que no recibe `--cli-instance-id`. Pide `--host-state-dir`, `--cli-tmux-socket` y `--slot-group`. Abrir el spool sube su esquema a la versión 2, igual que al abrirlo un host nuevo.

Para el spool del host de encargos, desde `~/dev/wt/agent-work-host` y con el host apagado:

```
LANG=en_US.UTF-8 python3 scripts/agent-work/native_gateway.py --openclaw-bin /Users/dn/.openclaw-r/openclaw --host-id mac-local --expect-url ws://127.0.0.1:18789 --host-state-dir /Users/dn/.local/state/agent-work-host/enc-1 --close-only --slot-group agent-work-enc1 --cli-tmux-socket agent-work
```

Imprime un JSON. `resources` dice, por recurso, su tarea, su instancia, el estado de su operación y el estado del recurso antes y después de la pasada. El "antes" se lee en solo lectura antes de abrir el spool, así que no trae lo que hace la migración al esquema 2 (desde B18). `rClosures` trae los recibos de `managedTasks.host.close` que R devolvió en esta corrida, con el estado que R guardó. `lastSent` es el último cierre que el spool tiene registrado como aceptado por R. Sale con 0 si `errors` está vacío y con 1 si no. Repetir la línea es seguro, porque un cierre que R ya tiene no se vuelve a mandar.

Los spools de sesiones adoptadas se cerraron con la variante `--close-only --cli-adapter-id opencode`, que la fase 4 de B22 retiró junto con la ruta: `mac-local` y `mac-local-b` el 2026-10-11 (`deploy-receipt.md`, sección Canarios) y `mac-local-c` el 2026-10-13 (`B22-canarios.md`, paso 1 del corte). Esa variante, con su Esc sobre el "Permission required" de una tarea cancelada, está en el commit `bff085d7`.

### El cierre de una sesión gestionada en la Mac

Estos comandos son de las sesiones gestionadas de una corrida (`corrida.sh`). El host de encargos cierra solo las suyas. Sirven para terminar una de esas sesiones y para un cierre que quedó `CleanupPending`.

`corrida.sh terminar-sesion <id> <sesión> --evidence <archivo>` y `corrida.sh cerrar <id>` cierran el recurso de una sesión gestionada en tres pasos. Primero, `native_gateway.py --flush-results` entrega a R los resultados pendientes, para que el recibo sea durable antes del cierre. Después, `resources.py close` cierra el recurso. Al final, otro `--flush-results` manda el cierre terminal a R para que suelte el cupo. Si un paso falla, la sesión conserva sus marcas, y repetir el comando retoma el cierre. Las variables necesarias son `AGENT_WORK_HOST_STATE_DIR`, `AGENT_WORK_TMUX_SOCKET`, `AGENT_WORK_RESOURCE_BIN` (la ruta a `resources.py`), `AGENT_WORK_GATEWAY_BIN` (la ruta a `native_gateway.py`), `AGENT_WORK_EXPECT_URL` (la URL de 1.8) y `OPENCLAW_BIN`. Las sesiones no gestionadas no usan ninguna y no llaman al gateway.

## Reversa (plan `:319`)

Si falla una entrada de la parte B y el binario nuevo sigue sano, se revierte solo esa entrada, sin la foto:

```
python3 scripts/agent-work/cutover_live.py revert --state <estado> --wait-seconds 120
```

Cierra primero la admisión de la entrada (quita su adaptador, o congela todo si era el único) y después rehabilita los crons viejos cuyos ids guardó el corte. No toca el spool. Si se interrumpe, el mismo comando retoma. Imprime `reverted; old crons re-enabled`.

Ventana de doble reporte: `revert` cierra la admisión, pero no espera a que terminen los encargos ya admitidos. Si uno sigue en vuelo, su resultado nativo puede llegar después de que el cron viejo volvió a correr, y el mismo trabajo queda reportado dos veces (fila B8-r2 de `followups.md`). Antes de revertir, mira qué hay en vuelo con la consulta de 1.8 (`select status, count(*) from operations group by status`). Si después del `revert` llega un resultado nativo, trátalo como duplicado del reporte del cron.

Para parar toda la admisión sin rehabilitar nada: `python3 scripts/agent-work/cutover_live.py freeze --wait-seconds 120`. El detalle está en `deploy-commands.md`, sección Revertir una sola entrada.

Si falla el binario nuevo:
1. congelar la admisión;
2. conservar los resultados (el spool de la Mac no se toca);
3. volver con la foto del paso 1.1.

El binario anterior no abre la base migrada ni acepta `managedTasks` en la config, así que la reversa restaura las bases **y** `openclaw.json`. Después vuelve a deshabilitar los crons viejos que la foto traiga habilitados. El orden medido y cada falla posible están en `deploy-commands.md`, sección Recuperar. En la Mac de ensayo, `cutover_live.rollback` lo hace solo y se probó con los dos binarios reales (`T11.md`, T11-c). En la Mini, los pasos de detener y arrancar son los de 1.2 y 1.4. No se repite el canario como carga continua.

## Al terminar (plan `:320`)

Hecho el 2026-10-11: `deploy-receipt.md`. Lleva, una vez:
- los hashes instalados (`build-info.json`, los sha256 de 0.2);
- la generación del corte (si hubo parte B);
- los contadores de B.6;
- los recursos que quedaron;
- la cobertura efectiva: qué entradas se adoptaron, y los adaptadores no habilitados, dichos como limitaciones.

El tablero solo no basta para dar T12 por hecha: hace falta continuidad observada, cero sondeo con modelos y cierre comprobado.
