---
name: goncloud-ssh-ops
description: "Run diagnostics or deploy app changes on the goncloud Linux server over SSH (Windows gateway or Mac node route); clean remote output without PowerShell quoting or CRLF failures."
---

# goncloud SSH operations

## When

Any task that reads or changes state on the goncloud server (logs, docker, git, app files under /mnt/data/appdata), including deploying app changes.

## Reaching the server

- From the Windows gateway: `ssh -o BatchMode=yes -o ConnectTimeout=8 claw@goncloud '<cmd>'`.
- From the Mac node ("David's MacBook Pro"): `ssh -o BatchMode=yes gonserver '<cmd>'` — root@10.13.13.1 through `~/.ssh/goncloud-mexico` (alias in `~/.ssh/config`). As root, `docker`/`git` need no sudo. `claw@10.13.13.1` from the Mac fails with `Permission denied (publickey)`.
- If gateway exec is denied (exec host pinned to the node), use the Mac route. BatchMode avoids password-prompt hangs on both.

## Steps

1. Simple one-liners without quotes/parens: as above. Anything with quotes, parentheses, or globs: write the bash script to a local file with the write tool, then pipe it **with CR stripped** — write-tool scripts carry CRLF and die remotely with `$'\r': command not found` (verified 2026-09-09):
   `((Get-Content -Raw <script>.sh) -replace "`r","") | ssh -o BatchMode=yes claw@goncloud bash -s`
   Never inline nested quotes in the PowerShell exec command — PowerShell double-parsing strips them and bash fails with syntax errors.
2. From the gateway, `docker` and `git` under /mnt/data/appdata are root-owned: prefix `sudo -n` (plain `docker ps` returns permission denied there).
3. Inspecting app containers: use `docker top <container> aux` — container images often lack `ps`, so in-container `ps` returns nothing and looks like "no process" (verified). DB reads without touching secrets: `docker exec <db-container> sh -lc 'psql -U $POSTGRES_USER -d $POSTGRES_DB -Atc "<sql>"'`.
4. `pkill -f <pattern>` can match your own ssh command line and kill the session mid-run (exit 16777215) — bracket a character (`pkill -f 'a6_wa[t]ch'`) or check with `pgrep` first.
5. Deploying an app change: runtime dirs ARE live git checkouts (`/mnt/data/appdata/<app>`) — there `git pull origin main`, find the unit (`systemctl list-units --type=service | grep -i <name>`; unit names differ from repo docs, e.g. accounting → `goncloud-dashboard`), restart it, then verify live by curling the service port (HTML/API of the changed thing). Repo `deploy.sh` headers can describe a stale flow (`/mnt/data/repos` does not exist) — trust the live layout. Restart only the target service; if the app runs in Docker instead of systemd, rebuild/recreate only its service (`docker compose up -d --no-deps --build <svc>`) and leave the DB container untouched.
6. Delete the local helper script when the remote work is done.

Completion check: remote output returns with no bash/CRLF errors; changes re-read from the server (or curl'd live) to confirm they landed.
