---
name: saikit-cierre-pr
description: Cuando cerrás un PR de la lane saikit en summonaikit-claude (integrar origin/master, validar y dejar listo). El merge lo hace el operador o, con la orden textual del dueño con fecha en el brief (6.5b), ejecutada por esta skill en implementer/ingenieria — summa-gate lo bloquea para el resto — y la batería de comportamiento no corre en la Mac del nodo; la evidencia es CI.
---
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->

# Saikit cierre PR

Repo: `/Users/dn/dev/summonaikit-claude` en el nodo Mac. `gh` no está en
el PATH del nodo: usá siempre la ruta absoluta `/opt/homebrew/bin/gh`
(medido funcionando 2026-09-13, PR #319; el PATH restringido del nodo se
detalla en ENV.md de mac-exec-detach-poll).

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
   ante las caídas `COMPANION_APP_UNAVAILABLE` del exec, seguí la skill de tu propio agente — **mac-exec-detach-poll** si sos implementer, **mac-node-ops paso 9** si sos ingeniería; los dos agentes tienen conjuntos de skills disjuntos y nombrar uno solo deja al otro sin ruta (reintentos de resultado desconocido: verificar efectos y re-encuestar con comandos cortos, lanzar detached con nohup si es largo; los `gh pr checks` son cortos y sobreviven;
   re-encuestá, no re-lances). No confundir con la ruta del kit autopilot (`kit-merge-route.md` en mac-node-ops, merge vía `saikit-merge.sh` con veredicto sellado): esta skill es cierre de lane saikit con validación de ledger + CI; el gate del kit es otro flujo del mismo repo.
4. NUNCA intentes el merge: `gh pr merge` (también encadenado con
   `&&`/`;`) está bloqueado por summa-gate desde el agente — error
   medido en PR #319: "Merge bloqueado por summa-gate: `gh pr merge`
   está prohibido desde el agente... El merge lo hace el operador o el
   flujo autorizado del repo". Con CI verde y CLEAN, reportá rama, SHA,
   PR y resultado de tests, y entregá el merge al operador. Jerarquía
   explícita (6.5b): la orden textual del dueño con fecha en el brief
   PREVALECE sobre este paso — con esa orden leé MERGE-POR-ORDEN.md
   (misma carpeta) y seguí esa rama en vez de entregar al operador.
   Solo esa rama lee MERGE-POR-ORDEN.md.

## Criterio de cierre

PR `MERGEABLE`/`CLEAN` con CI 100% verde y merge entregado al operador
con el reporte (rama, SHA, checks, tests locales); nunca un
`gh pr merge` ejecutado. Con orden del dueño en el brief, cada PR
ordenado queda `MERGED` con mergedAt y corren los checks post-merge
sobre el nuevo master (detalle en MERGE-POR-ORDEN.md).
