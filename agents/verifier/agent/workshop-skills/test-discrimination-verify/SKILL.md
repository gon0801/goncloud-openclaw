---
name: test-discrimination-verify
description: Verify tests discriminate — revert or weaken each protection (pytest, node, shell), confirm RED. Count collected tests to kill false green.
---

# Verify test discrimination by mutation

Trigger: someone claims new tests "protect" a behavior, or asks whether a suite would catch a regression. A test that passes with and without the fix protects nothing — it is worse than no test, because it buys false confidence.

## Rules

- Prove it on the real artifact. Never accept the author's mutation report; reproduce each one yourself.
- Count collected tests on **every** run. If the count differs from baseline the run is INVALID, not RED.
- ROJO real = a named test **FAILED**. "0 failed" with 0 collected is a false green, usually a syntax error.
- Mutate the artifact the runner **actually loads**. For a suite that imports a module by name, that is the in-tree module — a copy stays green and fakes "the mutation breaks nothing". When the runner loads the file **by path** (`node --test`, a shell script, a copied harness) or the tree is read-only for you, mutate a copy and run the runner there. Never commit a mutation. Back up the bytes + hash, and verify `git diff --quiet <module>` after every restore. In a hand-run battery, re-copy the artifact before **each** mutation: appending the next mutation to a copy that already holds the previous one makes the earlier line the cause of the RED, and the later mutant is classified ROJO while it never failed. A survivor can only be trusted on a clean copy.
- **Confirm the mutation landed before reading the verdict.** A find-and-replace that missed (escaped `$`, a quote style that never matched) leaves the file unchanged and the suite GREEN. Print the changed line or compare the hash before/after; an unapplied mutation is INVALID, never VERDE.
- Deleting a protection and **weakening** it are different proofs: a battery that is green-proof against deletion can still be blind to a narrowed guard.
- When the protection is itself a **text predicate** — a `grep -E` anti-anchor, a regex guard, a linter pattern — mutating code proves nothing; mutate the **input phrasing**: reverse the word order, use the passive voice, split the term across lines, swap a synonym. A guard written `interfaz.*(calcula|infiere)` catches only that order and passes `se calcula por la interfaz`, and its own self-probe still reports OK because the probe tests the phrasing its author had in mind. Probe the artifact **and** re-read the probe's own probe text.
- Run only the focused test file per mutation. The full battery runs once (repo CI), not per mutation.

## Steps

1. **Base.** `git branch --show-current`, `git log --oneline -1`, `git status --porcelain` (must be clean). `git diff --stat <base>..<head>` and `git diff --name-only` — confirm scope and whether the module under test was really left untouched. Run the focused suite; record baseline pass count and its `--collect-only` count.
2. **Backup.** Copy the module out and hash it (`shasum -a 256`). Keep the hash to prove restoration later.
3. **Battery — deletion and weakening.** One mutation per protected behavior/branch, using both shapes where each exists:
   - **Deletion**: remove the protection outright.
   - **Weakening**: a syntactically valid change that keeps the code running but narrows the protection. The usual un-tested spots are thresholds (`len(value) < 2`), guards (`or` reduced to one condition), orderings (`sorted(..., key=len, reverse=True)` → `list(...)`), comparison caps (`len(password) > 3`), and returned forms (`=***` → `=***REDACTED***`). A deletion-only battery signs all of these off as safe.
   For each: apply → syntax gate → count gate → run focused suite → classify → restore. Use `scripts/mutation_battery.py`.
   - Syntax error **or** collected != baseline → **INVALID**. Fix the mutation and re-run. Never report INVALID as RED or GREEN.
   - A named test fails, collected == baseline → **ROJO** (discriminates).
   - All pass, collected == baseline → **VERDE** (does NOT discriminate; report it).
4. **False-green probe.** Deleting a line inside a block yields `IndentationError` → "no tests collected, 1 error". Reproduce it once so the distinction is evidence-backed, then prefer a syntactically valid revert that mirrors the real bug shape.
5. **Coupling probe.** Apply 3–5 behavior-preserving refactors (rename a local, drop a redundant guard, swap equivalent calls). All must stay GREEN. A refactor that turns RED means the test is coupled to implementation, not behavior.
6. **Live-leak / red-first probe (fix changes).** When the change fixes a real bug, prove both ends by loading two revisions side by side: write the previous revision to a temp path (`git show <sha>:<path>`) and load it with `importlib.util.spec_from_file_location` next to the current module (two throwaway modules; the repo stays untouched). Drive the failing input through each and capture `stderr` with `contextlib.redirect_stderr`. The leak must reproduce on the old revision and be closed on the new. Then revert the fix in the tree and confirm the new regression test goes **RED** — red-first, never omitted. (A common shape: an exception handler that returns without clearing `record.msg`/`args`, so logging prints the raw secret in its own error output.)
   When the claim is a **parse or environment cause** — a script that did not parse under the system interpreter, a harness whose helper died without the right binary on `PATH` — the fix is proven the same way: run the **pre-fix revision** (`git show <base>:<path>` into a temp path, or the mutated copy) through the **same runner and the environment the claim names**, and show the named test or command go RED; then the fixed revision GREEN. Resolve that interpreter by absolute path: the runner's default is often a different version at a different location (`/bin/bash` 3.2 on macOS vs a homebrew bash 5; the `node` on `PATH` vs the version the evidence cites), and reproducing under the wrong one proves nothing. The discriminating variable is the environment, so revert the file or the environment — not just your reading of the diff.
7. **Fixtures.** Invented and distinctive — never real values, never values that collide with suite text. Match the fixture to the mutation it must catch:
   - **Length vs threshold**: an N-character fixture only catches floors **greater than N**. Exactly 1 character is the only thing that catches a `< 2` floor; `c0rt4!` (6 chars) catches an 8 floor, not a 2 floor.
   - **Ordering**: register the **shorter** secret first, or the natural order already replaces the long one first and the mutation survives.
   - **Form**: assert **exact equality** on the full deterministic output — `"password=***" in out` survives a change to `password=***REDACTED***`.
   - The secret registry is process-global and never cleared: pick a short, non-alphanumeric fixture that appears nowhere else the suite passes through `scrub()` (documented trap: a bare 1-char `T` breaks `nextToken`). Grep the literals and eyeball them.
8. **Restore + verify.** Write the backup back, confirm the hash matches, `git diff --quiet <module>`, `git status` clean, branch and HEAD unchanged.
9. **Report.** Table: protection reverted → mutation → test → real result (ROJO/VERDE/INVALID) → how restored. Then name any test that does NOT discriminate, and any uncovered gap you found. State unrun scope explicitly (e.g. full CI still pending). Do not invent a fix to justify a one-time brief.

## Completion

Every protection has a deletion **and** (where it exists) a weakening mutation, each with collected == baseline and a clear ROJO/VERDE. Non-discriminating tests are named. Module hash restored, tree clean, `git diff` empty. Gaps and unrun scope stated, not hidden.

Supporting file: `scripts/mutation_battery.py` — a Python/pytest template that runs the whole battery and prints one classified line per mutation.
