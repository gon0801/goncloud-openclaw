---
name: git-commit-push
description: Commit, merge and publish in the OpenClaw home/workspace git repos. Use when git commit/merge fails with "Author identity unknown", when git add -A aborts with "does not have a commit checked out", or a push to main/master is refused by policy. Produces commits the owner publishes.
---

# Git Commit & Push (OpenClaw home/workspace repos)

Commit and publish in the git repos under `~/.openclaw`. Verified 2026-09-10/11 on the `.openclaw` and `workspace` repos (Windows).

## Steps

1. These repos have no git identity configured, so `git commit` and `git merge` fail with "Author identity unknown … unable to auto-detect email address". Check first (`git config --local user.email`) and, only when empty, set the repo's automation identity — **locally, never `--global`**:
   `git config --local user.name "openclaw-auto"` and `git config --local user.email "ehventasmx@gmail.com"` (the author that signs the automatic snapshots; confirm with `git log -1 --format='%an <%ae>'`).
   - Completion: `git config --local user.email` returns the value and the following commit succeeds.

2. Stage explicitly. `git add -A` fails the **whole** command when the repo contains a nested git repo with no commits (`error: '<dir>/' does not have a commit checked out` + `fatal: adding files failed`, exit 128) — nothing gets staged, not even the valid files. Stage tracked edits with `git add -u`, then the new files by their exact paths.
   - Completion: `git diff --cached --name-only` lists exactly the intended files and nothing else.

3. Pushing to main/master is **blocked for the agent by policy** (summa-gate): `origin main`, `HEAD:main`, `refs/heads/main`, `+main` and delete-ref are all covered. Do not try variants — hand the owner the exact command instead, e.g. `git -C <repo> push origin HEAD:main`, and say what is waiting (`git log --oneline origin/main..HEAD`).
   - Completion: the owner runs the push; the agent never publishes to main itself.

4. Inspect before and after: `git status --short --branch`, `git log --oneline -1`. These repos carry an automatic snapshotter that also commits, so the tip can move under you — re-read it rather than assuming the commit you expected is there. A `pull --rebase` rewrites the snapshot commits, so their hashes change (`7d13890`/`7e2163f` became `63fa582`/`c6c2c0a` on 2026-09-11); re-resolve refs instead of reusing a SHA.
   - Branch names differ: the `workspace` repo's default branch is `master`, the `.openclaw` repo's is `main`. `git log origin/main..HEAD` on `workspace` dies with "ambiguous argument 'origin/main..HEAD'" — use the branch that exists.
   - Completion: status shows the expected ahead/behind counts, and the log tip matches the state you just produced.

## Pitfalls

- `--local`, not `--global`: other repos and machines must not inherit this identity.
- `git fetch`/`pull` here writes remote progress to stderr and PowerShell paints it red as if it failed. Judge by the exit code and the `Updating x..y` / `Fast-forward` lines, not the colour.
- A blocked push is not a failed task: the commits exist and are reported as pending — publishing is the owner's step.
- Before staging, `git ls-files --others --exclude-standard` shows the untracked paths; a bare `dir/` entry means a directory-level problem (nested repo), not a file to add. Read the `git add` output even when it is long — the `fatal:` line at the end is the one that matters.
- Both repos run `core.autocrlf=true`, so a working-tree file's byte size never matches its blob and `git show <ref>:<file> > out` rewrites line endings on Windows. Compare revisions with `git cat-file -s <ref>:<path>` and `git diff --ignore-cr-at-eol --stat`; an unchanged `--stat` with and without that flag means the diff is real content, not CRLF.
- The 2-hourly sync commits and pulls these repos. When the pull cannot run (dirty working tree, or an `add -A` aborted by the nested repo) it logs `CONFLICTO en pull - se deja como estaba` and skips that repo, leaving it `ahead`/`behind` with `push FALLO` — that is a waiting repo, not a corrupted one: commit the pending files, pull --rebase, and the cycle resumes.
