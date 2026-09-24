---
name: sellercentral-browser-census
description: Read Amazon Seller Central and Seller Flex order queues with the claw browser profile — tab recovery, row extraction, ship-by quirks, the Odoo Q3 / MELI direct-API cross-checks that back a zero or silence conclusion, customization (personalizadas) capture. Use for census or packing reads of Amazon MX/US orders, including when a labeled order still needs a packing backfill.
---

# Seller Central Browser Census

Read-only order census from Seller Central (MX/US) and Seller Flex using browser profile `claw`, target host. Never mutate orders.

## Steps

1. Open queue URLs directly (orders-v3 `mfn` unshipped/pending × easyship/selfship, MX and US; sellerflex dashboard). Queue tabs usually survive between runs — check with `openclaw browser --browser-profile claw tabs` before opening new ones. Flag and timeout rules for every call below: `browser-cli-claw-profile`.
2. On transient `tab not found` errors: re-run `tabs`; the tab is normally still alive. Prefer the raw hex tab id over short suggested ids: pass it as `--target-id <id>`.
3. Read page text with `evaluate --fn 'document.body.innerText.slice(0,4000)'` — there is no `openclaw browser text` subcommand. If an `evaluate` times out, retry once — SC pages settle slowly.
4. Compact snapshots truncate before the orders table. Extract order IDs with an evaluate over `a,span,div,button,td` matching `/^\d{3}-\d{7}-\d{7}$/` on exact `textContent`.
5. Ship-by display quirk: the US queue shows PDT dates; the MX queue shows the same instant as `12:59 AM CST` of the next day (MX "Sep 10 12:59 AM" = US "Sep 9"). Compare instants, not labels.
6. NEVER declare zero/total silence from SC queue counts alone: once an Easy Ship label/pickup is purchased, the order leaves the unshipped/pending queues even before shipment — a queue census cannot see it (verified: the 20h digest declared total silence while 2 labeled Easy orders and 1 Flex still needed packing). Back a zero with both ground truths, never with queue counters:
   - Amazon: the Q3 section of `packing/tmp/census_v2_pipe.sh <D>` in the operations workspace. Valid output = four sentinels (Q1_OK / Q2_OK / Q3_OK / ALERTA_ML_FUERA_VENTANA) + final CENSUS_V2_OK; a missing sentinel or CENSUS_V2_FAIL must abort the run with an alert, never silence. Q3 surfaces Odoo-stale 'ghosts' (shipped in SC, picking never validated): contrast each row against SC, exclude confirmed-shipped from the digest, list them for Odoo cleanup.
   - MELI: the direct API census `packing/meli_census_directo.py <D>` (RUNBOOK-20h section CENSO MELI DIRECTO), which ends in `MELI_CENSUS_OK`. The Odoo queues Q1/Q2/Q2b are superseded for MELI since 2026-09-13 and stay out of the digest — the script still emits and gates them, so ignore their rows rather than reading them as the MELI answer. ML orders carry no ship-by in Odoo (commitment_date NULL): report 'sin fecha de envio ML', never invent one. A labeled order that still needs packing goes out via manual backfill (helper flow in `telegram-send-gonserver`).
   Read `odoo-census-crosscheck.md` before running, debugging, or modifying the script (query design, sentinel semantics, and the `$( )` -> `***` write-channel forensics).
7. Customization details (personalizadas): when an order is marked personalizada, open `/orders-v3/order/<id>` and click the exact Show more button — `[...document.querySelectorAll('a,button,[role=button]')].filter(e => e.textContent.trim() === 'Show more')` (generic keyword or `aria-expanded` clicks do nothing) — then follow `customization-capture.md` for the preview location, the CHUNKS capture method, and the alternatives that fail. For the send flow follow rule 1b of `packing/RUNBOOK-20h.md` in the operations workspace.

## Completion check

- Every queue read returns explicit counts (including zero) and each order row carries order id, buyer name, product/SKU, and ship-by.
- A zero/silence conclusion is backed by the Amazon cross-check (`census_v2_pipe.sh` Q3) and the MELI direct API census (`meli_census_directo.py`), not queue counters alone.
- Only read-only page actions were used.
