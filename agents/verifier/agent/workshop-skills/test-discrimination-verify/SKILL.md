---
name: test-discrimination-verify
description: Verify tests discriminate — revert or weaken each protection (pytest, node, shell), confirm RED, count collected tests to kill false green. Includes live-leak and red-first probes.
---

# Verify test discrimination by mutation

Trigger: someone claims new tests "protect" a behavior, or asks whether a suite would catch a regression. A test that passes with and without the fix protects nothing — it is worse than no test, because it buys false confidence.

Read `rules.md` before mutating — the validity rules (collected-count gate, landed-mutation check, clean-copy rule, text-predicate guards). Read `fixtures.md` when authoring the fixtures the mutations must catch. Probe shapes and the per-step procedure are below; the script is `scripts/mutation_battery.py`.

## 1. Base

`git branch --show-current`, `git log --oneline -1`, `git status --porcelain` (must be clean). `git diff --stat <base>..<head>` and `git diff --name-only` — confirm scope and whether the module under test was really left untouched. Run the focused suite; record baseline pass count and its `--collect-only` count.

## 2. Backup

Copy the module out and hash it (`shasum -a 256`). The hash is what proves restoration later.

## 3. Battery: deletion and weakening

One mutation per protected behavior/branch, using both shapes where each exists:

- **Deletion**: remove the protection outright.
- **Weakening**: a syntactically valid change that keeps the code running but narrows the protection. The usual un-tested spots are thresholds (`len(value) < 2`), guards (`or` reduced to one condition), orderings (`sorted(..., key=len, reverse=True)` → `list(...)`), comparison caps (`len(password) > 3`), and returned forms (`=***` → `=***REDACTED***`). A deletion-only battery signs all of these off as safe.

For each mutation: apply → syntax gate → count gate → run the focused suite → classify → restore. Use `scripts/mutation_battery.py`. Verdicts and their meanings are in `rules.md`; fixtures are in `fixtures.md`.

## 4. False-green probe

Deleting a line inside a block yields `IndentationError` → "no tests collected, 1 error". Reproduce it once so the distinction is evidence-backed, then prefer a syntactically valid revert that mirrors the real bug shape.

## 5. Coupling probe

Apply 3–5 behavior-preserving refactors (rename a local, drop a redundant guard, swap equivalent calls). All must stay GREEN. A refactor that turns RED means the test is coupled to implementation, not behavior.

## 6. Live-leak and red-first probe — read `live-leak-probe.md`

Read `live-leak-probe.md` when the change fixes a real bug, or when the claim is a parse or environment cause: both halves of the proof (the leak reproduces on the old revision, the regression test goes RED when the fix is reverted) are detailed there, with the environment the claim names.

## 7. Restore and verify

Write the backup back, confirm the hash matches, `git diff --quiet <module>`, `git status` clean, branch and HEAD unchanged.

## 8. Report

Table: protection reverted → mutation → test → real result (ROJO/VERDE/INVALID) → how restored. Then name any test that does NOT discriminate, and any uncovered gap you found. State unrun scope explicitly (e.g. full CI still pending). Do not invent a fix to justify a one-time brief.

## Completion

Every protection has a deletion **and** (where it exists) a weakening mutation, each with collected == baseline and a clear ROJO/VERDE, per `rules.md`. Non-discriminating tests are named. Module hash restored, tree clean, `git diff` empty. Gaps and unrun scope stated, not hidden.

Supporting files: `rules.md` (validity rules) · `fixtures.md` (fixture shapes) · `live-leak-probe.md` (two-revision proof) · `scripts/mutation_battery.py` (Python/pytest battery runner, one classified line per mutation).
