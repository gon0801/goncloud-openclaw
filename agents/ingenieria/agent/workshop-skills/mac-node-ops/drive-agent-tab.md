# Driving an interactive TUI agent session on the Mac node (muse, claude, kimi, codex prompt)

Dispatching a prompt into an interactive Terminal.app agent session and tracking it to
completion. Locating the right window/tab first: see [`locate-session-cwd.md`](./locate-session-cwd.md).
Verified end-to-end 2026-09-14: a multi-row phase brief dispatched into a muse 1.2.1 tab,
which then created branches, commits, a push and a PR on its own.

## 1. Read the buffer by window id, not by iteration

Direct addressing is the verified-correct form:

```bash
osascript -e 'tell application "Terminal" to get contents of tab 1 of window id <N>'
```

Two traps verified the same day:

- Building the output in a loop with `set out to out & (contents of t)` / `return contents of t`
  returns the AppleScript **reference** (`tab 1 of window id 34218`), not the buffer text.
- `set out to out & (name of t)` dies with an AppleScript coercion error on tab objects.
  Collect only `id of w` and `tty of t` in a mapping pass, then use `tab <i> of window id <N>`.

Tabs may live as one-tab windows even when the requester describes them as one window with
tabs — resolve by tty (`tab 1 of window id M` ↔ tty row from the ETL), not by window count.

## 2. Dispatch: `do script` fills the prompt but does not submit

```bash
osascript -e 'tell application "Terminal"
  set frontmost of window id <N> to true
  do script "<prompt>" in window id <N>
end tell'
```

For a TUI prompt (muse `❯`, and the same class of harness CLIs), the text lands in the
input line **without being sent**. Confirm in the buffer, then submit:

```bash
osascript -e 'tell application "System Events" to keystroke return'
```

(keep the window frontmost; `do script` in an already-focused window keeps focus anyway).
Completion check: within ~10 s the buffer shows the agent starting (`Thinking`, `Read N files`).
A plain shell prompt would have executed the line directly — only a TUI needs the keystroke.

## 3. Monitor via repo state, not just the screen

The buffer shows only recent TUI lines and rate-limit retries. The durable artifact of an
implementation run is the working tree: alternate short buffer reads with

```bash
cd <repo> && git status -sb && git log --oneline -3 && git diff --stat HEAD
```

Branch creation, commits, pushes and the resulting PR (`gh pr checks <n>`) are readable from the repo side and survive screen truncation.

## 4. Keep in-node sleeps short

Exec commands with `sleep 45`–`120` inside them all returned
`COMPANION_APP_UNAVAILABLE: macOS app exec host unreachable` / unknown outcome even though
the Mac was fine (verified repeatedly 2026-09-14); commands ≤ ~10 s consistently returned.
Poll with short commands spaced across turns (step 9 of SKILL.md: check effects before any
retry — never re-run the killed sleep).
