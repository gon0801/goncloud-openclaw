---
name: openclaw-gateway-diag
description: "Diagnose OpenClaw gateway hangs, cron false-ok, LLM idle timeout on the Windows host; classify stream idle vs HTTP and do not invent config keys."
---

# OpenClaw gateway diagnosis (Windows host)

## When

Gateway hangs, cron `ok` with no real deliverable, `LLM idle timeout`, zai/glm stalls, or "no final summary was produced".

## Steps

1. Read logs on the gateway filesystem (exec is often pinned to the Mac node; `host:"gateway"` is rejected). Dated JSONL lives at `C:\Users\ehven\AppData\Local\Temp\openclaw\openclaw-YYYY-MM-DD.log` — date is the host local timezone, not UTC. Docs default `/tmp/openclaw` is not used on this Windows install. Jump by timestamp (EDT = UTC−4) with `read` offsets; do not wait for gateway `findstr`.
2. Classify the hang from evidence, not theory:
   - Stream idle: transcript `stopReason=aborted` + `errorMessage="LLM idle timeout (Ns): no response from model"`; `model-fetch` lines show `status=200` SSE and `timeoutMs=undefined`. Not 429. TTFB of 10–50s then silence still trips the idle watchdog.
   - HTTP/provider: `model-fetch` status 429/5xx or `failoverReason` auth/rate_limit/server_error.
   - Cron cloud stalls can cap idle at **60s** even when docs say cloud default 120s (`docs/concepts/agent-loop.md`). `models.providers.<id>.timeoutSeconds` becomes `modelRequestTimeoutMs` and **wins** over that default (verified: zai had none → 60s message; llama-cpp already had 600).
3. Cron `status: ok` is not proof of success. After tools settle, empty recovery injects `SETTLED_TOOL_FINALIZATION_FALLBACK_TEXT` via `provider=openclaw` `model=delivery-mirror` `idempotencyKey=…:settled-finalization-fallback`. Log: `settled post-tool turn lacked a final answer … running isolated finalization`. That visible sentence makes `resolveCronPayloadOutcome` treat the run as ok. `NO_REPLY` / `HEARTBEAT_OK` stay silent and must remain `ok`. Aborts do **not** trigger model fallback (`result-fallback-classifier` skips `meta.aborted`).
4. Before proposing OpenClaw config: read `docs/gateway/config-automation.md` and `docs/concepts/agent-loop.md`. There is no `cron.*` flag for “no summary = error”. Do not add `agents.defaults.llm.idleTimeoutSeconds` — doctor strips the legacy `llm` block. Do not patch `node_modules/openclaw/dist`. Source-level idle false-ok is OpenClaw PR **#141072** (preserve timeout terminal when recovery is empty); wait for merge + `openclaw update`, or ask before any local build. Restarting the gateway kills in-flight cron; check `openclaw cron list` Next times first (workspace AGENTS.md).

Completion check: cited log/transcript lines for idle vs HTTP vs delivery-mirror; config advice matches schema/docs; no dist patch and no invented keys.
