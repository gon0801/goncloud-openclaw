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

  // r3 (hallazgo 5): controles negativos — las consultas de estado no blockean.
  it("r3: NO bloquea gh pr checks con -R (consulta de checks)", () => {
    assert.equal(mergeGuardVerdict("gh pr checks 1 -R gon0801/goncloud-openclaw"), undefined);
  });

  it("r3: gh pr ready pasa, declarado (cambia estado del borrador, no fusiona)", () => {
    assert.equal(mergeGuardVerdict("gh pr ready 12"), undefined);
  });
});
