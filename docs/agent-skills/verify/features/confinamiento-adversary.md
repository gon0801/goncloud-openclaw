# Adversary confinement

Keeps the `adversary` agent from writing outside its zone. That agent exists to
attack the change and try to break things, so it is the one agent you least want
able to edit the repo it is attacking.

Registered on `before_tool_call` with the `exec` matcher, gated on the agent id,
so it only applies to `adversary` and leaves every other agent alone.

## Sub-features

Two checks, and the second is the one people forget:

| Check | What it catches |
|---|---|
| Write target | A command writing to a path outside the allowed zone |
| Redirection target | An absolute path on the right side of a redirect |

The allowed zone is the agent's own workspace, plus anything under
`.saikit/findings` and `.saikit/scratch`. That is where an adversary is supposed
to leave what it finds: a report, not an edit.

The redirect check exists because a write does not have to look like one. A
command whose visible verb is harmless can still land bytes somewhere through
its output. Redirects to the null device and to the standard streams are allowed
by name; everything else absolute is a target.

## How to get to it (user POV)

The `adversary` agent, mid-turn, runs a command that would write somewhere. It
believes it is taking notes. The guard decides whether the destination is its
zone.

## Driving it with the battery

Local only. There is no safe live drive: making the real adversary attempt a
write outside its zone on the one production gateway is exactly the thing the
guard exists to prevent, and an inert version would prove nothing.

```
cd /Users/dn/dev/goncloud-openclaw/summa-gate
PATH="$(dirname "$(command -v node)"):$PATH" node --test role.test.ts
```

`adversaryPathAllowed` takes the target and the workspace directory, so a drive
is: give it a path inside the zone and expect allowed, give it one outside and
expect blocked. Pair every case with its opposite. A check that only ever sees
allowed paths cannot tell you the guard works.

## Expected output

The block carries the destination it refused, so the message ends with the real
path:

```
Confinamiento adversary (summa-gate): escritura fuera de zona permitida. El agente adversary solo puede escribir dentro de su workspace o en paths bajo .saikit/findings y .saikit/scratch. Destino: <ruta>
```

And for the redirect case:

```
Confinamiento adversary (summa-gate): redirección a path absoluto fuera de zona permitida
```

## Gotchas

- **This is the only guard with no live drive**, and that is deliberate. If a
  proof claims to have driven it live, it drove something else.
- **The zone is three places, not one.** A proof that only tests the workspace
  leaves the two `.saikit` paths unproven, and those are where the adversary
  actually writes its findings.
- **The agent id gate means a wrong-id drive passes silently.** If you drive it
  as any agent other than `adversary`, nothing blocks and nothing is wrong. The
  absence of a block is only meaningful when the id is right.
- **Do not create real files outside the zone to test this.** The check is a
  function over a path string; it does not need the write to happen.
