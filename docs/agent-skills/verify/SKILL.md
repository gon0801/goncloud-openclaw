---
name: verify
description: Drive summa-gate, the guard plugin this repo ships into the OpenClaw gateway, and prove its behavior. Use before claiming a change to summa-gate/ or scripts/tests/ works, when a guard "should" block something, or when the gateway is behaving oddly. The users of this app are agents, so a real drive is an agent turn.
---

# Verify summa-gate

## What this app is, before you drive anything

This repo has no web page, no CLI and no server you start. What it ships is
**summa-gate**, a plugin that registers its guards as hooks inside the OpenClaw
gateway. Its users are **agents**: the plugin fires while an agent takes a turn,
and its behavior is visible as a blocked command, an injected instruction, a
confined workspace, or a refused close.

So "driving the app like a user would" means **taking an agent turn and reading
what the guard did to it**.

## Guards

The plugin's parts, exactly as `summa-gate/index.ts` numbers them with its
`// -- N.` comments. This file carries no count on purpose: a count rots the
first time someone adds a guard, and `scripts/tests/test-skill-verify.sh`
checks this list against those comments so it cannot.

- Merge-guard
- Canal entre agentes
- Confinamiento adversary
- Sentinel + standing rules
- Evidencia post-tool
- Gate de cierre
- Tracking de subagentes
- Observador de rendiciones

## The isolation problem: read this first

**There is exactly one gateway and it is production.** It runs on the Windows
host at `C:\Users\ehven\.openclaw`. You cannot start a second one, and this
repo's content reaches it only through a sync that runs every two hours at :10
of odd hours in `America/New_York`.

Three consequences that shape everything below:

1. **A live drive is a production drive.** The only live drives this skill
   allows are the inert ones in Drive, which fail by construction even if the
   guard were broken. Never invent a new live drive that would succeed if the
   guard failed.
2. **The gateway runs a different commit than your checkout**, up to two hours
   behind, and longer if the sync errored. Doctor tells you which.
3. **If two agents drive at once you cannot tell whose turn produced what.**
   Check for a live run before driving and refuse rather than interleave.

Everything provable without the gateway is provable locally, and that is the
layer you should reach for first.

## Launch

There is nothing to launch for the local layer. Install once, then each drive
runs on its own:

```
cd /Users/dn/dev/goncloud-openclaw
bash scripts/run-checks.sh
```

That is the whole local harness: the shell tests under `scripts/tests/` plus the
plugin's own `node --test` suite, which builds a fake gateway host in
`summa-gate/role.test.ts` (`fakeBaseApi`) and registers the real hooks against
it. It needs no gateway, no network and no credentials.

For the live layer there is no launch either: the gateway is already running.
Doctor tells you whether it is worth driving.

## Doctor

Four read-only questions, in this order. Stop at the first `no`.

```
G=~/.openclaw/bin/openclaw
command -v timeout >/dev/null || { echo "ATORADO: sin timeout, la sonda no mide nada"; exit 1; }
test -x "$G"                 || { echo "ATORADO: la CLI no es ejecutable"; exit 1; }
for i in 1 2; do
  timeout 70 $G gateway call status --timeout 60000 >/dev/null 2>&1 && { echo "vivo=0"; break; }
  [ $i = 2 ] && echo "vivo=1"
done
```

**The two prerequisite lines gate the loop; they do not just warn.** `timeout`
missing or the CLI not executable both make every probe fail, and neither means
the gateway is down. Printing a warning and then running the loop anyway still
ends in `vivo=1`, which is the wrong verdict for a broken local setup: they exit.

**Two attempts, not one, and this is measured.** Writing this skill, the first
probe failed and the gateway was up: five probes right after it answered, three
of them in under five seconds. A single failing probe means "ask again", not
"down". Two failures in a row, with both prerequisites satisfied, is the
finding.

`vivo=1`: nothing live is provable. Say so and stay on the local layer. Do not
raise the timeout to "fix" it; the gateway answers in seconds when it answers at
all, so a long wait buys nothing and hides a real outage behind a minute of
silence.

The other three run **by exec on the gateway host**, through a turn to `main`
(see Drive for the mechanism), because they ask about that machine, not yours:

```
openclaw plugins list
git -C C:\Users\ehven\.openclaw log -1 --format=%H
powershell -Command "Get-Content C:\Users\ehven\.openclaw\logs\sync-repos.log -Tail 20"
```

- `summa-gate` missing from `plugins list`: the plugin is not loaded. A drive
  would prove nothing; the absence is the finding.
- The gateway's commit is not an ancestor of your `origin/main`: it is running
  something your checkout does not describe. Check with
  `git merge-base --is-ancestor <sha> origin/main` and say which commit it is
  before interpreting any live result.
- The sync log ends in `CONFLICTO` or `FALLO`: the gateway stopped taking
  updates. Every live result is about an old build until that clears.

## Drive

### Local layer, for everything a fake host can show

Run the battery. To work on one guard, run its file alone and pair every fix
with a mutant that turns it red, because this repo's own rule is that a test
which passes without the fix does not count:

```
cd /Users/dn/dev/goncloud-openclaw/summa-gate
PATH="$(dirname "$(command -v node)"):$PATH" node --test role.test.ts
```

For the shell battery, a single check:

```
cd /Users/dn/dev/goncloud-openclaw
bash scripts/tests/<nombre>.sh
```

These tests `cd` to their own repo root. Copying one to a scratch directory and
running it there makes it fail with `not a git repository`, which looks like a
real failure and is not. Run them from the repo.

**To drive a registered hook instead of a function**, which is what a proof
needs, you have to resolve the gateway package first. `summa-gate/index.ts`
imports `openclaw`, and without it any import of the plugin dies with
`ERR_MODULE_NOT_FOUND`, which reads like the plugin is broken and is not:

```
cd /Users/dn/dev/goncloud-openclaw/summa-gate
OC="${OPENCLAW_NODE_MODULES:-$HOME/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw}"
test -d "$OC" || { echo "ATORADO: no hay instalacion de openclaw en $OC"; exit 1; }
mkdir -p node_modules && [ -e node_modules/openclaw ] || ln -s "$OC" node_modules/openclaw
```

**Re-create that link immediately before every drive, not once.** `role.test.ts`
makes its own and **deletes it in its teardown**, so any run of the battery or of
that file removes yours. Measured while writing this skill: the drive passed,
then the battery ran, then the same drive died with `ERR_MODULE_NOT_FOUND` and
nothing about the plugin had changed. Put the four lines above at the top of the
drive and the problem disappears; the link is gitignored, so re-making it costs
nothing.

Then register the plugin against a fake host and fire the hook
you care about. **Copy the shape from `fakeBaseApi` in `role.test.ts`; do not
write one from memory.** The fields the plugin reads sit at the **top level** of
the api object, not under `runtime`: `logger`, `on`,
`registerAgentToolResultMiddleware`, a memory-backed `runContext` keyed by
`${runId}:${namespace}`, and `pluginConfig`, which must be present even as `{}`.
Nesting them under `runtime` looks right and is wrong: registration succeeds,
the hook you wanted is simply not in the list, and nothing says so.

**A working one ships with this skill.** It drives the merge guard with ten
commands, six that must block and four that must pass — the allowlist branch
included: the same merge command must pass for `implementer` and `ingenieria`
and block for `verifier` and for a turn with no agent id. It prints each
verdict with the guard's message, and `scripts/tests/test-drive-merge-guard.sh`
runs it in the battery, so it cannot silently rot. To run it by hand:

```
cd /Users/dn/dev/goncloud-openclaw/summa-gate
PATH="$(dirname "$(command -v node)"):$PATH" node ../docs/agent-skills/verify/drive-merge-guard.ts
```

Copy it as the starting point for another guard rather than writing the fake
host again.

Drive each guard with **both** a case that must block and one that must pass. A
run where everything blocks and a run where nothing does look identical from a
green exit code.

### Live layer, one mechanism only

A turn to an agent, with the message in a file:

```
~/.openclaw/bin/openclaw agent --agent main --session-key agent:main:verify-<qué> \
  --message-file <archivo> --json
```

The message says, literally: "Corre por exec en el host gateway este comando y
pega la salida completa sin resumir: `<comando>`". It takes one to three
minutes; cap it at ten. No answer means `unknown`, not "passed".

A refusal from the binder is also `unknown`, not a failure: if `main` answers
"approval cannot safely bind this command" or "Approved executables: none", the
exec channel is locked, not the guard. That is a gateway-host condition, and the
fallback lives in
`agents/operaciones/agent/workshop-skills/openclaw-cron-jobs/exec-locked-fallback.md`.

**Every `openclaw` you run from the Mac is `~/.openclaw/bin/openclaw`.** It is
not on the PATH here; written bare it says "command not found" and you cannot
tell that from the gateway being down. Inside the exec message it goes bare,
because there it runs on the gateway host where it is on the PATH.

## Evidence

Write proofs to `docs/evidence/verify-<feature>-<fecha>.md`. Cleanup never
touches that directory.

Each proof carries, for every drive: the command verbatim, its output verbatim
and untrimmed except for length, and the literal string you were looking for.
The guard's messages are the evidence, and they are exact — quoting them
approximately proves nothing. The feature map under `features/` holds the exact
string for each one.

Proof standards for this repo, in its own terms:

- **Drive the guard, not the function.** Calling `mergeGuardVerdict` directly is
  a unit test and belongs in the battery. A proof exercises the registered hook,
  which is what `fakeBaseApi` gives you locally and what an agent turn gives you
  live.
- **A blocked action is only proven by an action that would otherwise succeed.**
  The live drives here are inert on purpose, so they prove the message arrives,
  not that the block held. Say which of the two you proved.
- **Capture the attempt and the state after it**, not just the refusal: if the
  guard should have stopped a push, show the branch did not move.
- **Never mock the gateway to prove a live claim.** The fake host proves
  registration and verdict logic. It cannot prove the plugin is loaded on the
  gateway; only `plugins list` can.

## Cleanup

The local layer creates nothing to clean. Confirm with `git status --porcelain`
that the battery left the tree as it found it; `.saikit/scratch/` and
`.saikit/findings/` fill up during real work and are **not** yours to delete.

The live layer creates one session per drive, named by the `--session-key` you
chose. Close only those, by that exact key. Never kill by process name and never
close a session you did not open: other agents' work runs on this same gateway.

If you added a worktree to run something, remove it by its path with
`git worktree remove`, never with `--force`, and run `git worktree prune`. A
worktree that refuses to go is telling you something is uncommitted in it.

Evidence under `docs/evidence/` survives all of this. If a cleanup step would
remove a proof, the cleanup is wrong.

## Feature map

`features/README.md` indexes one file per guard, each with its exact observable
string. A proof that drives one guard is a proof about that guard only; the map
exists so the next run can cover the others.

Keep the map honest with `/maintain-verification-skill` as the plugin changes.

## Where this skill lives

The canonical copy is tracked at `docs/agent-skills/verify/`, so it travels with
the repo and any host can read it. Claude Code finds it because
`.claude/skills/verify` is a symlink pointing here, and that link is machine
local: `.claude/` is gitignored, since the gateway's clone is this repo's root
and everything a session writes would otherwise ride the sync.

**Edit the tracked copy, not the link.** On a host without the link, read this
file directly; nothing here depends on being loaded as a slash command.

To recreate the link on a new machine:

```
cd /Users/dn/dev/goncloud-openclaw
mkdir -p .claude/skills
ln -s ../../docs/agent-skills/verify .claude/skills/verify
```
