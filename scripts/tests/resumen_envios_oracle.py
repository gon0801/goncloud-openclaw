#!/usr/bin/env python3
import json
import sys
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

SOURCES = {
    "amazon_mx_easy": ("unshipped", "pending", "guides"),
    "amazon_mx_self": ("unshipped", "pending"),
    "amazon_us_self": ("unshipped", "pending"),
    "amazon_seller_flex": ("flex_all",),
    "ml_pack": ("to_pack",),
    "ml_confirm": ("to_confirm",),
}
EXCLUDED = {
    "cancelled",
    "canceled",
    "shipped",
    "delivered",
    "delivered_to_carrier",
    "dropped_off",
    "picked_up",
}


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def next_business(day):
    result = day + timedelta(days=1)
    while result.weekday() >= 5:
        result += timedelta(days=1)
    return result


def classify(order, kind, at):
    if order.get("state", "pending").lower() in EXCLUDED:
        return "excluded"
    if order["platform"] == "mercado_libre" and order.get("action") not in {
        "pack",
        "confirm",
        "pack+confirm",
    }:
        return "undetermined"
    deadline = order.get("deadline")
    if (
        not deadline
        or not deadline.get("local_date")
        or deadline.get("display") == "verify_required"
    ):
        return "eligible" if deadline and deadline.get("membership_evidence") else "undetermined"
    try:
        today = at.astimezone(ZoneInfo(deadline.get("timezone", "America/Vancouver"))).date()
        shipping = date.fromisoformat(deadline["local_date"])
    except (ValueError, KeyError):
        return "undetermined"
    if kind == "principal":
        return "eligible" if shipping < today or shipping == next_business(today) else "excluded"
    return "eligible" if shipping <= today else "excluded"


def content_problem(order):
    lines = order.get("lines", [])
    if not lines:
        return True
    for line in lines:
        quantity = line.get("quantity")
        if not line.get("id") or not line.get("sku") or quantity is None or int(quantity) < 1:
            return True
        if line.get("customization") and not line["customization"].get("text"):
            return True
    return False


def evaluate(fixture):
    kind = fixture["cut"]["kind"]
    at = instant(fixture.get("times", [fixture["cut"]["at"]])[-1])
    raw_sources = {source["key"]: source for source in fixture["sources"]}
    statuses = {}
    all_decisions = []
    for source_key, required in SOURCES.items():
        source = raw_sources.get(source_key)
        if source is None:
            statuses[source_key] = "incomplete"
            continue
        checks = {check["name"]: check for check in source.get("checks", [])}
        checks_ok = all(name in checks and checks[name].get("ok") is True for name in required)
        counts_ok = all(
            check.get("expected_count", check.get("observed_count")) == check.get("observed_count")
            for check in checks.values()
        )
        decisions = [(order, classify(order, kind, at)) for order in source.get("orders", [])]
        all_decisions.extend((source_key, order, outcome) for order, outcome in decisions)
        bad_content = any(
            outcome != "excluded" and content_problem(order) for order, outcome in decisions
        )
        undetermined = any(outcome == "undetermined" for _, outcome in decisions)
        if (
            not checks_ok
            or not counts_ok
            or not source.get("durable", True)
            or bad_content
            or undetermined
        ):
            statuses[source_key] = "incomplete"
        elif any(outcome == "eligible" for _, outcome in decisions):
            statuses[source_key] = "complete_with_orders"
        else:
            statuses[source_key] = "complete_empty"
    grouped = {}
    for source_key, order, outcome in all_decisions:
        identity = (order["platform"], order.get("account"), order["id"])
        grouped.setdefault(identity, []).append((source_key, order, outcome))
    eligible = []
    undetermined = []
    conflict_sources = set()
    for identity, entries in grouped.items():
        outcomes = {outcome for _, _, outcome in entries}
        if len(outcomes) > 1:
            undetermined.append(identity[2])
            conflict_sources.update(source_key for source_key, _, _ in entries)
            continue
        if outcomes == {"eligible"}:
            signatures = {
                (order.get("state"), (order.get("deadline") or {}).get("local_date"))
                for _, order, _ in entries
            }
            if len(signatures) > 1:
                undetermined.append(identity[2])
                conflict_sources.update(source_key for source_key, _, _ in entries)
            else:
                eligible.append(identity[2])
        elif outcomes == {"undetermined"}:
            undetermined.append(identity[2])
            conflict_sources.update(source_key for source_key, _, _ in entries)
    for source_key in conflict_sources:
        statuses[source_key] = "incomplete"
    return {
        "eligible_ids": sorted(eligible),
        "undetermined_ids": sorted(undetermined),
        "source_statuses": statuses,
        "complete": not undetermined
        and all(
            status in {"complete_with_orders", "complete_empty"} for status in statuses.values()
        ),
    }


def main():
    fixture = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    print(json.dumps(evaluate(fixture), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
