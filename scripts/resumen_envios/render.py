from __future__ import annotations

from html import escape
from typing import Dict, Iterable, List, Sequence, Tuple

from .domain import LineObservation, NoticeKey, OrderObservation, SOURCE_KEYS


def line_text(line: LineObservation) -> str:
    fields = [f"<b>SKU:</b> {escape(line.sku)} × {line.quantity}"]
    fields.append(f"<b>SKU interno:</b> {escape(line.internal_sku) if line.internal_sku else 'SKU interno por confirmar'}")
    if line.customization:
        customization = line.customization
        fields.append(f"<b>Personalización:</b> {escape(customization.text)}")
        fields.append(f"<b>Opciones:</b> {escape(str(dict(customization.options)))}")
        if not customization.preview:
            fields.append("<b>Personalización incompleta: falta imagen</b>")
    return "\n".join(fields)


def order_block(order: OrderObservation) -> str:
    deadline = order.deadline
    deadline_text = "plazo por verificar"
    if deadline and deadline.raw_value and deadline.display == "verified":
        deadline_text = deadline.raw_value
    action = order.action or "modalidad por verificar"
    lines = [
        f"<b>Pedido:</b> {escape(order.visible_id)}",
        f"<b>Cliente:</b> {escape(order.client)}",
        f"<b>Plataforma:</b> {escape(order.key.platform)} / {escape(order.modality)}",
        f"<b>Plazo:</b> {escape(deadline_text)}",
        f"<b>Acción:</b> {escape(action)}",
    ]
    if order.payment_pending:
        lines.append("<b>pago pendiente</b>")
    lines.extend(line_text(line) for line in order.lines)
    return "\n".join(lines)


def section(order: OrderObservation) -> str:
    if order.key.platform == "mercado_libre":
        return "MERCADO LIBRE — POR CONFIRMAR ENVÍO" if "confirm" in order.action else "MERCADO LIBRE — POR EMPACAR"
    if order.modality == "flex":
        return "AMAZON FLEX"
    if order.modality == "easy":
        return "AMAZON EASY SHIP"
    if order.key.account == "us":
        return "AMAZON SELF SHIP US"
    return "AMAZON SELF SHIP MX"


SECTION_ORDER = {
    "AMAZON SELF SHIP US": 0,
    "AMAZON SELF SHIP MX": 1,
    "AMAZON EASY SHIP": 2,
    "AMAZON FLEX": 3,
    "MERCADO LIBRE — POR EMPACAR": 4,
    "MERCADO LIBRE — POR CONFIRMAR ENVÍO": 5,
}


def summary_blocks(orders: Sequence[OrderObservation], partial: bool) -> List[str]:
    blocks: List[str] = []
    previous_section = ""
    ordered = sorted(orders, key=lambda order: (SECTION_ORDER[section(order)], order.visible_id, order.key.native_id))
    for index, order in enumerate(ordered):
        current = section(order)
        headings: List[str] = []
        if index == 0 and partial:
            headings.append("<b>Resumen parcial</b>")
        if current != previous_section:
            headings.append(f"<b>{current}</b>")
            previous_section = current
        headings.append(order_block(order))
        blocks.append("\n\n".join(headings))
    return blocks


def split_telegram(blocks: Sequence[str], limit: int = 3800, max_parts: int = 50) -> Tuple[List[Tuple[str, List[int]]], List[int]]:
    parts: List[Tuple[str, List[int]]] = []
    overflow: List[int] = []
    current = ""
    members: List[int] = []
    for index, block in enumerate(blocks):
        if len(block) > limit:
            overflow.append(index)
            continue
        candidate = block if not current else current + "\n\n" + block
        if len(candidate) > limit:
            if len(parts) == max_parts - 1:
                overflow.append(index)
                continue
            parts.append((current, members))
            current = block
            members = [index]
        else:
            current = candidate
            if index not in members:
                members.append(index)
    if current:
        if len(parts) < max_parts:
            parts.append((current, members))
        else:
            overflow.extend(members)
    return parts, overflow


def email_html(orders: Sequence[OrderObservation], partial: bool) -> str:
    blocks = summary_blocks(orders, partial)
    body = "<br><br>\n".join(block.replace("\n", "<br>\n") for block in blocks)
    return "<!DOCTYPE html><html><body>" + body + "</body></html>"


def empty_notice(local_date: str) -> str:
    return "Sin pedidos por empacar para " + local_date


def incomplete_notice(statuses: Dict[str, str]) -> str:
    missing = sorted(key for key in SOURCE_KEYS if statuses.get(key) == "incomplete")
    return "Revisión incompleta: " + ", ".join(missing)


def photo_content(order: OrderObservation, line: LineObservation) -> str:
    preview = line.customization.preview if line.customization else None
    if not preview:
        raise ValueError("foto sin vista previa")
    return "\n".join([
        "<b>PEDIDO PERSONALIZADO</b>",
        f"<b>Pedido:</b> {escape(order.visible_id)}",
        f"<b>Línea:</b> {escape(line.key.native_line_id)}",
        f"<b>Vista previa:</b> {escape(preview)}",
    ])
