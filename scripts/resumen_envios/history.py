from __future__ import annotations

from typing import Any, Mapping

from .domain import notice_from_dict
from .store import Store


def apply_history(store: Store, raw: Mapping[str, Any]) -> None:
    complete_since = raw.get("complete_since")
    if complete_since:
        for channel, recipient in (("email", "operation"), ("telegram", "david"), ("telegram", "isabel"), ("telegram", "jorge")):
            store.watermark(channel, recipient, complete_since)
    for state, key in (("satisfied", "confirmed"), ("open", "open"), ("unknown", "ambiguous")):
        for item in raw.get(key, []):
            notice = notice_from_dict(item)
            store.import_notice(notice, state, "fixture_histórico", "fixture-anonimizado")
