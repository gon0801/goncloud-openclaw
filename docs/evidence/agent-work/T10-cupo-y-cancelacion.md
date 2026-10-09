# T10: cupo del host y cancelación con dos despachadores

## B4-37-r1

Primera parte de la casilla `:282` del plan (`docs/superpowers/plans/2026-09-30-encargos-agentes.md`,
sección T10): las filas A6, A11 y A13 de la matriz de aceptación
(`docs/evidence/agent-work/acceptance.md`) pasan a `completa`. **No marca `:282`**:
siguen parciales A8, A10, T10:delivery_latency y T10:idle_72h.

Este commit sobre la base `52eecbe`, con R `978355503c44` construido.

### A6: dos despachadores, cancelación y callback viejo

Prueba nueva `scripts/tests/test_agent_work_dispatchers_cancel_e2e.py`, caso
`dispatchers_cancel` del runner (`bash scripts/tests/test-agent-work-e2e.sh
dispatchers_cancel`, con R como `AGENT_WORK_RUNTIME_SOURCE`). Usa el Gateway real de R,
el host y los contadores externos de `crash_boundaries`. Sin rojo natural: el
comportamiento ya existe en G y R; el rojo de esta prueba lo dan las tres mutaciones de R
de abajo. Los pasos:

1. Dos despachadores registran el mismo pedido y obtienen la misma tarea.
2. El CLI hace el trabajo.
3. Uno cancela.
4. El Gateway muere con `kill -9`.

En el Gateway nuevo, el otro despachador, que no vio la cancelación, intenta readmitir
con su propia clave (`dispatcher-2-admission`). R lo rechaza con `Managed task is not
awaiting an agent result`. R tiene tres guardas contra la readmisión: la herramienta, el
almacén y una sola admisión por tarea. La prueba exige que el rechazo sea por
cancelación. Además, en el Gateway nuevo: tres reclamos del host no reciben nada, el
resultado tardío del host queda archivado como cancelado, y una continuación sobre la
tarea cancelada se rechaza con `Managed task is cancelled`.

Resultado final exigido: una tarea, ningún manejo ni hijo, una sola entrega al CLI y
cero despertares. Línea de la corrida verde (`B4-37-verde.log`, 84 s):

```
DISPATCHERS_CANCEL pids=[31154, 32481] tasks=1 handling=cancelled children=0 cli_accepted=1 wakes=0
```

Tres mutaciones de R, una a la vez; cada una vuelve a verde al deshacerla.

| n | Qué rompe | Falla con | Log |
|---|---|---|---|
| 1 | R: un segundo despachador con el mismo pedido no recupera la tarea | `the second dispatcher could not recover the task` | `B4-37-mutacion-1.log` |
| 2 | R: sin las dos guardas de cancelación de la admisión (herramienta y almacén). La tercera, una sola admisión por tarea, rechaza igual pero por otra causa; la prueba exige que el rechazo sea por cancelación | `already has an admission claim` | `B4-37-mutacion-2.log` |
| 3 | R: el host vuelve a recibir una tarea cancelada | `the host was offered the cancelled task again` | `B4-37-mutacion-3.log` |

### A11: caída entre reserva y lanzamiento, host dormido o inaccesible

Prueba nueva con dobles
`test_resource_close_crash_between_reserve_and_launch_with_host_unreachable_keeps_capacity`
(`scripts/tests/test-agent-work-resources.py`): reserva y lanzamiento empezado, el host
no responde y el gestor reinicia. Exige `CleanupPending` por `host unavailable` y que la
reserva de reemplazo se rechace por capacidad. Su mutación 5 de G (ver tabla) la mantiene
roja al aplicar el defecto. La respaldan `test_resource_close_pending_holds_host_capacity_and_pool_is_separate`,
`test_resource_close_reservation_crash_stop_failure_and_detached_child` y los casos B2 de
`crash_boundaries` (recibo `T10-crash-boundaries.md`, encargo B4-35).

### A13: stop falla y luego se recupera

Prueba nueva con dobles
`test_resource_close_session_gone_with_a_surviving_descendant_still_holds`
(`scripts/tests/test-agent-work-resources.py`): después de un stop fallido, la sesión
desaparece pero sobrevive un descendiente. Exige que siga `CleanupPending` con el cupo,
y que solo con `ps` vacío pase a `AbsenceVerified`. Su mutación 4 de G la mantiene roja
al aplicar el defecto. La respaldan
`test_resource_close_agentes_stop_failed_holds_without_signals_until_retried` y
`test_resource_close_reservation_crash_stop_failure_and_detached_child`.

Las cuatro pruebas de dobles juntas: `Ran 2 tests`, `OK`, `rc=0` con los filtros
`host_unreachable_keeps_capacity` y `surviving_descendant` (`B4-37-dobles.log`).

Mutaciones 4 y 5 sobre `scripts/agent-work/resources.py` de G, una a la vez; cada una
vuelve a verde al deshacerla.

| n | Qué rompe | Filtro | Falla con | Log |
|---|---|---|---|---|
| 4 | G: una sesión que desapareció libera el cupo aunque sobreviva un descendiente | `surviving_descendant` | `the session vanished but a descendant survived` | `B4-37-mutacion-4.log` |
| 5 | G: un lanzamiento sin identidad con el host inaccesible libera el cupo | `host_unreachable_keeps_capacity` | `('CleanupPending', 'host unavailable')` | `B4-37-mutacion-5.log` |

### Corrida real de `resource_close`

`bash scripts/tests/test-agent-work-host.sh resource_close` bajo la cuenta `agentes`
(`sudo -n -u agentes`, sin contraseña): `OK (skipped=1)`, `rc=0`
(`B4-37-resource-close.log`). Incluye las dos pruebas nuevas. Así salió también las tres
veces que la corrió David el 2026-10-08. La falla de la fila B4-28 de `followups.md` está
resuelta en G `97717e1`, en "Resueltos fuera del loop (resource_close)". Cuenta `agentes`
antes y después de la suite (`ps -o pid=,command= -U agentes`), solo `xpcproxy`:

```
62340 xpcproxy com.apple.distnoted.xpc.agent
62342 xpcproxy com.apple.lsd
69070 xpcproxy com.apple.metadata.mdbulkimport
```

### Regresión y suites cortas

Regresión con R: `bash scripts/tests/test-agent-work-e2e.sh cli_gateway`, `OK`, `rc=0`
(`B4-37-reg-cli_gateway.log`). Suites cortas sin R (`B4-37-cortas.log`): candados
declarados y runbooks `TODO VERDE`; `test-agent-work-e2e.sh` con los casos de R saltados,
`rc=0`; ruteo `Ran 15 tests`, `OK`; integración `Ran 115 tests`, `OK (skipped=1)`;
cinco `rc=0`.

### Límites

- En A6 el modelo contesta `NO_REPLY`, y el orden "cancelar, caer, readmitir y resultado
  tardío" es uno de varios posibles.
- A11 y A13 se miden con dobles y con el backend `agentes`.
- Host dormido: medido solo por un lector como host que no responde (`close` bloqueado,
  cupo retenido), sin prueba en la suite y sin timeout en `TmuxBackend._tmux`.
- El no reemplazo del lado de R se apoya en `managed-task.host-closure.test.ts` de R y en
  el error `Managed host assignment is bound to another instance`, que no se corren aquí.
- La fila B4-28 sigue en la tabla de pendientes de `followups.md` aunque "Resueltos fuera
  del loop" la resuelve; no se toca `followups.md` y queda para el cierre de T10.

## B4-40-r1

Residual de B4-37 que solo pedia G, con R fijo, en este commit.
`TMUX_TIMEOUT_SECONDS = 30` en `TmuxBackend._tmux` (el vencimiento sale como
`OSError` a CleanupPending `host unavailable`) y prueba nueva de host colgado
con un tmux falso que no responde: `close` vuelve en 30 s en CleanupPending y
retiene el cupo. Verde en la corrida del par (`resource_close`, 33 pruebas OK
con el unico salto launchd declarado). Mutaciones: sin timeout cuelga (matado
por `timeout 75`, EXIT=124); tragar el vencimiento como exito vacio da otro
motivo y sale rojo. El limite "Host dormido ... sin prueba en la suite y sin
timeout en `TmuxBackend._tmux`" queda cubierto.
