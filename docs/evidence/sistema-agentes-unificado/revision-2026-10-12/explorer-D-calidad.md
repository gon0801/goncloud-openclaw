# Explorador D: quality-kit hoy vs quality-policy.v2

## Piezas de quality-kit (/Users/dn/quality-kit HEAD 912cb8d, 2026-09-27)
| Pieza | Qué hace | Mecanismo o texto | Cableado |
|---|---|---|---|
| init-repo.ps1 | Detecta stack, escribe .pre-commit-config.yaml, instala hooks, copia templates/quality.yml, escribe bloque CALIDAD en AGENTS.md/CLAUDE.md del repo (:987-1040) | Hooks y CI = mecanismo; bloque = texto | A mano o heal-repo -AutoInit |
| heal-repo.ps1 | Cada sesión re-arma pre-commit; con -AutoInit corre init-repo en repos gon0801 o sin remoto | Mecanismo | SessionStart de ~/.claude/settings.json:79 (solo Claude) |
| check_memory.py | Reporta memorias >40 líneas, huérfanas, links rotos | Avisa, no bloquea | SessionStart :89 |
| install-ai-rules.ps1 | Pega bloque REGLAS DE CALIDAD 1-8 en ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md, ~/.kimi-code/AGENTS.md, ~/.config/kilo/AGENTS.md | Solo texto | A mano; no escribe en OpenCode |
| cross-review.ps1 | Lanza UNA revisión con otra CLI; cadena fija claude→glm→grok→kimi→qwen→codex; -Excluir un solo nombre; recorta diff a 60.000 chars; sale 3 si nadie responde | Transporte: no cuenta rondas, no aplica stop2, no decide; sale 0 aunque haya BLOQUEANTE | loop-autopilot §4 y regla 4 |
| install-repo-hygiene + check-context-docs.py | Hook de límites de CLAUDE/AGENTS | Mecanismo | accounting, Orbit, server, summonaikit; NO openclaw |
| install-ci-linux.ps1 | suite-linux.yml con shards | Mecanismo CI | Por repo |
| install-branch-push-policy.ps1 | Config de guardrail de otro plugin | Config | Por repo |
| saikit-gate-heal.ps1 | Parchea hook de SummonAI Kit | Inactivo (kit apagado 27-sep) | — |
| templates/quality.yml | pre-commit + pytest -n auto + job gate; NO implementa clasificador fast | Mecanismo CI | Repos con remoto |

Mecanismo propio de G que hace cumplir reglas: scripts/mac/corrida_worker/gates.py (review del head exacto; revisor-es-autor contra authors; mismo-revisor; push exige cross-review aprobada; stop2 mecanizado como bloqueante-repetido con rounds_seen>=2 :400-403; cero bloqueantes para merge; CI y CodeRabbit del SHA). Invocado por scripts/mac/corrida/compuerta.sh. .github/workflows/quality.yml de G (clasificador por archivos, shards, auditoría de la unión). No verificado si gates.py se usa en corridas actuales.

## Cómo llegan las reglas hoy
1. install-ai-rules → bloque en archivos globales (Claude CLAUDE.md:57-75).
2. init-repo → bloque en cada repo + hooks + CI.
3. SessionStart de Claude → heal-repo -AutoInit y check_memory.
4. loop-autopilot.md §4 (origin/main): ronda 1 -Con auto -Excluir -Base; siguientes -Con otro -Desde; solo bloqueante con reproducción abre ronda; sin tope; stop2 → ATORADO; rotar revisor. gates.py lo hace cumplir con corrida.sh compuerta.
5. Loops de claw (encargos PROMPT.md): Claude revisa todas las rondas sin rotar (:79-80); hasta 5 rondas por implementador; REPETIDO: sí → relevo a codex con otras 5 → solo entonces David (:327-330); cross-review una vez en B5 con codex por tmux, no con cross-review.ps1; batería local como encargo B<b>-bateria (R no tiene push ni CI).

## Tabla regla por regla
| Regla | Dónde | Ejecuta/texto | En v2 | Quién en SUA |
|---|---|---|---|---|
| R1 hooks, nunca --no-verify | global :60, repo, PROMPT | Hooks se ejecutan; prohibición es texto; respaldo real: CI re-corre pre-commit | Se conserva | Hooks del repo + CI + controlador |
| R2 bug → prueba de regresión | global :61 | Texto | Se conserva | Verifier con EvidenceClaim |
| R3 focalizadas + batería una vez por SHA | global :62 | CI ejecuta; "una vez" es texto; GitHub no obliga checks (403 branch protection) | Se conserva con cambio: reutilizar evidencia exige artefacto, criterio, dependencias, entorno compatibles y frescura | CI + EvidenceClaim |
| R4a agrupar hallazgos | global :63 | Texto | Se conserva | Controlador |
| R4b cross-review con otra IA | global :63; obligatoria por bloque en G | Script transporte; obligatoriedad por gates.py | Cambia: revisión independiente en la política; lanzador migra a flota; diff completo sin recorte; exit 0 con BLOCKER no aprueba | Flota + reviewer sin escritura + controlador |
| R4c solo bloqueante con comando reproduce abre ronda | global :64 | Texto | Cambia: reproducción o evidencia estática verificable; sospecha abre investigación | Reviewer + controlador |
| R4d siguientes rondas solo delta | global :64 | -Desde mecanismo | Se conserva y amplía (delta + efecto en contratos; cambio fuera invalida evidencia) | Controlador |
| R4e sin tope mientras haya bloqueante | global :64 | Texto | Se quita: máx. 4 ciclos por bloque | Dueño nativo (CorrectionBudget) |
| R4f stop2 | global :64; loop-autopilot :112; gates.py :401-403 mecanizado | Ejecutado en G | Se sustituye: 2 repeticiones → diagnóstico independiente + un relevo; detener con evidencia si no hay corrección, reaparece o se agota límite; nada reinicia el contador | Dueño nativo + controlador; excepción BLOQUEANTE_REPETIDO |
| R4g revisor distinto cada ronda | global :64; gates.py mismo-revisor | Ejecutado en G | Se quita: no rotar por ritual; discrepancia, falta de independencia o diagnóstico exigen otro | Flota |
| R4h bloqueante nunca al plan ni mergeado abierto | global; gates.py :404-406 | Ejecutado en G | Se conserva | Controlador + merge del head exacto |
| R4i no bloqueante no abre ronda | global | Texto | Se conserva | Controlador |
| R5 tardía → fila; checklist post-deploy una vez | global :65 | Texto | Se conserva con frescura; Plans.md = registro humano, no cola | Controlador |
| R6 sugerir init-repo | global :66 | Texto, pero heal-repo -AutoInit lo ejecuta solo | Opcional | Nadie obligatorio |
| R7 higiene CLAUDE/AGENTS | hook en 4-6 repos | Mecanismo | Se conserva si útil | Hooks del repo |
| R8a shards = unión, nunca recortar | G quality.yml + valida-union-shards.sh | Ejecutado en G | Se conserva | CI |
| R8b carril por tipo de cambio | global texto viejo "por tipo"; HEAD del kit "por ARCHIVOS fail-closed"; clasificador real solo en G | Ejecutado solo en G | Se conserva con corrección: no omitir por extensión; cambiar un corpus dispara su consumidor | CI + controlador |
| R8c checks de docs/ledger en job propio | global | Ejecutado | Se conserva | CI |
| R8d cierres de ledger = un PR | global | Texto | No se menciona | — |
| Delegación multi-IA | global :77-91 escrita a mano | Texto; gates.py excluye a todos los autores | Se absorbe en flota | Flota + dueño nativo |
| Activación | — | — | Nueva: recibo de adopción; sin recibo rige stop2 | Recibo; I12 |

## Mecanismo vs duplicación
Mecanismo real que SUA conserva: git hooks, quality.yml con shards/unión/clasificador (solo G), checker de higiene, transporte de cross-review.ps1.
Duplicación de texto: bloque de reglas en 4 archivos globales y 39 AGENTS/CLAUDE en ~/dev/* y ~/dev/wt/* con 8 versiones distintas del bloque CALIDAD (hashes distintos). Solo 2 tienen el texto nuevo "por ARCHIVOS". 9 repos no tienen stop2. loop-autopilot.md §4 copia la regla 4 y gates.py la mecaniza. La línea 61 del spec (reglas copiadas divergen) está comprobada.

## No obvio
1. Hoy conviven TRES políticas de rondas: (a) quality-kit stop2 sin tope y rotando revisor (global, loop-autopilot, gates.py); (b) loops de claw: 5 rondas por implementador → relevo con otras 5 → David, REPETIDO: sí releva en vez de parar, revisor fijo Claude (prompt-claw SKILL :59, PROMPT.md :327-330); (c) SUA v2: 4 ciclos + diagnóstico + un relevo. U3b pasó de (b) a (a): 35c0661 (29-sep) "5 rondas por implementador con relevo" → 8358fac (1-oct) "regla vigente de quality-kit". El PROMPT de encargos (4-oct) sigue en (b).
2. Los archivos globales (~/.claude/CLAUDE.md, ~/.codex/AGENTS.md, ~/.kimi-code/AGENTS.md) tienen la versión vieja de 3f17ed5 (18-sep, "por tipo de cambio"); la plantilla HEAD d35ad75 (20-sep) dice "por ARCHIVOS fail-closed". Plans 15.0 dice cc:完了 "regenerar instrucciones administradas" pero no se regeneraron.
3. BUG: ~/.config/kilo/AGENTS.md tiene rutas /private/tmp/quality-kit-memory-fix/... (27-sep). tests/run-tests.ps1:2132-2137 llama install-ai-rules redirigiendo Claude/Codex/Kimi pero no -KiloAgentsPath → correr la suite escribe el archivo REAL de Kilo. uninstall-ai-rules.ps1 no maneja Kilo.
4. cross-review.ps1 sale 0 aunque haya BLOQUEANTE; solo gates.py lee veredicto y SHA.
5. -Excluir excluye un nombre; la regla y gates.py excluyen a todos los autores. claude -p del cross-review corre sin restricción de herramientas (reviewer con escritura).
6. R6 dice "sugiere, no insistas" pero heal-repo -AutoInit inicializa solo.
7. --no-verify no tiene bloqueo mecánico para git commit --no-verify; respaldo: CI re-corre pre-commit.
8. SUA no se aplica a su propio trabajo documental; "cuatro" no es medido. final-review atrapó que el plan adoptaba v2 sin condición.

## Preguntas abiertas
Quién publica la fuente de política que sustituye a install-ai-rules; qué pasa con los 39 bloques en repos fuera de SUA; si v2 reemplaza también la política (b) de los loops de claw; si heal-repo/check_memory siguen; R8d y "+cross-review en release" sin equivalente; no verificado si gates.py se usa en producción.
