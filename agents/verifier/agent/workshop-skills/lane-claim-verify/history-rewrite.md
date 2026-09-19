# History rewrite: prove nothing but the history moved

Read from `lane-claim-verify` §3 when the claim is "I rebased", "I dropped a no-op commit", or "nothing changed but the history". Prove all three parts — the object store is not the line, and a surviving object is not the claim.

## 1. Gone from the line, not from the object store

- `git merge-base --is-ancestor <sha> HEAD` exits 1
- `git rev-list HEAD | grep -c '^<sha>'` is 0

`git cat-file -t <sha>` still answering proves the object survives — that is not the claim.

## 2. Every replayed commit carries the same change

- `git patch-id --stable` per commit, old chain vs new chain; `sort` each side to its own file, then `diff` the two files: identical sets mean the rewrite moved commits without altering a hunk.
- `git rev-parse <sha>^` confirms the parent the drop was anchored on.
- `git reflog show <branch>` corroborates with its `rebase (finish) ... onto <base>` line and the absence of conflict lines.

## 3. What the dropped commit carried survives in the new head

The dropped commit's own diff names it (e.g. two added rows); read those exact lines from `<sha>:<path>` and byte-`diff` them against the new head, rather than confirming "the line appears somewhere".

## Done when

Ancestry says gone, the patch-id sets are equal, and each carried hunk is byte-identical. A rewrite you cannot check this way is an unverified claim, not a PASS.
