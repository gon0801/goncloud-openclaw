# Auditing a finished Claude Code session log (who instructed what)

Logs live at `/Users/dn/.claude/projects/<project-slug>/<session-id>.jsonl` — one JSON object per line, multi-MB (4.7 MB / 2683 lines observed). Never paste raw lines into context; extract with python on the node.

## Extract the real human instructions

`type:"user"` mixes three things: actual human text, tool results, and `<task-notification>` wrappers. Filter to text items and drop notifications, or you count the harness talking to itself as human input:

```bash
python3 -c "
import json
lines=open('<path>').readlines()
for i,l in enumerate(lines):
    try: d=json.loads(l)
    except: continue
    if d.get('type')!='user': continue
    c=d.get('message',{}).get('content','')
    if isinstance(c,list):
        c=' '.join(x.get('text','') for x in c if isinstance(x,dict) and x.get('type')=='text')
    c=str(c).strip()
    if c and '<task-notification>' not in c:
        print(i, c[:250])
"
```

Read the tail of the assistant messages the same way (`type=='assistant'`, text items only) for the session's own verdict/sign-off.

## Decision rules

- Harness-run sessions take instructions from brief files (`Lee /tmp/brief-*.txt y haz lo que pide`). Establish provenance with `stat -f '%Sm %N' <brief>` and read the brief itself — the brief, not the chat, carries the operative spec.
- No human text message in the last ~100 lines before a merge means the merge was harness-autonomous. Report that as a finding with the line numbers; do not assume either way.
- An assistant tail message citing reviewer verdict + CI green (e.g. "CI 15/15 verde sobre <sha>") is the agent's own sign-off, not an operator instruction.
- Do not grep the JSONL for `merge`/`push` tool calls to conclude who merged — a gate may block that very search pattern; use the git refs (`git log --format='%H %P' -1 <merge-commit>`) for what landed and the message filter above for who asked.

Verified 2026-09-13: 19 "user" messages in one session were all harness-injected briefs/notifications; the operative instruction was a single `Lee /tmp/brief-pr319-r2.txt` line, and the merges of PRs #316-#319 were autonomous after CI green.
