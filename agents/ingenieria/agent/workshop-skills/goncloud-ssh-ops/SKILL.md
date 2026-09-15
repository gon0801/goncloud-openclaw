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
5. Deploying an app change — inspect the live layout first, then take one branch. Precondition for BOTH branches: the approved SHA is already on the deploy branch (merge before deploy — declared as precondition, not a note). Both branches: back up `app/` as `app.bak-predeploy-$(date +%Y%m%d-%H%M)` and after restart run the smoke check with the HTTP status code (`curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:<port>/<healthpath>` must be 200), not just "service is up". The deploy closes with the line `Live <SHA> en <URL>` (SHA = merged commit, URL = the app's URL:int:port from the machines table of goncloud-workspace-main).
   - From the Mac repo: `git fetch origin` and confirm the approved SHA is in `origin/master` (`git log -1 --oneline origin/master` is the merge, or `git merge-base --is-ancestor <sha> origin/master`). For a squash-merged PR the branch SHA is NEVER an ancestor even when the content shipped — confirm by the `(#NNN)` squash commit and a content marker in the deployed files, not by ancestry (see mac-node-ops step 8). Agents cannot merge; never archive a feature branch.
   - Layout check: `git -C /mnt/data/appdata/<app> status --short` + `git -C /mnt/data/appdata/<app> rev-list --left-right --count HEAD...origin/master`. Clean and on the deploy branch → back up `cp -a app app.bak-predeploy-$(date +%Y%m%d-%H%M)` first, then `git pull origin <branch>` (accounting-style); smoke with HTTP code + `Live` line per step 5 preamble. Dirty or far behind (backup `app.bak-predeploy-<timestamp>` already covered by the archive command below; smoke with HTTP code + `Live` line per step 5 preamble). Dirty or far behind (orbit: 187 commits + local edits; its `docs/DEPLOY.md` says the server is not a checkout) → do NOT pull; ship from the repo: `git archive --format=tar origin/master app Dockerfile .dockerignore pyproject.toml uv.lock tools/fabrica_campanas.py | ssh gonserver 'cd /mnt/data/appdata/orbit && cp -a app app.bak-predeploy-$(date +%Y%m%d-%H%M) && tar -xf -'` (archive keeps LF; back up `app/` first), then confirm shipped files match `git show origin/master:<path> | md5`.
   - Restart only what changed: systemd (`systemctl list-units --type=service | grep -i <name>`; unit names differ from repo docs, e.g. accounting → `goncloud-dashboard`) or Docker (`docker compose up -d --no-deps --build <svc>`); leave the DB container untouched. A real Docker deploy logs `Recreated` — `CACHED` + `Running` means the image did not change, i.e. the code was never copied.
   - Verify: `/health` returns ok; `ss -lntp | grep <port>` binds `127.0.0.1:<port>` and `10.13.13.1:<port>` (never `*:<port>`); `secrets/` perms unchanged (700). Rollback: `mv app.bak-predeploy-<fecha> app` (keep the new one) + rebuild.
   - Repo `deploy.sh` headers can describe a stale flow (`/mnt/data/repos` does not exist) — trust the live layout and `docs/DEPLOY.md`.
6. Delete the local helper script when the remote work is done.

Completion check: remote output returns with no bash/CRLF errors; changes re-read from the server (or curl'd live) to confirm they landed.
