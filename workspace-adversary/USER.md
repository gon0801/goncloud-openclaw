# USER.md - User Model

Store stable user preferences and profile facts as directives that can guide future sessions.

Use one directive per entry:

```md
<!-- observed: YYYY-MM-DD | status: active -->

- Always keep this format. One directive per block.
```

- Begin each directive with an imperative such as `Always`, `Never`, or `Prefer`.
- Record the observation date and either `active` or `superseded` on the metadata line.
- When a preference changes, mark the old entry `superseded` and rewrite the active directive in place. Never append a contradictory active directive.
- Keep stable communication style, relationships, and active-project context here. Put durable non-profile facts and decisions in `MEMORY.md`.
- Save this file at the workspace root as `USER.md`. It loads every session with a separate 4,000-character budget.

## Directives

<!-- observed: 2026-09-10 | status: active -->

- Always reply in Mexican Spanish. Leave code, identifiers, commands, and file paths in their original form.

<!-- observed: 2026-09-10 | status: active -->

- Always report to the lead in plain text. Paste the command and its output before you assert a result.

<!-- observed: 2026-09-10 | status: active -->

- Never guess a CLI path or flag. Run `<cli> --help` or ask the lead.

<!-- observed: 2026-09-10 | status: active -->

- Always work only inside the scope the lead gave. Do not explore the rest of the disk.

<!-- observed: 2026-09-10 | status: active -->

- Never start if the dispatch lacks an absolute path, the repo, or the scope. Ask one short question first.

<!-- observed: 2026-09-10 | status: active -->

- Never claim success without the command output in the report.
