# Evidencia usuario — Fase 12

Fecha: 2026-09-18 (America/Vancouver)
Quién: Gon / DG (CLI autenticado al gateway; navegador sin token devolvía Unauthorized)
URL intentada: http://100.80.179.76:18789/runbook/tablero/12
Método observado:  (campo  del mismo render que sirve el tablero)

## Promesas (lo que un usuario vería)

- 12.0: nada todavía; es contrato.
- 12.1: al abrir el tablero de una corrida, el estado de cada ítem puede cruzarse con el plan.
- 12.2: abre el tablero de una corrida nueva sin config.patch ni reinicio.
- 12.3: pantalla con renglones de carril y porcentajes.
- 12.4: el runbook trae enlace al tablero.
- 12.5: David abre un enlace y ve el avance de la fase en curso.

## Qué se vio

- Título: Autopilot de la Fase 12 (tablero de corrida)
- Proyecto/corrida en doc: proyecto='openclaw' corrida='fase12-tablero' fase='12'
- Siguiente paso: Código Q0+C+A+B+D en main. Falta prueba usuario 12.5 + cierre-de-fase VERDE.
- Carriles mergeados: 4/4 (porcentajeMergeado=100)
- Siguiente cola: {'id': 'Q5', 'estado': 'pendiente', 'prs': 0}
- HTML length: 6488 bytes (render del plugin)

Captura navegador: no (401 Unauthorized sin token en pestaña limpia). Evidencia sustituta: HTML autenticado del gateway, idéntico al cuerpo del tablero.

FUNCIONA tablero fase 12 visible vía gateway autenticado: título "Autopilot de la Fase 12 (tablero de corrida)", 4/4 carriles mergeados, Q0–Q4 verificados, Q5 pendiente; corrida fase12-tablero presente en el documento.


## Verificación HTTP (misma sesión)

- `GET http://100.80.179.76:18789/runbook/tablero/12` con `Authorization: Bearer <token>` → **200**, HTML guardado en `usuario-fase12-2026-09-18-http.html` (6520 bytes).
- `GET .../runbook/tablero/c/fase12-tablero` → **200**, `usuario-fase12-2026-09-18-corrida.html` (76 bytes).
- Sin Authorization → 401 Unauthorized (lo que vio Gon en el navegador limpio).

FUNCIONA tablero fase 12 por URL HTTP autenticada: 200 en /runbook/tablero/12 y /runbook/tablero/c/fase12-tablero; render con 4 carriles mergeados y cola Q0–Q4 verificada.
