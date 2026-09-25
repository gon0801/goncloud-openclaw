# Kit merge route (summonaikit): gate prerequisites + PR receipt

For autopilot runs where the lead merges PRs via `/Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh` — the sanctioned path; direct `gh pr merge` from an agent is blocked by summa-gate. The gate's authority is the PR itself: the latest `APPROVE lead <sha>` comment from the expected author carrying the `saikit-entrega.v1` receipt JSON. There is no sealed verdict to produce and no session state to satisfy: the gate re-reads GitHub on every run and never consults `harness-state.env`, a local verdict file or any host/session/cwd marker. (A retired ceremony sealed verdicts into `.saikit/veredictos/<sha>.json` and cross-checked them against hook state; the merge kit no longer reads any of that. The only file still written there is `.saikit/veredictos/<sha>.merge`, the record of the resulting merge commit.)

## Gate prerequisites (fail-closed; every rejection names its reason)

Run inside the PR's worktree, on the PR branch checked out (detached HEAD → `NO-MERGE: el gate necesita la rama del PR`), with `export PATH="/opt/homebrew/bin:$PATH"` first — the node service PATH lacks `gh`, and the gate silences gh errors (`2>/dev/null`), so a missing gh reads as `gh repo view no respondio en este cwd` (exit 127 swallowed). All observed verbatim 2026-09-16.

Checked in order: repo match via `gh repo view`; the PR of the current branch; `mergeable` (one UNKNOWN retry); config `.saikit/autopilot.json` read from **origin/<base>** (never the working tree) with `merge=true` and `merge_despliega` ∈ {publica, no} — older configs with `"si"` are invalid ("merge_despliega unknown"); `rama` == base; PR head == local HEAD; PR author == gh account; commits only from the local email / gh noreply; **base up to date** (`base avanzada` → integrate the base into the branch, re-run CI); **CI green on the exact head SHA, for the workflow the receipt names** (`gh run list --commit`: no runs / pending / skipped / other sha = red; the receipt's `ci.workflow` selects which run counts, so a stale green from another workflow does not pass); the PR must NOT touch `.saikit/autopilot.json` (config/bootstrap PRs merge only by the operator; every such refusal is a residual with command + verbatim output); then the receipt (`saikit-entrega.v1`): fresh comment for this exact SHA (`REVOKE lead <sha>` by the same author invalidates it), the required roles distinct from each other — `implementer`, `verifier` (`resultado: PASS`) and `reviewer` (`resultado: APPROVE`) for code classes — durable evidence links that resolve to PR/CI reports with command, result and SHA, and `bloqueantes` empty.

## Sequence

`--dry-run` (prints `DRY-RUN: gate en verde; haria: gh pr merge … --match-head-commit …`) → `--auto` from any agent (rechecks CI, exact-head CodeRabbit review and green status, receipt posted after that review, base and SHA under lock; merges squash with `--match-head-commit <sha> --body "Saikit-Merge: <sha>"`, records `.saikit/veredictos/<sha>.merge`, deletes the remote branch as a separate reported step). No per-PR owner permission. Reverts: `--revert-de <merge_commit> --confirmado` (single commit, exact tree equality with the pre-merge tree, Saikit-Merge trailer required, no receipt needed).

A head change (base integration, fix commit, author rewrite) invalidates the receipt: the gate wants a receipt for the exact head, and one for an earlier SHA is refused. Budget a fresh `APPROVE lead <new-sha>` comment with a fresh receipt after every base integration — not a ceremony: the receipt cites evidence that already exists for unchanged code, plus CI of the new SHA.

## One owner per merge (race rule)

Before launching a merge flow, check for other live flows targeting the same PR: `pgrep -fl 'claude -p'` and `ls -lt /tmp/*merge* /tmp/brief-* 2>/dev/null` — read any prompt file that names the PR and coordinate with its owner first. 2026-09-16: a flow launched outside the lead session and the lead's own closer raced for PR #49; the gate's exact-head check (`--match-head-commit`) made a double merge impossible, but the loser's flow was wasted work killed mid-flight. If another live flow already covers the PR, stand down and verify its result instead of launching a second one.

## The receipt, not a seal

- The receipt lives in a PR comment, so it survives any host, session and cwd change; a lead that takes over mid-phase reads it with `gh pr view <n> --comments` and continues without repeating review that is already evidenced there.
- Evidence links must resolve: a CI run URL, a job log, a PR comment with command and result. `artifact:` placeholders are fixtures, never production evidence.
- The validator checks structure and relations (coordinates, distinct roles, PASS/APPROVE, empty blockers). It does not prove the prose true; the lead checks that the links contain command, result and SHA before approving.
- `bloqueantes` with any entry fails the gate: an adjudicated blocker is fixed before promotion, never deferred to a plan row.

## Post-merge cleanup

The kit's postmerge removes the PR worktree itself (wt-E was already gone from `git worktree list` right after the #45 merge, 2026-09-16). A leftover worktree needs `--force` when only untracked files remain: confirm nothing tracked is dirty (`git -C <wt> status --short` — expect only `?? .saikit/`, `?? .claude/`, `?? out/`), then `git worktree remove --force <wt>`. The merge deletes the remote branch on its own; the LOCAL branch outlives it and is deleted by hand with `git branch -D <branch>` after the worktree is gone.
