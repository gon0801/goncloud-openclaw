---
name: test-lock-vacuity
description: Reviewing a candado/shell test that greps anchors: real lock or decoration? Audits wiring, false negatives, false positives, tautological probes.
---

# Candado (shell test) vacuity audit

## When

A PR adds or edits a `scripts/tests/*.sh` lock, a `run-checks` glob, or a pre-commit hook, and your verdict depends on that lock being real. A green lock is not evidence until it has been shown to fail.

## Procedure

Read the lock first. Run every mutation on **copies in `/tmp`**, never on the repo.

1. **Confirm the lock actually runs.** Green CI is vacuous if the new test sits outside every executed glob. Read the hook entry (`entry:`, `always_run:`) and the runner loop (`for t in scripts/tests/*.sh`), then confirm the CI step that invokes them passed on the PR's SHA. Prepend `/opt/homebrew/bin` to PATH before `gh`: it lives there, not in the Mac node's default PATH. Done when the new file is inside an executed glob and CI ran it on that SHA.
2. **False-negative check.** Copy the guarded artifact, remove or alter exactly what the lock claims to protect, run the lock → it must exit non-zero with the expected message. Then repeat with a *semantic* mutation: passive voice ("se calcula por la interfaz"), a synonym, a negation. A lock that only catches one word order survives the rest. Done when every mutation turns it RED; a survivor is a gap.
3. **False-positive check.** Splice in the artifact's own canonical wording, or a correct-but-differently-worded variant. The lock must stay GREEN. Done when correct text passes. If it goes RED, the pattern is too broad.
4. **Tautology and coverage check on any "discrimination" sub-check.** Find the block that claims to prove the anchors discriminate. If it writes a fixed dummy text and greps that, its `fail` branch can never fire and its `ok` line disproves nothing. The probe must derive from the real artifact (mutate a copy of it), not from a constant. Then check what shapes the probe feeds: a `git check-ignore` probe of literal top-level names (`tablero-runbook/events-local.jsonl`) stays green while the pattern misses the nested path the code actually writes (`tablero-runbook/data/events/6.jsonl`) — read the writer's path builder and probe that layout. Done when you can state whether the sub-check can ever fail and its probes cover every path shape the artifact produces.

## Decision rules

- **Decorative lock**: a mutation survives (step 2), or the discrimination probe is a fixed dummy (step 4). Name it with the file:line of the guilty pattern.
- **Latent vs live**: grep the real artifact for what the lock misses. Zero occurrences ⇒ latent gap, defer it; the delivered artifact is not defective.
- **The lock's own sonda is not authority**: its `limpio`/`ok` self-check can pass because the sonda's wording dodged the pattern. Verify against real wording.
- Adjudicate any blast or adversary artifact by the AGENTS.md rules; this skill only produces the vacuity finding that feeds them.

## Report

Numbered gaps with **file:line**, what's wrong, and what to do instead; split live defects from deferred latent gaps. `LGTM` when every mutation fires and there is no false positive or dummy probe.
