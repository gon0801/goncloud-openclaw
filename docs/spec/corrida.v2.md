# corrida.v2 — registro de una corrida autónoma con reloj global

Fecha: 2026-09-20. Estado: activo desde que se mergea. Extiende
[corrida.v1.md](corrida.v1.md): el validador lee las dos versiones; v1 sigue
aceptándose para registros viejos y para la migración.

## Qué cambia

`corrida.sh abrir` ya no crea un cron hombre-muerto `corrida-vigia-<id>` por
corrida. El único reloj es el `avance-tareas` global del director (cada
15 minutos, corte consolidado cada 30). El registro declara
`seguimiento_global:true` y no trae `cron_vigia_id`.

## Forma (v2)

Igual que v1, salvo:

| Campo | Qué es |
|---|---|
| `schema` | Siempre `corrida.v2` |
| `seguimiento_global` | Siempre `true`: esta corrida reporta por el reloj global |
| `cron_vigia_id` | Ausente. Su presencia es rojo |

El validador (`validar_registro` en `scripts/mac/corrida/lib.sh`) acepta
exactamente: v1 con `cron_vigia_id` no vacío, o v2 con `seguimiento_global`
en `true` y sin `cron_vigia_id`. Cualquier otra combinación es
`ROTO` con su motivo.

## Mensajes por etiqueta (`corrida_mensaje`, caso cerrado)

- `ABIERTA`: entrega inmediata y silenciosa al abrir la corrida (`corrida.sh
  abrir`), con su fila en `mensajes.jsonl`. Es la única forma de avisar que
  una corrida arrancó — antes de esto solo el cierre avisaba.
- `AVANZA`: valida contra `seguimiento.v1` y acumula
  `{at,cambio,sigue,necesito}` en `eventos-seguimiento.jsonl` (600, append
  atómico) para el próximo corte global. No llama a `message send` ni anota
  entrega en `mensajes.jsonl`. Así ningún llamador viejo se salta el
  consolidador de 30 minutos.
- `NECESITO TU RESPUESTA`, `DETENIDA`: entrega inmediata por `seguimiento.v1`
  con su fila en `mensajes.jsonl`, con notificación (no `--silent`).
- `CERRADA`: entrega inmediata y silenciosa, con su fila en `mensajes.jsonl`.
- Otra etiqueta: falla cerrada, no acumula ni manda.

Cada mensaje lleva en la línea 1 el nombre de la corrida (título del runbook,
o el `id`) y la hora en que abrió, más un prefijo: `▶️ ` en una corrida real,
`🧪 PRÁCTICA — no contestes ` si `simulacro:true`. En una corrida de práctica,
`NECESITO TU RESPUESTA` nunca pide una decisión real: el texto queda fijo
avisando que es una pregunta de práctica que se resuelve sola, sin el
`Comando: ` de referencia. Ver `docs/spec/seguimiento.v1.md`.

## Inventario (`corrida.sh seguimiento --json`)

Solo lectura: no escribe archivos ni llama a la red. Devuelve
`{schema:"corrida-seguimiento.v1", corridas:[...], errores:[...]}` con las
corridas abiertas v1/v2 válidas (`trabajoId` estable `corrida:<id>`, `id`,
`inicio`, `estado`, `runbook` y la última actividad válida acumulada). Las
cerradas se omiten. Un registro malformado no desaparece: su ruta sale en
`errores`. Del acumulado se lee el último evento válido; si la última línea
está malformada, su ruta sale en `errores` y se retrocede al válido anterior
(sin ninguno, actividad `null`). El director reconcilia cada `corrida:<id>`
con el mismo `trabajoId` de `runbook.progress.list`; una corrida abierta sin
documento de progreso queda visible como `desconocido`.

## Migración (`corrida.sh migrar-seguimiento --dry-run|--apply`)

`--dry-run` lista registros e ids legados sin mutar nada. `--apply` exige
antes de mutar exactamente un `avance-tareas` habilitado a cadencia de
15 minutos (`schedule.kind:"every"`, `everyMs:900000`); faltante, apagado,
duplicado, mal-cadencia o lista ilegible paran toda la migración sin tocar
ningún registro v1. Luego quita cada cron legado por id, verifica su
ausencia y reescribe ese registro a v2 de forma atómica bajo lock. Un fallo
deja ese registro v1 y el parcial se reporta (salida distinta de cero). Una
segunda corrida sin v1 es no-op verde.

## Cierre y arranque

`corrida.sh cerrar` quita el cron legado exacto solo en v1; en v2 nunca toca
el reloj compartido. En ambos caminos conserva la limpieza de marcas por
dueño (PR #104). `scripts/arranque-de-fase.sh` exige `avance-tareas` a
15 minutos más `corrida-empuje-<fase>`; `--solo-watchdog-global` omite solo
el empuje propio. Ambos modos rechazan un `corrida-vigia-<fase>` todavía puesto.
`scripts/cierre-de-fase.sh` rechaza el vigía legado y solo
pide ausente el reloj global cuando su scratch dice que no queda otro
trabajo activo (el scratch se lee por UUID, nunca por nombre).

## Campos opcionales de ruteo nativo (Fase 14.1)

Una corrida v2 puede traer estos campos; todos son opcionales y su
ausencia total deja un registro legado válido (`seguimiento_global:true`,
sin `cron_vigia_id`, v1/v2 legibles, reloj global intacto). No se crea
otro esquema v2 ni vuelve el cron por corrida.

| Campo | Qué es |
|---|---|
| `workers_registry` | Ruta del registro `workers.v1` que usa la selección |
| `automatic_routing` | Objeto con `enabled` (booleano): ruteo automático o flujo legado |
| `lanes` | Carriles con `worker`, rol, worktree y sesión |
| `effects` | Efectos externos ya ejecutados (para no repetirlos al reanudar) |
| `evidence` | Evidencia de compuertas por SHA (revisión, CI, CodeRabbit, merge, deploy, canary) |
| `outcome` | Resultado global (`open` mientras hay trabajo pendiente) |
| `authorization_ref` | Referencia a la preaprobación del dueño que ampara el merge automático |

`authorization_ref` sigue opcional para registros legados y de solo
lectura; la Task 7 lo exige, lo resuelve contra la tabla versionada de
preaprobaciones y falla cerrada cuando falta, es desconocido, no está
aprobado o queda fuera de alcance, antes de cualquier merge automático.
