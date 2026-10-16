# SUA-04, recibo del bloque: modelos y agentes que se actualizan

Bloque SUA-04 del
[plan](../../superpowers/plans/2026-10-05-sistema-agentes-unificado.md), hecho según su
[diseño](../../superpowers/specs/2026-10-16-sua-04-modelos-y-agentes-design.md). Las
mediciones viven en [SUA-04-mediciones.md](SUA-04-mediciones.md). R es el checkout de
integración de OpenClaw (`7b3db54226bf`, el que corre en la Mini). G es este repo.

## Qué entregó

- **El modelo por omisión sube solo.** Cada permiso de `proveedores-permitidos.json` puede llevar una línea (`zai-coding-plan/glm-{}-flash`) y un `defaultGrant`. Ya no hay un `DEFAULT_MODEL` global. Cada noche, `encargo.py diario` (launchd `ai.goncloud.agent-work-sucesion`, 05:30) corre `sucesion --aplicar`. Si el catálogo trae un sucesor estable de la línea, lo prueba con el caso de ingeniería del banco real y lo promueve en `sucesion.json`, sin tocar la política, y le avisa a David. Un canario rojo lo deja `rechazado`, y `sucesion --revertir` vuelve al anterior.
- **Las rutas nativas suben solas desde goncloud-hermes.** `claw_autoupdate` (04:50 en la Mini) prueba el sucesor antes de promover. G solo lo registra en `coverage.json`.
- **Agentes que entran y salen.** `agentes.py descubrir` y `sondear` detectan las altas y los retiros de la Mini. `encargo.py perfiles --mini` muestra el estado de cada uno, y el publicador retira y devuelve agentes con respaldo.
- **La ruta "encargo nativo a un agente" cierra de punta a punta.** `brief.py --agente --contrato` trae el protocolo del trabajador y `reporte.py` arma el resultado que R acepta.
- **Abrir un proveedor a pedido de David (B22-S6).** `main` corre `encargo.py solicitar` y le pasa a David la frase. `permitir --ref tg:<session_id>:<seq>` coteja esa frase contra su mensaje de Telegram en la base de `main` antes de escribir. Los avisos salen por `avisar.py` solo con `AGENT_WORK_AVISOS=1`.
- **Fuentes por caducidad.** `encargo.py fuentes [--aviso]` muestra lo que vence en menos de 30 días y lo avisa una vez por semana.
- **Claude por su CLI, segundo adaptador del host, certificado.** `claude -p` con `--restricted --strict-mcp-config --tools <las del perfil>`, el sandbox, `--append-system-prompt-file` con el AGENTS.md de la corrida y sin `ANTHROPIC_API_KEY` (suscripción). La lista de pasos es `TaskCreate`. `conducta.py --forma claude` juzga su stream.
- **Los siete adaptadores sin host salieron de `coverage.json`** (G1).

## Estado por invariante

| Invariante | Estado | Evidencia |
|---|---|---|
| I10. Un sucesor estable funciona sin editar ids | **Cumplido en la ruta por CLI.** M-22 promovió un sucesor real (`glm-5.3` sobre `glm-5.2`, en una línea de fixture) con el banco real, y el efectivo cambió sin tocar la política. La línea de verdad (`glm-{}-flash`) no tiene sucesor hoy: `diario` dio "nada-que-probar". | SUA-04-mediciones.md (M-22, ventana viva); `test-agent-work-modelos.py`, `test-agent-work-encargo.py` |
| I10. Preview, proveedor sin acceso y canario fallido no se promueven | **Cumplido.** En la CLI, por pruebas (`lineas.py`, canario rojo = `rechazado`). En la nativa, M-19 y M-20: el sucesor `gpt-6.1-sol` no se promovió porque su sonda falló. | SUA-04-mediciones.md (M-19, M-20) |
| I10. El intento activo conserva su modelo | **Cumplido** (ya lo daba `LaunchSpec` congelado; probado con una promoción). | `test-agent-work-encargo.py` |
| I11. Un alta posterior recibe y devuelve una tarea | **Cumplido en la ruta nativa a un agente.** M-18d y M-18e verdes: `result-recorded`, 0 entregas, `memory/` igual. Medida, no certificada. | SUA-04-mediciones.md (M-18); `coverage.json` (`routes`, `native-managed-agent`) |
| I11. Alta incompleta visible; competencia y memoria preservadas | **Cumplido.** `perfiles --mini` y `descubrir`; un alta no cambia a los demás (prueba de I19 "nuevo destino"); la sonda mide `memory/`. | `test-agent-work-agentes.py`, `test-agent-work-publicar.py` |
| I19. Crash entre aplicar y verificar | **Cumplido** si se reaplica la misma generación. Con una edición del dueño de por medio, no se certifica (#323). Con otra generación, falla cerrado; queda como fila. | `test-agent-work-publicar.py`; `followups.md` (SUA-04/I19) |
| I19. Revocación permanece tras reversa; apply sin attest; nuevo destino | **Cumplido.** | `test-agent-work-publicar.py`, `test-agent-work-encargo.py` |

## Las rutas y la ventana viva

- **`mac-local/claude` certificada** con el banco de G7: ingeniería con conducta ok, `fuera=no-existe`, y revisión del repo roto con `verdict=changes repo=igual`. Además, **un canario vivo por `main`** quedó verde: tarea `b8c5a12d` con `claude-opus-5-5`, `acknowledged` y `AbsenceVerified`.
- `coverage.json`: cada ruta nombra su `modelSuccession` (la CLI, `encargo.py sucesion`; las nativas, `claw_autoupdate`) con su evidencia. La ruta `native-managed-agent` queda medida y sin certificar.
- En vivo, el 2026-10-16: el host pasó a `main` (`25f6d941`); el gateway de la Mini autoriza `claude` en `mac-local` (config patch, tomado en caliente); se cargó el launchd `diario` y su primera corrida salió en 0; la skill `encargo-cli` quedó publicada. El vigilante `tmux-activity-watch` sigue apagado a propósito: el instalador corrió sin cargar launchd.

## Los PR

| PR | Merge | Qué trajo |
|---|---|---|
| #315 | `71b65dd2` | Diseño |
| #316 | `0d2356ea` | G1: los siete adaptadores fuera |
| #317 | `ffa59225` | G2: regla de línea y modelo por omisión por proveedor |
| #318 | `5da7d375` | G4: altas, retiros y sonda |
| #319 | `545f80ba` | G3: sucesión con canario |
| #320 | `ee196e97` | G4b: protocolo del trabajador nativo (M-18 verde) |
| #321 | `994243f6` | G5: `solicitar`, `permitir --ref tg:` y avisos |
| #322 | `a2982e7c` | G6: fuentes, aviso semanal, `diario` e I19 |
| #323 | `260355a7` | G6: la edición del dueño tras un apply cortado (datos) y `fuentes` que falla si el aviso no sale |
| #324 | `b4a4d937` | G7: Claude por su CLI, certificado |
| #326 | `25f6d941` | G7: claude sin PATH (el canario vivo) |

Implementaron Muse Wonder (G4, G4b, G7 de r1 a r3) y GLM 5.3 Flash (G1 a G3, G5, G6 y G7 de r4 a r6, como relevo de Muse por cuota). Diseñó y revisó el coordinador (Claude), que hizo las mediciones, el banco real de G7, la certificación y la ventana viva, y arregló él mismo los hallazgos de los bots de #321, #322, #323, #324 y #326. #322 se mergeó con dos `Major` de CodeRabbit en línea sin leer; el de datos se arregló en #323.

## Lo que queda abierto

Las filas `SUA-04/*` de [followups.md](../agent-work/followups.md): la sucesión nativa que no sube `gpt-6.1-sol` (goncloud-hermes), los menores de la sucesión por CLI y de `fuentes`, I19 con otra generación, las pruebas de CI de la ruta claude, el aviso de `permitir`, el borrado de la sonda y la forma de `routes` y `migration` en `coverage.json`. Ninguna es bloqueante.
