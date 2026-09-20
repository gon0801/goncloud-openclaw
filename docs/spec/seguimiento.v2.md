# seguimiento.v2 — reporte consolidado de 30 minutos

Fecha: 2026-09-20. Estado: activo desde que se mergea. Define el mensaje que
David recibe cada 30 minutos mientras haya trabajo activo. Conserva las
etiquetas y las tres preguntas de `seguimiento.v1`, pero permite bloques de
porcentaje entre el encabezado y esas preguntas. `seguimiento.v1` queda solo
para avisos inmediatos de cuatro líneas y registros viejos.

## Forma (v2)

```text
[AVANZA] Fase 14 — 46% (6/13 tareas)

Implementación — 75% (3/4)
Muse está corrigiendo el último caso del vigilante.

Revisión — 33% (1/3)
La primera revisión terminó; faltan la revisión cruzada y CodeRabbit.

Cierre — 0% (0/2)
Todavía no comienza.

Que cambió:
Se completó la detección de sesiones terminadas.

Que sigue:
Terminar la corrección y comenzar la revisión.

Que necesito de ti:
nada.
```

## Reglas

- El encabezado muestra porcentaje y fracción. La fracción permite auditar el
  porcentaje redondeado. Los porcentajes salen de las unidades del plan
  (`resumirSeguimiento`); ningún modelo los estima.
- Si hay varias fases activas, el mismo mensaje trae un bloque por fase y un
  solo bloque de preguntas al final. No se crea un cron por agente ni un
  mensaje por carril.
- Aparecen los carriles no omitidos del corte: activos, pendientes, atorados
  y terminados. Un carril `omitido` (trabajo cancelado) nunca se imprime. Una
  fase grande no vuelca su tabla entera: quien arma el insumo pasa solo los
  carriles del corte.
- Un plan no verificable se escribe `desconocido`, nunca `0%`.
- `Que cambió` compara contra el último reporte enviado, no contra el inicio
  de la fase.
- `Que sigue` nombra la siguiente unidad verificable.
- `Que necesito de ti` es `nada` salvo cuando la etiqueta es
  `NECESITO TU RESPUESTA`.
- Si no hubo cambio durante la ventana, el reporte de 30 minutos sale igual
  porque confirma que el trabajo continúa. Dice cuánto tiempo lleva la unidad
  actual (minutos enteros desde `actividad.iniciadaEn`) y cuál fue la última
  evidencia observada; nunca dice "nada nuevo".
- Lenguaje para el propietario: sin rutas, ramas, hashes, números de PR,
  flags, siglas ni acentos graves.

## Implementación

`tablero-runbook/seguimiento-render.ts` (`renderSeguimientoV2`): puro, sin
I/O. Rechaza el insumo vacío y las marcas de tiempo inválidas. Los casos
viven en `tablero-runbook/seguimiento-render.test.ts`, incluido el ejemplo
aprobado byte por byte.
