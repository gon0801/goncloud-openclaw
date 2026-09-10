#!/bin/bash
# census_v2_pipe.sh v4c — fixes lead 10-sep: PGPASSWORD real, temporales por PID, umask 077.
# CERO command-substitution en todo el archivo (ni siquiera en comentarios: el canal de
# escritura de Windows corrompe esa sintaxis): pgpass via tempfile + read; PID via $$;
# sentinels gateados en bash con tee + grep sobre archivos.
# P0/P2: Qn_OK gateado en bash antes de CENSUS_V2_OK; Q1/Q3 con picking_type outgoing; patron %amazon%.
# P1-3: Q2b guards: ML sale/done SIN picking (anomalia) + ALERTA ML draft+paid fuera de ventana sin picking.
# Uso: bash census_v2_pipe.sh <D>   (D = dia de empaque YYYY-MM-DD, fecha CDMX)
set -euo pipefail
umask 077
D="${1:?falta D (YYYY-MM-DD)}"
T=/tmp/cv2.$$; mkdir -m 700 "$T"
trap 'rm -rf "$T"; echo CENSUS_V2_FAIL: fallo inesperado linea $LINENO — ABORTA con ALERTA, nunca silencio' ERR
trap 'rm -rf "$T"' EXIT
awk -F: '$3=="EHV"{print $NF; exit}' /home/claw/.pgpass_claw_ro > "$T/p"
read -r PASS < "$T/p"
rm -f "$T/p"
[ -n "$PASS" ] || { echo CENSUS_V2_FAIL: pgpass sin entrada EHV; exit 1; }
run() { sudo -n docker exec -i -e PGPASSWORD="$PASS" odoo-db-1 psql -X -h 127.0.0.1 -U claw_ro -d EHV -v ON_ERROR_STOP=1; }
gate() { grep -q "$1" "$2" || { echo "CENSUS_V2_FAIL: sentinel $1 ausente en $2 — ABORTA con ALERTA, nunca silencio"; exit 1; }; }
Q1F="$T/q1"; Q2F="$T/q2"; Q3F="$T/q3"; Q2BF="$T/q2b"

echo "=== (Q1) MELI formato VIEJO: pickings %mercado%libre% outgoing | D=${D} CDMX ==="
run <<SQL | tee "$Q1F" || { echo 'CENSUS_V2_FAIL Q1: fallo docker/psql — ABORTA con ALERTA, nunca silencio'; exit 1; }
SELECT rp.name AS partner, so.name AS odoo, so.client_order_ref, sp.name AS picking, sp.state,
       ((COALESCE(sp.date_deadline, sp.scheduled_date) AT TIME ZONE 'UTC') AT TIME ZONE 'America/Mexico_City')::date AS deadline_cdmx
FROM stock_picking sp
JOIN sale_order so ON so.id = sp.sale_id
JOIN res_partner rp ON rp.id = so.partner_id
JOIN stock_picking_type spt ON spt.id = sp.picking_type_id
WHERE rp.name ILIKE '%mercado%libre%' AND sp.state IN ('assigned','confirmed','waiting') AND spt.code='outgoing'
  AND ((COALESCE(sp.date_deadline, sp.scheduled_date) AT TIME ZONE 'UTC') AT TIME ZONE 'America/Mexico_City')::date <= DATE '${D}'
  AND so.name NOT IN ('S01570','S01574')
ORDER BY 6;
SELECT 'Q1_OK n=' || count(*) FROM (
  SELECT sp.id FROM stock_picking sp JOIN sale_order so ON so.id = sp.sale_id JOIN res_partner rp ON rp.id = so.partner_id
  JOIN stock_picking_type spt ON spt.id = sp.picking_type_id
  WHERE rp.name ILIKE '%mercado%libre%' AND sp.state IN ('assigned','confirmed','waiting') AND spt.code='outgoing'
    AND ((COALESCE(sp.date_deadline, sp.scheduled_date) AT TIME ZONE 'UTC') AT TIME ZONE 'America/Mexico_City')::date <= DATE '${D}'
    AND so.name NOT IN ('S01570','S01574')) sub;
SQL
gate 'Q1_OK' "$Q1F"

echo "=== (Q2) MELI formato NUEVO: ML/draft+paid SIN picking, ventana 7d + piso 2026-09-08 ==="
run <<SQL | tee "$Q2F" || { echo 'CENSUS_V2_FAIL Q2: fallo docker/psql — ABORTA con ALERTA, nunca silencio'; exit 1; }
SELECT regexp_replace(so.name, '^ML[ ]+', '') AS numero_real, rp.name AS cliente,
       ((so.date_order AT TIME ZONE 'UTC') AT TIME ZONE 'America/Mexico_City')::timestamp(0) AS creada_cdmx,
       so.meli_status, 'sin fecha de envio ML' AS envio
FROM sale_order so
LEFT JOIN res_partner rp ON rp.id = so.partner_id
WHERE (so.name ILIKE 'ML %' OR so.meli_order_id IS NOT NULL)
  AND so.state = 'draft'
  AND so.meli_status = 'paid'
  AND ((so.date_order AT TIME ZONE 'UTC') AT TIME ZONE 'America/Mexico_City') >= (DATE '${D}' - 7)
  AND so.date_order >= TIMESTAMP '2026-09-08 00:00:00'
  AND NOT EXISTS (SELECT 1 FROM stock_picking sp2 WHERE sp2.sale_id = so.id
                  AND sp2.picking_type_id IN (SELECT id FROM stock_picking_type WHERE code='outgoing'))
ORDER BY so.date_order;
SELECT 'Q2_OK n=' || count(*) FROM (
  SELECT so.id FROM sale_order so
  WHERE (so.name ILIKE 'ML %' OR so.meli_order_id IS NOT NULL)
    AND so.state = 'draft' AND so.meli_status = 'paid'
    AND ((so.date_order AT TIME ZONE 'UTC') AT TIME ZONE 'America/Mexico_City') >= (DATE '${D}' - 7)
    AND so.date_order >= TIMESTAMP '2026-09-08 00:00:00'
    AND NOT EXISTS (SELECT 1 FROM stock_picking sp2 WHERE sp2.sale_id = so.id
                    AND sp2.picking_type_id IN (SELECT id FROM stock_picking_type WHERE code='outgoing'))) sub;
SQL
gate 'Q2_OK' "$Q2F"

echo "=== (Q3) CROSS-CHECK AMAZON: pickings %amazon% outgoing deadline CDMX <= D (cubre Flex MX id33/Flex id25/Easy/FBM) ==="
run <<SQL | tee "$Q3F" || { echo 'CENSUS_V2_FAIL Q3: fallo docker/psql — ABORTA con ALERTA, nunca silencio'; exit 1; }
SELECT rp.name AS partner, so.name AS odoo, so.client_order_ref, sp.name AS picking, sp.state,
       ((COALESCE(sp.date_deadline, sp.scheduled_date) AT TIME ZONE 'UTC') AT TIME ZONE 'America/Mexico_City')::date AS deadline_cdmx
FROM stock_picking sp
JOIN sale_order so ON so.id = sp.sale_id
JOIN res_partner rp ON rp.id = so.partner_id
JOIN stock_picking_type spt ON spt.id = sp.picking_type_id
WHERE rp.name ILIKE '%amazon%' AND sp.state IN ('assigned','confirmed','waiting') AND spt.code='outgoing'
  AND ((COALESCE(sp.date_deadline, sp.scheduled_date) AT TIME ZONE 'UTC') AT TIME ZONE 'America/Mexico_City')::date <= DATE '${D}'
  AND so.name NOT IN ('S01570','S01574')
ORDER BY 6;
SELECT 'Q3_OK n=' || count(*) FROM (
  SELECT sp.id FROM stock_picking sp JOIN sale_order so ON so.id = sp.sale_id JOIN res_partner rp ON rp.id = so.partner_id
  JOIN stock_picking_type spt ON spt.id = sp.picking_type_id
  WHERE rp.name ILIKE '%amazon%' AND sp.state IN ('assigned','confirmed','waiting') AND spt.code='outgoing'
    AND ((COALESCE(sp.date_deadline, sp.scheduled_date) AT TIME ZONE 'UTC') AT TIME ZONE 'America/Mexico_City')::date <= DATE '${D}'
    AND so.name NOT IN ('S01570','S01574')) sub;
SQL
gate 'Q3_OK' "$Q3F"

echo "=== (Q2b) GUARDS: ML sale/done SIN picking (anomalia a revisar) + ALERTA ML fuera de ventana sin picking ==="
run <<SQL | tee "$Q2BF" || { echo 'CENSUS_V2_FAIL Q2b: fallo docker/psql — ABORTA con ALERTA, nunca silencio'; exit 1; }
SELECT regexp_replace(so.name, '^ML[ ]+', '') AS numero_real, rp.name AS cliente, so.state AS so_state,
       so.meli_status, so.date_order::timestamp(0) AS creada
FROM sale_order so
LEFT JOIN res_partner rp ON rp.id = so.partner_id
WHERE (so.name ILIKE 'ML %' OR so.meli_order_id IS NOT NULL)
  AND so.state IN ('sale','done')
  AND so.date_order >= TIMESTAMP '2026-09-08 00:00:00'
  AND NOT EXISTS (SELECT 1 FROM stock_picking sp2 WHERE sp2.sale_id = so.id
                  AND sp2.picking_type_id IN (SELECT id FROM stock_picking_type WHERE code='outgoing'));
SELECT 'ALERTA_ML_FUERA_VENTANA n=' || count(*) FROM (
  SELECT so.id FROM sale_order so
  WHERE (so.name ILIKE 'ML %' OR so.meli_order_id IS NOT NULL)
    AND so.state = 'draft' AND so.meli_status = 'paid'
    AND ((so.date_order AT TIME ZONE 'UTC') AT TIME ZONE 'America/Mexico_City') < (DATE '${D}' - 7)
    AND so.date_order >= TIMESTAMP '2026-09-08 00:00:00'
    AND NOT EXISTS (SELECT 1 FROM stock_picking sp2 WHERE sp2.sale_id = so.id
                    AND sp2.picking_type_id IN (SELECT id FROM stock_picking_type WHERE code='outgoing'))) sub;
SQL
gate 'ALERTA_ML_FUERA_VENTANA' "$Q2BF"

echo 'CENSUS_V2_OK 4 queries ejecutadas, sentinels verificados en bash'
