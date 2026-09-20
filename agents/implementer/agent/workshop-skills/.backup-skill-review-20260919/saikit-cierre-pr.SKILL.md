---
name: Saikit cierre PR
description: Cuando cerrás un PR de la lane saikit en summonaikit-claude (integrar origin/master, validar y dejar listo). El merge lo hace el operador o, con la orden textual del dueño con fecha en el brief (6.5b), ejecutada por esta skill en implementer/ingenieria — summa-gate lo bloquea para el resto — y la batería de comportamiento no corre en la Mac del nodo; la evidencia es CI.
---

# Saikit cierre PR (backup 2026-09-19: copia del original antes del split; ver SKILL.md + MERGE-POR-ORDEN.md)

Repo: `/Users/dn/dev/summonaikit-claude` en el nodo Mac. `gh` no está en
el PATH del nodo: usá siempre la ruta absoluta `/opt/homebrew/bin/gh`
(medido funcionando 2026-09-13, PR #319).

## Pasos

1. Al integrar `origin/master` en una rama de bloque, el conflicto
   estructural es `Plans.md` (cada bloque agrega filas al mismo ledger):
   conservá las filas de AMBOS lados y verificá con
   `grep -n "<id>" Plans.md` que están las del bloque propio y las que
   vinieron de master antes de commitear. Si el repo quedó a mitad de un
   merge ("All conflicts fixed but you are still merging"), auditá la
   resolución ya en disco y concluí con `git commit --no-edit`; no
   rehagas el trabajo.
2. Validación local en la Mac: corré solo los tests enfocados del ledger
   (`bash tests/test_plans_ledger.sh`, `bash tests/test_audita_ledger.sh`
   — ambos pasan en la Mac). NO corras la batería de comportamiento
   local: `tests/test_gate_behavior.sh` falla en el SETUP en la Mac del
   nodo ("hook_lab: el hook no dejo estado al armar un turno con
   sentinel") incluso sobre master verde — es ambiental, no una
   regresión; la evidencia válida es CI Linux
   (`/opt/homebrew/bin/gh run list --branch master`).
3. Push sin force-push, esperá CI verde
   (`/opt/homebrew/bin/gh pr checks <N>`; los 15 checks tardan ~1–7 min
   por shard) y confirmá `mergeStateStatus: CLEAN` con
   `/opt/homebrew/bin/gh pr view <N> --json mergeable,mergeStateStatus`. Para la espera
   ante las caídas `COMPANION_APP_UNAVAILABLE` del exec, seguí el skill
   mac-exec-detach-poll (los `gh pr checks` son cortos y sobreviven;
   re-encuestá, no re-lances).
4. NUNCA intentes el merge: `gh pr merge` (también encadenado con
   `&&`/`;`) está bloqueado por summa-gate desde el agente — error
   medido en PR #319: "Merge bloqueado por summa-gate: `gh pr merge`
   está prohibido desde el agente... El merge lo hace el operador o el
   flujo autorizado del repo". Con CI verde y CLEAN, reportá rama, SHA,
   PR y resultado de tests, y entregá el merge al operador. Jerarquía
   explícita (6.5b): la orden textual del dueño con fecha en el brief
   PREVALECE sobre este paso — con esa orden seguí la sección "Merge por
   orden del dueño" de abajo en vez de entregar al operador.

## Criterio de cierre (resumen del original; el detalle de merge por orden vive en MERGE-POR-ORDEN.md)

PR `MERGEABLE`/`CLEAN` con CI 100% verde y merge entregado al operador
con el reporte (rama, SHA, checks, tests locales); nunca un
`gh pr merge` ejecutado.
