# Fase 18.0: inventario parcial y fallo del gateway

Estado al 2026-09-23: **18.0 en curso, no aceptada**. El primer inventario
se hizo entre 02:11 y 02:12 UTC; después se obtuvo acceso SSH mediante el
alias configurado `gwpc` y se inició la recuperación del gateway.
No contiene la configuración completa de Windows, credenciales, sesiones ni
transcripciones. Este recibo no autoriza desinstalación, corte o deploy.

## Fuentes y observaciones

| Dato | Fuente y método | Resultado |
|---|---|---|
| Ocho IDs y cadenas ordenadas históricas | `docs/patches/modelos-vivos-2026-09-15.json5`, contado con `jq` el 2026-09-23 02:11–02:12 UTC | La foto del 16 de septiembre declara `main`, `operaciones`, `ingenieria`, `implementer`, `reviewer`, `adversary`, `verifier` y `scout`, cada uno con un primary y siete fallbacks; incluye `agents.defaults.model`. No acredita el estado actual. |
| Referencia de destino | Captura aportada por David, 2026-09-19; confirmación explícita el 2026-09-23 | David indicó que esta es la cadena real que se debe conservar en la instalación nueva. Difiere de la configuración viva leída hoy. Se transcribe abajo; ningún modelo se cambió aún en Windows. |
| Presencia del equipo | `tailscale status --json`, 2026-09-23 02:11–02:12 UTC | El peer configurado para el gateway aparece `online=true` y `active=true`. Esto no prueba que OpenClaw esté funcionando. |
| API del gateway | `openclaw gateway call health --json --timeout 10000` y prueba TCP de 3 s, 2026-09-23 02:11–02:12 UTC | La llamada no devolvió salud positiva y el puerto configurado no aceptó conexión. No se pudo consultar `config.get`. |
| SSH del equipo | Los primeros intentos fueron por IP, sin el alias ni su clave; después `ssh -o BatchMode=yes gwpc`, 2026-09-23 | El alias configurado sí autentica. La afirmación anterior de que no había acceso a Windows era incorrecta. |
| CLI en esta Mac | `openclaw gateway --help`, 2026-09-23 02:11–02:12 UTC | Versión local `2026.9.4`; no informa la versión instalada en Windows. |
| CLI en Windows | `openclaw --version` por SSH, 2026-09-23 | `2026.9.5 (ec9c1a1)`, instalada en `C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw`. |
| Configuración viva | `openclaw config validate --json` y `openclaw config get agents.entries --json` por SSH | Configuración válida, con los ocho IDs históricos. Las cadenas vivas difieren de la foto del 16 de septiembre; no se han cambiado. |
| Instalador | `npm ls -g openclaw --depth=0 --json` por SSH | Paquete npm global `openclaw@2026.9.5`. La ruta del paquete es `C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw`. |
| Lanzadores y scripts de tareas | `Get-ScheduledTask` por SSH, leyendo solo ejecutable, directorio de trabajo y longitud de argumentos | Gateway: `C:\Users\ehven\.openclaw\gateway.vbs`, sin argumentos. Node: `C:\Users\ehven\.openclaw\node.vbs`, sin argumentos. Watchdog y sync ejecutan PowerShell; CUA Node ejecuta `cmd.exe`; Restore Console ejecuta PowerShell del sistema. Los argumentos íntegros no se publican: sus XML están exportados en el destino privado citado abajo. |
| Alcance de desinstalación, solo simulación | `openclaw uninstall --all --dry-run --non-interactive --yes` y `openclaw uninstall --service --dry-run --non-interactive --yes` en Windows | `--all` enumera el servicio y toda `C:\Users\ehven\.openclaw`, incluidos ocho workspaces. `--service` enumera solo el servicio. No se ejecutó ninguna desinstalación; el runbook de corte no puede usar `--all` realmente. |
| Paquete para reinstalar | `npm cache ls`, `npm pack openclaw@2026.9.5 --pack-destination C:\Users\ehven\.openclaw-recovery --silent` y `Get-FileHash` por SSH | Tarball privado `openclaw-2026.9.5.tgz`, 72.453.925 bytes, SHA-256 `1FB6EF4FAE447AF14F1E3B1028334F39146D181A66A4CCE2848D4F741C636340`. No se desinstaló ni reinstaló el paquete. |
| Prueba de instalación aislada | `npm install --offline --prefix C:\Users\ehven\.openclaw-recovery\npm-probe-20260922 ... --no-audit --no-fund`, seguido de `node ...\node_modules\openclaw\openclaw.mjs --version` | 331 paquetes instalados fuera del estado vivo; CLI aislada responde `2026.9.5 (ec9c1a1)`. npm avisó que cinco paquetes tienen scripts pendientes de aprobación, por lo que esta prueba no acredita los plugins/native modules completos. La instalación global y el servicio siguen intactos. |
| Workspaces | Campo `workspace` de los ocho `agents.entries` | `main` usa `workspace`; los otros siete usan `workspace-<id>`, todos bajo `C:\Users\ehven\.openclaw`. El `agentDir` de los siete secundarios apunta a `agents\<id>\agent`; el de `main` no está fijado explícitamente. |
| Tareas/servicio | `Get-ScheduledTask` y `Get-Service` por SSH | `OpenClaw Gateway` y `OpenClaw Node` están Ready; `OpenClaw Gateway Watchdog` y `OpenClaw CUA Node` Disabled; `OpenClaw Restore Console` Ready. `GoncloudRepoSync` está Disabled. `WireGuardTunnel$openclaw` está Running. No se deduce salud del gateway de estas tareas. |
| Canales/autenticación | Solo claves de `openclaw config get channels --json` y de `auth --json` | Telegram es el canal configurado, con cuentas secundarias `ingenieria` y `operaciones`. Hay nueve referencias de perfil de autenticación; no se exportaron valores. |
| Estado del gateway | Tareas programadas y registro de OpenClaw por SSH | La tarea `OpenClaw Gateway` falló primero por una base de `adversary` registrada bajo un ID de retención. El watchdog se desactivó temporalmente para evitar reinicios en bucle. |
| Respaldo previo a la reparación | `openclaw backup create --verify`, seguido de `openclaw backup verify --json` | Archivo privado de 3,342,919,705 bytes en `C:\Users\ehven\.openclaw-recovery`; `ok=true`. La restauración en staging también terminó con `ok=true`. |
| Base de `adversary` | SQLite `PRAGMA quick_check`, `foreign_key_check`, `schema_meta`; copia con `robocopy`; `openclaw doctor --fix` | La base retenida tenía integridad correcta y dueño `adversary`. Se copió íntegra a la ruta canónica; Doctor verificó igualdad byte a byte y preservó la copia anterior con sufijo `.corrupt-*`. |
| Segundo fallo de arranque | Registro y dos stability bundles del gateway, 2026-09-23 | Dos arranques llegaron a abrir el puerto, pero abortaron por timeout de publicación del runtime de modelos en plugins de workspace del agente `adversary`. La fase duró ~131 y ~136 s frente a un límite de 120 s. No hay salud positiva aún. |
| Prueba reversible de plugin | `openclaw config set plugins.entries.tablero-runbook.enabled false` y `openclaw config validate --json` | Se desactivó solo para un tercer arranque diagnóstico. La prueba se detuvo antes de concluir para priorizar la reconstrucción; se restauró `enabled=true`. No cambió agentes, modelos ni `summa-gate`. |

El tercer arranque se detuvo al cambiar la prioridad a la reconstrucción limpia.
`tablero-runbook` se restauró a `enabled=true`; el gateway quedó detenido y el
watchdog sigue desactivado para evitar reinicios fallidos automáticos.

## Respaldo de seguridad y restauración aislada

El archivo privado se creó a las 2026-09-23 02:26 UTC, antes de reconstruir la
ruta canónica de `adversary`. `openclaw backup restore --target` terminó con
`ok=true`, 27.341 entradas y cero symlinks en
`C:\Users\ehven\.openclaw-recovery\staging-20260922`. El destino hereda ACL
solo para el usuario del gateway, SYSTEM y Administrators. Es una prueba de
recuperabilidad, **no** una selección de archivos para importar a la
instalación nueva.
El SHA-256 del archivo de 3.342.919.705 bytes es
`9D91AF302A461CF412C17E5CFD94771E0A5FF98CD17BE63EB96F3DF40B70587A`;
un preflight puede cotejar ese hash sin repetir la restauración de 27.341
entradas.

| Área del estado restaurado | Archivos | Tamaño aproximado (MiB) | Decisión inicial |
|---|---:|---:|---|
| `backups` anidados | 46 | 1.905 | Seguro histórico; no importar. |
| `browser` y `browser-claw` | 14.834 | 2.480 | Perfiles/datos de navegador; no importar por defecto. |
| `agents` | 981 | 1.771 | Bases e historial; conservar en el respaldo, no activar en bloque. |
| `models` | 1 | 313 | Descargable; reinstalar si resulta necesario. |
| `state` | 2 | 245 | Base compartida antigua; no importar en bloque. |
| `workspace` principal | 4.104 | 214 | Comparar con Git y elegir solo contenido único. |
| `skills` | 223 | 0,9 | Revisar autoría y seleccionar las propias. |
| `openclaw.json` | 1 | 0,026 | Fuente de ocho agentes/cadenas; reconstruir configuración mínima, no copiar entera. |

La restauración contiene `state/openclaw.sqlite`, `openclaw.json` y el directorio
`credentials` (existencia verificada sin abrir valores). Siete bases de agente
están bajo su ID normal. La octava está en
`agents/adversary.HELD-20260922/agent/openclaw-agent.sqlite`, tal como estaba
antes de la reparación; no hay base canónica de `adversary` en este archivo.
El Git vivo de `.openclaw` tiene cinco cambios rastreados: dos archivos de
`workshop-skills` y `gateway-watchdog.ps1`, `gateway.cmd`, `gateway.vbs`.
También hay dos rutas sin seguimiento: la carpeta retenida de `adversary` y
`workspace-implementer/memory/2026-09-22.md`.
De los 214 MiB del `workspace` principal restaurado, ~152 MiB son `tmp`,
~23 MiB `node_modules`, ~19 MiB `.git` y ~17 MiB `media`; no son una lista de
importación. El Git vivo rastrea 193 archivos bajo los ocho workspaces.

Clasificación conservadora para el corte: las cinco ediciones rastreadas y las
dos rutas sin seguimiento son **datos a preservar**, no código autorizado para
copiar automáticamente. Los dos archivos de `workshop-skills` y la memoria de
`implementer` son contenido propio que se comparará con su fuente antes de
seleccionar; `gateway-watchdog.ps1`, `gateway.cmd` y `gateway.vbs` son
lanzadores/operación de la instalación vieja y se reconstruyen, no se importan.
La carpeta retenida de `adversary` es una copia de base antigua, no un noveno
agente. Backup y staging conservan los siete elementos; la comprobación de
hashes de los seis archivos individuales se hizo antes de la futura rotación.

Un bundle privado de Git de 45.402.859 bytes, SHA-256
`0FC9D7215DA7A07BD76AC351886E0D450BA5BEB31EB85A50CF2FB5267FCDE03E`,
pasó `git bundle verify` (109 refs, historia completa). Se exportaron seis
XML de tareas a `C:\Users\ehven\.openclaw-recovery\task-xml-20260922`:
Gateway, Gateway Watchdog, Node, CUA Node, Restore Console y
GoncloudRepoSync. Falta decidir qué ediciones son fuente única y verificar
que el bundle más el backup cubren el working tree antes del corte. Como
comprobación inicial, los cinco archivos rastreados modificados y el archivo
sin seguimiento `workspace-implementer/memory/2026-09-22.md` existen en el
staging y sus SHA-256 coinciden con el Windows vivo. La carpeta retenida de
`adversary` también está en el staging, aunque el Doctor cambió después su
nombre/ubicación activa.

La carpeta `skills` del PC tiene 69 skills. La comparación de nombres de
directorios con los catálogos locales de la Mac encontró una sola exclusiva
del PC: `make-bot-ui` (dos archivos, `SKILL.md` de 4.649 bytes más metadato de
origen). Está en el respaldo; se revisará para copiarla selectivamente. Las
otras 68 se pueden reconstruir desde las fuentes locales, sujeto a comprobar
versiones antes del corte.

## Cadenas de destino confirmadas por David

Transcripción de la captura del 2026-09-19, confirmada como referencia real
el 2026-09-23. Las anotaciones `(high)`, `(xhigh)` y `(max)` son parte de la
captura y deben reconciliarse con los campos de esfuerzo antes del corte; no
se sustituyen por el arreglo vivo observado. Cada fila tiene siete posiciones.

| Agente | Posiciones 1 → 7 |
|---|---|
| `main` | `opencode-go-resp/muse-spark-1.3-contributor` → `anthropic/claude-opus-5 (xhigh)` → `meta/muse-spark-1.3 (max)` → `xai/grok-4.6` → `zai/glm-5.3` → `openai/gpt-5.6-sol (xhigh)` → `kimi/k3` |
| `operaciones` | `opencode-go/deepseek-v4.1-flash` → `zai/glm-5.3-flash` → `openai/gpt-5.6-terra (xhigh)` → `anthropic/claude-sonnet-5 (xhigh)` → `xai/grok-4.6` → `kimi/kimi-for-coding (high)` → `meta/muse-spark-1.3 (max)` |
| `ingenieria` | `opencode-go-resp/muse-spark-1.3-contributor` → `openai/gpt-5.6-sol (xhigh)` → `kimi/k3` → `zai/glm-5.3` → `meta/muse-spark-1.3 (max)` → `anthropic/claude-opus-5 (xhigh)` → `xai/grok-4.6` |
| `implementer` | `opencode-go-resp/muse-spark-1.3-contributor` → `meta/muse-spark-1.3 (max)` → `zai/glm-5.3-flash` → `xai/grok-4.6` → `anthropic/claude-sonnet-5 (xhigh)` → `openai/gpt-5.6-terra (xhigh)` → `kimi/kimi-for-coding (high)` |
| `reviewer` | `opencode-go/deepseek-v4.1-flash` → `anthropic/claude-fable-5-1` → `kimi/k3` → `openai/gpt-6-astra` → `meta/muse-spark-1.3 (max)` → `xai/grok-4.6` → `zai/glm-5.3` |
| `adversary` | `opencode-go/deepseek-v4.1-flash` → `xai/grok-4.6` → `kimi/k3` → `zai/glm-5.3` → `meta/muse-spark-1.3 (max)` → `anthropic/claude-opus-5 (xhigh)` → `openai/gpt-5.6-sol (xhigh)` |
| `verifier` | `opencode-go/deepseek-v4.1-flash` → `zai/glm-5.3-flash` → `meta/muse-spark-1.3 (max)` → `kimi/kimi-for-coding` → `anthropic/claude-sonnet-5 (xhigh)` → `openai/gpt-5.6-terra (xhigh)` → `deepseek/deepseek-flash` |
| `scout` | `opencode-go/deepseek-v4.1-flash` → `zai/glm-5.3-flash` → `meta/muse-spark-1.3 (max)` → `kimi/kimi-for-coding` → `deepseek/deepseek-flash` → `anthropic/claude-sonnet-5 (xhigh)` → `openai/gpt-5.6-terra (xhigh)` |
| `agents.defaults.model` | `opencode-go-resp/muse-spark-1.3-contributor` → `anthropic/claude-opus-5 (xhigh)` → `meta/muse-spark-1.3 (max)` → `xai/grok-4.6` → `zai/glm-5.3` → `openai/gpt-5.6-sol (xhigh)` → `kimi/k3` |

La captura no muestra `agents.defaults.model`. David decidió usar también para
ese valor la cadena de `main` de la captura, con el mismo orden. Esta es una
decisión de destino; el valor por defecto observado en Windows se conserva
abajo como evidencia histórica, no como configuración aprobada.

## Cadenas observadas en Windows, no aprobadas como destino

Lectura de `openclaw config get agents.entries --json` y
`openclaw config get agents.defaults.model --json` por SSH el 2026-09-23.
Cada fila muestra el primario seguido de los fallbacks, en el orden vigente.
No se cambió ninguno.

| Agente | Primario → fallbacks |
|---|---|
| `main` | `opencode-go-resp/muse-spark-1.3-contributor` → `anthropic/claude-sonnet-5` → `meta/muse-spark-1.3` → `xai/grok-4.6` → `zai/glm-5.3` → `openai/gpt-5.6-sol` |
| `operaciones` | `opencode-go/deepseek-v4.1-flash` → `anthropic/claude-sonnet-5` → `meta/muse-spark-1.3` → `zai/glm-5.3` → `kimi/k3` → `xai/grok-4.6` → `openai/gpt-5.6-terra` |
| `ingenieria` | `opencode-go-resp/muse-spark-1.3-contributor` → `openai/gpt-5.6-sol` → `kimi/k3` → `zai/glm-5.3` → `meta/muse-spark-1.3` → `anthropic/claude-opus-5` → `xai/grok-4.6` |
| `implementer` | `opencode-go-resp/muse-spark-1.3-contributor` → `meta/muse-spark-1.3` → `zai/glm-5.3` → `xai/grok-4.6` → `anthropic/claude-opus-5` |
| `reviewer` | `opencode-go/deepseek-v4.1-flash` → `anthropic/claude-fable-5-1` → `kimi/k3` → `openai/gpt-6-astra` → `meta/muse-spark-1.3` → `xai/grok-4.6` |
| `adversary` | `opencode-go/deepseek-v4.1-flash` → `xai/grok-4.6` → `kimi/k3` → `zai/glm-5.3` → `meta/muse-spark-1.3` → `anthropic/claude-opus-5` → `deepseek/deepseek-flash` |
| `verifier` | `opencode-go/deepseek-v4.1-flash` → `openai/gpt-6-astra` → `meta/muse-spark-1.3` → `kimi/k3` → `zai/glm-5.3` → `anthropic/claude-fable-5-1` → `deepseek/deepseek-flash` |
| `scout` | `opencode-go/deepseek-v4.1-flash` → `zai/glm-5.3` → `meta/muse-spark-1.3` → `kimi/k3` → `xai/grok-4.6` → `anthropic/claude-sonnet-5` → `openai/gpt-5.6-sol` |
| `agents.defaults.model` | `opencode-go-resp/muse-spark-1.3-contributor` → `opencode/glm-5.3-flash` → `opencode-go/deepseek-v4.1-flash` → `opencode/muse-spark-1.3-contributor-free` → `opencode/deepseek-v4-flash-vision-exp` → `anthropic/claude-sonnet-5` → `zai/glm-5.3` → `kimi/k3` → `xai/grok-4.6` → `deepseek/deepseek-flash` → `openai/gpt-5.6-sol` |

## Datos que siguen `unknown`

- Comparación de contenido propio contra sus fuentes para decidir la lista
  exacta de importación; todos los cambios únicos ya están preservados.
- Disponibilidad real de cada proveedor. La configuración válida no la prueba.
- Argumentos exactos de tareas y rutas de sync para el runbook, versiones de
  skills replicadas y referencias de autenticación fuera del archivo oficial,
  aún sin inventario completo. Los XML de tareas están en destino privado;
  no se necesitan los valores de las credenciales.

## Para completar 18.0

Inventariar rutas, instalador, servicios, tareas, sync y archivos
únicos sin abrir secretos, y guardar el manifiesto detallado en un destino
privado. Comparar los ocho arreglos ordenados con ambas referencias fechadas.
Publicar aquí solo el recibo redactado con origen, hora y método de cada dato.
David eligió la captura como cadena de destino y la cadena de `main` para el
valor por defecto. Antes de cambiar el host falta clasificar archivos únicos y registrar el
manifiesto privado. El respaldo y su restore aislado de 18.1 ya se ejecutaron
como salvaguarda, pero la fase no se cierra por eso. El corte de 18.4 no se
inicia hasta completar las compuertas previas.
