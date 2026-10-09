# T10: cien reenvíos contra el Gateway real

## B4-36-r1

Recibo de la fila `A2` y de `T10:cien_reenvios` de `acceptance.md`, que pasan de `parcial`
("los 100 reportes pasan solo por Host.report con un runtime falso") a `completa`. Corrido en
este commit sobre la base `3a805fb`, con R `978355503c44` construido
(`AGENT_WORK_RUNTIME_SOURCE` apunta a R; el Gateway real es el de `crash_boundaries`).

Qué hace la prueba (`scripts/tests/test_agent_work_cien_reenvios_e2e.py`, caso
`cien_reenvios` del runner): el host reporta el mismo resultado cien veces y pierde el ACK en
99. Son 50 reportes con el ACK perdido a un Gateway que después muere con `kill -9`, después
de que su despertar se asienta, y 49 más con el ACK perdido y uno final con ACK a otro
Gateway sobre el mismo estado. La prueba cuenta los reportes por debajo del cliente, en cada
llamada `managedTasks.host.report` que termina bien, usando los contadores externos que ya
usa `crash_boundaries`.

Qué exige: los cien reportes llegan al Gateway, el mismo recibo las cien veces, una tarea con
su resultado, una sola entrega al CLI, un solo despertar del solicitante según el archivo del
proveedor, y el host sin pendientes. Las dos líneas del verde
(`B4-36-verde.log`; los pids cambian en cada corrida):

```
CIEN_REENVIOS reports=100 receipts=1 wakes=1 provider_requests=1 sent=100 pids=[<gw1>, <gw2>]
CRASH_BOUNDARY A2 pids=[<gw1>, <gw2>] tasks=1 cli_accepted=1 wakes=1 provider_by_gateway=[1, 0]
```

No hay rojo natural: el comportamiento ya existía en R, y la prueba lo fija contra el Gateway
real. El rojo lo dan las tres mutaciones:

| Mutación | Qué rompe | Texto del rojo | Log |
|---|---|---|---|
| 1 (R) | un reporte repetido se rechaza como conflicto | `R refused a repeated report` | `B4-36-mutacion-1.log` |
| 2 (R) | un reporte repetido vuelve a encolar el despertar del solicitante; lo caza el contador externo del proveedor | `the requester was woken more than once` | `B4-36-mutacion-2.log` |
| 3 (G) | el cliente del host guarda el recibo y no vuelve a llamar al Gateway; lo caza el conteo de llamadas | `a repeated report never reached the Gateway` | `B4-36-mutacion-3.log` |

Límites de lo que prueba:

- El CLI es un doble en tmux y el modelo contesta `NO_REPLY`, así que nunca hay hijos ni
  admisiones: "los mismos hijos" de A2 queda en cero y lo cubre solo el contador de
  despertares.
- El mismo recibo no discrimina: R lo deriva del digest del resultado. Con R reprocesando
  cada reporte repetido (sin el `return` del resultado ya registrado en
  `managed-task.worker.ts`), la prueba sigue verde, porque el `insertOnly` de la cola no
  vuelve a despertar (medido por un lector, 189 s).
- El resultado es siempre el mismo, así que no se prueba la comprobación de conflicto de R ni
  reportes distintos para la misma tarea.
- Cada reporte lanza el CLI de openclaw, unos 1,5 s por reporte.

Regresión con R: el caso `cli_gateway` sigue en verde (`B4-36-reg-cli_gateway.log`, `OK`,
`rc=0`). Suites cortas sin R: candados declarados, runbooks sin contradicciones, el runner
sin R (los casos de R se saltan), ruteo e integración; cinco `rc=0`
(`B4-36-cortas.log`). La base de la ronda, `delivery_latency`, también en verde
(`B4-36-base.log`); la matriz en estricto deja solo los siete parciales que no cubre este
commit (`B4-36-estricto.log`).

No marca `:282`: quedan parciales A6, A8, A10, A11, A13, T10:delivery_latency y
T10:idle_72h.

## B4-40-r1

Residual de B4-36 que solo pedia G, con R fijo, en este commit. Prueba nueva
`test_a_report_with_the_same_id_and_another_digest_is_rejected`: tras el ACK,
un reporte con el mismo id y otro digest sale rechazado, el recibo original no
cambia (`resultReceipt` intacto) y el rechazado no despierta (un solo
despertar; verde 59 s, `B4-40-digest-verde.log` en `.saikit/scratch/B4-40-r1/`,
mas la corrida del par). El limite "no se prueba la comprobacion de conflicto
de R ni reportes distintos" queda cubierto; el transporte de G envuelve el
rechazo en `native projection Gateway rejected request`.
