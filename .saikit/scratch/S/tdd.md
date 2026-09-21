# Carril S — TDD (rojo inicial medido, 2026-09-20)

## Rojo limpio (sin clasificador)

```
$ bash scripts/tests/test-clasificador-cambio.sh
FAIL: falta /Users/dn/dev/wt-f15-S/scripts/clasificar-cambio.sh (este test es el rojo del TDD: implementalo)
limpio_exit=1
```

## Rojo discriminante (stub que SIEMPRE dice fast: 20 casos en fallo)

El stub demuestra poder discriminante: con un clasificador que aprueba todo,
todos los casos que deben ser completo o exit 2 caen, y solo pasan los fast.
```
$ bash scripts/tests/test-clasificador-cambio.sh   # clasificar-cambio.sh = printf \"fast\n\"
  OK    docs-permitidos -> fast
  FALLA codigo: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA mezcla: veredicto 'fast', esperaba 'completo' (stderr: )
  OK    borrado-doc -> fast
  FALLA borrado-codigo: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA borrado-mezcla: veredicto 'fast', esperaba 'completo' (stderr: )
  OK    renombre-doc-doc -> fast
  FALLA renombre-doc-codigo: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA renombre-codigo-doc: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA documento-operativo-agents-x-agent.md: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA documento-operativo-docs-agent-skills-s-SKILL.md: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA documento-operativo-.github-workflows-quality.yml: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA formato-fuera-de-contrato: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA codigo-en-arbol-de-docs: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA allowlist-vacia: veredicto 'fast', esperaba 'completo' (stderr: )
  OK    sin-cambios -> fast
  FALLA base-inresoluble: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA historias-independientes: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA uso-sin-args: espero exit 2, llego 0
  FALLA uso-flag-desconocido: espero exit 2
  FALLA allowlist-inexistente: espero exit 2
  FALLA no-es-repo-git: espero exit 2
  OK    contrato-real-4-paths -> fast
  FALLA contrato-real-workflow: veredicto 'fast', esperaba 'completo' (stderr: )
  FALLA salida-github-output: GITHUB_OUTPUT no trae carril=fast y motivo= ()
  OK    salida-stdout-unica-linea
ROJO: 20 caso(s) del clasificador en fallo
stub_exit=1
```

## Verde (2026-09-20, tras implementar clasificar-cambio.sh + ci-fast-allowlist.txt)

```
$ bash scripts/tests/test-clasificador-cambio.sh
  OK    no-es-repo-git -> exit 2
  OK    contrato-real-4-paths -> fast
  OK    contrato-real-workflow -> completo
  OK    salida-github-output -> carril=fast y motivo= presentes
  OK    salida-stdout-unica-linea
TODO VERDE: test-clasificador-cambio
exit=0
```

## Verificacion final (2026-09-20)

- `bash scripts/tests/test-clasificador-cambio.sh` -> TODO VERDE (26 casos).
- `bash scripts/tests/test-summa-gate-quality-entrypoints.sh` -> PASS (los
  invariantes del workflow siguen: run-checks.sh exactamente una vez en CI,
  pre-commit/action, permisos contents: read, checkouts con
  persist-credentials: false).
- Simulacion local del paso gate (matriz de 10 estados): omision de jobs solo
  pasa con clasificacion fast valida; failure/cancelled/ausencia/garbage
  rebotan. El bloque extraido es el literal del workflow.
- Bateria local `bash scripts/run-checks.sh`: summa-gate OK, tablero-runbook OK
  (pass=176), verify-corpus OK, 49 de 50 pruebas de scripts/tests en verde.
  `test-corrida-nucleo.sh` no se pudo observar en esta maquina: su caso (9)
  corre `env -i PATH=.../opt/homebrew/bin:...` y `/opt/homebrew/bin/python3`
  esta corrupto en el host (shim `#!/bin/sh exec python3` que se auto-executa:
  loop infinito, 12+ min de CPU medidos; tambien detiene a otros carriles).
  No relacionado con este diff (no toca corrida/** ni python del host); el
  gate definitivo del carril es el job `gate` del CI en ubuntu. Reparacion
  sugerida al operador: `brew reinstall python@3.14` (o relink).

# r1 (2026-09-20) — correccion de los 2 bloqueantes de la cross-review (codex)

## Bloqueante 1: la allowlist puede autorizarse a si misma

### Rojo medido ANTES del arreglo (tests nuevos primero, codigo de 3643d34)

```
$ bash scripts/tests/test-clasificador-cambio.sh
  FALLA allowlist-se-reescribe: veredicto 'fast', esperaba 'completo (stderr: ... motivo=los 2 archivo(s) del cambio estan en la allowlist)
  FALLA control-scripts-clasificar-cambio.sh: veredicto 'fast', esperaba 'completo' (... estan en la allowlist)
  FALLA control-.github-workflows-quality.yml: veredicto 'fast', esperaba 'completo' (... estan en la allowlist)
ROJO: 3 caso(s) del clasificador en fallo
```

Los tres casos son la reproduccion del revisor: un cambio que reescribe la
allowlist a `**` (+codigo) clasifica fast con el codigo de 3643d34. En los dos
casos de control la `**` queda EN LA BASE (fuera del rango) para aislar la
regla por archivo de control del simple echo de tocar la llave.

### Arreglo y verde

`ruta_es_control` en clasificar-cambio.sh: tocar
scripts/ci-fast-allowlist.txt, scripts/clasificar-cambio.sh o
.github/workflows/quality.yml (por nombre, tambien en cada extremo de un
renombre) emite `completo` ANTES de consultar la allowlist.

```
$ bash scripts/tests/test-clasificador-cambio.sh
  OK    allowlist-se-reescribe -> completo
  OK    control-scripts-clasificar-cambio.sh -> completo
  OK    control-.github-workflows-quality.yml -> completo
TODO VERDE: test-clasificador-cambio        (29 casos)
```

## Bloqueante 2: el carril fast no ejecutaba ningun control documental

### Repro del revisor medida con el workflow de 3643d34

Repo de juguete cuyo unico cambio es `.saikit/progress/15.json` =
`{"fase": "15"}` (parseable, SIN la clave schema). Paso del gate extraido
literal del workflow, con los estados que produce un fast:

```
$ R_CLASIFICADOR=success CARRIL=fast R_QUALITY=skipped bash gate.sh
clasificador=success carril=fast
quality=skipped
gate: quality=skipped omitido, autorizado por clasificacion fast
gate: OK -- carril valido y todos los jobs de calidad en verde
gate_exit_con_doc_roto=0        <-- el hueco: verde sin auditar nada
```

### Arreglo

Paso nuevo "Checks documentales del rango" en el job clasificador de
quality.yml (env de shas movido a nivel job, compartido). Valida los archivos
CAMBIADOS del rango (merge-base igual que el clasificador; lo borrado no tiene
contenido que validar; rango inresoluble => exit 0 porque el clasificador ya
forzo completo en el mismo job):

- `.saikit/progress/*.json`: `python3 -m json.tool` + claves schema y fase.
- `docs/evidence/**/*.{md,txt}`: no vacios y primera linea `# `.
- `Plans.md`: filas TOCADAS por el diff con forma `| <n>.<n> | ... |` exigen
  exactamente 5 columnas (agregadas Y borradas; no todo el archivo).

Fail-closed: si algo no cumple, el job muere rojo y el gate rebota. Corre en
AMBOS carriles (politica: "Cambios mixtos ejecutan bateria completa y checks
documentales").

### Simulacion local extendida: `.saikit/scratch/S/sim-gate-doc-check-r1.sh`

Extrae LITERALES del workflow el paso doc-check y el paso del gate, corre el
clasificador real y traduce resultados a job results. El host de mac tiene el
python3 de brew roto, asi que el sim pone /usr/bin primero en el PATH (en CI
es el python del runner; nota de la ronda 0 arriba). 7 escenarios:

```
$ bash .saikit/scratch/S/sim-gate-doc-check-r1.sh
  OK    A-fast-progress-sin-schema -> carril=fast doc=1 gate=1     (fast doc rojo => gate RECHAZA)
  OK    A2-fast-progress-no-json -> carril=fast doc=1 gate=1
  OK    B-fast-docs-validos -> carril=fast doc=0 gate=0            (fast doc verde => gate PASA)
  OK    C-mixto-evidencia-sin-titulo -> carril=completo doc=1 gate=1
  OK    D-fast-fila-4-columnas -> carril=fast doc=1 gate=1
  OK    D2-fast-evidencia-vacia -> carril=fast doc=1 gate=1
  OK    E-fast-sin-docs-contractuales -> carril=fast doc=0 gate=0  (sin docs del contrato => pasa)
TODO VERDE: sim-gate-doc-check-r1 (7 escenarios)
```

### Mutaciones (una por proteccion, todas rojo en su escenario)

Silenciar `rc=1` de cada familia en quality.yml (copia de seguridad y
restauracion por archivo; el diff post-restauracion es identico):

| mutacion silenciada | escenario que se pone rojo |
|---|---|
| `no es JSON parseable` | A2-fast-progress-no-json |
| `sin las claves schema` | A-fast-progress-sin-schema |
| `esta vacio` | D2-fast-evidencia-vacia |
| `no arranca con titulo` | C-mixto-evidencia-sin-titulo |
| `rc=1` standalone del bloque Plans.md | D-fast-fila-4-columnas |

Cada mutacion dejo exactamente `ROJO: 1 escenario(s)`; la ultima hay que
hacerla por el `rc=1` suelto (el mensaje va en un printf de dos lineas, el sed
linea-a-linea no lo alcanza por el texto). Ejemplo de salida:

```
=== mutacion: sin las claves schema (espera FALLA A-fast-progress-sin-schema) ===
  FALLA A-fast-progress-sin-schema: doc-check rc=0, esperaba 1 (doc-check: OK)
ROJO: 1 escenario(s) del sim en fallo
```

### Salvedad para el lead

5 recibos .txt de log crudo ya existentes (docs/evidence/gate-recibo-logs-*.txt)
no arrancan con `# ` (primera linea `Log file: C:\...`). El paso solo valida
archivos CAMBIADOS, asi que no rebota nada hoy; si un PR futuro los toca, hay
que agregarles la linea de titulo en el mismo cambio (el contrato del brief es
literal: md Y txt con titulo).

## Verificacion final r1 (2026-09-20)

- `bash scripts/tests/test-clasificador-cambio.sh` -> TODO VERDE (29 casos).
- `bash scripts/tests/test-summa-gate-quality-entrypoints.sh` -> PASS
  (run-checks.sh sigue exactamente una vez en CI; pre-commit/action, permisos
  contents: read y persist-credentials: false intactos).
- `bash .saikit/scratch/S/sim-gate-doc-check-r1.sh` -> TODO VERDE (7 escenarios).
- `git diff origin/main...HEAD --stat -- scripts/run-checks.sh` -> vacio.
- YAML del workflow parsea (`ruby -ryaml`, sanity local).

# r2 (2026-09-20) — correccion exprés (CodeRabbit Stability Major: SIGPIPE)

## Hallazgo

En el paso "Checks documentales del rango", leer la primera linea con
`head -n 1` dentro de una sustitucion bajo `set -euo pipefail` puede recibir
SIGPIPE cuando `git show` todavia escribe (archivo grande): head cierra la
tuberia en cuanto imprime la primera linea, el productor recibe SIGPIPE (141)
y la ASIGNACION devuelve != 0, matando el job con un archivo de evidencia
VALIDO. El doc-check debe validar, no crashear entrada valida.

## Rojo medido (repro determinista, ANTES del arreglo)

Repro minima del mecanismo (repo de juguete, archivo de 15 MB bajo una tuberia
con buffer de 64 KiB), 5/5 corridas iguales:

```
$ bash -c 'set -euo pipefail; h=$(git rev-parse HEAD); primera=$(git show "$h:big.md" | head -n 1); echo "vivo: $primera"'
exit=141        # sin "vivo:" -- la asignacion mato el script
```

Escenario nuevo F en sim-gate-doc-check-r1.sh (fast + evidencia GRANDE y
valida: titulo '# ' en la primera linea, 15 MB de contenido), contra el
workflow de 5efa62f (con `head -n 1`):

```
$ bash .saikit/scratch/S/sim-gate-doc-check-r1.sh
  OK    A-fast-progress-sin-schema -> carril=fast doc=1 gate=1
  OK    A2-fast-progress-no-json -> carril=fast doc=1 gate=1
  OK    B-fast-docs-validos -> carril=fast doc=0 gate=0
  OK    C-mixto-evidencia-sin-titulo -> carril=completo doc=1 gate=1
  OK    D-fast-fila-4-columnas -> carril=fast doc=1 gate=1
  OK    D2-fast-evidencia-vacia -> carril=fast doc=1 gate=1
  OK    E-fast-sin-docs-contractuales -> carril=fast doc=0 gate=0
  FALLA F-fast-evidencia-grande-valida: doc-check rc=141, esperaba 0 ()
ROJO: 1 escenario(s) del sim en fallo
```

El rc=141 ES el hallazgo: entrada valida, paso muerto. Este rojo es tambien la
mutacion que acredita poder discriminante (revertir sed -> head reproduce
exactamente esta FALLA).

## Arreglo

`primera=$(git show "$hs:$f" | sed -n '1p')`: sed consume TODA la entrada, el
productor nunca ve la tuberia cerrada temprano y no hay EPIPE que convertir en
141 bajo pipefail. Era la unica lectura de primera linea del paso (grep
'head -n 1' == 0 despues del cambio). Coste: sed drena el archivo completo
(milisegundos para los .md/.txt de evidencia).

## Verde (2026-09-20, tras el arreglo)

```
$ bash .saikit/scratch/S/sim-gate-doc-check-r1.sh
  OK    F-fast-evidencia-grande-valida -> carril=fast doc=0 gate=0
TODO VERDE: sim-gate-doc-check-r1 (8 escenarios)
```

## Verificacion final r2 (2026-09-20)

- `bash scripts/tests/test-clasificador-cambio.sh` -> TODO VERDE (29 casos).
- `bash scripts/tests/test-summa-gate-quality-entrypoints.sh` -> PASS
  (invariantes del workflow intactos: run-checks.sh exactamente una vez en CI,
  pre-commit/action, permisos contents: read, persist-credentials: false).
- `bash .saikit/scratch/S/sim-gate-doc-check-r1.sh` -> TODO VERDE (8 escenarios).
- `grep -c 'head -n 1' .github/workflows/quality.yml` -> 0.
- YAML del workflow parsea (`ruby -ryaml`, sanity local).
