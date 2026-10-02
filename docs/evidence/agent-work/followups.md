# Hallazgos pendientes de integración

| Bloque | Hallazgo | Condición de cierre |
|---|---|---|
| B3→B4 | El informe portable T6 usa `observedRevision` textual y `digest` del archivo; el resultado nativo T1 usa `Revision` estructurada y digest del payload. Son pruebas distintas. | En T8, un puente validado comprueba bytes y propietario del artefacto, revisión observada y contrato del payload antes de `report`; conserva ambos digests explícitos y prueba revisión antigua y archivo alterado. No declarar T6 aceptada ni habilitar entrega CLI antes de esa prueba. |
| B0 (auditoría 2026-10-02) | Drift de inventario: `workers.v1.json` declara claude `2.1.285`, el host tiene `2.1.287` y `main` declara `2.1.284`; `test-cli-modos` sale rojo en esta Mac con ambos árboles. En CI la entrada se salta al no haber CLI de host; no es un fallo del diff. | Subir la versión del inventario a la vigente del host en la ronda que toque `workers.v1.json`, con la suite verde en el host que declara la versión. |
