<!-- project: github.com/gon0801/goncloud-openclaw -->
# Fallbacks when exec denies the cron CLI

Read this when the SKILL.md trigger fires: `openclaw cron` denied by the approval binder (`approval cannot safely bind this command` / `approval script operand changed`, typically after gateway restarts, with `Approved executables: none` in context).

**Contract check (AGENTS.md):** a confirmed cron CLI denial is a real block — report the exact command and the exact error to David, and do not route the same edit around it through another host or another profile. What follows is what may still work and how to keep the run verifiable while blocked (owner-run script, Control UI, post-run verification); it is not a licence to bypass the denial.

## Do not assume total lockout

- Simple literal `ssh <host> "<command>"` exec shapes may still pass while the CLI is denied.
- The first-class `automations` tool can still ADD self-owned one-shot wakeups (schedule `{kind:"at"}`, `sessionTarget:"current"`, delivery announce) even while its caller-scoped inventory reports the cron jobs as not found — use one to schedule post-run verification while the CLI is locked; it auto-deletes after firing.
- Creating the wakeup by CLI instead (`node ...openclaw.mjs cron add --name <n> --at <ISO+offset> --session current --announce --delete-after-run --message <text>`): pass `--agent operaciones` explicitly — without it the job runs under the configured DEFAULT agent (fixable afterwards with `cron edit <id> --agent operaciones`) — and `announce -> last` will fail-closed for isolated one-shots (the deliveryPreview warns); have the wakeup's message instruct reporting via sessions_send, which closes the loop regardless.

## Verified fallback: owner-run script

Hand the owner a `.ps1` that runs `openclaw cron edit <job-uuid> --message "$(Get-Content -Raw '<prompt file>')"` for each job plus `cron get` verifications — the owner terminal is not subject to the agent approval binder.

Control UI → Automations paste is the no-terminal alternative.
