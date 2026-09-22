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
