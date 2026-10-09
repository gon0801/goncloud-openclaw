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

## B4-39-r1: el par final

Dos commits sobre `e72027a2ed58735729fc2ddbb2eb9571253cb6ae`. El commit `7e1b1476c9909a6ef90ea42b164846e248b7253c` tiene el código y es el G del par; el commit siguiente solo trae evidencia. R está en `978355503c44313536ab4cd03a6bfb7a5423404b`, construido en ese mismo SHA y limpio.

Qué cambia en la matriz:

- **A10 pasa a `completa`.** La prueba nueva `test_no_inventory_cli_is_certified_so_no_cli_route_or_claim_opens` recorre el `coverage.json` real: 7 adaptadores en 2 hosts. Comprueba que las 14 rutas CLI se rechazan al rutear (`route <host>/<adapter> is not certified`) y al reclamar (`host adapter route is not certified`), sin llegar al Gateway. Dos mutaciones la ponen roja (`B4-39-a10-mutacion-*.log`):
  - con `mac-local/claude_opus` en `certified` sale `RouteUnavailable not raised`;
  - sin la guarda de `claim_cli_once` sale `an uncertified adapter must not reach the gateway`.
- **A8 y T10:idle_72h pasan a `fuera-de-bloque` con destino T12** (plan `:316`), por decisión de David del 2026-10-09. Una fila fuera del bloque tiene que nombrar una tarea cuya sección del plan contenga su ancla: `out_of_block_problem`.
- **Las guardas de la fila B4-29** (`AcceptanceGuardsTest`, rojo en `B4-39-rojo-guardas.log`):
  - `cites()` solo acepta casos que el runner de shell despacha y métodos `test*`;
  - `REF` rechaza rutas absolutas y rutas con `../`;
  - el estricto lee `acceptance-pair.json`.

  Seis mutaciones, una por guarda, salen rojas (`B4-39-guardas-mutacion-1..6.log`).

La corrida del par (`agent-work-acceptance-pair.py`, también disponible como caso `acceptance_pair`) corrió de 05:41:07Z a 06:29:47Z del 2026-10-09:

- corrió una vez cada una de las 51 pruebas que cita la matriz: los casos de shell por su runner y los métodos de Python uno por uno, con su resultado propio;
- las 51 salieron en verde, sin pruebas de Python saltadas;
- el único salto fue `test_resource_close_real_launchd_label_stays_pending`, que necesita una sesión de login real de `agentes`;
- los logs están en `par-final/` y el resumen en `par-final/corrida.log`.

El estricto (`bash scripts/tests/test-agent-work-e2e.sh acceptance`) sale en verde (`par-final/estricto-verde.log`). Cuatro mutaciones de la corrida lo ponen rojo (`par-final/estricto-mutacion-1..4.log`):

1. una prueba con `rc=1`;
2. una prueba de Python saltada por falta de R;
3. R construido en otro SHA;
4. `idle_72h` sin correr.

Hallazgos del bloque (`:283`):

- Las cuatro filas B4-28 que se cierran escribiendo (latido, candado del inventario, `lanzar-lead.sh` y `avisos atender`) quedan cerradas con rojo, verde y mutación (`B4-39-residuales.md`).
- `test-corrida-nucleo.sh` ya no corre el progress-events de quien lanza la prueba (`B4-39-nucleo-*.log`).
- Los residuales de B4-31 a B4-38 quedan en la tabla de `followups.md`, cada uno con su destino, o como limitaciones en `pr-B4.md`.
- Suites cortas (`B4-39-cortas.log`): las once salen con `rc=0`, incluidas las dos variantes en bash 3.2.

Límites:

- El estricto compara el par contra los commits. Un cambio sin commit en el árbol de trabajo no lo ve: la corrida del par lo registra en `gDirty`, y en esta salió vacío.
- Los saltos de las pruebas de shell solo se cuentan, porque los runners no imprimen el motivo. Las pruebas de shell que necesitan R salen con código 2 si no lo tienen, así que un salto por falta de R no puede pasar como verde.
- La batería completa del bloque y el artefacto nativo (`:284`) son de `B4-bateria`.
