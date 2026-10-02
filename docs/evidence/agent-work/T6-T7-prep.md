# Preparación T6–T7: resultados y recursos de host

Base integrada en G: `759a51c`, cherry-pick de `1394a2b`, junto con los cherry-picks `f235b9e`, `68075f6`, `6ff64fa`, `02bf825` y `218b834` de los originales `e81162e`, `4851bad`, `a718f0e`, `c925363` y `b7974d3` (los seis originales viven solo en la rama de preparación `feat/agent-work-b3-prep` y no son ancestros de la rama del loop). La integración no activa admisión gestionada ni certifica adaptadores.

- `bash scripts/tests/test-agent-work-host.sh` pasó 7 casos de entrega/recibo y 8 de recursos antes de la última prueba; `python3 scripts/tests/test-agent-work-resources.py` pasó los 9 casos en `759a51c`. `bash scripts/tests/test-native-harness-adapters.sh` pasó en la rama integrada. T6 conserva el informe ante reinicio, duplicados y pérdida de ACK; un inbox inválido no bloquea otro resultado.
- T7 conserva cupo cuando el cierre es incierto. La prueba aislada con tmux real cambia la sesión entre lectura y mutación: `mark`, `stop` y `revoke` no afectan la reemplazante. La regresión fallaba antes del arreglo. El diff correctivo `c925363..b7974d3` de la rama de preparación, integrado como `02bf825..218b834`, fue aprobado en la segunda ronda, tras los tres bloqueantes reproducidos en la primera.
- Los 100 ciclos de reserva/cierre usan un ejecutor simulado. Una prueba Mac con tmux aislado confirmó que un hijo desacoplado sobrevive al cierre del panel y que el backend conserva `CleanupPending` y cupo. Mac y Windows permanecen deshabilitados en `coverage.json` hasta certificar ausencia de descendientes y el puente con el resultado nativo.

El contrato pendiente entre digests y revisiones portables/nativas está registrado en `followups.md`; T8 debe probarlo antes de aceptar el bloque.
