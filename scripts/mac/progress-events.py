#!/usr/bin/env python3
"""Durable local evidence and publishing client for runbook progress events."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


RUN_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,40}\Z")
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}\Z")
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
SECRET_RE = re.compile(r"gh[pousr]_[A-Za-z0-9]|github_pat_[A-Za-z0-9_]|sk-[A-Za-z0-9_-]{8,}|AKIA[0-9A-Z]{16}")


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def check(value, pattern, name):
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise ValueError(f"{name} inválido")
    return value


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def mkdir(path):
    if path.is_symlink():
        raise ValueError(f"directorio simbólico: {path}")
    missing = []
    current = path
    while not current.exists():
        missing.append(current)
        current = current.parent
    if current.is_symlink():
        raise ValueError(f"directorio simbólico: {current}")
    for directory in reversed(missing):
        directory.mkdir(mode=0o700)
        fsync_dir(directory.parent)


def create_immutable(path, data):
    mkdir(path.parent)
    fd, temp_name = tempfile.mkstemp(dir=path.parent, prefix=".progress-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temp_name, path, follow_symlinks=False)
            fsync_dir(path.parent)
        except FileExistsError:
            if path.is_symlink() or path.read_bytes() != data:
                raise ValueError(f"ID existente con contenido distinto: {path.name}")
    finally:
        os.unlink(temp_name)


def replace_atomic(path, data):
    mkdir(path.parent)
    fd, temp_name = tempfile.mkstemp(dir=path.parent, prefix=".progress-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
        fsync_dir(path.parent)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def run_dir(args, corrida):
    check(corrida, RUN_RE, "corrida")
    return Path(args.state_dir) / "runs" / corrida


def gateway(args, method, params):
    result = subprocess.run([args.openclaw_bin, "gateway", "call", method,
                             "--params", json.dumps(params, ensure_ascii=False, separators=(",", ":")),
                             "--json"], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f"gateway no disponible para {method}")
    lines = result.stdout.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if not line.lstrip().startswith("{"):
            continue
        try:
            response, _ = json.JSONDecoder().raw_decode("".join(lines[index:]).lstrip())
        except json.JSONDecodeError:
            continue
        if isinstance(response, dict):
            return response
    raise RuntimeError("respuesta JSON inválida del gateway")


def get(args, corrida):
    response = gateway(args, "runbook.progress.get", {"corrida": corrida})
    if response.get("ok") is not True or not isinstance(response.get("revision"), int) or response["revision"] < 0 or not isinstance(response.get("doc"), dict):
        raise RuntimeError("get no devolvió documento y revisión aceptados")
    if response["doc"].get("corrida") != corrida:
        raise RuntimeError("get devolvió otra corrida")
    return response


def worker_can_rebase(event, doc):
    if event.get("source") == "native" and isinstance(event.get("generation"), int) and event["generation"] >= 0:
        return True
    lanes = doc.get("carriles")
    if not isinstance(lanes, list):
        return False
    lane = next((item for item in lanes if isinstance(item, dict) and item.get("id") == event.get("carril")), None)
    if lane is None:
        return False
    current = lane.get("worker")
    proposed = event.get("worker")
    if current is not None and current != proposed:
        return False
    last = lane.get("ultimo_evento")
    if isinstance(last, dict) and isinstance(last.get("at"), str):
        try:
            last_at = datetime.fromisoformat(last["at"].replace("Z", "+00:00"))
            event_at = datetime.fromisoformat(event["at"].replace("Z", "+00:00"))
            if last_at >= event_at:
                return False
        except (KeyError, ValueError, TypeError):
            return False
    return True


def event_id(kind, corrida, carril, intento, ronda):
    key = encoded([kind, corrida, carril, intento, ronda])
    return "evt-" + hashlib.sha256(key).hexdigest()[:32]


def record(args):
    corrida = check(args.corrida, RUN_RE, "corrida")
    carril = check(args.carril, ID_RE, "carril")
    intento = check(args.intento, ID_RE, "intento")
    sha = check(args.sha, SHA_RE, "SHA")
    if args.ronda < 1:
        raise ValueError("ronda inválida")
    kind = "round.ready" if args.action == "record-ready" else "round.verdict"
    identifier = check(args.event_id or event_id(kind, corrida, carril, intento, args.ronda), ID_RE, "ID")
    raw = Path(args.evidence_file).read_bytes()
    if len(raw) > 1_000_000:
        raise ValueError("evidencia demasiado grande")
    content = raw.decode("utf-8")
    if SECRET_RE.search(content):
        raise ValueError("evidencia contiene posible secreto")
    if args.historical and not args.source:
        raise ValueError("transcripción histórica requiere --source")
    if args.source and (len(args.source) > 80 or not ID_RE.fullmatch(args.source)):
        raise ValueError("source inválido")
    if not args.historical and kind == "round.ready" and not re.search(r"(?m)^LISTO " + re.escape(sha) + r"(?:\s|$)", content):
        raise ValueError("evidencia LISTO no corresponde al SHA")
    if not args.historical and kind == "round.verdict" and not re.search(r"(?m)^VEREDICTO(?:\s|$)", content):
        raise ValueError("falta VEREDICTO en evidencia")
    base = run_dir(args, corrida)
    evidence_path = base / "evidence" / (identifier + ".json")
    queue_path = base / "queue" / (identifier + ".json")
    sent_path = base / "sent" / (identifier + ".json")
    if (base / "rejected" / (identifier + ".json")).exists():
        raise ValueError(f"evento {identifier} ya fue rechazado; usa otro ID tras resolverlo")
    content_hash = hashlib.sha256(raw).hexdigest()
    metadata = {"id": identifier, "kind": kind, "corrida": corrida, "carril": carril,
                "intento": intento, "ronda": args.ronda, "sha": sha,
                "contentHash": content_hash, "content": content}
    if args.historical:
        metadata["historical"] = True
        metadata["source"] = args.source
    if kind == "round.verdict":
        metadata["verdict"] = args.verdict
    if evidence_path.exists():
        old = json.loads(evidence_path.read_text(encoding="utf-8"))
        if {key: old.get(key) for key in metadata} != metadata:
            raise ValueError(f"ID existente con contenido distinto: {identifier}")
        evidence_bytes = evidence_path.read_bytes()
        at = old["at"]
    else:
        metadata["at"] = at = now()
        evidence_bytes = encoded(metadata)
        create_immutable(evidence_path, evidence_bytes)
    event = {"kind": kind, "id": identifier, "corrida": corrida, "at": at,
             "carril": carril, "intento": intento, "ronda": args.ronda, "sha": sha,
             "evidence": {"ref": f"evidence/{identifier}.json", "sha": hashlib.sha256(evidence_bytes).hexdigest()}}
    if kind == "round.verdict":
        event["verdict"] = args.verdict
    if args.historical:
        event["source"] = "historical:" + args.source
    if args.expected_revision is not None:
        event["expectedRevision"] = args.expected_revision
    for path in (queue_path, sent_path):
        if path.exists():
            stored = json.loads(path.read_text(encoding="utf-8"))
            if {k: v for k, v in stored.items() if k != "expectedRevision"} != {k: v for k, v in event.items() if k != "expectedRevision"}:
                raise ValueError(f"ID existente con comando distinto: {identifier}")
            print(json.dumps({"id": identifier, "queued": path == queue_path,
                              "contentHash": content_hash,
                              "queueHash": hashlib.sha256(path.read_bytes()).hexdigest(),
                              "durable": True}))
            return
    create_immutable(queue_path, encoded(event))
    print(json.dumps({"id": identifier, "queued": True,
                      "contentHash": content_hash,
                      "queueHash": hashlib.sha256(queue_path.read_bytes()).hexdigest(),
                      "durable": True}))


def queue_event(args):
    event = json.loads(Path(args.event_json).read_text(encoding="utf-8"))
    if not isinstance(event, dict):
        raise ValueError("evento inválido")
    if event.get("kind") in ("round.ready", "round.verdict"):
        raise ValueError("use record-ready o record-verdict para registrar evidencia")
    if event.get("kind") not in ("run.opened", "round.started", "part.status", "part.added", "part.worker", "attention.changed", "run.closed"):
        raise ValueError("tipo de evento inválido")
    if SECRET_RE.search(json.dumps(event, ensure_ascii=False)):
        raise ValueError("evento contiene posible secreto")
    corrida = check(event.get("corrida"), RUN_RE, "corrida")
    identifier = check(event.get("id"), ID_RE, "ID")
    if not isinstance(event.get("at"), str) or not event["at"]:
        raise ValueError("at inválido")
    base = run_dir(args, corrida)
    if (base / "rejected" / (identifier + ".json")).exists():
        raise ValueError(f"evento {identifier} ya fue rechazado; usa otro ID tras resolverlo")
    queued = base / "queue" / (identifier + ".json")
    if recover_superseded_import(base, queued, event):
        print(json.dumps({"id": identifier, "queued": False, "superseded": True}))
        return
    for directory in ("queue", "sent"):
        target = base / directory / (identifier + ".json")
        if target.exists():
            create_immutable(target, encoded(event))
            print(json.dumps({"id": identifier, "queued": directory == "queue"}))
            return
    create_immutable(base / "queue" / (identifier + ".json"), encoded(event))
    print(json.dumps({"id": identifier, "queued": True}))


def recover_superseded_import(base: Path, path: Path, event: dict) -> bool:
    archive = base / "superseded" / path.name
    decision_path = archive.with_suffix(".superseded.json")
    has_decision = decision_path.exists() or decision_path.is_symlink()
    has_archive = archive.exists() or archive.is_symlink()
    if not has_decision and not has_archive:
        return False
    identifier = event["id"]
    content = encoded(event)
    if (event.get("kind") != "run.opened" or event.get("corrida") != base.name
            or path.name != identifier + ".json"):
        raise ValueError(f"importación sustituida inválida: {identifier}: {path}")
    if has_decision:
        if decision_path.is_symlink():
            raise ValueError(f"metadatos de importación simbólicos: {decision_path}")
        try:
            decision = json.loads(decision_path.read_text(encoding="utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise ValueError(f"metadatos de importación inválidos: {decision_path}") from exc
        reason = decision.get("reason") if isinstance(decision, dict) else None
        valid_reason = reason == "corrida ya existe" or (reason == "legacy projection changed or invalid" and event.get("importLegacy") is True)
        if (not isinstance(decision, dict) or decision.get("id") != identifier
                or not valid_reason):
            raise ValueError(f"metadatos de importación inválidos: {decision_path}")
        if "eventHash" in decision:
            if (decision.get("schema") != "progress-import-superseded.v1"
                    or decision.get("corrida") != base.name
                    or decision["eventHash"] != hashlib.sha256(content).hexdigest()
                    or not isinstance(decision.get("at"), str)
                    or (decision.get("revision") is not None
                        and (type(decision["revision"]) is not int or decision["revision"] < 0))):
                raise ValueError(f"metadatos de importación no coinciden: {decision_path}")
        elif not has_archive:
            raise ValueError(f"metadatos de importación sin hash verificable: {decision_path}")
    if has_archive:
        if archive.is_symlink() or archive.read_bytes() != content:
            raise ValueError(f"importación sustituida con otro contenido: {archive}")
    else:
        try:
            queued_content = path.read_bytes()
        except FileNotFoundError:
            queued_content = None
        if queued_content is None:
            if archive.is_symlink() or not archive.exists() or archive.read_bytes() != content:
                raise ValueError(f"importación sustituida sin evento coincidente: {path}")
        else:
            if path.is_symlink() or queued_content != content:
                raise ValueError(f"importación sustituida sin evento coincidente en cola: {path}")
            create_immutable(archive, content)
    if path.exists() or path.is_symlink():
        try:
            queued_content = path.read_bytes()
        except FileNotFoundError:
            queued_content = None
        if path.is_symlink() or (queued_content is not None and queued_content != content):
            raise ValueError(f"evento en cola con otro contenido: {path}")
        if queued_content is not None:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            fsync_dir(path.parent)
    return True


def supersede_import(base, path, event, reason, revision=None):
    identifier = event["id"]
    decision_path = (base / "superseded" / path.name).with_suffix(".superseded.json")
    if not decision_path.exists():
        decision = {"schema": "progress-import-superseded.v1", "corrida": base.name,
                    "id": identifier, "eventHash": hashlib.sha256(encoded(event)).hexdigest(),
                    "reason": reason, "revision": revision, "at": now()}
        try:
            create_immutable(decision_path, encoded(decision))
        except ValueError:
            if not decision_path.exists():
                raise
    recover_superseded_import(base, path, event)


def publish(args, max_events=None, quiet=False):
    base = run_dir(args, args.corrida)
    queue = base / "queue"
    if not queue.exists():
        if not quiet:
            print(json.dumps({"published": 0}))
        return 0
    count = 0
    paths = []
    for path in queue.glob("*.json"):
        try:
            event = json.loads(path.read_text(encoding="utf-8"))
            paths.append((event.get("kind") != "run.opened", path.stat().st_mtime_ns, path.name, path))
        except FileNotFoundError:
            continue
    paths.sort()
    paths = [item[3] for item in paths]
    if max_events is not None:
        paths = paths[:max_events]
    for path in paths:
        try:
            event = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            continue
        identifier = check(event.get("id"), ID_RE, "ID")
        if path.name != identifier + ".json" or event.get("corrida") != args.corrida:
            raise ValueError("comando en cola inválido")
        if recover_superseded_import(base, path, event):
            continue
        original_event = event.copy()
        attempt_path = base / "attempts" / path.name
        if attempt_path.exists():
            attempt = json.loads(attempt_path.read_text(encoding="utf-8"))
            if attempt.get("id") != identifier or not isinstance(attempt.get("expectedRevision"), int):
                raise ValueError("intento de publicación inválido")
            event["expectedRevision"] = attempt["expectedRevision"]
        # An event already accepted by the gateway can be retried with its original ID.
        if event.get("kind") != "run.opened" and "expectedRevision" not in event:
            event["expectedRevision"] = get(args, args.corrida)["revision"]
        if "expectedRevision" in event:
            replace_atomic(attempt_path, encoded({"id": identifier, "expectedRevision": event["expectedRevision"]}))
        response = gateway(args, "runbook.progress.event", event)
        if response.get("ok") is not True:
            reason = response.get("reason") or response.get("razon")
            if event.get("kind") == "run.opened" and event.get("importLegacy") and reason == "legacy projection changed or invalid":
                supersede_import(base, path, original_event, reason, response.get("revision"))
                continue
            if event.get("kind") == "run.opened" and reason == "corrida ya existe":
                accepted = get(args, args.corrida)
                intended_doc = event.get("doc")
                intended = intended_doc.get("carriles", []) if isinstance(intended_doc, dict) else []
                accepted_lanes = accepted["doc"].get("carriles", [])
                intended_ids = {lane.get("id") for lane in intended if isinstance(lane, dict)} if isinstance(intended, list) else set()
                accepted_ids = {lane.get("id") for lane in accepted_lanes if isinstance(lane, dict)} if isinstance(accepted_lanes, list) else set()
                if (accepted["revision"] < 1 or not intended_ids
                        or len(intended_ids) != len(intended) or not intended_ids.issubset(accepted_ids)):
                    raise RuntimeError(f"evento {identifier} rechazado: corrida existente no coincide con importación")
                supersede_import(base, path, original_event, reason, accepted["revision"])
                continue
            # A stale revision is only reconsidered after reading the authoritative state.
            conflict = response.get("reason") == "revision conflict" or response.get("razon") == "conflicto"
            if conflict and event.get("kind") in ("round.started", "round.ready", "round.verdict", "part.worker"):
                latest = get(args, args.corrida)
                if event.get("kind") != "part.worker" or worker_can_rebase(event, latest["doc"]):
                    current = latest["revision"]
                    if current != event.get("expectedRevision"):
                        event["expectedRevision"] = current
                        replace_atomic(attempt_path, encoded({"id": identifier, "expectedRevision": current}))
                        response = gateway(args, "runbook.progress.event", event)
            stale_worker = event.get("kind") == "part.worker" and (response.get("reason") or response.get("razon")) == "worker anterior al estado del carril"
            if response.get("ok") is not True and (stale_worker or conflict and event.get("kind") not in ("round.started", "round.ready", "round.verdict")):
                rejected = base / "rejected" / path.name
                metadata = {"id": identifier, "reason": "stale worker" if stale_worker else "revision conflict", "revision": response.get("revision"),
                            "expectedRevision": event.get("expectedRevision"), "at": now()}
                conflict_path = rejected.with_suffix(".conflict.json")
                if conflict_path.exists():
                    previous = json.loads(conflict_path.read_text(encoding="utf-8"))
                    if {key: previous.get(key) for key in metadata if key != "at"} != {key: value for key, value in metadata.items() if key != "at"}:
                        raise ValueError(f"rechazo existente con otra revisión: {identifier}")
                else:
                    create_immutable(conflict_path, encoded(metadata))
                if rejected.exists():
                    raise ValueError(f"rechazo existente: {identifier}")
                os.replace(path, rejected)
                fsync_dir(queue)
                fsync_dir(rejected.parent)
                if attempt_path.exists():
                    attempt_path.unlink()
                    fsync_dir(attempt_path.parent)
            if response.get("ok") is not True:
                raise RuntimeError(f"evento {identifier} rechazado: {response.get('razon') or response.get('reason') or 'error'}")
        sent = base / "sent" / path.name
        create_immutable(sent, path.read_bytes())
        path.unlink()
        fsync_dir(queue)
        if attempt_path.exists():
            attempt_path.unlink()
            fsync_dir(attempt_path.parent)
        count += 1
    if not quiet:
        print(json.dumps({"published": count}))
    return count


def publish_all(args):
    runs = Path(args.state_dir) / "runs"
    if not runs.exists():
        print(json.dumps({"published": 0, "failed": []}))
        return True
    if runs.is_symlink():
        raise ValueError("directorio runs simbólico")
    published = 0
    failed = []
    candidates = [path for path in runs.iterdir()
                  if path.is_dir() and not path.is_symlink() and RUN_RE.fullmatch(path.name)
                  and (path / "queue").is_dir() and not (path / "queue").is_symlink()
                  and any((path / "queue").glob("*.json"))]
    candidates.sort(key=lambda path: path.name)
    cursor_path = Path(args.state_dir) / "publish-all.cursor"
    cursor = cursor_path.read_text(encoding="utf-8").strip() if cursor_path.exists() else ""
    after = [path for path in candidates if path.name > cursor]
    before = [path for path in candidates if path.name <= cursor]
    selected = (after + before)[:20]
    if selected:
        replace_atomic(cursor_path, (selected[-1].name + "\n").encode("utf-8"))
    for run in selected:
        scoped = argparse.Namespace(**vars(args), corrida=run.name)
        try:
            published += publish(scoped, max_events=5, quiet=True)
        except (ValueError, OSError, RuntimeError, subprocess.TimeoutExpired, UnicodeError) as exc:
            failed.append(run.name)
            print(f"progress-events: {run.name}: {exc}", file=sys.stderr)
    print(json.dumps({"published": published, "failed": failed}))
    return not failed


def sync(args):
    corrida = check(args.corrida, RUN_RE, "corrida")
    response = get(args, corrida)
    stamp = now()
    metadata = {"corrida": corrida, "revision": response["revision"], "syncedAt": stamp}
    markdown = (f"# Estado de {corrida}\n\nrevisión: {response['revision']}\nsincronizado: {stamp}\n\n"
                f"```json\n{json.dumps(response['doc'], ensure_ascii=False, indent=2)}\n```\n")
    replace_atomic(Path(args.phase_json), encoded(response["doc"]))
    replace_atomic(Path(args.phase_json + ".revision.json"), encoded(metadata))
    replace_atomic(Path(args.estado), markdown.encode("utf-8"))
    print(json.dumps({"revision": response["revision"], "syncedAt": stamp}))


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--state-dir", default=os.environ.get("PROGRESS_EVENTS_STATE_DIR", str(Path.home() / ".local/state/runbook-progress-events")))
    p.add_argument("--openclaw-bin", default=os.environ.get("OPENCLAW_BIN", "openclaw"))
    sub = p.add_subparsers(dest="action", required=True)
    for action in ("record-ready", "record-verdict"):
        q = sub.add_parser(action)
        for name in ("corrida", "carril", "intento", "sha", "evidence-file"):
            q.add_argument("--" + name, required=True)
        q.add_argument("--ronda", type=int, required=True)
        q.add_argument("--event-id")
        q.add_argument("--expected-revision", type=int)
        q.add_argument("--historical", action="store_true")
        q.add_argument("--source")
        if action == "record-verdict":
            q.add_argument("--verdict", choices=("aprobado", "cambios"), required=True)
    q = sub.add_parser("queue-event")
    q.add_argument("--event-json", required=True)
    q = sub.add_parser("publish")
    q.add_argument("--corrida", required=True)
    sub.add_parser("publish-all")
    q = sub.add_parser("sync")
    q.add_argument("--corrida", required=True)
    q.add_argument("--estado", required=True)
    q.add_argument("--phase-json", required=True)
    return p


def main():
    args = parser().parse_args()
    try:
        if args.action in ("record-ready", "record-verdict"):
            record(args)
        elif args.action == "queue-event":
            queue_event(args)
        elif args.action == "publish":
            publish(args)
        elif args.action == "publish-all":
            return 0 if publish_all(args) else 1
        else:
            sync(args)
    except (ValueError, OSError, RuntimeError, subprocess.TimeoutExpired, UnicodeError) as exc:
        print(f"progress-events: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
