# T10 delivery_latency: latencia de entrega con reloj controlado

Caso del plan T10 (`docs/superpowers/plans/2026-09-30-encargos-agentes.md`): desde la
escritura durable del informe hasta su detección, hasta 5 segundos; desde la detección
hasta el recibo durable, hasta otros 5 segundos. Host despierto y red sana simulados.

## Qué se probó

Ruta real `watch_pump` → `pump_once` → `Host.flush` → `Spool` (`native_gateway.py`,
`host.py`, `spool.py`), sin cambios de producción. La escritura durable es
`atomic_json` al inbox del host (fsync de archivo y directorio); la detección es la
primera llamada a `Host.report` desde el bucle del pump; el recibo durable es el commit
de `Spool.acknowledge` en `host.sqlite`. Un reloj simulado controla el
intervalo de sondeo de 5 s y una respuesta nativa de 0,25 s; el cliente nativo
es un falso en proceso. El informe aparece 0,001 s después del primer sondeo,
para medir el peor caso del siguiente ciclo sin esperar tiempo real.

Comando: `bash scripts/tests/test-agent-work-e2e.sh delivery_latency`
(prueba: `ProjectionTransferTest.test_delivery_latency_acceptance_records_both_legs`
en `scripts/tests/test-agent-work-integration.py`).

## Mediciones (misma corrida verde, por separado)

- escritura durable → detección: **4,999 s simulados** (límite 5 s)
- detección → recibo persistido: **0,25 s simulados** (límite 5 s)

La prueba imprime ambas en una línea `DELIVERY_LATENCY {...}` y además verifica que el
recibo quedó persistido de forma durable (`Host.receipt` no nulo) antes de medir.

## Discriminación rojo → verde

Rojo reproducible: `AGENT_WORK_TEST_ACK_DELAY_SECONDS=6 bash
scripts/tests/test-agent-work-e2e.sh delivery_latency` adelanta el reloj simulado
seis segundos antes de persistir el recibo. La prueba falla solo en el tramo dos:
`detection_to_persisted_receipt_s: 6.25` > 5 mientras
`write_to_detection_s: 4.999` sigue en verde. El comando sale con código 1;
`T10-delivery-latency-red.log` guarda la salida. Sin esa variable, vuelve a verde.

Batería focalizada: `ProjectionTransferTest` completa, 23/23 en verde.

## Limitación precisa

La sondeada instalada NO está probada: la aceptación conduce `watch_pump` en proceso
con un reloj simulado y un cliente nativo falso. No ejercita el vigilante instalado
(launchd/systemd con el intervalo por defecto de 1.0 s), el transporte real
`openclaw gateway call` ni el runtime R real; los límites de 5 s valen para la ruta de
código bajo host despierto y red sana simulados. El tramo de detección está acotado
por el intervalo de sondeo (`watch_pump` exige `interval <= 5`), pero
el intervalo instalado real y el costo del transporte Gateway quedan fuera de esta
prueba. El caso entró en G con `9a18540` y el reloj simulado con `4687b0b`.
SHA de R: no aplica — el lado nativo está simulado por el cliente falso.

## B4-38-r1: reloj real contra el Gateway de R

Este commit va sobre la base `2058a11`, con R `978355503c44` construido. Cubre lo que la
sección de arriba deja fuera: el transporte real `openclaw gateway call` y el runtime R real.

Prueba: `scripts/tests/test_agent_work_delivery_latency_e2e.py`, caso `delivery_latency_r` de
`bash scripts/tests/test-agent-work-e2e.sh`. Arranca el Gateway real de R aislado (el de
`crash_boundaries`), registra y admite una tarea y corre el bucle de producción `watch_pump` con
su sondeo por defecto de 1 s en un hilo. El doble del CLI recibe la asignación y escribe su
resultado. Mide con el reloj real:

- escritura: la hora de modificación del archivo de resultado. El doble escribe y renombra sin
  fsync, así que el tramo 1 queda del lado conservador;
- detección: la primera llamada a `Host.report` del bucle, como en la sección de arriba;
- recibo: el commit de `Spool.acknowledge`, como en la sección de arriba.

Exige cada tramo en 5 s o menos. Línea del verde (`B4-38-verde.log`):

```
DELIVERY_LATENCY_R {"write_to_detection_seconds": 0.016, "detection_to_receipt_seconds": 1.212, "limit_seconds": 5}
```

En otras corridas el tramo 1 dio entre 0,02 y 1,55 s (depende de en qué punto de la espera cae
la escritura) y el tramo 2 entre 1,1 y 1,4 s.

No hay rojo natural: el comportamiento ya existía. El rojo lo dan dos mutaciones del host de G:

| Mutación | Qué rompe | Falla con | Log |
|---|---|---|---|
| 1 | el host no ve un resultado hasta que tiene 6 s | `detection took longer than 5 s` | `B4-38-mutacion-1.log` |
| 2 | el reporte al Gateway tarda 6 s más | `the durable receipt took longer than 5 s` | `B4-38-mutacion-2.log` |

Límites:

- La corrida con R no demuestra el peor caso: un bucle que se salta búsquedas (por ejemplo, un
  `flush` o un `collect` en una de cada cuatro pasadas) no lo detecta esta prueba. El peor caso
  del sondeo de diseño lo fija el caso con reloj controlado de arriba. Así lo decidió David
  (opción A del ATORADO de la preparación de B4-38, 2026-10-09).
- El bucle de la prueba corre sin `cli_claim` ni `cli_watch`; el `--watch` de producción sí los
  usa. Un lector midió una pasada que reclama y entrega en unos 4,3 s, así que el peor caso real,
  si la escritura coincide con otra entrega, puede pasar de 5 s.
- Host despierto, red local y el Gateway en la misma Mac; no se prueba un host remoto ni una red
  lenta. Cada reporte lanza el CLI de openclaw, y es la mayor parte del tramo 2.
- La línea "SHA de R: no aplica" de arriba vale para el caso con reloj controlado; este caso sí
  usa R, en `978355503c44`.

No marca `:282`: siguen parciales A8, A10 y T10:idle_72h.

Regresión con R: `cli_gateway` en `OK`, `rc=0` (`B4-38-reg-cli_gateway.log`). Suites cortas sin
R: los dos `TODO VERDE`, el runner sin R con `rc=0` (los casos de R se saltan), ruteo `OK` e
integración `OK (skipped=1)`, cinco `rc=0` (`B4-38-cortas.log`). La matriz estricta queda con A8,
A10 y T10:idle_72h (`B4-38-estricto.log`).
