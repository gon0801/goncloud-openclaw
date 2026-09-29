# Canary integral Etapa 4 (14.7), 2026-09-29

Resultado: **canary vivo observado y aprobado**. La corrida `canary-e4-0102` recorrió la ruta nativa completa: solicitud, selector, carril, harness, revisión cruzada, PR, CI, revisor, merge autorizado, deploy desde `origin/main` y observación viva. No hizo falta reversa.

## Cambio (payload)

`scripts/mac/corrida/preflight.sh` ya no lanza las filas de `cli-modos.tsv` cuyo binario salió de `workers.v1.json` (`cursor-agent` y `muse`). Esas filas quedan en `QUEDA unknown` como `fila legacy fuera del registro: <cli>`. F2 no cambia para los seleccionables.

## Cronología y evidencia

- **Base instalada.** Deploy de origin/main c125c76 con `instalar-mac.sh`, y `--verificar` dijo `instalacion sana`. Después el lead reinstaló en eaea55b.
- **Apertura.** `corrida.sh abrir canary-e4-0102 --runbook docs/runbooks/native-harness-rollout.md --vigia claw --cli-modos ~/bin/cli-modos.tsv` respondió `abierta canary-e4-0102` a las 01:02.
- **Preflight antes del fix.** Corrió desde `/Users/dn/dev/goncloud-openclaw` con `CORRIDA_NATIVE_ROUTING=execute`, `CORRIDA_WORKERS_REGISTRY=~/bin/workers.v1.json` y `CORRIDA_WORKER_PY=~/bin/corrida-worker.py`.
  - Salida: `NO APTO` con la única razón `- flag no entra: cursor-agent`.
  - El vigía tmux vio que se crearon `preflight-canary-e4-0102-cursor-agent` y `preflight-canary-e4-0102-muse`.
  - Un primer intento desde otra carpeta sumó `flag no entra: kimi`, que es un residual de confianza por carpeta (ver abajo).
  - Cada NO APTO mandó un DETENIDA (message_id 7772 y 7773).
- **Selección.** `corrida-worker.py select` recibió un pedido `role write`, `task_type backend`, `denied_harnesses ["claude-code"]` (para que el revisor sea de otro modelo), con salud por sonda 7/7 `available`.
  - Ganador `kimi_k3`, modelo `kimi-code/k3`, effort null, score 85: affinity 40, availability 15, diversity 10, history 10, quota 10.
  - Empate a 85 con kimi_coding, codex, zcode y grok; desempate por orden del registro.
  - Descartados: claude_fable y claude_opus por `repo-denied`.
- **Carril.** `preparar-carril canary-e4-0102 legacy /Users/dn/dev/goncloud-openclaw` creó la rama `corrida/canary-e4-0102/legacy` sobre la base c125c76, en el worktree `.worktrees/canary-e4-0102-legacy`.
- **Harness.**
  - `adaptador start ... kimi_k3 canary-legacy-kimi` respondió `adaptador: kimi pidio confianza para el worktree del carril (...); respondido si` y `canary-legacy-kimi`.
  - `adaptador deliver` respondió `accepted`.
  - `adaptador inspect` dio `running` y luego `complete` (commit del worker a las 01:33, unos 25 min después de la entrega), con la marca `ADAPTADOR-MARCA: completo`. No hubo relevo.
- **Terminal.** `mostrar-terminal` respondió `degraded`, con `attach_command` igual a `/opt/homebrew/bin/tmux attach -t =canary-legacy-kimi`.
- **Commit del worker.** 8a9c240 cambió `preflight.sh` (+21 −3) y agregó el caso F2-g en `test-corrida-preflight.sh`.
- **Mutación.** Se probó en copias desechables del scratchpad, una del worker y otra del revisor, poniendo el `preflight.sh` de c125c76. Ambas salieron rc=1 con `FAIL: F2-g: la fila legacy fuera del registro debio seguir APTO: NO APTO - binario muere al arrancar: legado`.
- **Revisión cruzada local.** La hizo Claude Opus 5.5, que no es autor.
  - Leyó el diff.
  - En el head, `test-corrida-preflight`, `test-cli-modos` y `test-corrida-nucleo` dijeron `TODO VERDE`.
  - `pre-commit run --from-ref c125c76 --to-ref HEAD` pasó.
  - Veredicto approve.
- **PR.** https://github.com/gon0801/goncloud-openclaw/pull/216, head 8a9c2402432c62c54a62256b12d6b68cf83987fe.
- **CI.** Una sola vuelta, sin reruns, todo `pass`: ci-contract, clasificador, gate, review, shards 1/3, 2/3 y 3/3. Runs 36544574408 y 36544574373.
- **Revisor.**
  - DeepSeek completo en el head: 1 Medium y 2 Low, 0 High o Critical.
  - CodeRabbit: `Review limit reached`, declarado indisponible.
  - Triage publicado en el PR (issuecomment-5887093433).
- **Merge.** Lo ordenó David y se ejecutó por la ruta autorizada (`gh pr merge --squash --match-head-commit 8a9c240...`). Merge SHA: 5c57c7d8ac859f953166e74e8f453365eaa27b74.
  - El registro lleva `authorization_ref fase14-merge-automatico`, escrito por David. `receipt-mode` responde `ci-y-revisor`.
- **Deploy.** Se hizo desde el worktree detached limpio `/Users/dn/dev/wt/canary-e4-deploy`, en origin/main 5c57c7d.
  - `instalar-mac.sh` dijo `instalado desde ... (ref origin/main@5c57c7d)`.
  - `--verificar` dijo `verificado: instalacion sana`.
- **SHA desplegado, leído de lo instalado.** Blob de `~/bin/corrida/preflight.sh`: `23d0859df24ab7b683e1016d05eb2d07b817de10`, igual a `5c57c7d:scripts/mac/corrida/preflight.sh`. El de antes del fix era `136c1159...`.
  - También coinciden `compuerta.sh`, `lib.sh`, `cli-modos.tsv`, `workers.v1.json` y `corrida-worker.py`.
- **Observación viva.** `~/bin/corrida.sh preflight canary-e4-0102` corrió de 02:26:55 a 02:27:16 desde `/Users/dn/dev/goncloud-openclaw`, con el mismo entorno que antes.
  - Salida: `APTO`, y en `QUEDA unknown` aparecen `- fila legacy fuera del registro: muse` y `- fila legacy fuera del registro: cursor-agent`.
  - El vigía tmux solo vio las sesiones de claude, codex, glm, grok, kimi y zcode. No hubo ninguna sesión `-cursor-agent` ni `-muse`.
- **Cierre.** `adaptador stop` respondió `stopped`. `corrida.sh cerrar canary-e4-0102` respondió `cerrada canary-e4-0102`, dejó completo `archive/legacy/` (events, evidence, selection, transcript) y mandó CERRADA (message_id 7779).

## Veredictos de compuerta (registro `gate.*` del carril `legacy`)

| Acción | Veredicto |
|---|---|
| cross-review | `ALLOW cross-review cross-review-ok` |
| push-pr | `ALLOW push-pr push-pr-ok` |
| ci | `ALLOW ci ci-ok` |
| coderabbit | `ALLOW coderabbit coderabbit-ok` (unavailable-declared) |
| merge | `ALLOW merge merge-ok` (result conditional, reviewed_sha 8a9c240) |
| deploy | `DENY deploy sin-merge deploy sin merge registrado`, y luego `ALLOW deploy deploy-ok` |
| canary | `ALLOW canary canary-ok` (reviewed_sha 5c57c7d) |

El primer deploy se negó porque el merge todavía no estaba en el registro. `corrida.sh reconciliar canary-e4-0102` registró push, PR y merge (`CONVERGED 3`), y el segundo intento dio ALLOW. El deploy y el canary se registraron con `reconciliar --observations` (`deployed` = 5c57c7d; `canary` = pass).

Estado final del carril: `push`, `pr`, `merge`, `deploy` y `canary` quedaron registrados, con canary `result pass`, sha 5c57c7d y `pending_hosts []`.

## Residuales (no bloqueantes, para una fila del plan)

- **F1 (Medium, DeepSeek).** Una corrida de la cadena legacy cuyo runbook prescribe `muse` o `cursor-agent` ya no sondea esa barra. Propuesta: sondear la fila legacy solo si el runbook de la corrida la usa.
- **F2 (Low).** El cruce F2 busca la fila por la columna 1 y el salto legacy compara la columna 2. Hay que unificar la clave.
- **F3 (Low).** El fixture F2 usa `cli-ok` en la columna 2, así que F2-b ya no lanza sus filas; el lanzamiento de un seleccionable ahora lo cubre F2-g.
- **Confianza por carpeta.** Se midió en un socket tmux privado. Solo `/Users/dn/dev/goncloud-openclaw` pasa las seis CLIs.
  - kimi pide Trust en el worktree `/Users/dn/dev/wt/...` y en el directorio de la corrida.
  - claude pide trust en `$HOME` y en el directorio de la corrida.
  - codex pide acceso a la carpeta en el directorio de la corrida.
  - La espera de 2 s y el pane de 10 filas no son la causa.
- **`abrir` no escribe `authorization_ref`.** No hay subcomando que declare la preaprobación en el registro, y esta vez lo escribió David a mano.
- **`mostrar-terminal` en `degraded`.** No se abrió una ventana de Terminal; queda el attach exacto.
- **Tres vigilantes huérfanos de pruebas anteriores.** Siguen vivos en `/var/folders/.../corridas/.arnes-vigia-bin`; no se tocaron.
