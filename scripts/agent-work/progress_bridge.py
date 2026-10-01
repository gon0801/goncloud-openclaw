"""Transfer native result projections to the existing durable progress queue."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


SHA = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def projection_digest(pending):
    semantic = {key: value for key, value in pending.items() if key != "projectionDigest"}
    return hashlib.sha256(canonical(semantic)).hexdigest()


def event_id(kind, destination):
    key = [kind, destination["corrida"], destination["carril"],
           destination["intento"], destination["ronda"]]
    return "evt-" + hashlib.sha256(canonical(key) + b"\n").hexdigest()[:32]


def evidence_bytes(root, ref):
    if not isinstance(ref, str) or not ref or Path(ref).is_absolute():
        raise ValueError("referencia de evidencia inválida")
    relative = Path(ref)
    if any(part in (".", "..") for part in relative.parts):
        raise ValueError("referencia de evidencia fuera del host")
    root = Path(root).resolve(strict=True)
    path = root / relative
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("evidencia simbólica")
    if not path.is_file():
        raise ValueError("evidencia ausente")
    raw = path.read_bytes()
    if len(raw) > 1_000_000:
        raise ValueError("evidencia demasiado grande")
    return path, raw


def transfer_projection(pending, *, host_id, evidence_root, progress_state_dir,
                        progress_client, acknowledge_native, _verified_bytes=None):
    """ACK only after the queue confirms the same event and evidence bytes."""
    if not isinstance(pending, dict):
        raise ValueError("proyección inválida")
    destination = pending.get("destination")
    result = pending.get("result")
    if not isinstance(destination, dict) or not isinstance(result, dict):
        raise ValueError("destino o resultado inválido")
    if destination.get("publisherHostId") != host_id:
        raise ValueError("host publicador ajeno")
    if not isinstance(pending.get("generation"), int) or pending["generation"] < 1:
        raise ValueError("generación inválida")
    if not isinstance(pending.get("taskId"), str) or not pending["taskId"]:
        raise ValueError("tarea inválida")
    if not isinstance(pending.get("resultDigest"), str) or not pending["resultDigest"].startswith("sha256:") or not DIGEST.fullmatch(pending["resultDigest"][7:]):
        raise ValueError("digest de resultado inválido")
    if pending.get("projectionDigest") != projection_digest(pending):
        raise ValueError("digest de proyección distinto")
    kind = result.get("kind")
    if kind not in ("ready", "verdict"):
        raise ValueError("tipo de proyección inválido")
    if not isinstance(result.get("sha"), str) or not SHA.fullmatch(result["sha"]):
        raise ValueError("SHA de proyección inválido")
    if kind == "verdict" and result.get("verdict") not in ("aprobado", "cambios"):
        raise ValueError("veredicto inválido")
    if not isinstance(result.get("contentHash"), str) or not DIGEST.fullmatch(result["contentHash"]):
        raise ValueError("hash de evidencia inválido")
    progress_kind = "round.ready" if kind == "ready" else "round.verdict"
    if pending.get("eventId") != event_id(progress_kind, destination):
        raise ValueError("ID de evento distinto")
    if _verified_bytes is None:
        _, raw = evidence_bytes(evidence_root, result.get("evidenceRef"))
    else:
        if not isinstance(_verified_bytes, bytes) or len(_verified_bytes) > 1_000_000:
            raise ValueError("snapshot de evidencia inválido")
        raw = _verified_bytes
    if hashlib.sha256(raw).hexdigest() != result["contentHash"]:
        raise ValueError("bytes de evidencia distintos")
    command = [sys.executable, str(progress_client), "--state-dir", str(progress_state_dir),
               "record-ready" if kind == "ready" else "record-verdict"]
    for key in ("corrida", "carril", "intento"):
        command.extend(("--" + key, str(destination[key])))
    command.extend(("--ronda", str(destination["ronda"]), "--sha", result["sha"],
                    "--event-id", pending["eventId"]))
    if kind == "verdict":
        command.extend(("--verdict", result["verdict"]))
    with tempfile.TemporaryDirectory(prefix="agent-work-projection-") as private:
        snapshot = Path(private) / "evidence.txt"
        with snapshot.open("xb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        completed = subprocess.run(command + ["--evidence-file", str(snapshot)],
                                   capture_output=True, text=True, timeout=30)
    if completed.returncode:
        raise RuntimeError(f"cola de progreso rechazó la proyección: {completed.stderr.strip()}")
    try:
        durable = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("ACK de cola inválido") from exc
    if (durable.get("id") != pending["eventId"] or durable.get("contentHash") != result["contentHash"]
            or durable.get("durable") is not True or not isinstance(durable.get("queueHash"), str)
            or not DIGEST.fullmatch(durable["queueHash"])):
        raise RuntimeError("ACK de cola no coincide con la proyección")
    receipt = {"taskId": pending["taskId"], "generation": pending["generation"],
               "resultDigest": pending["resultDigest"], "eventId": pending["eventId"],
               "projectionDigest": pending["projectionDigest"],
               "contentHash": durable["contentHash"], "queueHash": durable["queueHash"]}
    acknowledged = acknowledge_native(receipt)
    if acknowledged != receipt:
        raise RuntimeError("ACK nativo no coincide con la transferencia")
    return receipt


def transfer_host_projection(pending, *, host, operation_key, progress_state_dir,
                             progress_client, acknowledge_native):
    """Project bytes retained by a managed Host, even after workspace deletion."""
    if not isinstance(pending, dict) or not isinstance(pending.get("result"), dict):
        raise ValueError("proyección inválida")
    result, raw = host.result_snapshot(host.host_id, operation_key)
    if (result.get("hostId") != host.host_id or
            result.get("taskId") != pending.get("taskId") or
            result.get("generation") != pending.get("generation") or
            result.get("digest") != pending["result"].get("contentHash")):
        raise ValueError("snapshot no corresponde a la proyección nativa")
    projected = pending["result"]
    revision = result.get("observedRevision")
    if not isinstance(revision, dict) or revision.get("kind") != "code" or revision.get("sha") != projected.get("sha"):
        raise ValueError("revisión del host distinta de la proyección")
    if projected.get("kind") == "ready":
        expected_payload = {"evidenceRef": projected.get("evidenceRef")}
    elif projected.get("kind") == "verdict":
        verdict = {"aprobado": "approved", "cambios": "changes"}.get(projected.get("verdict"))
        if verdict is None:
            raise ValueError("veredicto de proyección inválido")
        reference_field = "evidenceRef" if verdict == "approved" else "findingsRef"
        expected_payload = {"verdict": verdict, reference_field: projected.get("evidenceRef")}
    else:
        raise ValueError("tipo de proyección inválido")
    if result.get("typedPayload") != expected_payload:
        raise ValueError("veredicto o evidencia del host distintos de la proyección")
    return transfer_projection(pending, host_id=host.host_id, evidence_root=None,
                               progress_state_dir=progress_state_dir,
                               progress_client=progress_client,
                               acknowledge_native=acknowledge_native,
                               _verified_bytes=raw)
