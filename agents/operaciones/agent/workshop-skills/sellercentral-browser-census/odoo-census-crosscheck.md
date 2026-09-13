<!-- project: github.com/gon0801/goncloud-openclaw -->
# Odoo census cross-check (`census_v2_pipe.sh`)

Read this before running, debugging, or modifying `packing/tmp/census_v2_pipe.sh <D>` in the operations workspace — the script behind the SKILL.md rule that a zero/silence conclusion must be backed by Odoo, not queue counters.

## Why the script exists

Once an Easy Ship label/pickup is purchased, the order leaves the unshipped/pending queues even before shipment — a queue census cannot see it. Verified: the 20h digest declared total silence while 2 labeled Easy orders and 1 Flex still needed packing.

## Required sections and sentinels

- (Q1) MELI old format: pickings partner ILIKE %mercado%libre% (covers 'Mercado Libre' with a space).
- (Q2) MELI new format: sale orders ILIKE 'ML %' OR meli_order_id IS NOT NULL, state=draft AND meli_status=paid (verified: they NEVER pass to sale/done; partner = buyer name, client_order_ref empty, no pickings; NOT EXISTS kills duplicate rows), 7-day creation window floored at 2026-09-08 (the 03-sep 49-order batch is import backlog, excluded by design), numero_real stripped of the ML prefix in SQL.
- (Q3) Amazon pickings: partner ILIKE '%amazon%' (substring: covers Flex id33/id25, Easy, FBM MX/US and any variant with amazon anywhere in the name), picking_type outgoing, deadline <= D in CDMX (double AT TIME ZONE UTC→CDMX; COALESCE(date_deadline, scheduled_date)).
- (Q2b) guards: ML in sale/done WITHOUT an outgoing picking (anomaly — include and flag it) plus the ALERTA_ML_FUERA_VENTANA sentinel (ML draft+paid without a picking that fell out of the 7-day window: n>0 must be reported as an alert, never ignored).

## Validation contract

- The script runs psql with -v ON_ERROR_STOP=1 — without it psql exits 0 on a failed query and empty output masquerades as a verified zero (the exact mechanism of the false-silence incident).
- Valid output = four sentinels (Q1_OK / Q2_OK / Q3_OK / ALERTA_ML_FUERA_VENTANA) + final CENSUS_V2_OK — and the script itself gates them in bash (tee to a file + grep before printing CENSUS_V2_OK), so a lost sentinel cannot pass as silence; a missing sentinel or CENSUS_V2_FAIL must abort the run with an alert, never silence.

## Write-channel corruption (`$( )` -> `***`)

The script contains ZERO command substitution by design: this write channel intermittently corrupts `$( )` to `***` inside written bash files (verified once — the stored line `PASS=*** )` produced a line-13 syntax error; other `$( )` files have passed unchanged, so treat it as intermittent). It reads the pgpass through tempfile+read and captures query output with tee+grep instead of `$(...)`. When a written bash script fails with a syntax error, check the file for `***` where `$(` was before retrying anything.
