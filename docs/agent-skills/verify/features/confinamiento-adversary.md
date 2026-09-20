# Adversary confinement

Keeps the `adversary` agent from writing outside its zone. That agent exists to
attack the change and try to break things, so it is the one agent you least want
able to edit the repo it is attacking.

Registered on `before_tool_call` with the `exec` matcher, gated on the agent id,
so it only applies to `adversary` and leaves every other agent alone.

## Sub-features

Three checks, and the redirect ones are what people forget:

| Check | What it catches |
|---|---|
| Write target | A write tool aimed at a path outside the allowed zone |
| Redirection target | A redirect target outside the zone, absolute or relative |
| Redirect after a `cd` | A relative target in a command that changes directory first: where it lands cannot be known, so it is refused |

The allowed zone is the agent's own workspace, plus anything under
`.saikit/findings` and `.saikit/scratch`. That is where an adversary is supposed
to leave what it finds: a report, not an edit.

The redirect checks exist because a write does not have to look like one. A
command whose visible verb is harmless can still land bytes somewhere through
its output. Redirects to the null device and to the standard streams are allowed
by name; every other target goes through `adversaryPathAllowed`, absolute or
relative — and a command that changes directory invalidates the resolution of
any relative target, so that combination is refused outright rather than
guessed at.

### The hole that was here, and how it got found

Until 2026-09-16 the hook skipped every relative target before checking it:
`if (!ABSOLUTE_PATH_RE.test(target)) continue;`, commented "relativos: dentro
del workspace". That comment was an assumption, not a fact, and
`printf x > ../../outside` from the adversary's own workspace wrote outside the
zone without the guard ever looking at it.

It is fixed: the `continue` is gone and every target goes through
`adversaryPathAllowed`, which already resolved relative paths correctly.

**Two things about it are worth keeping.** First, it survived because this guard
had no test at all, neither of the function nor of the hook, which is why
`adversary-confinamiento.test.ts` now exists. Second, it was found by a bot
reviewing *this documentation*, not the code: writing down what a guard promises
is what made the gap visible. A proof about this guard should still check both
kinds of target, because nothing stops the skip from coming back.

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
PATH="$(dirname "$(command -v node)"):$PATH" node --test adversary-confinamiento.test.ts
```

That file is this guard's own battery: nine cases, each paired with its
opposite. Pairing is the point, because a run where everything blocks and one
where nothing does look identical from a green exit code.

Two of those cases are regressions for holes this guard actually had: a relative
target that escapes, and a relative target in a command that changes directory
first. Neither is hypothetical; both were live.

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

For a redirect whose target is outside the zone:

```
Confinamiento adversary (summa-gate): redirección fuera de zona permitida (solo workspace, .saikit/findings, .saikit/scratch). Destino: <ruta>
```

And for the third check, a relative target in a command that changes directory
first:

```
Confinamiento adversary (summa-gate): el comando cambia de directorio, asi que un destino relativo no se puede ubicar; usa una ruta absoluta dentro de la zona permitida. Destino: <ruta>
```

All three messages end with the refused destination, so none is a fixed string:
match the part before `Destino:` and read the rest. `scripts/tests/test-skill-verify.sh`
fires all three through the registered hook and compares exactly that part.

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
