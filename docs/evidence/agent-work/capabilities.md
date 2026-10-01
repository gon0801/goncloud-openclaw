# Capacidades de OpenClaw 2026.9.7 en la base de T0

La prueba `agent-wait-dedupe.test.ts` incluye `loses an accepted request replay after gateway lifecycle restart`. Registra un `agent` aceptado, reinicia el ciclo de vida del gateway y comprueba que el mismo identificador ya no tiene replay en un contexto nuevo. El caso pasa en la base y demuestra la carencia. La prueba unitaria no ejecuta un proveedor. El ensayo separado `scripts/agent-work/probe-native-restart.py` usa un gateway de ensayo y un proveedor HTTP falso en loopback. Espera el fin del primer turno, reinicia el gateway y reenvía la misma clave. Observó `started` de nuevo y el contador de solicitudes marcadas del proveedor falso pasó de 2 a 3. Los procesos de ensayo se detuvieron y el puerto quedó cerrado.

| Capacidad | Resultado | Evidencia |
|---|---|---|
| Identidad de ejecución viva | available | `src/infra/agent-run-registry.ts` y pruebas de `agent-wait-dedupe.test.ts` |
| Registro durable de subagentes | available | `src/agents/subagents/registry/subagent-registry.store.sqlite.ts` |
| Deduplicación durable de `agent` tras reinicio | requires-change | `src/gateway/agent-turn/agent-dedupe.ts` lee `context.dedupe`; la prueba de T0 pierde el replay |
| Tarea común con registro, resultado y consumo | requires-change | `task_runs` existe, pero no hay API `submit/report/resolve` común a todas las rutas |
| Consulta durable de admisión por clave | requires-change | El `idempotencyKey` de `agent` queda en el mapa del contexto |
| Presupuesto agregado de un árbol | requires-change | La medición de uso no constituye reserva previa para todos los ejecutores |
| Cierre verificable de CLI propios | requires-change | Los scripts de `corrida` no certifican ausencia de proceso y descendientes |
| `ProjectionPending` junto al resultado | requires-change | La cola de progreso está en `G`; no existe la intención nativa transaccional |

Estas filas describen solo la fuente fijada. El build de esa fuente produjo `dist/entry.js` con el mismo SHA-256 que el archivo instalado en esta Mac; no certifica todos los archivos ni un despliegue. La versión 2026.9.6 examinada en el diseño también carecía de deduplicación durable; no se modifica esa instalación.

Compatibilidad de la base de T0: el cliente CLI y el gateway usados por el ensayo provienen del mismo checkout `v2026.9.7`; el cliente instalado y el entrypoint instalado declaran 2026.9.7. El ensayo verificó las llamadas públicas `sessions.create`, `sessions.send` y `agent.wait` entre esos componentes. La aplicación de escritorio y clientes remotos no participaron en T0: su compatibilidad con las nuevas tareas queda `unverified` hasta la matriz de T10. La coincidencia de versión o del entrypoint no equivale a certificar su protocolo.

El trazado de T0 ubica la ruta nativa en `sessions_spawn` → `spawnSubagentDirect` → `runSpawnPipeline` → `subagent_runs`. Ese registro persiste antes de iniciar el listener y contiene identidad de solicitante, generación y estado de entrega. `task_runs` es una tabla amplia, pero su escritor productivo actual es el historial de cron. T1 debe conservar `subagent_runs` como dueño de la ejecución nativa y definir la autoridad común sin crear otro scheduler ni duplicar la decisión de entrega.
