# B0 — corrección doc-check del PR 242 (recibo)

Bloqueante: el job `clasificador` (paso «Checks documentales del rango», definido en
`.github/workflows/quality.yml:153`) del run `36982279824` quedó rojo porque 15 `.txt` de
evidencia agregados por la rama no arrancan con `# `. Cascada: `shards` saltado por
`needs: [clasificador]` y `gate` rebotado con «shards=skipped omitido SIN clasificacion fast
valida». Este arreglo no toca `gate` ni `shards`.

## Nota de colisión con f5fece2

Durante esta ronda el commit `f5fece2` (ajeno a este encargo, ya pusheado en `origin/encargos/b0`)
añadió en los 15 un título mecánico `# <ruta>` más una línea en blanco. Ese cambio ya ponía el
doc-check en verde, pero no cumplía el contrato acordado (título que dice qué es la captura y de
qué tarea es, «y nada más»). El commit `096ccdf` de esta ronda reemplaza esas dos líneas por un
único título descriptivo por archivo: el diff neto contra `19e3ee3` es exactamente una línea por
archivo y la captura queda intacta debajo. Por eso la salida roja se reproduce contra `19e3ee3`
(el head que cita el encargo, antes de cualquier título).

## Comando del repro

`scripts/tests/test-doc-check-evidencia.sh` aplica la MISMA lógica del paso doc-check sobre el
mismo rango: `mb=$(git merge-base origin/main <head>)`, `git diff --name-only --diff-filter=d -z
"$mb" <head>`, match `docs/evidence/*.md|docs/evidence/*.txt`, no vacío con `git cat-file -s` y
primera línea con `sed -n 1p` (por el SIGPIPE de `head`, mismo motivo que el paso de CI);
fail-closed con exit 1. Recorre TODO el rango, no una lista fija. Sin argumentos evalúa HEAD; con
un commit como argumento evalúa ese head (rojo histórico y mutaciones sin mover la rama).

## Salida roja (contra 19e3ee3, antes de los títulos)

```
$ bash scripts/tests/test-doc-check-evidencia.sh 19e3ee3
doc-check-repro: docs/evidence/agent-work/B0-source-final-baseline.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/B0-source-final-build.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T1-contract-focused.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T1-focused.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T1-incident-red.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T1-red.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T1-wrapper-red.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T1-wrapper-registration.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T1-wrapper-result.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T2-binding-focused.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T2-binding-red.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T2-partial-focused.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T2-red.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T2-wrapper-admission.txt no arranca con titulo '# '
doc-check-repro: docs/evidence/agent-work/T2-wrapper-red.txt no arranca con titulo '# '
doc-check-repro: RECHAZADO (161 archivo(s) en el rango)
```

Código de salida: 1. Nombra exactamente los 15 archivos del encargo y ningún otro.

## Salida verde (en 096ccdf, head del arreglo)

```
$ bash scripts/tests/test-doc-check-evidencia.sh
doc-check-repro: OK (162 archivo(s) en el rango)
```

Código de salida: 0. Sin archivos reportados. (162 y no 161 porque el propio script y followups.md
entran en el rango; el script no hace match con el glob de evidencia.)

## Mutación (commit efímero sin el título de T2-red.txt)

Plumbing sin mover la rama ni el worktree:

```
git show HEAD:docs/evidence/agent-work/T2-red.txt | tail -n +2 > /tmp/mut-t2-red.txt
blob=$(git hash-object -w /tmp/mut-t2-red.txt)
GIT_INDEX_FILE=/tmp/idx-mut-doc-check git read-tree 'HEAD^{tree}'
GIT_INDEX_FILE=/tmp/idx-mut-doc-check git update-index --cacheinfo "100644,$blob,docs/evidence/agent-work/T2-red.txt"
tree=$(GIT_INDEX_FILE=/tmp/idx-mut-doc-check git write-tree)
mut=$(git commit-tree "$tree" -p HEAD -m 'mutacion temporal doc-check: sin titulo en T2-red.txt')
```

Commit efímero: `146bc942ad950d5d1ceeb602c6c0872ad8a7435e` (quedan intactos el título y el
contenido de T2-red.txt en HEAD y en el worktree; nada que restaurar).

```
$ bash scripts/tests/test-doc-check-evidencia.sh 146bc942ad950d5d1ceeb602c6c0872ad8a7435e
doc-check-repro: docs/evidence/agent-work/T2-red.txt no arranca con titulo '# '
doc-check-repro: RECHAZADO (162 archivo(s) en el rango)
```

Código de salida: 1. Nombra exactamente el archivo mutado y ningún otro.

## Los 15 títulos puestos

- `docs/evidence/agent-work/B0-source-final-baseline.txt`: `# B0 — baseline final de R: test-runtime.sh 37/37 y doble admisión tras reinicio (captura)`
- `docs/evidence/agent-work/B0-source-final-build.txt`: `# B0 — build final del árbol de R con build-all (captura)`
- `docs/evidence/agent-work/T1-contract-focused.txt`: `# T1 — salida focalizada del contrato: managed-task.store.test.ts 7/7 (captura)`
- `docs/evidence/agent-work/T1-focused.txt`: `# T1 — salida focalizada de managed-task.store.test.ts 5/5 (captura)`
- `docs/evidence/agent-work/T1-incident-red.txt`: `# T1 — regresión roja del contrato review.v1 e incidencia PermissionRequired (captura)`
- `docs/evidence/agent-work/T1-red.txt`: `# T1 — regresión roja inicial: faltan registerManagedTask y reportManagedTaskResult (captura)`
- `docs/evidence/agent-work/T1-wrapper-red.txt`: `# T1 — salida roja del ejecutor de G: caso registration_identity sin implementar (captura)`
- `docs/evidence/agent-work/T1-wrapper-registration.txt`: `# T1 — wrapper de G: test-runtime.sh registration_identity 2/2 (captura)`
- `docs/evidence/agent-work/T1-wrapper-result.txt`: `# T1 — wrapper de G: test-runtime.sh result_receipt 4/4 (captura)`
- `docs/evidence/agent-work/T2-binding-focused.txt`: `# T2 — prueba combinada del registro nativo 13/13 (captura)`
- `docs/evidence/agent-work/T2-binding-red.txt`: `# T2 — regresión roja de la comprobación del registro nativo (captura)`
- `docs/evidence/agent-work/T2-partial-focused.txt`: `# T2 — salida focalizada de admission, spawn-pipeline y store 11/11 (captura)`
- `docs/evidence/agent-work/T2-red.txt`: `# T2 — regresión roja: falta claimManagedTaskAdmission (captura)`
- `docs/evidence/agent-work/T2-wrapper-admission.txt`: `# T2 — wrapper de G: test-runtime.sh admission_restart 4/4 (captura)`
- `docs/evidence/agent-work/T2-wrapper-red.txt`: `# T2 — salida roja del ejecutor de G: caso admission_restart sin implementar (captura)`

Los títulos están redactados a partir de lo que `status.md`, `T1.md` y `T2-partial.md` dicen de
cada captura (los conteos 37/37, 7/7, 5/5, 2/2, 4/4, 13/13, 11/11 y los casos `registration_identity`
y `admission_restart` salen de esas citas). Los 20 `.md` de evidencia del rango ya cumplían el
contrato y no se tocaron.
