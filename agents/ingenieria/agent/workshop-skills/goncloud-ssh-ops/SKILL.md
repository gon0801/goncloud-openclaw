---
name: goncloud-ssh-ops
description: "Run diagnostics or deploy app changes on the goncloud Linux server over SSH from the Windows gateway; clean remote output without PowerShell quoting or CRLF failures."
---

# goncloud SSH operations (from Windows gateway)

## When

Any task that reads or changes state on the goncloud server (logs, docker, git, app files under /mnt/data/appdata), including deploying app changes.

## Steps

1. Simple one-liners without quotes/parens: `ssh -o BatchMode=yes -o ConnectTimeout=8 claw@goncloud '<command>'` (BatchMode avoids password-prompt hangs).
2. Anything with quotes, parentheses, or globs: write the bash script to a local file with the write tool, then pipe it **with CR stripped** — write-tool scripts carry CRLF and die remotely with `$'\r': command not found` (verified 2026-09-09):
   `((Get-Content -Raw <script>.sh) -replace "`r","") | ssh -o BatchMode=yes claw@goncloud bash -s`
   Never inline nested quotes in the PowerShell exec command — PowerShell double-parsing strips them and bash fails with syntax errors.
3. `docker` and `git` under /mnt/data/appdata are root-owned: use `sudo -n <cmd>` (passwordless sudo works for claw; plain `docker ps` returns permission denied).
4. Deploying an app change: runtime dirs ARE live git checkouts (`/mnt/data/appdata/<app>`) — there `sudo -n git pull origin main`, find the unit (`sudo -n systemctl list-units --type=service | grep -i <name>`; unit names differ from repo docs, e.g. accounting → `goncloud-dashboard`), `sudo -n systemctl restart <unit>`, then verify live by curling the service port (HTML/API of the changed thing). Repo `deploy.sh` headers can describe a stale flow (`/mnt/data/repos` does not exist) — trust the live layout. Restart only the target service.
5. Delete the local helper script when the remote work is done.

Completion check: remote output returns with no bash/CRLF errors; changes re-read from the server (or curl'd live) to confirm they landed.
