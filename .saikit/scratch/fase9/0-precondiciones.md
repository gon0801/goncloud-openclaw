# Fase 9 — Precondiciones 0.0 (verificación gateway, -saikit:autopilot)

Fecha (UTC): 2026-09-18. Verificado desde el gateway Windows contra `origin/main`.
Punto de partida: `origin/main` = `7a83ee6` (Merge PR #77). Rama de trabajo: `fase9/fase9-arranque-gateway`.

Fuente runbook: `docs/runbooks/autopilot-fase9.md` en `origin/main`, blob
`1d74d877af577629affbce9239369b1226b87a11` (coincide con el sha del encargo, PR #61 mergeado
2026-09-17T19:51:10Z — verificado por API: `merged:true`).

| # | Comprobación | Resultado |
|---|---|---|
| runbook | `git cat-file -e origin/main:docs/runbooks/autopilot-fase9.md` | **0 presente** (blob 1d74d87) |
| plan | filas `^\| 9\.` en `Plans.md` de `origin/main` | **13** (esperado por runbook: 10) — DESVIACIÓN declarada abajo |
| fase7 | filas `^\| 7\.` con `cc:TODO` o `cc:WIP` | **0** — Fase 7 cerrada (PR #69 mergeado). La fase puede arrancar |
| autopilot | `git cat-file -e origin/main:.saikit/autopilot.json` | **0 presente** → `{"merge":true,"merge_despliega":"publica","salud_url":null,"revert_si_rojo":true,"rama":"main","sin_verify_app":true,"telegram":false}` |
| kit | `test -r /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh` | **unknown desde gateway** (ruta local de la Mac, no verificable aquí; en el repo existe la skill `agents/main/agent/workshop-skills/saikit-merge-route/SKILL.md`). Lo verifica el lead en 0.0/Q1 (`--dry-run`, "sin estado del hook" = detención) |
| candado | `bash scripts/tests/test-runbooks-no-contradicen-entorno.sh` | **TODO VERDE** (corrido local en este turno, EXIT 0, git-bash) |
| loop | `bash scripts/tests/test-loop-autopilot.sh` | **TODO VERDE** (corrido local en este turno, EXIT 0) |
| gateway | `openclaw gateway call status` | **no corrido desde este lane** (sin binario `openclaw` en el gateway Windows de este turno); lo reintenta el lead en cada cambio de estado según runbook |
| vigilante | `pgrep -f bin/tmux-activity-watch.sh` | **unknown desde gateway** (proceso de la Mac; lo comprueba el lead en 0.0) |

## Desviación del plan (manda declararla, no editarla)

El runbook exige `plan == 10`. `origin/main` trae **13 filas 9.x**: a las 9.0–9.9 se sumaron
**9.10** (instalador `scripts/mac/instalar-mac.sh`), **9.11** (agente `usuario`) y **9.12** (séptima
comprobación `usuario` en `scripts/cierre-de-fase.sh` + slot de promesa observable en el plan y la skill).
Todas en `cc:TODO`. Si la DoD de una tarea difiere entre plan y runbook, **manda `Plans.md`**
y la revisión de cierre se hace contra su DoD literal. El lead lo declara en el PR de cierre;
este archivo es la primera constancia.

## Conclusión 0.0 (lado gateway)

Ninguna precondición **verificable desde aquí** detiene la fase: runbook presente, PR #61 mergeado,
Fase 7 cerrada, autopilot.json presente, los dos candados en verde. `gateway` y `vigilante_vivo`
quedan `unknown` desde este host y los confirma el lead en la Mac. `kit` (hook/sello) se descubre
en el `--dry-run` de Q1.
