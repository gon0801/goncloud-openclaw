# Locating an interactive agent session and its cwd on the Mac node

Use `lsof -a -p <pid> -d cwd -Fn` to confirm cwd — **never trust the
Terminal.app tab title**. A tab named after one project can run in a
different cwd, and a session's actual cwd can have a tab named
differently.

## When to use

Continue from a previous turn, take over a session the requester
references by title (e.g. "✳ Revisar pendientes"), or confirm process
context before mutating files in a project cwd.

When NOT to use: the agent runs headless (`claude -p`, `cursor-agent -p`,
`kimi -p`) — those run in the agent's own cwd, not under a Terminal.app
tab, and the ETL above does not apply.

## ETL: Terminal.app tabs → foreground PID → cwd

### T (tty per Terminal.app tab)

Single osascript per session dump. Avoid `index of t` (AppleScript
coercion bug on Terminal.app tabs). Reads `id of w`, `tty of t`,
`custom title of t`:

```bash
/usr/bin/osascript <<'EOS'
tell application "Terminal"
  set out to ""
  repeat with w in windows
    set wId to id of w
    set tabsCount to count of tabs of w
    set out to out & "WINDOW id=" & wId & " tabs=" & tabsCount & linefeed
    repeat with t in tabs of w
      try
        set tTitle to custom title of t
      on error
        set tTitle to "(no custom title)"
      end try
      try
        set tTty to tty of t
      on error
        set tTty to "(no tty)"
      end try
      set out to out & "  tab tty=" & tTty & " title=" & tTitle & linefeed
    end repeat
  end repeat
  return out
end tell
EOS
```

Output: `WINDOW id=<n> tabs=<n>` per window, then
`tab tty=/dev/ttysNNN title=...` per tab. The `/dev/ttysNNN` is the
canonical tty path the other tools read. The window's `id of w` is
stable across restarts of the osascript call but not across
Terminal.app relaunches.

### P (foreground PID per tty)

```bash
/bin/ps -t <tty> -o pid,ppid,user,stat,start,etime,comm
```

The shell (`-zsh` under `login(1)` typically `PPID=root`) is the parent;
the agent CLI is `S+` (foreground, session leader). For Claude it's
`claude`; for Kimi `kimi-code`; for OpenCode `opencode`; for Cursor
`cursor`/`cursor-agent`; for Muse `muse-bin-*`.

### C (cwd per PID, never assumed)

```bash
/usr/sbin/lsof -a -p <pid> -d cwd -Fn | /usr/bin/grep '^n'
```

The `^n` filter strips the `p<pid>` and `fcwd` field-header lines,
leaving `n<path>`. macOS stores cwd as the `fcwd` descriptor — `lsof
-a -d cwd` filters to that, and `-Fn` formats the field as
nul-separated `<key><value>`. Verify **both** the parent shell's cwd
and the foreground process's cwd if they differ — the shell can have
`cd`'d internally while the foreground process kept its boot cwd.

### Record the table

`(tty, title, comm, pid, cwd)` — five fields, one row per tab. Print
the full row in the agent's response so the verifier (next turn or
human) re-derives it. Do not summarize into prose ("claude is running
in summonaikit-claude") — the table is the artifact.

When the requester's task names a tab by title, locate the matching
row by title and confirm the cwd matches what the task requires. If
they mismatch, declare which row the agent actually used instead of
silently switching to the closest match.

## Verified wrong pattern to avoid

```bash
/usr/bin/pgrep -f claude | /usr/bin/xargs -I{} /usr/sbin/lsof -p {} …
```

Stdin-bound `xargs` filters can drop the targeted session in the
partial sample. On 2026-09-12, a preflight declared "no claude with
cwd=/Users/dn/dev/summonaikit-claude" while ttys001 had `claude` (PID
95447) inside that exact cwd. The wrong filter missed ttys001 entirely;
the prior preflight then committed a `host_impediment_reason` in
`docs/evidence/phase-20/20.18/PREFLIGHT-2026-09-12.md` that had to
be refreshed in commit `8abfa73` of `work/20.18-20.19-preflight`.

Never use `pgrep -f` + `xargs -I{}` for an "is X running with cwd Y"
claim. The strict ETL above is the only path verified correct on this
Mac.

## Worked example (2026-09-12 12:00 EDT)

Output table (verbatim, 11 tty rows; row matching David's habit tab
by title `✳ Revisar pendientes` is ttys001):

| tty     | title                              | cwd                                  | comm      | pid   |
|---------|------------------------------------|--------------------------------------|-----------|-------|
| ttys000 | goncloud-Orbit                     | /Users/dn/dev/goncloud-Orbit         | muse      | 74009 |
| ttys001 | ✳ Revisar pendientes               | /Users/dn/dev/summonaikit-claude     | claude    | 95447 |
| ttys003 | ✳ A.5 implementation review        | /Users/dn/dev/goncloud-Orbit         | claude    | 66171 |
| ttys005 | revisa a.2b y a.3                  | /Users/dn/dev/goncloud-Orbit         | kimi-code | 27311 |
| ttys006 | [OpenClaw-director] Cross-review   | /Users/dn/dev/summonaikit-claude     | kimi-code | 28907 |
| ttys007 | OpenCode                           | /Users/dn/dev/goncloud-Orbit         | opencode  | 28248 |
| ttys008 | summonaikit-claude                 | /Users/dn/dev/summonaikit-claude     | muse      | 71993 |
| ttys010 | goncloud-openclaw                  | /Users/dn/dev/goncloud-openclaw      | muse      | 7261  |
| ttys012 | ✳ Claw acceso navegador clave      | /Users/dn/dev/goncloud-openclaw      | claude    | 94329 |
| ttys013 | revisa si se puede agregar el mo…  | /Users/dn/dev/goncloud-openclaw      | kimi-code | 13757 |
| ttys014 | ✳ Orden 2000018393906916 no reg…   | /Users/dn/dev/goncloud-bridge-in-out | claude    | 34598 |

Notes on traps in this table:

- **ttys008 title says `summonaikit-claude` but comm `muse`.** A
  title-only match would have selected the wrong process. lsof on
  PID 71993 confirms the cwd matches, but the process is muse, so
  retyping `-saikit` prompts into this tab does not run Claude there.
- **ttys001 title `✳ Revisar pendientes` is the habitual David tab**
  for `/Users/dn/dev/summonaikit-claude`. comm `claude`, cwd matches.
- **ttys003 title `✳ A.5 implementation review` runs in `/Users/dn/
  dev/goncloud-Orbit`, not in summonaikit-claude.** Title lied.
- **ttys014 title `✳ Orden 2000…` runs `claude` in
  goncloud-bridge-in-out.** Comm matches by name but cwd does not
  match the summonaikit-claude project.

Three of these four traps are title-vs-cwd mismatches inside one
shell. The ETL above is the only automated path that disambiguates
them.

## Output discipline

The row table is the artifact. Print it in the response so a verifier
(other agent, requester, or human) re-derives the same mapping
without trusting any prose summary.
