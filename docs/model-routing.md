# Enrutado de modelos de OpenClaw

Generado desde goncloud-motor-conf (`modelos.toml`, `papeles.toml`,
`rutas.toml`) con `ops/motor-h/genera-model-routing.py`. No se edita a
mano: `bash ops/motor-h/comprueba-tabla.sh` exige que este archivo
coincida con la conf.

## Carriles (en orden de relevo)

| Carril | Modelos |
| --- | --- |
| codigo | sonnet, k3, glm, grok |
| revisar | opus, k3, glm, grok |

Si no hay nadie del carril `revisar`, revisa cualquier modelo que no trabajó el bloque.

## Papeles

| Papel | Carril |
| --- | --- |
| implementar | codigo |
| revisar | revisar |

## Rutas de los carriles

| Modelo | Cuenta | CLI | Lanzamiento sin ventana |
| --- | --- | --- | --- |
| sonnet | anthropic | claude | `claude -p --model sonnet --permission-mode bypassPermissions --output-format json {prompt}` |
| opus | anthropic | claude | `claude -p --model opus --permission-mode bypassPermissions --output-format json {prompt}` |
| k3 | kimi | kimi | `kimi -p {prompt} --output-format stream-json` |
| glm | zai | opencode | `opencode run --auto -m zai-coding-plan/glm-5.3 {prompt}` |
| grok | xai | grok | `grok --prompt-file {brief} --always-approve --output-format json` |

## Rutas fuera de los carriles (solo entran si un plan las pide)

| Modelo | Cuenta | CLI | Lanzamiento sin ventana |
| --- | --- | --- | --- |
| muse | meta | muse | `muse exec --yolo --json --prompt-file {brief}` |
| deepseek | deepseek | claude | `claude -p --model deepseek-v4-pro --permission-mode bypassPermissions --output-format json {prompt}` |
| deepseek (env) | | | `ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL, ANTHROPIC_DEFAULT_HAIKU_MODEL, ANTHROPIC_DEFAULT_OPUS_MODEL, ANTHROPIC_DEFAULT_SONNET_MODEL, ANTHROPIC_MODEL, CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_CODE_SUBAGENT_MODEL` |
| qwen | qwen | qwen | `qwen --approval-mode yolo --output-format json {prompt}` |
