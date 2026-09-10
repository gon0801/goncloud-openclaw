---
name: test-discrimination-verify
description: Verify tests discriminate — revert each protection, confirm its test goes RED. Count collected tests to kill false green.
---

# Verify test discrimination by mutation

Trigger: someone claims new tests "protect" a behavior, or asks whether a suite would catch a regression. A test that passes with and without the fix protects nothing — it is worse than no test, because it buys false confidence.

## Rules

- Prove it on the real artifact. Never accept the author's mutation report; reproduce each one yourself.
- Count collected tests on **every** run. If the count differs from baseline the run is INVALID, not RED.
- ROJO real = a named test **FAILED**. "0 failed" with 0 collected is a false green, usually a syntax error.
- Run only the focused test file per mutation. The full battery runs once (repo CI), not per mutation.
- Never touch the PR or branch. Work on a copy; restore from a hashed backup.

## Steps

1. **Base.** `git branch --show-current`, `git log --oneline -1`, `git status --porcelain` (must be clean). `git diff --stat <base>..<head>` and `git diff --name-only` — confirm scope and whether the module under test was really left untouched. Run the focused suite; record baseline pass count and its `--collect-only` count.
2. **Backup.** Copy the module out and hash it (`shasum -a 256`). Keep the hash to prove restoration later.
3. **Battery.** One mutation per protection (one per documented behavior/branch). For each: apply → syntax gate → count gate → run focused suite → classify → restore. Use `scripts/mutation_battery.py`.
   - Syntax error **or** collected != baseline → **INVALID**. Fix the mutation and re-run. Never report INVALID as RED or GREEN.
   - A named test fails, collected == baseline → **ROJO** (discriminates).
   - All pass, collected == baseline → **VERDE** (does NOT discriminate; report it).
4. **False-green probe.** Deleting a line inside a block yields `IndentationError` → "no tests collected, 1 error". Reproduce it once so the distinction is evidence-backed, then prefer a syntactically valid revert that mirrors the real bug shape.
5. **Coupling probe.** Apply 3–5 behavior-preserving refactors (rename a local, drop a redundant guard, swap equivalent calls). All must stay GREEN. A refactor that turns RED means the test is coupled to implementation, not behavior.
6. **Fixtures.** Secrets are invented and distinctive — never real values, never 1–2 characters (documented trap: a 1-char token breaks `nextToken`). Grep the literals and eyeball them.
7. **Restore + verify.** Write the backup back, confirm the hash matches, `git status` clean, branch and HEAD unchanged.
8. **Report.** Table: protection reverted → mutation → test → real result (ROJO/VERDE/INVALID) → how restored. Then name any test that does NOT discriminate, and any uncovered gap you found. State unrun scope explicitly (e.g. full CI still pending). Do not invent a fix to justify a one-time brief.

## Completion

Every protection has a mutation with collected == baseline and a clear ROJO/VERDE. Non-discriminating tests are named. Module hash restored, tree clean. Gaps and unrun scope stated, not hidden.

Supporting file: `scripts/mutation_battery.py` — a Python/pytest template that runs the whole battery and prints one classified line per mutation.
