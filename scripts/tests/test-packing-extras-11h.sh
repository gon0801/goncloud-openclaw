#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.." || exit 1
python3 - "$@" <<'PY'
import glob
import re
import sys

if len(sys.argv) > 2:
    print("USO: bash scripts/tests/test-packing-extras-11h.sh [plantilla]", file=sys.stderr)
    sys.exit(2)
if len(sys.argv) == 2:
    path = sys.argv[1]
else:
    candidates = []
    for candidate in glob.glob("docs/cron-messages/packing-extras-11h.v*.txt"):
        match = re.search(r"\.v(\d+)\.txt$", candidate)
        if match:
            candidates.append((int(match.group(1)), candidate))
    if not candidates:
        print("ROJO: no hay plantilla packing-extras-11h", file=sys.stderr)
        sys.exit(1)
    path = max(candidates)[1]

text = open(path, encoding="utf-8").read()
folded = text.casefold()
required = {
    "horario preservado": ("lun-vie 11:00 CDMX",),
    "estado del propio trabajo": (
        "openclaw automations scratch 9386486d-37d6-4ae1-bf7b-12892527f2d9 --set",
    ),
    "fuentes exclusivas": (
        "Mercado Libre, Amazon Seller Central y Seller Flex",
        "PROHIBIDO usar Odoo",
        "FALLO_EXPLICITO",
    ),
    "MELI por portal autorizado": (
        "browser --browser-profile claw",
        "vendedores.mercadolibre.com.mx/ventas/omni/listado",
        "TAB_TODAY",
        "TAB_NEXT_DAYS",
        "MELI_PORTAL_OK",
    ),
    "Amazon y Flex completos": (
        "seis colas Seller Central",
        "MX Easy Ship unshipped y pending",
        "MX Self Ship unshipped y pending",
        "US Self Ship unshipped y pending",
        "Perdidos",
        "modalidad pendiente",
        "shipped/easyship",
        "Waiting for Pick Up",
        "Pending Drop off",
        "ETIQUETADOS_EASY_OK",
    ),
    "deduplicacion y cierre": (
        "todos los <D>-extras*.html",
        "bloques de pedido",
        "dedup pendiente",
        "packing_extras_state.py",
        "registrar-lote",
        "pedidos_pendientes",
        "TG_SKIP_CHATS_CON_RECIBO",
        "TG_SOLO_CHATS",
        "CORTE_COMPLETO",
        "Si falta cualquier punto, no declares completo, no declares silencio y no escribas los HTML de entrega",
    ),
    "formato v9.2": (
        "<b>AMAZON MX/US</b>",
        "<b>AMAZON EASY SHIP</b>",
        "<b>AMAZON FLEX</b>",
        "<b>MERCADO LIBRE</b>",
        "<b>Pedido:</b>",
        "<b>Cliente:</b>",
        "<b>Producto:</b>",
        "<b>Modelo:</b>",
        "<b>Color:</b>",
        "<b>SKU:</b>",
        "<b>Envio:</b>",
    ),
    "destinos preservados": (
        "ehventasmx@gmail.com",
        "/home/claw/send_sales_digest.sh",
        "Gon e Isabel",
        "/home/claw/packing/send_pers_photo.sh",
        "Gon, Isabel y Jorge",
    ),
}
forbidden = {
    "dependencia de Odoo": ("res_company", "census_v2_pipe", "meli_census_directo", "decode odoo"),
    "estado de otro trabajo": ("9e907473-a32e-46e6-b2bf-180aadf3f14c",),
    "consultas del censo viejo": ("q1_ok", "q2_ok", "q3_ok"),
}
failures = []
for behavior, needles in required.items():
    for needle in needles:
        if needle.casefold() not in folded:
            failures.append(f"FALTA {behavior}: {needle}")
for behavior, needles in forbidden.items():
    for needle in needles:
        if needle.casefold() in folded:
            failures.append(f"CONTRADICCION {behavior}: {needle}")
scoped_instructions = {
    "agents/operaciones/agent/workshop-skills/sellercentral-browser-census/SKILL.md": (
        "EXCEPCIÓN packing-extras-11h",
        "9386486d-37d6-4ae1-bf7b-12892527f2d9",
        "shipped/easyship",
        "Fuera de esta excepción",
    ),
    "agents/operaciones/agent/workshop-skills/sellercentral-browser-census/odoo-census-crosscheck.md": (
        "No aplica al job 9386486d-37d6-4ae1-bf7b-12892527f2d9",
        "packing-extras-11h.v17.txt",
    ),
}
for scoped_path, needles in scoped_instructions.items():
    scoped_text = open(scoped_path, encoding="utf-8").read().casefold()
    for needle in needles:
        if needle.casefold() not in scoped_text:
            failures.append(f"FALTA excepcion acotada en {scoped_path}: {needle}")
if failures:
    print(f"ROJO: {path}")
    print("\n".join(failures))
    sys.exit(1)
print(f"VERDE: {path}")
print(f"contratos={sum(map(len, required.values()))} prohibiciones={sum(map(len, forbidden.values()))}")
PY
