# Plan de prueba del importador

| Task | Contenido | DoD | Depends | Status |
|------|-----------|-----|---------|--------|
| 7.1 | `[lane:fast] [tdd:required]` **Medir el tiempo de arranque.** El host anota cuándo empieza. | El log trae la hora de arranque; una prueba lo lee | - | cc:完了 |
| 7.2 | `[lane:gate]` **Guardar el arranque en la base.** Una tabla nueva. | La tabla existe en la base nueva; la base vieja abre igual. Su prueba falla sin la tabla | 7.1 | cc:TODO |
| 7.3 | **Mostrar el arranque en el tablero.** | El tablero muestra la hora | 7.2, 7.1 | cc:TODO |
| 7.4 | **Una fila abierta que nadie eligió.** | Algo pasa | - | cc:TODO |
| 7.5 | **Depende de una abierta.** | Otra cosa pasa | 7.4 | cc:TODO |
