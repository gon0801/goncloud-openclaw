from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
from typing import Any, Dict, Mapping, Optional, Tuple


SOURCE_KEYS = (
    "amazon_mx_easy",
    "amazon_mx_self",
    "amazon_us_self",
    "amazon_seller_flex",
    "ml_pack",
    "ml_confirm",
)


@dataclass(frozen=True)
class OrderKey:
    platform: str
    account: Optional[str]
    native_id: str

    def as_dict(self) -> Dict[str, Any]:
        return {"platform": self.platform, "account": self.account, "native_id": self.native_id}


@dataclass(frozen=True)
class LineKey:
    order: OrderKey
    native_line_id: str

    def as_dict(self) -> Dict[str, Any]:
        return {"order": self.order.as_dict(), "native_line_id": self.native_line_id}


@dataclass(frozen=True)
class PhotoKey:
    line: LineKey
    kind: str = "personalization_preview"

    def as_dict(self) -> Dict[str, Any]:
        return {"line": self.line.as_dict(), "kind": self.kind}


@dataclass(frozen=True)
class NoticeKey:
    order: OrderKey
    channel: str
    recipient: str
    line: Optional[LineKey] = None
    kind: str = "order"

    @classmethod
    def for_order(cls, order: OrderKey, channel: str, recipient: str) -> "NoticeKey":
        return cls(order=order, channel=channel, recipient=recipient)

    @classmethod
    def for_photo(cls, photo: PhotoKey, recipient: str) -> "NoticeKey":
        return cls(order=photo.line.order, line=photo.line, channel="telegram", recipient=recipient, kind="photo")

    def as_dict(self) -> Dict[str, Any]:
        return {
            "kind": self.kind,
            "order": self.order.as_dict(),
            "line": self.line.as_dict() if self.line else None,
            "channel": self.channel,
            "recipient": self.recipient,
        }

    def text(self) -> str:
        return json.dumps(self.as_dict(), ensure_ascii=False, sort_keys=True, separators=(",", ":"))


@dataclass(frozen=True)
class Deadline:
    raw_value: Optional[str]
    platform_timezone: str
    platform_local_date: Optional[str]
    display: str = "verified"
    membership_evidence: Optional[str] = None

    @classmethod
    def from_dict(cls, raw: Optional[Mapping[str, Any]]) -> Optional["Deadline"]:
        if raw is None:
            return None
        return cls(
            raw_value=raw.get("raw"),
            platform_timezone=str(raw.get("timezone", "America/Vancouver")),
            platform_local_date=raw.get("local_date"),
            display=str(raw.get("display", "verified")),
            membership_evidence=raw.get("membership_evidence"),
        )

    def as_dict(self) -> Dict[str, Any]:
        return {
            "raw": self.raw_value,
            "timezone": self.platform_timezone,
            "local_date": self.platform_local_date,
            "display": self.display,
            "membership_evidence": self.membership_evidence,
        }


@dataclass(frozen=True)
class Customization:
    text: str
    options: Mapping[str, Any]
    preview: Optional[str]
    publication_photo: Optional[str] = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "Customization":
        return cls(
            text=str(raw.get("text", "")),
            options=dict(raw.get("options", {})),
            preview=raw.get("preview"),
            publication_photo=raw.get("publication_photo"),
        )

    def as_dict(self) -> Dict[str, Any]:
        return {
            "text": self.text,
            "options": dict(self.options),
            "preview": self.preview,
            "publication_photo": self.publication_photo,
        }


@dataclass(frozen=True)
class LineObservation:
    key: LineKey
    sku: str
    internal_sku: Optional[str]
    quantity: Optional[int]
    customization: Optional[Customization] = None

    @classmethod
    def from_dict(cls, order: OrderKey, raw: Mapping[str, Any]) -> "LineObservation":
        customization = raw.get("customization")
        return cls(
            key=LineKey(order=order, native_line_id=str(raw["id"])),
            sku=str(raw.get("sku", "")),
            internal_sku=raw.get("internal_sku"),
            quantity=int(raw["quantity"]) if raw.get("quantity") is not None else None,
            customization=Customization.from_dict(customization) if customization else None,
        )

    def as_dict(self) -> Dict[str, Any]:
        return {
            "id": self.key.native_line_id,
            "sku": self.sku,
            "internal_sku": self.internal_sku,
            "quantity": self.quantity,
            "customization": self.customization.as_dict() if self.customization else None,
        }


@dataclass(frozen=True)
class OrderObservation:
    key: OrderKey
    visible_id: str
    client: str
    modality: str
    action: str
    state: str
    deadline: Optional[Deadline]
    first_seen_at: str
    lines: Tuple[LineObservation, ...]
    payment_pending: bool = False
    source_key: str = ""

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any], source_key: str = "") -> "OrderObservation":
        key = OrderKey(
            platform=str(raw["platform"]),
            account=raw.get("account"),
            native_id=str(raw["id"]),
        )
        return cls(
            key=key,
            visible_id=str(raw.get("visible_id", raw["id"])),
            client=str(raw.get("client", "Cliente por verificar")),
            modality=str(raw.get("modality", "")),
            action=str(raw.get("action", "")),
            state=str(raw.get("state", "pending")),
            deadline=Deadline.from_dict(raw.get("deadline")),
            first_seen_at=str(raw.get("first_seen_at", "1970-01-01T00:00:00Z")),
            lines=tuple(LineObservation.from_dict(key, line) for line in raw.get("lines", [])),
            payment_pending=bool(raw.get("payment_pending", False)),
            source_key=source_key,
        )

    def as_dict(self) -> Dict[str, Any]:
        return {
            "platform": self.key.platform,
            "account": self.key.account,
            "id": self.key.native_id,
            "visible_id": self.visible_id,
            "client": self.client,
            "modality": self.modality,
            "action": self.action,
            "state": self.state,
            "deadline": self.deadline.as_dict() if self.deadline else None,
            "first_seen_at": self.first_seen_at,
            "lines": [line.as_dict() for line in self.lines],
            "payment_pending": self.payment_pending,
        }


@dataclass(frozen=True)
class CheckResult:
    name: str
    ok: bool
    verified: str
    missing: str = ""
    reason: str = ""
    raw_ref: Optional[str] = None
    expected_count: Optional[int] = None
    observed_count: Optional[int] = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "CheckResult":
        return cls(
            name=str(raw["name"]),
            ok=bool(raw.get("ok", False)),
            verified=str(raw.get("verified", "")),
            missing=str(raw.get("missing", "")),
            reason=str(raw.get("reason", "")),
            raw_ref=raw.get("raw_ref"),
            expected_count=raw.get("expected_count"),
            observed_count=raw.get("observed_count"),
        )

    def as_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "ok": self.ok,
            "verified": self.verified,
            "missing": self.missing,
            "reason": self.reason,
            "raw_ref": self.raw_ref,
            "expected_count": self.expected_count,
            "observed_count": self.observed_count,
        }


@dataclass(frozen=True)
class SourceReport:
    key: str
    checks: Tuple[CheckResult, ...]
    orders: Tuple[OrderObservation, ...]
    received_at: str
    durable: bool = True
    reason: str = ""

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "SourceReport":
        key = str(raw["key"])
        if key not in SOURCE_KEYS:
            raise ValueError("fuente desconocida: " + key)
        return cls(
            key=key,
            checks=tuple(CheckResult.from_dict(check) for check in raw.get("checks", [])),
            orders=tuple(OrderObservation.from_dict(order, key) for order in raw.get("orders", [])),
            received_at=str(raw.get("received_at", "1970-01-01T00:00:00Z")),
            durable=bool(raw.get("durable", True)),
            reason=str(raw.get("reason", "")),
        )

    def as_dict(self) -> Dict[str, Any]:
        return {
            "key": self.key,
            "checks": [check.as_dict() for check in self.checks],
            "orders": [order.as_dict() for order in self.orders],
            "received_at": self.received_at,
            "durable": self.durable,
            "reason": self.reason,
        }


def parse_instant(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("instante sin zona: " + value)
    return parsed.astimezone(timezone.utc)


def order_text(order: OrderKey) -> str:
    return json.dumps(order.as_dict(), ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def notice_from_dict(raw: Mapping[str, Any]) -> NoticeKey:
    order_raw = raw["order"]
    order = OrderKey(order_raw["platform"], order_raw.get("account"), order_raw["native_id"])
    line = None
    if raw.get("line"):
        line = LineKey(order, raw["line"]["native_line_id"])
    return NoticeKey(order, raw["channel"], raw["recipient"], line, raw.get("kind", "order"))


def notice_from_text(value: str) -> NoticeKey:
    return notice_from_dict(json.loads(value))
