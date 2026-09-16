import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { mergeGuardVerdict } from "./lib.ts";

const P_MERGES = "/pulls/1/" + "me" + "rges";
const PUSH_MAIN = "git push " + "origin " + "ma" + "in";
const GH_PR_M = "gh pr " + "me" + "rge";
const MUT = 'mutation($id:ID!,$oid:GitObjectID!){mergePullRequest(input:{pullRequestId:$id,expectedHeadOid:$oid,mergeMethod:SQUASH}){pullRequest{number,state}}}';
const CMD_MUT = 'gh api graphql -f query=\'' + MUT + '\'';

describe("mergeGuardVerdict (6.5c)", () => {
  it("bloquea la mutacion GraphQL mergePullRequest desde main", () => {
    assert.match(mergeGuardVerdict(CMD_MUT, "main") ?? "", /Merge bloqueado/);
  });

  it("permite la mutacion GraphQL mergePullRequest desde implementer", () => {
    assert.equal(mergeGuardVerdict(CMD_MUT, "implementer"), undefined);
  });

  it("permite la mutacion GraphQL mergePullRequest desde ingenieria", () => {
    assert.equal(mergeGuardVerdict(CMD_MUT, "ingenieria"), undefined);
  });

  it("agente sin allowlist sigue bloqueado", () => {
    assert.match(mergeGuardVerdict("gh api graphql -f query='mutation($id:ID!){mergePullRequest(input:{pullRequestId:$id}){pullRequest{number}}}'", "verifier") ?? "", /Merge bloqueado/);
  });

  it("bloquea la ruta REST /merges con agentId fuera de la allowlist", () => {
    assert.match(mergeGuardVerdict("gh api repos/x/y" + P_MERGES, "verifier") ?? "", /Merge bloqueado/);
  });

  it("bloquea la ruta REST /merges sin agentId (retro-compatibilidad)", () => {
    assert.match(mergeGuardVerdict("gh api repos/x/y" + P_MERGES) ?? "", /Merge bloqueado/);
  });

  it("bloquea api.github.com con path de merge", () => {
    assert.match(
      mergeGuardVerdict("curl -s https://api.github.com/repos/x/y" + P_MERGES + " -X PUT -d commit_message=x", "verifier") ?? "",
      /Merge bloqueado/,
    );
  });

  it("NO bloquea gh pr view (consulta)", () => {
    assert.equal(mergeGuardVerdict("/opt/homebrew/bin/gh pr view 12 --json state", undefined), undefined);
  });

  it("NO bloquea git push de rama del carril", () => {
    assert.equal(mergeGuardVerdict("git push origin fase6/merge-guard:fase6/merge-guard", "implementer"), undefined);
  });

  it("bypass conocido documentado: query=@archivo pasa (declarado en codigo y skill)", () => {
    assert.equal(mergeGuardVerdict("gh api graphql -f query=@/tmp/q.txt", "main"), undefined);
  });

  it("retro-compatibilidad: un solo argumento mantiene el comportamiento previo", () => {
    assert.match(mergeGuardVerdict("git push origin main") ?? "", /Push bloqueado/);
    assert.match(mergeGuardVerdict("gh pr merge 12") ?? "", /Merge bloqueado/);
    assert.equal(mergeGuardVerdict("git push origin feature/x"), undefined);
  });

  it("cross-review r1: agente allowlisted con comando encadenado - la mutacion pasa y el push sigue bloqueado", () => {
    const PUSH_PROT = "git push " + "origin " + "ma" + "in";
    assert.match(
      mergeGuardVerdict(CMD_MUT + " && " + PUSH_PROT, "implementer") ?? "",
      /Push bloqueado/,
    );
    assert.equal(mergeGuardVerdict(CMD_MUT, "implementer"), undefined);
  });

  it("cross-review r1: unificacion restMerge - mismo endpoint, mismo trato que curl para la allowlist", () => {
    assert.equal(mergeGuardVerdict("gh api repos/x/y" + P_MERGES, "ingenieria"), undefined);
    assert.equal(mergeGuardVerdict("gh api repos/x/y" + P_MERGES, "implementer"), undefined);
    assert.match(
      mergeGuardVerdict("gh api repos/x/y" + P_MERGES, "verifier") ?? "",
      /Merge bloqueado/,
    );
  });

  it("cross-review r1: allowlist normalizada - implementer capitalizado o con espacios se comporta igual", () => {
    assert.equal(mergeGuardVerdict(CMD_MUT, "Implementer"), undefined);
    assert.equal(mergeGuardVerdict(CMD_MUT, " implementer "), undefined);
    assert.match(mergeGuardVerdict(CMD_MUT, "verifier") ?? "", /Merge bloqueado/);
  });

  // cross-review r2 (grok): los cortes de ruta terminaban en (?:[\s/'"`]|$) y no incluian ? ni #,
  // asi que `.../merge?squash=1` o `.../merges#ancla` pasaban. Con query/fragmento debe bloquear igual.
  it("cross-review r2: bloquea gh api con path de merge seguido de ?query", () => {
    assert.match(mergeGuardVerdict("gh api -X PUT repos/o/r" + P_MERGES + "?squash=1", "verifier") ?? "", /Merge bloqueado/);
  });

  it("cross-review r2: bloquea api.github.com con path de merge y query string", () => {
    assert.match(
      mergeGuardVerdict("curl -s https://api.github.com/repos/x/y" + P_MERGES + "?squash=1 -X PUT", "verifier") ?? "",
      /Merge bloqueado/,
    );
  });

  it("cross-review r2: bloquea gh api con path de merge seguido de #fragmento", () => {
    assert.match(mergeGuardVerdict("gh api repos/o/r" + P_MERGES + "#ancla", "verifier") ?? "", /Merge bloqueado/);
  });

  // cross-review r2 (grok): mutaciones GraphQL hermanas del merge. mergeBranch es el equivalente
  // a POST /merges (ya cubierto via REST/host) pero por GraphQL pasaba, y
  // enablePullRequestAutoMerge abre la puerta al mismo merge sin orden. Mismo criterio: se
  // bloquean fuera de la allowlist, pasan dentro; mutacion inocua no se toca.
  const MUT_BRANCH = "mutation($b:String!){me" + "rgeBranch(input:{branchName:$b,base:\"ma" + "in\",message:\"x\"}){mergeCommit{oid}}}";
  const MUT_AUTO = "mutation($id:ID!){enablePullRequestAuto" + "Merge(input:{pullRequestId:$id,mergeMethod:SQUASH}){pullRequest{number}}}";

  it("cross-review r2: bloquea la mutacion GraphQL mergeBranch (equivalente a POST /merges)", () => {
    assert.match(mergeGuardVerdict("gh api graphql -f query='" + MUT_BRANCH + "'", "verifier") ?? "", /Merge bloqueado/);
  });

  it("cross-review r2: bloquea la mutacion GraphQL enablePullRequestAutoMerge", () => {
    assert.match(mergeGuardVerdict("gh api graphql -f query='" + MUT_AUTO + "'", "verifier") ?? "", /Merge bloqueado/);
  });

  it("cross-review r2: las mutaciones hermanas respetan la allowlist (implementer pasa)", () => {
    assert.equal(mergeGuardVerdict("gh api graphql -f query='" + MUT_BRANCH + "'", "implementer"), undefined);
    assert.equal(mergeGuardVerdict("gh api graphql -f query='" + MUT_AUTO + "'", "ingenieria"), undefined);
  });

  it("cross-review r2: mutacion GraphQL inocua NO se bloquea", () => {
    assert.equal(
      mergeGuardVerdict("gh api graphql -f query='mutation($id:ID!){updateIssue(input:{id:$id}){issue{number}}}'", "verifier"),
      undefined,
    );


  });

  // r3 (hallazgo 1): encadenado sin espacio — &&, ; y | no estaban en las clases de
  // corte, asi que el comando con `&&echo`/`;ls` detras esquivaba el guard.
  it("r3: bloquea path de merge encadenado con && o ;", () => {
    assert.match(mergeGuardVerdict("gh api repos/o/r" + P_MERGES + "&&echo ok", "verifier") ?? "", /Merge bloqueado/);
    assert.match(mergeGuardVerdict("gh api repos/o/r" + P_MERGES + ";ls", "verifier") ?? "", /Merge bloqueado/);
  });

  it("r3: bloquea la orden de merge de gh pr encadenada con ; o &&", () => {
    assert.match(mergeGuardVerdict(GH_PR_M + ";ls") ?? "", /Merge bloqueado/);
    assert.match(mergeGuardVerdict(GH_PR_M + "&&echo ok") ?? "", /Merge bloqueado/);
  });

  it("r3: bloquea curl a api.github.com con path de merge encadenado con &&", () => {
    assert.match(
      mergeGuardVerdict("curl -X PUT https://api.github.com/repos/o/r" + P_MERGES + "&&echo ok", "verifier") ?? "",
      /Merge bloqueado/,
    );
  });

  // r3 (hallazgo 2): token entrecomillado — la comilla en la posicion del token corta la
  // frontera (?:^|[^A-Za-z0-9]) y el comando esquivaba el guard. Matching adicional sobre
  // una copia sin comillas: normaliza para el matching, fail-closed (los falsos positivos
  // bloquean; los falsos negativos son lo prohibido).
  it("r3: bloquea el cliente gh entre comillas (token quoted)", () => {
    const quoted = "'gh' api graphql -f query='" + MUT + "'";
    assert.match(mergeGuardVerdict(quoted, "main") ?? "", /Merge bloqueado/);
  });

  it("r3: el quoted pasa solo dentro de la allowlist", () => {
    const quoted = "'gh' api graphql -f query='" + MUT + "'";
    assert.equal(mergeGuardVerdict(quoted, "implementer"), undefined);
  });

  it("r3: doble comilla en el cliente tambien bloquea (verifier)", () => {
    const quoted = "\"gh\" api graphql -f query='" + MUT + "'";
    assert.match(mergeGuardVerdict(quoted, "verifier") ?? "", /Merge bloqueado/);
  });

  // r3 (hallazgo 3): comentario GraphQL — con un comment detras del nombre el `(`
  // exigido por la regex ya no esta a continuacion y el comando esquivaba el guard.
  // Queda declarado el falso positivo aceptado: mencionar el nombre ya blockea.
  it("r3: bloquea mergePullRequest seguido de comentario GraphQL", () => {
    const commented = "gh api graphql -f query='mutation($id:ID!){mergePullRequest#c\n(input:{pullRequestId:$id}){pullRequest{number,state}}}'";
    assert.match(mergeGuardVerdict(commented, "verifier") ?? "", /Merge bloqueado/);
  });

  it("r3: bloquea mergeBranch y enablePullRequestAutoMerge con comentario", () => {
    const b = "gh api graphql -f query='mutation($b:String!){mergeBranch#c\n(input:{branchName:$b}){mergeCommit{oid}}}'";
    const a = "gh api graphql -f query='mutation($id:ID!){enablePullRequestAutoMerge#c\n(input:{pullRequestId:$id}){pullRequest{number}}}'";
    assert.match(mergeGuardVerdict(b, "verifier") ?? "", /Merge bloqueado/);
    assert.match(mergeGuardVerdict(a, "verifier") ?? "", /Merge bloqueado/);
  });

  // r3 (hallazgo 4): ruta REST de auto-merge — PUT abre el mismo merge sin orden y DELETE
  // era su alta; ninguna caia en GH_API_MERGE_PATH_RE porque el path es /auto-merge.
  it("r3: bloquea PUT de la ruta REST auto-merge", () => {
    assert.match(mergeGuardVerdict("gh api -X PUT repos/o/r/pulls/1/auto-merge -f merge_method=squash", "verifier") ?? "", /Merge bloqueado/);
  });

  it("r3: bloquea DELETE de la ruta REST auto-merge", () => {
    assert.match(mergeGuardVerdict("gh api -X DELETE repos/o/r/pulls/1/auto-merge", "verifier") ?? "", /Merge bloqueado/);
  });

  it("r3: auto-merge respeta la allowlist (implementer pasa)", () => {
    assert.equal(mergeGuardVerdict("gh api -X PUT repos/o/r/pulls/1/auto-merge -f merge_method=squash", "implementer"), undefined);
    assert.equal(mergeGuardVerdict("gh api -X DELETE repos/o/r/pulls/1/auto-merge", "ingenieria"), undefined);
  });

  // turno de cola (re-review 2026-09-16, hallazgo 1 MEDIO): ruta REST merge-async —
  // endpoint oficial de GitHub para PRs apilados; el path /merge-async no caia en la
  // clase de merge (ni en gh api ni via curl a api.github.com).
  it("turno de cola: bloquea PUT de la ruta REST merge-async (gh api)", () => {
    assert.match(mergeGuardVerdict("gh api -X PUT repos/o/r/pulls/45/merge-async", "verifier") ?? "", /Merge bloqueado/);
  });

  it("turno de cola: bloquea curl contra api.github.com .../merge-async", () => {
    assert.match(mergeGuardVerdict("curl -X PUT https://api.github.com/repos/o/r/pulls/45/merge-async", "verifier") ?? "", /Merge bloqueado/);
  });

  it("turno de cola: merge-async respeta la allowlist (implementer pasa)", () => {
    assert.equal(mergeGuardVerdict("gh api -X PUT repos/o/r/pulls/45/merge-async", "implementer"), undefined);
  });

  // r3 (hallazgo 5): controles negativos — las consultas de estado no blockean.
  it("r3: NO bloquea gh pr checks con -R (consulta de checks)", () => {
    assert.equal(mergeGuardVerdict("gh pr checks 1 -R gon0801/goncloud-openclaw"), undefined);
  });

  it("r3: gh pr ready pasa, declarado (cambia estado del borrador, no fusiona)", () => {
    assert.equal(mergeGuardVerdict("gh pr ready 12"), undefined);
  });
  // r3 (hallazgo 2, completacion): comillas escapadas con backslash y backticks en el
  // cliente — la copia de matching tambien tira backslashes de escape y backticks, si no
  // `\'gh\' api` (queda `\gh\ api` al quitar comillas) y `` `gh` api `` siguen esquivando
  // la frontera del cliente.
  it("r3: cliente gh con comillas escapadas por backslash tambien bloquea", () => {
    const escaped = "\\'gh\\' api graphql -f query='" + MUT + "'";
    assert.match(mergeGuardVerdict(escaped, "verifier") ?? "", /Merge bloqueado/);
    assert.equal(mergeGuardVerdict(escaped, "implementer"), undefined);
  });

  it("r3: cliente gh entre backticks tambien bloquea", () => {
    const backticked = "`gh` api graphql -f query='" + MUT + "'";
    assert.match(mergeGuardVerdict(backticked, "verifier") ?? "", /Merge bloqueado/);
    assert.equal(mergeGuardVerdict(backticked, "implementer"), undefined);
  });

  // turno de cierre (2026-09-16, hallazgo BLOQUEANTE ALTA): la frontera de ruta era un enum
  // de terminadores ([\s/'"`?#;&|]) sin >, >>, < ni ), asi que el terminador PEGADO esquivaba
  // el guard y el merge se ejecutaba. `.../45/merge>/tmp/resp.json` es bash ordinario — lo que
  // escribe cualquiera que quiera guardar la respuesta de la API en un archivo — no una tecnica
  // de evasion. El fix invierte la frontera (lookahead negativo de continuacion de ruta) en vez
  // de agregar el tercer parche al enum. Red-first en las DOS rutas: gh api y host curl.
  const P_MERGE = "/pulls/45/" + "me" + "rge";

  it("cierre: bloquea la ruta REST de merge con > pegado (gh api)", () => {
    assert.match(
      mergeGuardVerdict("gh api -X PUT repos/o/r" + P_MERGE + ">/tmp/resp.json", "main") ?? "",
      /Merge bloqueado/,
    );
  });

  it("cierre: bloquea la ruta REST de merge con >> pegado (gh api)", () => {
    assert.match(
      mergeGuardVerdict("gh api -X PUT repos/o/r" + P_MERGE + ">>/tmp/resp.json", "main") ?? "",
      /Merge bloqueado/,
    );
  });

  it("cierre: bloquea la ruta REST de merge con < pegado (gh api)", () => {
    assert.match(
      mergeGuardVerdict("gh api -X PUT repos/o/r" + P_MERGE + "</tmp/body.json", "main") ?? "",
      /Merge bloqueado/,
    );
  });

  it("cierre: bloquea la ruta REST de merge en subshell, con ) pegado", () => {
    assert.match(
      mergeGuardVerdict("(gh api -X PUT repos/o/r" + P_MERGE + ")", "main") ?? "",
      /Merge bloqueado/,
    );
    assert.match(
      mergeGuardVerdict("(cd /Users/dn/dev/wt-E && gh api -X PUT repos/o/r" + P_MERGE + ")", "main") ?? "",
      /Merge bloqueado/,
    );
  });

  it("cierre: bloquea /auto-merge y /merges con > pegado (gh api)", () => {
    assert.match(
      mergeGuardVerdict("gh api -X PUT repos/o/r/pulls/45/auto-merge>/tmp/o.json", "main") ?? "",
      /Merge bloqueado/,
    );
    assert.match(
      mergeGuardVerdict("gh api -X POST repos/o/r" + "/me" + "rges>/tmp/o.json", "main") ?? "",
      /Merge bloqueado/,
    );
  });

  it("cierre: merge-async sigue bloqueando con la frontera invertida (alternacion)", () => {
    assert.match(
      mergeGuardVerdict("gh api -X PUT repos/o/r/pulls/45/merge-async>/tmp/o.json", "verifier") ?? "",
      /Merge bloqueado/,
    );
    assert.match(
      mergeGuardVerdict("gh api -X PUT repos/o/r/pulls/45/merge-async", "verifier") ?? "",
      /Merge bloqueado/,
    );
  });

  it("cierre: la forma pegada respeta la allowlist (implementer pasa)", () => {
    assert.equal(
      mergeGuardVerdict("gh api -X PUT repos/o/r" + P_MERGE + ">/tmp/resp.json", "implementer"),
      undefined,
    );
  });

  it("cierre: bloquea curl a api.github.com con > pegado a la ruta de merge", () => {
    assert.match(
      mergeGuardVerdict("curl -X PUT https://api.github.com/repos/o/r" + P_MERGE + ">/tmp/o.json", "main") ?? "",
      /Merge bloqueado/,
    );
  });

  it("cierre: bloquea curl a api.github.com en subshell, con ) pegado", () => {
    assert.match(
      mergeGuardVerdict("(curl -X PUT https://api.github.com/repos/o/r" + P_MERGE + ")", "main") ?? "",
      /Merge bloqueado/,
    );
  });

  it("cierre: la forma pegada del host respeta la allowlist (ingenieria pasa)", () => {
    assert.equal(
      mergeGuardVerdict("curl -X PUT https://api.github.com/repos/o/r" + P_MERGE + ">/tmp/o.json", "ingenieria"),
      undefined,
    );
  });

  it("cierre: bloquea la orden de gh pr con > o ) pegado (frontera del cliente)", () => {
    assert.match(mergeGuardVerdict(GH_PR_M + ">/tmp/o.json") ?? "", /Merge bloqueado/);
    assert.match(mergeGuardVerdict("(" + GH_PR_M + ")") ?? "", /Merge bloqueado/);
  });

  // turno de cierre (2026-09-16, hallazgo MEDIA): GRAPHQL_MERGE_RE solo se consultaba si
  // GH_API_RE matcheaba, asi que la mutacion por curl a api.github.com/graphql pasaba entera.
  // El token sale de `gh auth token` — un exec comun, sin secret-read — asi que la excusa
  // "curl con token queda fuera de alcance" no cubria este caso. Se cierra por host, igual
  // que la rama REST hace para curl.
  const CURL_GRAPHQL_MUT =
    'curl -s https://api.github.com/graphql -H "Authorization: bearer TOK" -d \'{"query":"mutation{mergePullRequest(input:{pullRequestId:$id}){pullRequest{number,state}}}"}\'';

  it("cierre: bloquea la mutacion GraphQL por curl al host, fuera de la allowlist", () => {
    assert.match(mergeGuardVerdict(CURL_GRAPHQL_MUT, "main") ?? "", /Merge bloqueado/);
    assert.match(mergeGuardVerdict(CURL_GRAPHQL_MUT, "verifier") ?? "", /Merge bloqueado/);
  });

  it("cierre: la mutacion GraphQL por curl al host pasa dentro de la allowlist", () => {
    assert.equal(mergeGuardVerdict(CURL_GRAPHQL_MUT, "implementer"), undefined);
    assert.equal(mergeGuardVerdict(CURL_GRAPHQL_MUT, "ingenieria"), undefined);
  });

  it("cierre: consulta GraphQL inocua por curl al host NO se bloquea", () => {
    assert.equal(
      mergeGuardVerdict(
        'curl -s https://api.github.com/graphql -d \'{"query":"query{repository(owner:\\"o\\",name:\\"r\\"){name}}"}\'',
        "verifier",
      ),
      undefined,
    );
  });

  // turno de cierre: alcance declarado de la frontera invertida. El lookahead no discrimina el
  // sufijo de la ruta, asi que /merge-upstream (sync de fork: no aterriza este PR en main) queda
  // bloqueado fail-closed — falso positivo aceptado y declarado por decision del lead, porque el
  // costo es un comando raro que hay que pedirle al operador, y el costo del otro lado es un
  // merge sin orden. /update-branch no lleva ruta de merge y sigue pasando.
  it("cierre: /merge-upstream queda bloqueado fail-closed (falso positivo declarado)", () => {
    assert.match(
      mergeGuardVerdict("gh api -X POST repos/o/r/merge-upstream -f branch=main", "verifier") ?? "",
      /Merge bloqueado/,
    );
  });

  it("cierre: /update-branch sigue pasando (no aterriza el PR en main)", () => {
    assert.equal(mergeGuardVerdict("gh api -X PUT repos/o/r/pulls/45/update-branch", "verifier"), undefined);
  });

  // turno de cierre: costo declarado del fix. La rama de `gh api` no exige localidad — cualquier
  // token /merge… del texto cuenta, sea el endpoint o el destino de un redirect, con espacio o
  // pegado. Antes, un destino como /tmp/merge.txt se salvaba solo porque `.` no estaba en el enum
  // de terminadores; con la frontera invertida bloquea. Es la misma ambiguedad lexica que hacia
  // posible el bypass, resuelta del lado seguro: se pide un destino que no lleve /merge en la ruta.
  it("cierre: falso positivo declarado - un destino de redirect con /merge en la ruta bloquea", () => {
    assert.match(mergeGuardVerdict("gh api repos/o/r/pulls/45>/tmp/merge.txt", "reviewer") ?? "", /Merge bloqueado/);
    assert.match(mergeGuardVerdict("gh api repos/o/r/pulls/45 > /tmp/merge.txt", "reviewer") ?? "", /Merge bloqueado/);
    assert.equal(mergeGuardVerdict("gh api repos/o/r/pulls/45 > /tmp/resp.txt", "reviewer"), undefined);
  });

  it("cierre: controles negativos - las consultas de estado siguen pasando", () => {
    assert.equal(mergeGuardVerdict("gh pr view 45 --json state,mergedAt", "verifier"), undefined);
    assert.equal(mergeGuardVerdict("gh api repos/o/r/pulls/45 --jq .mergeable_state", "verifier"), undefined);
    assert.equal(mergeGuardVerdict("git log --merges -3", "verifier"), undefined);
  });

});
