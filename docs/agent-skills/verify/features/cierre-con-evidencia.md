# Close ceremony

Refuses to let a turn close without the evidence it promised. An agent that did
the work but never produced the receipt gets stopped at the door and told
exactly which piece is missing.

Registered on `before_agent_finalize`, which is the last moment before a turn
ends. That placement is the point: it catches the turn that was going to report
success on work it did not prove.

## Sub-features

The guard names what is missing rather than failing generically. That is the
whole design: an agent that gets "close rejected" and no list will guess, and
guessing produces a fabricated receipt, which is worse than no receipt.

The pieces it looks for are the labeled lines of the receipt, each of which has
to **start** its line. A receipt whose labels are buried mid-sentence reads fine
to a person and does not satisfy the check, and that is deliberate: the prose
version drifted from the machine-readable one and the check reads the one that
can be verified.

## How to get to it (user POV)

An agent finishes its work and moves to close the turn. If the turn was armed
with the sentinel, the ceremony applies, and the close is where it is enforced.

## Driving it with the battery

Local only. Driving this live means arming a real turn on the production gateway
and deliberately closing it wrong.

```
cd /Users/dn/dev/goncloud-openclaw
bash scripts/tests/test-evidencia-sin-texto-de-usuario.sh
cd summa-gate && PATH="$(dirname "$(command -v node)"):$PATH" node --test diagnostic-guard-finalize.test.ts
```

Drive it both ways. A close with a complete receipt must pass, and a close
missing one labeled line must be refused **naming that line**. The naming is the
feature; a test that only checks for refusal would pass against a guard that
rejects every close.

## Expected output

The refusal for a close that has nothing: armed with the sentinel, no receipt
block, no labeled lines, no test run. Each missing piece is its own line:

```
Cierre rechazado por summa-gate. Falta para cerrar la ceremonia:
- el bloque `SUMMONAIKIT HARNESS RECEIPT`
- la etiqueta `Understand:`
- la etiqueta `Implement:`
- la etiqueta `Verify:`
- la etiqueta `Review:`
- la etiqueta `Close:`
- la etiqueta `Retro:`
- evidencia de verificación real (no se detectó una corrida de tests exitosa en este turno) o una declaración explícita de skip de verificación con su razón

Rehacé tu respuesta final incluyendo el bloque SUMMONAIKIT HARNESS RECEIPT con las 6 etiquetas (Understand, Implement, Verify, Review, Close, Retro), cada una en su línea. Si necesitás una aclaración usá `SUMMONAIKIT HARNESS PAUSED`; si esperás un subagente, `SUMMONAIKIT HARNESS DELEGATED - awaiting <rol>`.
```

The list varies with what the close is missing; this is the everything-missing
instance. `<rol>` is a placeholder: `scripts/tests/test-skill-verify.sh` pins
everything before it character for character against the registered hook. The
proof has to show the list, not just the first line, because the list is what
makes the guard useful.

## Gotchas

- **The receipt has a prose description and a machine-readable shape, and they
  are not the same thing.** The numbered stages written in prose describe what
  to do; the check reads the labeled lines. A change to one and not the other
  puts them back out of sync, which already happened once.
- **Labels must start their line.** This bites when a receipt is reflowed or
  wrapped, which turns a passing close into a refused one with no code change.
- **The ceremony only applies to an armed turn.** Driving an unarmed one and
  seeing no refusal proves nothing.
- **Do not satisfy the check by writing the labels without the work.** The guard
  reads for the labels; it cannot tell a real receipt from a recited one. That
  gap is why the repo's rule is that a test which passes without the fix does
  not count, and it applies to receipts too.
