# Estado de implementación de encargos

Bloque activo: B1 en integración; T4 se prepara en una rama posterior aislada. B0 terminó con el recibo `T0.md`. La base de B1 está fijada en `block-bases.json`. T1, T2 y T3 tienen implementación nativa aislada, aún sin cierre del bloque.

La fuente de OpenClaw 2026.9.7 está en un checkout aislado. La deduplicación del gateway tras reinicio necesita ampliación nativa. La admisión productiva permanece deshabilitada.

El build aislado terminó y su entrypoint coincide por SHA-256 con el instalado. La prueba de gateway con proveedor falso confirmó una segunda admisión tras reinicio.

En el SHA final de B0 de R (`00e289c344af4cff10aafbf7b7f807822b54fa77`), `pnpm build` terminó correctamente ([log](B0-source-final-build.txt)) y `test-runtime.sh baseline` pasó 37/37 más la reproducción de dos admisiones tras reinicio ([log](B0-source-final-baseline.txt)). El gateway de ensayo y sus descendientes terminaron. La batería nativa amplia que empezó sobre el SHA anterior se detuvo al detectar dos fallos de UI ya corregidos; no se cuenta como evidencia final de B0.

En R, `e2eaae212c` reúne T1–T3 y la prueba de la cola del solicitante tras reinicio. Pasaron 16 pruebas focalizadas de almacén, admisión, consumo y lanzamiento, además de los tres escenarios E2E `idle`, `deleted` y `busy`; `tsgo:core` pasó. La revisión independiente cerró la admisión posterior a cancelación y una regresión de autoridad del padre antes del despacho. Falta la batería nativa completa del SHA final de B1 y comprobar las fronteras de ciclo de vida y efecto externo incierto de T3 antes de declararlo cerrado. La admisión productiva permanece deshabilitada.

T6 y T7 están integradas como preparación aislada en G (`759a51c`). Pasaron las 7 pruebas de entrega/recibos, las 9 de recursos de host y el contrato del adaptador CLI. La revisión cruzada de T7 aprobó el arreglo de las carreras tmux (`c925363..b7974d3` en la rama de preparación). No se aceptan aún T6/T7: falta enlazar el informe portable al contrato nativo y certificar el cierre de descendientes por cada pareja host/adaptador. La prueba con un hijo desacoplado demuestra que el adaptador Mac actual conserva `CleanupPending` y cupo, pero no puede probar ausencia. `coverage.json` mantiene todas las parejas deshabilitadas.

T8 tiene una preparación aislada en G (`55ee4cb`): el cliente de progreso confirma ID y hashes después de guardar evidencia y evento, y el puente reutiliza ese recibo tras perder respuestas. Pasaron 32 pruebas del cliente y 5 del puente, incluidas ambas clases de ACK perdido y el cambio concurrente de la evidencia; la corrección de esa carrera recibió revisión cruzada. Falta la consulta y confirmación nativa de `ProjectionPending`, el enlace al director y la cadena E2E; no se marca T8 terminada.
