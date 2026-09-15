# Ruteo ingenieria vs cadena · medición del audit (6.0b)

Fecha de medición: 2026-09-15. Medidor (fila 6.0b de Plans.md): `openclaw audit --kind agent_run --limit 500 --json`, solo lectura, corrido en esta Mac (host del gateway remoto).

Comando exacto:

```
~/.openclaw/bin/openclaw audit --kind agent_run --limit 500 --json
```

Exit code: 0. Payload�� inspectado: 500 eventos.

## Resultado: unknown (la ventana del CLI no alcanza)

El CLI devuelve **solo metadatos** de cada run (`occurredAt`, `agentId`, `sessionKey`, `action`, `status`); no trae payload de qué hizo el run (tócó repo, qué archivos, si abrió PR). Y el tope de 500 eventos cubre **solo ~7.4 horas** (2026-09-15 07:43 → 15:03, hora local de la Mac), no las 2–4 semanas pedidas por la fila.

Con esa ventana y ese payload **no se puede pesar** cuántos despachos de main a ingenieria fueron cambios de repo ni cuántos terminaron en PR. Se declara `unknown`, con el tope del CLI como razón, tal como la DoD pide ("si el audit no cubre la ventana, se escribe unknown con el límite del CLI, no 0").

## Lo que sí alcanza a ver la ventana (informativo, no concluyente)

| Fecha (2026-09-15, hora local Mac) | Despacho | ¿Tocó repo? | ¿PR? |
|---|---|---|---|
| 07:43 → 15:03 (ventana completa) | main → main: 233 runs started, 226 succeeded, 6 failed, 4 cancelled | unknown | unknown |
| 07:43 → 15:03 (ventana completa) | main → ingenieria (`sessionKey` `agent:ingenieria:*`): 16 runs started, 10 succeeded, 1 cancelled | unknown | unknown |
| 07:43 → 15:03 (ventana completa) | main → operaciones: 1 run started, 1 succeeded | unknown | unknown |
| 07:43 → 15:03 (ventana completa) | main → openclaw (plugin): 1 run started, 1 succeeded | unknown | unknown |

Lectura honesta: la mayoría de los runs de la ventana son turnos de main hacia sí misma (respuestas/coordina), no despachos a la cadena ni a ingenieria. Pero el evento `agent_run` no dice si un run tocó repo o abrió PR, y la ventana no llega a 2 semanas.

## Consecuencia para la regla (a) de 6.1

Dado que la fila deja la medición como condicional ("Si 6.0b muestra que la mayoría de los cambios de repo son de una sola edición, la regla (a) lleva ese umbral escrito"), y que la medición quedó `unknown`, **la regla (a) va sin umbral**. El "PR chico contra A con el umbral" queda como decisión prevista: si una medición posterior (auditoría con mayor ventana o payload más rico) muestra que la mayoría de los cambios de repo son ediciones únicas, se abre ese PR aparte contra goncloud-workspace-main con su propio loop de cross-review. No se abre en esta corrida.

Nota sobre el payload: la redacción del audit es `metadata_only` por diseño (`redaction: metadata_only` en cada evento); el tope del CLI es `--limit 500`. Un intento de deducir "¿tocó repo?" a partir del `sessionKey` no discrimina ediciones de consultas: un run de main puede leer el repo sin tocarlo.
