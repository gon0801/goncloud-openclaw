---
name: openclaw-config-patch
description: Patch OpenClaw config from a JSON5 file, and provision a new agent. Use when asked to change models/agents/channels/logging config, when the config tool refuses with "Direct config writes cannot change models", when `openclaw config patch` refuses with "Refusing to replace ... it would remove existing entries", when a model named in an agent chain fails validation, or when adding an agent that must run on the Mac node. Produces an applied, read-back change.
---

# OpenClaw Config Patch (JSON5 file)

Apply config changes with `openclaw config patch --file` through its dry-run gate and past the two non-obvious validation guards. Verified 2026-09-10 (model and agent-chain patches, and provisioning a new agent; all applied hot).

## Steps

1. Write the patch to a file (e.g. `$env:TEMP\<name>.json5`) and dry-run it:
   `openclaw config patch --file <path> --dry-run`
   Objects merge recursively, `null` deletes a path, arrays and scalars replace.
   - The system-expert config tool cannot write every namespace: `models.*` (provider/catalog definitions feed routing) is refused there with "Direct config writes cannot change `models`" — owner approval does not change that. The CLI `openclaw config patch --file` **can** write it. When the config tool refuses a path for this reason, do not retry it there; switch to the file patch.
   - A provider-level knob like `models.providers.<id>.timeoutSeconds` patches with a recursive merge and `reloadKind: hot` — confirm from `gateway config.schema.lookup <path>` before assuming a restart is needed.
   - The owner's standing rule: apply without `--dry-run` only once the dry-run passes.
   - Completion: "Dry run successful: N update(s) validated", or one of the guards below to resolve.

2. Guard "Refusing to replace <path>; it would remove existing entries: <ids>. Use --merge to merge by id or --replace to replace intentionally." — it fires when the patch's array drops existing entries. The suggested `--replace` does **not** exist; the real flag is `--replace-path <dot.path>` (repeatable). Re-run naming the exact array:
   `openclaw config patch --file <path> --dry-run --replace-path models.providers.<provider>.models`
   - Completion: the dry-run passes with `--replace-path`.

3. Register before referencing: a model must exist in `models.providers.<p>.models[]` before any chain may name it in `agents.defaults.models` or `agents.<...>.model`, or the dry-run fails validation. Ship the registration as its own patch first.
   - Completion: the registration dry-run passes before the chain patch runs.

4. One atomic patch per model swap: when a patch removes a model from the provider registry, update every chain that names it — `agents.defaults.model` plus each `agents.entries.<id>.model` — and set the `agents.defaults.models` entry to `null`, all in that same file. List the entries with `openclaw config get agents.entries` before writing.
   - Completion: a single dry-run covering the registry and all chains passes.

5. Apply with the flags the dry-run proved (add `--replace-path` if step 2 required it). Most patches hot-apply, but the CLI's "Change will apply without restarting the gateway" is **not** authoritative: the `logging.audit.*` family (`enabled`, `executionIdentity`, `messages`) is captured at gateway startup and needs a restart even while the CLI still prints that line. After restarting, confirm the new *behavior*, not just the stored value (for audit, `openclaw audit --limit <n>` shows whether the `AGENT` column is populated).
   - Completion: "Applied N config update(s)", plus — for a startup-captured setting — a restart and a read-back that shows the new behavior.

6. Read back every changed path: `openclaw config get agents.defaults.model`, `openclaw config get agents.entries.<id>.model`, `openclaw config get agents.defaults.models`. Report anything the patch was said to remove but did not — a claimed removal still present is a finding, not a detail.
   - Completion: every intended path reads back the intended value.

## Provision a new agent

Same config surface, different entry point. Verified 2026-09-10 (adding the `scout` worker).

1. `openclaw agents add <name> --workspace "<dir>" --non-interactive` seeds the workspace (template `SOUL.md`, `IDENTITY.md`, `USER.md`, `BOOTSTRAP.md`) and creates `agents.entries.<name>` holding only `name`, `workspace`, `agentDir`, `identity`. It prints "Updated config" and still exits 1 — see Pitfalls.
   - Completion: `openclaw config get agents.entries.<name>` returns the new record.

2. Write the role's `AGENTS.md` into the workspace with the `write` tool (gateway filesystem path, `C:\Users\ehven\...`).

3. Patch what `agents add` left out: the model chain (`primary` + `fallbacks`, matched to the sibling workers) and, for a worker that reads repos, `tools.exec.host` + `tools.exec.node` pinned to the Mac node — the same node id the other engineering workers carry. Without it the new agent's `exec` runs on the gateway Windows host, where the Mac paths do not exist.
   - Completion: dry-run passes, apply, then `openclaw config get agents.entries.<name>.model` and `...tools.exec` read back the intended values.

## Pitfalls

- Under PowerShell these commands exit 1 while succeeding: the CLI writes diagnostics to stderr (`[sqlite/transaction] slow SQLite transaction hold`, `[plugins] summa-gate ...`), PowerShell turns that into a `NativeCommandError`, and `agents add` / `config patch` both printed their success lines and then "Process exited with code 1". Judge by the success line plus a read-back, never by the exit code, and do not re-run the command on the strength of that code alone.
- Verification is `openclaw config get <path>`, never a config-set "done" narration.
- Nulling a model entry deletes its alias too (e.g. `DeepSeek-Flash`); grep the workspaces for the alias and flag any operational hit (skill, script, automation). Memory notes are harmless.
- Registration and wiring are separate changes: adding a model to the catalog does not put it in any chain.
- A restart made to apply a startup-captured setting can kill an in-flight automation run: check `openclaw cron list --all` for a job in `running` state before restarting, and recover a killed run with the `automation-run-recovery` skill.
- `logging.audit.enabled` defaults to `true`; to turn on run-identity recording you only set `executionIdentity` (default `false`). The schema's own text says restart after changing it.
