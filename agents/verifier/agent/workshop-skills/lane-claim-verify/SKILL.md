---
name: lane-claim-verify
description: Lane or PR claim bundle — batteries green, SHA pinned, evidence byte-identical, RED reproduced, history rewrite lost nothing? Verify against the final tree and a fresh base.
---

# Verify a lane's claim bundle against the final tree

Trigger: a dispatch or draft PR reports a lane done — "N batteries PASS", "evidence recorded", "SHA X", "CI pending". Each item is a claim, not evidence. The dispatch's paths and SHA are inputs; the live tree and live CI are the record.

Claim-by-claim entry points: §1 artifact identity · §2 batteries and evidence · §3 history rewrite · §4 lane scope · §5 CI status.

## 1. Pin the artifact three ways

`git -C <worktree> rev-parse HEAD`, `git rev-parse origin/<branch>`, and the PR's `headRefOid` must be the same SHA, and `git status --porcelain` must be empty. Verify any SHA quoted in the dispatch exists before building on it: `git cat-file -t <sha>`.

Done when the three agree and the tree is clean, or the drift is named as a finding.

## 2. Re-run the claimed batteries, and byte-compare their evidence

Run each named battery from the repo root with its own command line; record the exit code and the ok-count. Never accept the author's transcript. When a battery takes an override (a path, a phase), find it in the script's own header (`RUNBOOK=`, `FASE=`, `--params`) rather than guessing.

Done when every claim has a fresh verdict or is named inconcluso. For probing whether a battery would *catch* a regression, that is `test-discrimination-verify`, not this.

Re-run the claim's **premise** too. A doc edit justified by "the CLI rejects `--params @<file>`" is proven by running that CLI and reproducing the rejection, not by reading the diff. The premise is a claim like any other.

Evidence must correspond to the **final tree**, not merely match verdicts: `cmp .saikit/scratch/<lane>/<evidence>.txt /tmp/<fresh>.txt` per artifact, GREEN and RED alike. Identical bytes are the proof; equal verdict lines are weaker — say which you established.

Shell note: exec on the Mac node runs `/bin/sh`, which rejects process substitution `<(…)` — send compound or bash-only syntax through `bash -c '…'` or a heredoc (`bash -s <<'EOF' … EOF`). This bites inside `for` loops and `diff <(…)` chains, not only at top level (observed: `diff <(cut …) <(cut …)` → `syntax error near unexpected token '('`). `cmp`/`diff` take two paths, so no substitution is needed — write each side to its own file first.

## 3. Verify a history rewrite lost nothing — read `history-rewrite.md`

Read `history-rewrite.md` when the claim is a rebase, a dropped commit, or "only the history moved, the content did not". It lists the exact git commands for the three parts: gone from the line, every replayed commit carries the same change, what the dropped commit carried survives.

Done when ancestry says gone, the patch-id sets are equal, and each carried hunk is byte-identical.

## 4. Prove the RED claim reproducible, and scope the diff to the lane

Two checks; each needs a revision or a base resolved from the **live remote**, never from a local ref that may have gone stale.

- **RED reproducible.** Extract the pre-fix revision by path — `git show <sha>:<path> > /tmp/prev` — and run the same battery with the override it exposes. Expect the named FAIL line and a nonzero exit. Confirm the revision is the one the claim names: `git rev-parse <fix-commit>^` must be that parent. A RED you cannot reproduce is an unverified claim, not a PASS.
- **Scope.** Resolve the base live before diffing: `gh api repos/<owner>/<repo>/git/ref/heads/<default> --jq .object.sha` (or `git fetch origin <default>`), and use that SHA. Then `git diff --name-only <live-base>...<branch>`; invert-grep the lane's expected path prefixes and require empty output. Confirm the lane's dependency files are untouched relative to base — `git diff <live-base> -- <dep-path>` empty, or `git hash-object <file>` against `git rev-parse <live-base>:<file>`. A lane that quietly edits a file outside its scope is a finding even when every test is green.

A **stale** local ref invents findings that do not exist: it shows the branch reverting hunks the base has since rewritten, and gives line numbers from the old revision. When the local ref and the live base differ, say so and redo every comparison against the live base.

## 5. Re-query CI live, at the pinned SHA

A dispatch's CI status ages out ("pending" after the run has finished). Query the PR and its checks again, and require the run's `headSha` to equal the pinned SHA before quoting its conclusion — a green run on a different SHA proves nothing. Resolve `gh` by absolute path; the default PATH on the node usually lacks it. Labeling a red step `nuevo`/`preexistente` is `regression-triage`'s job, not this one.

## 6. Keep probes outside the tree

Mutants, extracted revisions, and fresh outputs live in `/tmp`, never in the worktree. Leave the tree clean; if the dispatch asks for an artifact, write it where it names, declare it untracked, and never commit. A probe file left in the tree is an incident to report against yourself.

## Completion

Per claim: verdict, exact command, observed output. SHA agrees three ways; evidence byte-verified (or the weaker check named); RED reproduced; scope empty outside the lane against a live-resolved base; CI quoted only for the pinned SHA; history-rewrite claims carry the `history-rewrite.md` proof (ancestry + patch-id + carried hunk); tree clean except artifacts you declared. Unrun scope and inconcluso items are named, not hidden.
