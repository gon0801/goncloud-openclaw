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
