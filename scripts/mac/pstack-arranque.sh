#!/bin/sh
# Hook SessionStart de Claude Code: el aviso de pstack que antes ponía el port (pstack-claude).
# Habla solo cuando la copia del original está activa (sincronizar-pstack.sh activar deja la
# marca); mientras el port siga instalado, su propio hook da el aviso y este calla.
# Instalación: ~/.claude/settings.json, hooks.SessionStart, matcher startup|resume|clear|compact.
set -eu
[ -f "${PSTACK_MARCA_ACTIVA:-$HOME/.agents/.pstack-oficial-activo}" ] || exit 0
cat <<'AVISO'
<EXTREMELY_IMPORTANT>
You have pstack (the original from cursor/plugins, synced nightly into ~/.agents/pstack-oficial).

Invoke the `poteto-mode` skill and follow its instructions when a task meets any of these:

- it touches more than one file, or changes a signature other files call
- it involves a design or architecture choice
- it is a bug whose cause is not yet known, or a performance issue

It routes to the right pstack skill from there. For smaller tasks, such as a contained change to one file with an obvious test, a question, or a one-line edit, work directly and verify on the real artifact.

When the intent is already specific, enter that skill directly: `tdd`, `architect`, `how`, `why`, `arena`, `interrogate`.

`<pstack>` in these skills is ~/.agents/pstack-oficial (it holds `skills/`, `agents/` and `docs/`); read `<pstack>/docs/harness/claude-code.md` once per session for the Cursor-to-Claude-Code names. The subagent types are `poteto-agent` and `comment-sicko`.

User instructions (CLAUDE.md, AGENTS.md, direct requests) take precedence. Other session-start mandates, such as superpowers, still apply. Their skill checks run as before, and when a task meets the criteria above they route implementation through poteto-mode.
</EXTREMELY_IMPORTANT>
AVISO
