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
