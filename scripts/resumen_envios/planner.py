from __future__ import annotations

from collections import defaultdict
from typing import DefaultDict, Dict, List, Mapping, Sequence, Tuple

from .domain import LineObservation, NoticeKey, OrderObservation, PhotoKey, order_text
from .policy import Assessment
from .render import (
    SECTION_ORDER,
    email_html,
    empty_notice,
    incomplete_notice,
    photo_content,
    section,
    split_telegram,
    summary_blocks,
)
from .store import Store


RECIPIENTS = ("operation", "david", "isabel")


def required_notices(order: OrderObservation, cut_kind: str) -> List[NoticeKey]:
    notices: List[NoticeKey] = []
    if cut_kind == "principal" or order.key.platform == "amazon":
        notices.append(NoticeKey.for_order(order.key, "email", "operation"))
    notices.extend(
        NoticeKey.for_order(order.key, "telegram", recipient) for recipient in ("david", "isabel")
    )
    return notices


def seal_plan(
    store: Store,
    cut_id: str,
    cut_kind: str,
    local_date: str,
    scheduled_at: str,
    assessment: Assessment,
) -> Dict[str, object]:
    assigned = store.assigned_obligations()
    selected: DefaultDict[Tuple[str, str], List[NoticeKey]] = defaultdict(list)
    notice_orders: Dict[str, OrderObservation] = {}
    summary_states: Dict[Tuple[str, str], str] = {}
    unknown_count = 0

    def process(notice: NoticeKey, order: OrderObservation, first_seen_at: str) -> str:
        nonlocal unknown_count
        coverage = store.coverage(notice, first_seen_at)
        if coverage == "CONFIRMED":
            return "confirmed"
        if coverage == "UNKNOWN":
            store.open_obligation(notice, cut_id, "unknown")
            store.add_issue(cut_id, "reconciliation", notice.text(), "cobertura_previa_desconocida")
            unknown_count += 1
            return "unknown"
        obligation_id = store.open_obligation(notice, cut_id, "open")
        store.link_obligation(cut_id, notice)
        if obligation_id in assigned:
            return "already_assigned"
        return "open"

    for order in assessment.eligible:
        for notice in required_notices(order, cut_kind):
            state = process(notice, order, order.first_seen_at)
            summary_states[(order_text(order.key), notice.recipient)] = state
            if state == "open":
                selected[(notice.channel, notice.recipient)].append(notice)
                notice_orders[notice.text()] = order

    photo_candidates: List[Tuple[NoticeKey, OrderObservation, LineObservation]] = []
    open_photo = False
    for decision in assessment.decisions:
        order = decision.order
        for line in order.lines:
            if not line.customization:
                continue
            notice = NoticeKey.for_photo(PhotoKey(line.key), "david")
            for recipient in ("david", "isabel", "jorge"):
                notice = NoticeKey.for_photo(PhotoKey(line.key), recipient)
                existing = store.obligation_state(notice)
                if decision.outcome != "eligible" and existing is None:
                    continue
                if (
                    recipient in {"david", "isabel"}
                    and summary_states.get((order_text(order.key), recipient)) == "unknown"
                ):
                    coverage = "UNKNOWN"
                else:
                    coverage = store.coverage(notice, order.first_seen_at)
                if coverage == "CONFIRMED":
                    continue
                if coverage == "UNKNOWN":
                    store.open_obligation(notice, cut_id, "unknown")
                    store.add_issue(
                        cut_id, "reconciliation", notice.text(), "cobertura_foto_desconocida"
                    )
                    unknown_count += 1
                    open_photo = True
                    continue
                state = "open" if line.customization.preview else "awaiting_asset"
                obligation_id = store.open_obligation(
                    notice, cut_id, state, line.customization.preview
                )
                store.link_obligation(cut_id, notice)
                open_photo = True
                if state == "open" and obligation_id not in assigned:
                    photo_candidates.append((notice, order, line))

    revision = store.save_assessment(cut_id, assessment.as_dict(), assessment.complete)
    units: List[str] = []
    overflow_count = 0
    for (channel, recipient), notices in sorted(selected.items()):
        orders = [notice_orders[notice.text()] for notice in notices]
        paired = sorted(
            zip(notices, orders),
            key=lambda pair: (
                SECTION_ORDER[section(pair[1])],
                pair[1].visible_id,
                pair[1].key.native_id,
            ),
        )
        notices = [notice for notice, _ in paired]
        orders = [order for _, order in paired]
        if channel == "email":
            units.append(
                store.create_unit(
                    cut_id,
                    revision,
                    channel,
                    recipient,
                    "summary",
                    1,
                    email_html(orders, not assessment.complete),
                    notices,
                    scheduled_at,
                )
            )
            continue
        blocks = summary_blocks(orders, not assessment.complete)
        parts, overflow = split_telegram(blocks)
        for ordinal, (content, member_indexes) in enumerate(parts, 1):
            members = [notices[index] for index in member_indexes]
            units.append(
                store.create_unit(
                    cut_id,
                    revision,
                    channel,
                    recipient,
                    "summary",
                    ordinal,
                    content,
                    members,
                    scheduled_at,
                )
            )
        for index in overflow:
            notice = notices[index]
            store.add_issue(cut_id, "capacity", notice.text(), "contenido_pendiente_por_capacidad")
            overflow_count += 1

    selected_summary_count = sum(len(notices) for notices in selected.values())
    if selected_summary_count == 0 and not assessment.eligible:
        if assessment.complete and cut_kind == "principal" and not open_photo:
            for recipient in ("david", "isabel"):
                units.append(
                    store.create_unit(
                        cut_id,
                        revision,
                        "telegram",
                        recipient,
                        "cut_notice",
                        1,
                        empty_notice(local_date),
                        [],
                        scheduled_at,
                    )
                )
        elif not assessment.complete:
            content = incomplete_notice(assessment.source_statuses)
            for recipient in ("david", "isabel"):
                units.append(
                    store.create_unit(
                        cut_id,
                        revision,
                        "telegram",
                        recipient,
                        "cut_notice",
                        1,
                        content,
                        [],
                        scheduled_at,
                    )
                )

    for ordinal, (notice, order, line) in enumerate(photo_candidates, 1):
        units.append(
            store.create_unit(
                cut_id,
                revision,
                "telegram",
                notice.recipient,
                "photo",
                ordinal,
                photo_content(order, line),
                [notice],
                scheduled_at,
            )
        )

    store.seal_assessment(cut_id, revision, assessment.complete)
    return {
        "revision": revision,
        "units": units,
        "summary_obligations": selected_summary_count,
        "photo_obligations": len(photo_candidates),
        "overflow": overflow_count,
        "unknown": unknown_count,
    }
