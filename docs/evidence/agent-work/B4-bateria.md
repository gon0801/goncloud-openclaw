# B4: artefacto nativo y baterías del bloque

Fecha: 2026-10-09. Host local: macOS (darwin, arm64). No es CI. Encargo B4-bateria (plan `:284`):
el artefacto nativo con integridad registrada y una sola corrida de cada batería del bloque.

## El par (verificado antes de lanzar y al cerrar)

- G: `4c0a11ec0985c8c4d60829988a6a94470b2299a1`, rama `encargos/b4`, worktree `~/dev/wt/encargos-b4`.
  `git status --porcelain` muestra solo `?? out/` antes y después de las baterías.
- R: `978355503c44313536ab4cd03a6bfb7a5423404b`, rama `feat/agent-work-integration`,
  `/Users/dn/dev/openclaw-agent-work-integration`. Árbol limpio antes y después.
- Bases del bloque: G `77fafb0f66e595d6a4812c3591d09627315dde82` (ancestro de `4c0a11e`),
  R `3c1c7485375705ecb25411646994bdc37b63a10b` (head de B3, ancestro del par).
- Cuenta `agentes` antes de cada batería: solo los 3 `xpcproxy com.apple.*` de siempre.

## Paso 1 — artefacto nativo de R con integridad (una vez)

Copia aislada: `git -C /Users/dn/dev/openclaw-agent-work-integration worktree add --detach <mktemp -d>/r 978355503c44` (la copia vive en `/var/folders/hp/sc_3c6qs7nvdswl_x3w5sdbr0000gn/T/tmp.Anru5gyeVW/r`).

1. `CI=1 pnpm install --frozen-lockfile --prefer-offline --ignore-scripts` → exit 0 (fin 15:41:38Z,
   menos de un minuto con el store caliente; `LANG=en_US.UTF-8`).
2. `CI=1 pnpm build` → exit 0. Fin 15:48:42Z; phase timings del propio build: total 7 m 1,2 s.
3. Contrato del artefacto: `jq -r .commit dist/build-info.json` =
   `978355503c44313536ab4cd03a6bfb7a5423404b` (el SHA del par) y `git status --porcelain` de la
   copia vacío. El build corresponde al código revisado.
4. Integridad registrada:
   - `shasum -a 256 dist/entry.js` =
     `5b023c6417db26670df94798cb523df75b570576527159c8a2e244049d75d414`.
   - Digest del árbol: `(cd <copia> && find dist -type f | LC_ALL=C sort | xargs shasum -a 256) | shasum -a 256` =
     `4cf1a2e805d9f666eac02dd76da0da9f1cba890c80518099a89c3533fbffdf33`; el árbol tiene
     13 884 archivos.
   - `pnpm pack` → exit 1: `ERR_PNPM_BUNDLED_DEPENDENCIES_WITHOUT_HOISTED`
     («bundleDependencies does not work with "nodeLinker: isolated"»; help: añadir
     `nodeLinker: hoisted` a `pnpm-workspace.yaml` o borrar `bundleDependencies` del root
     `package.json`). Error literal anotado y sin arreglo, como manda el encargo: la
     integridad queda en los dos primeros valores. El paquete `.tgz` y su integridad
     sha512 en formato npm NO quedaron registrados por esta causa.
5. Nada se instaló en el gateway ni en el sistema: el artefacto vive solo en la copia aislada.

Logs: `~/.local/state/encargos-loop/artifacts/B4-bateria/paso1-build.log`,
`paso1-pack.log`, `paso1-install.exit`, `paso1-build.exit`, `paso1-entry-sha256.txt`,
`paso1-dist-arbol-sha256.txt`, `paso1-dist-num-archivos.txt`.

## Paso 2 — batería de G (una vez)

Comando: `cd ~/dev/wt/encargos-b4 && LANG=en_US.UTF-8 bash scripts/run-checks.sh` sobre `4c0a11e`.
Inicio 2026-10-09T15:50:01Z, fin 16:29:45Z. Duración 39 min 44 s. Exit 1.
LOGDIR de la corrida: `logs/run-checks/corrida-20261009-085001-41973` (101 entradas:
100 ok, 1 falla; `verify-corpus` ok). Copia íntegra del LOGDIR:
`~/.local/state/encargos-loop/artifacts/B4-bateria/g-logdir-corrida/`. Log del driver:
`~/.local/state/encargos-loop/artifacts/B4-bateria/paso2-g-bateria.log`.

- Pruebas reales como `agentes`: `test-agent-work-host.sh`, OK (skipped=1) en 50 s,
  44 pruebas. El skip es `test_resource_close_real_launchd_label_stays_pending`
  (EIO 5 de la sesión de login, como siempre).
- Sin `AGENT_WORK_RUNTIME_SOURCE` las pruebas que necesitan R salen skip (e2e:
  `cli_gateway` y `review_tail_restart`; integration: la cruzada). Anotadas como NO
  CORRIDAS, no como pases: ya corrieron sobre este mismo par en la corrida del par de
  B4-39 (`acceptance-pair.json`, 51 referencias en verde).

Falla de la batería y clasificación:

1. `test-cli-modos.sh` (rc=1, 5 s). Drift de inventario registro vs host: claude
   registro 2.1.285 vs host 2.1.292; codex 0.159.2 vs 0.160.0; grok 1.0.44 vs 1.0.46.
   Reproducida sola (`LANG=en_US.UTF-8 bash scripts/tests/test-cli-modos.sh`):
   - sobre `4c0a11e`: exit 1, 3 s, salida idéntica
     (`paso2-solo-4c0a11e-test-cli-modos.log`);
   - sobre la base `77fafb0f` en worktree aislado de `mktemp -d`: exit 1, 3 s, salida
     idéntica (`paso2-solo-base77fafb0-test-cli-modos.log`).
   Falla igual en la base → limitación de la base (fila B0 de `followups.md`,
   conocida desde la auditoría; en CI la entrada se salta al no haber CLI de host).
   No es bloqueante del cierre.

## Paso 3 — batería de R (una vez), en la copia del paso 1

Es la batería de lo que hicimos, nunca la suite completa: sin `pnpm test` ni `--changed`.

1. Objetivos: `~/.local/state/encargos-loop/bateria-r-objetivos.sh <copia>` → exit 0,
   **613 archivos** (599 en la batería de B3; B4 añadió pruebas).
2. Tipos: `LANG=en_US.UTF-8 pnpm tsgo:core` → exit 0, 33 s.
   `LANG=en_US.UTF-8 pnpm tsgo:core:test` → exit 0. La primera invocación la cortó el
   tope de la herramienta del implementador a los 5 min (sin corrida completa, sin
   exit); se relanzó con `nohup` según la regla del encargo y terminó OK a los
   16:44:27Z (unos 6,5 min). Cero errores de tipos: la deuda de B0→B2 sigue arreglada.
3. Batería (una vez, con `nohup`):
   `LANG=en_US.UTF-8 OPENCLAW_NODE_TEST_PLAN_CONTINUE_ON_FAILURE=1 node --import ./scripts/tsx.mjs scripts/test-projects.mts $(cat objetivos.txt)`
   Inicio 2026-10-09T16:44:39Z, fin 18:41:46Z. Duración 1 h 57 min 7 s. Exit 1.
   **29 de 29 shards arrancados**, como anuncia el plan.

Inventario de fallas (12 líneas `×` únicas; una prueba sale en dos formatos de línea,
así que son 11 pruebas en 3 archivos):

| archivo | × | shard (resumen) | clase |
|---|---|---|---|
| `src/node-host/node-worker-supervisor.recovery.test.ts` | 2 | `vitest.infra.config.ts` (1 failed / 133 passed de 134) | base, por tiempos: B3-r3 la corrió sola 3 veces por árbol y cayó 3 de 3 incluso en la base pública `c074824a27` |
| `src/tui/tui-pty-local.e2e.test.ts` | 8 | `vitest.tui-pty.config.ts` (1 failed de 1) | base pública: cayó en los tres árboles (base, B3 y B4) en B3 |
| `test/e2e/qa-lab/runtime/agent-sandboxed-exec-behavior.e2e.test.ts` | 1 | `vitest.e2e.config.ts` (1 failed / 68 passed de 69) | base pública: `spawn docker ENOENT` (sin Docker en esta Mac); cayó en los tres árboles en B3 |

- **Fallas nuevas: NINGUNA.** Las tres conocidas no se reproducen en aislado porque el
  encargo solo manda reproducir lo que no esté en lo conocido, y las tres ya tienen
  clasificación por árbol de B3 (`B3-bateria.txt`).
- Los 7 archivos de la fila B4/regresiones (`attempt-stream-transport`,
  `attempt.exec-review-transcript`, `attempt.spawn-workspace.diagnostics`,
  `attempt.tool-search-catalog-abort`, `update-command-admit`, `schema.hints`,
  `openclaw-state-db`) NO cayeron; tampoco las conocidas de B1/B2
  (`heartbeat-runner.model-override`, `openclaw-database-maintenance`,
  `openclaw-database-preflight`, `check-native-state-schema-version`, `sanitize-text`).
  Los arreglos de B4-1 a B4-3 se sostienen en esta batería.
- Fila B4-31 de `followups.md` (`scheduleRestartSentinelWake > durably wakes the
  configured system-agent session when the sentinel has no sessionKey`): **NO quedó
  clasificada por esta batería.** Su archivo `src/gateway/server-restart-sentinel.test.ts`
  no entró a los 613 objetivos: el selector `bateria-r-objetivos.sh` solo casa imports
  estáticos `from '…/<módulo>(.js|.ts)?'` y esa prueba importa el módulo con
  `await import("./server-restart-sentinel.js")`. El módulo sí cambió desde la base
  pública. La fila queda actualizada en `followups.md` y sigue pendiente; no es
  bloqueante del cierre.
- El ejecutor de G contra R (`test-runtime.sh`) no se repite aquí: ya corrió sobre este
  mismo par en la corrida del par de B4-39 (`acceptance-pair.json`, 51 referencias en
  verde), y `acceptance` lo exige y lo lee.

Logs: `~/.local/state/encargos-loop/artifacts/B4-bateria/paso3-r-objetivos.log`
(2,5 MB), `paso3-x-resultado.txt` (12 líneas únicas), `paso3-x-archivos.txt`,
`objetivos.txt`, `paso3-tsgo-core.log`, `paso3-tsgo-core-test.log` y sus `.exit`.

## Casilla del plan

`:284` marcada `[x]`: la integridad del paso 1 quedó registrada (dos valores + error
literal del pack), las dos baterías corrieron exactamente una vez y no hay ningún
bloqueante del cierre (la falla de G es limitación de la base; las tres de R, base
conocida; `scheduleRestartSentinelWake` queda pendiente en `followups.md`, sin ser
regresión del par).
