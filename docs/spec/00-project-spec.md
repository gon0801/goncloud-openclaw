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
3. Nada se mergea sin autorización explícita de David; donde mergear ya despliega (openclaw y los 3 workspaces, por el sync) la autorización es una sola: "merge y deploy".
4. Nada se reporta como "listo" sin haberse verificado antes con la prueba del repo (`verify/`) cuando existe.

Decisión de producto registrada (D2): se crea `verify/` en goncloud-Orbit y goncloud-accounting con `saikit-verificar-app`; no se adapta el verifier a `.cursor/skills/verify-*` porque duplica mantenimiento sin cambiar nada para David — esas skills siguen siendo de la flota DG y `verify/` es la fuente de claw.

Mapa: [Camino feliz del producto](../runbooks/camino-feliz-producto.md).

## Links

- [Structural Investigation Guard design](../superpowers/specs/2026-09-12-structural-investigation-guard-design.md)
- [Structural Investigation Guard implementation plan](../superpowers/plans/2026-09-12-structural-investigation-guard.md)
- [Execution ledger](../../Plans.md)
