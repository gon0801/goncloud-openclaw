# T10: matriz de aceptación

## B4-28-r1

Este commit sobre la base `7386298e4f93c31a69258f3c790ff5e3dee4ed66`; R no se usa (su head sigue en `6e3d428bf81c54effa0e06c67726e3a5ce90a24e`).

El problema: `docs/evidence/agent-work/acceptance.md` no existía y `test-agent-work-e2e.sh` no tenía caso `acceptance`. Nada en el repo decía qué escenario de aceptación y qué frontera de caída ya tiene prueba y cuál falta.

Qué hay:

- La matriz `docs/evidence/agent-work/acceptance.md`, con una fila por cada escenario de la tabla de aceptación del spec (A1 a A17), por cada frontera de caída (B1 a B7) y por cada caso que nombra la línea 287 del plan (`T10:review_tail_restart`, `T10:delivery_latency`, `T10:idle_72h`, `T10:resource_100_cycles`, `T10:cien_reenvios`). Cada fila lleva cobertura, pruebas como ``ruta::nombre``, el par G/R (`pendiente` en todas), recibo y nota. La cobertura es juicio del lead con un mapa de citas; este commit la copia, no la decide.
- La prueba `scripts/tests/test_agent_work_acceptance.py` con dos clases. `AcceptanceMatrixTest` es la forma: filas exactamente en el orden del spec con su nombre literal, cobertura en el conjunto cerrado `completa|parcial|falta|fuera-de-bloque`, cada cita resuelta (`def <nombre>(` en un `.py`, etiqueta de caso en un `.sh`), recibo existente como página `docs/evidence/agent-work/*.md`, G y R `pendiente` o SHA de 40, solo `A17` `fuera-de-bloque` con nota `T11:`, y la línea 287 del plan nombrando exactamente los cinco casos. `AcceptanceStrictTest` es el estricto: todo `completa` (salvo `fuera-de-bloque`), un solo par G/R, G commit ancestro de `HEAD` y R commit del checkout que nombra `runtime-map.json`.
- Dos casos nuevos en `test-agent-work-e2e.sh`. `acceptance_matrix` corre la forma; `acceptance` corre forma y estricto. `all` solo corre la forma para que la batería completa de G no exija el par final, que todavía no existe. Los dos nombres entraron en el mensaje de casos disponibles.
- Once filas `| B4-28 |` en `followups.md` con residuales de B4-20 a B4-27. Una es nueva: en una medición, la suite `resource_close` falló y dejó vivo un proceso de la cuenta `agentes`; la causa probable sale de leer el código (la limpieza solo mata los procesos de la foto inicial del nonce) y no está reproducida.

Cobertura de partida. El estricto en rojo (`acceptance is incomplete:`) lista las filas abiertas, literales del log:

> A1 parcial, A2 parcial, A3 parcial, A6 parcial, A8 parcial, A10 parcial, A11 parcial, A13 parcial, B1 parcial, B2 parcial, B3 parcial, B4 parcial, B5 parcial, B6 parcial, B7 parcial, T10:review_tail_restart parcial, T10:delivery_latency parcial, T10:idle_72h parcial, T10:cien_reenvios parcial

`A17` está `fuera-de-bloque` con nota `T11: cutover_fencing (plan :298)` y el estricto la ignora por diseño. La matriz queda con 9 filas `completa` (A4, A5, A7, A9, A12, A14, A15, A16 y T10:resource_100_cycles), 19 `parcial` y 1 `fuera-de-bloque`.

Pruebas, cada una con su comando (`LANG=en_US.UTF-8`, logs en `docs/evidence/agent-work/B4-28-<nombre>.log`):

- Base sin cambios: `bash scripts/tests/test-agent-work-e2e.sh delivery_latency` → `B4-28-base.log`, `OK`, `rc=0`.
- Rojo natural: `bash scripts/tests/test-agent-work-e2e.sh acceptance_matrix` con la prueba aplicada y sin matriz → `B4-28-rojo-natural.log`, `rc=1`, `docs/evidence/agent-work/acceptance.md does not exist`.
- Verde de forma: tras copiar la matriz, el mismo comando → `B4-28-verde.log`, `Ran 2 tests`, `OK`, `rc=0`.
- Estricto en rojo (hoy sale rojo a propósito; es la evidencia de partida de T10): `bash scripts/tests/test-agent-work-e2e.sh acceptance` → `B4-28-estricto-rojo.log`, `rc=1` con la lista de arriba.
- Las 20 mutaciones de `mutar.py`, una a la vez, con los tres archivos respaldados y restaurados, y `git diff` comprobado byte a byte contra `impl.patch` después de cada una (25 restauraciones, todas limpias a la primera). Cada `B4-28-mutacion-<n>.log` guarda `rc=` al final. 19 dan `rc=1` con una sola línea `FAIL:` y el texto esperado; la 12 pone todas las filas `completa` con el par `7386298…`/`6e3d428…` y da `rc=0` `OK` a propósito, para probar que el estricto puede salir verde. Detalle: las mutaciones 13, 14, 19 y 20 corren `acceptance` y prueban el par (doble, G no commit, G no ancestro, R no commit del checkout de R, que se lee solo con `git cat-file`).

Límites, dichos como tales:

- La cobertura es juicio del lead con un mapa de citas, y la prueba no la verifica.
- La prueba ve que la prueba citada existe por texto, no que cubra el escenario.
- El par G/R queda `pendiente` hasta la corrida del par final.
- El estricto comprueba que G es ancestro de `HEAD` y que R existe en su checkout, pero no lee los logs: que los casos de R no se hayan saltado y que `build-info` coincida queda para el encargo del par final.
- `test-runtime.sh` es el ejecutor de G para los casos de R: la cita comprueba que el caso existe en G, no en R.

Suites de regresión (`B4-28-cortas.log`, los cinco `rc=0`):

- `bash scripts/tests/test-candados-declarados.sh` → `TODO VERDE: candados declarados (137 frases, 88 marcas)`, `rc=0`.
- `bash scripts/tests/test-runbooks-no-contradicen-entorno.sh` → `TODO VERDE: runbooks sin contradicciones con el kit ni con el entorno`, `rc=0`.
- `bash scripts/tests/test-agent-work-e2e.sh` sin argumentos → `rc=0`; su última línea es el `OK` de la matriz (`Ran 2 tests`).
- `python3 scripts/tests/test-agent-work-routing.py` → `OK`, `rc=0` (15 pruebas).
- `python3 scripts/tests/test-agent-work-integration.py` → `OK (skipped=1)`, `rc=0` (115 pruebas).

Parte 1 de T10; no marca casillas. Faltan: `review_tail_restart` por la ruta del solicitante agente, las fronteras con contador externo, los cien reenvíos contra el Gateway real, la limpieza de `resource_close`, el par final con las baterías y los PR.
