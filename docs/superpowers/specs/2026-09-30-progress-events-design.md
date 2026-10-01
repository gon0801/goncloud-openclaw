# Progreso durable por ronda para todos los tableros nuevos

## Decisión

El gateway es la autoridad del progreso visible. `runbook.progress.event` acepta
operaciones tipadas con ID estable y asigna una revisión por corrida. Una
proyección `runbook-progress.v1` alimenta `get`, las rutas HTTP, el HTML y los
resúmenes existentes. La Mac conserva sus hechos de ejecución y reintenta la
publicación con los mismos IDs; su registro no es la autoridad de los tableros
manuales ni de otros hosts.

Las escrituras `runbook.progress.set` siguen leyendo y escribiendo tableros
históricos. En cuanto una corrida se importa o abre por eventos, `set` no puede
sobrescribirla. Las corridas nuevas tienen identidad propia; compartir una fase
no comparte el archivo canónico. La ruta por fase queda para los tableros
históricos.

## Contrato de uso

```text
event(run.opened, id estable, corrida, documento inicial validado,
      presupuesto de rondas por carril)
event(round.started, carril, intento, número, SHA base)
event(round.ready, carril, intento, número, SHA entregado, evidencia LISTO)
event(round.verdict, carril, intento, número, SHA revisado,
      aprobado|cambios, evidencia VEREDICTO)
event(part.status, carril, estado, evidencia de entrega cuando corresponda)
event(attention.changed, estado y motivo)
event(run.closed, resumen)
get(corrida) -> documento derivado y revisión
events.get(corrida) -> historial paginado
```

`run.opened` declara el alcance y el presupuesto de revisiones. El porcentaje
visual es una **estimación de avance**: un carril mergeado vale 100; un carril
activo vale la fracción de rondas cerradas sobre las estimadas, limitada a 99
antes del merge. El porcentaje global promedia los ítems elegibles de la cola,
como hoy. Si falta un presupuesto, el avance de ese carril es desconocido. Un
veredicto sólo cierra la ronda cuyo SHA revisó; LISTO, silencio de tmux y
notificaciones no la cierran. Cada evento conserva su evidencia y procedencia.
El porcentaje de los avisos sigue contando tareas verificadas o carriles
mergeados, y no trata revisiones como trabajo entregado.

La autoridad valida ID, corrida, carril, intento, ronda, SHA y evidencia en el
límite RPC. La misma operación reenviada devuelve la misma revisión; el mismo
ID con otro contenido se rechaza. Una transición que depende del estado exige
la revisión esperada. El escritor vuelve a leer y decide ante un conflicto. El
registro y la proyección se escriben con reemplazo atómico; el registro se
confirma antes de responder `ok:true` y una proyección rezagada se reconstruye
desde él. El bloqueo es por corrida, no global.

`estado.md` y el JSON local se generan desde la proyección recibida, con la
revisión y hora de sincronización. Una publicación sin respuesta queda en la
cola local y se reintenta sin crear otro ID. Los archivos LISTO y VEREDICTO se
escriben de forma durable antes de comunicar el evento, con referencia y hash;
una transcripción histórica se marca como tal.

## Alternativas y síntesis

Se comparó hacer autoridad al registro local `corrida.v2`. Su escritura
atómica y deduplicación son buenas para hechos de ejecución, pero obligaría a
tableros manuales y futuros hosts a pasar por esa Mac o a mantener dos
autoridades. Se eligió el gateway común. Del diseño local se conserva el
reintento derivado de hechos ya persistidos y un cursor de publicación; no se
crea una segunda verdad para el porcentaje.

La migración importa cada corrida histórica una sola vez desde un documento
validado, marca la nueva propiedad y deja el resto en su ruta anterior. U3a se
importa con evidencia identificada; su sincronizador específico se retira
cuando la lectura real del gateway confirma el estado y la cifra nuevos.

## Verificación

La prueba debe cubrir identificadores arbitrarios, B1/B2 mergeados y B3 r1,
dos cierres sucesivos de B3, revisión del SHA equivocado, eventos duplicados y
fuera de orden, dos escritores en una corrida, dos corridas de la misma fase,
reinicio entre registro y proyección, y red caída con reintento. HTML, JSON,
resumen y archivo local deben reflejar la misma revisión. Las pruebas del
aviso de 30 minutos siguen comprobando su porcentaje de entrega independiente.
