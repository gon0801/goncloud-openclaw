# SUA-00, mediciones: lo que ya está medido, lo que falta y el baseline

Fecha: 2026-10-13. Bloque SUA-00, pasos 3 y 4 del
[plan](../../superpowers/plans/2026-10-05-sistema-agentes-unificado.md).
Este documento no corrió nada vivo. Las mediciones pendientes las corre el
coordinador cuando la autorización las cubra. Cada una está marcada
`PENDIENTE-MEDIR`. Inventario que acompaña: [SUA-00-inventario](SUA-00-inventario.md).

## Resumen para David

Hay una medición que ya vale y no se repite: en 30 minutos con un encargo
vivo, nadie gastó inferencia en vigilarlo. Lo que falta medir es cuánto cuesta
despertar a `main` por evento, cuánto contexto carga una sesión nueva frente a
`/new`, y qué pasa si llega un evento mientras `main` está ocupado. Esas tres
cosas deciden qué verbo usa SUA para despertar al controlador. Hasta tenerlas,
no se elige verbo.

## Ya medido, se reutiliza

### Ventana de 30 minutos del 2026-10-11

Fuente: `docs/evidence/agent-work/deploy-receipt.md`, sección "Contadores",
del 2026-10-11 19:44:31Z a las 20:14:37Z.

| Contador | Inicio | Fin |
|---|---|---|
| Eventos de la sesión `agent:main:canario-encargos` | 302 | 302 |
| Eventos de todas las sesiones de `main` | 18356 | 18422 |
| `managed_tasks` | 7 | 7 |
| `managed_task_incidents` | 3 | 3 |
| `managed_task_host_closures` | 7 | 7 |
| Tokens de opencode en el pane `canario` | 41.0K | 41.0K |
| Procesos `openclaw agent` en la Mac | 0 | 0 |
| Crons vigía habilitados | `bids-02-vigia` | `bids-02-vigia` |

Línea literal: "Conclusión: cero inferencia atribuible a vigilar encargos."
Los 66 eventos nuevos de `main` y las 16 llamadas al proveedor fueron todos de
`bids-02-vigia`, un cron cada 5 minutos. Esto vale para la ruta
`main` → `mac-local/opencode` y no se repite (corrección K11 del plan).

### Latencias de B22

Fuente: `docs/evidence/agent-work/B22-canarios.md`.

| Qué | Valor | Dónde |
|---|---|---|
| Pedido a `main` hasta cierre del host en R, canario A intento 2 | 64,8 s | tabla Canarios, "Pasaron 64,8 s entre el `created_at` de la tarea y el cierre del host en R" |
| Reinicio del host hasta `estado` con pid nuevo | menos de 10 s, 4 de 4 veces | "El corte, paso a paso", paso 6 |
| Pasadas del host perdidas por túnel ssh | 4 en el corte, la siguiente reclamó | "En `enc-1/host.log`, 4 pasadas fallaron con `gateway closed (1006 …)`" |
| Intervalo de la pasada del host | 1 s por omisión, tope 5 s | `scripts/agent-work/native_gateway.py:883-887` |

### Consumo por corrida de subagente nativo

Fuente: `docs/evidence/agent-work/limits.json` y `T11-limites-medicion.md`.
Copia consistente de la Mini del 2026-10-09, 1923 corridas de subagente del
2026-09-23 al 2026-10-09.

| Medida por corrida | Mediana | p95 | Máximo |
|---|---|---|---|
| Llamadas al modelo | 5 | 65 | 1440 |
| Tokens de entrada | 112 460 | 3 495 223 | 445 540 546 |
| Tokens de salida | 2 324 | 27 681 | 252 098 |
| Tokens del árbol | 114 248 | 3 514 452 | 445 792 644 |

Profundidad máxima observada 1, hijos simultáneos máximo 2, hijos totales
máximo 4. Los topes de `limits.json` son máximo observado × 10 por decisión de
David (2026-10-10, B8).

### Rondas de revisión del loop de encargos

Fuente: `revision-2026-10-12/decisiones-para-david.md`, punto 1. 81 veredictos:
62 en ronda 1, 15 en ronda 2, 1 en ronda 3 y ninguno más arriba. Ningún tope
entre 3 y 5+5 habría cambiado nada.

## Baseline de coste y latencia del ciclo actual

Lo que se puede afirmar con recibos. Lo que no, dicho como tal.

| Dimensión | Baseline | Fuente | Qué no se puede medir |
|---|---|---|---|
| Vigilancia de un encargo por CLI | 0 llamadas al proveedor en 30 min | deploy-receipt.md, Contadores | nada |
| Vigilancia de un loop de claw con vigía | 16 llamadas al proveedor en 30 min, unas 32 por hora, unas 768 por día | deploy-receipt.md, Contadores | tokens por llamada del vigía. `provider.payload.measured` los guarda en la Mini. `PENDIENTE-MEDIR` M-04 |
| Latencia pedido → resultado cerrado, ruta por CLI | 64,8 s para un encargo de un archivo | B22-canarios.md | latencia de un encargo real de ingeniería. Ningún loop real corre por la ruta |
| Latencia pedido → resultado, ruta nativa | `unknown` | n/a | `subagent_runs` guarda árbol y tiempos, no se extrajo la duración en T11. `PENDIENTE-MEDIR` M-05 |
| Coste en dinero | `unknown` | n/a | todos los proveedores de la ruta por CLI cobran por suscripción salvo deepseek (`proveedores-permitidos.json`, `billing`). No hay tarifa por token que multiplicar |
| Rondas de corrección por bloque | 1 ronda en 62 de 81 veredictos | decisiones-para-david.md | el coste en tokens de una ronda. No se midió |
| Despertar por evento | `unknown` | n/a | `PENDIENTE-MEDIR` M-01 a M-03 |

## Pendiente de medir

Cada fila tiene un comando de solo lectura o sobre una sesión de ensayo propia,
el número que sale y la decisión que depende de él. Nada de esto se corre desde
G ni desde este bloque. Las sesiones de ensayo se llaman
`agent:main:sua-ensayo-<fecha>-<n>` y se borran al terminar (M-08).

| ID | Pregunta | Comando o procedimiento | Número que sale | Decisión que depende | Estado |
|---|---|---|---|---|---|
| M-01 | Latencia de un despertar por evento con el gateway ocioso | Con ningún turno de `main` en vuelo: `openclaw system event --mode now --timeout 15000 --session-key agent:main:sua-ensayo-<f>-1 --text "ensayo SUA-00 M-01: contesta NO_REPLY"`. Medir desde la emisión hasta el primer evento de la sesión en la base del agente | segundos hasta el inicio del turno, y tokens de ese turno | Verbo de despertar del controlador: `system event`, `agent --message` o cron con sesión durable | PENDIENTE-MEDIR |
| M-02 | Qué pasa con un evento si `main` está ocupado | Mandar M-01 mientras `bids-02-vigia` tiene un turno en vuelo (verlo con `openclaw cron runs`). Comparar: ¿se encola, se pierde, o abre otro turno? | 0 o 1 turno adicional; tiempo de espera | Si el controlador necesita sesión propia distinta de la de `main` | PENDIENTE-MEDIR |
| M-03 | Contexto base de una sesión nueva frente a `/new` | Un turno vacío en `agent:main:sua-ensayo-<f>-2` (sesión nueva) y otro en una sesión existente después de `/new`. Leer tokens de entrada de `provider.payload.measured` de cada uno | tokens de entrada de cada turno | Si cada reconciliación abre sesión propia o reutiliza una con `/new` | PENDIENTE-MEDIR |
| M-04 | Tokens de un despertar vacío | Un turno que solo corre `managed_tasks_inspect` sobre una tarea cerrada y contesta `NO_REPLY` | tokens de entrada y salida | Cadencia del latido sin modelo frente a con modelo; cuánto cuesta cada vigía de 5 min | PENDIENTE-MEDIR |
| M-05 | Latencia pedido → resultado por ruta nativa | Consulta de solo lectura sobre una copia de la Mini: `subagent_runs` con `created_at` y fin, mediana y p95 | segundos, mediana y p95 | Baseline nativo frente a los 64,8 s de la ruta por CLI | PENDIENTE-MEDIR |
| M-06 | `NO_REPLY` y Telegram | Después de M-01: ¿la sesión de ensayo mandó algo a Telegram? Leer la base de la sesión, no el teléfono | 0 o más mensajes salientes | Si el aviso consolidado necesita filtro propio | PENDIENTE-MEDIR |
| M-07 | Aislamiento del solicitante | Confirmar en vivo lo que dice `managed-task.turn.ts:42-44`: un cron isolated que llame `managed_tasks_submit` recibe "Managed task requires a durable requester session". Usar un cron de ensayo propio y borrarlo | 1 rechazo literal | Qué sesión usa el controlador: nunca un cron isolated | PENDIENTE-MEDIR |
| M-08 | Borrado remoto de sesiones de ensayo | Desde la Mac: `openclaw sessions delete --session-key agent:main:sua-ensayo-<f>-<n>` por cada una. Memoria del proyecto: desde la Mac el delete va sin `--agent` | 0 sesiones `sua-ensayo-*` al final | Higiene; sin esto las sesiones de ensayo engordan la memoria del gateway | PENDIENTE-MEDIR |
| M-09 | Crons vivos hoy | `openclaw cron list --json` | lista de crons y cuáles son `*-vigia` | Alinear `coverage.json.modelWakes` (foto del 2026-10-07) y la lista de entradas que SUA-09O corta | PENDIENTE-MEDIR |
| M-10 | Memoria del gateway antes y después de los ensayos | `openclaw health --json` y la métrica de heap que da el gateway, antes de M-01 y después de M-08 | MB de heap | Si los ensayos dejan basura; memoria del proyecto: el aviso salta al 50 % del heap | PENDIENTE-MEDIR |

Regla para elegir el verbo: se elige con M-01, M-02 y M-04 en la mano, no por
preferencia. Si M-02 muestra que un evento se pierde con `main` ocupado, el
controlador no puede vivir en la sesión de `main`.

## Lint y formato de R

Leído en `/Users/dn/dev/openclaw-agent-work-integration` en `4acb881e015a`.
No se corrió nada sobre R.

| Qué | Comando literal | Herramienta | Configuración |
|---|---|---|---|
| Formato | `pnpm format:check` → `oxfmt --check` (`package.json:1814`) | oxfmt 0.68.0 | `.oxfmtrc.jsonc`: ancho 100, comillas dobles, punto y coma, coma final `all`, ordena imports, ignora `**/*.json` |
| Lint | `pnpm lint` → `node --import ./scripts/tsx.mjs scripts/run-lint.mts` (`:1849`) | oxlint 1.83.0 con oxlint-tsgolint 7.0.2002, más stylelint y una verificación i18n (`scripts/run-lint.mts:10-41`) | `.oxlintrc.json` y `config/oxlint/` |
| Tipos | `pnpm tsgo:core` → `node scripts/run-tsgo.mjs -p tsconfig.core.json --incremental ...` (`:2197`) | tsgo, typescript 7.1.0-dev | `tsconfig.core.json` |
| Pruebas | `node scripts/run-vitest.mjs <archivo> --testNamePattern <caso>` | vitest 5.0.1 | `vitest.config.ts`, `test/vitest/` |
| Pre-commit de R | `scripts/pre-commit/run-node-tool.sh oxlint --type-aware src test` y `... oxfmt --check src test` (`.pre-commit-config.yaml:87-97` de R) | los mismos | |
| CI de R | job `check-shard` corre `pnpm lint` y `pnpm format:check` (`.github/workflows/ci.yml:5034`, `:5040-5042`); `check-lint-core-<stripe>` corre `scripts/run-oxlint-shards.mts --only=core --split-core` (`:5245-5246`) | | Si ese CI corre para la rama `feat/agent-work-integration`: `unknown`, depende de `github.repository == 'openclaw/openclaw'` |

Un bloque que escriba en R corre `pnpm lint:core`, `pnpm format:check` y
`pnpm tsgo:core` sobre sus archivos antes del commit, como ya hicieron B4 a B18
(`docs/evidence/agent-work/B4-*-tsgo-core.log`).

## Alcance de lint y formato para los módulos nuevos de G

G no tenía lint ni formato de Python: ni `pyproject.toml`, ni `ruff.toml`, ni
hook, ni paso en CI. La única validación era correr las pruebas `unittest` por
sus envolturas `.sh`. SUA-00 deja configurado el alcance para lo nuevo sin tocar
el legado:

- `ruff.toml` en la raíz con `include` limitado a `scripts/sistema_agentes/**/*.py`
  y `scripts/tests/test-sistema-agentes-contrato.py`, `target-version = "py39"`
  y `line-length = 100`. Un archivo fuera de `include` no se revisa ni se
  reformatea.
- Hooks `ruff` y `ruff-format` en `.pre-commit-config.yaml`, con `files`
  limitado a esas mismas rutas. `pre-commit run --all-files ruff` no toca ningún
  archivo legado.
- Cada módulo nuevo que SUA cree en G entra al `include` en el mismo PR que lo
  crea. El legado (`scripts/agent-work/`, `scripts/mac/corrida_worker/`) entra
  solo cuando un bloque lo migre y lo diga en su recibo.

La corrida que lo prueba está en [SUA-00-mutaciones](SUA-00-mutaciones.md),
sección final.
