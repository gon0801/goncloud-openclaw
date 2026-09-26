# Feature map: summa-gate

One file per guard, plus `merge-guard.md`, which documents a guard that was
removed and how to prove it stays gone. Each guard file says what the guard is,
how a user reaches it, how to drive it, and the exact string that proves it
fired.

The users here are agents. "Reaching" a feature means an agent does something
during a turn, and the guard answers.

| Guard | What it stops | File |
|---|---|---|
| Merge & deploy (guard removed) | Nothing since a088618 (#159): the interception was removed and every agent follows the normal PR flow. The file documents the absence and its proof | [merge-guard.md](merge-guard.md) |
| Adversary confinement | The `adversary` agent writing outside its zone | [confinamiento-adversary.md](confinamiento-adversary.md) |
| Agent channel | A `sessions_send` whose answer would be lost | [canal-entre-agentes.md](canal-entre-agentes.md) |
| Close ceremony | A turn closing without its evidence | [cierre-con-evidencia.md](cierre-con-evidencia.md) |

## The rule that applies to the guard files

**The guard's message is the evidence, and it is exact.** Each guard file quotes
the string its guard emits. Matching it approximately proves nothing: these
strings are asserted character for character by the battery, and a near-miss
means you drove something else.

## Two layers, and what each can prove

| Layer | Proves | Cannot prove |
|---|---|---|
| Local, the battery and `node --test` | The hook is registered and the verdict logic is right | That the plugin is loaded on the gateway |
| Live, an agent turn | The plugin is loaded and the message reaches the agent | That the block held, when the drive is inert |

Both layers are needed for a claim about production. Neither alone is enough,
and saying which one you ran is part of the proof.

## Not mapped yet

Four more hooks exist: the sentinel and standing-rules injection at prompt
build, post-tool evidence capture, subagent tracking, and the renditions
observer. They are covered by the battery but have no driving recipe here. A
proof about them starts by adding their file.
