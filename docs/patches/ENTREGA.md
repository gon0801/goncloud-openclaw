# Entrega Fase 1 — fix/agentes-openclaw

## Tabla hallazgo → cambio → evidencia

| Diagnostico | Cambio | Evidencia |
|---|---|---|
| Workspaces plantilla / BOOTSTRAP | W1 IDENTITY/USER/SOUL + delete BOOTSTRAP | diff `workspace-*` |
| AGENTS.md Claude Code | W2 tools OpenClaw + Dos maquinas + Contrato + Grok + skills reales | `rg saikit:\|ctx7\|\`Write\`` vacio |
| summa-gate role order | `canonicalRole` implementer antes que test; extract `lib.ts` | `docs/patches/summa-gate-RED.txt` → `summa-gate-GREEN.txt` (11/11) |
| OpenAI cuota / codex / cadenas | M1 FASE B: 4 proveedores; `ingenieria` primary grok; fase2 main+ops; fase3 anthropic; eslabon-6 | `docs/patches/modelos-*.json5`, brief FASE-B |
| pathPrepend warning / noise | N1 docs + `scripts/mac/shot.sh` | `docs/patches/n1-mac-node.md`, `shot-evidence.txt` |

## Para el lead

1. Aplicar M1 fase1 en el **gateway** (dry-run remote desde Mac falla resolucion de modelos). Ver `docs/patches/README.md`. Luego V1 pings.
2. Aplicar fase2-main-operaciones solo despues del estreno.
3. Fase3 anthropic solo cuando authStatus liste anthropic (setup-token lo corre David).
4. N1.2 PATH: ya incluye homebrew; ampliar solo si hace falta; reinicio desconecta.
5. N1.4 file-transfer approvals + paths locales para imagenes.
6. Fuera de alcance: `openclaw doctor` (sessions_search DB), sessions_send announce, heartbeat 60 min.

## not_observed

- V1 pings (lead no aplico M1).
- Dry-run exit 0 desde Mac remote: falla resolucion de modelos no-OpenAI (`models list` remote solo OpenAI). Patches siguen el brief; dry-run real en gateway.
- Toggle dedicado allowPrivateNetwork para `view_image`.
- `openclaw config get agents.entries.<id>.model` via remote: unset; rollback re-verificado contra `gateway call config.get` → `parsed.agents.entries` (coincide con snapshot).
- Rescate OpenAI nativo→codex forzado de punta a punta (`eslabon-6-openai.md`).

## Obstaculos del brief corregidos

1. `config get …model` remote unset → rollback desde snapshot `openclaw.json`.
2. PATH del nodo ya no es solo `/usr/bin:/bin:...`; incluye homebrew (observed en `ai.openclaw.node.env`).
3. Dry-run remote no valida zai/kimi/deepseek; aplicar/validar en gateway.
4. Follow-up audit: cadenas cortas → 4 proveedores + fase2/3.
5. **FASE B** (`docs/briefs/2026-09-10-cursor-FASE-B-cadenas-modelos.md`): `ingenieria` primary `xai/grok-4.6` (antes deepseek-pro); patches fase1/fase3 actualizados. No aplicado.
