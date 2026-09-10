# Patches de modelo — APLICADOS 2026-09-10

Estos archivos ya fueron aplicados al gateway el 2026-09-10 y quedan como registro de lo aplicado. Nota de fidelidad: lo aplicado en produccion usa `deepseek/deepseek-v4-flash` donde la tabla FASE-B original decia `deepseek/deepseek-v4-pro` (decision de David, 2026-09-10); estos archivos ya reflejan el flash real. `modelos-rollback.json5` NO se toco: describe el estado pre-M1 exacto (primarios OpenAI) y solo sirve para volver a ese estado.

`config patch` mergea objetos y **reemplaza arrays enteros**. Los `fallbacks` del patch sustituyen la lista previa completa.

Reglas de cadena (FASE B, brief `2026-09-10-cursor-FASE-B-cadenas-modelos.md`): ningun agente repite proveedor; toda la cadena en runtime nativo (sin OpenAI-OAuth/codex); 4 proveedores + Anthropic como 5o. Esta tabla reemplaza M1 puntos 1-2 del brief de agentes.

**Donde se aplican.** `openclaw config patch` desde la Mac escribe `~/.openclaw/openclaw.json` local, no el gateway. Correr los patches **en la maquina Windows** (CLI local al gateway). No usar `gateway call config.patch` a ciegas (sin dry-run verificado).

## Fuente del rollback

`openclaw config get agents.entries.<id>.model` (CLI remote) devolvio **unset**.

**Re-verificado 2026-09-10** con lectura viva (permitida):

```bash
~/.openclaw/bin/openclaw gateway call config.get --params '{}'
# usar parsed.agents.entries.<id>.model
```

Los valores de `modelos-rollback.json5` coinciden con esa lectura viva del gateway (mismo contenido que el snapshot `openclaw.json` del repo en ese momento). Si el gateway diverge despues, regenerar el rollback antes de revertir.

## modelos-fase1.json5

Reasigna implementer, reviewer, adversary, verifier, ingenieria. Cada cadena tiene 4 proveedores distintos. No toca `main` ni `operaciones`.

Cadenas (FASE B):

| agente | primary | fallbacks |
|---|---|---|
| implementer | zai/glm-5.3 | deepseek-v4-flash, kimi/k3, xai/grok-4.6 |
| reviewer | kimi/k3 | deepseek-v4-flash, zai/glm-5.3, xai/grok-4.6 |
| adversary | deepseek-v4-flash | kimi/k3, zai/glm-5.3, xai/grok-4.6 |
| verifier | deepseek-v4-flash | zai/glm-5.3, kimi/k3, xai/grok-4.6 |
| ingenieria | **xai/grok-4.6** | zai/glm-5.3, deepseek-v4-flash, kimi/k3 |

```bash
# En la maquina Windows (gateway), no desde la Mac remota:
openclaw config patch --file docs/patches/modelos-fase1.json5 --dry-run
openclaw config patch --file docs/patches/modelos-fase1.json5
```

Verificar despues:

```bash
for id in implementer reviewer adversary verifier ingenieria; do
  ~/.openclaw/bin/openclaw config get agents.entries.$id.model
done
```

Esperado: `ingenieria` primary `xai/grok-4.6`; los demas segun tabla; ningun primario OpenAI-OAuth.

**Nota xAI OAuth:** el token en Windows puede vencer ~6 h. Si no auto-renueva, `ingenieria` cae a zai (cadena viva, no bug). Renovar solo en Windows con `openclaw models auth login --provider xai --agent main`.

## modelos-fase2-main-operaciones.json5

`main` y `operaciones`. Aplicar **despues** del estreno de packing. Incluye el 5o eslabon Anthropic (ya desbloqueado) para no dejar esos dos agentes en 4 eslabones.

- `main` → zai → deepseek-pro → kimi → xai → anthropic/claude-sonnet-5
- `operaciones` → zai *(sin cambio de primary)* → deepseek-flash → kimi → xai → anthropic/claude-sonnet-5

```bash
# Windows / gateway, despues del estreno:
openclaw config patch --file docs/patches/modelos-fase2-main-operaciones.json5 --dry-run
openclaw config patch --file docs/patches/modelos-fase2-main-operaciones.json5
```

## modelos-fase3-anthropic.json5

5to eslabon para el pipeline + `ingenieria`. **YA DESBLOQUEADO (2026-09-10 ~07:50Z).** David instalo setup-token; `models.authStatus` lista `anthropic` (`anthropic:manual`, type token, inherited, sin expiracion). Smoke: verifier + `anthropic/claude-haiku-4-5` → harness nativo con tools.

**Aplicable junto con fase1** en Windows. No toca `main` ni `operaciones` (esos van en fase2 post-estreno, ya con Anthropic en la cola).

```bash
# Windows / gateway, junto con fase1:
openclaw config patch --file docs/patches/modelos-fase3-anthropic.json5 --dry-run
openclaw config patch --file docs/patches/modelos-fase3-anthropic.json5
```

Contenido: `anthropic/claude-sonnet-5` en implementer/ingenieria/verifier; `anthropic/claude-opus-5` en reviewer/adversary. Cadena FASE B completa por agente.

Este eslabon consume la **misma** cuota de la suscripcion Claude de David. Si estorba, API key de Anthropic aparte. El token **no** entra al repo.

## Rollback

```bash
# Windows / gateway:
openclaw config patch --file docs/patches/modelos-rollback.json5 --dry-run
openclaw config patch --file docs/patches/modelos-rollback.json5
```

Si solo aplicaste fase1, el rollback tambien reescribe main/operaciones al snapshot. Recorta el JSON a mano si no queres eso.

## Ventana post-reset / ajuste con datos (documentado, no aplicar)

- 2026-09-10 ~13:41Z: chequear si OAuth xAI se auto-renovo. Si no, y login manual cada 6 h es insostenible, bajar `ingenieria` primary a eslabon profundo.
- 2026-09-12 (reset xAI semanal): reevaluar burn de grok en `ingenieria`.
- 2026-09-15 (reset OpenAI): ver `eslabon-6-openai.md` antes de reintroducir gpt-5.x.
- Metricas: `openclaw audit --kind agent_run --status failed --agent <id>`; `models.authStatus` (openai/xai/deepseek). Audit no guarda el modelo que atendio cada corrida.

## V1 — solo despues de que el lead aplique fase1 (y fase3 si va junto)

Por cada uno de `implementer`, `reviewer`, `adversary`, `verifier` (NUNCA main/operaciones/ingenieria):

```bash
~/.openclaw/bin/openclaw agent --agent <id> -m "Responde exactamente: PONG" --json
~/.openclaw/bin/openclaw gateway call sessions.list --params '{"agentId":"<id>","limit":1}'
```

Assert: responde; modelo nuevo; `defaults.agentRuntime.id` distinto de `codex`.
