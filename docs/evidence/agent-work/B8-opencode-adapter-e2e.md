# B8: certificación de `mac-local/opencode` (GLM) en una sesión adoptada

Corrida en vivo de `scripts/tests/test_agent_work_opencode_adapter_e2e.py` el 2026-10-10. El Gateway es R `4b9785c` (build limpio) dentro del arnés. El host, `TmuxTransport`, `ResourceManager` y el pump son los de producción, sobre un servidor tmux propio. El CLI es `opencode 1.18.35` con `-m zai-coding-plan/glm-5.3-flash`. El único doble es el modelo del solicitante.

Qué prueba la corrida:

- `main` (sesión `agent:main:encargos-loop`) envía y admite dos encargos a `mac-local/opencode`, uno tras otro, a la misma sesión adoptada.
- Con texto del operador en el composer, el reclamo queda `deferred` y el host no teclea nada. Al borrarlo, el host teclea una vez por encargo y solo sobre un composer `VACIO`.
- GLM escribe `agent-work.accept.v1` en `acceptRef`. El host lo valida y marca la entrega `delivered`.
- GLM escribe `cert-N.txt` y un `agent-work.result.v1` `produced`. El digest coincide con los bytes esperados, y el Gateway guarda `evidenceContentHash` igual a ese SHA-256.
- Cada resultado despierta solo a `agent:main:encargos-loop`. El encargo se resuelve (`handled`), la sesión queda `ReleasedAdopted` y opencode sigue vivo.
- No hay incidentes: ni `invalid-result`, ni `delivery-unaccepted`, ni `permission-required`.

Comando:

```
LANG=en_US.UTF-8 AGENT_WORK_OPENCODE_LIVE=1 \
AGENT_WORK_RUNTIME_SOURCE=<checkout de R construido> \
python3 scripts/tests/test_agent_work_opencode_adapter_e2e.py -v
```

Corridas:

- Corrida 1, roja: `B8-opencode-run1-rojo.log`. Entrega, composer y aceptación salieron bien. GLM adivinó la forma del resultado (`status`, `payload`, `artifacts`) y el host lo rechazó con `result schema or kind mismatch` (`invalid-result`). La asignación no decía qué campos lleva `result.v1`. Arreglo: el host escribe `protocol` en toda asignación de CLI, con el `accept` exacto, el `result` base y los tres campos que el CLI llena (`host.py`, `cli_protocol`).
- Corrida 2, verde: `B8-opencode-run2-verde.log`.
- Corrida 3, verde, sobre el código final (comprobación de digest más estricta). Es la evidencia de la certificación:

```
test_main_loop_hands_tasks_to_an_adopted_opencode_session (__main__.OpencodeAdapterE2E.test_main_loop_hands_tasks_to_an_adopted_opencode_session) ... OPENCODE_E2E t=  25.4s gateway=ws://127.0.0.1:54000 socket=agent-work-opencode-70958-b4eeb4d4 model=zai-coding-plan/glm-5.3-flash workspace=/private/var/folders/hp/sc_3c6qs7nvdswl_x3w5sdbr0000gn/T/agent-work-opencode-_wsw1l4t/workspace
OPENCODE_E2E t=  27.8s opencode composer VACIO
OPENCODE_E2E t=  27.8s task 1 submitted and admitted taskId=bd6d8623-9031-4904-ae83-06ba5fe28440
OPENCODE_E2E t=  32.3s draft in the composer: claim deferred, nothing typed
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
OPENCODE_E2E t=  75.9s task 1 accepted and reported receipt=4ea804d3118b993c168e8028f2a5592190cbe1f076715bb1a225cdffc14690c6
{"claimed": 0, "closed": 0, "detected": 0, "incidents": 0, "reported": 1, "transferred": 0}
OPENCODE_E2E t=  80.5s task 1 gateway result={"artifactRef": "artifact:686879e4d129f80ca5d9d5f8f699278555942376e286788fb1d3a6ad89f3a26e", "digest": "sha256:10406a9fb400b29bab71919e991435b3cb3cb1be72b7d72499a26b99997bfa50", "evidenceContentHash": "686879e4d129f80ca5d9d5f8f699278555942376e286788fb1d3a6ad89f3a26e", "kind": "produced", "observedRevision": {"kind": "code", "repository": "opencode-cert", "sha": "cccccccccccccccccccccccccccccccccccccccc"}, "payload": {"evidenceRef": "cert-1.txt"}}
OPENCODE_E2E t=  80.5s task 1 woke agent:main:encargos-loop, handled, session released and kept
OPENCODE_E2E t=  80.5s task 2 submitted and admitted taskId=e6426ea5-beac-4103-93db-01cf88a0834f
{"claimed": 1, "closed": 1, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 1, "closed": 0, "detected": 0, "incidents": 0, "reported": 0, "transferred": 0}
{"claimed": 0, "closed": 0, "detected": 0, "incidents": 0, "reported": 1, "transferred": 0}
OPENCODE_E2E t= 112.5s task 2 accepted and reported receipt=1e6652341d3ba8b2bc33a97fef94fbcd90e32b10c0de9f441ccd09d70fc81be4
OPENCODE_E2E t= 112.5s task 2 gateway result={"artifactRef": "artifact:8ad7e46cb18973c9c5adc7ab8d94ec13c69492dc5293dec043a2f3a00e1f6354", "digest": "sha256:5cc94b38117173ca886cd46d86718a8b0dbaf18b6909f549589f8d9425bf90c9", "evidenceContentHash": "8ad7e46cb18973c9c5adc7ab8d94ec13c69492dc5293dec043a2f3a00e1f6354", "kind": "produced", "observedRevision": {"kind": "code", "repository": "opencode-cert", "sha": "cccccccccccccccccccccccccccccccccccccccc"}, "payload": {"evidenceRef": "cert-2.txt"}}
OPENCODE_E2E t= 112.6s task 2 woke agent:main:encargos-loop, handled, session released and kept
OPENCODE_E2E t= 112.6s OPENCODE_ADAPTER_E2E tasks=2 typed=2 deferred_over_draft=1 incidents=0 sessions=['agent:main:encargos-loop'] claims=34
ok

----------------------------------------------------------------------
Ran 1 test in 112.776s

OK
```

Corrida 4, verde, sobre B8-r2 (2026-10-10): el host fija el pane de `opencode.exe` y juzga el composer sin mirar el color. Mismo comando, R en el mismo checkout construido. Log completo: `B8-r2-opencode-adapter-e2e.log`.

```
OPENCODE_E2E t=  32.9s draft in the composer: claim deferred, nothing typed
OPENCODE_E2E t= 112.4s OPENCODE_ADAPTER_E2E tasks=2 typed=2 deferred_over_draft=1 incidents=0 sessions=['agent:main:encargos-loop'] claims=33
Ran 1 test in 112.573s
OK
```
