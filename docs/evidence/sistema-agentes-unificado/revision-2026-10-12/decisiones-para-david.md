# Decisiones para David sobre el plan SUA

Solo lo que la matriz no puede cerrar. Cada punto empieza con mi recomendación.

## 1. Política de rondas: cómo se activa

**Recomiendo una sola decisión tuya, escrita una vez: la regla 4 de quality-kit como base en todos lados, con tu 5+5 como tope (5 rondas por implementador, relevo a otro modelo con otras 5, y después te preguntan). El v2 de 4 ciclos de codex no se activa.** Hoy conviven tres reglas. La regla 4 de `~/.claude/CLAUDE.md:66-67` no tiene tope, ni paro por bloqueante repetido, ni rotación de revisor, y `CLAUDE.md:92` dice que las rondas siguen solo esa regla. Los loops de claw usan tu 5+5 (`prompt-claw` SKILL.md:59), que dictaste el 2026-09-29 (PR #227, fila 9). El repo G sigue aplicando stop2 y rotación (`loop-autopilot.md:112`; `bloqueante-repetido` y `mismo-revisor` en `gates.py`). Ese stop2 entró en `8358fac` sin decisión tuya registrada. El "4" de codex no está medido. En el loop de encargos hay 81 veredictos: 62 en r1, 15 en r2, 1 en r3 y ninguno más arriba, así que ningún tope entre 3 y 5+5 habría cambiado nada. Lo que sí cuesta es tener tres textos. Si decides esto, el corregido ya lo deja listo: SUA-05 implementa tu regla como datos y retira de G stop2 y la rotación de revisor. Si prefieres otro número, basta con decirlo una vez; ninguna autorización genérica del programa lo cambia.

## 2. ¿SUA-00 corre en paralelo con los seguimientos de encargos (B18)?

**Recomiendo que sí, en solo lectura, y que SUA-01 espere a que B18-R esté mergeado o cerrado.** SUA-00 solo lee G y R y escribe documentos y fixtures nuevos en G (`docs/spec/sistema-agentes.v1.md`, `scripts/tests/fixtures/sistema-agentes/`). B18-G toca el host (`TmuxBackend.stop`, `--close-only`, colas muertas) y B18-R toca `src/agents/tasks/managed-tasks-tool.ts` en R (residuales 3 a 5 de B11, `followups.md:39`; `estado.md:614`). Ninguno de los dos escribe lo que escribe SUA-00. SUA-01 sí choca: reescribe archivos de `src/agents/tasks/`, y el plan de encargos (`:67`) prohíbe dos escritores en paralelo sobre `R.taskStore`. El costo de correr en paralelo es chico: cuando B18 se mergee, SUA-00 relee los archivos que B18 cambió y actualiza su inventario. La alternativa, esperar a B18, no compra nada, porque el inventario se tendría que releer igual antes de SUA-01.

## 3. ¿Apruebas el orden SUA?

**Recomiendo aprobar solo SUA-00 ahora y decidir el orden completo con su inventario en la mano.** No hay registro de que hayas aprobado el orden SUA; pediste diseño (`architecture-task.md`, según explorer B). El orden vigente en main sigue siendo U3 → U3a → base de encargos → U3b → U4 → U5 → U6, y tu decisión real del 2026-09-30 fue "U3b solo con U3a al 100%" (P9636), que SUA conserva. Lo que SUA cambia de tus decisiones del 2026-09-29: la #2 (el decisor pasa de `corrida.sh` a R), la #5 (confirmar plan por tamaño pasa a depender de la autoridad), la #9 (rondas, punto 1) y la #10 ("repo nuevo siempre pregunta" pasa a "sin autoridad"). SUA-00 va a contestar dos cosas que pueden mover SUA-01 y SUA-02: si `SessionGoal`/`/goal` de R se reutiliza, y cómo queda `coverage.json`. Aprobar el orden antes de eso es aprobar a ciegas.

## 4. El PR #247

**Recomiendo cerrarlo y sacar antes su arreglo de argv a un PR chico contra main.** El PR #247 (draft, cabeza `e5cae2d`) trae la Fase F, que SUA reemplaza, y además un arreglo real. `_check_argv_element` rechaza caracteres de control (`registry.py:148` en `e5cae2d`), con su prueba `test-worker-model-binding.sh`. Main no tiene ninguna de las dos: en `6e01ec0`, `registry.py:143-154` solo rechaza operadores de shell. Ese arreglo vale sin SUA. Si el PR se cierra sin rescatarlo, el defecto `--model\nwrong` sigue abierto en main hasta SUA-03. Si prefieres redefinir el PR en vez de cerrarlo, que quede solo con ese arreglo y su prueba.

## Lo que ya no hace falta decidir

B5 (T11 y T12) ya no es una decisión. Lo terminó el loop de encargos y el plan cerró al 100% el 2026-10-11 (PR #266, `deploy-receipt.md`). El corregido dice que SUA no lo absorbe ni lo repite.

## Lo que David contestó

- Punto 1 (rondas), 2026-10-12: regla 4 de quality-kit con tope 5+5. La propuesta de cuatro ciclos queda inactiva.
- Punto 2 (SUA-00 y B18), 2026-10-12: SUA-00 espera a que cierre B18 en G y en R. B18 cerró ese mismo día.
- Punto 3 (orden SUA), 2026-10-13: "1. sí solo SUA-00". Aprueba solo SUA-00.
- Punto 4 (PR #247), 2026-10-12: se cierra después de rescatar su arreglo de argv en un PR aparte. Hecho.
- Quién hace SUA-00, 2026-10-13: "2. claude y glm". Claude implementa y GLM revisa.
