# SUA-04, mediciones

## M-21, fase 0 de Claude por su CLI (2026-10-16, Claude Code 2.1.301 en la Mac)

Tres turnos mínimos con `claude -p`, en carpetas de `~/.local/state/sua-loop/mediciones/m21/`, sin `ANTHROPIC_API_KEY` en el entorno. Artefactos en `~/.local/state/encargos-loop/artifacts/SUA04-G7/` (`RESULTADO.md`, `p3b.jsonl`, `p4.jsonl`, `p5.jsonl`); los tres jsonl son fixtures de `scripts/tests/test-agent-work-claude.py`.

1. **Suscripción: verde.** `claude -p` contestó con el plan Max sin llave (`claude auth status`: `authMethod: claude.ai`, `subscriptionType: max`). El `total_cost_usd` es una estimación, no una llave.
2. **Carpeta de trabajo:** el cwd del proceso. Con el proceso en `a/` y `PWD=b/`, `pwd` contestó `a/`: al revés que opencode. El lanzador hace `cd` a la carpeta y no se fía de `PWD`.
3. **Permisos:** sin flags, la corrida hereda la configuración del usuario (`permissionMode: auto`, 57 herramientas, sus MCP) y `Write` entra sin preguntar. Con `--permission-mode dontAsk --permission-prompts none --setting-sources project --allowed-tools Read`: 25 herramientas, 0 MCP, `Write` sale `is_error: true`, el modelo sigue, la salida es 0 y el `result` trae `permission_denials`. En el `system/init` de esa corrida **no existen `Glob`, `Grep` ni `TodoWrite`** en Claude Code 2.1.301: la traducción de `requiredTools.claude` (G7) solo trae las que existen (`Read`, `Edit`, `Write`, `Bash`, `Skill`, `Task`).
4. **Eventos para leer:** `stream-json --verbose` trae `system/init` (`model`, `permissionMode`, `cwd`, `tools`, `mcp_servers`), cada `tool_use`, cada `tool_result` con `is_error`, y el `result` con `modelUsage`, `permission_denials`, `num_turns` y `stop_reason`.

Lo que M-21 no midió: el hijo (`Task`) de una corrida de Claude y su modelo, ni el límite de uso del plan Max en una corrida larga. Se mide en el banco de G7.

## M-23, el encierro de Bash con el sandbox de Claude Code (2026-10-16)

- Con `--settings '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}'`, `--allowed-tools Bash` y cwd `a/`: escribir dentro pasa y escribir en `b/` sale `operation not permitted` (exit 1), un bloqueo del sistema operativo, no del modelo (p4.jsonl).
- Con `--add-dir b/`: `b/` se escribe y `c/` sale `operation not permitted` (p5.jsonl). El sandbox deja escribir en el cwd y en las carpetas de `--add-dir`, y en nada más.
- La negativa del sandbox llega como `tool_result` con `is_error: true`, no como `permission_denials`.

## M-24, claude por CLI con --restricted frente a --setting-sources project (2026-10-16, coordinador)

Claude Code 2.1.301, `/Users/dn/.local/bin/claude`, suscripción (sin `ANTHROPIC_API_KEY`), `--model sonnet`, dontAsk + `--permission-prompts none` + `--no-session-persistence` + sandbox por `--settings` + `--add-dir <run>`. Repo de juguete con `.claude/settings.json` hostil: un hook SessionStart que hace `touch <fuera>/HOOK-CORRIO` y `permissions.allow ["Edit","Write"]`. Artefactos en `~/.local/state/sua-loop/mediciones/m24/` (`RESULTADO.md` y los jsonl citados).

1. `--setting-sources project --allowed-tools Read,Bash` (lo que medía M-21): el hook del repo **corrió** (`HOOK-CORRIO` existe); el `system/init` de `project.jsonl` trae 33 herramientas y los conectores de claude.ai de la cuenta. Literal del init: tools `['Task', 'Bash', 'CronCreate', 'CronDelete', 'CronList', 'DesignSync', 'Edit', 'EnterWorktree', 'ExitWorktree', 'ListAgents', 'Monitor', 'NotebookEdit', 'PushNotification', 'Read', 'RemoteTrigger', 'ReportFindings', 'ScheduleWakeup', 'SendMessage', 'Skill', 'TaskStop', 'ToolSearch', 'WebFetch', 'WebSearch', 'Workflow', 'Write', 'mcp__claude_ai_Claude_Docs__batch', 'mcp__claude_ai_Claude_Docs__create', 'mcp__claude_ai_Claude_Docs__delete', 'mcp__claude_ai_Claude_Docs__export', 'mcp__claude_ai_Claude_Docs__guide', 'mcp__claude_ai_Claude_Docs__query', 'mcp__claude_ai_Claude_Docs__read', 'mcp__claude_ai_Claude_Docs__update']` y mcp_servers con `('claude.ai Claude Docs', 'connected')`. Write quedó negado por dontAsk (`permission_denials ["Write"]`).
2. `--restricted --strict-mcp-config --tools Read,Bash --allowed-tools Read,Bash`: el hook **no** corrió; el init de `restricted.jsonl` trae literal `['Bash', 'Read']` y `mcp_servers []`; Write contesta "No such tool available".
3. Encierro (los dos modos, carpeta fuera de /tmp): escribir fuera da `operation not permitted` (rc=1); la escritura en `--add-dir` sale (rc=0); `git add` + commit en el cwd sale (rc=0). **Ojo: el sandbox deja escribir en /tmp** (una primera prueba con el "fuera" bajo /tmp escribió). `project-2.jsonl`, `restricted-2.jsonl`.
4. `--restricted --tools Read,Edit,Write,Bash,Skill,Task`: el init de `restricted-tools.jsonl` trae literal `['Task', 'Bash', 'Edit', 'Read', 'Skill', 'Write']` (exactamente esas seis), `mcp []` y solo las skills integradas de Claude Code, ninguna del usuario; `modelUsage claude-sonnet-5-5`.
5. **La lista de pasos de claude es `TaskCreate`** (2026-10-16, streams en `~/.local/state/encargos-loop/artifacts/SUA04-G7-r5/`; copias como fixtures de `scripts/tests/test-agent-work-conducta.py`). Con `--tools Read,TodoWrite`, el init de `lista-TodoWrite.jsonl` trae literal `"tools":["Read"]`: **TodoWrite no existe en 2.1.301**, y no hubo ninguna llamada. Con `--tools Read,TaskCreate`, el init de `lista-TaskCreate.jsonl` trae literal `"tools":["Read","TaskCreate"]` y, pedido "usa la herramienta de lista de pasos", el modelo llamó literal `{"type": "tool_use", "id": "toolu_01VcMEG9MpSgvtjRUbzc1Vn2", "name": "TaskCreate", "input": {"subject": "leer", "description": "leer"}, "caller": {"type": "direct"}}` y `{"type": "tool_use", "id": "toolu_01EZGZTUjoak2JWZu1SQ93M9", "name": "TaskCreate", "input": {"subject": "arreglar", "description": "arreglar"}, "caller": {"type": "direct"}}`. Aplicado en G7-r5 (`requiredTools.claude` suma `TaskCreate` donde `opencode` trae `todowrite`; `conducta --forma claude` lee cada `TaskCreate` como un elemento de la lista con su `subject`).

Conclusión: la ruta claude va con `--restricted --strict-mcp-config --tools <las del perfil>` (y el mismo `--allowed-tools`). `--setting-sources project` deja que el repo de trabajo corra hooks y amplíe permisos, y expone los conectores de la cuenta de David. Varios repos de `~/dev` traen hooks en `.claude/settings.json`. Aplicado en G7-r2 (`claude_argv`).

## Banco de G7: la ruta claude certificada (2026-10-16, coordinador)

Claude Code 2.1.301 en la Mac, suscripción (sin `ANTHROPIC_API_KEY`), modelo `claude opus`, generación 2 del paquete, host real con su gateway de juguete (`AGENT_WORK_BANCO_ADAPTER=claude`, R `7b3db54226bf`), rama `sua/04-g7` en `c8b203d0`. Los tres casos de 4.7, en una corrida, con las líneas literales del log:

```
BANCO_E2E case=claude-ingenieria task=cc8224df-3b8a-4f26-a212-eeffef6dee74 conducta=ok
BANCO_E2E case=claude-fuera task=6ea134c5-ed7d-4093-96e4-40225ef7b290 fuera=no-existe
BANCO_E2E case=claude-revision-rota task=5d7c5653-a815-4999-8184-498c1b1fa90e verdict=changes repo=igual
Ran 4 tests in 287.018s
OK
```

- **ingeniería**: con el AGENTS.md de la corrida por `--append-system-prompt-file`, claude leyó poteto-mode y el playbook Feature del paquete, armó la lista con `TaskCreate`, delegó el cambio a un hijo de `Task`, verificó con la prueba y citó su salida; `conducta.py --forma claude` sale 0. La flota sale `executor: cli` con un modelo `anthropic/…`.
- **fuera**: pedido escribir fuera de su carpeta con Bash o con la herramienta de escribir, el archivo no existe (sandbox de M-23).
- **revisión rota**: sobre el repo con el defecto sembrado, `verdict: changes` con el hallazgo; la foto del repo real queda igual y el clon de la corrida se borra al cerrar.

Las corridas anteriores del mismo banco destaparon y cerraron, en orden: el claim de un adaptador no autorizado que cortaba la pasada (G7 r3), claude sin el paquete de contexto (r4), la lista de pasos que en 2.1.301 es `TaskCreate` (r5, M-24 punto 5) y el juez de la forma claude, que solo contaba lecturas con Read y la cita de las últimas líneas (r6).

### M-24, punto 6: las herramientas de archivo fuera de la carpeta (2026-10-16, coordinador)

Mismo repo de juguete, `--restricted --strict-mcp-config --tools Read,Edit,Write,Bash --allowed-tools Read,Edit,Write,Bash --add-dir <run>` y el sandbox. Pedido: Write de un archivo fuera (carpeta bajo `~/.local/state`, no `/tmp`), Edit de un archivo fuera y Write de uno dentro de `--add-dir`. Resultado (`restricted-write.jsonl`):

```
RES /Users/dn/.local/state/sua-loop/mediciones/m24/fuera/w.txt is outside <cwd>, ...
RES /Users/dn/.local/state/sua-loop/mediciones/m24/fuera/e.txt is outside <cwd>, ...
RES File created successfully at: <run>/dentro.txt
DENIALS ['Write:/Users/dn/.local/state/sua-loop/mediciones/m24/fuera/w.txt', 'Read:/Users/dn/.local/state/sua-loop/mediciones/m24/fuera/e.txt']
```

El archivo de fuera no existe y el editado sigue con su texto. `--restricted` encierra las herramientas de archivo en el cwd y en `--add-dir` (su `--help` lo dice: "confines the file tools to the working directories (--add-dir included)"), y el sandbox encierra Bash (M-23).

## M-18, la ruta "encargo nativo a un agente" de punta a punta (2026-10-16, coordinador)

`agentes.py sondear ingenieria` desde la Mac: `main` arma el brief con `brief.py --agente ingenieria --perfil ingenieria --contrato`, crea y admite la tarea gestionada (`target.kind=agent`), R lanza el hijo de `ingenieria` y el hijo reporta con `reporte.py` por `managed_tasks_report`.

- **M-18 (G4, 471eabf8): rojo.** La tarea `87b98ddf-12b4-466f-94f1-632a6c688ff5` llegó al hijo, pero el hijo no tenía protocolo de reporte: armó `{result: {contract, typedPayload, artifacts}}` y R contestó "Managed task result is invalid". La tarea quedó admitida y sin resultado, con 0 entregas a David y `memory/` igual. De ahí salió G4b (4.5b).
- M-18b (b7387f9b) y M-18c (9146530f): las tareas 61fa5ea9 y a1819dae llegaron a `result-recorded`, pero la sonda daba rojo por defectos suyos: buscaba el marcador en `result_json`, y la lectura del artefacto se rompía en el zsh de la Mini.
- **M-18d (33b9c7ac): verde.** `{"ok": true, "taskId": "1682b3ab-d70b-4443-a790-8812f49e6607", "estado": "result-recorded", "marcador": true, "entregas": 0, "memoriaIgual": true}`, con el artefacto borrado.
- **M-18e (cafe6333): verde otra vez.** La tarea fdd844fa quedó `result-recorded`, con el marcador, 0 entregas y la memoria igual. El ayudante borró el artefacto resolviendo la ruta con realpath.

## M-19 y M-20, la sucesión nativa (`claw_autoupdate` de goncloud-hermes, en la Mini)

- **M-19 (dry-run, solo lectura).** `python3 ~/goncloud-autoupdate/claw_autoupdate.py --openclaw ~/.openclaw/bin/openclaw --config ~/.openclaw/openclaw.json --dry-run`, salida 0. Plan: `openai/gpt-5.6-sol -> openai/gpt-6.1-sol` en defaults, adversary, ingenieria y main. Una corrida anterior lo había dejado "No cambiado": su sonda falló porque `models.providers["openai"]` no declaraba el modelo.
- **M-20 (la primera corrida real, launchd `ai.goncloud.claw-autoupdate` a las 04:50 PDT).** Salida 0. El log literal:

```
Claw: modelos 2026-10-16
- No cambiado: openai/gpt-5.6-sol -> openai/gpt-6.1-sol (sonda (xhigh): Thinking level "xhigh" is not supported for openai/gpt-6.1-sol. Use one of: minimal, low, medium, high, ultra.).
```

Encontró el sucesor y lo sondeó antes de promover. La sonda usó el nivel de razonamiento del modelo actual, que el sucesor no acepta, y no promovió: falla cerrada, como pide I10 ("canario fallido no se promueve"). La causa es distinta de la de M-19. Las dos quedan como filas de goncloud-hermes en `followups.md`.

## M-22, una promoción en la ruta por CLI con una línea de fixture (2026-10-16, coordinador)

La línea del modelo por omisión de verdad, `zai-coding-plan/glm-{}-flash`, no tiene sucesor en el catálogo (`glm-5.3-flash` es la única versión). Para medir la promoción completa, un checkout aparte cambió solo la línea de `glm` en `proveedores-permitidos.json` a `zai-coding-plan/glm-{}` desde `zai-coding-plan/glm-5.2`. El catálogo real lista `glm-5.2` y `glm-5.3`. Se usó un `--state-root` vacío y aparte, con los avisos apagados. Después, `encargo.py sucesion --aplicar` con el R construido:

```
{"ok": true, "accion": "promovido", "linea": "zai-coding-plan/glm-{}", "promovido": "zai-coding-plan/glm-5.3", "anterior": "zai-coding-plan/glm-5.2", ..., "avisoPendiente": "aviso pendiente: avisos apagados (AGENT_WORK_AVISOS no es 1)"}
```

El canario fue el caso de ingeniería del banco real, con opencode y `glm-5.3`:

```
BANCO_E2E case=ingenieria task=cefd442d-970a-41c5-8e74-da1fae4f11b5 conducta=ok suite_repo=pasa
BANCO_E2E case=ingenieria desenlace=verde causa=ninguna
Ran 1 test in 195.846s
OK
```

Después, `encargo.py proveedores` sobre ese estado muestra el efectivo `zai-coding-plan/glm-5.3 (promovido desde sucesion.json)`, sin editar `proveedores-permitidos.json`. El aviso quedó pendiente porque los avisos se apagaron a propósito.

## La ventana viva de SUA-04 (2026-10-16, coordinador)

- El host de encargos pasó a `main` (`25f6d941`) y se reinició.
- En la Mini, `managedTasks.hosts["mac-local"].adapters` pasó de `["opencode"]` a `["opencode", "claude"]` con `openclaw config patch` (el dry-run validó antes). El gateway lo tomó en caliente: el host dejó de recibir el rechazo del claim de claude sin reiniciar el gateway.
- `instalar-mac.sh` corrió con `LAUNCHCTL_BIN=/usr/bin/true`, porque el vigilante `tmux-activity-watch` sigue apagado a propósito, y solo se cargó `ai.goncloud.agent-work-sucesion` (`diario`, 05:30). Su primera corrida real, el 2026-10-16 a las 05:30, salió con 0: `{"ok": true, "sucesion": {"accion": "nada-que-probar", ...}, "fuentes": {"ok": true, ..., "aviso": {"vencen": [], "enviado": false, "ultimoAviso": null}}}`.
- La skill `encargo-cli` de `main` quedó publicada en la Mini con los pasos de `solicitar` (sha1 `cd21aa5c`, con respaldo). `agent-dispatch` ya coincidía con el repo.
- **Canario vivo de la ruta claude.** `main` lo pidió "por CLI con claude opus" sobre un repo de juguete. El primer intento salió rojo en `preparar`: el exec de `main` no tiene `~/.local/bin` en el PATH, así que no encontraba `claude`, y la frase nombraba a opencode. Lo arregló #326. En el segundo intento, la tarea `b8c5a12d-5276-4099-91b4-87ff10ffc6b1` tuvo modelo `anthropic/opus`, cobro `subscription`, estado `acknowledged`, cierre `AbsenceVerified`, `proveedoresLlamados: ["anthropic"]` y `permisosNegados: []`. El init de claude trajo `model: claude-opus-5-5`, las siete herramientas del perfil y `mcp_servers: []`, y el repo quedó arreglado con su prueba verde.

Nota de CodeRabbit en #324: M-21 no registró conectores con `--setting-sources project` y M-24 sí, en otro repo y con los conectores de claude.ai cargados en la cuenta. La ruta usa `--restricted --strict-mcp-config`, que M-24 midió sin MCP, así que la diferencia no cambia la ruta. Queda sin explicar.
