# T12: instalación en vivo en la Mac Mini

Este paso a paso es para David, o para quien él autorice, y se corre en la Mac Mini del gateway vivo (`gon@100.73.187.5`). La parte A se hizo el 2026-10-10 y la parte B el 2026-10-11 (plan `:305-:320`). Desde el 2026-10-11 a las 15:15Z, la Mini corre R `f8316c9`. Antes pasó por `f1c5f34` (parte A), `19c2ed1`, `4b9785c` y `ff1709f`. Los hashes de cada paquete, el corte, los canarios y los contadores están en `deploy-receipt.md`. Cada comando de abajo se ensayó en la Mac de desarrollo sobre una copia de la Mini (T11, `deploy-commands.md`). Los pasos que dependen de la Mini (cómo arranca y se detiene su gateway) se leen en la Mini antes de empezar.

## Qué trabajadores pueden recibir un encargo

Desde B6 (`B6.md`), R certifica el presupuesto según el servidor y la API, no según el nombre del proveedor:
- `https://api.openai.com/v1`, con Chat Completions y Responses;
- `https://opencode.ai/zen/go/v1`, solo con Responses.

En la Mini eso cubre a `main`, `ingenieria` e `implementer`, cuyo primario es `opencode-go-resp/muse-spark-1.3-contributor`. No cubre a los agentes con primario `opencode-go/deepseek-v4.1-flash` (`adversary`, `operaciones`, `reviewer`, `verifier`, `scout`): ese proveedor pasa por el plugin `opencode-go`, y R rechaza un plugin dentro de un encargo.

Un encargo que cae a un fallback por CLI (claude-cli) o a un plugin (codex) se rechaza antes de gastar. Salvo `mac-local/opencode` (B8; ver "La sesión de opencode que adopta el host" en la parte B), las rutas a un CLI de la Mac siguen sin certificar (matriz A10): esos loops conservan su vigía y lo declaran (plan `:318`). Los alias de modelo de opencode (B19, sección "Un host por alias de modelo") se certifican uno por uno, cada uno con su propio canario.

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
| 1.8 | Captura de resultados cuando exista el host (parte B) | En la Mac: `python3 scripts/agent-work/native_gateway.py --openclaw-bin ~/.openclaw/bin/openclaw --host-id mac-local --expect-url ws://127.0.0.1:18789 --host-state-dir <dir del host> --flush-results`, y para clasificar, `sqlite3 <dir del host>/host.sqlite "select status, count(*) from operations group by status"` | consumidos (`acknowledged`), pendientes (con resultado y sin recibo) y en vuelo; los `deferred` (nada tecleado) se reintentan solos; los `attempted` y `uncertain` se dejan sin reenviar | 1 min | Los resultados quedan en el spool; nunca se reenvía uno incierto. Para cerrar uno, mira el pane: si el CLI tomó la referencia, `python3 scripts/agent-work/host.py resolve-delivery mac-local <dir del host> <taskId> <generation> delivered "<qué viste>"`; si no la tomó, borra el texto del composer, usa `abandoned` en lugar de `delivered` y cancela la tarea en R. `abandoned` libera la sesión adoptada (`ReleasedAdopted`, con opencode vivo) y la instancia, que toma trabajo nuevo con el mismo `--cli-instance-id`; la adopción siguiente borra la marca que quedó en la sesión. Un spool de antes de B9 libera sus `abandoned` la primera vez que lo abre el host nuevo. Si R rechaza el resultado tardío de la tarea cancelada, ese resultado se queda en el spool con `report failed:` en los errores del inbox, y los demás se reportan igual. Mientras la tarea no se cancele en R, cada pasada que R la ofrezca sale con `resource has no launch to attach`, sin teclear nada. |

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

`main` pega `instructionRef` y `target` tal cual en `managed_tasks_submit`, junto con su `taskKey`, `inputRevision`, `resultContract` y `continuation`, y después llama a `managed_tasks_admit`. Desde B19 los pasos completos, sin que nadie se los dicte, están en la skill `encargo-cli` de `main` (`agents/main/agent/workshop-skills/encargo-cli/SKILL.md`). Escribir el mismo brief dos veces es seguro: el archivo ya está y la salida es la misma. Si sale con 1, el motivo va en stderr y no hay nada que enviar: brief vacío o de más de 1 MB, raíz inexistente o enlazada, o un archivo con ese nombre y otro contenido. `brief.py` no certifica la ruta; un adaptador sin certificar (matriz A10) lo sigue rechazando R.

### La sesión de opencode que adopta el host

Desde B8 (`B8-opencode-adapter-e2e.md`), `mac-local/opencode` es la única combinación certificada. El host no lanza esa sesión: la adopta. Se lanza a mano, una vez, así:

```
tmux -L <socket> new-session -d -s <sesión> -x 200 -y 50 -c <workspace> \
  -e 'OPENCODE_CONFIG_CONTENT={"permission":{"external_directory":{"<hostStateDir>/**":"allow"}}}' \
  /opt/homebrew/bin/opencode -m zai-coding-plan/glm-5.3-flash
```

- `<socket>`, `<sesión>` y `<workspace>` son los mismos valores que recibe el host en `native_gateway.py --watch` (`--cli-tmux-socket`, `--cli-session` y `--cli-workspace-root`), con `--cli-adapter-id opencode` y un `--cli-instance-id` fijo. El brief llega a `<workspace>/managed-briefs/`, y el artefacto del resultado tiene que quedar dentro de `<workspace>`.
- La asignación, `acceptRef` y `resultRef` viven en `<hostStateDir>` (`--host-state-dir`), fuera del workspace. Sin la regla `external_directory`, opencode se detiene en "Permission required" y el host reporta `permission-required`. `<hostStateDir>` va con su ruta real (en macOS, `/private/var/...` y no `/var/...`).
- El binario va con ruta absoluta, porque el servidor tmux conserva su propio `PATH`. El modelo es `zai-coding-plan/*`, nunca `zai/*` (que cobra por token).
- Compruébalo con `tmux -L <socket> display-message -p -t '=<sesión>:' '#{pane_current_command}'`, que debe imprimir `opencode.exe`. La primera vez que el host lee la sesión fija el pane donde corre `opencode` u `opencode.exe`, y desde ahí lee y teclea solo en ese pane, aunque el operador abra o active otra ventana de la sesión (`C-b c`). Si ese pane desaparece o deja de correr opencode, o si la sesión tiene cero o varios panes de opencode cuando el host la conoce, la entrega queda `deferred` y no se teclea nada.
- `agent-tmux.sh opencode` no sirve para esto: usa el servidor tmux por defecto y no lleva la regla de permisos.
- Mientras el operador tenga texto en el composer, de cualquier color, el host espera y no teclea nada. Solo cuentan como vacíos el composer sin texto y los tres placeholders medidos de opencode 1.18.35 (`Ask anything… "…"`). Teclea la referencia una vez y relee el composer cada 0,3 s, hasta 3 s, porque opencode tarda en dibujar una referencia larga. Pulsa Enter solo cuando el composer muestra exactamente lo que tecleó; si a los 3 s no lo muestra, no pulsa Enter, la entrega queda `uncertain` y la cierra el operador (1.8). La sesión no se marca con `OPENCLAW_WATCH`; el host le pone `AGENT_WORK_MANAGED=1`.
- Mientras opencode muestre un diálogo, el host difiere la entrega y no teclea nada, porque el diálogo se llevaría las teclas. Un ejemplo es "Update Available … Skip Confirm", que opencode 1.18.35 abre al arrancar aunque `OPENCODE_DISABLE_AUTOUPDATE=1`. Ciérralo con Esc en la sesión (`tmux -L <socket> attach -t <sesión>`, Esc y después `C-b d`). La pasada siguiente entrega.
- El host tiene cupo 1: el encargo siguiente se reclama solo cuando el anterior se cerró o se abandonó (1.8). Sin cupo, el host no le pide trabajo a R, porque R liga a la instancia la tarea que entrega.
- Entre encargos no hay que cerrar nada a mano. En cuanto R da el recibo del resultado, la misma pasada de `native_gateway.py --watch` cierra el recurso adoptado con ese recibo como evidencia: quita la marca del host de la sesión sin parar opencode, la deja `ReleasedAdopted` y le manda el cierre a R. La pasada siguiente ya puede reclamar otro encargo. Si ese cierre queda `CleanupPending` (por ejemplo, `adopted identity uncertain` o `host unavailable`), cada pasada lo reintenta (desde B14). Si la sesión ya lleva la marca de otro recurso, o ninguna, el host ya no la tiene: deja el recurso `ReleasedAdopted` sin teclear ni quitar marcas, y le manda el cierre a R. Si todavía lleva la marca del host, o el host no la puede leer, o la lee desde otro servidor tmux, el recurso sigue `CleanupPending` y retiene el cupo: ciérralo como en la sección siguiente.
- Un encargo cancelado tampoco se cierra a mano. Cada pasada pregunta a R (`managedTasks.host.cancellation`, desde el paquete de R `f8316c9`) si canceló la tarea de cada operación abierta. Si la canceló, el host marca la operación `cancelled` y cierra el recurso con la cancelación como evidencia. Si opencode muestra "Permission required" para ese encargo, antes lo rechaza con Esc, nunca con Enter, que aprueba. Después quita su marca sin parar opencode y le manda el cierre a R, y en esa misma pasada ya puede reclamar otro encargo. Si la pantalla muestra otro diálogo, el host no teclea nada y lo anota en los errores de la pasada; ciérralo tú en la sesión. Un cierre por cancelación que queda `CleanupPending` sí se reintenta en cada pasada.

### El host en la Mac

El host corre desde `~/dev/wt/agent-work-host`, en `tmux -L agent-work`, sesión `host`. Lo arranca este comando (el de `~/.local/state/agent-work-host/host-cmd.txt`):

```
OPENCLAW_BIN=/Users/dn/.openclaw-r/openclaw LANG=en_US.UTF-8 python3 scripts/agent-work/native_gateway.py --openclaw-bin /Users/dn/.openclaw-r/openclaw --host-id mac-local --expect-url ws://127.0.0.1:18789 --host-state-dir /Users/dn/.local/state/agent-work-host/mac-local-c --evidence-root /Users/dn/.local/state/agent-work-host/evidence --progress-state-dir /Users/dn/.local/state/runbook-progress-events --progress-client /Users/dn/bin/progress-events.py --watch --cli-adapter-id opencode --cli-instance-id canario-3 --cli-session canario --cli-workspace-root /Users/dn/dev/canario-encargos --cli-tmux-socket agent-work --cli-deadline-seconds 3600 2>&1 | tee -a /Users/dn/.local/state/agent-work-host/host.log
```

- `--progress-state-dir` es `/Users/dn/.local/state/runbook-progress-events`. El host encola ahí cada resultado y él mismo lo publica en el tablero (desde B16).
- El host publica su propio avance. Al final de cada pasada corre `progress-events.py publish --corrida <c>`, con su `--openclaw-bin`, para cada corrida que tiene archivos en `runs/<c>/queue/`. Hace una llamada por corrida y como máximo cuatro por pasada, empezando por la cola más reciente, cada una con 30 s de tope. Con las colas vacías no lanza ningún proceso. Si una publicación falla, el evento sigue en la cola, la pasada lo anota en sus errores como `progress publish rejected corrida <c>: <stderr del cliente>` y la pasada siguiente lo reintenta. Si vuelve a fallar con la misma cola, espera 30 s, luego 60 s y así hasta 5 min. Un evento nuevo en esa cola lo vuelve a intentar en la pasada siguiente. Un evento que el cliente manda a `rejected/` sale una sola vez en los errores y no se reintenta.
- Para encargos no hace falta el latido. El LaunchAgent `ai.goncloud.corrida-latido` (`corrida.sh latido`) no está cargado desde el 2026-09-27 y tiene que seguir así: además de publicar, manda mensajes de seguimiento de las corridas. No lo cargues para que el tablero se mueva.
- Una cola de una corrida que el tablero no conoce no se publica nunca. El host la reintenta hasta una vez cada 5 min y deja en `host.log` una línea `progress publish rejected corrida <c>: progress-events: get no devolvió documento y revisión aceptados` por intento. `publish` no la manda sola a `rejected/`, porque `runbook.progress.get` contesta `desconocida` tanto a una corrida que no existe como a un candado ocupado o a un registro ilegible (`followups.md`, fila B16). Una cola así se archiva a mano, sin borrar nada: `mkdir -p ~/.local/state/runbook-progress-events/archivo-<fecha> && mv ~/.local/state/runbook-progress-events/runs/<c> ~/.local/state/runbook-progress-events/archivo-<fecha>/`. Las 49 colas de las pruebas de humo del 2026-10-04 (`smoke-*` y `r14`) se archivaron así el 2026-10-11 en `archivo-2026-10-11/`.
- `~/bin/progress-events.py` tiene que ser igual a `scripts/mac/progress-events.py` del mismo checkout: una copia vieja no lleva los campos del ACK durable. Compruébalo antes de arrancar con `cmp ~/bin/progress-events.py scripts/mac/progress-events.py`, que no imprime nada si son iguales.
- `--host-state-dir` y `--cli-instance-id` cambian solo cuando se empieza un spool nuevo. Un spool que ya no corre ningún host se cierra con la sección "Cerrar un spool viejo".

### Un host por alias de modelo (B19)

`main` elige el modelo que hace el trabajo con el `adapterId` del encargo. `opencode` es la sesión de B8, con GLM 5.3 flash del plan de Z.AI (`zai-coding-plan/glm-5.3-flash`). `opencode@<proveedor>/<modelo>` es cualquier otro modelo que liste `opencode models`, por ejemplo `opencode@opencode-go/deepseek-v4-pro`. El id lleva el modelo literal porque así es estable y se explica solo: R no le pide nada más que estar en `managedTasks.hosts.mac-local.adapters` (`managed-tasks.ts:158` de R), y el host saca de ahí el `-m` sin otra tabla. `host.py opencode-model <alias>` imprime el modelo de un alias. Rechaza un alias mal formado y cualquier `zai/*`, que cobra por token.

Un host maneja una sola sesión de opencode, así que cada alias necesita su propio host. Los arranca, o reusa los que ya corren, `scripts/agent-work/lanzar-host.sh`, desde el checkout del host (`~/dev/wt/agent-work-host`):

```
bash scripts/agent-work/lanzar-host.sh [--canario] <alias> <instancia> <sesión> <workspace>
```

- Abre la sesión `<sesión>` de opencode en `tmux -L agent-work`, con `-m <modelo del alias>`, `OPENCODE_DISABLE_AUTOUPDATE=1` y la regla `external_directory` para el spool. Después abre el host en la sesión `host-<instancia>`, con el spool `~/.local/state/agent-work-host/<instancia>`, su log en `<spool>/host.log` y las mismas opciones que `host-cmd.txt` (incluido `--progress-state-dir ~/.local/state/runbook-progress-events`).
- Correrlo dos veces no arranca nada nuevo: reusa la sesión si corre ese modelo con la regla de ese spool, y reusa el host si `<spool>/host-cmd.txt` trae el mismo comando. Se niega, sin arrancar nada, si la sesión corre otro modelo o permite otro spool, si `host-<instancia>` corre con otro comando, o si otro proceso ya lleva `--cli-instance-id <instancia>` o `--cli-session <sesión>`, por ejemplo el host vivo de la sesión `host`.
- `--canario` agrega `--cli-canary` al host: además de los alias `certified`, reclama los que `coverage.json` tiene `sandbox-tested-uncertified`. Sin esa opción, un host de un alias sin certificar no reclama nada (`host adapter route is not certified` en cada pasada).
- Los alias abiertos hoy son `opencode@opencode-go/deepseek-v4-pro`, `opencode@opencode-go/kimi-k3`, `opencode@opencode-go/grok-4.7` y `opencode@opencode-go/qwen3.8-max`, todos `sandbox-tested-uncertified`. Cada uno se certifica con su propio canario: un pedido casual a `main` que lo nombra, resuelto sin pasos dictados. Al pasar, el alias cambia a `certified` en `coverage.json`, con su evidencia en `hostAdapterEvidence`, y su host se relanza sin `--canario`.
- El CLI trabaja dentro del workspace de su host. Un repo fuera de ese workspace termina en una incidencia de permiso.
- Todos los hosts publican la misma cola, `~/.local/state/runbook-progress-events`. Una pasada publica solo mientras tiene el candado `.host-publish.lock` de ese directorio; si otro host lo tiene, esa pasada no publica y la siguiente lo vuelve a intentar. El host de la sesión `host` toma el candado cuando se reinicia sobre B19.
- opencode 1.18.35 abre el diálogo "Update Available" al arrancar aunque lleve `OPENCODE_DISABLE_AUTOUPDATE=1`, y mientras esté abierto el host no entrega. Ciérralo con Esc (`tmux -L agent-work attach -t <sesión>`, Esc y después `C-b d`).

R abre un alias con `cutover_live.py adapters`, que agrega los alias a la lista con `config.patch` y `baseHash`, sin `replacePaths`, y no toca ninguna otra clave. El script de B19 es `t12-adapters-1.sh` (`deploy-commands.md`, sección "Abrir alias de modelo en mac-local"). La skill de `main` se publica con `t12-skills-main-1.sh` (misma sección). No hace falta reiniciar el gateway: R vigila `workshop-skills` y el turno siguiente de `main` ve la skill nueva.

El canario 8 (`~/.local/state/encargos-loop/canario/mensaje-8.txt`) certifica el alias de deepseek. Es un pedido casual, sin pasos: solo funciona si `main` sigue `encargo-cli` por su cuenta. Pasa si:
- R tiene una tarea con `target.adapterId` `opencode@opencode-go/deepseek-v4-pro`, `inputRevision` de tipo `code` con el HEAD de `~/dev/canario-encargos`, un resultado `ready.v1` y una decisión `complete`;
- el spool `~/.local/state/agent-work-host/deepseek-1` tiene esa operación `acknowledged` y su recurso `ReleasedAdopted`;
- `~/dev/canario-encargos/saludo.py` define `saludar(nombre)`, y `saludar("David")` regresa `Hola, David`.

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

Un spool que ya no corre ningún host puede seguir reteniendo cupo en R: R guarda un lugar de presupuesto para cada admisión cuyo cierre del host no es terminal. `native_gateway.py --close-only` hace una sola pasada de cierre sobre ese spool y sale. Reporta los resultados pendientes, suelta las sesiones con recibo, cierra las tareas que R canceló, reintenta los `CleanupPending` y manda los cierres a R. Nunca reclama trabajo, nunca entrega y nunca teclea; la única tecla posible es el Esc de B13 sobre un "Permission required" de una tarea cancelada. Toma las instancias de las filas del spool, así que no recibe `--cli-instance-id`. Abrir el spool sube su esquema a la versión 2, igual que al abrirlo un host nuevo.

El 2026-10-11 quedaban dos spools viejos del canario. Con `~/dev/wt/agent-work-host` ya en el `main` que trae B14 (el checkout está en HEAD separado: `git -C ~/dev/wt/agent-work-host fetch origin && git -C ~/dev/wt/agent-work-host checkout --detach origin/main`), se cierran desde `~/dev/wt/agent-work-host` con una línea cada uno. `--close-only` no necesita reiniciar el host vivo. El 2026-10-11 el checkout pasó a `2be0f55` a las 19:27:09Z, y el host se reinició sobre ese código en el mismo segundo. Cada línea guarda antes una copia del spool. En Claude Code se corren con el prefijo `!`, que solo sirve para correr un comando desde Claude Code y no es parte de la línea:

```
cp ~/.local/state/agent-work-host/mac-local/host.sqlite ~/.local/state/agent-work-host/mac-local/host.sqlite.pre-b14 && LANG=en_US.UTF-8 python3 scripts/agent-work/native_gateway.py --openclaw-bin /Users/dn/.openclaw-r/openclaw --host-id mac-local --expect-url ws://127.0.0.1:18789 --host-state-dir /Users/dn/.local/state/agent-work-host/mac-local --close-only --cli-adapter-id opencode --cli-tmux-socket agent-work
cp ~/.local/state/agent-work-host/mac-local-b/host.sqlite ~/.local/state/agent-work-host/mac-local-b/host.sqlite.pre-b14 && LANG=en_US.UTF-8 python3 scripts/agent-work/native_gateway.py --openclaw-bin /Users/dn/.openclaw-r/openclaw --host-id mac-local --expect-url ws://127.0.0.1:18789 --host-state-dir /Users/dn/.local/state/agent-work-host/mac-local-b --close-only --cli-adapter-id opencode --cli-tmux-socket agent-work
```

Cada una imprime un JSON. `resources` dice, por recurso, su tarea, su instancia, el estado de su operación y el estado del recurso antes y después de la pasada. El "antes" se lee en solo lectura antes de abrir el spool, así que no trae lo que hace la migración al esquema 2 (desde B18). `rClosures` trae los recibos de `managedTasks.host.close` que R devolvió en esta corrida, con el estado que R guardó. `lastSent` es el último cierre que el spool tiene registrado como aceptado por R. Sale con 0 si no hubo errores, o si el único es la nota del diálogo de una sesión que ya se soltó (por ejemplo `permission dialog left: pane unverifiable`), que queda en `errors` (desde B18). Con cualquier otro error sale con 1, y repetir la línea es seguro, porque un cierre que R ya tiene no se vuelve a mandar. Si el Esc de una tarea cancelada deja el "Permission required" en pantalla, la línea sale con 1, con `permission dialog visible but Esc did not close it, attempt <n> of 3` en `errors`, y deja la sesión tomada. Repetir la línea vuelve a intentar el Esc, y al tercer intento suelta la sesión igual y lo anota (desde B17). Lo esperado:

| Spool | Tarea | Instancia | Recurso después | Cierre que R devuelve |
|---|---|---|---|---|
| `mac-local` | `1454c912-0604-4b7c-8808-f8b8da5d8828` | `canario-1` | `ReleasedAdopted`, `delivery abandoned` | `ReleasedAdopted`, con la cancelación de R como evidencia |
| `mac-local-b` | `98431858-869c-4cab-9189-b10adb127489` | `canario-2` | `ReleasedAdopted`, `adopted mark superseded` (o `adopted mark cleared` si la sesión ya no lleva marca) | `ReleasedAdopted`, con el recibo del resultado como evidencia (`bb59de80…`) |

Si `mac-local-b` sigue `CleanupPending` con `adopted identity uncertain`, la sesión `canario` todavía lleva su marca, `8d126bc852d15dfa51c0313eebda6140`: no la cierres a mano y anótalo en `followups.md`.

El 2026-10-11, las dos líneas cerraron en R: `1454c912` a las 19:43:50Z con `delivery abandoned`, y `98431858` a las 19:43:58Z con `adopted mark cleared` (`deploy-receipt.md`, sección Canarios).

### El cierre de una sesión gestionada en la Mac

Una sesión adoptada se libera sola cuando R da el recibo de su resultado (sección anterior). Estos comandos sirven para terminar una sesión gestionada y para un cierre que quedó `CleanupPending`.

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
