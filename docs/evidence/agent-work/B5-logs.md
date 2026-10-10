# Logs del cierre de B5

Corridas posteriores al par de la matriz, sobre G `dd527cc` y R `f1c5f34`. Van en este documento porque, después del par, la guarda de `test_agent_work_acceptance.py` solo deja cambiar documentos `.md` de evidencia.

## T11-f1c5f34-fencing.log

`cutover_fencing` sobre el artefacto `f1c5f34`.

```
test_adoption_keeps_the_cli_session_and_delivers_a_result_captured_across_it (__main__.CutoverFencingE2E.test_adoption_keeps_the_cli_session_and_delivers_a_result_captured_across_it) ... ok
test_an_in_flight_turn_is_drained_then_the_old_cron_never_asks_again (__main__.CutoverFencingE2E.test_an_in_flight_turn_is_drained_then_the_old_cron_never_asks_again) ... ok
test_an_interrupted_transfer_resumes_without_suspending_again (__main__.CutoverFencingE2E.test_an_interrupted_transfer_resumes_without_suspending_again) ... ok
test_an_uncertain_admission_blocks_the_transfer (__main__.CutoverFencingE2E.test_an_uncertain_admission_blocks_the_transfer) ... ok
test_two_emitters_never_transfer (__main__.CutoverFencingE2E.test_two_emitters_never_transfer) ... ok
test_unknown_limits_refuse_before_any_cron_is_touched (__main__.CutoverFencingE2E.test_unknown_limits_refuse_before_any_cron_is_touched) ... ok

----------------------------------------------------------------------
Ran 6 tests in 191.010s

OK
```

## T11-f1c5f34-rollback.log

`cutover_rollback` sobre el artefacto `f1c5f34`.

```
test_a_bad_snapshot_keeps_the_candidate_running_with_admission_frozen (__main__.CutoverRollbackE2E.test_a_bad_snapshot_keeps_the_candidate_running_with_admission_frozen) ... ok
test_a_previous_binary_that_does_not_start_leaves_the_candidate_frozen_on_the_snapshot (__main__.CutoverRollbackE2E.test_a_previous_binary_that_does_not_start_leaves_the_candidate_frozen_on_the_snapshot) ... ok
test_a_rollback_interrupted_before_stopping_leaves_the_candidate_frozen (__main__.CutoverRollbackE2E.test_a_rollback_interrupted_before_stopping_leaves_the_candidate_frozen) ... ok
test_an_interrupted_rollback_resumes_without_reviving_the_old_cron (__main__.CutoverRollbackE2E.test_an_interrupted_rollback_resumes_without_reviving_the_old_cron) ... ok
test_rollback_returns_the_previous_binary_on_the_snapshot_and_keeps_the_old_cron_suspended (__main__.CutoverRollbackE2E.test_rollback_returns_the_previous_binary_on_the_snapshot_and_keeps_the_old_cron_suspended) ... ok

----------------------------------------------------------------------
Ran 5 tests in 400.469s

OK
```

## T11-T12-sombra.log

`verificar-medida-sombra.py` en la copia de la Mini.

```
{"faithful": true, "pairs": [[39555, 39555], [54632, 54632]], "bySession": {"operaciones:agent:operaciones:subagent:47833b28-3be2-4d42-a685-d050035e8809": {"rc": 0, "requests": 1, "maxBytes": 39555, "error": null}, "main:agent:main:telegram:default:direct:6470689715": {"rc": 0, "requests": 1, "maxBytes": 54632, "error": null}}, "ensayo": "/var/folders/hp/sc_3c6qs7nvdswl_x3w5sdbr0000gn/T/ensayo-gateway-lvbqsokq"}
rc=0 34s
```
