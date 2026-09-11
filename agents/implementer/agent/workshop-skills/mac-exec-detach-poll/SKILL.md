---
name: Mac exec detach poll
description: Cuando un comando largo en el nodo Mac (exec host=node) muere con COMPANION_APP_UNAVAILABLE o queda con desenlace desconocido. Relanza despegado con nohup y vigilalo con comandos cortos.
---

# Mac exec detach poll

En el nodo Mac los comandos exec de minutos (baterias de pytest, builds)
mueren intermitentemente con `COMPANION_APP_UNAVAILABLE` y la salida se
pierde; los comandos cortos siguen pasando. No repitas la corrida a
ciegas.

## Pasos

1. Diagnostica antes de reintentar: `pgrep -fl "<proceso>"` para ver si
   algo sobrevivio. Si vive, vigilalo; no lo relances.
2. Relanza DESPEGADO de la sesion exec, con salida a archivo y el exit
   code registrado al final:

   `nohup sh -c 'PYTHONPATH=. <cmd> > /tmp/<tarea>.log 2>&1; echo "EXIT=$?" >> /tmp/<tarea>.log' >/dev/null 2>&1 & echo lanzada`

3. Vigila con comandos CORTOS (sobreviven a las caidas del companion):

   `tail -3 /tmp/<tarea>.log; pgrep -fl "<proceso>" >/dev/null && echo SIGUE || echo TERMINO`

   Espacia las consultas: la bateria de Orbit (~2100 tests) tarda ~90 s;
   cada encuesta avanza pocos puntos de progreso.
4. El resultado valido es el del log (`EXIT=` + resumen), nunca la sola
   ausencia de proceso. Un EXIT distinto de 0 va al reporte tal cual.

## Criterio de cierre

Log con `EXIT=` registrado y el resumen leido del archivo, o bloqueo
declarado si ni el lanzamiento despegado sobrevive.
