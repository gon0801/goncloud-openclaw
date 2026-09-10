---
name: gmail-compose-rich-mail
description: Send an HTML-formatted mail from the business Gmail session via browser (profile claw) — fill recipient, subject, and rich body through JS, send, and verify in Sent. Use when a packing report or digest mail must go out through browser Gmail.
---

# Gmail Compose Rich Mail

Compose and send rich HTML mail in Gmail with browser profile `claw`, target host, driving everything by JS evaluation — snapshots do not see the compose dialog.

## Steps

1. Keep a tab on `https://mail.google.com/mail/u/0/#inbox` (profile `claw`). Click the "Redactar" button and wait for `div[role="dialog"]` to appear.
2. Do all compose work with `act` `evaluate` inside that dialog; query-filtered snapshots (compact or `refs="aria"`) return nothing for it. Selectors: `input[aria-label="Destinatarios"]` (To), `input[name="subjectbox"]` (subject), `div[aria-label="Cuerpo del mensaje"]` (body).
3. Recipient: `execCommand('insertText')` does nothing on the To input. Use the native setter, then commit the chip with a REAL Enter:
   ```js
   const to = dlg.querySelector('input[aria-label="Destinatarios"]');
   Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')
     .set.call(to, 'target@example.com');
   to.dispatchEvent(new Event('input', {bubbles: true}));
   to.focus();
   ```
   then `act` `press` key `Enter`. A synthetic `KeyboardEvent` does NOT commit the chip; only the real key event does. Blurring the To input does NOT commit it either (chips stay empty) — do not substitute blur for the press. If the `press` call fails once with `Unknown key: "***"` (a serialization artifact), retry the identical call — the second attempt delivers the real Enter.
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
7. Verify in Sent: navigate to `#sent` and scan ALL same-origin iframes for the subject text — the message list lives inside an iframe, and querying only the first iframe can return empty right after navigation.

## Completion check

- The Sent scan finds the mail with the exact intended subject and the recipient chip (`span[email]`).
- The subject contains no recipient address text.
