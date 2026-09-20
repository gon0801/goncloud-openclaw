---
name: gmail-html-email
description: Send styled/rich HTML email through Gmail web compose in the automated browser. Use when a task says send an HTML/formatted email to a Gmail address, or when injecting innerHTML into Gmail compose throws a TrustedHTML error. Produces a sent HTML email verified in Gmail's Sent folder.
---

# Gmail HTML Email (browser automation)

Send a formatted HTML email through Gmail compose when the browser profile `claw` (or another managed profile) has a live Gmail session. Verified 2026-09-08 (compose fill + HTML + send) and 2026-09-09 (re-send of a stuck draft via native click; corrected delivery check — page `innerText` with a compose window open is a false positive, never report sent from that).

## Steps

1. Start the managed browser profile, then confirm Gmail is open. Profiles are stopped after gateway restarts, so first check `browser tabs` on the profile (e.g. `claw`); if it reports `running: false`, start it with `browser start` on that profile name — cookies/sessions persist in the profile user-data dir, so Gmail stays logged in. Then, if no Gmail tab exists, navigate to `https://mail.google.com/mail/u/0/#sent` first so the session proves live, and open compose with `https://mail.google.com/mail/u/0/#inbox?compose=new`.
   - Before composing, close any leftover compose window from a previous run: if the tab URL contains `?compose=` or a compose dialog is open, click its "Guardar y cerrar" button so it cannot contaminate later verification.
   - Completion: the profile reports `running: true`, Gmail is logged in, and no compose window is open.

2. Locate the compose fields with one `act kind=evaluate` probe, since Gmail snapshots often expose only an `<iframe>` and hide the real inputs:
   `Array.from(document.querySelectorAll('input, [contenteditable="true"]')).map(e => ({aria: e.getAttribute('aria-label'), name: e.getAttribute('name')}))`
   Expected handles: recipients `input[aria-label="Destinatarios"]`, subject `input[name="subjectbox"]`, body `div[aria-label="Cuerpo del mensaje"][contenteditable="true"]` (Spanish UI; adapt for English: "To recipients" / subjectbox / "Message Body").

3. Fill recipient and subject with the React-safe native setter pattern — plain `.value =` does NOT stick in Gmail:
   ```js
   const setVal = (el, v) => {
     const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
     Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v);
     el.dispatchEvent(new Event('input', {bubbles: true}));
   };
   ```
   After setting the recipient, do NOT rely on dispatching Enter alone — it can leave the address uncommitted (no chip forms and the send silently fails). Instead focus the input, set the value, then click the autocomplete suggestion whose text contains the address (`div[role="option"]`, poll up to ~4 s for it to appear) and confirm a recipient chip exists in the compose dialog before continuing.
   - Completion: the compose dialog shows the recipient as a chip (e.g. `div[aria-label^="Para"]` containing the name/address) and the subject input's `.value` equals what you typed.

4. Inject the HTML body. Direct `body.innerHTML = html` fails with: *"This document requires 'TrustedHTML' assignment."* Fix: create a Trusted Types policy and assign through it:
   ```js
   let policy;
   try { policy = window.trustedTypes.createPolicy('inject', { createHTML: s => s }); } catch (e) {}
   body.innerHTML = policy ? policy.createHTML(html) : body.innerHTML;
   body.dispatchEvent(new Event('input', { bubbles: true }));
   ```
   Pass the HTML inside the evaluate function as base64 (`atob('...')` + `decodeURIComponent(escape(...))` for UTF-8) to avoid shell/JSON quoting breakage on long documents.
   - Fallback when base64 is unavailable (shell `exec` denied) and `file://` navigation is blocked: embed the HTML directly in the evaluate fn as a JS template literal with **every backslash doubled** (`C:\Users\...` → `C:\\Users\\...`) so Windows paths survive; UTF-8 passes through untouched. Verify after injection with `body.innerHTML.length > 0` plus key substrings, including one containing a backslash path.
   - Completion: probe returns `body.innerHTML.length` > 0 and the key text samples match.

5. Click the real Send button — scope the search to the compose dialog and match its actual label:
   ```js
   const dlg = [...document.querySelectorAll('div[role="dialog"]')].find(d => d.querySelector('input[name="subjectbox"]'));
   const b = [...dlg.querySelectorAll('div[role="button"], button')].find(x => (x.getAttribute('aria-label')||'').startsWith('Enviar'));
   b && b.click();
   ```
   Observed 2026-09-09 (Spanish UI): the working button's aria-label is **"Enviar (Ctrl-Enter)"**. Never search the whole document for `Enviar` — a document-scope match can hit an unrelated element and the click no-ops while returning `ok`. A plain synthetic `.click()` may also return `ok` without firing Gmail's handler: after clicking, poll until the compose dialog closes (the tab URL loses `?compose=`). If it stays open, locate the button again, read its bounding-rect center via evaluate, and send a native coordinate click there (`act kind=clickCoords`). A real send shows the toast "Se envió el mensaje".
   - Completion: the compose dialog is gone (URL hash has no `?compose=`) and the toast appeared.

6. Verify delivery — never from a page with a compose window open:
   - (a) Open `https://mail.google.com/mail/u/0/#drafts` and confirm no list row pairs "Borrador" with your subject (the draft must be gone).
   - (b) Navigate to `https://mail.google.com/mail/u/0/#sent` and confirm the URL has **no** `?compose=` fragment (compose closed). Find the subject inside a list row (`tr[role="row"]` text) — do NOT rely on `document.body.innerText`, which includes any open compose/draft overlay (this exact check caused a false "sent" report on 2026-09-09).
   - (c) Recipient evidence: when sending to the account itself, the Sent row may read "yo"/"Para: mí"; if the row does not show the address, open the message and read its To header.
   - Completion: draft gone, subject found in a Sent row, recipient confirmed. Only then report the email as sent.

Recovery — message stuck as a draft: Gmail auto-saves drafts, so nothing is lost. Reopen the draft row in `#drafts`, confirm subject/recipient/body are intact (`body.innerHTML.length` > 0), then redo steps 5–6. Verified 2026-09-09: the draft reopened complete and a native click on "Enviar (Ctrl-Enter)" delivered it.

## Pitfalls

- Gmail page snapshots (`efficient`/role) may show only an iframe with no compose fields; use `act evaluate` against the top document instead of snapshot refs for fill/send steps.
- Never paste raw HTML as text into the body — it arrives as literal source. Always inject through the contenteditable with the Trusted Types policy above.
- Long HTML in evaluate strings breaks on quotes/newlines; base64-encode it first and decode inside the function. If you cannot base64 (no shell), the doubled-backslash template-literal fallback in step 4 is verified working.
- `document.body.innerText` contains any open compose or draft content — never use it alone as proof of delivery; the `?compose=` fragment in the URL marks an open compose window.
- The Send button inside the compose dialog is "Enviar (Ctrl-Enter)" (Spanish UI, verified 2026-09-09); a document-wide search for "Enviar" or a synthetic click can silently no-op. Completion = compose dialog closes; otherwise retry with a native coordinate click.
- Keep secrets (tokens, credentials) out of the evaluate payloads; the compose address is the only recipient data needed.
