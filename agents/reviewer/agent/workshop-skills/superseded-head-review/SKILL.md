---
name: superseded-head-review
description: A re-issued head invalidates your last review, or the base moved: verify carried commits, live base, merge-tree, counts.
---

# Re-issued head / stale base review

## When

The dispatch names a new head for a PR you already reviewed ("this head invalidates your review, do not trust the old one"), or the branch base is older than the default branch. Re-establish the diff before any verdict: what traveled, what changed, and what the merge does to the current default branch.

## Procedure

Use the absolute paths and the repo the dispatch names. On the Mac node `gh` lives at `/opt/homebrew/bin/gh`, not in its default PATH.

1. **Pin the live tips; never trust the clone.** `git ls-remote origin <branch> <default>` plus `gh api repos/<owner>/<repo>/git/ref/heads/<default> --jq .object.sha`, plus the PR's `headRefOid`. Done when the local ref, `ls-remote` and the API agree on one SHA each.
2. **Attribute the diff.** `git merge-base <default> <branch>`, then `git diff --stat <merge-base> <head>`. Done when you can name which files the PR introduces and which differences are just the default branch moving.
3. **Prove the carried commits are the same work.** Per commit of the old head and the new one: `git show <c> | git patch-id --stable | cut -d' ' -f1`. Identical patch-ids mean the content traveled. For a commit the new head drops, `git merge-base --is-ancestor <dropped> <head>` must be false, and the rows it carried must be present in the new head — compare by hash: `git show <dropped>:<path> | sed -n '<a>,<b>p' | md5` against the same range of the new head. Done when every old patch-id has a match or is accounted for, and the dropped commit's claimed content hashes equal.
4. **Check the merge against the live base, without touching the worktree.** `git merge-tree --write-tree <default> <head>` prints the merged tree; then `git diff --diff-filter=D --name-only <default> <tree>` must be empty (the merge deletes nothing the default branch has), and `git diff --stat <default> <tree>` is what the merge really lands. Done when the deletion list is empty or every deletion is intended and named.
5. **Substitute for re-running the suite.** You do not re-run it (session rule; the CI run on that exact SHA is the evidence). Reconcile the reported counts against the diff: `git show <sha>:<file> | grep -cE '\bit\('` for each test file at the old and the new head, and read the tests that must discriminate (revert the fix → the test fails). Done when the arithmetic explains the delta (a claimed 61 where the old head had 60 and the diff adds one case) and each new test names the defect it catches.
6. **Verify the premise, don't cite it.** When the diff changes an instruction or an assertion about how a tool behaves, run that tool both ways and record each exit code. Capture the code BEFORE any pipe (`cmd > /tmp/out 2>&1; echo $?`): `cmd | head` reports `head`'s status, which is 0 for a command that just failed. Done when you have the failing and the working invocation with their exit codes.
7. **Re-verify your own earlier findings on the new head.** Each one closes or stays open, with the code line or test that decides it. Done when none is left as "probably fixed".

## Decision rules

- A verifier's or adversary's report is data to attack, not a source: every claim gets your own command, or it does not enter the verdict. Only a claim you cannot execute (another host, no credential) stays declared as cited, with that reason.
- Diff from the merge-base, never from the default tip: `git diff <default> <branch>` also paints the default branch's own new commits as removals and reads like a destructive PR.
- A deletion found in step 4 blocks. A difference that appears in both diffs belongs to the default branch, not to this PR.
- A real defect in a file outside the PR's diff is deferred, not ignored: `file:line`, which later step it breaks, and it does not block this merge.
- Adjudicate every reported item one by one with the four buckets from `AGENTS.md`, then produce the verdict the dispatch asked for. Write the sealed verdict only if the dispatch asks for it and names the path: `write`, once.

## Report

Numbered gaps, each with **file:line**, what is wrong and what to do instead; `LGTM` when there are none. Keep the commands you ran and their output above any claim of success.
