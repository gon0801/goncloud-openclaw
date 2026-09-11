---
name: mac-agent-transcript
description: Read the last output of a CLI coding agent (kimi-code, claude, codex, muse) running in a Terminal tab on David's Mac, from its on-disk session log. Use when asked what Kimi/Claude/Codex said or did, or to see what a Terminal tab is running. Produces the agent's last assistant message.
---

# Mac Coding-Agent Transcript (David's Mac)

Read what a CLI coding agent in a Terminal tab on the Mac is doing from its session log, instead of typing into the live terminal. Verified 2026-09-09 on kimi-code; the on-disk transcript is the reliable read even when the live tab is unwritable.

## Steps

1. Find the agent process and its tty/cwd. `ps -axo pid,ppid,command | grep -E '[z]sh|[k]imi|[c]laude|[c]odex|[m]use'` lists the CLI processes; `ps -o pid,tty,stat,command -p <pid>` gives the tty (e.g. ttys005); `lsof -a -p <pid> -d cwd -Fn | grep '^n'` gives the working directory.
   - Completion: you have the process pid, its tty, and its cwd (e.g. /Users/dn/dev/goncloud-Orbit).

2. Locate the session transcript.
   - **kimi-code:** sessions under `~/.kimi-code/sessions/<wd_...>/<session_...>/`; `~/.kimi-code/session_index.jsonl` maps `sessionId` → `sessionDir` → `workDir`. Pick the most recently modified `<session_...>` under the matching `wd_...` (`ls -lt`); confirm with `state.json` (`title`, `lastPrompt`, `updatedAt`).
   - **Claude Code:** `~/.claude/projects/<slug>/<sessionId>.jsonl`, where `<slug>` is the session's cwd with `/` replaced by `-` (cwd `/Users/dn/dev/summonaikit-claude` → `-Users-dn-dev-summonaikit-claude`). `ls -lt` the directory for the newest `.jsonl`; the claude pid's cwd ties it to the tab. The file advances only when a turn commits, so a stale mtime means that session is idle.
   - Completion: you have the active session's transcript file.

3. Extract the last assistant message.
   - **kimi-code:** every `wire.jsonl` line is JSON; assistant text is in `type == "context.append_loop_event"` events whose `event.part.type == "text"` → `event.part.text`. Take the last.
   - **Claude Code:** every JSONL line has `type` (`user`/`assistant`) and `message.content` (a string, or a list of parts); take the last `message.content` part with `type == "text"` from an `assistant` line.
   - Completion: you have the last assistant text.

4. To confirm a typed handoff actually reached a session, `grep -rl "<unique-marker>" ~/.claude/projects/` (or the kimi session dirs). The file containing your text names the receiving session — use this instead of trusting the tab title or a window index, since a paste can silently land in another project's session. This also reveals which cwd a running agent belongs to.
   - Completion: exactly the intended session's transcript contains the marker.

5. Verify it is the right task before reporting: `state.json` `title` and `lastPrompt` must match the question (e.g. "what did Kimi say about X"). If the newest session is a different task than the one asked about, say so instead of reporting the wrong session's output.
   - Completion: the reported text corresponds to the session/task the user asked about.

## Pitfalls

- `session_index.jsonl` is not guaranteed time-ordered; trust session directory mtimes (`ls -lt`) over index position to find the newest.
- Several sessions can share one `wd_...` folder (the agent restarts sessions in the same project). Always confirm via `state.json` title/lastPrompt that you read the session the user means.
- The live Terminal tab title reflects the active session; cross-check it against `state.json.title`.
