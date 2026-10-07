---
name: seguimiento-tablero
description: Úsala SIEMPRE que David te encargue directo (por Telegram, sin prompt de Claude) algo de más de un paso o de más de ~30 minutos, o cuando arranques a mano un loop o una corrida larga. Antes de empezar lo abres en el tablero, lo marcas en cada paso real y lo cierras al terminar; así el reloj avance-tareas le manda a David un corte corto cada vez que hay novedad (y un latido cada 4 horas), con el título y cuántas partes van, sin gastar tu turno.
---

# Seguimiento en el tablero

El reloj `avance-tareas` corre sin modelo cada 15 minutos. Solo reporta lo que está abierto en el tablero: un trabajo que no registras, David no lo ve avanzar; uno que no cierras, se lo sigue reportando (caso Fase 9: 11 días de avisos de algo muerto).

## Cuándo

- David te pide algo con más de un paso, o que va a tardar más de ~30 minutos.
- Arrancas un loop o una corrida larga a mano.
- No aplica a una respuesta de un solo turno.

## Cómo

Todo corre en la Mac: `exec` con `host="node"` y `node="David's MacBook Pro"`. El script habla con el gateway por el CLI de openclaw y sale distinto de 0 si el gateway no aceptó; lee lo que imprime.

1. **Antes de empezar**, abre el trabajo con un id corto (minúsculas, números y guiones) y una parte por paso grande:
   <!-- candado: test-tablero-trabajo.sh -->
   ```bash
   /Users/dn/bin/tablero-trabajo.sh abrir migrar-correo "Migrar el correo a Fastmail" "Exportar buzones" "Importar en Fastmail" "Cambiar DNS" --siguiente "exportar los buzones de Gmail"
   ```
   Repetirlo con el mismo id no pisa nada: imprime lo que ya hay. Si las partes viven en otro repo que no sea goncloud-openclaw, agrega `--repo owner/repo`.
2. **En cada cambio real** (encargo, entrega, revisión, PR, merge, paro), marca la parte (número o `p1`, `p2`...):
   ```bash
   /Users/dn/bin/tablero-trabajo.sh paso migrar-correo 1 mergeado "buzones exportados, 5 de 5"
   /Users/dn/bin/tablero-trabajo.sh paso migrar-correo 2 implementando "importando 3 de 5 buzones" --siguiente "terminar la importación"
   /Users/dn/bin/tablero-trabajo.sh paso migrar-correo 2 revision-cruzada "PR abierto, en revisión" --pr 231
   /Users/dn/bin/tablero-trabajo.sh paso migrar-correo 3 atorado "el registrador pide 2FA"
   ```
   Estados: `pendiente` (no empieza), `implementando` (trabajando), `revision-cruzada` (en revisión), `en-cola` (lista para merge), `mergeado` (parte terminada: es la única que cuenta en "1 de 3 partes"), `atorado` (parada, di por qué), `omitido` (cancelada, sale de la cuenta). Una parte que aparece a mitad de camino: `tablero-trabajo.sh agregar migrar-correo "Avisar a los contactos"`.
3. **Cuando necesitas a David**, dilo en el tablero; el reloj le manda `[NECESITO TU RESPUESTA]` en el siguiente tick. Cuando responde, suéltalo:
   ```bash
   /Users/dn/bin/tablero-trabajo.sh atencion migrar-correo "Necesito el código 2FA del registrador"
   /Users/dn/bin/tablero-trabajo.sh atencion migrar-correo --resuelta
   ```
4. **Al terminar o abandonar**, ciérralo con una línea; desde ahí el reloj deja de reportarlo:
   ```bash
   /Users/dn/bin/tablero-trabajo.sh cerrar migrar-correo "Correo migrado a Fastmail; DNS apuntando"
   ```
   Para ver cómo está: `tablero-trabajo.sh ver migrar-correo`.

## Reglas

- Mientras trabajas, nunca pases más de 24 horas sin un `paso`: un trabajo quieto se sigue reportando como en curso y David ya no sabe si está vivo.
- No mandes tú el avance periódico: lo manda el reloj. Por Telegram solo eventos: aprobado, merge, paro, pregunta.
- Un trabajo que ya lleva su propio tablero (una corrida con documento de progreso) no se abre otra vez aquí.
- Si el script falla, díselo a David una vez ("no pude registrar X en el tablero") con lo que imprimió, y sigue con el trabajo.
