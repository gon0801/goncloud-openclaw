---
name: gateway-cli-setup
description: Install a CLI tool and wire its token credentials on the Windows gateway host. Use when a winget install hangs at "Starting package install...", a freshly installed command is "not recognized" in the next exec, or a token file must become CLI auth plus a User env var (e.g. GH_TOKEN) without ever printing it. Produces a working, authenticated tool with the secret file destroyed and the variable verified.
---

# Gateway CLI Setup (Windows host, token auth)

Install and authenticate a CLI tool from agent exec on the Windows gateway host. Verified 2026-09-12 with GitHub CLI (`gh`) 2.100.0: winget hung, the portable-zip fallback completed end to end.

## Steps

1. Try winget first: `winget install --id <Id> -e --accept-source-agreements --accept-package-agreements --disable-interactivity`. Bound the wait: if output stalls at "Starting package install..." for ~5 minutes with `winget` and a spawned `msiexec` alive and no new output (verified: 15+ min silent hang on `GitHub.cli`), stop polling — the install is wedged, not slow.
   - Completion: install finishes, or two consecutive polls with identical output plus live installer processes confirm the wedge.

2. Kill the wedged installer and fall back to the portable zip. `Stop-Process -Name winget,msiexec -Force -ErrorAction SilentlyContinue` kills winget and the spawned installer msiexec; the Windows Installer **service** msiexec survives. The exec session then exits code 1 — that is the kill, not a new failure. Download the release zip (`Invoke-WebRequest -Uri <zip-url> -OutFile "$env:TEMP\<tool>.zip"`) and `Expand-Archive "$env:TEMP\<tool>.zip" -DestinationPath <tools-dir> -Force`.
   - The zip may have **no top-level folder**: gh 2.100.0's zip extracted straight into `<tools-dir>\bin\gh.exe`, not `<tools-dir>\<name>\bin\`. Locate the exe before wiring PATH: `Get-ChildItem <tools-dir> -Recurse -Filter <tool>.exe`.
   - Completion: the exe exists at a known path with a non-zero size.

3. Wire PATH and refresh it **inline in every later exec call**. Persist it for the agents:
   `$p='<bindir>'; $cur=[Environment]::GetEnvironmentVariable('Path','User'); if($cur -notlike "*$p*"){[Environment]::SetEnvironmentVariable('Path',"$cur;$p",'User')}`
   But environment changes do **not** reach subsequent exec calls: each exec is a new process inheriting the gateway's startup environment (verified: `<tool>` was "not recognized" in the call right after the User PATH update succeeded). Until the gateway restarts, prefix every command that needs the tool with `$env:Path += ';<bindir>'` or call the exe by full path.
   - Completion: `<tool> --version` returns in the same call as the inline refresh.

4. Authenticate from the token file without exposing it: `Get-Content <token-file> | gh auth login --with-token` — gh stores the token in its keyring, so auth survives the file's later deletion. Verify `gh auth status` and `gh api user --jq .login`. If the task also needs git-over-HTTPS credentials, run `gh auth setup-git` (owner-requested in the original brief; not reached in the verified run).
   - Completion: auth status shows the account and the API call returns the login.

5. Env var and secret-file ordering — the owner's stated rule for token-file setups: set the env var from the file **before** deleting the file, never the reverse. `[Environment]::SetEnvironmentVariable('GH_TOKEN', (Get-Content <token-file> -Raw).Trim(), 'User')`; verify with a boolean only, `[Environment]::GetEnvironmentVariable('GH_TOKEN','User') -ne $null` → True. Then `Remove-Item <token-file> -Force` and confirm `Test-Path <token-file>` → False.
   - If a later instruction says "delete it now" while the file is still the only source for a pending step, do **not** delete: say the file still feeds a pending step and delete only after that step completes. Deleting early destroys the token and makes the remaining steps impossible.
   - Completion: env var verified non-null, token file gone, contents never printed.

6. Clean up: `Remove-Item "$env:TEMP\<tool>.zip" -Force` and confirm it is gone.

## Pitfalls

- Verify env vars with the registry-backed read (`[Environment]::GetEnvironmentVariable(<name>,'User')`), which works in any process regardless of the stale process environment — not with `$env:<NAME>`, which still shows the old value.
- Never print the token file's contents or the variable's value: reads go straight into the command (pipe, `-Raw`), never into output; report only booleans and command results.
- `Test-Path` before assuming a download or extraction succeeded; `Expand-Archive -Force` overwrites silently and a partial extraction can hide the exe one level off the expected path.
