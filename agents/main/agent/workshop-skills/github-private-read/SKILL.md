---
name: github-private-read
description: Read files, PR state and commit metadata from a private GitHub repo from agent exec when web_fetch or raw.githubusercontent return 404. Use when a task names a private-repo file (runbook, Plans.md, JSON config) and gh is authenticated, or when gh api rejects a flag you expected. Produces the decoded file plus the remote state reads behind it.
---

# GitHub Private Read (gh api)

`web_fetch` and `raw.githubusercontent` answer 404 on private repos without a token. The owner's gh CLI is the route (install/auth: `gateway-cli-setup`). Verified 2026-09-18 on the Windows gateway against `gon0801/goncloud-openclaw` (64 KB runbook, Plans.md, loop doc, JSON config, PR and commit reads).

## Steps

1. Confirm access first: `gh auth status`, then
   `gh api repos/<owner>/<repo> --jq "{default_branch, private, full_name}"`.
   - Completion: the repo reads back `private:true` with its default branch.

2. Read a file through the contents API and decode it with node — there is no python3 on this host:
   ```powershell
   gh api repos/<owner>/<repo>/contents/<path> --jq ".content" > tmp/<name>-b64.txt
   node -e "const fs=require('fs'); let b64=fs.readFileSync('tmp/<name>-b64.txt','utf8').replace(/[^A-Za-z0-9+/=]/g,''); fs.writeFileSync('tmp/<name>',Buffer.from(b64,'base64'));"
   ```
   The API wraps the base64 with newlines, so strip everything outside `[A-Za-z0-9+/=]` before decoding. Never `node -e` under PowerShell for anything longer — quoting mangles it; this one-liner is the verified size limit, anything bigger goes in a `.js` file (see `gateway-delivery-queue` step 1).
   - Completion: the output file is non-zero and its head matches the expected format (blob SHA via `git rev-parse <ref>:<path>` when a clone exists to cross-check).

3. Read PR and commit state from the API, never from a local clone's branch position (see `owner-report-delivery`):
   `gh api repos/<owner>/<repo>/pulls/<n> --jq "{number, state, merged, merged_at, title, base: .base.ref, head: .head.ref}"`,
   `gh pr list --repo <owner>/<repo> --state all --json number,title,state,headRefName`,
   `gh pr checks <n> --repo <owner>/<repo>`.
   - Completion: merged/state/base/head come from the remote.

## Pitfalls

- `gh api` has no `--per-page`-style flags: `--per-page` dies with `unknown flag` (verified). For GET list endpoints put params in the endpoint query string — `gh api "repos/<owner>/<repo>/commits?per_page=1"` works — and do NOT use `-F` for them: `-F per_page=1` on a GET answered `Not Found` (verified).
- PowerShell splits an unquoted multi-segment `gh api` endpoint into separate args: `gh api repos/<owner>/<repo>/commits/<sha>/check-runs` dies with `gh: accepts 1 arg(s), received 5` (verified 2026-09-18). Wrap the endpoint in one quoted arg — `gh api ('repos/<owner>/<repo>/commits/<sha>/check-runs')` — same class as the query-string rule above.
- A fresh clone has no git identity: the first commit fails `unable to auto-detect email address` — `git-commit-push` step 1 (repo-local `openclaw-auto`).
- PowerShell paints gh/gh-api stderr red and may exit 1 on success output (credential/progress noise): judge by the returned data plus a read-back, not the colour or the code (same class: `git-commit-push`, `openclaw-config-patch` pitfalls).
