---
name: git-commit-push
description: Commit, merge and publish in the OpenClaw home/workspace git repos. Use when git commit or merge fails with "Author identity unknown" / "unable to auto-detect email address", or a push to main/master is refused by policy. Produces commits the owner publishes.
---

# Git Commit & Push (OpenClaw home/workspace repos)

Commit and publish in the git repos under `~/.openclaw`. Verified 2026-09-10 on the `.openclaw` repo (Windows).

## Steps

1. These repos have no git identity configured, so `git commit` and `git merge` fail with "Author identity unknown … unable to auto-detect email address". Check first (`git config --local user.email`) and, only when empty, set the repo's automation identity — **locally, never `--global`**:
   `git config --local user.name "openclaw-auto"` and `git config --local user.email "ehventasmx@gmail.com"` (the author that signs the automatic snapshots; confirm with `git log -1 --format='%an <%ae>'`).
   - Completion: `git config --local user.email` returns the value and the following commit succeeds.

2. Pushing to main/master is **blocked for the agent by policy** (summa-gate): `origin main`, `HEAD:main`, `refs/heads/main`, `+main` and delete-ref are all covered. Do not try variants — hand the owner the exact command instead, e.g. `git -C <repo> push origin HEAD:main`, and say what is waiting (`git log --oneline origin/main..HEAD`).
   - Completion: the owner runs the push; the agent never publishes to main itself.

3. Inspect before and after: `git status --short --branch`, `git log --oneline -1`. These repos carry an automatic snapshotter that also commits, so the tip can move under you — re-read it rather than assuming the commit you expected is there.

## Pitfalls

- `--local`, not `--global`: other repos and machines must not inherit this identity.
- `git fetch`/`pull` here writes remote progress to stderr and PowerShell paints it red as if it failed. Judge by the exit code and the `Updating x..y` / `Fast-forward` lines, not the colour.
- A blocked push is not a failed task: the commits exist and are reported as pending — publishing is the owner's step.
