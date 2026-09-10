---
name: test-discrimination-verification
description: Verify that delivered tests actually fail when the behavior they claim to protect is removed. Use when asked to verify tests, review a test PR, answer "does this test catch the bug", or to act as verifier/adversary in the engineering chain. Produces a per-behavior mutation table and the list of tests that do not protect.
---

# Test Discrimination Verification

Prove a test suite discriminates: every test must go RED when its protection is removed. A test that passes with and without the fix protects nothing and gives false confidence. Verified 2026-09-10 on a redaction-module suite (13 protections, 13 mutants); the traps below each cost a real re-run or a signed-green-without-coverage.

## Steps

1. Record the baseline first: run the suite, note the **passed** count AND the **collected** count (`pytest --collect-only -q | tail -1`), plus the exact commit and base SHA. Take a verified backup of each file you will mutate (`sha256` or a copy).
   - Completion: baseline counts and SHAs recorded; backups exist for every file you will touch.

2. For each documented behavior, neutralize its protection in a scratch copy, run the suite, and confirm at least one test goes RED. Restore from the backup and re-verify the checksum before moving to the next one.
   - Completion: a per-behavior row: protection reverted → test → real RED/VERDICT → restore confirmed.

3. Check the collected count on **every** mutant run. A mutation that breaks syntax (e.g. deleting the only line of an `if` block → `IndentationError`) or excludes the module makes pytest collect **0** tests: the run looks green ("0 failed") while nothing ran. A green with a *lower* collected count is a failed experiment, not a passing test.
   - Completion: collected count equals the baseline on every mutant run.

4. Weaken, don't only remove. Deleting a protection is caught; **weakening** it often is not — that is where non-protecting tests hide. Try, per behavior: lower a numeric floor (e.g. a minimum length 8 → 2), drop a sort/priority the code relies on, narrow a guard so only some inputs take it, or change the *shape* of a returned value when the assert uses `in` rather than equality. Every behavior that survives a weakened mutation is a test that does not protect.
   - Completion: each behavior has a weakened-mutation result, not just a deleted-protection result.

5. Rule out green-by-carried-state: run each test in isolation and in shuffled/reverse order. A test that passes only in file order is green because an earlier test registered the state it checks, not because of its own protection. Flag shared mutable module state (registries, caches) with no reset between tests.
   - Completion: pass/fail pattern is identical isolated, reversed, and shuffled.

6. Test the asserts, not just the behavior: `assert "X" not in out` only proves the exact substring is absent — a redaction that truncates the secret survives it. Prefer exact-equality assertions on the produced value; report weak asserts you find.
   - Completion: each assert either compares a produced value exactly or is flagged.

7. Control for coupling: apply behavior-preserving refactors (rename a variable, equivalent rewrite) — the suite must stay GREEN. Red means the tests are pinned to the implementation, not the behavior.
   - Completion: neutral-refactor run is green.

8. Report per behavior with exact commands and output, state plainly which tests do not discriminate, and say if an attack found nothing (a clean result is a result — do not invent a failure to fill the report).
   - Completion: the report separates "suite does not discriminate" (a real finding) from "test is merely harsh".

## Pitfalls

- Never accept the author's or a peer's claim of "verified"; reproduce the mutation yourself and cite the command output.
- A mutant that fails for the wrong reason (syntax error, import error, skipped/deselected test) proves nothing — verify the test actually ran and asserted.
- Report the collected count and the pass count together; a bare "all green" is exactly how a zero-collection run passes unnoticed.
- Fixtures must be invented and distinctive; a value that is a substring of another, or of realistic data, can pass or fail by coincidence.
