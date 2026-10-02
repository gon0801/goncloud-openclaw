# T10: revisión fuera de la cola de tmux (parcial)

G `3b307c9` añadió `review_tail_restart`. Contra R `5780efab16`, `AGENT_WORK_RUNTIME_SOURCE=/Users/dn/dev/openclaw-agent-work-integration bash scripts/tests/test-agent-work-e2e.sh review_tail_restart` pasó 1/1 en 23,3 s. El caso registra un resultado `Changes` en el Gateway aislado, comprueba su recibo durable, deja la respuesta fuera de las últimas 80 líneas de tmux, reinicia el proceso solicitante y ejecuta el reconciliador de G. El registro conserva la intención de corrección y R acepta exactamente un hijo de corrección. El fixture ahora acepta un presupuesto finito opcional; el primer intento mostró que un hijo sin presupuesto no podía admitirse.

La salida de tmux es sintética y la tarea se siembra directamente en el Gateway de prueba. El caso no acredita un revisor vivo, el despertar del modelo solicitante ni un repositorio de negocio; esas fronteras siguen pendientes para la aceptación completa de T10.
