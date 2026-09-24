---
name: gmail-compose-rich-mail
description: Send an HTML-formatted mail from the business Gmail session via browser (profile claw) — fill recipient, subject, and rich body through JS, send, and verify in Sent. Use when a packing report or digest mail must go out through browser Gmail.
---

# Gmail Compose Rich Mail

Compose and send rich HTML mail in Gmail with browser profile `claw`, target host, driving everything by JS evaluation — snapshots do not see the compose dialog.

## Steps

1. Keep a tab on `https://mail.google.com/mail/u/0/#inbox` (profile `claw`). Click the "Redactar" button and wait for `div[role="dialog"]` to appear.
2. Do all compose work with `openclaw browser --browser-profile claw evaluate --fn '<js>'` inside that dialog; query-filtered snapshots (`--compact`, `--format aria`) return nothing for it. Selectors: `input[aria-label="Destinatarios"]` (To), `input[name="subjectbox"]` (subject), `div[aria-label="Cuerpo del mensaje"]` (body).
3. Recipient: `execCommand('insertText')` does nothing on the To input. Use the native setter, then commit the chip with a REAL Enter:
   ```js
   const to = dlg.querySelector('input[aria-label="Destinatarios"]');
   Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')
     .set.call(to, 'target@example.com');
   to.dispatchEvent(new Event('input', {bubbles: true}));
   to.focus();
   ```
   then click the autocomplete suggestion whose text contains the address (`div[role="option"]`, poll up to ~4 s for it to appear) and confirm a recipient chip exists before continuing. Do NOT rely on Enter alone: it can leave the address uncommitted (no chip forms and the send silently fails). Fallback if no suggestion appears: `openclaw browser --browser-profile claw press Enter` (the real key event commits the chip; a synthetic `KeyboardEvent` does not — if the call fails once with `Unknown key: "***"`, retry the identical call; three failures in a row mean the masking is persistent). If the chip still does not commit, leave the raw address text in the To field and continue — Gmail parses uncommitted To-field text as a recipient at send time (verified: the Sent row resolved the recipient on a self-addressed business mail), and step 7's Sent check is the safety net. Blurring the To input does NOT commit it — do not substitute blur.
4. Subject: set it with the same native setter plus an `input` event. Re-read the subject value before sending — recipient text can end up appended to the subject during this flow; rewrite it with the setter if contaminated.
5. Body: inject the HTML through a TrustedTypes policy and fire an input event:
   ```js
   let policy;
   try { policy = window.trustedTypes.createPolicy('ehvmail', {createHTML: s => s}); }
   catch (e) { policy = {createHTML: s => s}; }
   body.innerHTML = policy.createHTML(html);
   body.dispatchEvent(new InputEvent('input', {bubbles: true}));
   ```
   For bodies larger than ~8 KB, inject in two parts — first `innerHTML` with part 1, then `insertAdjacentHTML('beforeend', policy.createHTML(part2))` — reusing a TrustedTypes policy per part (verified with a 14 KB digest; a single 4-5 KB injection also works in one shot).
6. Send by clicking the button whose `aria-label` starts with `Enviar`:
   ```js
   [...dlg.querySelectorAll('div[role="button"]')]
     .find(b => (b.getAttribute('aria-label') || '').startsWith('Enviar')).click();
   ```
   The dialog closing (URL back to `#inbox`) is not proof of delivery.
7. Verify delivery (never from a page with a compose window open, and never from `body.innerText`, which includes open compose/draft overlays): (a) open `#drafts` and confirm no row pairs "Borrador" with your subject (the draft must be gone); (b) navigate to `#sent` and find the subject inside a list row (`tr[role="row"]`) — scan ALL same-origin iframes for it, since the message list lives inside an iframe and querying only the first can return empty right after navigation. If a full-page `navigate` to `#sent` times out twice (observed after a send), switch views the SPA way instead: `evaluate --fn "location.hash = '#sent'"` (no reload, returns instantly) and then run the same iframe sweep.

## Completion check

- The Sent scan finds the mail with the exact intended subject and the recipient chip (`span[email]`).
- The subject contains no recipient address text.
