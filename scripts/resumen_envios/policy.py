from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import date, datetime, timedelta
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple
from zoneinfo import ZoneInfo

from .domain import OrderObservation, SourceReport, SOURCE_KEYS, order_text


REQUIRED_CHECKS = {
    "amazon_mx_easy": ("unshipped", "pending", "guides"),
    "amazon_mx_self": ("unshipped", "pending"),
    "amazon_us_self": ("unshipped", "pending"),
    "amazon_seller_flex": ("flex_all",),
    "ml_pack": ("to_pack",),
    "ml_confirm": ("to_confirm",),
}

EASY_ACTIONS = {"ship", "waiting_for_pickup", "pending_drop_off"}

EXCLUDED_STATES = {
    "cancelled",
    "canceled",
    "shipped",
    "delivered",
    "delivered_to_carrier",
    "dropped_off",
    "picked_up",
}


@dataclass(frozen=True)
class Decision:
    order: OrderObservation
    outcome: str
    reasons: Tuple[str, ...]
    evidence: Tuple[str, ...]

    def as_dict(self) -> Dict[str, object]:
        return {
            "order": self.order.as_dict(),
            "outcome": self.outcome,
            "reasons": list(self.reasons),
            "evidence": list(self.evidence),
        }


@dataclass(frozen=True)
class Assessment:
    decisions: Tuple[Decision, ...]
    source_statuses: Mapping[str, str]
    source_details: Mapping[str, Mapping[str, object]]

    @property
    def eligible(self) -> Tuple[OrderObservation, ...]:
        return tuple(decision.order for decision in self.decisions if decision.outcome == "eligible")

    @property
    def complete(self) -> bool:
        return not any(decision.outcome == "undetermined" for decision in self.decisions) and all(
            self.source_statuses.get(key) in {"complete_with_orders", "complete_empty"} for key in SOURCE_KEYS
        )

    def as_dict(self) -> Dict[str, object]:
        return {
            "decisions": [decision.as_dict() for decision in self.decisions],
            "source_statuses": dict(self.source_statuses),
            "source_details": dict(self.source_details),
            "complete": self.complete,
        }


def next_dispatch_day(value: date, holidays: Optional[Set[str]] = None) -> date:
    holidays = holidays or set()
    candidate = value + timedelta(days=1)
    while candidate.weekday() >= 5 or candidate.isoformat() in holidays:
        candidate += timedelta(days=1)
    return candidate


def platform_today(order: OrderObservation, scheduled_at: datetime) -> Optional[date]:
    if not order.deadline or not order.deadline.platform_local_date:
        return None
    try:
        zone = ZoneInfo(order.deadline.platform_timezone)
        local_today = scheduled_at.astimezone(zone).date()
        deadline_date = date.fromisoformat(order.deadline.platform_local_date)
    except (ValueError, KeyError):
        return None
    return deadline_date


def decide_order(order: OrderObservation, cut_kind: str, scheduled_at: datetime, holidays: Optional[Set[str]] = None) -> Decision:
    evidence = (order.source_key,)
    if order.state.lower() in EXCLUDED_STATES:
        return Decision(order, "excluded", ("estado_" + order.state.lower(),), evidence)
    if order.key.platform == "mercado_libre" and order.action not in {"pack", "confirm", "pack+confirm"}:
        return Decision(order, "undetermined", ("accion_ml_no_reconocida",), evidence)
    if order.modality == "easy" and order.action not in EASY_ACTIONS:
        order = replace(order, action="")
    deadline = order.deadline
    if not deadline or not deadline.platform_local_date or deadline.display == "verify_required":
        if deadline and deadline.membership_evidence:
            return Decision(order, "eligible", ("pertenencia_confirmada_plazo_por_verificar",), evidence + (deadline.membership_evidence,))
        return Decision(order, "undetermined", ("plazo_impide_confirmar_elegibilidad",), evidence)
    try:
        zone = ZoneInfo(deadline.platform_timezone)
        today = scheduled_at.astimezone(zone).date()
        dispatch_date = date.fromisoformat(deadline.platform_local_date)
    except (ValueError, KeyError):
        return Decision(order, "undetermined", ("plazo_o_zona_invalidos",), evidence)
    if cut_kind == "principal":
        target = next_dispatch_day(today, holidays)
        if dispatch_date < today:
            return Decision(order, "eligible", ("atrasado",), evidence)
        if dispatch_date == target:
            return Decision(order, "eligible", ("vence_siguiente_dia_despacho",), evidence)
        return Decision(order, "excluded", ("fuera_del_corte_principal",), evidence)
    if dispatch_date <= today:
        return Decision(order, "eligible", ("vence_hoy_o_antes",), evidence)
    return Decision(order, "excluded", ("vence_despues_del_corte",), evidence)


def content_defects(order: OrderObservation) -> Tuple[str, ...]:
    defects: List[str] = []
    if not order.lines:
        defects.append("sin_lineas")
    for line in order.lines:
        if not line.key.native_line_id:
            defects.append("linea_sin_id")
        if not line.sku:
            defects.append("linea_sin_sku_plataforma")
        if line.quantity < 1:
            defects.append("cantidad_invalida")
        if line.customization and not line.customization.text:
            defects.append("personalizacion_sin_texto")
    return tuple(defects)


def source_assessment(report: SourceReport, cut_kind: str, scheduled_at: datetime, holidays: Optional[Set[str]] = None) -> Tuple[str, Dict[str, object], Tuple[Decision, ...]]:
    checks = {check.name: check for check in report.checks}
    missing = [name for name in REQUIRED_CHECKS[report.key] if name not in checks]
    failed = [name for name, check in checks.items() if not check.ok]
    count_gaps = [
        name
        for name, check in checks.items()
        if check.expected_count is not None and check.expected_count != check.observed_count
    ]
    decisions = tuple(decide_order(order, cut_kind, scheduled_at, holidays) for order in report.orders)
    defects = {
        decision.order.key.native_id: content_defects(decision.order)
        for decision in decisions
        if decision.outcome != "excluded" and content_defects(decision.order)
    }
    undetermined = [decision.order.key.native_id for decision in decisions if decision.outcome == "undetermined"]
    details: Dict[str, object] = {
        "verified": [check.verified for check in report.checks if check.ok],
        "missing": missing + failed + count_gaps,
        "reason": report.reason or "; ".join(check.reason for check in report.checks if check.reason),
        "undetermined": undetermined,
        "content_defects": defects,
        "durable": report.durable,
    }
    if missing or failed or count_gaps or undetermined or defects or not report.durable:
        return "incomplete", details, decisions
    if any(decision.outcome == "eligible" for decision in decisions):
        return "complete_with_orders", details, decisions
    return "complete_empty", details, decisions


def merge_decisions(decisions: Sequence[Decision]) -> Decision:
    first = decisions[0]
    outcomes = {decision.outcome for decision in decisions}
    if len(outcomes) != 1:
        order = max((decision.order for decision in decisions), key=lambda item: item.first_seen_at)
        return Decision(order, "undetermined", ("conflicto_entre_vistas",), tuple(decision.order.source_key for decision in decisions))
    if first.outcome != "eligible":
        return first
    signatures = {
        (
            decision.order.state,
            decision.order.deadline.platform_local_date if decision.order.deadline else None,
        )
        for decision in decisions
    }
    if len(signatures) != 1:
        order = max((decision.order for decision in decisions), key=lambda item: item.first_seen_at)
        return Decision(order, "undetermined", ("plazo_o_estado_confictivo",), tuple(decision.order.source_key for decision in decisions))
    actions = {decision.order.action for decision in decisions}
    order = max((decision.order for decision in decisions), key=lambda item: (len(item.lines), item.first_seen_at))
    if len(actions) > 1:
        if order.key.platform == "mercado_libre":
            order = replace(order, action="pack+confirm")
        elif not actions.issubset({"ship", "waiting_for_pickup", "pending_drop_off"}):
            return Decision(order, "undetermined", ("accion_confictiva",), tuple(decision.order.source_key for decision in decisions))
        elif "ship" in actions:
            specific = next(decision.order for decision in decisions if decision.order.action != "ship")
            order = replace(order, action=specific.action)
    reasons = tuple(sorted({reason for decision in decisions for reason in decision.reasons}))
    evidence = tuple(sorted({item for decision in decisions for item in decision.evidence}))
    return Decision(order, "eligible", reasons, evidence)


def assess_sources(reports: Iterable[SourceReport], cut_kind: str, scheduled_at: datetime, holidays: Optional[Set[str]] = None) -> Assessment:
    by_source = {report.key: report for report in reports}
    statuses: Dict[str, str] = {}
    details: Dict[str, Mapping[str, object]] = {}
    all_decisions: List[Decision] = []
    for key in SOURCE_KEYS:
        if key not in by_source:
            statuses[key] = "incomplete"
            details[key] = {"verified": [], "missing": ["fuente_no_recibida"], "reason": "sin resultado"}
            continue
        status, detail, decisions = source_assessment(by_source[key], cut_kind, scheduled_at, holidays)
        statuses[key] = status
        details[key] = detail
        all_decisions.extend(decisions)
    grouped: Dict[str, List[Decision]] = {}
    for decision in all_decisions:
        grouped.setdefault(order_text(decision.order.key), []).append(decision)
    merged = [merge_decisions(group) for _, group in sorted(grouped.items())]
    for decision in merged:
        if decision.outcome != "undetermined":
            continue
        for source_key in decision.evidence:
            if source_key in statuses:
                statuses[source_key] = "incomplete"
                details[source_key] = {**details[source_key], "merge_conflict": decision.order.key.native_id}
    return Assessment(tuple(merged), statuses, details)
