---
name: Mac exec detach poll
description: Cuando un comando largo en el nodo Mac (exec host=node) muere con COMPANION_APP_UNAVAILABLE, un binario comun (rg, timeout, uv, gh, corepack) falta en el exec, o un CLI lanzado en tmux muere al instante sin error. Relanza despegado con nohup, vigila con comandos cortos y usa las rutas del PATH restringido.
---

# Mac exec detach poll

En el nodo Mac los comandos exec de minutos (baterias de pytest, builds)
mueren intermitentemente con `COMPANION_APP_UNAVAILABLE` y la salida se
pierde; los comandos cortos siguen pasando. No repitas la corrida a
ciegas.

## Pasos

1. Diagnostica antes de reintentar: `pgrep -fl "<proceso>"` para ver si
   algo sobrevivio. Si vive, vigilalo; no lo relances. Si lo que murió
   era un `git commit`, deja `index.lock` huérfano y el reintento muere
   con `Unable to create ... index.lock`: antes de borrarlo verificá
   que ningún git viva sobre ese worktree y recién ahí borrá el lock
   (medido 2026-09-18: dos reintentos bloqueados por el lock de un
   commit matado por COMPANION_APP_UNAVAILABLE).
2. Relanza DESPEGADO de la sesion exec, con salida a archivo y el exit
   code registrado al final:

   `nohup sh -c 'PYTHONPATH=. <cmd> > /tmp/<tarea>.log 2>&1; echo "EXIT=$?" >> /tmp/<tarea>.log' >/dev/null 2>&1 & echo lanzada`

3. Vigila con comandos CORTOS (sobreviven a las caidas del companion):

   `tail -3 /tmp/<tarea>.log; pgrep -fl "<proceso>" >/dev/null && echo SIGUE || echo TERMINO`

   Espacia las consultas: la bateria de Orbit (~2100 tests) tarda ~90 s;
   cada encuesta avanza pocos puntos de progreso. El espaciado se hace
   ENTRE turnos del agente (una llamada corta por encuesta): nunca metas
   `sleep`/espera DENTRO del comando — `sleep 60; tail ...` muere igual
   con COMPANION_APP_UNAVAILABLE y el resultado queda desconocido
   (medido 2026-09-17).
4. El resultado valido es el del log (`EXIT=` + resumen), nunca la sola
   ausencia de proceso. Un EXIT distinto de 0 va al reporte tal cual.
5. Si el fallo es un binario ausente (`rg`, `timeout`, `uv`, `gh`,
   `python`), un `sed`/`bash` con sintaxis distinta a Linux, o un CLI en
   tmux que muere al instante sin error: el exec del nodo sanea el PATH y **`pathPrepend` se ignora** — anteponé
   `export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH;`
<!-- candado: test-mac-path-regla.sh -->
   o usá la ruta absoluta, y leé ENV.md (misma carpeta) para la tabla de
   ausencias medidas y su reemplazo. Solo esa rama lee ENV.md.

## Criterio de cierre

Log con `EXIT=` registrado y el resumen leido del archivo, o bloqueo
declarado si ni el lanzamiento despegado sobrevive.
