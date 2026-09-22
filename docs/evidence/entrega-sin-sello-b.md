# Entrega sin sello — Bloque B: batería completa en CI y commits rápidos

Bloque B de `docs/superpowers/plans/2026-09-20-entrega-sin-sello.md`, ejecutado en
`fix/entrega-sin-sello-b-glm` desde `origin/main` 1f7b269. Commits: `52619f8`
(B1: contrato de cobertura de CI) y `e80f4b5` (B4: pruebas de fuente
deterministas). Rojos previos y mutantes: `.saikit/scratch/ADV/tdd.md`.

## Invocaciones antes/después

| Concepto | Antes (main 1f7b269) | Después (este bloque) | Comando / artifact del número |
|---|---|---|---|
| Batería en pre-commit local | 0 invocaciones | 0 invocaciones (sin cambio; B2 ya estaba en 15.2) | `grep -c run-checks .pre-commit-config.yaml` = 0 |
| Batería en CI por PR | 3 (matriz de shards) | 3 (sin cambio: no se re-corre nada) | job `shards`, `run: SAIKIT_SHARD=${{ matrix.shard }} bash scripts/run-checks.sh` |
| Auditoría de la unión en gate | 0 (el gate solo miraba resultados de jobs) | 1 por PR en carril completo | paso `Auditar la union...`: `bash scripts/valida-union-shards.sh auditoria "$inv"` sobre los artifacts `logs-run-checks-shard-{1,2,3}` |
| Contrato de cobertura | inexistente | 1 por PR, en ambos carriles | job `ci-contract`: `bash scripts/tests/test-ci-coverage-contract.sh` |
| Corridas del runner en el sandbox del contrato | — | 5 por corrida del test (3 shards válidos + 1 roja + 1 duplicada), contadas en el registro de invocaciones del test (caso 2) | `scripts/tests/test-ci-coverage-contract.sh` |

## Duraciones (segundos, macOS local; `/usr/bin/time`)

| Prueba focal | Duración |
|---|---|
| `test-ci-coverage-contract.sh` (13 casos + cableado, arbol de juguete) | 1.5 |
| `test-browser-profile-flag.sh` (con su regresión B4 incluida) | 0.15 |
| `test-skill-verify.sh` (con su regresión B4 incluida) | 0.24 |
| `test-summa-gate-quality-entrypoints.sh` (vecino, sin cambios) | verde |
| `test-runner-shards.sh` (vecino, sin cambios) | verde |

Duraciones de CI antes/después, instalación y espera de infraestructura:
**unknown** — razón: sin push ni PR permitidos en esta entrega no hay corrida de
Actions que medir; el número lo produce el primer PR de esta rama. Referencia
anterior disponible: el job `gate` conserva `timeout-minutes: 5` y `ci-contract`
nace con `timeout-minutes: 10`.

Duración local de `test-corrida-preflight.sh` completo: **unknown** — razón:
medido dos veces, la versión nueva agotó un timeout de 600 s con salida vacía y
la versión SIN cambios de `HEAD` (baseline extraída de git) también agotó 150 s
con salida vacía en el mismo punto (primer `abrir t-ok`): lentitud preexistente
de este test en esta máquina, no una regresión del bloque; el test sigue
candado en CI (shard 2/3). El delta nuevo sí quedó verificado con `bash -n` de
ambos archivos y un arnés focal aislado (cuatro escenarios del chequeo (7):
igual, muda, doblez, ausente — el último produce el unknown explícito).

## Inventario esperado vs unión observada

Medido en el sandbox del contrato (casos 1-3): inventario esperado 10 entradas
lógicas (5 shell del glob de juguete + 5 entradas fijas node/sintaxis/corpus);
unión observada de los 3 resúmenes = las mismas 10, cada una exactamente una vez;
duplicados 0, faltantes 0, sobrantes 0. En CI real sobre los artifacts de la
matriz: **unknown** (misma razón: sin corrida de Actions en esta entrega); el
gate lo affirmará en el primer PR y el caso (w) ya verifica que usa el mismo
validador que este test ejecutó.

## Mutantes (poder discriminante)

| Mutante | Cazado por | Resultado |
|---|---|---|
| M1 conjunto exacto desactivado | caso (7) | CAZADO |
| M2 resumen vacío aceptado | caso (11) | CAZADO |
| M3 resumen faltante tolerado | caso (8) | CAZADO |
| M4 filas en falla aceptadas | caso (5) | CAZADO |
| M5 unión vs inventario desactivada | caso (13) | CAZADO |
| M6 duplicados aceptados | caso (4) | CAZADO |
| M7 gate sin ci-contract en needs | caso (w) | CAZADO |
| M8 ci-contract omisible (`if:`) | caso (w) | CAZADO |
| M-B4-1 browser vuelve a consultar el binario instalado | caso (4): `la copia divergente FUE EJECUTADA` | CAZADO |
| M-B4-2 skill-verify vuelve a resolver el SDK desde la instalación | regresión B4: `la fuente ya no pasa` | CAZADO |

10/10 cazados. M2 y M4 sobrevivieron en la primera versión del test y obligaron a
apretar los casos para exigir la razón del rechazo (detalle en tdd.md).

## Rojos medidos antes del verde

R1 (gate sin auditoría de contenido, `grep valida-union|download-artifact` = 0),
R2 (validador sin cablear), R-B4a (copia divergente altera la fuente),
R-B4b (ausencia produce skip), R-B4c (skill-verify rompido por SDK divergente
del host): salidas completas en `.saikit/scratch/ADV/tdd.md`.

## Pendientes para el PR

- URL del run de Actions final: la añade el lead al abrir el PR.
- Primer gate con los artifacts reales: confirma la unión de inventario en CI
  (los números locales ya cubren la lógica; queda la observación en vivo).

## Ronda correctiva 2026-09-22 (`fix/entrega-sin-sello-b-review`)

Tres defectos de la revisión del bloque, cada uno con su regresión que falla sin
el arreglo. Rojos previos copiados aquí (versionados); el detalle de sesión vive
en el comentario de adjudicación del PR.

### Commits de la ronda

- `ab1cd1d` B1: re-corrida del mismo shard deja rastro y el gate la rechaza
  (runner `corrida-<marca>` por invocación + validador que rechaza un shard con
  más de una corrida + contrato con re-corrida real).
- `fd5cb1e` B3: preflight mira el exit code de la sonda `--browser-profile`.
- `53c0f4b` B2: la corrida hija aislada hereda el node verificado por el padre.
- `711e5f8` B1-bis: el discovery del validador incluye `corrida-*/` a la raíz
  del artifact (layout real del upload; reproducido por el gate rojo del run
  35748762272 en el PR del bloque C).
- `7460293` B2-bis (CodeRabbit): el wrapper ejecuta la ruta de node vía
  `NODE_WRAPPER_TARGET` (tolera espacios).
- Arreglos de una línea de la revisión independiente: `local rc_bien` y el
  mensaje de "falta el resumen" lista las cuatro formas buscadas.

### Comandos focalizados y resultados (macOS, esta rama)

| Comando | Resultado |
|---|---|
| `bash scripts/tests/test-ci-coverage-contract.sh` | rc=0, `TODO VERDE` (casos 7 y 7b nuevos) |
| `bash scripts/tests/test-skill-verify.sh` | rc=0, `TODO VERDE` (regresión B2 afirmada) |
| `bash scripts/tests/test-corrida-preflight.sh` | rc=0, `TODO VERDE` (caso B4-8 `rechaza`) |
| `bash scripts/tests/test-runner-shards.sh` | rc=0, `TODO VERDE` (rutas `corrida-*`) |
| `git diff --check` | vacío |

### Rojos previos (verificados antes de cada arreglo)

- B1 (sin el rechazo de re-corridas, el validador daba OK con dos invocaciones
  de 1/3 sobre el mismo artifact):
  `FAIL: (7) el validador acepto la RE-CORRIDA del mismo shard (rc=0)` /
  `valida-union-shards: OK — 10 entrada(s), cada una exactamente una vez`.
- B2 (la hija re-descubrió node en su entorno en vez de heredarlo):
  `FAIL regresion B2: la hija no uso el node heredado del padre; re-descubrio
  node en su entorno (0 usos antes, 0 despues)`.
- B3 (un CLI que rechaza el flag salía APTO):
  `FAIL: un CLI que rechaza --browser-profile no puede salir APTO:` seguido de
  `APTO`.
- B1-bis en CI real (gate sobre el artifact real): run 35748762272, job `gate`,
  `RECHAZADO — falta el resumen del shard 1 (se busco auditoria/shard-1/resumen.txt
  ...)` — el layout que el discovery no miraba; corregido y verde en el run
  35750564167.

### Verifier independiente (agente distinto del implementador)

VERIFICACION PASS. Los cinco comandos en rc=0 y tres mutaciones demostraron
discriminación: (a) sin el rechazo de `n_res -ne 1` el contrato cae en el caso
(7) exacto; (b) sin `NODE_HEREDADO` la hija falla con "corrida aislada sin
NODE_HEREDADO ejecutable"; (c) sin el chequeo del exit code el preflight
declara `APTO` para un CLI que rechaza el flag (caso B4-8). Worktree restaurado
limpio; sin `--no-verify`; sin batería completa local.

### Revisión independiente (agente distinto del implementador y del verifier)

REVISION APPROVE, cero bloqueantes. Revisó `origin/main...HEAD` completo (8
archivos, 5 commits) con cuatro mutaciones propias, la reproducción del hueco
de mundo viejo con `origin/main` (dos corridas reales de 1/3 → validador viejo
`OK`), el layout upload/download contra el discovery, las sondas restantes del
preflight y la herencia de node. No bloqueantes: `rc_bien` fuera de `local`
(aplicado), mensaje de búsqueda incompleto (aplicado), directorio `corrida-*`
sin resumen invisible (sin bypass real: sin resumen no hay filas que auditar y
"falta el resumen" rechaza), grep del caso (7) más laxo que el rc (la
aserción que discrimina es la del rc, probada por mutación), `RES_ROJO` vacío
(ya cubierto por el assert del rc de la corrida roja).

### CI

- Run de Actions que validó el código de esta ronda (SHA `07245d6`, PR #127):
  https://github.com/gon0801/goncloud-openclaw/actions/runs/35757609197 —
  shards (1/3, 2/3, 3/3), `gate`, `ci-contract` y `clasificador` en success.
- El commit de evidencia (este) re-corre la batería por ser push nuevo; el run
  de su SHA final queda citado en el recibo del PR #127 (comentario
  persistente), junto con el veredicto de CodeRabbit sobre esta rama
  (revisión completada sin comentarios).
