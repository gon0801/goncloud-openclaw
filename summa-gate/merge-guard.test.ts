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
});
