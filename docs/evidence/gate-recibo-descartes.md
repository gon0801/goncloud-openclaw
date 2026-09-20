# Gate de recibo - descartes medidos (Fase 1 / 1.1)

> Que un agente no le haga perder una noche a David concluyendo "no se puede"
> sin haberlo intentado. Plans.md F.1, Hallazgo alto #6 del adversary.

## Resumen

- N=5 corridas, todas el 2026-09-12, ventana total observada: ~50 min
  cronologicos del archivo de log.
- Lineas buscadas (ancladas a timestamp ISO-8601, *lineas reales de log*):
  - `summa-gate: revise solicitado` (cuenta: 0/5)
  - `before_agent_finalize requested revision after potential side effects`
    (cuenta: 0/5)
  - `summa-gate: cierre limpio` (cuenta: 0/5)
- Cociente descartados / solicitados: **indefinido** (denominador 0).
- Conclusion honesta: **unknown**. El plan lo dice textual:
  `not_observed != absent`. 5 muestras sin observar no prueban que el fenomeno
  no exista; prueban que, en mi ventana, el gate no pidio revise y por tanto
  tampoco hubo descartes de revise en el runtime.

## Recuento por corrida

| run | timestamp pull | ventana efectiva (1a-ult linea timestamp) | revise solicitado | revise descartado | cierre limpio |
|---|---|---|---|---|---|
| 1 | 20260912T114350 | 2026-09-12T11:05:34.926 -> 2026-09-12T11:43:47.278 (~38 min) | 0 | 0 | 0 |
| 2 | 20260912T114355 | 2026-09-12T11:43:51.116 -> 2026-09-12T11:43:55 (~4 s)   | 0 | 0 | 0 |
| 3 | 20260912T115348 | 2026-09-12T11:53:48.193 -> 2026-09-12T12:05:37.884 (~12 min) | 0 | 0 | 0 |
| 4 | 20260912T120538 | 2026-09-12T12:05:37.538 -> 2026-09-12T12:05:37.884 (~250 ms, buffer corte) | 0 | 0 | 0 |
| 5 | 20260912T120544 | 2026-09-12T12:05:40.039 -> 2026-09-12T12:05:40.039 (~50 ms, buffer corte) | 0 | 0 | 0 |

Ventanas efectivas chicas en runs 2/4/5 son el resultado del cap de
`--max-bytes=250000` de la CLI, no inactividad del gateway: el buffer se corta
por tamano antes que por tiempo.

## Limitacion de la CLI (afecta toda la observacion)

El plan asumia `openclaw logs --limit 5000 --max-bytes 900000` (~45 min por
corrida). La CLI acepta `--limit 200` y `--max-bytes 250000` como techo, sin
flag publico que los suba. Documentacion de OpenClaw: `cli/logs`. Implicancia:

- Si el ritmo de escritura al log es alto, una corrida cubre mas ventana
  cronologica; si es bajo, cubre segundos.
- En este host, runs 2/4/5 muestran ventanas <1 s pese a tener 179-204 lineas
  utiles del log. La cantidad de lineas no es la ventana cronologica.

Para atacar esta limitacion sin cambiar el metodo:

- **Opcion A**: reejecutar `openclaw logs` muchas veces durante el dia y
  registrar el timestamp del primer evento del pull. Esto ampliaria N pero no
  la ventana por corrida; sigue siendo ineficiente para una conclusion a 3
  dias.
- **Opcion B**: leer el archivo de log directo
  (`C:\Users\ehven\AppData\Local\Temp\openclaw\openclaw-2026-09-12.log`) desde
  un exec gateway-side. Esto saca el techo de la CLI pero deja de ser "el plan
  literal". Requiere visto bueno explicito (no se hace en este PR).

## Falso positivo que hubo que descartar (anotado para el siguiente)

El primer conteo no anclado a timestamp me dio revise=1/descartado=1 en
runs 4 y 5. Causa: la CLI devuelve dentro del buffer tanto lineas de log
reales como texto de los turnos en curso. Las dos lineas que matchearon
correspondian a **mi propio texto de assistant** del turno previo (lineas 108
y 105 de los pulls 4 y 5), que nombra las dos cadenas del DoD para describir
la medicion. Anclando los greps al formato `^[0-9]{4}-[0-9]{2}-[0-9]{2}T...`
el conteo cae a 0/0/0 en los cinco pulls. Regla para el siguiente run que
mire estas dos lineas: **siempre anclar el grep a ISO-8601 timestamp**; el
`grep -c` plano sobre el archivo entero es propenso a este falso positivo.

## Conclusion

- El hallazgo alto #6 del adversary ("el revise se descarta cuando hubo side
  effects") no se manifiesta en mi ventana. Eso no lo refuta, pero tampoco lo
  activa.
- 1.2 (declarar el alcance real del gate en `summa-gate/index.ts:415-489`)
  sigue valiendo aunque el cociente no se haya podido calcular: la limitacion
  estructural del mecanismo (descartar revise con side effects) sigue siendo
  cierto por lectura del runtime, independientemente de cuantos turnos la
  padezcan.
- 2.2 sigue siendo el medidor con base suficiente para reabrir Fase 4. 1.1
  era una sonda, no la medicion principal.

## Proximo paso

- Cerrar 1.1 hoy con este archivo + 5 crudos en
  `docs/evidence/gate-recibo-logs-*.txt`.
- Pasar a 1.2: editar `summa-gate/index.ts` para declarar el alcance real del
  gate (con cita del runtime, sin cambiar comportamiento) y agregar prueba en
  rojo contra `origin/master`.
