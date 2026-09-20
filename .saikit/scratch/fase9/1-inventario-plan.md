# Fase 9 — Inventario del plan (13 filas, todas `cc:TODO`)

Leído de `Plans.md` en `origin/main` (`7a83ee6`). El runbook nombra 9.0–9.9; el plan trae además
9.10, 9.11 y 9.12 (fuera del alcance escrito del runbook — el lead decide si las suma a D/cierre
o las declara; la revisión de cierre manda contra esta DoD literal).

| Tarea | Lane | Título | Depende |
|---|---|---|---|
| 9.0 | fast, spike-medición | Spike: lo que no se sabe (Hermes, muse timeout, `muse --yolo`+red, `dsh`, transcript claw, Tailscale PC→Mac). Salida `docs/evidence/fase9-spike.md`, una línea `veredicto <tema>: <valor>` por tema | — |
| 9.1 | fast | Contratos `corrida.v1` + `seguimiento.v1` + `scripts/mac/cli-modos.tsv` (12 CLIs de `AGENT_TMUX_TOOLS`) + fixtures | — |
| 9.2 | gate | `scripts/mac/corrida.sh`: abrir, lanzar-sesion, cerrar, `corrida_mensaje` (biblioteca). Registro en `~/.local/state/corridas/<id>/`, permisos 600, destino leído de cron existente, todo subcomando lee del registro | 9.1 |
| 9.3 | gate | Preflight `APTO`/`NO APTO`: gh real, binarios bajo PATH mínimo, flags, vigilante = blob de `origin/<default>`, gateway, `message send --dry-run`, clases de comando declaradas | 9.2 |
| 9.4 | gate | `corrida.sh estado`: parte sin modelo (registro, espejo `runbook-progress.v1`, líneas `LISTO`/`ATORADO`, diálogos, carril callado 30 min, TIMEBOX, PRs por `gh`) | 9.1 |
| 9.5 | gate | Latido LaunchAgent `ai.goncloud.corrida-latido` cada 5 min: mensaje ante cambio/60 min/diálogo 10 min; despierta al vigía (`system event` claw, `eventos.jsonl` Hermes); hombre muerto = cron `corrida-vigia-<id>` | 9.4 |
| 9.6 | gate | `corrida.sh responder <sesión>`: decide con tabla del registro, **nace apagado** (solo actúa con `responder.on`; sin él registra en `decisiones.jsonl` y no manda teclas) | 9.2 |
| 9.7 | gate | Loop §§1,3,8,9,12 → `corrida.sh`+`seguimiento.v1`; TIMEBOX con pausas al loop; skill `autopilot-runbook` (slots Seguimiento + Clases de comando); plantilla de encargo; `guia-del-vigia.md`; skills `agent-dispatch` y `mac-tmux-control` llaman a `corrida.sh` y marcan antes de mandar | 9.2–9.6 |
| 9.8 | gate | Rama por defecto en rojo no pasa en silencio: el latido avisa `DETENIDA` en lenguaje de usuario + registro local con sha/autor/archivos. **No se toca `scripts/sync-repos.ps1`** | 9.5 |
| 9.9 | release, medición viva | Simulacro 7 escenarios + cierre. Evidencia `docs/evidence/fase9-simulacro-<fecha>.md`. Despliegue a `~/bin` | 9.0–9.8 |
| 9.10 | gate | `scripts/mac/instalar-mac.sh`: instala 6 archivos, genera plist con `$HOME`+uid propios, `--dry-run`/`--verificar`, idempotente | 9.3 |
| 9.11 | gate | Agente `usuario` (`agents/usuario/agent/AGENTS.md`): prueba sin leer código, reporta `FUNCIONA`/`NO FUNCIONA`/`NO PUDE PROBARLO`, evidencia `docs/evidence/usuario-<fase>-<AAAA-MM-DD>.md`. Primera corrida real: tablero Fase 7 | 9.1 |
| 9.12 | gate | `scripts/cierre-de-fase.sh` + séptima comprobación `usuario`; el plan declara por fila su promesa observable; la skill lo exige | 9.11 + PR que agrega `cierre-de-fase.sh` |

DoD literal completa de cada fila: ver `tmp/fase9-plan-rows.txt` (extraído en este turno) o `Plans.md`.
