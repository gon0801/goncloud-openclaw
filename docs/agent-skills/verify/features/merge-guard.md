# Merge y deploy sin bloqueo local

Summa-gate no intercepta comandos de Git o GitHub para impedir merge o deploy.
Cualquier agente usa el flujo normal del PR con CI y CodeRabbit aprobados.

## Verificación

`node --test summa-gate/merge-guard-wiring.test.ts` ejecuta los hooks registrados
con comandos de merge, push y deploy para los ocho roles y sin agentId.
`bash scripts/tests/test-drive-merge-guard.sh` comprueba diez comandos permitidos.
