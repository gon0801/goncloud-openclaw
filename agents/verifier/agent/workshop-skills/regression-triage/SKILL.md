---
name: regression-triage
description: Preexisting or new failure — classify PR test, lint and CI red against the base. HEAD-vs-BASE runs, per-module runner replica, full-battery survival, CI step, skipped gates.
---

# Attribute failures: preexisting or new

Trigger: a PR is red (tests or CI), or an author says failures are "preexisting", "environmental", "falta de deps", or reports a green focused subset while the full run is red. An author label is a claim, never evidence.

Checkpoints: §1 environment · §2 HEAD vs BASE (tests and lint) · §3 full battery · §4 runner replica · §5 CI classification · §6 skipped gate · §7 report.

## 1. Build the real environment first

A failure whose cause is a missing import is an **environment artifact**, not a preexisting failure. Read the declared deps (Dockerfile, `requirements.txt`, `pyproject.toml`) and install them in a throwaway venv:

- `python3 -m venv /tmp/venv-verif && /tmp/venv-verif/bin/pip install -r <requirements>`
- If one package fails to build and is unrelated to the module under test (e.g. Pillow on a newer Python), drop only that line so the rest installs — name the omission in the report.
- Call the interpreter by absolute path for every later run. A repo "shim" (e.g. a `python3.14` on PATH) may not exist in your shell.
- Pin the clock too: CI runs UTC and the dev machine does not. A test green locally but red in CI can flip solely on the day boundary — re-run with `TZ=UTC` before labeling anything (`TZ=UTC date` vs `date`).

Done when: the focused tests run without import errors under the CI-pinned environment, or you can name the dep you could not install.

## 2. HEAD vs BASE, same interpreter and pinned env

Run the **same focused tests** on the branch and on the base revision, under the same pinned environment (same interpreter, same `TZ`):

- `git worktree add --detach /tmp/<repo>-base origin/<default>`; confirm `git log --oneline -1` is the base SHA.
- Pin the subject first: `git rev-parse HEAD` must match `git ls-remote origin refs/heads/<branch>`. A SHA quoted in the dispatch or PR body is a claim — verify it exists (`git cat-file -t <sha>`), never validate against it.
- Report both sides: `HEAD: <counts>` vs `BASE: <counts>`. Only HEAD-fail/BASE-pass tests count against the change; fail-on-both is preexisting.

**Lint is a second HEAD-vs-BASE axis.** Run the repo's exact lint select on both revisions (a common CI set is `ruff check --select=E9,F63,F7,F82 app/ tools/`). A lint error present only on HEAD is a new blocking finding even when every test is green. The usual source when a change disables a behavior: a no-op or early `return` inserted before the original body leaves the orphaned body in the file — unreachable at runtime, but the linter still reads its names, so `F821 Undefined name` fires and the CI lint job fails. "Inaccesible, sin efecto" is the author's claim; this run disproves it. Lint the changed files and a base copy (write `git show <base>:<path>` into a temp dir) to label each error.

Done when: every failing test and every lint error is labeled `nuevo` or `preexistente` by its own two runs.

## 3. One full battery, and prove the run survived — read `full-battery.md`

Read `full-battery.md` before launching the single allowed full-suite pass, and again if the exec host drops mid-run.

Done when: the battery has an exit sentinel in its log, or the run is declared **dead** and the battery still unspent.

## 4. Replicate the repo's own runner

Read the CI config before picking a command. If CI isolates per module (`for f in tests/test_*.py; do python3 -m unittest tests.$mod; done`), run per module: one combined invocation loads all modules in a single process, cross-module global state leaks, and a different set of tests fails. A different runner is a different result — do not mix them.

Same for lint: use the exact `--select=` from the repo's workflow, not a generic default.

## 5. Classify CI red

1. Head-SHA run: `…/actions/runs?head_sha=<sha>`, then `…/actions/runs/<id>/jobs` → the step with `conclusion: failure`.
2. Base branch's run of the **same workflow**: `…/actions/runs?branch=<default>&per_page=3`, matching the base SHA.
3. Same step red on base ⇒ preexisting. Different step ⇒ the change's.

Notes: job logs need admin (403) and a private repo can 404 on `repos/…` or `check-runs` — a missing or unreadable check is **not** green; say "no verifiqué". `…/check-runs/<id>/annotations` sometimes carries the failing file/line. A CLI (`gh`) missing from the default PATH is not unreadable CI — resolve it by absolute path (e.g. `/opt/homebrew/bin/gh`) and keep going.

## 6. Skipped gate / `--no-verify`

Find the hook's own command (`.pre-commit-config.yaml`, `.git/hooks/pre-push`), run it by hand on the pushed tree, and report whether it would have blocked. The flag itself is never the verdict and needs no re-push to fix — but when the hand-run hook **would have blocked**, that is a blocking finding on the **tree**, and the fix is a content fix (which does require a push). Note which paths the hook covers: one that excludes a single file still gates every other changed file. A skipped hook is exactly how a lint-detectable defect reaches CI, so `--no-verify` is acceptable only if the hand-run shows the hook would have passed.

## 7. Report

Per claim: exact command + observed counts (HEAD vs BASE, collected counts, exit codes). Label each red `nuevo`/`preexistente`, and name anything you could not run or read. Never present a re-push as the fix when the tree is unchanged.

Completion: every red has a label backed by its artifact; deps built or the missing one named; skipped gates run by hand; worktrees/venvs accounted for.
