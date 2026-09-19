# Fase 13 — verificación con lectores frescos

Cinco lectores de contexto fresco ejecutaron el plan de la Fase 13 en su primera
versión (`da26524`) en vez de leerlo, con la skill `lectores-frescos`. Uno por eje:
producto, arquitectura, seguridad, QA y escéptico. Todos en solo lectura, todos
contra `origin/main`.

Resultado: **el plan describía bien los síntomas y se equivocaba en la causa.** La
tarea central proponía construir algo que ya existe ocho veces. Esta es la evidencia
que sostiene la reescritura.

## Lo que mató la premisa

La primera versión decía que "lo único que la flota DG tiene y claw no es un dueño y
un reloj para el mantenimiento", y en Hechos verificados que "los dos crons que
existen son SOLO LECTURA + AVISO". Ese dato salía de contar archivos en `docs/crons/`.

```
$ ~/.openclaw/bin/openclaw cron list --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['jobs']))"
17
```

Ocho de esos 17 son `skill-collection-review-<agente>`, uno por cada agente de
`allowAgents`, semanales (`everyMs: 604800000`), sesión aislada, `toolsAllow` de
`ls, read, write, edit, apply_patch, exec, process`, todos con último run `ok`.

**Los ocho tienen `delivery: null`** y su prompt no contiene ninguna instrucción de
reportar a nadie. Dice "Work only in this directory" y nunca dice a quién avisar.

Y escriben en `agents/<id>/agent/workshop-skills/`, que en el gateway es el clon de
este repo, así que sus cambios entran a `main` por el sync.

## El incidente, con su cron nombrado

```
$ ~/.openclaw/bin/openclaw cron runs 4e8dbbfd-b08a-4eb0-af04-231fb2e22575 --limit 1 --json
runAtIso: 2026-09-18T21:11:08.726-07:00   durationMs: 199298   completionStatus: succeeded
delivered: false   deliveryStatus: not-requested
summary: "…mac-exec-detach-poll: se conserva y se divide… La tabla se movió íntegra a
ENV.md… saikit-cierre-pr: se conserva y se divide… Ningún requisito de decisión se eliminó."
```

El sync de las 01:10 (`a7cd5eb`) trajo eso a `main`, cuatro candados que afirmaban su
regla contra un `SKILL.md` suelto se pusieron rojos, y el repo quedó sin poder recibir
commits durante cuatro horas. El CI lo dijo dos minutos después del último PR verde.
Arreglado en el PR #94.

Verificado que el cron no borró nada: 583 palabras distintas antes, 621 después, cero
del viejo ausentes.

## Hallazgos que cambiaron una tarea

| Lo que decía el plan | Lo medido | Comando |
|---|---|---|
| 13.7: un cron nuevo que corre `verify/` de Orbit desde el gateway | El gateway no tiene clon de Orbit ni de accounting | `sync-repos.ps1:3-8` sincroniza 4 rutas |
| 13.4: `config patch` sobre `allowAgents` con read-back | El CLI `config get/patch` escribe el archivo local de la Mac; `allowAgents` no está authored | `openclaw config get agents.entries.main.subagents.allowAgents` → unset |
| D2: "a `scout` nadie le despacha" | Tiene `skill-collection-review-scout` (`1b3146eb-…`) semanal con permiso de escritura | `cron get 1b3146eb-… --json` |
| 13.1(a): comparar cadenas del doc con `grep` sobre el fuente | Imposible: `lib.ts:274-278` arma una cadena concatenando 5 literales, y dos llevan `${target}` contra `<ruta>` en el doc | 7 cadenas extraídas de los fences, 3 sin coincidencia, solo 1 es deriva |
| 13.1(b): el conteo iguala `grep -c 'api\.on('` | 10 registros, 9 guards numerados, y uno condicional a `diagnosticGuard.mode` | `index.ts:822` |
| 13.5: registrar bloqueos en el jsonl del observador | Ese archivo es una línea por turno y esa igualdad es el divisor de la tasa | `observer.ts:2-8`, `collapseTurns` en `:436-457` |
| 13.6(b): "un `.txt` sin `.md` falla" | Fallan siete archivos hoy, no uno, y el plan no daba convención de apareo | listado de `docs/cron-messages/*.txt` |
| 13.3: puntero versionado al contrato de `ingenieria` | Se compara consigo mismo: queda verde diga lo que diga el otro repo | mutante plantado |

## Verificado y correcto, para no volver a gastarlo

- Las cuatro derivas de la tabla de apertura: `api.on(` = 10, `.sh` = 35, la tanda de
  `tablero-runbook` en `run-checks.sh:60-99`, y la cadena de adversary de `index.ts:497`
  sin "a path absoluto". Las cuatro confirmadas carácter por carácter.
- `bash scripts/run-checks.sh` sale `TODO VERDE` sobre `origin/main`: 35 tests de shell,
  280 casos `node --test` en `summa-gate`, 105 en `tablero-runbook`.
- La mina del aplicador es real y su dirección quedó comprobada: el cron vivo
  `verif-digest-20h` (`c812d541-…`) tiene el prompt **corregido**, idéntico al fence del
  `.md`; el `.txt` que el aplicador manda es el que regresaría el bug.
- `verify/` existe en Orbit y en accounting; Orbit lleva 29 commits en `master` desde
  que `verify/` se tocó por última vez, accounting 0.
- Herramientas presentes en la Mac: `gh 2.98.0`, `python3 3.14.7`, `pwsh 7.7.0-preview.4`,
  `psql 16.15`, `node v26.8.1`. **`docker` no existe**, así que cualquier tarea que pida
  un Postgres desechable tiene que decir cómo.
- El id vivo de `verif-sync-repos`, que el plan daba por `unknown`, es
  `2d763be5-6390-4ccf-a3a4-621c91c41e94`.
- `drive-merge-guard.ts` sale `DRIVE VERDE: 6 casos` con el symlink de `SKILL.md:130-138`
  puesto, y `ERR_MODULE_NOT_FOUND` sin él. `role.test.ts` lo borra en su teardown, así que
  correr la batería antes del driver lo rompe.

## Lo que el lector escéptico dejó abierto

La Fase 9 se planeó un día antes, con la misma forma de cuatro carriles y 14 tareas, y
está entera en `cc:TODO` con un solo PR abierto que cubre 3 de las 14. Las fases que sí
cerraron rápido eran más chicas: la 12 tenía 6 tareas y cerró el mismo día. Por eso esta
reescritura baja de 9 tareas a 7 y no deja cola de optativos. La pregunta de si la Fase 13
compite con la 9 por turnos y agentes sigue abierta y la decide el dueño.

Su veredicto textual sobre la primera versión: "El plan vale la pena".
