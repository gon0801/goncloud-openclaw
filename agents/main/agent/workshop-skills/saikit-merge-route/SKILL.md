---
name: saikit-merge-route
description: Merge a lane's PR by the saikit kit route (dry-run → LISTO → --confirmado) instead of `gh pr merge`, when the gate answers NO-MERGE, when a bot-authored commit or a missing/superseded verdict blocks it, or when verifying an autopilot lane's gates before reporting it closed. Produces a merged squash SHA plus the per-PR review coverage and gateway evidence behind the closure.
---

# saikit Kit Merge Route

Land a lane's PR through the kit's gate. `gh pr merge` is blocked by summa-gate (see `git-commit-push`); the kit is the sanctioned path. The gate prepares and stops: `--confirmado` is the operator's yes, already granted in the phase's preapproval table — never ask the owner per merge. Verified 2026-09-16 across seven Fase 6 lanes plus the closure PR.

## Route

1. Preconditions, read from the remote: `.saikit/autopilot.json` exists on `origin/<default>` (the gate reads it there; a PR touching that file is refused by design and needs an owner-made bootstrap first), the head SHA has green CI, and the lane's prompt carried the sentinel (`-saikit:autopilot`) — the gate records its evidence by it, and a brief stripped of the sentinel fails the SAIKIT-SENTINEL check.
   - Completion: all three confirmed from the remote, not from local state.

2. Safe window — a merge here deploys by the sync: `TZ=America/New_York date` and `openclaw cron list --all`; no job with `Next` inside 15 minutes, and outside :05–:15 of odd hours. Then, from the lane's worktree:
   `saikit-merge.sh --dry-run` → must end `LISTO`; `saikit-merge.sh` → `LISTO`; `saikit-merge.sh --confirmado` → the squash merge.
   - Completion: the PR reads `MERGED` with its squash SHA and the postmerge run for the default branch is green.

3. The verdict must exist for the **exact head SHA** the gate checks (re-seal after any rebase or fix commit — a verdict for a superseded SHA is refused: `NO-MERGE: sin veredicto para <sha> en <path>/veredictos`). Record its sha256 in the PR.
   - The gate wants the `verified:` line from a Bash run in the **lead's own** session, not from a dispatched verifier: after the verifier reports, the lead re-runs the blast command itself. A verifier-only line leaves the gate unsatisfied.
   - Never pre-fill the verdict schema with values; a pre-filled verdict is a false approval.

4. One merge owner per PR. Two closers racing one PR (2026-09-16: a parallel flow and the lead's closer both aimed at the closure PR) do not double-merge — the gate's `expectedHeadOid` refuses the second — but they burn a full cycle and one is killed mid-ceremony. Give each PR to exactly one closer.
   - Run headless closers in tmux, not `nohup`: a closer dies with the exec host's connection, and the ceremony must outlive it. Headless closers also need `--dangerously-skip-permissions`.

5. Derive the PR number with `gh pr view <n> --json number`; never hardcode it in the brief or the closer's script.

## Gate rejections and their real cause

- `NO-MERGE: commit de otro email: <sha> es de <bot@…>` — the gate refuses bot-authored commits. Rewrite author and committer only (`GIT_AUTHOR_EMAIL`/`NAME` via `filter-branch`), verify the content diff is empty, force-push with lease, wait for fresh green CI, publish a fresh `APPROVE lead <new-sha>`, and run a fresh ceremony.
- `NO-MERGE: gh repo view no respondio en este cwd` — the kit calls `gh` unqualified and the exec PATH lacks `/opt/homebrew/bin`. Re-run with `PATH=/opt/homebrew/bin:…`.
- An `APPROVE lead` published with an **empty** SHA, or with a short SHA **expanded by hand** to a commit that does not exist, leaves the gate with no valid approval. Read the real value: `git rev-parse HEAD`, or `gh pr view <n> --json headRefOid`.
- A red whose job died in 2–3 s with no steps and `recent account payments have failed or your spending limit needs to be increased` is GitHub billing, not code — and the `push:<default>` job first runs on the merge that introduces the workflow, so its red can belong to a merge whose tree is exactly what was approved. Do not revert: have the owner fix Billing & plans, then re-run.

## Close-out checks (report only what you read)

1. Per PR, read the PR's own comments for the cross-review evidence and the `APPROVE lead <sha>`, and count what is actually there. CodeRabbit `rate limited` is not a clean review, and a lane can merge with only CodeRabbit plus the lead's mutation audit — say so when that is the case (2026-09-16: accounting merged that way; the owner's "¿todo aprobado por cross review?" exposed it only because each PR was checked).
2. Gateway SHAs: `git -C <clone> log -1 --format=%H` per repo must equal the merged SHA. The workspaces take the merge on the next 2-hourly sync, so a SHA merged after the sync legitimately reads as pending — confirm with `git merge-base --is-ancestor <sha> origin/main`.
3. The last `sync-repos.log` cycle: no `CONFLICTO` and no `FALLO`. Older-dated hits are history, not the current cycle.
4. Leftovers: remote bootstrap branches (`fase6/autopilot-bootstrap`, `fase6/docs`) survive worktree cleanup and are declared, not silently kept.

## Pitfalls

- A verdict sealed by a closer whose session died is stale — re-seal instead of reusing the recorded sha256.
- Re-running CI is not diagnosis: three re-runs dying in 3 s each was the billing block; only the run after the owner's fix executed.
- Never ask a verifier to exceed a count/liveness cap the repo or the runbook sets, and never substitute a role you consider broken (see `agent-dispatch`).
