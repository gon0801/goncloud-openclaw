---
name: test-discrimination-verification
description: Verify that delivered tests actually fail when the behavior they claim to protect is removed or weakened, and that a fix really closes the hole. Use when asked to verify tests, review a test PR, answer "does this test catch the bug", or to act as verifier/adversary in the engineering chain. Produces a per-behavior mutation table and the list of tests that do not protect.
---

# Test Discrimination Verification

Prove a test suite discriminates: every test must go RED when its protection is removed or weakened. A test that passes with and without the fix protects nothing and gives false confidence. Verified 2026-09-10 on a redaction-module suite: round 1 (13 protections, 13 mutants) was clean under deletion, yet 5 weakening mutants survived and one live fail-open leak sat outside the suite entirely.

## Steps

1. Record the baseline first: branch, the **exact commit and base SHA**, the **passed** count AND the **collected** count (`pytest --collect-only -q | tail -1`). Take a verified backup of each file you will mutate (`sha256` or a copy), plus the expected sha of the module under test.
   - Completion: baseline counts, branch and SHAs recorded; backups exist for every file you will touch.

2. Apply each mutation to the **real file in the working tree** — never to a separate copy. Mutating a copy leaves the suite green and yields the false conclusion that the mutation kills nothing. Run the suite, confirm at least one test goes RED, then restore (checksum) and re-verify before the next one; if the task forbids uncommitted module edits, commit the fix under test **before** running the harness, or the legitimate diff dirties the cleanup check.
   - Completion: a per-behavior row: protection mutated → test → real RED verdict → restore confirmed (`git diff --quiet <file>`).

3. Check the collected count on **every** mutant run. A mutation that breaks syntax (deleting the only line of an `if` block → `IndentationError`) or excludes the module makes pytest collect **0** tests: the run looks green while nothing ran. A green with a *lower* collected count is a failed experiment, not a passing test. The same false green hides in a shell suite: a guarded block whose precondition is never met (the artifact is not executable, a download landed elsewhere) runs nothing and emits neither skip nor FAIL, so the case reports ok. Verify the expected line was actually executed — require an explicit success line or a skip-with-reason.
   - Completion: collected count equals the baseline on every mutant run, or an executed/skipped line proves the block ran.

4. Weaken, don't only remove. Deleting a protection is usually caught; **weakening** it often is not — that is where non-protecting tests hide. Per behavior try: lower a numeric floor (a minimum length 8 → 2), drop a sort/priority the code relies on, narrow a guard so only some inputs take it, or change the *shape* of a returned value when the assert uses `in` rather than equality. Every behavior that survives a weakened mutation is a test that does not protect.
   - Completion: each behavior has a weakened-mutation result, not just a deleted-protection result.

5. Make the new test discriminate against **its own** mutant: state which mutant turns it red, and confirm the red test is the intended one. A fault that reddens a different test, or a fixture too long to exercise the floor it claims to test (a fixture of N characters only discriminates floors above N), does not protect the behavior.
   - Completion: each new test names the mutant that kills it, and that is the test that goes red.

6. Rule out green-by-carried-state: run each test in isolation and in shuffled/reverse order. A test that passes only in file order is green because an earlier test registered the state it checks. Flag shared mutable module state (registries, caches) with no reset between tests, and choose fixtures that cannot collide with text the whole suite passes through that state.
   - Completion: pass/fail pattern is identical isolated, reversed, and shuffled.

7. Test the asserts, not just the behavior: `assert "X" not in out` only proves the exact substring is absent — a redaction that truncates the secret survives it, and `assert "key=***" in out` survives `key=***REDACTED***`. Prefer exact-equality assertions on the produced value; report weak asserts you find.
   - Completion: each assert either compares a produced value exactly or is flagged.

8. Control for coupling: apply behavior-preserving refactors (rename a variable, equivalent rewrite) — the suite must stay GREEN. Red means the tests are pinned to the implementation, not the behavior.
   - Completion: neutral-refactor run is green.

9. Harness mechanics — a mutation verdict is only as good as the reader: derive RED/GREEN from the runner's **failure counter**, not from parsing test names (a name regex that misses an id reports "not red" for a test that did fail). Assert the mutated file actually differs before running, read its sha back to prove which revision ran, and disable stale bytecode (`PYTHONDONTWRITEBYTECODE=1`, clear `__pycache__`) so the source on disk governs.
   - Completion: the table is produced by the counter, and every row carries the sha of the file that ran.

10. For a fix in scope, prove it red-first: the new regression test must FAIL against the pre-fix revision and PASS with the fix. When the fix closes a fail-open path, reproduce the leak against the old revision by loading it separately, then show it is closed — "the code now looks right" is not evidence.
   - Completion: old revision red, new revision green, leak reproduced and closed.

11. When verifying someone else's suite, write your own harness instead of reusing their instrument (audit theirs for the mechanics in step 9 and say whether you trusted it). Report per behavior with exact commands and output, state plainly which tests do not discriminate, and say if an attack found nothing — a clean result is a result; do not invent a failure to fill the report.
   - Completion: an independent harness reproduces the table; the report separates "suite does not discriminate" (a real finding) from "test is merely harsh".

## Pitfalls

- Never accept the author's or a peer's claim of "verified"; reproduce the mutation yourself and cite the command output.
- A mutant that fails for the wrong reason (syntax error, import error, skipped/deselected test) proves nothing — verify the test actually ran and asserted.
- Report the collected count and the pass count together; a bare "all green" is exactly how a zero-collection run passes unnoticed.
- Fixtures must be invented and distinctive; a value that is a substring of another, or of realistic data, can pass or fail by coincidence. Register order matters when one fixture contains another.
- Do not trust a brief's cited line numbers or counts: verify them and report the defect. A pointer to the wrong line sends the whole verification down a wrong path.
- Test isolation traps are easy to miss in a suite that mutates process-global state; a fixture of one character can leak into unrelated assertions.
- Register a new protection's mutation in the suite's **own** mutation harness, and extend the checker that harness runs. A hand-rolled mutation case that re-implements the edit outside the harness passes vacuously whenever the protection it means to remove is absent — it asserts nothing about the unfixed code, so it is green against both revisions and catches nothing. Verified 2026-09-11: a pin-removal case repeated the `sed` by hand and the repo's guard function never checked the pin, so neither could fail; the same mutations registered in the real harness caught them.
