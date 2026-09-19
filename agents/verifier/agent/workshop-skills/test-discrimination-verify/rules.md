# Rules that make a mutation run valid

Read from `test-discrimination-verify` before mutating.

## Prove it on the real artifact

Never accept the author's mutation report; reproduce each one yourself.

## Count collected tests on every run

If the count differs from baseline the run is INVALID, not RED.

## ROJO means a named test FAILED

"0 failed" with 0 collected is a false green, usually a syntax error.

## Mutate the artifact the runner actually loads

For a suite that imports a module by name, that is the in-tree module — a copy stays green and fakes "the mutation breaks nothing". When the runner loads the file **by path** (`node --test`, a shell script, a copied harness) or the tree is read-only for you, mutate a copy and run the runner there. Never commit a mutation. Back up the bytes + hash, and verify `git diff --quiet <module>` after every restore. In a hand-run battery, re-copy the artifact before **each** mutation: appending the next mutation to a copy that already holds the previous one makes the earlier line the cause of the RED, and the later mutant is classified ROJO while it never failed. A survivor can only be trusted on a clean copy.

## Confirm the mutation landed before reading the verdict

A find-and-replace that missed (escaped `$`, a quote style that never matched) leaves the file unchanged and the suite GREEN. Print the changed line or compare the hash before/after; an unapplied mutation is INVALID, never VERDE.

## Deleting and weakening are different proofs

A battery that is green-proof against deletion can still be blind to a narrowed guard.

## Text predicates need input mutations

When the protection is itself a **text predicate** — a `grep -E` anti-anchor, a regex guard, a linter pattern — mutating code proves nothing; mutate the **input phrasing**: reverse the word order, use the passive voice, split the term across lines, swap a synonym. A guard written `interfaz.*(calcula|infiere)` catches only that order and passes `se calcula por la interfaz`, and its own self-probe still reports OK because the probe tests the phrasing its author had in mind. Probe the artifact **and** re-read the probe's own probe text.

## Both shapes where each exists

Every protected behavior gets a deletion mutation and, where the shape exists, a weakening mutation. One mutation per protected behavior/branch.

## Verdicts

- Syntax error **or** collected != baseline → **INVALID**. Fix the mutation and re-run. Never report INVALID as RED or GREEN.
- A named test fails, collected == baseline → **ROJO** (discriminates).
- All pass, collected == baseline → **VERDE** (does NOT discriminate; report it).

## Cost

Run only the focused test file per mutation. The full battery runs once (repo CI), not per mutation.
