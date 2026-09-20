---
name: packing-baseline-html-pair
description: Falta el par base envios-del-dia del packing o hay que regenerarlo a mano: par amazon+meli, secciones, encoding y que declarar como faltante.
---

# Packing baseline HTML pair (`envios-del-dia`)

The pair `envios-del-dia/<D>-amazon.html` + `<D>-meli.html` is the baseline every later run of packing day D dedups against: the extras crons' PASO 0 aborts when no pair for D exists, so a missing pair stalls the 11:00 and 20:00 cuts. Rebuild it from the digest content the run already produced — never from a fresh census.

## Steps

1. Recover the day's content from the run's own digest text: `read` `packing/tmp/digest_20h_<D>.txt` (UTF-8). If that file is gone, the same content is in the run history: `openclaw cron runs eeae2a74-6389-4e83-a80a-d0ae6cdc7988` → the entry for D whose `summary` holds the digest. (A pasted copy of an earlier history also sits in `tmp/run20h.json` — UTF-16LE and only as fresh as the day it was dumped, so prefer the CLI.)
2. Write the pair from that content only. Do not run censuses (SC / MELI / Odoo) to rebuild a pair: the pair reports what the digest reported, so a new census risks a pair that disagrees with the digest that was already delivered.
3. Cross-check the recovered text against the run summary and `packing/RUNBOOK-20h.md` (Formato v9.1 is authoritative for fields). When the two sources disagree on a field — Modelo/Estuche, or the SKU ↔ Envío ID pairing of a Flex order — write the digest `.txt` verbatim and list every divergence in the report. Never merge silently, pick the tidier value, or invent a name, hour, or channel the input does not carry.
4. Write both files with the `write` tool (UTF-8), copying the shape of the previous day's pair. Skeleton:

```html
<!DOCTYPE html>
<html><head><meta charset="utf-8"></head>
<body style="margin:0;background:#f4f4f7;font-family:Arial,sans-serif;">
<div style="max-width:640px;margin:0 auto;background:#fff;">
  <div style="background:#232f3e;color:#fff;padding:18px 24px;">
    <h1 style="margin:0;font-size:20px;">Ventas para empacar — <dia> <D> de <mes></h1>
    <p style="margin:4px 0 0;font-size:13px;color:#d5d9df;">Amazon Seller Central &#183; <que produjo este par></p>
  </div>
  <div style="padding:16px 24px;">

  <h2 style="font-size:16px;border-bottom:2px solid #ff9900;padding-bottom:6px;">AMAZON EASY SHIP</h2>
  <div style="border:1px solid #ddd;background:#fafafa;padding:10px 14px;margin-bottom:10px;">
    <b>Pedido:</b> 702-0000000-0000000<br>
    <b>Cliente:</b> <nombre real><br>
    <b>Modelo:</b> <modelo><br>
    <b>Color:</b> <color><br>
    <b>Estuche:</b> <estuche, si aplica><br>
    <b>SKU:</b> <sku interno><br>
    <b>Env&#237;o:</b> <ship-by>
  </div>
  </div>
</body></html>
```

   Field order per card is the RUNBOOK one: Pedido, Cliente, [PERSONALIZADA], Modelo, Color, Estuche, SKU, [Envío ID], Envío. Section headings and their border colors: `AMAZON MX / US`, `AMAZON EASY SHIP` and `AMAZON FLEX` → `#ff9900`; `MERCADO LIBRE — POR EMPACAR` → `#ffe600`. Include a section only when it has orders. Personalizada: bold line `PERSONALIZADA (foto aparte por sendPhoto)` after Cliente, never appended to the pedido number. Flex: `Envío ID:` line after SKU. MELI `Envío:` = `comprado <dia> <hh:mm>`, or `sin fecha de envio ML` — never a ship-by date. Accented label values go in as entities (`&#237;` = í, `&#233;` = é, `&#243;` = ó, `&amp;` = &). A side with zero orders is the literal `VACIO` (6 bytes, no HTML), as in `2026-09-16-meli.html` — that is what the extras dedup expects for an empty side.
5. Never copy a field out of console output: PowerShell and `Get-Content` render this UTF-8 content as mojibake (em dashes and accented letters come out as multi-character garbage), so a value lifted from the console lands corrupted. Take the text through the `read` tool and type the intended characters. These HTML artifacts are UTF-8 with accents and em dashes; the pure-ASCII rule applies only to cron prompt files (see `openclaw-cron-jobs`).
6. Verify before reporting: `node -e` on each file — bytes > 0, no `\uFFFD`, starts with `<!DOCTYPE html>`, and the expected order ids and `<h2>` headings present (`node -e "...fs.readFileSync(f).toString('utf8')..."`). Then report the two absolute paths and the divergences from step 3 to main/David.
7. Touch nothing else: not the other day's pair, not `<D>-extras*.html`, not the `packing/` scripts. Writing the pair sends nothing — mail and Telegram belong to the run that produced the digest — so a pair-only rebuild stays silent and cannot duplicate a delivery.

## Completion check

- Both `<D>-amazon.html` and `<D>-meli.html` exist (or hold `VACIO` for an empty side) and the step-6 node check passes on each.
- The report gives both paths plus every field the recovered input could not supply (pending Flex names, missing ship-by hour/channel, conflicting Modelo/Estuche) instead of a filled-in guess.
