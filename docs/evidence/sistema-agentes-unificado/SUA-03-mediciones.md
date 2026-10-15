# M-13 (SUA-03), 2026-10-15 05:49-05:56Z, opencode 1.18.35 en la MacBook

Entorno como `opencode_env` (PWD, TMPDIR, OPENCODE_DISABLE_AUTOUPDATE, AGENT_WORK_MANAGED y OPENCODE_CONFIG_CONTENT con external_directory, enabled_providers y small_model), en un repo temporal por corrida. Script: `m13.sh`; salidas `<n>.out`, `<n>.err`, `<n>.meta`.

| Punto | Llave | Resultado | Aplica |
|---|---|---|---|
| a | `instructions: [<archivo>]` | El modelo repitió `NONCE-A-054929`, que solo estaba en el archivo | Sí |
| b | `skills.paths: [<dir>]` con una skill del mismo nombre en `~/.agents/skills` | opencode carga las dos y avisa `duplicate skill name ... existing=~/.agents/skills/... duplicate=<skills.paths>`: **gana `~/.agents/skills`**. Además lee `~/.claude/skills` (también con duplicados). El modelo no llamó a la herramienta `skill` y contestó una palabra que no estaba en ninguna, así que la carga se ve en el log y no en conducta | Se carga; pierde contra el global con el mismo nombre |
| c | `agent.poteto-agent.model` | `message=stream agent=poteto-agent modelID=glm-5.3-flash` (su archivo lo fija a glm-5.3) | Sí |
| e | eventos del hijo | En stderr (`--print-logs`) aparecen las líneas `message=stream agent=poteto-agent`; en el flujo JSON de stdout solo el `tool_use` de `task` del padre | Solo en el log |
| d | `permission.edit: "deny"` | La herramienta de escribir y editar no se ofrece al modelo (dijo que no la tiene); no hay línea `evaluated`; `prueba.txt` no existe | Sí, quitando la herramienta |
| f | `evaluated ... allow` contra `tool_use` | 2 `evaluated` (read y bash) para 2 `tool_use` completados. La corrida no terminó: `stream error` del proveedor después de las herramientas y alarma a los 240 s | 1 a 1 en esta muestra |
| 2a | `task` a poteto-agent con `-m kimi` sin override | `ProviderModelNotFoundError: Model not found: zai-coding-plan/glm-5.3`: el hijo falla porque su proveedor no está en `enabled_providers` | Falla, como se esperaba |
| 2b | lo mismo con `agent.poteto-agent.model = kimi-code-plan-cn/kimi-for-coding` | `agent=poteto-agent modelID=kimi-for-coding`, `task` completado | Sí |

Para el diseño de SUA-03: (a), (c) y (d) se pueden usar en `opencode_env`. En (b) los nombres de las skills del paquete tienen que ser únicos frente a `~/.agents/skills` y `~/.claude/skills` (prefijo propio), porque el global gana. (e) la conducta del hijo se lee del log de stderr, no del flujo JSON. Sin el override de (c) cada hijo `poteto-agent` falla con un modelo que no sea de zai.

Nota de G3-r2: por el punto (b), `coverage.json` deja `contextGenerations` vacío: la generación 1 queda SIN certificar para encargos (solo corre con `--canario`). La generación 2, con nombres propios de skills, la construye G4 y la certifica M-16.
