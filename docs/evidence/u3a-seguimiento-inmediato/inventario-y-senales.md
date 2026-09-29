# Inventario de CLI habilitadas y señales de fin (19.0)

Fecha: 2026-09-29. Base: `u3a/b1-medicion-base` en `2a17dec` (cierre de U3,
`origin/main`). Medición viva en esta Mac salvo lo marcado ficticio o pendiente.

## Host

| Dato | Valor |
|---|---|
| macOS | 26.7 (25G229), arm64, Apple M5 Pro, 24 GiB |
| tmux | 3.7c (`/opt/homebrew/bin/tmux`) |
| node | v26.10.0 |
| Vigía tmux | `ai.goncloud.tmux-activity-watch` cargado, pid 97834, copia `~/bin` idéntica byte a byte al repo |
| Latido legacy | `ai.goncloud.corrida-latido` deshabilitado (`launchctl print-disabled`: disabled; decisión 14.29 D1) |
| Hook Stop | instalado en `~/.claude/settings.json` → `/opt/homebrew/bin/bash /Users/dn/bin/claude-stop-openclaw-event.sh`; copia idéntica al repo |
| Límites de la medición | servidor tmux propio (`tmux -L`), `CORRIDA_STATE` y `openclaw` doblados; el gateway real y el servidor tmux de David no se tocaron |

## CLI habilitadas (registro `workers.v1.json` entregado por U3)

Siete workers sobre cinco binarios. Todas instaladas y con salud comprobada por
`--version` (el `health` del propio registro).

| Token | Binario | Versión host | Versión en registro | Flag sin preguntas | Barra medida |
|---|---|---|---|---|---|
| claude_fable, claude_opus | `claude` | 2.1.284 | 2.1.284 | `--permission-mode acceptEdits` | `(shift+tab to cycle)` |
| kimi_k3, kimi_coding | `kimi` | 2.1.1 | 2.1.1 | `--auto` | `thinking:` |
| codex | `codex` | 0.158.0 | 0.158.0 | `--sandbox workspace-write` | `Ask Codex to do anything` |
| zcode (+ alias glm) | `zcode` | 3.10.2-18 | 3.10.2-18 | `--mode yolo` | `zai/glm` |
| grok | `grok` | 1.0.44 | 1.0.41 (desactualizado) | `--always-approve` | `[stable]` |

Desvíos encontrados:

- `grok` 1.0.44 pinta `[stable]` igual que 1.0.41 (consta en la corrida
  medida), pero el registro quedó en 1.0.41. En sondas manuales del arnés,
  sin artefacto conservado, el primer arranque de 1.0.44 añadió un menú
  inicial y un diálogo de telemetría que retrasaron la barra más allá de los
  10 s que espera `lanzar-sesion`; el segundo arranque la pintó en ~8 s y la
  corrida medida pasó sin precalentamiento. El registro conviene
  actualizarlo a 1.0.44.
- `acceptEdits` de claude no cubre comandos de terminal: un encargo que empuje
  a Bash lo deja esperando aprobación de permisos (observado en la primera
  corrida; ver transiciones-base.md).

Cobertura: la medición de señales es por binario. Cada binario cubre todos
sus workers del registro porque la ruta legacy medida lanza por fila de
`cli-modos.tsv` (sin worker) y la señal de fin depende del binario y su
harness, no del worker. La ruta por worker (carril con `adaptador start` y
argv con modelo) no se midió aquí; queda para 19.1 con las mismas señales.

## Filas de `cli-modos.tsv` fuera del registro (no habilitadas)

| Token | Estado en este host | Tratamiento |
|---|---|---|
| cursor-agent | instalado 2026.09.28 | legacy explícita (decisión de David, cuota agotada); el preflight no la lanza |
| muse | NO instalado | fila sin binario; sin identidad ni señal comprobada |
| deepseek | NO instalado | fila sin binario |
| opencode 1.18.31, qwen 0.24.0, dsh 0.1.1-rc.2 | instalados, sin flag ni barra medidas (`unknown`) | fuera del registro: sin worker, el lanzador los rechaza |

Ninguna CLI del registro quedó fuera de la medición.

## Señal de fin, destino y dueño, por CLI

| CLI | Señales de fin disponibles | Destino del aviso | Dueño de la corrida |
|---|---|---|---|
| claude | hook `Stop` (inmediato, exige marca `OPENCLAW_WATCH=1`); quietud del vigía; permiso en pantalla; cierre de proceso → relanzo | el hook manda a `agent:main:vigia-mac` SIN identidad de corrida; el vigía manda a `agent:main:sim9-<corrida>` | el director: `reconciliar` con lock del registro; `sesiones[].dueno=lead` en la ruta legacy |
| kimi, codex, zcode, grok | quietud del vigía (por defecto tras 900 s); permiso en pantalla (inmediato); cierre de proceso → relanzo automático | `agent:main:sim9-<corrida>` con marca de corrida; sin corrida, `agent:main:vigia-mac` | el mismo director |

Hechos de código que sostienen la tabla:

- `claude-stop-openclaw-event.sh:23,110`: clave fija `agent:main:vigia-mac`,
  envío con `system event --mode now`, sin clave de corrida.
- `tmux-activity-watch.sh:107-109,191-195`: `QUIET_SECS=900`, `TICK_SECS=15`,
  recordatorios cada `3600` s; con `OPENCLAW_WATCH_RUN=<id>` el evento va a
  `agent:main:sim9-<id>`, sin marca a `vigia-mac`.
- `tmux-activity-watch.sh:274-314` (`relanzo_automatico`): relanza sin modelo
  la sesión caída de una corrida abierta, con marca atómica anti-duplicado.
- `corrida/reconciliar.sh:8-10,39-84`: un solo director por corrida; el lock
  se sostiene solo para leer y reducir, nunca durante un efecto externo.

## Un solo dueño del consumidor de eventos y del tick

- El vigía es un único LaunchAgent (`pid 97834`); su tick es el único sondeo
  de pantallas y escribe el único diario `eventos.jsonl`.
- Del diario solo lee `corrida/latido.sh`, y el propio vigía lo lanza cada
  300 s bajo lock (`LATIDO_SECS=300`); no hay otro reloj de latido (el
  LaunchAgent legacy sigue deshabilitado).
- El hook y el vigía solo notifican: ninguno invoca un reconciliador. La
  decisión del siguiente paso queda en el director (`reconciliar`), que exige
  lock exclusivo y registra la reserva antes de lanzar. El relanzo del vigía
  es el único lanzamiento automático, acotado a recrear la sesión caída de
  una corrida abierta, una sola vez por caída.
- El reloj global del director es un único cron `avance-tareas` cuyo payload
  es `tablero-runbook/avance-tick.mjs`, job de comando sin modelo (PR #211,
  `a81b63a`).
- Los eventos de máquina sin corrida salen por `agent:main:vigia-mac`, fuera
  del Telegram de David, con recordatorios cada 60 min (PR #214, `eaea55b`;
  medido por U3: sin esa sesión, main recibía 32 mensajes/hora por el DM).

Conclusión: consumidor de eventos y tick comparten dueño. No hay una segunda
ruta que lance trabajo; la que existe (relanzo) es idempotente por marca.

## Lo ya instalado que resuelve parte de cli-eventos (medido al cerrar U3)

| Pieza | Estado comprobado | Evidencia |
|---|---|---|
| Relanzo sin modelo de sesiones caídas (PR #212) | medido: sesión viva de nuevo en 0.54-2.09 s tras el cierre y primera actividad del sucesor en 1.05-2.61 s (cierre provocado por el arnés, ficticio) | `salidas/*/times.*.json`, campo `relevo` |
| Tick de avance sin modelo (PR #211) | real: `avance-tick.mjs` es el payload del cron único | cabecera del propio script |
| Eventos de máquina a `vigia-mac` + recordatorios 60 min (PR #214) | disparo comprobado: el hook Stop disparó y su envío fue recibido por el doble en `vigia-mac`; la entrega real al gateway no se midió. Constantes `*_REMIND_SECS=3600` verificadas en código | `salidas/claude/doble.*.jsonl`; `tmux-activity-watch.sh:109,115` |
| Compactación de la sesión de main con reinicio diario | declarado; vive en la configuración del gateway (Windows), no verificable desde este host | pendiente, no observado |

Servidores tmux de pruebas anteriores encontrados vivos (`-L nucleo5700`,
`-L taw38928/40874/46396` con sesiones `muse-orbit`): previos a esta medición,
no son del arnés de 19.0; su limpieza corresponde al residual 15 de 19.3.
