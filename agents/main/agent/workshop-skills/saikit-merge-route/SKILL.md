---
name: saikit-merge-route
description: Merge a lane's PR by the saikit kit route (dry-run → LISTO → --confirmado) instead of `gh pr merge`, when the gate answers NO-MERGE, when the receipt is missing or superseded, or when verifying an autopilot lane's gates before reporting it closed. Produces a merged squash SHA plus the per-PR review coverage and gateway evidence behind the closure.
---

# saikit Kit Merge Route

Land a lane's PR through the kit's gate. `gh pr merge` is blocked by summa-gate (see `git-commit-push`); the kit is the sanctioned path. The gate prepares and stops: `--confirmado` is the operator's yes, already granted in the phase's preapproval table — never ask the owner per merge. Verified 2026-09-16 across seven Fase 6 lanes plus the closure PR; the authority moved from a sealed verdict to the PR receipt (`saikit-entrega.v1`) in entrega-sin-sello A.

## Route

1. Preconditions, read from the remote: `.saikit/autopilot.json` exists on `origin/<default>` (the gate reads it there; a PR touching that file is refused by design and needs an owner-made bootstrap first), and the head SHA has green CI for the workflow the receipt names.
   - Completion: all confirmed from the remote, not from local state.

2. Safe window — a merge here deploys by the sync: `TZ=America/New_York date` and `openclaw cron list --all`; no job with `Next` inside 15 minutes, and outside :05–:15 of odd hours. Then, from the lane's worktree:
   `saikit-merge.sh --dry-run` → prints `DRY-RUN: gate en verde`; `saikit-merge.sh` → `LISTO`; `saikit-merge.sh --confirmado` → the squash merge.
   - Completion: the PR reads `MERGED` with its squash SHA and the postmerge run for the default branch is green.

3. The receipt must exist for the **exact head SHA** the gate checks: the latest `APPROVE lead <sha>` comment with the `saikit-entrega.v1` JSON — `implementer`, `verifier` (PASS) and `reviewer` (APPROVE) as three distinct agents for code classes, evidence links that resolve to PR/CI reports (command, result, SHA), `bloqueantes` empty. A `REVOKE lead <sha>` by the same author kills it. After any rebase or fix commit, publish a fresh `APPROVE lead <new-sha>` receipt for the new head — a receipt for a superseded SHA is refused (`NO-MERGE: sin recibo`), and fixing that is one new comment, not a re-review: unchanged code keeps its evidence, only the new CI run is cited.
   - Never pre-fill receipt fields with invented values; evidence links must resolve, and `artifact:` placeholders are fixtures, not evidence.

4. One merge owner per PR. Two closers racing one PR (2026-09-16: a parallel flow and the lead's closer both aimed at the closure PR) do not double-merge — the gate's `--match-head-commit` refuses the second — but they burn a full cycle. Give each PR to exactly one closer.

5. Derive the PR number with `gh pr view <n> --json number`; never hardcode it in a brief or a script.

## Gate rejections and their real cause

- `NO-MERGE: commit de otro email: <sha> es de <bot@…>` — the gate refuses bot-authored commits. Rewrite author and committer only (`GIT_AUTHOR_EMAIL`/`NAME`) and verify the content diff is empty. The rewritten SHA is NOT a descendant of the PR branch's remote head, so no normal push can update it and force-push is prohibited: create a replacement branch and a replacement PR with the same content, wait for fresh green CI on the new head, publish a fresh `APPROVE lead <new-sha>` receipt there, and re-run the route.
- `NO-MERGE: gh repo view no respondio en este cwd` — the kit calls `gh` unqualified and the exec PATH lacks `/opt/homebrew/bin`. Re-run with `PATH=/opt/homebrew/bin:…`.
- An `APPROVE lead` published with an **empty** SHA, or with a short SHA **expanded by hand** to a commit that does not exist, leaves the gate with no valid receipt. Read the real value: `git rev-parse HEAD`, or `gh pr view <n> --json headRefOid`.
- A red whose job died in 2–3 s with no steps and `recent account payments have failed or your spending limit needs to be increased` is GitHub billing, not code — and the `push:<default>` job first runs on the merge that introduces the workflow, so its red can belong to a merge whose tree is exactly what was approved. Do not revert: have the owner fix Billing & plans, then re-run.

## Close-out checks (report only what you read)

1. Per PR, read the PR's own comments for the review evidence and the latest `APPROVE lead <sha>` receipt, and count what is actually there: which roles are named, whose evidence resolves. CodeRabbit `rate limited` is not a review; say what the receipt actually covers — adjudicated blockers are what block, non-blocking comments live in `residuales` (2026-09-16: accounting merged with coverage thinner than assumed; the owner's "¿todo aprobado por cross review?" exposed it only because each PR was checked).
2. Gateway SHAs: `git -C <clone> log -1 --format=%H` per repo must equal the merged SHA. The workspaces take the merge on the next 2-hourly sync, so a SHA merged after the sync legitimately reads as pending — confirm with `git merge-base --is-ancestor <sha> origin/main`.
3. The last `sync-repos.log` cycle: no `CONFLICTO` and no `FALLO`. Older-dated hits are history, not the current cycle.
4. Leftovers: remote bootstrap branches (`fase6/autopilot-bootstrap`, `fase6/docs`) survive worktree cleanup and are declared, not silently kept.

## Pitfalls

- A receipt whose SHA no longer matches the PR head is stale — publish a fresh `APPROVE lead <new-sha>`; never reuse the old comment as approval for other code.
- Re-running CI is not diagnosis: three re-runs dying in 3 s each was the billing block; only the run after the owner's fix executed.
- Never ask a verifier to exceed a count/liveness cap the repo or the runbook sets, and never substitute a role you consider broken (see `agent-dispatch`).
