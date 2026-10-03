# B2: triage base-vs-diff de los 5 fallos nuevos de la bateria R

Triage pendiente del cierre B2 (run a41d1381 que nunca volvio): los 5 fallos nuevos
frente a B1 (4 casos UI en 3 ficheros + 1 timeout de backup-create) se re-corrieron en
aislado, un shard por corrida, sobre la base `c074824a27` y sobre el head `5b14e9e563a`.
Fecha: 2026-10-03. Host local: macOS (darwin, arm64). No es CI. Sin push en R (nunca hay).

Metodo (una sola corrida por celda, sin reintentos)
- Base UI: `cd /tmp/triage-b2-base && node scripts/run-vitest.mjs run
  ui/src/components/provider-usage.test.ts ui/src/pages/chat/chat-composer-context.test.ts
  ui/src/pages/usage/view.test.ts` -> Test Files 3 passed (3), Tests 48 passed (48), EXIT=0
  (log `/tmp/triage-base-ui.log`).
- Head UI: mismo comando en `/Users/dn/dev/openclaw-agent-work-integration` (@5b14e9e) ->
  Test Files 3 passed (3), Tests 48 passed (48), EXIT=0 (log `/tmp/triage-head-ui.log`).
- Base backup: `node scripts/run-vitest.mjs run src/infra/backup-create.test.ts` en base ->
  passed 1 shard en 26.01s, EXIT=0 (log `/tmp/triage-base-backup.log`).
- Head backup: mismo en head -> passed 1 shard en 25.21s, EXIT=0
  (log `/tmp/triage-head-backup.log`).
- G: `bash scripts/tests/test-clasificador-cambio.sh` -> TODO VERDE; `bash
  scripts/tests/test-doc-check-evidencia.sh` -> OK (22 archivos en el rango);
  `bash scripts/clasificar-cambio.sh --base origin/main --head HEAD` ->
  carril=completo (esperado: 22 archivos, logs de evidencia + 1 script).

Resultados
- UI (provider-usage x2 incl. `JP¥13` vs `¥13`, chat-composer-context, usage/view):
  VERDE en base y en head en aislado con `en_US.UTF-8` o sin LANG (48/48 los dos, 3
  ficheros); con el LANG por defecto del host (`en_CA.UTF-8`) fallan SIEMPRE, en base y
  en head (seccion B2-2-r1 abajo). Causa: locale, limitacion del host y de la base, no
  carga ni orden. No es regresion del diff R 2046bd95 -> 5b14e9e (el diff de B2 toca 13
  ficheros).
- backup-create (timeout 120 s en bateria, `private agent DB=true`): VERDE en base (26 s)
  y en head (25 s) en aislado; el timeout es de carga, no del diff. Espurio.
- Los otros 8 de la bateria coinciden 1:1 con la fila B1/bateria de followups.md
  (ya registrados, sin corregir donde hubo comparable).
- La bateria quedo INCOMPLETA por aborto propio del runner (~571/700 shards sin arrancar);
  la ausencia de un fichero en el inventario no es un pase.

B2-2-r1 (revisor, causa UI = locale)
- Con el entorno por defecto del host (`LANG=en_CA.UTF-8`) los 4 casos de UI fallan
  SIEMPRE, en base `c074824a27` y en head `5b14e9e563a` (exit 1: `b22-base-ui.log`,
  `b22-head-ui.log`).
- Con `en_US.UTF-8` y sin LANG pasan 48/48 en los dos (exit 0: `b22-*-ui-en_US.UTF-8.log`,
  `b22-*-ui-unset.log`).
- Clasificacion corregida: limitacion del host y de la base por locale, no carga ni orden.
- El diff R de B2 (2046bd95 -> 5b14e9e) toca 13 ficheros.
- Evidencia completa: `~/.local/state/encargos-loop/artifacts/B2-2-r1-revisor/`.

Decision
- Correccion de codigo NO procede (ni en R ni en G): los 4 fallos de UI son limitacion
  del host y de la base por locale, y el timeout de backup-create es de carga.
- Va a followups.md como fila B2/bateria (limitacion de bateria local + flakies
  documentados). El cierre B2 sigue: respaldo R, ledger, push+PR, CI, revisor, merge.
- G clasificador y doc-check verdes en local; si CI los pone rojos, es re-run (ajeno),
  no ronda (salvo bloqueante reproducible del diff).
