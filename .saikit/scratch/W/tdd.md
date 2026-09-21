# TDD carril W (15.2, shards en CI) — rojo medido antes del verde

Fecha: 2026-09-21 · Worktree: /Users/dn/dev/wt-f15-W · Rama: fase15/shards

## Estado de partida

- `git log --oneline -1` => `9ac48ee feat(ci): clasificador de cambios por archivos y gate fast (15.0 S) (#116)`
  (contiene tambien el runner sharding de 15.1 R: `c303dea`).
- Test de entrypoints SIN actualizar contra el workflow de partida: VERDE
  (`PASS test-summa-gate-quality-entrypoints`, exit 0).

## El cambio de test (rojo primero)

Se actualizo `scripts/tests/test-summa-gate-quality-entrypoints.sh` ANTES de tocar
el workflow:

- (3) reescrito: CI ya no puede correr la bateria "exactamente una vez" monolitica;
  ahora la unica corrida permitida es `run: SAIKIT_SHARD=${{ matrix.shard }} bash
  scripts/run-checks.sh` dentro de la matriz.
- (6) nuevo: funcion `contrato_shards` que valida el contrato 15.2 sobre el
  workflow REAL — un solo paso de bateria shardado por matriz, `fail-fast: false`,
  exactamente los shards 1/3, 2/3, 3/3, `needs: [clasificador]` con condicion
  `!= 'fast'`, sin `continue-on-error`, gate con `needs: [clasificador, shards]`,
  regla de pares (`success:fast` + rebote "no quedo en success") y
  `actions/upload-artifact` de `logs/run-checks/`.
- (7) nuevo: el mismo validador sobre fixtures recortados en
  `scripts/tests/fixtures/quality-shards/` — `workflow-valido.yml` (pasa) y tres
  mutaciones de una linea que DEBEN ser rechazadas: `shard-faltante.yml` (matriz
  sin 3/3), `fallo-ignorado.yml` (`continue-on-error: true` en shards),
  `gate-sin-dependencia.yml` (gate sin shards en needs). Sin red, sin GitHub.

## ROJO medido (contra el workflow ACTUAL, sin shards)

```
$ bash scripts/tests/test-summa-gate-quality-entrypoints.sh
ok (1): scripts.check cubre index.ts, lib.ts, observer.ts y diagnostic-guard.ts
ok (2): scripts/run-checks.sh invoca npm run check
FAIL: la unica corrida de la bateria debe quedar shardada por la matriz (SAIKIT_SHARD=${{ matrix.shard }})
exit=1
```

El rojo nace exactamente en la asercion nueva: el workflow actual corre la bateria
monolitica y no hay matriz que shardée.

## Poder discriminante del validador (estado rojo, antes del fix)

Misma funcion `contrato_shards` extraida del test y corrida a mano:

```
--- workflow REAL (sin shards, debe RECHAZAR):
rechazado OK
--- fixture VALIDO (debe aceptar):
aceptado OK
--- fixtures ROTOS (deben rechazar):
shard-faltante: rechazado OK
fallo-ignorado: rechazado OK
gate-sin-dependencia: rechazado OK
```

Es decir: el validador no acepta cualquier cosa (acepta al valido y rechaza al
workflow viejo y a cada mutacion). Despues del cambio del workflow, la corrida
completa del test vuelve a verde con estos mismos checks dentro.

## Mutaciones cubiertas (siembras locales, jamas pushes rojos)

| Siembra | Fixture | Por que el validador la rechaza |
|---|---|---|
| shard faltante | `shard-faltante.yml` | falta `shard: 3/3` en la matriz: la union de resumen.txt ya no cubre la bateria |
| fallo ignorado | `fallo-ignorado.yml` | `continue-on-error: true` en el job de shards |
| gate sin dependencia completa | `gate-sin-dependencia.yml` | gate `needs: [clasificador]` sin los shards |

## r1 — el gate debe ser quien espere a los shards (bloqueante cross-review codex)

Fecha: 2026-09-21 · Base: `a245a9e` (intacto; el arreglo va en UN commit `fix(ci):` nuevo).

Hallazgo: (e) de `contrato_shards` grepea `^    needs: \[clasificador, shards\]` en TODO
el archivo — no ancla el bloque del job `gate`. Reproduccion del revisor: mover el needs
completo a un job señuelo y dejar `needs: [clasificador]` en el gate. Fixture nuevo que
lo reproduce tal cual: `scripts/tests/fixtures/quality-shards/gate-sin-shards-senuelo.yml`
(nombre ASCII, sin eñe: los validadores lo consumen por ruta en MSYS/Linux).
Baseline del test de entrypoints contra `a245a9e`: VERDE (exit 0, 8 ok).

### ROJO medido (funcion extraida del test SIN tocar, contra el fixture nuevo)

`sed -n '/^contrato_shards()/,/^}/p' scripts/tests/test-summa-gate-quality-entrypoints.sh`
+ driver que llama `contrato_shards <yaml>`:

```
ACEPTA (exit 0)   <- CASO DEL REVISOR: debe RECHAZAR
ACEPTA (exit 0)   <- workflow real: debe ACEPTAR
ACEPTA (exit 0)   <- fixture valido: debe ACEPTAR
rechaza (exit 1) <- gate-sin-dependencia: debe RECHAZAR
```

El caso del revisor pasa hoy: el validador acepta un gate que no espera la bateria,
exactamente como lo reprocho la ronda 1. Los controles no cambian (el hueco es solo el
ancalaje).

### Arreglo (mismo commit)

(e) reescrito: extrae la SECCION `gate:` por su clave (`awk` desde `^  gate:` hasta la
siguiente clave de job a igual indentacion o EOF; seccion vacia = rechazo, fail-closed) y
exige DENTRO de esa seccion una linea `needs:` de nivel de job con `clasificador` Y
`shards` (orden libre). El grep global se borra: era el hueco. (7) suma el fixture nuevo
al ciclo de rechazo; los comentarios de familia "tres hermanos" pasan a "cuatro".

### VERDE medido (mismo test completo, despues del arreglo)

`bash -n` limpio. `bash scripts/tests/test-summa-gate-quality-entrypoints.sh`:

```
ok (1) ... ok (6)  (sin cambios, todos verdes)
ok (7): fixture shard-faltante.yml rechazado como corresponde
ok (7): fixture fallo-ignorado.yml rechazado como corresponde
ok (7): fixture gate-sin-dependencia.yml rechazado como corresponde
ok (7): fixture gate-sin-shards-senuelo.yml rechazado como corresponde
exit=0
```

### Poder discriminante del validador ARREGLADO (funcion extraida, driver a mano)

```
rechaza (exit 1) <- CASO DEL REVISOR (gate-sin-shards-senuelo.yml): debe RECHAZAR
ACEPTA (exit 0)   <- workflow real: debe ACEPTAR
ACEPTA (exit 0)   <- fixture valido: debe ACEPTAR
rechaza (exit 1) <- gate-sin-dependencia: debe RECHAZAR
rechaza (exit 1) <- sin job gate (gate renombrado a gatex): debe RECHAZAR (fail-closed)
ACEPTA (exit 0)   <- gate needs [shards, clasificador] (orden libre): debe ACEPTAR
```

El fixture senuelo CONSERVA la linea `needs: [clasificador, shards]` (1 ocurrencia,
verificada con grep -c): el rechazo solo puede venir del anclaje de la seccion `gate:`,
no de que la linea desaparezca. La mutacion "sin job gate" deja intactos todos los greps
globales (a)-(d),(f),(g) — su unico rechazo posible es la seccion gate vacia del (e) nuevo.

## r2 — el contrato se acota a las secciones de job y exige exactamente tres entradas

Fecha: 2026-09-21 · Base: `edad26b` (a245a9e y edad26b intactos; el arreglo va en UN
commit `fix(ci):` nuevo).

Hallazgo BLOQUEANTE (CodeRabbit, Functional Major): `contrato_shards` corria la mayoria
de los checks positivos sobre el YAML CRUDO — un comentario u otro job satisfacia
`fail-fast`, los valores de shard, la dependencia del clasificador, el texto de la regla
de pares o el upload de artifacts mientras el job `shards` REAL violaba el contrato.
Ademas el loop de shards solo verificaba que `1/3`, `2/3` y `3/3` APARECIERAN: aceptaba
duplicados y entradas extra.

### Fixtures nuevos (mutaciones de workflow-valido.yml, YAML valido)

- `shards-duplicado.yml`: DOS entradas `1/3` y NINGUNA `3/3` (entries 1/3, 1/3, 2/3).
- `shards-en-comentario.yml`: los tokens del contrato (`fail-fast: false`, `needs:
  [clasificador]`, `carril != 'fast'`, la corrida `SAIKIT_SHARD=...`, `shard: 1/3|2/3|3/3`,
  `actions/upload-artifact`, `logs/run-checks`, `success:fast`, `no quedo en success`)
  viven en COMENTARIOS del job `clasificador`, mientras el job `shards` real corre la
  bateria MONOLITICA (`run: bash scripts/run-checks.sh`) con matriz `1/2`/`2/2`.

### ROJO medido (funcion vieja EXTRAIDA del test SIN tocar, driver a mano)

`sed -n '/^contrato_shards()/,/^}/p'` + driver `contrato_shards <yaml>`:

```
ACEPTA  (exit 0) <- .github/workflows/quality.yml                    (correcto)
ACEPTA  (exit 0) <- workflow-valido.yml                              (correcto)
rechaza (exit 1) <- shard-faltante.yml                               (correcto)
rechaza (exit 1) <- fallo-ignorado.yml                               (correcto)
rechaza (exit 1) <- gate-sin-dependencia.yml                         (correcto)
rechaza (exit 1) <- gate-sin-shards-senuelo.yml                      (correcto)
rechaza (exit 1) <- shards-duplicado.yml          (ver NOTA abajo)
ACEPTA  (exit 0) <- shards-en-comentario.yml      <- EL CASO DEL REVISOR: debe RECHAZAR
```

NOTA honesta sobre `shards-duplicado.yml`: el validador VIEJO ya lo rechazaba, pero por
la razon EQUIVOCADA — le falta el token `shard: 3/3` y el loop viejo lo exigia. El hueco
de duplicados real del revisor es este, medido aparte (mutacion de workflow-valido con
CUATRO entradas: 1/3, 1/3, 2/3, 3/3 — los tres tokens presentes mas un duplicado):

```
$ grep -cE '^[[:space:]]*-[[:space:]]*shard:' mut-cuatro-entradas.yml
4
ACEPTA  (exit 0) <- mut-cuatro-entradas.yml       <- duplicados/extra aceptados: debe RECHAZAR
```

O sea: el brief decia "el workflow actual acepta ambos fixtures"; medido, acepta
`shards-en-comentario.yml` (el caso central del anclaje) y NO el de duplicados — pero
si acepta la forma pura de duplicados/extra (4 entradas). Ambos huecos quedan cubiertos
y el dato queda asentado.

### Arreglo (mismo commit)

`contrato_shards` reescrito en
`scripts/tests/test-summa-gate-quality-entrypoints.sh`:

- Se extrae la SECCION `shards:` por su clave (awk de `^  shards:` hasta la siguiente
  clave de job a igual indentacion o EOF, misma tecnica de `seccion_gate`; seccion
  ausente o vacia = rechazo, fail-closed) y DENTRO de ella corren TODOS los checks del
  job: (a) unica corrida de la bateria con la linea `SAIKIT_SHARD=...`, (b) `fail-fast:
  false` + EXACTAMENTE tres entradas de matrix include (`grep -c` de
  `^\s*-\s*shard:` == 3) con cada valor `1/3|2/3|3/3` exactamente UNA vez, (c) `needs:`
  de nivel de job con `clasificador` + condicion `carril != 'fast'`, (d) sin
  `continue-on-error`, (g) upload de `logs/run-checks/`.
- (f) la regla de pares (`success:fast` / `no quedo en success`) pasa a correr DENTRO de
  `seccion_gate` (su job): el texto suelto en el YAML crudo lo satisfacia un comentario.
- (e) queda como en r1. Los greps globales de (a)-(d),(f),(g) se BORRAN: eran el hueco.
- (7) suma los dos fixtures nuevos al ciclo de rechazo (seis hermanos).

### VERDE medido (test completo, despues del arreglo)

`bash -n` limpio. `bash scripts/tests/test-summa-gate-quality-entrypoints.sh`:

```
ok (1)..(6)  (sin cambios, todos verdes)
ok (7): fixture shard-faltante.yml rechazado como corresponde
ok (7): fixture fallo-ignorado.yml rechazado como corresponde
ok (7): fixture gate-sin-dependencia.yml rechazado como corresponde
ok (7): fixture gate-sin-shards-senuelo.yml rechazado como corresponde
ok (7): fixture shards-duplicado.yml rechazado como corresponde
ok (7): fixture shards-en-comentario.yml rechazado como corresponde
exit=0
```

### Poder discriminante del validador r2 (funcion extraida, driver a mano)

```
ACEPTA  (exit 0) <- workflow real: debe ACEPTAR
ACEPTA  (exit 0) <- workflow-valido.yml: debe ACEPTAR
ACEPTA  (exit 0) <- gate needs [shards, clasificador] (orden libre): debe ACEPTAR
rechaza (exit 1) <- shard-faltante.yml        (seccion con 2 entradas)
rechaza (exit 1) <- fallo-ignorado.yml        (continue-on-error DENTRO de la seccion)
rechaza (exit 1) <- gate-sin-dependencia.yml  (seccion gate sin shards en needs)
rechaza (exit 1) <- gate-sin-shards-senuelo.yml (idem, needs en el señuelo)
rechaza (exit 1) <- shards-duplicado.yml      (3 entradas pero 1/3 dos veces y 3/3 cero)
rechaza (exit 1) <- shards-en-comentario.yml  (seccion shards: 0 SAIKIT_SHARD, 0
                                                 fail-fast, 2 entradas 1/2-2/2)
rechaza (exit 1) <- mut-cuatro-entradas.yml   (4 entradas: duplicado/extra — el caso
                                                 que el validador viejo ACEPTABA)
rechaza (exit 1) <- shards renombrado a `shardss:` (seccion vacia: fail-closed)
```

Razones verificadas por conteo sobre la seccion extraida (grep -c): duplicado tiene
`entradas=3` pero el valor `1/3` aparece 2 veces y `3/3` 0 (rechaza el exactly-once);
comentario tiene `SAIKIT_SHARD=0`, `fail-fast=0`, `entradas=2` (rechaza el anclaje);
cuatro-entradas tiene `entradas=4` (rechaza el tope de 3).
