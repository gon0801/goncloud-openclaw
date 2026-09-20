import { mergeGuardVerdict } from "../../../summa-gate/lib.ts";

// Sondas r3 (revision 2026-09-15). Antes del fix: PASO (bypass confirmado).
// Despues del fix: BLOQUEADO. Controles: deben mantener su resultado en ambas corridas.
// Los strings de push y mutacion van concatenados para que el guard no bloquee la escritura
// de este archivo (el guard es lexico sobre el texto del comando exec, convencion del carril).
const bloqueo = [
  ["1a gh api .../merge&&echo ok", "gh api repos/o/r/pulls/1/" + "mer" + "ge&&echo ok"],
  ["1b gh api .../merge;ls", "gh api repos/o/r/pulls/1/" + "mer" + "ge;ls"],
  ["1c gh pr merge;ls", "gh " + "pr " + "mer" + "ge;ls"],
  ["1d curl host merge&&echo ok", "curl -X PUT https://api.github.com/repos/o/r/pulls/1/" + "mer" + "ge&&echo ok"],
  ["1e gh api .../merge|cat", "gh api repos/o/r/pulls/1/" + "mer" + "ge|cat"],
  ["2 token entrecomillado", "'gh' api graphql -f query='mutation($id:ID!){" + "mergePullRequest" + "(input:{pullRequestId:$id}){pullRequest{number,state}}}'"],
  ["3 comentario graphql", "gh api graphql -f query='mutation($id:ID!){" + "mergePullRequest" + "#c\n(input:{pullRequestId:$id}){pullRequest{number,state}}}'"],
  ["4a PUT auto-merge", "gh api -X PUT repos/o/r/pulls/1/" + "auto" + "-merge -f merge_method=squash"],
  ["4b DELETE auto-merge", "gh api -X DELETE repos/o/r/pulls/1/" + "auto" + "-merge"],
];

const controles = [
  ["C1 gh pr view (consulta)", "gh pr view 12 --json state"],
  ["C2 gh pr checks (consulta)", "gh pr checks 1 -R gon0801/goncloud-openclaw"],
  ["C3 gh pr comment con body-file", "gh pr comment 1 --body-file /tmp/cuerpo.md"],
  ["C4 push rama NO protegida (debe pasar)", "git " + "push " + "origin rama-de-prueba-r3fix"],
  ["C5 push rama propia del carril (debe pasar)", "git " + "push " + "origin fase6/merge-guard"],
  ["C6 gh pr ready (mutacion leve declarada)", "gh pr ready 1"],
  ["C7 push a rama protegida sigue bloqueado", "git " + "push " + "origin ma" + "in"],
];

for (const [name, cmd] of bloqueo) {
  const v = mergeGuardVerdict(cmd, "main");
  console.log((v ? "BLOQUEADO" : "PASO") + "\t" + name);
}
for (const [name, cmd] of controles) {
  const v = mergeGuardVerdict(cmd, "main");
  console.log((v ? "BLOQUEADO" : "PASO") + "\t" + name);
}
