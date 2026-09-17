# Agent channel

Stops a `sessions_send` whose answer would be lost. When claw dispatches work to
another agent and waits for the reply, the reply comes back on a path that dies
silently if the dispatching turn already closed. The agent waits, nothing
arrives, and no error says why.

This guard is not about permission. It is about a shape of message that cannot
work, refused up front instead of failing quietly twenty minutes later.

## Sub-features

The guard lets through the three shapes that do work:

| Shape | Why it survives |
|---|---|
| A send to a `main` session | That path does not die the same way |
| A notice explicitly marked as expecting no answer | Nothing is waiting, so nothing is lost |
| A dispatch carrying the exact return-report tag with the sender's session key | The answer comes back as a new turn, not down the dying path |

The third one is why the tag is matched **literally**. Looking for the loose
words instead let through a message that only mentioned the mechanism, including
one that explicitly denied it would report back. That was found by a cross
review and the fix is the literal match, so a proof that uses a paraphrased tag
is testing the old bug.

## How to get to it (user POV)

Claw, mid-turn, dispatches work to another agent and expects the result on the
same call. No waiting flag helps: the agent can take longer than any wait.

## Driving it with the battery

Local only. Driving this live means dispatching real work to a real agent on the
production gateway and watching the answer disappear, which costs a turn and
proves what the battery already proves.

```
cd /Users/dn/dev/goncloud-openclaw/summa-gate
PATH="$(dirname "$(command -v node)"):$PATH" node --test role.test.ts
```

`sessionsSendGuardVerdict` takes the send parameters. Drive it four ways: the
blocked shape, and each of the three that must pass. Three passing shapes and no
blocked one proves nothing, and one blocked shape with no passing ones proves a
guard that refuses everything.

## Expected output

The message names the measurement that produced the rule:

```
Envio bloqueado por summa-gate: la respuesta de un sessions_send de Claw a otro agente se pierde si el agente tarda mas que la espera, y ninguna espera lo evita (2026-09-11: 41 respuestas perdidas). Usa una de estas:
```

It continues with the three allowed shapes. Match the opening; the list after it
is guidance for the agent that got blocked.

## Gotchas

- **The date and the count in that string are load-bearing.** They are what
  stops someone from deleting the rule as paranoia. If a change makes the
  message generic, the rule loses its evidence.
- **The tag is literal.** Reproducing it from memory in a drive will silently
  test the wrong thing, because a near-match falls into the blocked branch and
  looks like the guard working.
- **A passing shape must carry the sender's own session key**, not any key. A
  drive with a borrowed key passes for the wrong reason.
- **This guard shares a hook with others.** A verdict here does not mean the
  other checks on that hook ran. They are separate proofs.
