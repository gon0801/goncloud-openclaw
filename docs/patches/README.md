# Patches de modelo — NO aplicados

Estos archivos son para que el **lead** corra `openclaw config patch`. Cursor no los aplica.

`config patch` mergea objetos y **reemplaza arrays enteros**. Los `fallbacks` del patch sustituyen la lista previa completa.

Reglas de cadena (brief): ningun agente repite proveedor; toda la cadena en runtime nativo (sin OpenAI-OAuth/codex); 4 proveedores distintos hoy, 5 cuando entre Anthropic.

## Fuente del rollback

`openclaw config get agents.entries.<id>.model` (CLI remote desde esta Mac) devolvio **unset**. El remote solo expuso `agents.entries.main: {}`.

Los valores de `modelos-rollback.json5` salen del snapshot del repo `openclaw.json`. Verificar en vivo con el lead antes de revertir si el gateway ya diverge.

## modelos-fase1.json5

Reasigna implementer, reviewer, adversary, verifier, ingenieria. Cada cadena tiene 4 proveedores distintos. No toca `main` ni `operaciones`.

```bash
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-fase1.json5 --dry-run
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-fase1.json5
```

Verificar despues:

```bash
for id in implementer reviewer adversary verifier ingenieria; do
  ~/.openclaw/bin/openclaw config get agents.entries.$id.model
done
```

Esperado: primarios zai/kimi/deepseek segun el patch; ningun primario OpenAI-OAuth; 3 fallbacks nativos.

## modelos-fase2-main-operaciones.json5

`main` y `operaciones`. Aplicar **despues** del estreno de packing.

- `main` → primary `zai/glm-5.3`, fallbacks deepseek-pro / kimi / xai
- `operaciones` → primary `zai/glm-5.3` (sin cambio), fallbacks deepseek-flash / kimi / xai (saca el eslabon muerto `openai/gpt-5.6-sol`)

```bash
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-fase2-main-operaciones.json5 --dry-run
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-fase2-main-operaciones.json5
```

## modelos-fase3-anthropic.json5

5to eslabon. Aplicar **solo** cuando `models.authStatus` liste `anthropic`.

Prerequisito (lo corre David en persona; Cursor no lo ejecuta ni escribe el token): `claude setup-token` en la Mac → lead instala con `openclaw models auth login --provider anthropic --method setup-token`.

```bash
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-fase3-anthropic.json5 --dry-run
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-fase3-anthropic.json5
```

Contenido: ultimo eslabon `anthropic/claude-sonnet-5` en main/operaciones/implementer/ingenieria/verifier; `anthropic/claude-opus-5` en reviewer/adversary.

Este eslabon consume la **misma** cuota de la suscripcion Claude de David. Si estorba, cambiar a API key de Anthropic sin tocar el resto de la cadena. El token **no** entra al repo.

## Rollback

```bash
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-rollback.json5 --dry-run
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-rollback.json5
```

Si solo aplicaste fase1, el rollback tambien reescribe main/operaciones al snapshot. Recorta el JSON a mano si no queres eso.

## Ventana post-reset (documentado, no aplicar)

- 2026-09-12 (reset xAI): evaluar `ingenieria` → primary `xai/grok-4.6`.
- 2026-09-15 (reset OpenAI): ver `eslabon-6-openai.md` antes de reintroducir gpt-5.x.

## V1 — solo despues de que el lead aplique fase1

Por cada uno de `implementer`, `reviewer`, `adversary`, `verifier` (NUNCA main/operaciones/ingenieria):

```bash
~/.openclaw/bin/openclaw agent --agent <id> -m "Responde exactamente: PONG" --json
~/.openclaw/bin/openclaw gateway call sessions.list --params '{"agentId":"<id>","limit":1}'
```

Assert: responde; modelo nuevo; `defaults.agentRuntime.id` distinto de `codex`.
