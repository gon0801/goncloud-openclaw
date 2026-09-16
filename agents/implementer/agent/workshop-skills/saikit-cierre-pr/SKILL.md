---
name: Saikit cierre PR
description: Cuando cerrás un PR de la lane saikit en summonaikit-claude (integrar origin/master, validar y dejar listo). El merge lo hace el operador o, con la orden textual del dueño con fecha en el brief (6.5b), ejecutada por esta skill en implementer/ingenieria — summa-gate lo bloquea para el resto — y la batería de comportamiento no corre en la Mac del nodo; la evidencia es CI.
---

# Saikit cierre PR

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
   `gh pr view <N> --json mergeable,mergeStateStatus`. Para la espera
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

## Merge por orden del dueño

The repo convention leaves merges to the owner, but David can order them explicitly ("Fusiona", 2026-09-13) — that order is the merge authority for the lane's approved PRs. `gh pr merge` is still blocked by the merge-guard; the GitHub API route is not (verified 2026-09-13 on #315/#316/#317, all squash):

1. Merge order for stacked PRs: base PR first, then the stacked one after re-targeting. When a stacked PR's base is a branch that just merged, either wait for GitHub to auto-re-target or re-target it first: `gh api -X PATCH repos/<owner>/<repo>/pulls/<n> -f base=master --jq '{number,base:.base.ref,state}'` (verified on #316). Then re-check `mergeable` — it goes `UNKNOWN` while GitHub recalculates, and `CONFLICTING` if master moved past it (fix below before merging).
2. Merge with the expected head pinned: `ID=$(gh pr view <n> -R <owner>/<repo> --json id,headRefOid --jq '"\(.id) \(.headRefOid)"')`, split into GraphQL node id and head oid, then `gh api graphql -f query='mutation($id:ID!,$oid:GitObjectID!){mergePullRequest(input:{pullRequestId:$id,expectedHeadOid:$oid,mergeMethod:SQUASH}){pullRequest{number,state}}}' -f id="$ID" -f oid="$OID"`. Confirm from `gh pr view <n> --json state,mergedAt`.
3. A `UNPROCESSABLE ... Pull Request is not mergeable` error can race the merge actually landing: after the error, re-read `state,mergedAt` before retrying — #316/#317 both showed MERGED with a mergedAt timestamp immediately after the error (the first attempt or the retry landed; the second call raced its own recalculation). Never assume from the error alone that nothing merged.
4. Merging master-moving PRs makes sibling PRs `CONFLICTING`: resolve by merging `origin/master` into the PR branch and fixing conflicts toward the branch's newer content (it carries the review rounds); push, wait for the CI run of the merge commit, then merge. Verified on #318 after #315–#317 landed (Plans.md rows and add/add .saikit tsv conflicts).
   - Completion: every ordered PR reads `MERGED` with a mergedAt timestamp, and the lane's post-merge checks run on the new master.

Precondiciones (Fase 6, 6.5b): este bloque solo corre cuando el brief trae la orden textual de David con fecha; sin esa orden no se hace, nunca. La sección viene movida verbatim desde agent-dispatch. Alcance del guard desde 6.5c: la mutación GraphQL de merge y las rutas REST de merge de api.github.com quedan bloqueadas para todo agente salvo implementer/ingenieria (allowlist de summa-gate/lib.ts; desde el cross-review r1 la rama REST via gh api aplica la misma allowlist que el path de host: mismo endpoint, un solo trato sin importar el cliente); bypass conocido declarado del guard léxico sobre exec: `query=@archivo` lo esquiva porque el texto del comando no lleva la mutación. curl con token queda fuera de alcance (requeriría secret-read) y se declara.
   Bypass INHERENTE restante (r3, límite declarado del diseño): la indirección de shell
   (variables, aliases, eval, base64) y `query=@archivo`/curl-con-token quedan fuera del
   alcance léxico del guard sobre exec — declarado también en summa-gate/lib.ts. Cierre r3:
   el encadenado sin espacio (`&&`/`;`/`|`) ya no esquiva la promesa del paso 4; la ruta
   REST `auto-merge` (alta y baja) y las mutaciones de merge con comentario GraphQL pegado
   al nombre blockean igual (falso positivo aceptado: mencionar el nombre de la mutación
   blockea; `gh pr ready` y `gh pr checks` siguen pasando).
   Jerarquía explícita: esta orden del dueño en el brief PREVALECE sobre el paso 4
   genérico ("NUNCA intentes el merge") — con la orden en el brief se ejecuta esta
   sección; sin ella rige el paso 4 y el merge queda para el operador. Nota de ruta:
   el `gh` de la sección movida es `/opt/homebrew/bin/gh` en el nodo Mac (no está en
   el PATH del nodo; ver cabecera de esta skill).

## Criterio de cierre

PR `MERGEABLE`/`CLEAN` con CI 100% verde y merge entregado al operador
con el reporte (rama, SHA, checks, tests locales); nunca un
`gh pr merge` ejecutado.
