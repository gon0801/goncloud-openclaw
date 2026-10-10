# T12: instalación en vivo en la Mac Mini

Este paso a paso es para David, o para quien él autorice, y se corre en la Mac Mini del gateway vivo (`gon@100.73.187.5`). El plan deja T12 pendiente hasta que haya autorización y una ventana (plan `:305-:320`). Lo que se instala es el artefacto de `artifact-manifest.json`: R `f1c5f34` en la parte A, y `19c2ed1` desde B6. Cada comando de abajo se ensayó en la Mac de desarrollo sobre una copia de la Mini (T11, `deploy-commands.md`). Los pasos que dependen de la Mini (cómo arranca y se detiene su gateway) se leen en la Mini antes de empezar.

## Qué trabajadores pueden recibir un encargo

Desde B6 (`B6.md`), R certifica el presupuesto según el servidor y la API, no según el nombre del proveedor:
- `https://api.openai.com/v1`, con Chat Completions y Responses;
- `https://opencode.ai/zen/go/v1`, solo con Responses.

En la Mini eso cubre a `main`, `ingenieria` e `implementer`, cuyo primario es `opencode-go-resp/muse-spark-1.3-contributor`. No cubre a los agentes con primario `opencode-go/deepseek-v4.1-flash` (`adversary`, `operaciones`, `reviewer`, `verifier`, `scout`): ese proveedor pasa por el plugin `opencode-go`, y R rechaza un plugin dentro de un encargo.

Un encargo que cae a un fallback por CLI (claude-cli) o a un plugin (codex) se rechaza antes de gastar. Las rutas a un CLI de la Mac siguen sin certificar (matriz A10): esos loops conservan su vigía y lo declaran (plan `:318`).

## Actualizar la Mini a R `19c2ed1` (B6)

La parte A instaló `f1c5f34` y sus tablas de abajo son el registro de esa instalación. La parte B necesita `19c2ed1`, el artefacto que hoy fija `artifact-manifest.json`. Para instalarlo:

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
| 0.2 | Copiar los paquetes a la Mini | `scp ~/.local/state/encargos-loop/artifacts/paquete-f1c5f34/openclaw-2026.9.7.tgz ~/.local/state/encargos-loop/artifacts/paquete-f1c5f34/openclaw-ai-2026.9.7.tgz gon@100.73.187.5:/tmp/` y, en la Mini, `shasum -a 256 /tmp/openclaw*.tgz` | los dos sha256 de `artifact-manifest.json` | Copiar otra vez; no instalar con otro hash. |
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
| 1.8 | Captura de resultados cuando exista el host (parte B) | En la Mac: `python3 scripts/agent-work/native_gateway.py --openclaw-bin ~/.openclaw/bin/openclaw --host-id mac-local --expect-url ws://127.0.0.1:18789 --host-state-dir <dir del host> --flush-results`, y para clasificar, `sqlite3 <dir del host>/host.sqlite "select status, count(*) from operations group by status"` | consumidos (`acknowledged`), pendientes (con resultado y sin recibo) y en vuelo; los `attempted` y `uncertain` se dejan sin reenviar | 1 min | Los resultados quedan en el spool; nunca se reenvía uno incierto. |

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

Solo con R `19c2ed1` o posterior instalado, un trabajador certificable de la sección de arriba (por ejemplo, la ruta `operaciones → ingenieria`) y `maxContextTokens` medido.

| # | Qué | Comando | Resultado |
|---|---|---|---|
| B.1 | La entrada | Un archivo `entry.json` con `id`, `legacyCrons` (sus crons de vigilancia, por nombre o id), `host`, `adapter`, `deviceId`, `instructionRoot`, `runTimeoutSeconds` y `spools` | — |
| B.2 | Preparar e inspeccionar | `python3 scripts/agent-work/cutover_live.py prepare --state <estado> --entry entry.json` y `… inspect --state <estado> --wait-seconds 60` | `problems: []` |
| B.3 | Suspender, drenar y transferir (`:312`, `:313`) | `python3 scripts/agent-work/cutover_live.py apply --state <estado> --wait-seconds 120` | `transferred`; un reinicio del gateway de unos 6 s; un solo emisor |
| B.4 | Las dos entregas, la incidencia, la revisión con `Changes`, la operación sin SHA, cancelar y cerrar (`:313`, `:314`) | Con la ruta abierta, el flujo de `main_cli_loop` y `review_tail_restart` en vivo | Lo que esos casos prueban en `T10-*.md` |
| B.5 | Tablero y cierre de trabajadores (`:315`) | `openclaw gateway call managedTasks.projections.list` y `resources.py` | proyección y cierres verificados |
| B.6 | 30 minutos sin novedades (`:316`) | Contadores externos: peticiones al proveedor (el panel de opencode), `sessions.list` y `ps` del perímetro, al inicio y al final | cero inferencia atribuible a vigilancia |
| B.7 | Retirar los despertares viejos (`:317`, `:318`) | Borrar los crons suspendidos (sus ids están en el estado del corte) y sus recreadores; cambiar `~/.claude/skills/prompt-claw/SKILL.md` para que un loop sobre la ruta adoptada no cree `<loop>-vigia` | — |

## Reversa (plan `:319`)

Ante cualquier falla:
1. congelar la admisión;
2. conservar los resultados (el spool de la Mac no se toca);
3. volver con la foto del paso 1.1.

El binario anterior no abre la base migrada ni acepta `managedTasks` en la config, así que la reversa restaura las bases **y** `openclaw.json`. Después vuelve a deshabilitar los crons viejos que la foto traiga habilitados. El orden medido y cada falla posible están en `deploy-commands.md`, sección Recuperar. En la Mac de ensayo, `cutover_live.rollback` lo hace solo y se probó con los dos binarios reales (`T11.md`, T11-c). En la Mini, los pasos de detener y arrancar son los de 1.2 y 1.4. No se repite el canario como carga continua.

## Al terminar (plan `:320`)

Escribir una vez `docs/evidence/agent-work/deploy-receipt.md` con:
- los hashes instalados (`build-info.json`, los sha256 de 0.2);
- la generación del corte (si hubo parte B);
- los contadores de B.6;
- los recursos que quedaron;
- la cobertura efectiva: qué entradas se adoptaron, y los adaptadores no habilitados, dichos como limitaciones.

El tablero solo no basta para dar T12 por hecha: hace falta continuidad observada, cero sondeo con modelos y cierre comprobado.
