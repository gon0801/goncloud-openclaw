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
