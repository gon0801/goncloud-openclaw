# Live-leak and red-first probes

Read from `test-discrimination-verify` §6 when the change fixes a real bug, or when the claim is a parse or environment cause.

## Two revisions, side by side

Write the previous revision to a temp path (`git show <sha>:<path>`) and load it with `importlib.util.spec_from_file_location` next to the current module (two throwaway modules; the repo stays untouched). Drive the failing input through each and capture `stderr` with `contextlib.redirect_stderr`. The leak must reproduce on the old revision and be closed on the new. Then revert the fix in the tree and confirm the new regression test goes **RED** — red-first, never omitted. (A common shape: an exception handler that returns without clearing `record.msg`/`args`, so logging prints the raw secret in its own error output.)

## Parse or environment cause

When the claim is a **parse or environment cause** — a script that did not parse under the system interpreter, a harness whose helper died without the right binary on `PATH` — the fix is proven the same way: run the **pre-fix revision** (`git show <base>:<path>` into a temp path, or the mutated copy) through the **same runner and the environment the claim names**, and show the named test or command go RED; then the fixed revision GREEN.

Resolve that interpreter by absolute path: the runner's default is often a different version at a different location (`/bin/bash` 3.2 on macOS vs a homebrew bash 5; the `node` on `PATH` vs the version the evidence cites), and reproducing under the wrong one proves nothing. The discriminating variable is the environment, so revert the file or the environment — not just your reading of the diff.
