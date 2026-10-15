# Plan de prueba del importador

## Resumen

| Filas | Estado |
|---|---|
| 7.4 | cerrada antes de la tabla de abajo |

| Task | Contenido | DoD | Depends | Status |
|------|-----------|-----|---------|--------|
| 7.1 | `[lane:fast] [tdd:required]` **Medir el tiempo de arranque.** El host anota cuándo empieza. | El log trae la hora de arranque; una prueba lo lee | - | cc:完了 |
| 7.2 | `[lane:gate]` **Guardar el arranque en la base.** Una tabla nueva. | La tabla existe en la base nueva; la base vieja abre igual. Su prueba falla sin la tabla | 7.1 | cc:TODO |
| 7.3 | **Mostrar el arranque en el tablero.** | El tablero muestra la hora | 7.2, 7.1 | cc:TODO |
| 7.4 | **Una fila abierta que nadie eligió.** | Algo pasa | - | cc:TODO |
| 7.5 | **Depende de una abierta.** | Otra cosa pasa | 7.4 | cc:TODO |
| 7.6 | **Una celda con una barra.** | `a \| b` imprime dos columnas; la prueba lo lee | 7.1 | cc:TODO |
| 7.7 | **Una barra sin escapar.** | `a | b` parte la celda | - | cc:TODO |
| 7.8 | **Depende de un rango.** | El rango cuenta | 7.1–7.2 | cc:TODO |
| 7.9 | **Depende con punto y coma.** | El punto y coma separa | 7.1; 7.2 (implementación) | cc:TODO |
| 7.10 | **Depende de algo que no es una fila.** | Nada se pierde | 7.2 y autorización de David | cc:TODO |
| 7.11 | **Rango que abarca un id repetido.** | El rango lo incluye | 7.1–7.5 | cc:TODO |
| 7.12 | **Rango cuyo extremo salió en una resumen.** | No reviente | 7.2–7.4 | cc:TODO |
