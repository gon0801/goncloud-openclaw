---
name: post-merge-closure
description: Merge in doubt, a PR that read mergeable no longer merges, or a deploy/ledger checker red after a saikit PR: confirm the merge, re-check mergeability, settle the hook deploy, log it, close the row.
---

# Post-Merge Closure (saikit repo)

Close the loop after an agent merges a PR in `gon0801/summonaikit-claude` on the Mac: confirm the merge, settle the gate-hook deploy, and leave the ledger closed in one PR. The repo's own `AGENTS.md` ("Deploy tras merge") is the procedure's authority — read it there. This skill carries only what it does not say and what bit us.

Verified 2026-09-11 (PR #300 → `844d048`): merge confirmed by API, hook copies already current, a regressed registration reverted from its backup, ledger closed in PR #301.

## Steps

1. Confirm the merge from the remote, never from the local checkout. `gh pr view <n> --repo gon0801/summonaikit-claude --json state,mergeCommit,mergedAt` must read `MERGED`, and the change must be present in the default branch's content: `git show origin/master:<file> | grep -c "<marker>"` ≥ 1.
   - A local checkout sitting on the feature branch, a `docs/deploy-log.md` with no entry for the PR, and zero open PRs are **not** evidence of "not merged". That inference produced a false correction to the owner.
   - Completion: both the PR state and the default-branch content confirm the merge.

2. Sync and inspect: `git fetch`, `git checkout master && git pull --ff-only`; then `HEAD == origin/master` and `git status --porcelain` empty.
   - Completion: clean tree, on the default branch, at the merged commit.

3. Check the hook copies before deploying, and do not re-run the installer when they are already current. Compare each live copy against the repo's: `shasum -a 256 ~/.{claude,grok,dsh,codex}/hooks/summonaikit-harness.sh` versus `git show origin/master:hooks/summonaikit-harness.sh | shasum -a 256`. When they match, `bash tools/install-hook.sh --check` confirms it and the deploy is a no-op — re-running the installer adds only risk, because it **rewrites the registration block even while the harness file is current**.
   - Measured on that run: it rewrote `~/.grok/hooks/summonaikit.json` from `/opt/homebrew/bin/bash` to `/bin/bash` while every copy still reported "YA AL DIA".
   - Completion: copies confirmed current and the installer not re-run — or the run justified and its registration writes diffed against their backups.

4. Live-profile writes are the lead's, with the owner's explicit OK. The installer writes the operator's production profiles (`~/.claude`, `~/.grok`, `~/.dsh`, `~/.codex`) and must never be handed to a worker. If a copy is not already current, stop and report rather than forcing it. If a write already happened, restore from the installer's backup (`<profile>/hooks/saikit-backups/*.bak`) and prove byte-identity with `cmp` before reporting.
   - Completion: each live profile is byte-identical either to the repo hook or to its pre-run backup.

5. Verify the declared interpreter can actually run the harness. The installer resolves it with `command -v bash` (`tools/install-hook.sh` ~L465), so the invoking context decides the value written into a live registration. Run from the agent's node exec, that resolved to `/bin/bash` (3.2) instead of `/opt/homebrew/bin/bash` (5.3) — and 3.2 cannot even parse the harness.
   - Parse check: `/opt/homebrew/bin/bash -n hooks/summonaikit-harness.sh` → exit 0; `/bin/bash -n` → exit 2 (a here-doc inside `$( )`, line ~1631). Compare each registration's `bash:` value against that.
   - `tools/check-hook-registration.sh` exits 0 either way: it validates that the key exists, not that the value runs.
   - Completion: every registered interpreter parses the harness.

6. Close the ledger in one PR: add the `docs/deploy-log.md` entry and set the row to `cc:完了` in `Plans.md` (only the Status cell — the row's DoD text is the contract and is never edited); run `bash tools/check-deploy-log.sh` and `bash tools/audita-ledger.sh` (both exit 0), plus `bash tests/test_plans_ledger.sh` before pushing any Plans.md edit; scope the commit by area (`docs(plans):`), never by row number; open the PR and merge after CI and CodeRabbit approval.
   - A Plans.md task row must have exactly **5 cells**: editing rows by script duplicated the Dependencies column (20.10, 20.11 twice) and CI went red deterministically — `test_plans_ledger` rejects 6-cell rows. Verified 2026-09-13 on the 20.21/20.22 closure PR: first run red, cell fix green.
   - `deploy-log` is newest-first: insert the new `##` entry ABOVE the most recent dated entry, not at the first anchor you find — the checker fails with "inversion de fecha" when a newer entry sits under an older one (verified same run: entry placed after the 2026-09-12 block → FAIL, repositioned above it → OK).
   - When a CI shard goes red, grep for the first FAIL is misleading: a test's own expected-mutation output prints `FAIL:` lines that passed. Read the run-end summary (`=== N PASS / M FAIL ===`) and the `FAIL: test_<name>` lines to name the real failing file — verified: the scary advlock FAILs were expected mutations; the real break was `FAIL: test_plans_ledger` at the tail.
   <!-- candado: test-loop-autopilot.sh -->
   - Completion: all three checks exit 0, the closure PR is `MERGED`, and its integrated SHA is confirmed from the PR API.

7. Report only what you verified. If a wrong claim already reached the owner, correct it in the same channel, with the evidence that contradicts it.

## Pitfalls

- "YA AL DIA" from the installer concerns the harness file only; registration is rewritten regardless, so a "no-op" deploy can still mutate a live profile.
- A registration checker that only asserts a `bash: ` key exists will pass a non-runnable interpreter — check the value, not the key.
- A local branch position is not merge state; assert merges from the PR API and the default branch's content.
- Opening the closure PR is not completion: confirm `MERGED` and its integrated SHA before reporting it closed.
- The ledger's DoD text is the contract and survives closing unchanged (`[Required]`/`[Conditional]`/`[needs-spike]` markers included). Rewriting it to match an implementation is a ledger-integrity break, not a status update — verified 2026-09-11: #305 rewrote the 20.16 DoD while marking it done, and restoring the original from `4157c4c^` became part of the revert.
- A merge whose gate was still running is not a validated merge: #304's check run finished 4½ minutes after its merge and #305's 6¾ minutes after. Before reporting a merged row as validated, confirm the gate run for that SHA finished green — not merely that checks exist.
- **Mergeability is not static: re-check it immediately before merging, and again after any other PR lands on the base branch.** A PR that read `MERGEABLE`/`CLEAN` at review time went `CONFLICTING`/`DIRTY` once a later PR touched the same files — verified 2026-09-11: #307 and #308 both went DIRTY after #306 was merged to master. Check `gh pr view <n> --json mergeable,mergeStateStatus`, not the state you saw when you last reviewed it. A revert branch collides with a later PR on the same files as a modify/delete conflict (the branch deleted what the later PR edited); resolve it by keeping the branch's deletions (`git rm`) when the deletion is the branch's intent.
