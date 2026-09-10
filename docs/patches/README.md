# Patches de modelo (Fase 1) — NO aplicados

Estos archivos son para que el **lead** corra `openclaw config patch`. Cursor no los aplica.

`config patch` mergea objetos y **reemplaza arrays enteros**. Los `fallbacks` del patch sustituyen la lista previa completa.

## Fuente del rollback

`openclaw config get agents.entries.<id>.model` (CLI remote desde esta Mac) devolvió **unset** para implementer/reviewer/adversary/verifier/ingenieria/main. El remote solo expuso `agents.entries.main: {}`.

Los valores de `modelos-rollback.json5` salen del snapshot del repo `openclaw.json` en `origin/main` (mismo checkout que el gateway Windows). Verificar en vivo con el lead antes de revertir si el gateway ya diverge.

## modelos-fase1.json5

Reasigna implementer, reviewer, adversary, verifier, ingenieria. No toca `operaciones` ni `main`.

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

Esperado: primarios zai/kimi/deepseek segun el patch; ningun primario OpenAI-OAuth.

Revertir:

```bash
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-rollback.json5 --dry-run
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-rollback.json5
```

(El rollback restaura tambien `main`; si solo aplicaste fase1, recorta el JSON a mano o acepta reescribir main al valor del snapshot.)

## modelos-fase2-main.json5

Solo `main`. Aplicar **despues** del estreno de packing (cron report-7h-estreno 13:25/13:45Z del 2026-09-10).

```bash
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-fase2-main.json5 --dry-run
~/.openclaw/bin/openclaw config patch --file docs/patches/modelos-fase2-main.json5
```

## Ventana post-reset (documentado, no aplicar)

- 2026-09-12 (reset xAI): evaluar `ingenieria` → primary `xai/grok-4.6`.
- 2026-09-15 (reset OpenAI): reevaluar si vuelve gpt-5.x y a que agente.

## V1 — solo despues de que el lead aplique fase1

Por cada uno de `implementer`, `reviewer`, `adversary`, `verifier` (NUNCA main/operaciones/ingenieria):

```bash
~/.openclaw/bin/openclaw agent --agent <id> -m "Responde exactamente: PONG" --json
~/.openclaw/bin/openclaw gateway call sessions.list --params '{"agentId":"<id>","limit":1}'
```

Assert: responde; modelo nuevo; `defaults.agentRuntime.id` distinto de `codex`.
