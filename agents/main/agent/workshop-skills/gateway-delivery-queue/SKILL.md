---
name: gateway-delivery-queue
description: Inspect failed entries in the gateway delivery queue (state/openclaw.sqlite) and purge only terminal recovery receipts. Use when openclaw health reports deliveryQueues.failed > 0, when a queued send never left, or when asked to clean up failed deliveries. Produces an emptied queue verified by health.
---

# Gateway Delivery Queue (state/openclaw.sqlite)

The gateway's outbound queue lives in `state/openclaw.sqlite`, table `delivery_queue_entries` (`queue_name`, `status`, `id`, `entry_json`, `recovery_state`, `enqueued_at`/`failed_at`). `openclaw health` surfaces a non-empty queue as `deliveryQueues.failed`; when the queue is clean that key is **absent from the output entirely** (not zero). Verified 2026-09-11 on the Windows gateway: 3 `failed` rows classified, backed up and purged by exact id; health then reported no `deliveryQueues`.

## Steps

1. Enumerate the candidate DBs (`Get-ChildItem <gateway-root>, <gateway-root>\state -Filter *.sqlite`) — the queue was in `state\openclaw.sqlite`. Inspect read-only with `new DatabaseSync(p,{readOnly:true})`; `node:sqlite` is built into node 24, no `--experimental-sqlite` flag. The script prints `sin tabla delivery_queue_entries` and exits when a DB has no such table, so the same script is safe to run on every candidate.
   Write the script to a `.js` file and run `node <file> <db-path>`. Do **not** use `node -e '…'`: PowerShell mangles the single-quoted JS, `require("node:sqlite")` arrives as `require(node:sqlite)`, and it dies with `SyntaxError: missing ) after argument list`.
   Queries: table existence, `SELECT * FROM delivery_queue_entries WHERE status='failed'`, and a count grouped by `queue_name, status`. Truncate any `entry_json` over ~400 chars in the printout.
   - Completion: you have every failed row and the per-queue counts.

2. Classify each failed row before touching it. A **terminal recovery receipt** is safe to purge: `channel`, `target`, `session_key`, `entry_kind`, `last_error` all `null`, `recovery_state` in `completed_permanent` / `completed_bounded`, and an `entry_json` holding only id/timestamps/retention — no message text, no media path. A **real undelivered message** carries a channel/target and content in `entry_json`: purging it drops a message and the send is the thing to fix. Never delete a row you did not print and classify.
   - Completion: every row you intend to delete is named as a terminal receipt with its id.

3. Deleting rows from the gateway's state DB is destructive: get the owner's explicit confirmation naming the queue and the count first.
   - Completion: owner approval on record for this queue and count.

4. Back up as a consistent snapshot, not a file copy: `VACUUM INTO '<abs-path>'` from a `readOnly` handle. The destination must be in **single quotes** — with `"…"` SQLite reads it as a column name and fails `no such column: "C:/…/openclaw.pre-dq-….sqlite"`. Confirm the backup file exists, non-zero, before any delete.
   - Completion: `backup ok` plus a non-zero backup file.

5. Delete by exact id inside one transaction: `DELETE FROM delivery_queue_entries WHERE queue_name=? AND status=? AND id=?` per id, wrapped in `BEGIN`/`COMMIT`, summing `changes`. Ids can contain colons (`main-session-restart-recovery:pending-final:<uuid>`), so parameterize; never `DELETE … WHERE status='failed'`.
   - Completion: the summed `changes` equals the approved count and the grouped counts show no `failed` row for that queue.

6. Verify: re-run the read-only inspection (0 failed) and `openclaw health --json` grep for `delivery` — the `deliveryQueues` key is gone. Per-agent DBs are `agents\<id>\agent\openclaw-agent.sqlite` (sessions); if only one DB was checked, run the same step-1 script on the others rather than assuming.
   - Completion: 0 failed rows and health reports no delivery queues.

## Pitfalls

- PowerShell quoting is the main trap here; both the inspection JS and the SQL `VACUUM INTO` path belong in a `.js` file — do not fight the one-liner.
- A `failed` row is not automatically an undelivered message: terminal recovery receipts dominate the count and are the only safe purge target.
- If `node:sqlite` is missing, retry with `--experimental-sqlite` rather than switching to another driver.
