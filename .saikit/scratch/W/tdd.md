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
