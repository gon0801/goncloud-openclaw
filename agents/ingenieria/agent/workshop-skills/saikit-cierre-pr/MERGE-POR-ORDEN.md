# Merge por orden del dueño (lane saikit)

Leer solo cuando el brief trae la orden textual del dueño con fecha
(6.5b). Sin esa orden rige el paso 4 de SKILL.md y el merge queda para
el operador; nunca se ejecuta esta rama.

The repo convention leaves merges to the owner, but David can order them explicitly ("Fusiona", 2026-09-13) — that order is the merge authority for the lane's approved PRs. `gh pr merge` is still blocked by the merge-guard — para TODO agente, sin excepción, y desde r7 (completado en r8) también con flags interpuestos entre `gh`, `pr` y el verbo, en sus CUATRO formas: valor separado (`-R o/r`, `--repo o/r`), valor pegado con `=` (`-R=o/r`, `--repo=o/r`) y valor pegado SIN `=` (`-Ro/r`, la forma de una sola pieza que r7 dejó abierta), que antes esquivaban la regla entera; desde r9 la misma tolerancia vale para la rama `gh api` (las dos reglas con allowlist, REST y GraphQL), que hasta r8 exigía que `gh` y `api` fueran contiguos, y también para la forma separada con el valor entrecomillado que lleva un espacio adentro (`-H 'Accept: application/vnd.github+json'`); the GitHub API route is not, for `implementer`/`ingenieria` agents (verified 2026-09-13 on #315/#316/#317, all squash — since 6.5c it *is* blocked for every other agent, see "Alcance del guard desde 6.5c" below):

1. Merge order for stacked PRs: base PR first, then the stacked one after re-targeting. When a stacked PR's base is a branch that just merged, either wait for GitHub to auto-re-target or re-target it first: `/opt/homebrew/bin/gh api -X PATCH repos/<owner>/<repo>/pulls/<n> -f base=master --jq '{number,base:.base.ref,state}'` (verified on #316). Then re-check `mergeable` — it goes `UNKNOWN` while GitHub recalculates, and `CONFLICTING` if master moved past it (fix below before merging).
2. Merge with the expected head pinned. Read the two values in one call and pass them literally to the next — the node exec runs `/bin/sh` with no process substitution, so `read -r ID OID < <(...)` fails with `syntax error near unexpected token '<'` (measured 2026-09-17): `/opt/homebrew/bin/gh pr view <n> -R <owner>/<repo> --json id,headRefOid --jq '"\(.id) \(.headRefOid)"'`, then `/opt/homebrew/bin/gh api graphql -f query='mutation($id:ID!,$oid:GitObjectID!){mergePullRequest(input:{pullRequestId:$id,expectedHeadOid:$oid,mergeMethod:SQUASH}){pullRequest{number,state}}}' -f id="<ID>" -f oid="<OID>"`. `-R <owner>/<repo>` vale para `gh pr ...` — fuera de un clon es obligatorio, sin él falla con `failed to run git` — pero `gh api` no tiene ese flag: con `-R` responde `unknown shorthand flag: 'R'` (medido 2026-09-17); la llamada graphql va sin `-R`. `mergeMethod` sigue la convención del repo: SQUASH en la lane saikit, MERGE donde el log muestra `Merge pull request #N` (goncloud-openclaw #65, medido 2026-09-17). A single `ID=$(...)` holding both leaves `OID` unset and sends an invalid GraphQL input. Confirm from `/opt/homebrew/bin/gh pr view <n> --json state,mergedAt`.
3. A `UNPROCESSABLE ... Pull Request is not mergeable` error can race the merge actually landing: after the error, re-read `state,mergedAt` before retrying — #316/#317 both showed MERGED with a mergedAt timestamp immediately after the error (the first attempt or the retry landed; the second call raced its own recalculation). Never assume from the error alone that nothing merged.
4. Merging master-moving PRs makes sibling PRs `CONFLICTING`: resolve by merging `origin/master` into the PR branch and fixing conflicts toward the branch's newer content (it carries the review rounds); push, wait for the CI run of the merge commit, then merge. Verified on #318 after #315–#317 landed (Plans.md rows and add/add .saikit tsv conflicts).
   - Completion: every ordered PR reads `MERGED` with a mergedAt timestamp, and the lane's post-merge checks run on the new master.

Precondiciones (Fase 6, 6.5b): este bloque solo corre cuando el brief trae la orden textual de David con fecha; sin esa orden no se hace, nunca. La sección viene movida verbatim desde agent-dispatch. Alcance del guard desde 6.5c: la mutación GraphQL de merge y las rutas REST de merge de api.github.com quedan bloqueadas para todo agente salvo implementer/ingenieria (allowlist de summa-gate/lib.ts; desde el cross-review r1 la rama REST via gh api aplica la misma allowlist que el path de host: mismo endpoint, un solo trato sin importar el cliente; desde el turno de cierre 6.5c el nombre de la mutación (GRAPHQL_MERGE_RE) se consulta cuando matchea el cliente `gh api` O el host `api.github.com/graphql`, así que curl con token queda cubierto en las DOS ramas: REST por path de host, GraphQL por host + nombre de mutación); bypass conocido declarado del guard léxico sobre exec: `query=@archivo` lo esquiva porque el texto del comando no lleva la mutación.
   Bypass INHERENTE restante (r3, límite declarado del diseño): quedan DOS — la indirección
   de shell (variables, aliases, eval, base64) y `query=@archivo` (la mutación vive en el
   archivo, no en el comando) — fuera del alcance léxico del guard sobre exec, declarado
   también en summa-gate/lib.ts. Cierre r3:
   el encadenado sin espacio (`&&`/`;`/`|`) ya no esquiva la promesa del paso 4; la ruta
   REST `auto-merge` (alta y baja) y las mutaciones de merge con comentario GraphQL pegado
   al nombre blockean igual (falso positivo aceptado: mencionar el nombre de la mutación
   blockea; `gh pr ready` y `gh pr checks` siguen pasando). El guard es
   léxico sobre TODO el texto del comando: un heredoc que solo ESCRIBE
   la frase literal también dispara (medido 2026-09-17 en
   goncloud-openclaw: la escritura de un archivo de evidencia murió por
   llevar la frase en el cuerpo, sin ejecutar nada). Recuperación
   verificada: redactar el archivo sin el literal; no ofuscarlo con
   variables o base64 para pasarlo — esa indirección es un bypass
   declarado fuera del alcance del guard, no una vía de escritura. Cierre r7: el flag interpuesto
   entre `gh`/`pr`/el verbo tampoco esquiva; no era una tercera clase inherente (el texto
   del comando llevaba la orden completa y visible), por eso se cerró y el conteo sigue
   siendo DOS. Cierre r9: la frontera izquierda queda cubierta en las DOS ramas del
   cliente —`gh pr <verbo>` y `gh api` (REST y GraphQL)—, no solo en la primera; hasta r8
   la declaración decía "cubierta" con `gh api` todavía exigiendo contigüidad, que era
   justo la rama de las dos reglas con allowlist. El conteo DOS vuelve a ser verdadero.
   Las consultas con flag de repo (`gh pr -R o/r view 45`, `gh pr checks 45 -R o/r`,
   también con el valor pegado) y las lecturas con flag antes de `api` (`gh -X GET api
   rate_limit`, `gh --header '…' api repos/o/r/pulls/45`) siguen pasando, con control
   negativo propio en la batería; la allowlist sigue pasando en su rama (implementer/
   ingenieria con la orden del dueño), también con flag interpuesto.
   Jerarquía explícita: esta orden del dueño en el brief PREVALECE sobre el paso 4
   genérico ("NUNCA intentes el merge") — con la orden en el brief se ejecuta esta
   sección; sin ella rige el paso 4 y el merge queda para el operador. Nota de ruta:
   el `gh` de la sección movida es `/opt/homebrew/bin/gh` en el nodo Mac (no está en
   el PATH del nodo; ver cabecera de esta skill y ENV.md de mac-exec-detach-poll).
