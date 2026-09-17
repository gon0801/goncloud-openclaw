---
name: egress-suppression-verify
description: Alert/email/webhook sending disabled? Prove zero egress on every path — config present but fake, transport poisoned, attempts captured = 0.
---

# Prove a removed outbound effect is really gone

Trigger: a change disables sending (Telegram alerts, email, webhook, push), or claims "ya no envía", "chat limpio", "no-op", "suprimido". Reading the diff is nivel 2; mocked unit tests prove nothing about real sends. The claim is only proven by calling the real senders in the real module with the transport poisoned.

## 1. Enumerate every sending path

Grep production code for the transport and the sender symbol — not the file list the implementer gave you:

- the transport target: `grep -rn "api.telegram.org\|sendMessage\|smtp\|webhook_url" app/ tools/ --include=*.py`
- the sender names the engines call (e.g. `_send_telegram_alert`), including renamed leftovers: `*_LEGACY_*`, `*_SUPRIMIDO`, `*_DESHABILITADO`.

Renamed-but-alive bodies are the trap. A leftover `_LEGACY_*` still holds the real HTTP call, so grep lights it up; it is a violation **only if a caller reaches it**. List callers per symbol and mark each reachable/unreachable — an unreachable body is dead weight, not a leak.

Then scan the test tree for assertions on the effect: `assert_called_once`, `call_count`, `assert_called`, and `<effect>_sent` keys. Only assertions that exercise the **real** sender break under a suppression — ones patching the sender with a mock stand-in keep passing and prove nothing. Each remaining expectation must be updated by the change or provably mocked; an untouched one is a blast-radius item.

Done when: a table of sender × reachability × test assertions, every row sourced from a command.

## 2. Set the enablement config to fake-but-present values

A fail-silent-on-missing-config path returns False with no config at all, so a bare call proves nothing. Put the real gate in place first: the env vars / settings rows the integration checks, with **fake** values (never real credentials). Only then does a False return mean "suppressed" rather than "unconfigured".

Done when: the checked config is present and fake, and you can name the exact key(s) you set.

## 3. Poison the transport, call each sender

Patch the lowest layer every path funnels through so it **raises**, and patch before importing the senders (an import-time `from requests import post` otherwise captures the original): `requests.post`, `requests.Session.request`, `urllib.request.urlopen`. Make each raise a recognizable error and append to a capture list.

- Call each sender directly with minimal stand-ins for its args; `MagicMock()` is enough when the sender only reads fields to build the aborted message text.
- Record each return value against its documented contract — suppression usually returns `False`/`None` while the caller continues, and a wrapper may still return `True` because it reports its DB insert, not the send.

Done when: one line per sender: return value + captured-attempts count.

## 4. Completion

- Captured attempts = **0** for every sender, with the config present. One attempt = FAIL: paste the sender and the capture.
- Every leftover body (`_LEGACY_*`) has zero reachable callers.
- Write the result to the blast artifact your dispatch names (repo convention: `.saikit/findings/blast-<task>.json`), `nivel`: 4, with the probe command and the per-sender output. **Redact before writing**: flatten CR/LF, truncate, and keep the fake env values out of the artifact.
- This is nivel 4: the real module, exercised on purpose. Nivel 5 (the running app) needs the repo's own e2e — name which level you reached, and never let a nivel-4 proof stand in for it unstated.
- If a sender cannot be called in isolation (needs live engine/DB state), call the nearest reachable wrapper and say which layer you proved; mark the rest **inconcluso**. Inconcluso ≠ PASS.

## Boundaries

- Do not re-run the repo's full test battery for this: the suppression proof is a focused probe. Battery rules live in `regression-triage`.
- A red suite after a suppression is an attribution question, not this skill — go to `regression-triage`.
