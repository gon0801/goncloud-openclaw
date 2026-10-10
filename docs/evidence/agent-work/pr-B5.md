# B5: instalación, adopción y reversa (T11)

Cubre T11 completa (7/7) del plan `docs/superpowers/plans/2026-09-30-encargos-agentes.md`, y deja T12 lista para cuando David la autorice. El plan la marca pendiente hasta entonces.

## Dependencias exactas

- G: la rama `encargos/b5` desde `b7a6ecc` (merge de B4).
- R: `f1c5f34ae8f91652412188349c296b3c1a882701` en la rama `feat/agent-work-integration`. A R no se le hace push nunca. Respecto de B4 suma dos commits:
  - `818f0fd`: el despertar del sentinel deja de mandar campos de ruta vacíos (la regresión que encontró la batería de B4);
  - `f1c5f34`: cada llamada al proveedor registra el tamaño de su cuerpo (`provider.payload.measured`).
- El artefacto: `artifact-manifest.json` fija los paquetes npm de R `f1c5f34` (`openclaw` y `@openclaw/ai` van juntos), con sus hashes, y `scripts/agent-work/artifact.py verify` lo comprueba.

## Qué entra

- **`:295` a `:297`:**
  - el manifiesto con su verificador;
  - los comandos reales de instalación y recuperación (`deploy-commands.md`), ensayados con la duración de cada uno;
  - el perfil productivo de `limits.json`, medido sobre una copia de la Mini: 1923 corridas, con la regla del máximo × 1,5. `maxContextTokens` queda desconocido y por eso la admisión sigue cerrada.
- **`:298` y `:299`:** `cutover_live.py`, el corte real de una entrada contra el gateway. Lo prueban `cutover_fencing` (6 casos contra el gateway real de R) y un ensayo sobre una copia consistente de la Mini, en sandbox y sin red, donde la base real migra de 19 a 27 y el corte transfiere en 13 s, reinicio incluido.
- **`:300` y `:301`:** `cutover_live.rollback`, probado con los dos binarios reales: 5 casos, entre ellos la foto mala, el binario anterior que no arranca y las interrupciones. El 2026.9.7 público no abre la base migrada ni acepta `managedTasks`, así que la reversa vuelve a la foto y deja suspendidos los crons viejos que la foto traía habilitados.
- **T12:** `T12-runbook.md` y la medición en sombra de `maxContextTokens` (`medir-contexto-sombra.py`). En la copia se comprobó que el evento mide los mismos bytes que recibe el proveedor.

## Limitaciones, dichas como tales

- **La admisión no se puede abrir con la configuración actual de la Mini.** R certifica el presupuesto solo para `openai` por HTTP, y ningún agente lo usa. La decisión es de David (fila B5/T12 de `followups.md`).
- **Detener y arrancar el gateway en la Mini (launchd)** se fija en T12 con el paso 0.3 del runbook. El ensayo lo hace con `ensayo_host.py`.
- **Los residuales de las revisiones de T11** están en `followups.md`, con destino antes de la parte B de T12.

## Revisión

GLM aprobó T11-a (r2), T11-b (r2) y T11-c (r1). Cada VEREDICTO repitió los comandos en una copia aislada y agregó una mutación propia. Los cambios posteriores (la sombra y el artefacto `f1c5f34`) van con su revisión en este PR.

## Batería

`cutover_fencing` y `cutover_rollback` sobre el artefacto `f1c5f34`, y la corrida del par de la matriz de aceptación sobre G y R de este PR: `acceptance-pair.json`, `par-final/`.
