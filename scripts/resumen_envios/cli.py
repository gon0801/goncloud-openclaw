from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

from .delivery import FakeTransportHub
from .domain import SourceReport
from .history import apply_history
from .service import CutService
from .store import Store


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Vista previa aislada de resúmenes de envíos")
    result.add_argument("fixture", type=Path)
    result.add_argument("--db", required=True, type=Path)
    result.add_argument("--locks", required=True, type=Path)
    result.add_argument("--at")
    result.add_argument("--resume", action="store_true")
    return result


def main() -> int:
    args = parser().parse_args()
    if os.environ.get("RESUMEN_ENVIOS_DRYRUN") != "1":
        print("RESUMEN_ENVIOS_DRYRUN=1 es obligatorio; no hay transportes reales", file=sys.stderr)
        return 2
    fixture = json.loads(args.fixture.read_text(encoding="utf-8"))
    store = Store(args.db)
    transports = FakeTransportHub()
    apply_history(store, fixture.get("history", {}))
    service = CutService(store, transports, args.locks, set(fixture.get("holidays", [])))
    cut = fixture["cut"]
    cut_id = store.cut_id(cut["kind"], cut["local_date"])
    try:
        if args.resume:
            view = service.resume_cut(cut_id)
        else:
            reports = [SourceReport.from_dict(raw) for raw in fixture["sources"]]
            times = [args.at] if args.at else fixture.get("times", [cut["at"]])
            for scheduled_at in times:
                view = service.advance_cut(cut["kind"], cut["local_date"], scheduled_at, reports)
        print(json.dumps({"view": view, "outbox": transports.outbox}, ensure_ascii=False, indent=2))
        return 0
    finally:
        store.close()


if __name__ == "__main__":
    raise SystemExit(main())
