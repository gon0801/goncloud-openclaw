# B4-40-r1: notas de la ronda

Base: G `4c0a11ec` (rama `encargos/b4-40-r1`, worktree limpio), R
`978355503c44313536ab4cd03a6bfb7a5423404b` fijo, construido (buildstamp
coincide con HEAD de R; R queda sin cambios al final).

Cobertura dictada: residuales de followups.md que se cierran solo en G.

## 1. B4-34a: B5 y B7 reclaman tres veces mas

`test_between_decision_and_its_receipt_the_restart_recovers_the_same_child`
(B5) reclama la correccion tres veces mas tras el primer exito antes de la
espera final: las tres devuelven `uncertain` (el reinicio no vuelve a teclear)
y la asercion del archivo del CLI deja una sola revision y una sola correccion
(`B4-40-b5-verde.log`, OK 103 s).

`test_a_cancellation_then_a_late_result_wakes_nobody` (B7) reclama tres veces
mas tras archivar el tardio: las tres devuelven `None` (nada ofrecido) y el
archivo del CLI deja una sola entrega (`B4-40-b7-verde.log`, OK 83 s).

Mutacion del doble (review-cli.py entrega dos veces): ambos casos en rojo
(ver tabla y `B4-40-mutacion-doble-b5.log` / `B4-40-mutacion-doble-b7.log`).

## 2. B4-34b: cancelar y reportar a la vez (B7 con carga)

`test_cancel_and_report_at_once_keep_a_single_terminal_state`: barrera de dos
hilos contra el Gateway vivo de R; cancelacion confirmada y reporte tomado
(`cancel=True receipts=1`, cero errores), un solo estado terminal
(`handling=cancelled delivery=result-recorded`), cero despertares tras cancelar
y tardio archivado. Dos corridas en verde (`B4-40-race-verde.log`,
`B4-40-race-verde-2.log`, ~53 s cada una). Sin rojo: no se toca R.

## 3. B4-36: mismo id, otro digest

`test_a_report_with_the_same_id_and_another_digest_is_rejected`: el host
reporta, recibe ACK, y un segundo reporte con otro payload sale rechazado por
R (el transporte de G lo envuelve en `native projection Gateway rejected
request`); el recibo original no cambia (`resultReceipt` intacto) y el
rechazado no despierta (un solo despertar, `B4-40-digest-verde.log`, OK 59 s).
Sin rojo: no se toca R.

## 4. B4-37: timeout en TmuxBackend._tmux y host colgado

`TMUX_TIMEOUT_SECONDS = 30` en `TmuxBackend._tmux`: el vencimiento sale como
`OSError` y los caminos de `close`/`attach` ya lo llevan a CleanupPending
(`host unavailable`). Prueba nueva
`test_resource_close_hung_host_close_times_out_and_holds_capacity` con un
tmux falso que no responde: `close` vuelve en 30 s en CleanupPending y el cupo
queda retenido (`B4-40-hung-verde`, dentro de `B4-40-resource-close-v.log`;
corrida directa OK 30 s).

## 5. Residual VEREDICTO-B4-39: pair_problems y el salto launchd

`test-agent-work-host.sh` corre `resource_close` con `-v`, el corredor del par
guarda el motivo de cada salto `.sh`, y `pair_problems` rechaza todo salto
`.sh` salvo el declarado
(`test_resource_close_real_launchd_label_stays_pending`, firma `user/502
Background-only`). Prueba nueva en `AcceptanceGuardsTest`
(`test_a_shell_skip_must_be_the_declared_launchd_skip`; guardas 9 OK) mas
mutacion (ver tabla).

## Tabla de mutaciones

| n | Punto | Que rompe | Falla con | Log |
|---|---|---|---|---|
| 1 | B4-37 (G) | sin `timeout=` en `_tmux` | el caso cuelga; matado por `timeout 75` (EXIT=124) | `B4-40-mutacion-hung-1-sin-timeout.log` |
| 2 | B4-37 (G) | el vencimiento se traga como exito vacio | `('CleanupPending', 'launch outcome uncertain')` | `B4-40-mutacion-hung-2-timeout-tragado.log` |
| 3 | B4-39 (G) | `shell_skip_allowed` siempre falso | 3 rojos en guardas (el par declarado incluido) | `B4-40-mutacion-guardas-sin-excepcion.log` |
| 4 | B4-34a (doble) | el doble entrega dos veces | B5: `the CLI did not get the review and one correction` | `B4-40-mutacion-doble-b5.log` |
| 5 | B4-34a (doble) | el doble entrega dos veces | B7: `the CLI was handed the assignment more than once` | `B4-40-mutacion-doble-b7.log` |
