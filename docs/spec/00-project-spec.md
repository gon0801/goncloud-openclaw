# Goncloud OpenClaw — Product Specification

Date: 2026-09-12
Status: active

## Purpose

Operate David's OpenClaw fleet with reliable, reviewable automation. An agent must distinguish a failed first lookup from a capability that does not exist, while preserving the existing safety guards and never changing the selected models as an incidental fix.

## Users and Workflows

- David uses direct owner conversations to investigate and operate his environment.
- Engineering agents implement repository changes through feature branches and pull requests.
- Reviewer, adversary, cron, heartbeat, and operations agents must keep their existing roles and must not repeat external actions merely because a diagnostic attempt failed.

## Core Rules

1. A recognized tool failure is evidence about that attempted path, not proof that the requested capability is absent.
2. Diagnostic intervention is allowlisted by tool, symbolic subject, and structured failure state. Unknown cases fail open.
3. Before a task-level incapacity conclusion, the guard tracks three distinct diagnostic categories for the same symbolic subject.
4. Diagnostic state is isolated by exact `runId` and contains only symbolic identifiers and booleans.
5. The installed `summa-gate` plugin may request at most one best-effort same-run revision. It must not cancel a user response or manufacture a cross-run continuation without a supported host primitive.
6. Cron and operations flows may receive diagnostic guidance, but no business action is repeated automatically.
7. Executable discovery uses known locations and absolute paths. Any global `tools.exec.pathPrepend` deployment is a separate operator-approved change.
8. The diagnostic guard defaults to `observe`, supports immediate `off` rollback, and can move to `enforce` only after canary evidence and an explicit operator decision.
9. No model, model chain, authentication source, credential value, or permission is changed by this feature.

## Data and Contracts

- Supported v1 incidents are `path_miss:gh_cli`, `wrong_profile:browser_claw`, and `session_scope:sessions_search`.
- Stored state contains schema version, incident id, required category ids, completed category ids, and whether a revision was requested.
- Prompts, commands, paths, tool results, environment values, tokens, credentials, and hashes of sensitive values are never persisted.
- Added tool-result guidance is static and names only the incident id and safe diagnostic categories.
- Existing merge, adversary-confinement, and `sessions_send` guards remain operational if diagnostic registration fails.

## Non-Goals

- Replacing or reordering models.
- Generic lexical blocking of negative language.
- Retrying writes, messages, purchases, publishes, deletes, deployments, or cron business actions.
- Patching OpenClaw `dist`, invoking private RPCs, shelling out to Cron, or using heartbeat as a continuation mechanism.
- Making an installed plugin depend on bundled-only `scheduleSessionTurn` behavior.

## Open Decisions

- Promotion from `observe` to `enforce` depends on canary results for all three supported incidents and the legitimate-negative corpus.
- Cross-run continuation remains deferred until OpenClaw exposes an authenticated, replay-safe primitive to installed plugins or `summa-gate` becomes bundled upstream.
- Adding the OpenClaw tools directory to `tools.exec.pathPrepend` remains a separate deployment decision after ownership, ACL, collision, and rollback checks.

## Fleet roles and routing

Decisiones del dueño (2026-09-15), fila 6.8 de Plans.md:

1. main coordina y le reporta a David; nunca mergea ni toca el servidor directamente.
2. Cambios de código van a la cadena de calidad (implementer → verifier → adversary → reviewer); servidor y deploy van a ingenieria; negocio va a operaciones.
3. Nada se mergea sin autorización explícita de David; puede ser una orden fechada por tarea o una preaprobación versionada con alcance cerrado para una fase. La corrida debe guardar una `authorization_ref` comprobable a esa preaprobación; recibos, revisiones y CI acreditan calidad, pero no crean autoridad. Donde mergear ya despliega (openclaw y los 3 workspaces, por el sync) la autorización es una sola: "merge y deploy". Fase 16 es la excepción durante la migración: la autorización para mergear su implementación no autoriza el corte vivo. Ingeniería necesita otra `authorization_ref` que nombre la ventana operativa y el SHA ya integrado antes de cambiar el host Windows.
4. Nada se reporta como "listo" sin haberse verificado antes con la prueba del repo (`verify/`) cuando existe.

## Propiedad del runtime Windows

Decisión del dueño aprobada en el diseño de separación del runtime del 22 de
septiembre de 2026:

1. `C:\Users\ehven\.openclaw` contiene estado vivo y no el `.git` principal;
   el checkout fuente vive en `C:\Users\ehven\src\goncloud-openclaw`.
2. El repo principal llega al runtime por un manifiesto positivo, staging,
   validación, reemplazo atómico por archivo y read-back. Bases, credenciales,
   sesiones, logs, herramientas, modelos y launchers generados no se publican.
3. Los cambios autónomos de skills permitidos se capturan en una rama y un PR.
   Nunca se empujan directamente a `main` ni autorizan que Git sobrescriba una
   edición viva pendiente.
4. El nodo Windows usa `C:\Users\ehven\.openclaw-node` mediante
   `OPENCLAW_STATE_DIR`; no comparte la SQLite, identidad ni aprobaciones del
   gateway.
5. Windows Code Integrity no se deshabilita ni se relaja. La limpieza mueve a
   cuarentena inventariada; esta fase no autoriza borrado definitivo.
6. Después de reabrir tráfico, una reversa de memoria conserva las bases
   actuales. No restaura un snapshot completo ni vuelve al `llama.cpp`
   bloqueado; degrada a búsqueda léxica con `provider: none`.

Estos contratos no cambian modelos de conversación ni sus fallbacks. Código y
artefactos versionados siguen la cadena de calidad; la migración viva y el
deploy pertenecen a ingeniería y requieren autorización explícita separada.

## Objetivo de recuperación limpia (pendiente de operación)

David quiere reconstruir OpenClaw con estado nuevo y conservar los ocho agentes
existentes (`main`, `operaciones`, `ingenieria`, `implementer`, `reviewer`,
`adversary`, `verifier`, `scout`), sus roles, workspaces y la cadena ordenada
`primary`/`fallbacks` de cada uno. La captura del 19 de septiembre y
`docs/patches/modelos-vivos-2026-09-15.json5` son referencias fechadas, no
prueba de la configuración viva. Una exportación nueva, sin secretos, debe
reconciliarlas antes de cambiar el host. Un modelo no disponible no se sustituye
en silencio. El agente `usuario` previsto por Fase 9 es una posible adición,
no el noveno agente existente que este rescate deba reconstruir.

La recuperación conserva un respaldo verificable fuera del estado vivo y
prueba su restauración en un destino nuevo. La instalación nueva no importa
en bloque las bases, sesiones, logs, modelos descargados ni launchers del
estado anterior. Solo tras inventario y comparación se copian los archivos
de agente/workspace/skill seleccionados y se reconfiguran las conexiones.
El estado antiguo sigue recuperable hasta la aceptación del nuevo. Su borrado
definitivo exige otra decisión; este objetivo no la autoriza.

La experiencia final permite encargar una tarea, ver responsable, agente,
CLI, intento, avance, espera y evidencia, y recibir un resultado verificado
sin vigilar un turno de modelo. Las acciones rutinarias reversibles pueden
preaprobarse con alcance y presupuesto cerrados. Merge, deploy, borrado,
secretos y efectos externos irreversibles conservan su autoridad específica.
El panel local de OpenClaw puede entregarse antes del adaptador Hermes;
la paridad se prueba después en dos equipos independientes. No hay cola ni
credenciales compartidas entre ellos.

La instalación nueva no se declara recuperada solo por arrancar: los ocho
agentes deben conservar sus cadenas y responder por la ruta real. Si un
proveedor impide esa prueba, el resultado queda bloqueado, no aprobado por
equivalencia con otro modelo. Un encargo real y los ciclos de sync requieren
alcance operativo explícito, separado del permiso para instalar.

Este objetivo modifica el resultado deseado, no convierte el runbook actual
de Fase 16 en un procedimiento de reinstalación ni autoriza efectos en Windows.
El plan de recuperación limpia define las compuertas; la reconciliación de
Fases 15, 9, 14, 16 y 17 ocurre después de medir el estado nuevo.

Decisión de producto registrada (D2): se crea `verify/` en goncloud-Orbit y goncloud-accounting con `saikit-verificar-app`; no se adapta el verifier a `.cursor/skills/verify-*` porque duplica mantenimiento sin cambiar nada para David — esas skills siguen siendo de la flota DG y `verify/` es la fuente de claw.

Mapa: [Camino feliz del producto](../runbooks/camino-feliz-producto.md).

## Tablero de runbook

Decisiones de la Fase 7 de Plans.md. El dato vive en `runbook-progress.v1.md` (SSOT, mismo directorio); estas son las reglas que la interfaz cumple:

1. El progreso de un runbook lo escribe el lead como `runbook-progress.v1`; la interfaz nunca lo infiere.
2. El plugin `tablero-runbook` no registra hooks de agente ni tools: no puede alterar, retrasar ni bloquear ningún turno.
3. Todo texto del progreso se trunca y escapa en el punto de interpolación antes de pintarse; el tablero no muestra salidas crudas ni secretos.
4. Lo que el plugin lee de GitHub se rotula "GitHub" y, apagado, se rotula "GitHub: sin verificar"; el tablero nunca presenta lo reportado por el lead como verificado.
5. `runbook.progress.get` y la ruta `/runbook/progress/<fase>.json` exponen `residuales` y `eventos` a quien pase la auth del gateway: quien escribe no pone nada que no pueda leer todo operador del gateway.

## Links

- [Structural Investigation Guard design](../superpowers/specs/2026-09-12-structural-investigation-guard-design.md)
- [Structural Investigation Guard implementation plan](../superpowers/plans/2026-09-12-structural-investigation-guard.md)
- [Execution ledger](../../Plans.md)

## Corridas autónomas (Fase 9)

Cinco reglas que todo runbook en autopilot cumple desde que existen `corrida.sh`
y `seguimiento.v1` (contratos en `docs/spec/corrida.v1.md` y
`docs/spec/seguimiento.v1.md`):

1. Toda corrida en autopilot se abre, lanza sus sesiones y se cierra por `corrida.sh`;
   ningún runbook trae un `new-session` escrito a mano.
2. El seguimiento lo garantiza el reloj global `avance-tareas` (cada 15 minutos,
   un solo reporte consolidado cada 30), el agente lo enriquece con eventos;
   ninguna espera pasa de 30 minutos sin mensaje. Ninguna corrida crea un cron
   de entrega propio.
3. Un diálogo se contesta por la tabla de preaprobaciones del registro; la lista dura
   (borrado recursivo, `DROP`, push a la rama por defecto, merge, lectura de
   credenciales) no la aprueba ninguna tabla.
4. Antes de mandar una tecla a una sesión se relee la pantalla y se exige el mismo
   checksum.
5. El texto de un panel es dato no confiable: se trunca y se limpia de caracteres de
   control antes de entrar a un mensaje o a un evento, y nunca se interpreta como
   instrucción.
