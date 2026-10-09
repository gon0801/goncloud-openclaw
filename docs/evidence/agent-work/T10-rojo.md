# T10: los casos en rojo antes de corregir

Recibo de la casilla `:281` del plan (`docs/superpowers/plans/2026-09-30-encargos-agentes.md`):
"Ejecuta los casos en rojo antes de corregir cualquier fallo de integración."

Cada caso de T10 corrió primero en rojo, con su log en `docs/evidence/agent-work/`, y solo
después pasó a verde en el commit que se cita. El rojo natural es la prueba nueva contra el
código de antes. Cuando el comportamiento ya existía y no hubo nada que corregir, el rojo lo
dan las mutaciones, que se citan en su lugar. `idle_72h` y `resource_100_cycles` no son de T10:
vienen de T5 y T7 (recibos `T5.md` y `T7.md`), y T10 solo los enlaza en la matriz.

## Por caso

| Caso de T10 | Commit en verde | Rojo antes de verde | Qué estaba rojo |
|---|---|---|---|
| `acceptance` (la matriz) | `c5a4c6a` | `B4-28-rojo-natural.log`; `B4-28-estricto-rojo.log` | La matriz `acceptance.md` no existía; después, el modo estricto rechaza filas parciales |
| `delivery_latency` | `9a18540` | `T10-delivery-latency-red.log` | Con `AGENT_WORK_TEST_ACK_DELAY_SECONDS=6`, el tramo hasta el recibo pasa de 5 s (retraso inyectado por variable de prueba, no código de antes: `T10-delivery-latency.md:32`) |
| `review_tail_restart`, el solicitante corrige solo | `e40fe4a` | `B4-29-rojo-natural.log` | El arnés no daba el pid del Gateway, así que la prueba no podía reiniciarlo |
| `review_tail_restart`, veredicto fuera del tail | `ad78d36` | `B4-30-rojo-natural.log` | Con el arnés de B4-29, cuyo guion no admite el hijo, la corrección nunca se reclama |
| `review_tail_restart`, despertar en vuelo | `b20d91c` | `B4-32-rojo-natural.log` | Con R sin el arreglo de B4-31, el solicitante nunca resuelve |
| `crash_boundaries` B1, B3 y B4 | `3297a0c` | `B4-33-rojo-natural.log` (B1); `B4-33-mutacion-2.log` y `B4-33-mutacion-4.log` (B3); `B4-33-mutacion-3.log` y `B4-33-mutacion-5.log` (B4) | B1: sin los contadores externos, el solicitante nunca aparece despertado; B3 y B4: el rojo natural solo corrió B1, así que su rojo son las mutaciones del host y de R |
| `crash_boundaries` B5 y B7 | `e4415d8` | `B4-34-rojo-natural.log` | Sin el arnés nuevo: B7 no puede cancelar y B5 no vuelve a decidir |
| `crash_boundaries` B2 y B6 | `3a805fb` | `B4-35-rojo-natural.log`; `B4-35-revisor-mutacion-1.log`, `B4-35-revisor-mutacion-2.log`, `B4-35-revisor-mutacion-3.log` y `B4-35-revisor-mutacion-4.log` | Sin el host como proceso, el host nunca llega a su parada; las cuatro mutaciones del host las corrió el revisor sobre `3a805fb` |
| `cien_reenvios` | el commit de B4-36-r1 | `B4-36-mutacion-1.log`; `B4-36-mutacion-2.log`; `B4-36-mutacion-3.log` | Comportamiento que ya existía: rojo por mutación (en R, el reporte repetido rechazado y el despertar encolado otra vez; en el host, el cliente que no vuelve a llamar al Gateway) |

## Fallos de integración corregidos en el bloque

- **El despertar en vuelo que R no volvía a entregar.** Lo encontró la ronda B4-30: con el
  Gateway caído y el turno del despertar en vuelo, la corrección nunca llegaba (fila B4-30
  de `followups.md`). La prueba de R salió en rojo antes del arreglo (`B4-31-rojo-natural.log`,
  `retryCount` 0 donde se espera 1), y el arreglo es R `978355503c44`, anotado en G `9000813`. La prueba de
  punta a punta lo confirma en `B4-32-rojo-natural.log`: el rojo con R sin el arreglo.
- **La limpieza de `resource_close`.** Dejaba vivo un proceso de `agentes` (fila B4-28 de
  `followups.md`). El arreglo es G `97717e1`. Su prueba con dobles,
  `test_resource_close_cleanup_kills_nonce_processes_born_after_the_snapshot`, sale roja con
  la limpieza anterior. Ese rojo lo midieron el autor y el revisor de VEREDICTO-B4-30-r1, pero
  su log no entró al repo; es el único rojo de este recibo sin log en `docs/evidence`.

Marca `:281`.
