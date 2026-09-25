# seguimiento.v1 — contrato de los mensajes a David

Fecha: 2026-09-18. Última revisión: 2026-09-25 (Fase 9, 9.2: nombre de la
corrida, aviso de apertura, práctica sin preguntas). Estado: activo desde que
se mergea.

## Para qué

David quiere saber cómo va el proceso, no cómo está hecho, y quiere poder decir
de un vistazo DE QUÉ corrida es cada mensaje — llegan mezclados con los de
otros proyectos en el mismo chat. Todo mensaje de seguimiento de una corrida
cumple este contrato, lo mande el latido, el lead, la apertura o el cierre.

## Forma (v1)

Cuatro líneas, en este orden, con estos prefijos literales (un mensaje que no
los traiga es rojo):

1. `[ETIQUETA] <Nombre de la corrida> (abrió HH:MM), N de M partes terminadas`
   — el nombre es el título del runbook registrado, o el identificador de la
   corrida si no hay título (o si el título trae jerga: ver más abajo); la
   hora es la de apertura, en la hora local de quien la abrió. El avance va
   como "N de M partes". En `CERRADA` basta un cierre en palabras: ya no
   queda nada que contar. En `ABIERTA`, si todavía no se sabe cuántas partes
   tiene, se omite SOLO ese pedazo (la coma y el conteo): la línea 1 queda
   `[ABIERTA] <Nombre> (abrió HH:MM)`, la hora de apertura se conserva
   siempre; nunca se inventa un número ni se dice "desconocido" donde antes
   había datos. Fuera de esos dos casos, cuando el avance no se puede
   expresar honestamente con un conteo, la línea 1 admite el literal
   `avance desconocido` en lugar del conteo.
   Toda la línea 1 lleva además un prefijo, antes del `[ETIQUETA]`: `▶️ ` en
   una corrida real, `🧪 PRÁCTICA — no contestes ` en una corrida de práctica
   (`simulacro:true` en el registro).
2. `Qué cambió: ...` — una frase, en palabras de usuario.
3. `Qué sigue: ...` — una frase, en palabras de usuario.
4. `Qué necesito de ti: ...` — `nada`, o la pregunta en palabras simples con lo
   que implica cada opción.

(Los prefijos sin acento — `Que cambio:`, `Que sigue:`, `Que necesito de ti:`
— también pasan el validador, por si queda algún mensaje viejo grabado; lo que
emite `corrida_mensaje` ya sale siempre acentuado.)

Etiquetas cerradas: `ABIERTA`, `AVANZA`, `DETENIDA`, `NECESITO TU RESPUESTA`,
`CERRADA`. Cualquier otra etiqueta es rojo. Tope: un `AVANZA` a menos de
15 minutos del anterior se junta con el siguiente cambio; las otras cuatro
salen siempre de inmediato. Rutina (`ABIERTA`, `CERRADA`) con `--silent`;
`DETENIDA` y `NECESITO TU RESPUESTA` con notificación.

### `NECESITO TU RESPUESTA`: el texto es fijo, no lo decide el llamador

Las líneas 2 y 4 de `NECESITO TU RESPUESTA` las fija `corrida_mensaje`, sin
importar qué le haya pasado el llamador (`responder.sh`, `latido.sh`...):

- Corrida real: `Qué cambió: Una parte de la corrida quedó esperando que
  decidas algo.` y la línea 4 trae la pregunta de sí/no con su
  `Comando: ...` de referencia.
- Corrida de práctica: `Qué cambió: Una parte de la prueba llegó a una
  pregunta de práctica.` y `Qué necesito de ti: nada: es una prueba, se
  resuelve sola` — sin `Comando: `, porque no hay nada que aprobar.

### El comando textual y el marcador `Comando: `

La línea 4 puede terminar con UN comando textual de referencia, tras el marcador
literal `Comando: ` — por ejemplo `... decir si o no a X; Comando: ~/bin/corrida.sh
responder --sesion s --si`. El marcador existe para que la máquina distinga el comando
del resto del mensaje: las líneas 2-3 y el cuerpo de la línea 4 se validan como
lenguaje de usuario, y el único segmento tras `Comando: ` queda exento de esa
validación. El marcador solo se permite en `NECESITO TU RESPUESTA` de una corrida
real; en las demás etiquetas, en una corrida de práctica, repetido, o con el
segmento vacío, es rojo.

## Lenguaje de usuario (lo que el validador rechaza)

Sin nombres de archivo, comandos, ramas, SHAs, números de PR ni siglas. Es
rojo si el **cuerpo** del mensaje (líneas 2 a 4) trae: acento grave (`` ` ``),
ruta con `/`, `--flag`, `#123`, SHA hexadecimal (7 a 64 dígitos hex, con al
menos un dígito y una letra), o una palabra de la lista negra: commit, merge,
PR, pull request, rebase, push, repo, rama, worktree, branch, CI, hook, script
— con sus plurales y participios. Ejemplo: se dice "la parte de mensajes
quedó integrada y probada", no "mergeé el PR de M con CI verde".

La línea 1 (el nombre de la corrida) **no** se revisa con este mismo
validador: el título de un runbook no lo controla quien manda el mensaje, así
que un título como "Autopilot de la Fase 15 — CI completa" no puede tumbar
todos los mensajes de esa corrida. La sanidad de la línea 1 se resuelve antes,
en `corrida_encabezado`: si el título trae algo de la lista de arriba, cae al
identificador de la corrida en vez de usarlo.

Ejemplo válido y mutaciones en `scripts/tests/fixtures/corrida/mensaje-*.txt`.
