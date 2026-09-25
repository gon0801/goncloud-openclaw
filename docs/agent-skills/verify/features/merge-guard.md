# Merge guard

Blocks direct `gh pr merge`, GitHub API merge routes and pushes to a protected
branch for every role using OpenClaw's gateway `exec`. Any agent may use the
kit's `saikit-merge.sh --auto` after its CI, CodeRabbit and receipt gates pass.

Registered on `before_tool_call` with the `exec` matcher, so it sees the **text
of the command** an agent is about to run. That is its strength and its limit:
it reads text, so shell indirection and a query loaded from a file get past it,
and both are declared limits in `summa-gate/lib.ts`. A standalone CLI does not
pass through this hook; its instruction is to use the kit route.

## Sub-features

Four rules:

| Rule | Who it stops |
|---|---|
| The CLI merge subcommand | Every gateway agent |
| The GraphQL merge mutation | Every gateway agent |
| The API merge routes | Every gateway agent |
| Push to a protected branch | Every gateway agent |

Matching runs over the original command and over a copy with quotes stripped,
so a quoted token does not slip through. A verdict from either copy blocks.

## How to get to it (user POV)

An agent, mid-turn, runs a shell command that merges or pushes. It does not have
to be the whole command: chained with `&&` or `;` still counts, and so does a
flag sitting between the tool and its verb.

## Driving it with the battery and a turn

Local, and this is the layer that can actually prove a block:

```
cd /Users/dn/dev/goncloud-openclaw/summa-gate
PATH="$(dirname "$(command -v node)"):$PATH" node --test role.test.ts merge-guard-wiring.test.ts
```

`role.test.ts` cubre el veredicto y el hook de `sessions_send`; el cableado del
merge-guard vive en `merge-guard-wiring.test.ts`.

Live, inert by construction. Send a turn to `main` asking it to run, by exec:

```
gh pr merge 1 -R gon0801/goncloud-openclaw --squash
```

That pull request merged weeks ago, so the command errors even if the guard
failed. **It proves the message arrives, not that the block held.** Say that in
the proof.

**Which guard answers depends on where you type it, and the two say different
things.** From your own session in this repo, a lexical pre-tool hook refuses
the command before `summa-gate` ever sees it, and its message talks about the
kit script. Only by exec on the gateway host does the command reach the
registered hook, whose message starts with "Merge bloqueado por summa-gate".
If your proof quotes the kit message, you proved the wrong guard.

Send it to `main`, the agent this repo's runbooks already use for exec. The
registered hook blocks the same merge command for all gateway roles.

## Expected output

One of these, character for character:

```
Merge bloqueado por summa-gate: usá saikit-merge.sh --auto. El kit comprueba CI, CodeRabbit, recibo y SHA para cualquier agente.
```

```
Merge bloqueado por summa-gate: usá saikit-merge.sh --auto; la API directa omite el gate de CodeRabbit.
```

```
Merge bloqueado por summa-gate: usá saikit-merge.sh --auto; la API directa omite el gate de CodeRabbit.
```

```
Push bloqueado por summa-gate: `git push` a master/main está prohibido desde el agente (incluye origin master, +master, HEAD:main, refs/heads/main y delete-ref :main).
```

`scripts/tests/test-skill-verify.sh` registers the real plugin against the fake
host and checks each of these against the live `blockReason`, so the four
strings above cannot drift from `summa-gate` without the battery going red.

## Gotchas

- **The repo has a second, unrelated guard that will stop you first.** A lexical
  hook inspects the text of commands you type and refuses ones naming the kit's
  merge script or the CLI merge subcommand, even inside a commit message or a
  heredoc. It answers about hashes and manifests, which reads like the kit is
  broken. It is not. Check with `shasum` against the kit manifest, writing the
  path in pieces so the check itself does not trip it. Hash matches means false
  positive: rewrite the command and move on.
- **A timeout is not a pass.** No answer within ten minutes is `unknown`.
- **A binder refusal is not a failure of the guard.** See Drive in the parent
  skill.
- **Do not prove this by calling `mergeGuardVerdict` directly.** That is a unit
  test, and it is already in the battery. A proof drives the registered hook.
