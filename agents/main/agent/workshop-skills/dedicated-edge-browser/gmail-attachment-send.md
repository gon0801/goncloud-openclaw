# Gmail Attachment Send (Claw's dedicated Edge)

Send a plain email with a file attachment through Gmail web compose in Claw's dedicated Edge (port 18803), with the file already on the gateway. Verified 2026-09-12: subject/body/attachment filled, sent, toast "Mensaje enviado". For rich HTML bodies use `gmail-html-email` (Trusted Types injection); its verification rules (Sent-folder check, never trust page text with a compose window open) apply here too.

## Steps

1. Rename the artifact to its real name first — downloads land as extensionless GUIDs. `Copy-Item <dl-path>\<guid> "C:\Users\ehven\Downloads\<real-name>.xlsx" -Force` and check the size.
   - Completion: named file exists, non-zero.
2. Connect to port 18803 (step pattern of the SKILL.md), open `https://mail.google.com/mail/u/0/#inbox`, wait ~12 s. A redirect to `accounts.google.com` means the session expired — owner logs in once in the visible window.
   - Completion: URL is a Gmail view, not a sign-in page.
3. Open compose by clicking the button whose **aria-label is "Redactar"** (Spanish UI; "Escribir"/"Compose" matched nothing). Find it by probing `div[role=button], button` aria-labels.
   - Completion: a `div[role="dialog"]` with an address input appears.
4. Fill in dialog order — click each field, `keyboard.type`, no setters needed:
   - To: the dialog's first text input (plain `input[name="to"]` may be absent); after typing, `Tab` commits the chip.
   - Subject: `input[name="subjectbox"]`.
   - Body: the dialog's `div[role="textbox"]`.
   - Completion: fields visibly hold the values.
5. Attach: `uploadFile` on the dialog's `input[type="file"]` (uploading does not open the OS file dialog). Wait ~8 s for the chip to appear.
   - Completion: attachment chip visible in the dialog.
6. Send: click the dialog's button labelled `Enviar` (match text, not document-wide). Verify by the toast "Mensaje enviado" (`document.body.innerText` match is fine once the compose is closed; the stricter Sent-folder rules live in `gmail-html-email` step 6).
   - Completion: toast captured; report recipient, subject, attachment.
