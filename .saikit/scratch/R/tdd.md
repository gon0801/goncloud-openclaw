# TDD 13.1 — marcas de candado declaradas (carril R, glm)

Worktree `/Users/dn/dev/wt-f13-R`, rama `fase13/marcas`.
Test nuevo: `scripts/tests/test-candados-declarados.sh` (ida y vuelta; la lista
de frases ancladas sale de recorrer todos los tests de `scripts/tests/`, no de
una lista escrita a mano).

## Rojo primero (antes de que existiera una sola marca)

```
$ bash scripts/tests/test-candados-declarados.sh
FAIL ida: 103 frase(s) anclada(s) sin marca junto a la frase:
  test-agent-dispatch-no-merge.sh no marca 'go/no-go' en agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
  test-agent-dispatch-no-merge.sh no marca 'openclaw and the workspaces' en agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
  test-agent-dispatch-no-merge.sh no marca 'Orbit and accounting' en agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
  test-agent-dispatch-no-merge.sh no marca 'saikit-cierre-pr' en agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
  test-agent-dispatch-no-merge.sh no marca 'regression' en agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
  test-agent-dispatch-spawn.sh no marca 'sessions_spawn agentId=<role> mode=run' en agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
  test-agent-dispatch-spawn.sh no marca 'timeoutSeconds: 0' en agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
  test-browser-profile-flag.sh no marca 'openclaw browser --browser-profile claw tabs --json' en agents/main/agent/workshop-skills/browser-cli-claw-profile/SKILL.md
  test-browser-profile-flag.sh no marca 'requires credentials before opening a websocket' en agents/main/agent/workshop-skills/browser-cli-claw-profile/SKILL.md
  test-browser-profile-flag.sh no marca 'NEVER run `reset-profile` on `claw`' en agents/main/agent/workshop-skills/browser-cli-claw-profile/SKILL.md
  test-browser-profile-flag.sh no marca 'One session drives the claw browser at a time' en agents/main/agent/workshop-skills/browser-cli-claw-profile/SKILL.md
  test-browser-profile-flag.sh no marca 'timeoutSeconds >= 60' en agents/main/agent/workshop-skills/browser-cli-claw-profile/SKILL.md
  test-cierre-pr-merge-comando.sh no marca 'Merge order for stacked PRs' en agents/implementer/agent/workshop-skills/saikit-cierre-pr/MERGE-POR-ORDEN.md
  ... y 89 más
ok vuelta: las 0 marca(s) de agents/** y docs/agent-skills/** apuntan a tests que existen y afirman su frase
ROJO: 103 problema(s) con los candados declarados
exit=1
```

## Verde con las marcas (57 marcas: 46 colocadas + copias idénticas)

```
$ bash scripts/tests/test-candados-declarados.sh
ok ida: las 100 frases ancladas por 11 test(s) tienen su marca
ok vuelta: las 57 marca(s) de agents/** y docs/agent-skills/** apuntan a tests que existen y afirman su frase
TODO VERDE: candados declarados (100 frases, 57 marcas)
exit=0
```

Los 11 tests que anclan frases, según el inventario derivado de recorrer
`scripts/tests/`: test-agent-dispatch-no-merge (5), test-agent-dispatch-spawn
(2), test-browser-profile-flag (5), test-cierre-pr-merge-comando (12: 6 por
copia de saikit), test-goncloud-ssh-ops-deploy (7), test-mac-path-regla (6),
test-mac-tmux-control (9), test-merge-allowlist-cierre-pr (2), test-saikit-
cierre-pr-merge-owner (8), test-skill-autopilot-runbook (30), test-tmux-
activity-watch (14).

Detalles de implementación que el revisor querrá saber:
- La marca va en línea propia a ≤2 líneas de la frase; la región de la frase
  se extiende al bloque cercado o al frontmatter que la contiene (adentro no
  se puede insertar un comentario HTML).
- `agent-dispatch/SKILL.md` no puede contener "merge" y el test que lo ancla
  se llama `test-agent-dispatch-no-merge.sh`: la marca lo nombra con el
  escape clásico de una clase de un carácter, `test-agent-dispatch-no-[m]erge.sh`,
  y la vuelta resuelve `[c]` → `c` antes de buscar el archivo.
- browser-cli-claw-profile va idéntico en main/operaciones/ingenieria y
  saikit-cierre-pr en implementer/ingenieria (sus tests exigen la igualdad):
  las mismas marcas en cada copia; la vuelta acepta una copia byte-idéntica
  como destino válido de la marca.

## Mutante 1 de la DoD: quitarle la marca a una frase anclada

Borrada la única marca de `agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md`
(la frase anclada es la del deploy de 6.4b):

```
$ sed -i '' '/<!-- candado: test-goncloud-ssh-ops-deploy.sh -->/d' agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md
$ bash scripts/tests/test-candados-declarados.sh
FAIL ida: 7 frase(s) anclada(s) sin marca junto a la frase:
  test-goncloud-ssh-ops-deploy.sh no marca 'app.bak-predeploy-' en agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md
  test-goncloud-ssh-ops-deploy.sh no marca 'cp -a app app.bak-predeploy-$(date +%Y%m%d-%H%M)' en agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md
  test-goncloud-ssh-ops-deploy.sh no marca 'back up `cp -a app app.bak-predeploy-' en agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md
  test-goncloud-ssh-ops-deploy.sh no marca '%{http_code}' en agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md
  test-goncloud-ssh-ops-deploy.sh no marca 'http_code' en agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md
  test-goncloud-ssh-ops-deploy.sh no marca 'Precondition for BOTH branches' en agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md
  test-goncloud-ssh-ops-deploy.sh no marca 'Live <SHA> en <URL>' en agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md
ok vuelta: las 56 marca(s) de agents/** y docs/agent-skills/** apuntan a tests que existen y afirman su frase
ROJO: 7 problema(s) con los candados declarados
exit=1
$ # restaurado:
$ bash scripts/tests/test-candados-declarados.sh
ok ida: las 100 frases ancladas por 11 test(s) tienen su marca
ok vuelta: las 57 marca(s) ... afirman su frase
TODO VERDE: candados declarados (100 frases, 57 marcas)
exit=0
```

Además se barrió la propiedad completa: borrar CUALQUIERA de las 57 marcas,
una por vez, pone el test en rojo (57/57 rojas; script de barrido en
`.saikit/scratch/R/`, sin commitear mutantes).

## Mutante 2 de la DoD: marca que apunta a un test que no la afirma

La marca de goncloud re-apuntada a `test-camino-feliz.sh` (test que existe
pero no ancla ninguna frase en agents/**):

```
$ sed -i '' 's/<!-- candado: test-goncloud-ssh-ops-deploy.sh -->/<!-- candado: test-camino-feliz.sh -->/' agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md
$ bash scripts/tests/test-candados-declarados.sh
FAIL ida: 7 frase(s) anclada(s) sin marca junto a la frase:
  ... (las 7 frases de goncloud sin marca, como arriba)
FAIL vuelta: 1 marca(s) que no sostiene su test:
  agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md:28 <!-- candado: test-camino-feliz.sh --> — ese test no afirma ninguna frase junto a esta marca
ROJO: 8 problema(s) con los candados declarados
exit=1
$ # restaurado: TODO VERDE (100 frases, 57 marcas), exit=0
```

Extra: marca a un test que no existe (`test-no-existe.sh`) también roja:
`FAIL vuelta: ... <!-- candado: test-no-existe.sh --> — no es un test de scripts/tests/`.

## Batería

```
$ bash scripts/run-checks.sh
  ... (summa-gate: 280 pass) ...
  ... (tablero-runbook: pass=105) ...
=== pruebas de contrato de scripts/
  OK    test-agent-dispatch-no-merge.sh
  OK    test-agent-dispatch-spawn.sh
  OK    test-arranque-de-fase.sh
  OK    test-browser-profile-flag.sh
  OK    test-camino-feliz.sh
  OK    test-candados-declarados.sh
  OK    test-cierre-de-fase.sh
  OK    test-cierre-pr-merge-comando.sh
  OK    test-cli-modos.sh
  OK    test-contrato-dispatch.sh
  OK    test-corrida-nucleo.sh
  OK    test-corrida-preflight.sh
  OK    test-esperar-contrato.sh
  OK    test-evidencia-sin-texto-de-usuario.sh
  OK    test-goncloud-ssh-ops-deploy.sh
  OK    test-hooks-apuntan-a-archivos-trackeados.sh
  OK    test-lanzar-fase.sh
  OK    test-lanzar-lead.sh
  OK    test-localizador-de-runbook.sh
  OK    test-loop-autopilot.sh
  OK    test-mac-path-regla.sh
  OK    test-mac-tmux-control.sh
  OK    test-merge-allowlist-cierre-pr.sh
  OK    test-patch-modelos-repartidos.sh
  OK    test-progreso-valido.sh
  OK    test-restart-gateway-script.sh
  OK    test-run-checks-reporta-fallo.sh
  OK    test-runbook-progreso.sh
  OK    test-runbooks-no-contradicen-entorno.sh
  OK    test-runner-del-kit.sh
  OK    test-saikit-cierre-pr-merge-owner.sh
  OK    test-salida-del-observador-no-trackeada.sh
  OK    test-skill-autopilot-runbook.sh
  OK    test-spec-fleet-roles.sh
  OK    test-spec-tablero.sh
  OK    test-summa-gate-quality-entrypoints.sh
  OK    test-sync-no-sube-binarios.sh
  OK    test-sync-pull-identity.sh
  OK    test-tmux-activity-watch.sh
=== corpus de rendiciones re-derivable
filas: 22 | veredicto declarado == recomputado: 22
DEBEN detectarse: 16 -> atrapados 16, escapados 0
LEGITIMOS:        6 -> sobre-marcados 5, bien ignorados 1
OK: verify-corpus
TODO VERDE
exit=0
```

Nota de una corrida intermedia: en un arranque suelto de
`test-skill-autopilot-runbook.sh` a mitad de la tarea, su paso (4) estuvo rojo
porque la copia de la Mac traía slots 14-15 que en ese momento no estaban en
ninguna ref (verificado con `git stash` que el fallo ocurría también en el
árbol sin mis cambios). Minutos después el blob apareció en
`refs/heads/fase9/docs` (repo compartido con otros carriles) y el paso pasó a
`ok (4): ... es la versión de refs/heads/fase9/docs`. La corrida final de la
batería, arriba, es la que vale: TODO VERDE, exit 0.

## r1 — el parser no veía anclas con ruta literal (hallazgo del cross-review, corregido)

Defecto: un test que afirma una frase con la ruta del archivo INLINE no era
reconocido como ancla. Arreglo: el destino del grep ahora acepta, además de
variable, una RUTA LITERAL bajo agents/ o docs/agent-skills/ (con o sin
comillas, ./ opcional). Nada más se relajó; la vuelta quedó igual.

```
$ # repro del lead (antes del fix), con scripts/tests/test-tmp-repro-r1.sh presente:
$ cat scripts/tests/test-tmp-repro-r1.sh
#!/usr/bin/env bash
grep -qF 'A phase is closed only when a command says so' agents/main/agent/workshop-skills/agent-dispatch/SKILL.md || exit 1
$ bash scripts/tests/test-candados-declarados.sh
ok ida: las 100 frases ancladas por 11 test(s) tienen su marca
ok vuelta: las 57 marca(s) de agents/** y docs/agent-skills/** apuntan a tests que existen y afirman su frase
TODO VERDE: candados declarados (100 frases, 57 marcas)      # ← punto ciego: el ancla nueva no aparece
exit=0

$ # tras el fix, con el test temporal presente y sin su marca:
$ bash scripts/tests/test-candados-declarados.sh
FAIL ida: 1 frase(s) anclada(s) sin marca junto a la frase:
  test-tmp-repro-r1.sh no marca 'A phase is closed only when a command says so' en agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
ok vuelta: las 57 marca(s) de agents/** y docs/agent-skills/** apuntan a tests que existen y afirman su frase
ROJO: 1 problema(s) con los candados declarados
exit=1

$ # con la marca puesta junto a la frase (línea bajo el encabezado):
$ bash scripts/tests/test-candados-declarados.sh
ok ida: las 101 frases ancladas por 12 test(s) tienen su marca
ok vuelta: las 58 marca(s) de agents/** y docs/agent-skills/** apuntan a tests que existen y afirman su frase
TODO VERDE: candados declarados (101 frases, 58 marcas)
exit=0

$ # borrados el test temporal y su marca: verde como hoy
$ bash scripts/tests/test-candados-declarados.sh
ok ida: las 100 frases ancladas por 11 test(s) tienen su marca
ok vuelta: las 57 marca(s) de agents/** y docs/agent-skills/** apuntan a tests que existen y afirman su frase
TODO VERDE: candados declarados (100 frases, 57 marcas)
exit=0
```

El fix no destapa anclas nuevas en los tests existentes (inventario antes y
después: 100 entradas, 0 nuevas — los tests actuales usan variable para el
destino); las 57 marcas quedan como estaban.

Batería r1: primera corrida con UN rojo — `test-tmux-activity-watch.sh`,
la excepción flaky conocida (fila 9.13 del plan): falló en la pasada de la
batería y el re-run de diagnóstico del propio run-checks ya daba TODO VERDE;
standalone ×3 verde. Segunda corrida completa, sin tocar nada:

```
$ bash scripts/run-checks.sh
  ... (summa-gate: 280 pass, tablero-runbook: pass=105) ...
=== pruebas de contrato de scripts/
  OK    test-candados-declarados.sh        (+ los otros 38 OK, incluidos todos los que anclan frases)
  ... (40 tests OK en total, 0 FALLA)
=== corpus de rendiciones re-derivable
OK: verify-corpus
TODO VERDE
exit=0
```

## r2 — el regex de ruta literal seguía corto + auto-prueba de regresión permanente

Hueco 1 (regex): ni `./agents/...` (con barra tras el punto) ni
`'agents/...'` (comillas simples) se reconocían. Arreglo: el destino admite
prefijo `./` opcional y comillas simples o dobles (además de la forma pelada
de r1); la normalización quita comillas y `./` antes del chequeo de alcance.

```
$ # repro del lead, DOS tests temporales (./ y comillas simples), ANTES del fix:
$ bash scripts/tests/test-candados-declarados.sh
ok ida: las 100 frases ancladas por 11 test(s) tienen su marca      # ← punto ciego
ok vuelta: las 57 marca(s) ...
TODO VERDE: candados declarados (100 frases, 57 marcas)
exit=0

$ # VERIFY 1: los TRES estilos temporales presentes (pelado + ./ + comillas simples):
$ bash scripts/tests/test-candados-declarados.sh
FAIL ida: 3 frase(s) anclada(s) sin marca junto a la frase:
  test-tmp-repro-r2a.sh no marca 'A phase is closed only when a command says so' en agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
  test-tmp-repro-r2b.sh no marca 'A phase is closed only when a command says so' en agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
  test-tmp-repro-r2c.sh no marca 'A phase is closed only when a command says so' en agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
ok vuelta: las 57 marca(s) ...
ROJO: 3 problema(s) con los candados declarados
exit=1

$ # VERIFY 2: borrados los temporales:
$ bash scripts/tests/test-candados-declarados.sh
ok ida: las 100 frases ancladas por 11 test(s) tienen su marca
ok vuelta: las 57 marca(s) ...
TODO VERDE: candados declarados (100 frases, 57 marcas)
exit=0
```

Hueco 2 (auto-prueba): dentro del propio test, `auto_prueba_regresion`
levanta una caja de arena en `mktemp -d` (fuera del repo: no queda ningún
archivo temporal commiteable) con una skill sintética y un test sintético por
estilo (pelada, ./, comillas simples, comillas dobles), corre ESTE MISMO
script contra ella con `CANDADOS_RAIZ` (raíz parametrizada) y exige: sin
marcas, rojo nombrando a los cuatro estilos; con las marcas, TODO VERDE.

```
$ bash scripts/tests/test-candados-declarados.sh
ok auto-prueba: los 4 estilos de ruta literal se detectan y exigen su marca
ok ida: las 100 frases ancladas por 11 test(s) tienen su marca
ok vuelta: las 57 marca(s) ...
TODO VERDE: candados declarados (100 frases, 57 marcas)
exit=0

$ # VERIFY 3: mutación — regex revertido a la forma de r1 (sin ./ ni comillas simples):
$ bash scripts/tests/test-candados-declarados.sh
FAIL auto-prueba: el parser no detecta el ancla con ruta literal estilo dot
  FAIL ida: 2 frase(s) anclada(s) sin marca junto a la frase:
    test-sintetico-bare.sh no marca 'frase sintetica bare' en agents/sintetico/agent/workshop-skills/skill-s/SKILL.md
    test-sintetico-dos.sh no marca 'frase sintetica dos' en agents/sintetico/agent/workshop-skills/skill-s/SKILL.md
  ok vuelta: las 0 marca(s) ...
  ROJO: 2 problema(s) con los candados declarados
exit=1
$ # restaurado:
$ bash scripts/tests/test-candados-declarados.sh
ok auto-prueba: los 4 estilos de ruta literal se detectan y exigen su marca
ok ida: las 100 frases ancladas por 11 test(s) tienen su marca
ok vuelta: las 57 marca(s) ...
TODO VERDE: candados declarados (100 frases, 57 marcas)
exit=0
```

Batería r2 (VERIFY 4), verde a la primera (sin flaky esta vez):

```
$ bash scripts/run-checks.sh
  ... (tablero-runbook: node --check OK; # tests 105, pass 105, fail 0) ...
=== pruebas de contrato de scripts/
  OK    test-agent-dispatch-no-merge.sh
  ... (los 39 tests de scripts/ en OK, incluido test-candados-declarados.sh) ...
  OK    test-tmux-activity-watch.sh
=== corpus de rendiciones re-derivable
filas: 22 | veredicto declarado == recomputado: 22
DEBEN detectarse: 16 -> atrapados 16, escapados 0
LEGITIMOS:        6 -> sobre-marcados 5, bien ignorados 1
OK: verify-corpus
TODO VERDE
```

La salida cerró en `TODO VERDE`, que run-checks.sh solo imprime con
`fallas == 0` (el final del script es ese eco o "N comprobacion(es) en rojo"
+ exit 1; verificado en run-checks.sh:143-148): exit 0. Los pasos previos
(summa-gate, pre-commit) corrieron arriba de la parte volcada; cualquier
rojo ahí habría cerrado la corrida con el conteo en rojo en vez de TODO
VERDE. VERIFY 1-3 re-corridos hoy dieron idéntico a lo volcado arriba.

---

# TDD 15.1 — inventario, logs y shards (carril R, glm)

Worktree `/Users/dn/dev/wt-f15-R`, rama `fase15/runner`.
Test nuevo: `scripts/tests/test-runner-shards.sh` (arbol de juguete con fixtures en
`scripts/tests/fixtures/runner-shards/`: NO corre la bateria real). Rojo medido el
2026-09-20, ANTES de tocar `scripts/run-checks.sh` y `test-tmux-activity-watch.sh`.

## Rojo 1 — el runner de hoy ignora SAIKIT_SHARD (corre todo en cualquier shard)

```
$ bash scripts/tests/test-runner-shards.sh
(1) union de los tres shards = bateria completa, sin duplicados
FAIL: (1) shard 1/3: el inventario corrido no es el esperado.
    esperaba : nucleo
    obtuvo   : bateria-summa bateria-tablero corpus nucleo preflight resto-a resto-b sintaxis-summa sintaxis-tablero watchdog
exit=1
```

## Rojo 2 — SAIKIT_SHARD invalido (4/3) pasa por verde y ademas corre la bateria

Sonda contra el runner sin cambios, arbol de juguete todo verde (5 entradas):

```
$ TALLY_SHARDS=... SAIKIT_SHARD=4/3 bash run-checks.sh-de-juguete
exit=0 ; entradas corridas: 5
```

## Rojo 3 — una prueba roja se ejecuta dos veces (la segunda es el "diagnostico")

```
$ TALLY_SHARDS=... bash run-checks.sh-de-juguete   (con test-roja.sh que sale 7)
exit=1
ejecuciones de la roja: 2
```

## Verde

(despues de implementar: `bash scripts/tests/test-runner-shards.sh` → TODO VERDE,
pegado mas abajo en este mismo archivo)

## Verde (tras reescribir scripts/run-checks.sh y retirar la llamada anidada del watchdog)

```
$ bash scripts/tests/test-runner-shards.sh
(1) union de los tres shards = bateria completa, sin duplicados
ok (1): la union de los tres shards es la bateria completa y nada corre dos veces
(2) sin SAIKIT_SHARD corre TODO y un archivo nuevo entra solo por el glob
ok (2): sin la variable corre TODO y el archivo nuevo entro solo por el glob
(3) shards invalidos salen != 0 sin correr nada
ok (3): 4/3 y x salen != 0 sin correr una sola entrada
(4) un shard sin su prueba en el glob es rojo, no un verde por vacio
ok (4): el shard que no encuentra su prueba revienta
(5) una prueba roja: una sola ejecucion, primera salida y exit code en el log
ok (5): una sola ejecucion; primera salida y exit code conservados en el log y el resumen
TODO VERDE: runner-shards
exit=0
```

Lo que el arbol de juguete afirma, entrada por entrada: cada fixture, cada bateria node,
cada sintaxis y el corpus dejan UNA linea por ejecucion en un tally compartido; la union
de los tres shards son las 10 entradas exactamente una vez cada una (5 shell + 2
baterias node + 2 sintaxis + corpus). La roja cuenta 1 linea (antes 2: la segunda era el
"diagnostico" del runner viejo re-ejecutandola).

## Bateria local: ATASCADA por el python3 de Homebrew, no por este cambio

`bash scripts/run-checks.sh` (todo, una sola vez) quedo colgado en
`test-corrida-nucleo.sh` paso (9), que corre con un entorno lavado a proposito:
`env -i PATH="$T/bin:/opt/homebrew/bin:/usr/bin:/bin"`. Ese PATH pone primero el
python3 de Homebrew, que HOY esta roto A NIVEL DE MAQUINA:

```
$ timeout 10 python3 -c 'print(1)'          # /opt/homebrew/bin/python3 (3.14.7)
rc=124   (gira a ~100% CPU incluso sin sandbox y con -S/-E)
$ timeout 10 /usr/bin/python3 -c 'print(1)' # el de Apple: 0.036 s
vivo-apple
```

Arbol del cuello de botella (ps): corrida.sh (paso 9) -> `/bin/sh
/opt/homebrew/bin/python3 -c "import json,os..."` con 7+ min de CPU girando. El
carril hermano S (wt-f15-S) quedo clavado en el MISMO paso con el MISMO arbol, y
`test-corrida-nucleo.sh` es el UNICO test del repo con ese PATH lavado
(grep env -i). Es decir: un arbol SIN este diff tambien se cuelga hoy en esta
maquina — el bloqueo es del entorno, no del cambio. En CI (ubuntu) el python3 es
sano y ese paso corre normal.

Verificacion local alcanzable (con PATH prefijando un python3 sano para el resto
de la bateria, que hereda el PATH): shards 2/3 y 3/3 en verde, watcher y vecinos
en verde sueltos; el shard 1/3 queda bloqueado solo por ese paso. La union
mecanica de los tres shards la exige `scripts/tests/test-runner-shards.sh`.

## Rojo tardio (hallado por la bateria, no por la corrida suelta)

El shard 3/3 real puso `test-runner-shards.sh` en rojo: el caso "(2) sin SAIKIT_SHARD
corre TODO" heredaba la variable del runner que lo envolvia (en CI se invoca como
`SAIKIT_SHARD=3/3 bash scripts/run-checks.sh`) y el "todo" de juguete corria un shard 3
disfrazado — el tally salia sin nucleo/preflight/watchdog. Suelto nunca fallaba: sin
variable en el entorno que heredar. Fix: el caso '' usa `env -u SAIKIT_SHARD`. Es
exactamente el tipo de falso verde de entorno que esta prueba existe para cazar.

Verde del fix en los tres contextos: suelto, con SAIKIT_SHARD=3/3 exportado (el que
pintaba el rojo) y con 1/3 exportado: exit=0 en los tres.
