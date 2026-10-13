# Investigador why: control de versiones (git + gh)

## Source
git + gh en /Users/dn/quality-kit (gon0801/quality-kit), /Users/dn/dev/goncloud-openclaw (origin/main 77fafb0, git log --all), lectura del worktree flota-poteto sin modificarlo. No R, no encargos-b4 (solo git log desde el repo principal).

## What I Searched
quality-kit: git log --all; -S 'TOPE DURO', '100-150k', 'REGLAS DE CALIDAD', 'mismo bloqueante', 'Carril', 'una sola vez'; git show 2fd9a2f, 974c66f, 5f45117, 8d2644f, 5ec3ee9, d7329e2, 4103a19, 3f17ed5, d35ad75, 3c6efb5, fb90a8a, 88997fe; gh pr view #1–#18; gh issue list (vacío).
goncloud-openclaw: -S 'antes de U3b', 'U3a cerrada al 100%', 'U3 → U3a → U3b → U4', '5 rondas', 'RONDAS_AGOTADAS', 'política quality-kit vigente', 'mismo bloqueante', 'No heredes la excepción antigua de rondas'; git log -p origin/main -- Plans.md; git show 35c0661, 8358fac, 62956cf, a19501c, f734f2a, 8e2dde0, 84efcb0; gh pr view #48, #81, #83, #128, #159, #196, #207, #226, #227, #234, #241-#247; git grep docs/evidence 'tope alcanzado', 'ATORADO', 'BLOQUEANTE_REPETIDO', 'r[4-9]'; gh issue list (#137, #156, #191, ninguno sobre reglas).

## Direct Evidence
A. Regla 4 (rondas) en quality-kit, en orden:
1. 974c66f (2026-07-03): revisión cruzada entre 3 CLIs, sin tope.
2. 2fd9a2f (2026-07-29): "TOPE DURO: maximo 1 ronda… Cada ronda cuesta ~100-150k tokens". Mensaje: "Incidente 2026-07-30: 4 rondas seguidas en un fix-pack quemaron ~500k tokens con rendimiento decreciente (rondas 3-4 solo hallaron carreras microscopicas)." Única medición de costo de rondas en el kit.
3. 8d2644f / PR #7 (2026-09-08): reglas 3 y 5 (batería una vez por bloque; no repetir si CI validó el SHA). "Evita ciclos de validación repetidos".
4. 5ec3ee9 / PR #10 (2026-09-16): sin tope. "Decisión del dueño (2026-09-16): el tope duro dejaba hallazgos válidos sin atender".
5. d7329e2 / PR #11 (2026-09-18): para solo sin ALTA ni MEDIA; rotar revisor. Motivo: Fase 9, ronda 3 cerrada con 4 medias vivas declarando "tope alcanzado".
6. 4103a19 / PR #12 (2026-09-18 15:19): solo bloqueante reabre, tope 2 rondas. "La regla sin tope volvía el cross-review una cadena sin fin… siempre salía algo." Introduce -Desde.
7. 3f17ed5 / PR #13 (2026-09-18 16:47): "Decision del operador: sin tope fijo… si el mismo bloqueante vuelve en dos rondas seguidas, el arreglo no converge y decide el operador… un bloqueante nunca va a una fila del plan." Nace stop2. Tercera versión ese día.
8. 3c6efb5 / PR #15 (2026-09-22): -Base.
La regla de rondas cambió 6 veces entre julio y septiembre, 4 entre el 16 y el 18-sep.

B. Batería una vez en CI, CI paralelo, carril:
- PR #3 (2026-08-29, decisión de gon "tras preguntar por qué cada tarea tomaba horas"): Orbit ~6 min por push, 17 pushes ≈ 1.7 h de espera duplicada (daño causado por el propio kit con pre-push), corregido moviendo el candado a CI.
- PR #8 (2026-09-09): summonaikit batería 22-26 min por PR vs 2.7 de diseño; shardear, nunca recortar.
- d35ad75 / PR #14 (2026-09-20, Fase 15): carril fast por archivos. fase15-ci-performance.md: "174 s… baseline 422 s… −59 %; los PR de solo documentación ya no pagan la batería".

C. Incidentes en goncloud-openclaw (loop-autopilot.md §4, origin/main):
- "2026-09-16, PR #48: catorce rondas cruzadas sobre un cambio de documentación, a 100-150 mil tokens cada una, todas con el mismo revisor… ninguna era la falta de un tope: el revisor nunca rotó, y se siguió rondando por hallazgos bajos."
- "2026-09-18… 'sin tope, se sigue mientras aparezcan altas o medias' volvió la revisión una cadena sin fin… (quality-kit #12). Ese mismo día quitó el tope (#13)".
- §5: PR #48 mergeado con CodeRabbit verde y 13 comentarios accionables sin leer (6 altos; 4 candados que daban verde con el defecto puesto).
- PR #48 dice lo contrario: "cada ronda encontró algo real"; la cadena cayó (exit 3): glm, grok, qwen colgados >300 s; kimi y codex sin cuota.
- PR #81 (Fase 9): 7 rondas; ronda 6 (claude) halló 1 alta + 3 medias después de 3 rondas solo con medias.

D. Rondas reales en encargos (B0-B4) con la regla vigente:
- #242 (B0): ronda 1 CAMBIOS, 1 bloqueante reproducible (relanzar sesión duplicaba identidad); ronda 2 APROBADO.
- #243 (B1): APROBADO r1. #245 (B2): APROBADO r2 (bloqueante cerrado con 2 pruebas). #246 (B3): B3-1, B3-2a/2b/2c y batería r1-r3. encargos/b4: B4-1..B4-12 casi todas r1, una r2 (B4-6).
- Ningún registro de stop2 disparado en commits ni docs/evidence. fase15: "ninguna ronda terminó con el mismo bloqueante dos veces seguidas"; carril W llegó a ronda 5.

E. U3b con 5 rondas fue decisión de David y se revirtió:
- 35c0661 / PR #227 (2026-09-29/30), director-corrida-design.md, "## Decisiones de David — Estas decisiones no se vuelven a discutir en la implementación." Fila 9: "Hasta 5 rondas con el mismo implementador; relevo a otro modelo con otras 5; después pregunta a David. Vale también para bloques chicos." Y: "Para las corridas del director, esta decisión de David reemplaza la regla 4 de quality-kit… El operador ya decidió de antemano el relevo a las 5 rondas y la pregunta a las 10."
- 84efcb0 (autor t <t@t>, 2026-09-30 22:57): "Aplica las instrucciones vigentes de quality-kit. No heredes la excepción antigua de rondas del diseño U3b."
- 8358fac/62956cf (t, 2026-10-01 20:50): fila 9 → "Un bloqueante repetido en dos rondas seguidas detiene el bloque para decisión del operador"; RONDAS_AGOTADAS → BLOQUEANTE_REPETIDO.
- a19501c (t, 2026-10-01 21:03): fila 20.1 de Plans.md de "5 rondas por tanda, relevar_impl" a "política quality-kit vigente… paro del mismo bloqueante".
- Sin PR propio; entraron dentro del PR #242 ("Bloque 0", 100 commits, mergedBy gon0801). Sin discusión sobre rondas en los comentarios del #242.

F. El orden:
- 8e2dde0 / PR #234 (Claude, 2026-10-01): "El orden acordado es U3 → U3a → U3b → U4; U3b arranca solo con U3a cerrada al 100% (decisión de David, 2026-09-30)."
- a19501c (t): "La base de encargos durables se integra y verifica antes de U3b y de la integración OpenClaw de U4…". NO atribuida a David. Viajó en el #242.
- Razón técnica: docs/evidence/agent-work/compatibility-u3b-u6.md: "Fase 20.1 y 20.5–20.8 modifican corrida_worker/reconcile.py, corrida/reconciliar.sh, adaptador, avisos y cierre que T8–T9 ya modificaron… Partir del SHA integrado de encargos".
- PR #234 leyes del director (pedido de David 2026-09-30): "nunca push ni merge sin VEREDICTO APROBADO del head", "el revisor nunca es del harness del implementador vigente".

G. SUA sobre su propia política: "Cuatro es un límite inicial propuesto, no una cifra medida ni una orden histórica de David… Mientras falte recibo de adopción rigen las reglas actuales, incluido detener el mismo bloqueante en dos rondas." + "Si la autorización del programa ya cubre ese cambio, se usa sin volver a preguntar." revision.md: "No hay medición que justifique una cifra óptima"; "No hay medición que permita prometer ahorro de tokens o tiempo". El diff de Plans.md borra las dos líneas del orden y pone "orden histórico U3b → flota → U4/U5 → U6 queda sustituido". PR #247: "Implementó Codex."

## Indirect
- Divergencia de copias (apoya a codex): ~/.claude/CLAUDE.md con regla 8 previa a d35ad75; README del kit con texto viejo (residual 5 de Fase 15); PR #83: loop-autopilot §4 "se contradecía a sí mismo". Alternativa: problema de reinstalar, no de reglas malas.
- Problemas de cross-review.ps1 (apoya a codex): 88997fe "la CLI se mataba a mitad… diff de 48 981 no alcanzó ni con 1200 s"; cadena caída o sin cuota (exit 3) en #48 y Fase 9; 4 pruebas del kit fallando desde #10 hasta #18; las revisiones recientes (encargos) las hace Claude en ventana, no cross-review.ps1; gates.py exige cross-review-ok sin pasar por el kit.
- Las reglas ayudaron (en contra): bloqueantes reales atrapados en #242, #245, #247 (bypass con salto de línea). Fase 6: "en los siete carriles, al menos una prueba pasaba igual con el defecto puesto; ningún implementador lo detectó solo". Encargos convergen en 1-3 rondas sin paro. Carril fast −59%.
- CI repetido pese a la regla 3: PR #226 (U3a B2) CI sobre ~10 SHAs en ~19 h; PR #128 "CI ronda 2…24", cerrado sin merge. Costo vino de no seguir la regla (push antes del veredicto).
- Patrón de David de retirar capas de proceso: PR #159 (25-sep) retira hook que bloqueaba merge/push; SummonAI Kit apagado 27-sep (PR #196); PR #207 "compuerta de merge sin kit, decisión David 2026-09-28". Es SaiKit, no quality-kit.
- Autoría: commits que revirtieron 5 rondas y agregaron "encargos antes de U3b" son de t <t@t>, sin trailer, en inglés, estilo de e5cae2d (Codex). Pero t también firma commits de Claude. No se puede afirmar por git que fue Codex.

## Contradictions
1. 5 rondas como decisión de David ("no se vuelve a discutir") vs stop2 impuesto dos días después por t sin decisión de David registrada. SUA v2 (tope + relevo) se parece más al espíritu de David que stop2. revision.md cita 35c0661 pero no dice que era "Decisiones de David".
2. t cambió de postura: impuso stop2 sobre U3b (30-sep/1-oct) y propone sustituirlo (5-oct).
3. Lecturas opuestas del PR #48.
4. PR #81: alta en ronda 6 tras 3 rondas de medias; la regla vigente habría cortado antes.
5. Regla 8 instalada internamente tensa y distinta de la fuente.
6. "U3b solo con U3a al 100%" atribuido a David; "encargos antes de U3b" no.

## Gaps
Sin medición de costo de stop2 ni alternativas; única: ~500k en 4 rondas (07-30) y "100-150k por ronda" sin medición propia. Ningún stop2 disparado. Sin registro de que David aprobó revertir 5 rondas ni ordenó "encargos antes de U3b". Sin cita de David "afecta más de lo que ayuda" en git.

## Leads
Memoria loops-push-solo-tras-aprobado.md: "Hasta 5 rondas por implementador, luego relevo con otras 5, y solo entonces se pregunta a David." Why: U3a B2 CI corrió 4 veces ~40 min por vuelta; David "esta haciendo sus propias reglas". quality-kit-review.md de codex. Transcripciones 2026-09-29/30 y 10-01.
