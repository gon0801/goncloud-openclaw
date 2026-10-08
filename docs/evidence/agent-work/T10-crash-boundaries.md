# T10: fronteras de caída con contador externo

## B4-33-r1

Primera parte de la casilla `:280` del plan (`docs/superpowers/plans/2026-09-30-encargos-agentes.md`,
sección T10): las fronteras B1, B3 y B4 de la tabla "Estados y fronteras de caída" del
spec, verificadas con contadores de peticiones y procesos que viven fuera del Gateway.
**No marca `:280`**: B2, B5, B6 y B7 quedan para la segunda parte.

Este commit sobre la base `b20d91c`, con R `978355503c44` construido. Prueba nueva:
`scripts/tests/test_agent_work_crash_boundaries_e2e.py`, caso `crash_boundaries` del
runner (`bash scripts/tests/test-agent-work-e2e.sh crash_boundaries`, con R como
`AGENT_WORK_RUNTIME_SOURCE`). Verde: 3 casos, 266 s, `OK`.

### Los dos contadores externos

- `CROSS_PROVIDER_LOG`: el arnés (`scripts/tests/fixtures/agent-work/managed-cli-gateway-harness.mjs`)
  agrega cada petición al proveedor en un archivo dado, con el pid del Gateway que la hizo.
- El archivo del doble del CLI (`scripts/tests/fixtures/agent-work/review-cli.py`): con la
  ruta como argumento, agrega ahí cada aceptación (y su arranque, solo como diagnóstico).
  `ReviewCli` acepta argumentos para el doble.

Sobreviven al `kill -9` del Gateway porque viven en procesos ajenos a él (el arnés y el
doble del CLI) y escriben a archivos en disco: matar el Gateway no toca ni los procesos
ni los archivos. El resultado de dominio exigido en los tres casos: una tarea con su
resultado y ningún hijo; una sola aceptación del CLI según su archivo; un solo despertar
del solicitante entre los dos Gateways según el archivo del proveedor; el host sin
resultados pendientes.

### Por frontera

- **B1 (antes de entregar):** el Gateway cae después de registrar la tarea. Un segundo
  despachador manda el mismo pedido al Gateway nuevo y recupera la misma tarea.
  `CRASH_BOUNDARY B1 pids=[4630, 6358] tasks=1 cli_accepted=1 wakes=1 provider_by_gateway=[0, 1]`
- **B3 (entre admitir y recibir respuesta):** el Gateway cae con el CLI ya trabajando.
  Tras reiniciar, el host reclama tres veces y no vuelve a teclear nada; la readmisión
  con la misma clave no crea otra admisión.
  `CRASH_BOUNDARY B3 pids=[10239, 12284] tasks=1 cli_accepted=1 wakes=1 provider_by_gateway=[0, 1]`
- **B4 (entre escribir resultado y ACK):** R registra el resultado y el ACK se pierde.
  El despertar termina, el Gateway cae, y el host repite el mismo reporte al Gateway
  nuevo y recibe el mismo recibo.
  `CRASH_BOUNDARY B4 pids=[16150, 18817] tasks=1 cli_accepted=1 wakes=1 provider_by_gateway=[1, 0]`

(Líneas de la corrida verde `B4-33-verde.log`; los pids cambian en cada corrida.)

### Discriminación rojo → verde

Rojo natural, sin los contadores: el caso B1 (`before_delivery`) falla con
`the requester was never woken` (`rc=1`, 122 s) porque sin `CROSS_PROVIDER_LOG` en el
arnés el archivo del proveedor nunca existe (`B4-33-rojo-natural.log`).

Cinco mutaciones, una a la vez; cada caso falla por el defecto de dominio de su frontera.
La 4 y la 5 son las que caen en los contadores externos (el archivo del CLI y el del
proveedor).

| n | Qué rompe | Filtro | Falla con | Log |
|---|---|---|---|---|
| 1 | R: `register` no recupera la tarea de la misma clave | `before_delivery` | `a second dispatcher could not recover the task` (56 s) | `B4-33-mutacion-1.log` |
| 2 | G: el host vuelve a teclear una asignación cuyo resultado ya existe | `between_admission` | `the restart typed the assignment again` (64 s) | `B4-33-mutacion-2.log` |
| 3 | R: un reporte repetido tras perder el ACK se rechaza como conflicto | `between_result` | `R refused the repeated report` (68 s) | `B4-33-mutacion-3.log` |
| 4 | G: el host vuelve a teclear la asignación ya entregada e informa el estado de antes | `between_admission` | `the CLI was handed the assignment more than once` (91 s) | `B4-33-mutacion-4.log` |
| 5 | R: el reporte repetido vuelve a encolar el despertar del solicitante | `between_result` | `the requester was woken more than once` (90 s) | `B4-33-mutacion-5.log` |

### Límites

- El CLI es un doble en tmux y el modelo contesta `NO_REPLY` sin guion.
- El contador del proveedor vive en el proceso del arnés y escribe a un archivo,
  separado del contador del servicio de R.
- Un despertar o una entrega duplicados se detectan si llegan en los 20 s de espera
  final; con R volviendo a encolar el despertar, llegó a los 7,5 a 7,7 s (medido por
  un lector).
- El contenido del resultado se fija por su digest (el mismo recibo en los dos
  Gateways), no se inspecciona con `managed_tasks_inspect`.
- B2, B5, B6 y B7 quedan para la segunda parte de `:280`.

### Regresión y suites cortas

Regresión con R `978355503c44`, los cuatro casos en verde: `review_tail_restart`
(2 casos, 176 s, `B4-33-reg-review_tail_restart.log`), `cli_gateway` (35 s,
`B4-33-reg-cli_gateway.log`), `main_cli_loop` (2 casos, 76 s,
`B4-33-reg-main_cli_loop.log`) y `review_tail_restart_director` (23 s,
`B4-33-reg-review_tail_restart_director.log`).

Suites cortas sin R (`B4-33-cortas.log`): `test-candados-declarados.sh` y
`test-runbooks-no-contradicen-entorno.sh` con `TODO VERDE`, `test-agent-work-e2e.sh`
con `rc=0` (los casos de R se saltan), ruteo `OK` (15 pruebas) e integración
`OK (skipped=1)` (115 pruebas); cinco `rc=0`. La matriz estricta quedó en
`B4-33-estricto.log`: `acceptance is incomplete` con A2, A3, A6, A8, A10, A11, A13,
B2, B5, B6, B7 y los tres T10; ya sin B1, B3 ni B4.
