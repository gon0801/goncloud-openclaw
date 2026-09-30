#!/usr/bin/env python3
"""Sync U3a from estado.md and persisted round evidence.

Each block has equal weight: closed = 100%, otherwise r/(r+1), where r
is the number of persisted verdicts. This is an estimate, rounded to the
board's integer format; only closing the block earns 100%.
"""

import argparse
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys


POINTS = {"B1": "19.0", "B2": "19.1", "B3": "19.2"}


def latest_status(state, block):
    matches = re.findall(rf"^- {block} (ABIERTO|CERRADO)\b.*$", state, re.MULTILINE)
    return matches[-1] if matches else None


def closed_rounds(root, point):
    rounds = set()
    for path in root.glob(f"VEREDICTO-{point}-r*"):
        match = re.fullmatch(rf"VEREDICTO-{re.escape(point)}-r([1-9]\d*)", path.name)
        if match and re.match(r"^VEREDICTO: (APROBADO|CAMBIOS)\b", path.read_text()):
            rounds.add(int(match.group(1)))
    return len(rounds)


def current_round(root, point, state):
    numbers = [int(n) for n in re.findall(rf"{re.escape(point)}-r([1-9]\d*)\b", state)]
    for path in root.iterdir():
        match = re.fullmatch(rf"(?:encargo|LISTO|VEREDICTO)-{re.escape(point)}-r([1-9]\d*)(?:\.md)?", path.name)
        if match:
            numbers.append(int(match.group(1)))
    return max(numbers, default=1)


def record(root, name, source):
    if not re.fullmatch(r"(?:LISTO|VEREDICTO)-19\.[012]-r[1-9]\d*", name):
        raise ValueError("Nombre esperado: LISTO o VEREDICTO-19.<0|1|2>-r<N>")
    content = source.read_text(encoding="utf-8")
    if not content.strip() or (name.startswith("VEREDICTO") and not re.match(r"^VEREDICTO: (APROBADO|CAMBIOS)\b", content)):
        raise ValueError("Evidencia vacía o primera línea de VEREDICTO inválida")
    target = root / name
    if target.exists():
        if target.read_text(encoding="utf-8") != content:
            raise ValueError("Ya existe evidencia distinta para esa ronda; se conserva")
        return
    temporary = target.with_suffix(".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(target)


def queue_item(block, old):
    return old or {
        "id": block, "prs": [], "estado": "pendiente", "ventana": None,
        "merge_commits": [], "verificado": None, "detenido_por": None,
    }


def sync(root):
    path = root / "fase19.json"
    doc = json.loads(path.read_text())
    original = deepcopy(doc)
    state = (root / "estado.md").read_text()
    old_queue = {item["id"]: item for item in doc["cola"]}
    queue = []
    changes = []

    for lane in doc["carriles"]:
        block = lane["id"]
        if block not in POINTS:
            continue
        status = latest_status(state, block)
        desired = lane["estado"]
        if status == "CERRADO":
            desired = "mergeado"
        elif status == "ABIERTO" and desired == "pendiente":
            desired = "implementando"
        if lane["estado"] != desired:
            changes.append(f"{block} {desired}")
            lane["estado"] = desired
        if status == "ABIERTO":
            lane["ronda"] = current_round(root, POINTS[block], state)
            lane["paso_loop"] = max(lane["paso_loop"], 2)
        if block == "B3" and status == "ABIERTO":
            lane["rama"] = "u3a/b3-cierre"
        if block == "B2" and status == "CERRADO":
            lane["paso_loop"] = max(lane["paso_loop"], 5)
        item = queue_item(block, old_queue.get(block))
        if desired == "mergeado":
            item["estado"] = "verificado"
            item["verificado"] = "ok"
        item["prs"] = [{"repo": lane["repo"], "pr": lane["pr"]}] if lane.get("pr") else []
        if desired == "mergeado":
            advance = 100
        elif desired not in {"pendiente", "omitido", "revertido"}:
            rounds = closed_rounds(root, POINTS[block])
            advance = min(99, round(100 * rounds / (rounds + 1)))
        else:
            advance = 0
        if item.get("avance") != advance:
            changes.append(f"{block} {advance}%")
        item["avance"] = advance
        queue.append(item)

    doc["cola"] = queue + [item for item in original["cola"] if item["id"] not in POINTS]
    next_steps = re.findall(r"^- Pr[oó]xima acci[oó]n: (.+)$", state, re.MULTILINE | re.IGNORECASE)
    if next_steps and doc["siguiente_paso"] != next_steps[-1][:160]:
        doc["siguiente_paso"] = next_steps[-1][:160]
        changes.append("siguiente paso")
    if doc == original:
        return False
    now = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    doc["lead"]["actualizado"] = now
    doc["eventos"].append({"at": now, "que": "Tablero sincronizado: " + (", ".join(changes) or "ronda y datos del bloque"), "situacion": None})
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
    tmp.replace(path)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--gateway", type=Path, default=Path.home() / ".openclaw/bin/openclaw")
    parser.add_argument("--record")
    parser.add_argument("--input", type=Path)
    args = parser.parse_args()
    if bool(args.record) != bool(args.input):
        parser.error("--record y --input se usan juntos")
    if args.record:
        record(args.root, args.record, args.input)
    sync(args.root)
    if args.publish:
        result = subprocess.run(
            [str(args.gateway), "gateway", "call", "runbook.progress.set", "--params", (args.root / "fase19.json").read_text(), "--json"],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0 or not json.loads(result.stdout).get("ok"):
            print(result.stderr or result.stdout, file=sys.stderr)
            return 1
        print(result.stdout.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
