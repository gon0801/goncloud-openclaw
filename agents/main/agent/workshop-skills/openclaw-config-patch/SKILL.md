---
name: openclaw-config-patch
description: Patch OpenClaw config from a JSON5 file. Use when asked to change models/agents/channels config, when `openclaw config patch` refuses with "Refusing to replace ... it would remove existing entries", or when a model named in an agent chain fails validation. Produces an applied, read-back change.
---

# OpenClaw Config Patch (JSON5 file)

Apply config changes with `openclaw config patch --file` through its dry-run gate and past the two non-obvious validation guards. Verified 2026-09-10 (model and agent-chain patches; all applied hot).

## Steps

1. Write the patch to a file (e.g. `$env:TEMP\<name>.json5`) and dry-run it:
   `openclaw config patch --file <path> --dry-run`
   Objects merge recursively, `null` deletes a path, arrays and scalars replace.
   - Completion: "Dry run successful: N update(s) validated", or one of the guards below to resolve.
   - The owner's standing rule: apply without `--dry-run` only once the dry-run passes.

2. Guard "Refusing to replace <path>; it would remove existing entries: <ids>. Use --merge to merge by id or --replace to replace intentionally." — it fires when the patch's array drops existing entries. The suggested `--replace` does **not** exist; the real flag is `--replace-path <dot.path>` (repeatable). Re-run naming the exact array:
   `openclaw config patch --file <path> --dry-run --replace-path models.providers.<provider>.models`
   - Completion: the dry-run passes with `--replace-path`.

3. Register before referencing: a model must exist in `models.providers.<p>.models[]` before any chain may name it in `agents.defaults.models` or `agents.<...>.model`, or the dry-run fails validation. Ship the registration as its own patch first.
   - Completion: the registration dry-run passes before the chain patch runs.

4. One atomic patch per model swap: when a patch removes a model from the provider registry, update every chain that names it — `agents.defaults.model` plus each `agents.entries.<id>.model` — and set the `agents.defaults.models` entry to `null`, all in that same file. List the entries with `openclaw config get agents.entries` before writing.
   - Completion: a single dry-run covering the registry and all chains passes.

5. Apply with the flags the dry-run proved (add `--replace-path` if step 2 required it). Patches hot-apply; no restart is needed.
   - Completion: "Applied N config update(s). Change will apply without restarting the gateway."

6. Read back every changed path: `openclaw config get agents.defaults.model`, `openclaw config get agents.entries.<id>.model`, `openclaw config get agents.defaults.models`. Report anything the patch was said to remove but did not — a claimed removal still present is a finding, not a detail.
   - Completion: every intended path reads back the intended value.

## Pitfalls

- Verification is `openclaw config get <path>`, never a config-set "done" narration.
- Nulling a model entry deletes its alias too (e.g. `DeepSeek-Flash`); grep the workspaces for the alias and flag any operational hit (skill, script, automation). Memory notes are harmless.
- Registration and wiring are separate changes: adding a model to the catalog does not put it in any chain.
