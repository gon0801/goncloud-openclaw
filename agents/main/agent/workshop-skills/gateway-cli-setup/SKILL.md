---
name: gateway-cli-setup
description: Install and authenticate a CLI tool from agent exec on the Windows gateway host — token-file auth (e.g. GH_TOKEN) or npm-global install with browser-OAuth login (e.g. Claude Code). Use when winget hangs at "Starting package install...", a freshly installed command is "not recognized" in the next exec, or a token file must become CLI auth plus a User env var without ever printing it. Produces a working, authenticated tool; the token path ends with the secret file destroyed and the variable verified.
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
   - End state: the owner-run gateway restart propagates the User PATH and the env var into new exec sessions — verified 2026-09-12: after it, bare `<tool>` calls and `$env:<VAR>` worked with no inline refresh; retire the workaround then. Sessions that predate that restart keep the stale environment even when the registry-backed reads confirm PATH, exe and token are all set (same day, earlier: "not recognized" and empty `$env:GH_TOKEN` alongside User-level True/True) — read that as a stale context, not a failed install, and do not re-run the install for it.

4. Authenticate from the token file without exposing it: `Get-Content <token-file> | gh auth login --with-token` — gh stores the token in its keyring, so auth survives the file's later deletion. Verify `gh auth status` and `gh api user --jq .login`. If the task also needs git-over-HTTPS credentials, run `gh auth setup-git` (owner-requested in the original brief; not reached in the verified run).
   - Completion: auth status shows the account and the API call returns the login.

5. Env var and secret-file ordering — the owner's stated rule for token-file setups: set the env var from the file **before** deleting the file, never the reverse. `[Environment]::SetEnvironmentVariable('GH_TOKEN', (Get-Content <token-file> -Raw).Trim(), 'User')`; verify with a boolean only, `[Environment]::GetEnvironmentVariable('GH_TOKEN','User') -ne $null` → True. Then `Remove-Item <token-file> -Force` and confirm `Test-Path <token-file>` → False.
   - If a later instruction says "delete it now" while the file is still the only source for a pending step, do **not** delete: say the file still feeds a pending step and delete only after that step completes. Deleting early destroys the token and makes the remaining steps impossible.
   - Completion: env var verified non-null, token file gone, contents never printed.

6. Clean up: `Remove-Item "$env:TEMP\<tool>.zip" -Force` and confirm it is gone.

## npm route with OAuth login (verified: Claude Code 2.1.270, 2026-09-12)

For npm-distributed CLIs the zip/winget path does not apply; auth is a browser OAuth wizard, not a token file.

A. `npm install -g <pkg>` (node + npm are already on the gateway). An `npm warn allow-scripts ... postinstall` warning is non-fatal — verify with `<tool> --version` before re-running anything with `--allow-scripts` (verified: Claude Code worked fully with the postinstall script blocked).
   - Completion: `<tool> --version` returns a version.
B. OAuth login needs a real TTY: exec with `pty: true`, then drive the first-run wizard with `process send-keys` — Enter through the theme prompt and the login-method prompt; the OAuth URL opens in the owner's browser and the owner completes the sign-in. Verify from the PTY log ("Logged in as <account>", "Login successful") plus the tool's credentials file existing (e.g. `Test-Path "$env:USERPROFILE\.claude\.credentials.json"` → True) — never from the process exit code.
   - The wizard can end on a "trust this folder" prompt and the pty session may then die with exit 1: auth is already stored by then, so an unanswered trust prompt is not a failed login — re-check the credentials file instead of re-running the wizard.
   - Completion: login-success line in the PTY log and the credentials file present.

## Pitfalls

- Verify env vars with the registry-backed read (`[Environment]::GetEnvironmentVariable(<name>,'User')`), which works in any process regardless of the stale process environment — not with `$env:<NAME>`, which still shows the old value.
- Never print the token file's contents or the variable's value: reads go straight into the command (pipe, `-Raw`), never into output; report only booleans and command results.
- `Test-Path` before assuming a download or extraction succeeded; `Expand-Archive -Force` overwrites silently and a partial extraction can hide the exe one level off the expected path.
