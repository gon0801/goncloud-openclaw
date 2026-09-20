---
name: openclaw-config-patch
description: Patch OpenClaw config from a JSON5 file, and provision a new agent. Use when asked to change models/agents/channels/logging config or an agent's icon/avatar, when the config tool refuses with "Direct config writes cannot change models", when `openclaw config patch` refuses with "Refusing to replace ... it would remove existing entries", when a model named in an agent chain fails validation, or when adding an agent that must run on the Mac node. Produces an applied, read-back change.
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

## Exec host pin / unpin (both machines)

A `tools.exec.host: "node"` pin denies a cross-host override outright — the call fails with `exec host not allowed (requested gateway; configured host is node; set tools.exec.host=gateway or auto to allow this override)`, it does not queue or run elsewhere. To let a pinned agent work on both hosts, set `host` to `"auto"` and keep the `node` id as its default (verified 2026-09-17: six agents unpinned, one word each, node ids untouched). Leave agents with no pin (here: main, operaciones) alone — adding one can move them off their home host.
   - Completion: `openclaw config get agents.entries.<id>.tools.exec` reads back `host: auto` for every intended agent.
Direct file edits over repeated identical blocks need unique neighboring context per block: two batch attempts failed (indentation, non-unique context) and changed nothing — verified by read-back — then one-by-one edits anchored on each agent's own lines succeeded. A config edit re-arms the deferred-restart mechanic in Pitfalls, so batch the pins into one round and check `cron list --all` first.

## Set an agent's identity (name / emoji / avatar)

Same namespace (`agents.entries.<id>.identity`), different entry point: the `set-identity` subcommand. Verified 2026-09-16 (icons for all 8 agents).

1. Put the image inside that agent's own workspace and pass a **workspace-relative** path: `openclaw agents set-identity --agent <id> --avatar avatars/<id>.png`. Each agent has its own `avatars\` (`C:\Users\ehven\.openclaw\workspace-<id>\avatars\`; plain `workspace\` for `main`).
   - Completion: the file exists in that agent's workspace.
2. **Never trust this command's `--json` output.** On the verified run it printed a full success object naming the new avatar for all 8 agents while only **2** had persisted to `openclaw.json`; re-running the other six landed five, and the last needed its own run. Apply, then read back and count: `(Get-Content openclaw.json -Raw | ConvertFrom-Json).agents.entries.PSObject.Properties | ForEach-Object { $_.Name + '=' + $_.Value.identity.avatar }`. Re-run only the agents that read back empty — the command is idempotent. (The observed loss was intermittent and its cause was not established; do not invent one. Verify instead.)
   - Completion: every agent reads back its intended avatar, and you report the true count rather than the command's claim.
3. This namespace hot-applies: `config hot reload applied (agents.entries.<id>.identity.avatar)` — no restart, no `SIGUSR1`, gateway PID unchanged (verified 8/8 with no restart), unlike the startup-captured `logging.audit.*` family in step 5.

To prepare images that live on the Mac for a Windows-side workspace: `sips -Z 256 <src> --out <dst>` (verified 1254×1254 ≈ 900 KB → 256×256 ≈ 55 KB), move them with the relay in `mac-node-file-transfer`, then copy into each workspace's `avatars\`.

## Pitfalls

- Under PowerShell these commands exit 1 while succeeding: the CLI writes diagnostics to stderr (`[sqlite/transaction] slow SQLite transaction hold`, `[plugins] summa-gate ...`), PowerShell turns that into a `NativeCommandError`, and `agents add` / `config patch` both printed their success lines and then "Process exited with code 1". Judge by the success line plus a read-back, never by the exit code, and do not re-run the command on the strength of that code alone.
- Verification is `openclaw config get <path>`, never a config-set "done" narration.
- Nulling a model entry deletes its alias too (e.g. `DeepSeek-Flash`); grep the workspaces for the alias and flag any operational hit (skill, script, automation). Memory notes are harmless.
- Registration and wiring are separate changes: adding a model to the catalog does not put it in any chain.
- A config change that needs a restart does **not** restart immediately: the gateway logs `config change requires gateway restart (<path>)` and defers while work is active, `restart still deferred` every ~30 s, then `restart timeout after 300xxx ms ... forcing restart` → `received SIGUSR1` + `forced restart requested; skipping active work drain`. That forced restart **aborts whatever is running** (a turn died with `AbortError OPENCLAW_RESTART_ABORT`, 2026-09-16 17:08). So a config edit made during a long turn can kill that turn minutes later, and the trigger is the edit you made earlier, not anything happening at that moment. Check `openclaw cron list --all` for a `running` job before editing, and recover a killed run with `automation-run-recovery`.
- Batch related edits into ONE patch instead of a burst: each edit that needs a restart re-arms the deferral, and rapid edits produce `config change detected; evaluating reload` / `config reload superseded` churn (~25 in one afternoon on 2026-09-16) with the restart landing at the end of the burst. When several namespaces must change (bind, auth, models, plugins), write them as one file and dry-run once.
- A config-driven restart is not a fault, but it looks like one from outside: repeated restarts plus the resulting latency get misread as a gateway instability loop. Count them from the gateway log (`http server listening`, `received SIGUSR1`) rather than from `gateway-restart.log`, which accumulates across days — see `gateway-stability-diagnosis`.
- `logging.audit.enabled` defaults to `true`; to turn on run-identity recording you only set `executionIdentity` (default `false`). The schema's own text says restart after changing it.
- A success-shaped CLI response is not a write confirmation. `agents set-identity --json` returned a complete identity object (avatar included) for agents whose config was never updated — verified 6 of 8 silently lost, 2026-09-16. Read the config back before reporting identity, model, or channel changes as done; `openclaw config get <path>` is the check for `config patch`, and a `ConvertFrom-Json` count is the check here.
