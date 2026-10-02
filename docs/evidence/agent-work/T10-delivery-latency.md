# T10 delivery_latency: latencia de entrega con reloj controlado

Caso del plan T10 (`docs/superpowers/plans/2026-09-30-encargos-agentes.md`): desde la
escritura durable del informe hasta su detección, hasta 5 segundos; desde la detección
hasta el recibo durable, hasta otros 5 segundos. Host despierto y red sana simulados.

## Qué se probó

Ruta real `watch_pump` → `pump_once` → `Host.flush` → `Spool` (`native_gateway.py`,
`host.py`, `spool.py`), sin cambios de producción. La escritura durable es
`atomic_json` al inbox del host (fsync de archivo y directorio); la detección es la
primera llamada a `Host.report` desde el bucle del pump; el recibo durable es el commit
de `Spool.acknowledge` en `host.sqlite`. El cliente nativo es un falso en proceso
(respuesta inmediata = red sana); el pump corre con `interval=0.05`.

Comando: `bash scripts/tests/test-agent-work-e2e.sh delivery_latency`
(prueba: `ProjectionTransferTest.test_delivery_latency_acceptance_records_both_legs`
en `scripts/tests/test-agent-work-integration.py`).

## Mediciones (misma corrida verde, por separado)

- escritura durable → detección: **0.005 s** (límite 5 s)
- detección → recibo persistido: **0.003 s** (límite 5 s)

La prueba imprime ambas en una línea `DELIVERY_LATENCY {...}` y además verifica que el
recibo quedó persistido de forma durable (`Host.receipt` no nulo) antes de medir.

## Discriminación rojo → verde

Rojo: se añadió localmente `time.sleep(6)` al inicio de `Spool.acknowledge`
(producción, sin commitear) para demorar la persistencia del recibo. La prueba falló
solo en el tramo dos: `detection_to_persisted_receipt_s: 6.008` > 5 mientras
`write_to_detection_s: 0.004` siguió en verde — los dos tramos se miden por separado.
Log completo: `T10-delivery-latency-red.log`. Se restauró `spool.py`
(`git checkout`, diff de producción limpio) y la prueba volvió a verde.

Batería focalizada: `ProjectionTransferTest` completa, 23/23 en verde.

## Limitación precisa

La sondeada instalada NO está probada: la aceptación conduce `watch_pump` en proceso
con `interval=0.05` y un cliente nativo falso. No ejercita el vigilante instalado
(launchd/systemd con el intervalo por defecto de 1.0 s), el transporte real
`openclaw gateway call` ni el runtime R real; los límites de 5 s valen para la ruta de
código bajo host despierto y red sana simulados. El tramo de detección está acotado
estructuralmente por el intervalo de sondeo (`watch_pump` exige `interval <= 5`), pero
el intervalo instalado real y el costo del transporte Gateway quedan fuera de esta
prueba. SHA de G: el commit que introduce este archivo (hijo de `cecf243`). SHA de R:
no aplica — el lado nativo está simulado por el cliente falso.
