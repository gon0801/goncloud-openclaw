# seguimiento.v1 — contrato de los mensajes a David

Fecha: 2026-09-18. Estado: activo desde que se mergea (Fase 9, 9.1).

## Para qué

David quiere saber cómo va el proceso, no cómo está hecho. Todo mensaje de seguimiento
de una corrida cumple este contrato, lo mande el latido, el lead o el cierre.

## Forma (v1)

Cuatro líneas, en este orden:

1. `[ETIQUETA] Fase 9, N de M partes terminadas` — el avance como "N de M partes".
2. `Que cambio: ...` — una frase, en palabras de usuario.
3. `Que sigue: ...` — una frase, en palabras de usuario.
4. `Que necesito de ti: ...` — `nada`, o la pregunta en palabras simples con lo que
   implica cada opción; el comando textual solo al final, como referencia.

Etiquetas cerradas: `AVANZA`, `DETENIDA`, `NECESITO TU RESPUESTA`, `CERRADA`.
Cualquier otra etiqueta es rojo. Tope: un `AVANZA` a menos de 15 minutos del anterior se
junta con el siguiente cambio; las otras tres salen siempre de inmediato. Rutina con
`--silent`; `NECESITO TU RESPUESTA` con notificación.

## Lenguaje de usuario (lo que el validador rechaza)

Sin nombres de archivo, comandos, ramas, SHAs, números de PR ni siglas. En concreto es
rojo si el mensaje trae: acento grave (`` ` ``), ruta con `/`, `--flag`, SHA hexadecimal
(7 a 40 dígitos hex), o una palabra de la lista negra: commit, merge, PR, worktree,
branch, CI, hook, script. Ejemplo: se dice "la parte de mensajes quedó integrada y
probada", no "mergeé el PR de M con CI verde".

Ejemplo válido y mutaciones en `scripts/tests/fixtures/corrida/mensaje-*.txt`.
