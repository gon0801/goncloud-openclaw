# Fixtures: match them to the mutation they must catch

Read from `test-discrimination-verify` when authoring the fixtures for a mutation battery. Invented and distinctive — never real values, never values that collide with suite text.

## Length vs threshold

An N-character fixture only catches floors **greater than N**. Exactly 1 character is the only thing that catches a `< 2` floor; `c0rt4!` (6 chars) catches an 8 floor, not a 2 floor.

## Ordering

Register the **shorter** secret first, or the natural order already replaces the long one first and the mutation survives.

## Form

Assert **exact equality** on the full deterministic output — `"password=***" in out` survives a change to `password=***REDACTED***`.

## Registry collisions

The secret registry is process-global and never cleared: pick a short, non-alphanumeric fixture that appears nowhere else the suite passes through `scrub()` (documented trap: a bare 1-char `T` breaks `nextToken`). Grep the literals and eyeball them.
