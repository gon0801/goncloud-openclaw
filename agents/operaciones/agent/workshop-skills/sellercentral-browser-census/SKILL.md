---
name: sellercentral-browser-census
description: Read Amazon Seller Central and Seller Flex order queues with the claw browser profile — tab recovery, row extraction, ship-by quirks, customization details. Use for census or packing reads of Amazon MX/US orders.
---

# Seller Central Browser Census

Read-only order census from Seller Central (MX/US) and Seller Flex using browser profile `claw`, target host. Never mutate orders.

## Steps

1. Open queue URLs directly (orders-v3 `mfn` unshipped/pending × easyship/selfship, MX and US; sellerflex dashboard). Queue tabs usually survive between runs — check with `action=tabs` before opening new ones.
2. On transient `tab not found` errors: re-run `action=tabs`; the tab is normally still alive. Prefer the raw hex `targetId` over short tab ids on subsequent actions. If `tabs` responds but `evaluate`/`navigate`/`screenshot` consistently time out (wedged bridge after a gateway restart), stop retrying browser actions — report the browser limit and reroute through ssh, whose approval passes independently. Element-scoped screenshots (`element=` selector) hung repeatedly in this setup (observed on gestalt pages) while `tabs` still responded; do not build a flow that depends on them.
3. Read rows with `action=text` (maxChars ~4000). If a text action times out, retry once — SC pages settle slowly.
4. Compact snapshots truncate before the orders table. Extract order IDs with an evaluate over `a,span,div,button,td` matching `/^\d{3}-\d{7}-\d{7}$/` on exact `textContent`.
5. Ship-by display quirk: the US queue shows PDT dates; the MX queue shows the same instant as `12:59 AM CST` of the next day (MX "Sep 10 12:59 AM" = US "Sep 9"). Compare instants, not labels. Queue coverage limit: once a shipping label is purchased (order page shows carrier + tracking ID, status Shipped), the order leaves the unshipped/pending queues even before carrier handover — a queue census cannot see it, so a pending personalization send for a labeled order needs manual backfill (helper flow in `telegram-send-gonserver`).
6. Customization details (personalizadas): open `/orders-v3/order/<id>` and click the exact Show more button — `[...document.querySelectorAll('a,button,[role=button]')].filter(e => e.textContent.trim() === 'Show more')` (generic keyword or `aria-expanded` clicks do nothing). The illustrative preview lives behind the Customization Information link on the gestalt page; grab its presigned URL by evaluating images — filter `currentSrc || src` on `/gestalt-buyer-snapshot|s3\.amazonaws\.com|X-Amz-Signature/i`, expecting a 400×400 img — and download immediately with exec `Invoke-WebRequest` (evaluate works where element screenshots hang). The URL expires in 60 s — for the download-and-send flow follow rule 1b of `packing/RUNBOOK-20h.md` in the operations workspace.

## Completion check

- Every queue read returns explicit counts (including zero) and each order row carries order id, buyer name, product/SKU, and ship-by.
- Only read-only page actions were used.
