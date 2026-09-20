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

- `AVANZA`: valida contra `seguimiento.v1` y acumula
  `{at,cambio,sigue,necesito}` en `eventos-seguimiento.jsonl` (600, append
  atómico) para el próximo corte global. No llama a `message send` ni anota
  entrega en `mensajes.jsonl`. Así ningún llamador viejo se salta el
  consolidador de 30 minutos.
- `NECESITO TU RESPUESTA`, `DETENIDA`, `CERRADA`: entrega inmediata por
  `seguimiento.v1` con su fila en `mensajes.jsonl`, como siempre.
- Otra etiqueta: falla cerrada, no acumula ni manda.

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
15 minutos más `corrida-empuje-<fase>` y rechaza un `corrida-vigia-<fase>`
todavía puesto. `scripts/cierre-de-fase.sh` rechaza el vigía legado y solo
pide ausente el reloj global cuando su scratch dice que no queda otro
trabajo activo (el scratch se lee por UUID, nunca por nombre).
