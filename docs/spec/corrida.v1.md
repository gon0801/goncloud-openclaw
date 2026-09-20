# corrida.v1 — registro de una corrida autónoma

Fecha: 2026-09-18. Estado: activo desde que se mergea (Fase 9, 9.1).

## Para qué

Un vigía puede perder la memoria a media corrida (compactación, `/new`, reinicio de
sesión). El registro es lo que lo reorienta: quién es el vigía, qué sesiones son suyas,
qué se preaprobó, con qué tabla de modos se lanzaron, a dónde van los mensajes. Ninguna
pieza depende de lo que el agente recuerde.

## Dónde vive

`~/.local/state/corridas/<id>/registro.json`, fuera del repo, porque trae el destino de
los mensajes. Directorio con permisos 700, archivos con 600. Lo escribe `corrida.sh abrir`
y lo leen todos los subcomandos (9.2): ningún subcomando lee del entorno lo que el
registro ya dice.

## Forma (v1)

| Campo | Qué es |
|---|---|
| `schema` | Siempre `corrida.v1` |
| `id` | Identificador de la corrida (p. ej. `simulacro-9`) |
| `runbook` | Ruta del runbook que manda, dentro del repo |
| `vigia` | Cerrado: `claw` o `hermes`. Cualquier otro valor es rojo |
| `simulacro` | `true` si es simulacro: `corrida_mensaje` antepone `[SIMULACRO] ` |
| `canal.cron` | Nombre del cron existente del que `abrir` leyó el destino; el destino resuelto vive solo aquí, jamás en el repo ni en entorno |
| `canal.destino` | El destino de entrega resuelto de ese cron; el validador lo exige (`ROTO:sin canal.destino`) |
| `cron_vigia_id` | El `id` que devolvió `cron add --json` al crear el hombre-muerto; `cerrar` lo quita por ese id y falla ruidosamente si no puede |
| `cli_modos` | Ruta de la tabla de modos que usa esta corrida (por defecto la instalada) |
| `inicio` | Cuándo se abrió, con zona horaria |
| `timebox_horas` | 6 por carril; vuelve a 6 completas al salir de un diálogo |
| `sesiones[]` | `nombre`, `rol` (`lead` o `carril`, siempre presente), `cli`, `dueno`, `dir` |
| `preaprobaciones[]` | `patron` + `decision` (`Aprobado` o `Negado`); lo no casado escala |
| `estado` | `abierta` o `cerrada` |

Ejemplo válido y mutaciones en `scripts/tests/fixtures/corrida/registro-*.json`;
el validador vive en `scripts/mac/corrida/lib.sh` y la prueba 9.1 lo carga por source.

## Ciclo de vida de las marcas

`corrida.sh lanzar-sesion` serializa la creación, las marcas y el registro con el
mismo lock global que usa la reconciliación. Publica `OPENCLAW_WATCH_RUN=<id>`
antes de activar `OPENCLAW_WATCH=1` y conserva el lock hasta registrar la sesión.
Así una limpieza decidida sobre una sesión vieja no puede caer sobre otra que
reutilizó el mismo nombre. Cuando
un carril termina, el vigía ejecuta `corrida.sh terminar-sesion <id> <sesion>`:
retira solo esa marca, deja la sesión abierta y no toca su worktree. La operación
es idempotente y rechaza sesiones que no pertenezcan al registro indicado.

`corrida.sh cerrar <id>` conserva el barrido final de todas las sesiones de la
corrida. Como reparación conservadora, `corrida.sh reconciliar-marcas` retira las
marcas cuyo único dueño registrado es una corrida cerrada. Si una corrida abierta
también reclama la sesión, o no hay dueño conocido, la marca se conserva para que
el operador decida; la reconciliación nunca mata sesiones ni borra worktrees.
