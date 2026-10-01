# Hallazgos pendientes de integración

| Bloque | Hallazgo | Condición de cierre |
|---|---|---|
| B3→B4 | El informe portable T6 usa `observedRevision` textual y `digest` del archivo; el resultado nativo T1 usa `Revision` estructurada y digest del payload. Son pruebas distintas. | En T8, un puente validado comprueba bytes y propietario del artefacto, revisión observada y contrato del payload antes de `report`; conserva ambos digests explícitos y prueba revisión antigua y archivo alterado. No declarar T6 aceptada ni habilitar entrega CLI antes de esa prueba. |
