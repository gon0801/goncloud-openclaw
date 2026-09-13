---
name: sellercentral-browser-census
description: Read Amazon Seller Central and Seller Flex order queues with the claw browser profile — tab recovery, row extraction, ship-by quirks, Odoo cross-check for zero/silence conclusions, customization (personalizadas) capture. Use for census or packing reads of Amazon MX/US orders.
---

# Seller Central Browser Census

Read-only order census from Seller Central (MX/US) and Seller Flex using browser profile `claw`, target host. Never mutate orders.

## Steps

1. Open queue URLs directly (orders-v3 `mfn` unshipped/pending × easyship/selfship, MX and US; sellerflex dashboard). Queue tabs usually survive between runs — check with `action=tabs` before opening new ones.
2. On transient `tab not found` errors: re-run `action=tabs`; the tab is normally still alive. Prefer the raw hex `targetId` over short tab ids on subsequent actions. If `tabs` responds but `evaluate`/`navigate`/`screenshot` consistently time out (wedged bridge after a gateway restart), stop retrying browser actions — report the browser limit and reroute through ssh, whose approval passes independently. Element-scoped screenshots (`element=` selector) hung repeatedly in this setup (observed on gestalt pages) while `tabs` still responded; do not build a flow that depends on them.
3. Read rows with `action=text` (maxChars ~4000). If a text action times out, retry once — SC pages settle slowly.
4. Compact snapshots truncate before the orders table. Extract order IDs with an evaluate over `a,span,div,button,td` matching `/^\d{3}-\d{7}-\d{7}$/` on exact `textContent`.
5. Ship-by display quirk: the US queue shows PDT dates; the MX queue shows the same instant as `12:59 AM CST` of the next day (MX "Sep 10 12:59 AM" = US "Sep 9"). Compare instants, not labels.
6. NEVER declare zero/total silence from SC queue counts alone: once an Easy Ship label/pickup is purchased, the order leaves the unshipped/pending queues even before shipment — a queue census cannot see it (verified: the 20h digest declared total silence while 2 labeled Easy orders and 1 Flex still needed packing). Cross-check Odoo first with `packing/tmp/census_v2_pipe.sh <D>` in the operations workspace: valid output = four sentinels (Q1_OK / Q2_OK / Q3_OK / ALERTA_ML_FUERA_VENTANA) + final CENSUS_V2_OK; a missing sentinel or CENSUS_V2_FAIL must abort the run with an alert, never silence. ML orders carry no ship-by in Odoo (commitment_date NULL): report 'sin fecha de envio ML', never invent one. Q3 surfaces Odoo-stale 'ghosts' (shipped in SC, picking never validated): contrast each row against SC, exclude confirmed-shipped from the digest, list them for Odoo cleanup. A labeled order that still needs packing goes out via manual backfill (helper flow in `telegram-send-gonserver`). Read `odoo-census-crosscheck.md` before running, debugging, or modifying the script (query design, sentinel semantics, and the `$( )` -> `***` write-channel forensics).
7. Customization details (personalizadas): when an order is marked personalizada, open `/orders-v3/order/<id>` and click the exact Show more button — `[...document.querySelectorAll('a,button,[role=button]')].filter(e => e.textContent.trim() === 'Show more')` (generic keyword or `aria-expanded` clicks do nothing) — then follow `customization-capture.md` for the preview location, the CHUNKS capture method, and the alternatives that fail. For the send flow follow rule 1b of `packing/RUNBOOK-20h.md` in the operations workspace.

## Completion check

- Every queue read returns explicit counts (including zero) and each order row carries order id, buyer name, product/SKU, and ship-by.
- A zero/silence conclusion is backed by the Odoo cross-check (`census_v2_pipe.sh`), not queue counters alone.
- Only read-only page actions were used.
