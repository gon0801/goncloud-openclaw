---
name: telegram-ack-reaction
description: Make the Telegram bot react to inbound messages with an emoji, and fix it when the ack reaction never fires. Use for configuring channels.telegram.ackReaction / messages.ackReactionScope, or when a configured ack reaction silently does nothing. Produces a reaction verified on the user's message.
---

# Telegram Ack Reaction

Configure the bot's automatic emoji reaction to inbound messages, and diagnose the two independent causes that make it silently never fire. Verified 2026-09-09: the configured emoji was rejected by Telegram, then the scope default excluded DMs; both had to be fixed and the gateway restarted before the reaction appeared.

## Steps

1. Pick an emoji that is a valid reaction in the target chat. Telegram rejects unsupported emojis **silently** — the config looks set but nothing appears. Discover the allowed set by attempting a reaction (`message react` returns "Reaction unavailable: <emoji>. This chat allows: …") or with `emoji-list`. Choose from that list (e.g. 🤔 worked; 🔄 was rejected in a DM).
   - Completion: you have an emoji confirmed present in that chat's allowed reactions.

2. Set `channels.telegram.ackReaction` to that emoji (system expert `config.set`).
   - Completion: `gateway config.get channels.telegram.ackReaction` (or CLI `openclaw config get`) returns the value.

3. Set `messages.ackReactionScope` to `direct` (DMs only) or `all` (DMs + groups). The default is `group-mentions`, which fires only when the bot is mentioned in groups — **never in DMs**. This is the most common reason "nothing happens" even with a valid emoji.
   - Completion: `gateway config.get messages.ackReactionScope` returns the intended scope.

4. Restart the gateway. `ackReactionScope` is read at Telegram provider startup and does **not** hot-reload; `ackReaction` and `richMessages` hot-reload, but the scope does not.
   - Completion: gateway is back up (`session_status` shows fresh uptime).

5. Verify live: ask the user to send a message and confirm the emoji appears on it without any manual action.
   - Completion: the reaction shows on the user's own message.

## Pitfalls

- Two independent causes produce the same symptom ("no reaction"): a wrong emoji (invalid for the chat) and a wrong scope (default `group-mentions`). Check both before concluding — fixing only one still leaves the reaction dead.
- Do not trust a config-set "done" narration alone; read back the value with `gateway config.get <path>` or CLI `openclaw config get`. The gateway's config view can lag with a stale hash until reload/restart.
- `channels.telegram.richMessages` is a separate hot-reload boolean (default off — some clients render rich blocks as unsupported). Enabling ack reactions does not imply it, and vice versa.
