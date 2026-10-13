# Síntesis del why (sintetizador opus, 2026-10-06), con niveles de confianza

Pregunta: por qué existen las reglas de calidad y el orden actual, y si las recomendaciones de Claude o los cambios de codex en SUA funcionarán mejor, punto por punto. Hipótesis de David: "quality kit afecta más de lo que ayuda; codex dejó lo importante y quitó lo que no sirve".

## Veredictos

| Punto | Veredicto | Confianza |
|---|---|---|
| (a) "quality-kit afecta más de lo que ayuda" | Cierto para la **coordinación**: `cross-review.ps1` sale en 0 aunque haya BLOQUEANTE y recorta el diff, el bloque de reglas está copiado en 39 archivos con 8 versiones, la regla 4 se reescribió 6 veces y stop2 interrumpe a David. Falso para los **mecanismos**: hooks, batería una vez en CI, shards, carril fast (−59 %, 422 s → 174 s) y revisión independiente con reproducción, que atrapó defectos reales. Gran parte del dolor de David vino de SaiKit (P9330), de la batería de R mal acotada (P9943) y de hacer push antes del veredicto (P9590, P9146, P9205, P9247), que la regla 3 ya prohibía. "Codex dejó lo importante" se sostiene en general. | Media-alta |
| (b) stop2 vs v2 vs 5+5 | stop2 es la que peor encaja. No es la última decisión de David: el "seguro" de las 2 repeticiones apareció en 3f17ed5, 75 s después de P8713, que pedía rondas "indefinidas", y no hay prompt de David con esa regla (Inferido). La 5+5 la dictó David en P9580 (35c0661/PR #227, fila 9, "no se vuelven a discutir") y la revirtió `t` en 8358fac/a19501c sin registro de decisión. v2 se parece más a la 5+5 (tope + relevo, sin preguntar en cada repetición), pero el 4 no está medido y es más estricto. En encargos ninguna de las tres habría cambiado nada: 32 VEREDICTO, nada pasó de r3 y 0 `REPETIDO: sí`. | Media |
| (c) "SUA cambia tu decisión del 30-sep (encargos antes de U3b)" | **Falsa.** La decisión del 30-sep fue "U3a al 100% antes de U3b" (P9636) y SUA la conserva. "Encargos antes de U3b" la escribió `t` en a19501c/84efcb0 sin atribuírsela a David, y Claude la aplicó el 2-oct (obs #61041). Lo que SUA sí cambia de David: la fila 9 (5+5) y las decisiones #2, #5 y #10 del 29-sep. | Alta |
| (d) B4 antes de SUA-01 | **B4 primero: sostenido con fuerza.** 12 archivos de R compartidos, la regla del plan de encargos `:67` (no paralelizar escritores sobre `R.taskStore`), una base G sin los commits de B4 y un conflicto seguro en el plan de encargos. **B5 primero: debilitado, no tumbado.** El gate viejo de U3b pedía B1-B4 (`u3b-loop/estado.md:3`); T11-T12 se traslapan con SUA-09, pero SUA no hereda de forma explícita la ventana de 30 min sin inferencia, la plantilla prompt-claw sin `<loop>-vigia` ni `limits.json`. SUA-00 en paralelo es viable si parte del head G de B4. | Alta (B4), baja-media (B5) |
| (e) Activación como decisión explícita de David | Sostenida. David no quiere aprobar pasos (P8095, P9591), pero dicta él cada política de rondas (P8031, P8682, P8705, P8709, P8713, P9580 y el tope 3 de U3a) y se molesta cuando un agente "hace sus propias reglas". Su 5+5 ya fue sustituida una vez bajo un mandato genérico. Ajuste: **una sola decisión global** que fije el número, no un recibo por repo/host. La línea de SUA "mientras falte recibo rige stop2" le impondría stop2 a encargos, que corre con la 5+5. | Media-alta |
| (f) Primer entregable solo OpenClaw | Sostenida débilmente. SUA ya permite aceptar OpenClaw primero (D:62), el orden viejo era U4 antes que U5 y H no está inventariado. Mejor ajuste: definir el primer entregable por un resultado que David vea, la promesa de Telegram de 20.10 que SUA perdió ("Telegram" aparece 0 veces en D, P y C). | Baja-media |

## Preserve / Change / Avoid / Risk

**Preserve**
- Los mecanismos que v2 conserva: hooks sin `--no-verify`, regresión por bug, batería una vez por SHA en CI, shards que cubren la unión, carril fast por archivos, revisión independiente y "un bloqueante nunca va al plan ni se mergea abierto".
- La dependencia de SUA en "U3a cerrada" (la decisión real de David, P9636).
- La regla del plan de encargos `:67`: no paralelizar escritores sobre `R.taskStore` ni `R.scheduler`.
- El "diagnóstico independiente" ante un bloqueante repetido. En F0, la repetición señaló que hacía falta rediseñar.
- La aceptación OpenClaw separada de la de Hermes (D:62).

**Change**
- Cerrar B4 antes de SUA-01. SUA-00 en paralelo, rebasado sobre el head G de B4.
- B5: decisión de David entre terminarlo o heredar sus obligaciones como filas explícitas.
- Quitar "si la autorización del programa ya cubre ese cambio". La adopción es una sola decisión global de David que fija el número. Nombrar la 5+5 como política vigente de los loops de claw.
- Definir el primer entregable por la promesa de Telegram.
- Corregir "ni una orden histórica de David": la 5+5 sí lo fue.

**Avoid**
- Venderle a David que v2 o SUA ahorran tiempo o tokens: el propio SUA dice que no hay medición (D:66, revision.md:56).
- Que un agente sustituya una decisión de David en un commit de "alineación" sin registro.
- Culpar al texto de las reglas del costo de la batería de R o del push antes del veredicto.
- Arrancar SUA-01 con B4 abierto, o editar el plan de encargos desde flota-poteto mientras B4 marca casillas.

**Risk**
- v2 suaviza "sin reproducción no bloquea" a "evidencia estática verificable": puede haber más rondas por bloqueantes débiles.
- v2 deja de rotar al revisor por ritual. La falta de rotación se culpó de las 14 rondas del #48.
- Con un tope de 4, el caso #81 (una alta en la ronda 6) quedaría detenido.
- Si David dice "sí, v2" sin fijar el número, el 4 entra como si fuera decisión suya.
- Hermes en paralelo compite por el cupo de 4 sesiones y por la cuota de bots.

## Avance desde el análisis (estado al 2026-10-06)

- B4-14-r1 (G1b: cliente de incidencias en la bomba) está APROBADO, G 82f26f4.
- B4-15-r1 (G2a: detectores de sesión cerrada, plazo e informe inválido; `delivery_clock`; `cli_watch` en la bomba) está APROBADO, G e655060.
- B4-16-r1 (G2b: diálogo de permiso con episodios durables) está en diseño.
- Queda en B4:
  - G2c: el caso `cli_silent_failure` en el runner, el E2E y la casilla `:268`;
  - `:269` `cli_delivery_acceptance`, `:264`, `:265` y `:266`;
  - 7 casillas de T10;
  - la batería.
- B5 (T11-T12, instalación y corte) está pendiente.
