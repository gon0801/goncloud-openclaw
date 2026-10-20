# Merge y deploy sin bloqueo local

Summa-gate no intercepta comandos de Git o GitHub para impedir merge o deploy.
Cualquier agente usa el flujo normal del PR con CI verde. Revisión: el bot ai-review (DeepSeek) sobre el head, sin bloqueantes abiertos. CodeRabbit es opcional: si comenta, se lee y sus hilos Major/Critical se adjudican; si no comenta o está sin cuota, no frena ni se espera, pero un hilo Major/Critical suyo sin adjudicar frena hasta adjudicarse.

## Verificación

`node --test summa-gate/merge-guard-wiring.test.ts` ejecuta los hooks registrados
con comandos de merge, push y deploy para los ocho roles y sin agentId.
`bash scripts/tests/test-drive-merge-guard.sh` comprueba diez comandos permitidos.
