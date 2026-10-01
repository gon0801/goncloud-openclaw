# Preparación T6–T7: resultados y recursos de host

Base integrada en G: `218b834` (cherry-picks de `e81162e`, `4851bad`, `a718f0e`, `c925363` y `b7974d3`). La integración no activa admisión gestionada ni certifica adaptadores.

- `bash scripts/tests/test-agent-work-host.sh` pasó 7 casos de entrega/recibo y 8 de recursos en el SHA integrado. T6 conserva el informe ante reinicio, duplicados y pérdida de ACK; un inbox inválido no bloquea otro resultado.
- T7 conserva cupo cuando el cierre es incierto. La prueba aislada con tmux real cambia la sesión entre lectura y mutación: `mark`, `stop` y `revoke` no afectan la reemplazante. La regresión fallaba antes del arreglo. El diff correctivo `c925363..b7974d3` fue aprobado en la segunda ronda, tras los tres bloqueantes reproducidos en la primera.
- Los 100 ciclos de reserva/cierre usan un ejecutor simulado. El backend tmux real devuelve `CleanupPending` si no puede probar la ausencia de descendientes. Mac y Windows permanecen deshabilitados en `coverage.json` hasta certificar esa propiedad y el puente con el resultado nativo.

El contrato pendiente entre digests y revisiones portables/nativas está registrado en `followups.md`; T8 debe probarlo antes de aceptar el bloque.
