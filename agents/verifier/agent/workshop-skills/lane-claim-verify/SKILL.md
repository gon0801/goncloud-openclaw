---
name: lane-claim-verify
description: Lane/PR claims batteries green? Re-run on the final tree, byte-compare evidence, pin SHA 3 ways, prove RED reproducible, scope diff, re-query CI.
---

# Verify a lane's claim bundle against the final tree

Trigger: a dispatch or draft PR reports a lane done — "N batteries PASS", "evidence recorded", "SHA X", "CI pending". Each item is a claim, not evidence. The dispatch's paths and SHA are inputs; the live tree and live CI are the record.

## 1. Pin the artifact three ways

`git -C <worktree> rev-parse HEAD`, `git rev-parse origin/<branch>`, and the PR's `headRefOid` must be the same SHA, and `git status --porcelain` must be empty. Verify any SHA quoted in the dispatch exists before building on it: `git cat-file -t <sha>`.

Done when the three agree and the tree is clean, or the drift is named as a finding.

## 2. Re-run every claimed battery yourself

Run each named battery from the repo root with its own command line; record the exit code and the ok-count. Never accept the author's transcript. When a battery takes an override (a path, a phase), find it in the script's own header (`RUNBOOK=`, `FASE=`, `--params`) rather than guessing.

Done when every claim has a fresh verdict or is named inconcluso. For probing whether a battery would *catch* a regression, that is `test-discrimination-verify`, not this.

## 3. Byte-compare the recorded evidence to the fresh run

Evidence must correspond to the **final tree**, not merely match verdicts: `cmp .saikit/scratch/<lane>/<evidence>.txt /tmp/<fresh>.txt` per artifact, GREEN and RED alike. Identical bytes are the proof; equal verdict lines are weaker — say which you established.

Shell note: exec on the Mac node runs `/bin/sh`, which rejects process substitution `<(…)` — send compound or bash-only syntax through `bash -c '…'`. `cmp`/`diff` take two paths, so no substitution is needed.

## 4. Prove the RED claim reproducible

Extract the pre-fix revision by path — `git show <sha>:<path> > /tmp/prev` — and run the same battery with the override it exposes. Expect the named FAIL line and a nonzero exit. Confirm the revision is the one the claim names: `git rev-parse <fix-commit>^` must be that parent. A RED you cannot reproduce is an unverified claim, not a PASS.

## 5. Scope the diff to the lane

`git diff --name-only origin/main...<branch>`; invert-grep the lane's expected path prefixes and require empty output. Confirm the lane's dependency files are untouched relative to base — `git diff origin/main -- <dep-path>` empty, or `git hash-object <file>` against `git rev-parse origin/main:<file>`. A lane that quietly edits a file outside its scope is a finding even when every test is green.

## 6. Re-query CI live, at the pinned SHA

A dispatch's CI status ages out ("pending" after the run has finished). Query the PR and its checks again, and require the run's `headSha` to equal the pinned SHA before quoting its conclusion — a green run on a different SHA proves nothing. Resolve `gh` by absolute path; the default PATH on the node usually lacks it. Labeling a red step `nuevo`/`preexistente` is `regression-triage`'s job, not this one.

## 7. Keep probes outside the tree

Mutants, extracted revisions, and fresh outputs live in `/tmp`, never in the worktree. Leave the tree clean; if the dispatch asks for an artifact, write it where it names, declare it untracked, and never commit. A probe file left in the tree is an incident to report against yourself.

## Completion

Per claim: verdict, exact command, observed output. SHA agrees three ways; evidence byte-verified (or the weaker check named); RED reproduced; scope empty outside the lane; CI quoted only for the pinned SHA; tree clean except artifacts you declared. Unrun scope and inconcluso items are named, not hidden.
