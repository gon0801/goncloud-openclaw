"""Authenticated Gateway transport for the native projection queue."""

import argparse
import base64
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from collections import namedtuple
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path

from contracts import (HOST_BEAT_FILE, AuthorizedOperation, HostBeat, HostObservation, IncidentRejected, OperationKey,
                       RunDir, SessionRecord, operation_id)
import contexto
import flota
from host import (ACCEPT_DEADLINE_SECONDS, RESULT_DEADLINE_SECONDS, DeliveryDeferred, Host, PhotoFailed,
                  repo_photo, writes_source)
from modelos import (POLICY_FILE, CatalogStore, CatalogUnavailable, ContextoIncompleto, ExactModel, ModelNotListed,
                     PerfilRechazado, ProviderNotConfigured, ProviderPolicy, authorize, explicar)
from progress_bridge import transfer_host_projection, transfer_projection
from resources import BoundaryBusy
from sesion import (COVERAGE_FILE, GroupBoundaryBackend, LaunchHeader, LaunchSpec, MalformedHeader, Package, Route,
                    opencode_argv, opencode_env, plan_launch, session_directory, session_name)
from spool import atomic_json, canonical, incident_identity

CHECKOUT = Path(__file__).resolve().parents[2]
CONTEXT_DIR = Path("scripts/agent-work/contexto")

DEFINITIVE_INCIDENT_REJECTIONS = (
    "Managed task incident conflict",
    "Managed task generation mismatch",
    "Managed task producer mismatch",
    "Managed task not found",
    "Managed task host does not own this CLI assignment",
    "Managed task incident key or digest is invalid",
    "Managed task host incident is invalid",
    "Managed host incident identity is invalid",
    "invalid managed host incident params",
    "Managed task assignment is invalid",
)


def _rejection(response):
    """The Gateway's own words for a failed call: error.message from the JSON on stdout, else stderr."""
    try:
        parsed = json.loads(response.stdout)
    except json.JSONDecodeError:
        parsed = None
    error = parsed.get("error") if isinstance(parsed, dict) else None
    message = error.get("message") if isinstance(error, dict) else None
    if not isinstance(message, str) or not message.strip():
        message = response.stderr or response.stdout or f"exit {response.returncode}"
    return " ".join(message.split())[:300]


class GatewayProjectionClient:
    def __init__(self, openclaw_bin, host_id, expected_url=None):
        if not host_id or not isinstance(host_id, str):
            raise ValueError("publisher host required")
        self.openclaw_bin = str(openclaw_bin)
        self.host_id = host_id
        self.expected_url = expected_url

    def _call(self, method, params, *, nullable=False, definitive=()):
        serialized = json.dumps(params, sort_keys=True, separators=(",", ":"))
        command = [self.openclaw_bin, "gateway", "call", method,
                   "--json", "--timeout", "30000"]
        if method.startswith("managedTasks.host."):
            command.append("--device-auth")
        if self.expected_url:
            command.extend(("--expect-url", self.expected_url))
        pending = None
        try:
            if len(serialized.encode()) > 100_000:
                descriptor, pending = tempfile.mkstemp(prefix="agent-work-gateway-", suffix=".json")
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    stream.write(serialized)
                    stream.flush()
                    os.fsync(stream.fileno())
                command.extend(("--params-file", pending))
            else:
                command.extend(("--params", serialized))
            response = subprocess.run(command, capture_output=True, text=True, timeout=35)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RuntimeError("native projection Gateway unavailable") from exc
        finally:
            if pending is not None:
                os.unlink(pending)
        if response.returncode:
            if definitive:
                try:
                    parsed = json.loads(response.stdout)
                except json.JSONDecodeError:
                    parsed = None
                if (isinstance(parsed, dict) and parsed.get("ok") is False
                        and isinstance(parsed.get("error"), dict)
                        and parsed["error"].get("type") == "gateway_request_error"
                        and parsed["error"].get("message") in definitive):
                    raise IncidentRejected(parsed["error"].get("message"))
            raise RuntimeError(f"native projection Gateway rejected request {method}: {_rejection(response)}")
        try:
            parsed = json.loads(response.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError("native projection Gateway returned invalid JSON") from exc
        if parsed is None and nullable:
            return None
        if not isinstance(parsed, dict):
            raise RuntimeError("native projection Gateway returned invalid response")
        return parsed

    def list_pending(self, after_task_id=None, limit=100):
        if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
            raise ValueError("projection page limit invalid")
        params = {"publisherHostId": self.host_id, "limit": limit}
        if after_task_id is not None:
            params["afterTaskId"] = after_task_id
        response = self._call("managedTasks.projections.list", params)
        rows = response.get("projections")
        if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
            raise RuntimeError("native projection Gateway returned invalid page")
        return rows

    def ack(self, receipt):
        response = self._call("managedTasks.projections.ack",
                              {"publisherHostId": self.host_id, "receipt": receipt})
        if response != receipt:
            raise RuntimeError("native projection Gateway ACK differs from queue receipt")
        return response

    def report_host_result(self, result, artifact_bytes):
        if not isinstance(result, dict) or result.get("hostId") != self.host_id:
            raise ValueError("host report identity mismatch")
        if (not isinstance(artifact_bytes, bytes) or len(artifact_bytes) > 10 * 1024 * 1024
                or hashlib.sha256(artifact_bytes).hexdigest() != result.get("digest")):
            raise ValueError("host artifact digest or size mismatch")
        result_id = hashlib.sha256(canonical(result).encode()).hexdigest()
        return self._call("managedTasks.host.report", {
            "hostId": self.host_id, "resultId": result_id, "result": result,
            "artifactBase64": base64.b64encode(artifact_bytes).decode("ascii"),
        })

    def close_host(self, assignment, state, reason, evidence_digest):
        if not isinstance(assignment, dict) or assignment.get("hostId") != self.host_id:
            raise ValueError("host closure identity mismatch")
        fields = ("taskId", "instanceId", "producerId", "capability")
        if any(not assignment.get(field) for field in fields):
            raise ValueError("host closure assignment incomplete")
        generation = assignment["generation"]
        if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
            raise ValueError("host closure generation must be positive")
        if state not in ("CleanupPending", "AbsenceVerified", "ReleasedAdopted"):
            raise ValueError("host closure state invalid")
        if (state == "CleanupPending" and not reason) or len(reason) > 4096:
            raise ValueError("host closure reason invalid")
        if not re.fullmatch(r"[0-9a-f]{64}", evidence_digest or ""):
            raise ValueError("host closure evidence digest invalid")
        params = {"hostId": self.host_id, "instanceId": assignment["instanceId"],
                  "capability": {"taskId": assignment["taskId"], "generation": generation,
                                 "producerId": assignment["producerId"],
                                 "token": assignment["capability"]},
                  "state": state, "reason": reason, "evidenceDigest": evidence_digest}
        if assignment.get("adapterId"):
            params["adapterId"] = assignment["adapterId"]
        receipt = self._call("managedTasks.host.close", params)
        if (not isinstance(receipt, dict) or receipt.get("taskId") != assignment["taskId"]
                or receipt.get("generation") != generation or receipt.get("state") != state
                or receipt.get("evidenceDigest") != evidence_digest):
            raise RuntimeError("native host closure receipt identity mismatch")
        return receipt

    def host_cancellation(self, assignment):
        """R's cancellation id for the task this host holds, or None while it is not cancelled."""
        if not isinstance(assignment, dict) or assignment.get("hostId") != self.host_id:
            raise ValueError("host cancellation identity mismatch")
        fields = ("taskId", "instanceId", "producerId", "capability", "adapterId")
        if any(not assignment.get(field) for field in fields):
            raise ValueError("host cancellation assignment incomplete")
        generation = assignment["generation"]
        if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
            raise ValueError("host cancellation generation must be positive")
        response = self._call("managedTasks.host.cancellation", {
            "hostId": self.host_id, "adapterId": assignment["adapterId"],
            "instanceId": assignment["instanceId"],
            "capability": {"taskId": assignment["taskId"], "generation": generation,
                           "producerId": assignment["producerId"], "token": assignment["capability"]}})
        cancellation_id = response.get("cancellationId")
        if (response.get("taskId") != assignment["taskId"] or response.get("generation") != generation
                or not (cancellation_id is None or (isinstance(cancellation_id, str) and cancellation_id))):
            raise RuntimeError("native host cancellation identity mismatch")
        return cancellation_id

    def report_host_incident(self, assignment, incident):
        if not isinstance(assignment, dict) or assignment.get("hostId") != self.host_id:
            raise ValueError("host incident identity mismatch")
        fields = ("taskId", "instanceId", "producerId", "capability")
        if any(not assignment.get(field) for field in fields):
            raise ValueError("host incident assignment incomplete")
        if not assignment.get("adapterId"):
            raise ValueError("host incident adapter required")
        generation = assignment["generation"]
        if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
            raise ValueError("host incident generation must be positive")
        incident_key, incident_digest = incident_identity(generation, incident)
        params = {"hostId": self.host_id, "adapterId": assignment["adapterId"],
                  "instanceId": assignment["instanceId"],
                  "capability": {"taskId": assignment["taskId"], "generation": generation,
                                 "producerId": assignment["producerId"],
                                 "token": assignment["capability"]},
                  "incident": incident}
        receipt = self._call("managedTasks.host.incident", params,
                             definitive=DEFINITIVE_INCIDENT_REJECTIONS)
        expected = {"taskId": assignment["taskId"], "generation": generation,
                    "incidentKey": incident_key, "incidentDigest": incident_digest}
        if receipt != expected:
            raise RuntimeError("native host incident receipt identity mismatch")
        return receipt

    def admit_host(self, assignment):
        if not isinstance(assignment, dict) or assignment.get("hostId") != self.host_id:
            raise ValueError("host admission identity mismatch")
        fields = ("taskId", "generation", "instanceId", "producerId", "capability", "claimId")
        if any(not assignment.get(field) for field in fields):
            raise ValueError("host admission assignment incomplete")
        params = {"hostId": self.host_id, "instanceId": assignment["instanceId"],
                  "claimId": assignment["claimId"],
                  "capability": {"taskId": assignment["taskId"],
                                 "generation": assignment["generation"],
                                 "producerId": assignment["producerId"],
                                 "token": assignment["capability"]}}
        if assignment.get("adapterId"):
            params["adapterId"] = assignment["adapterId"]
        receipt = self._call("managedTasks.host.admit", params)
        expected = {"state": "host-admitted", "claimId": assignment["claimId"],
                    "hostId": self.host_id, "instanceId": assignment["instanceId"],
                    "generation": assignment["generation"]}
        if receipt != expected:
            raise RuntimeError("native host admission receipt identity mismatch")
        return receipt

    def claim_host(self, adapter_id, instance_id):
        if not adapter_id or not instance_id:
            raise ValueError("host claim adapter and instance required")
        return self._call("managedTasks.host.claim", {
            "hostId": self.host_id, "adapterId": adapter_id, "instanceId": instance_id,
        }, nullable=True)

    def brief_chunk(self, adapter_id, instance_id, task_id, claim_id, offset, length):
        if not isinstance(offset, int) or offset < 0 or not 1 <= length <= 4096:
            raise ValueError("host brief range invalid")
        return self._call("managedTasks.host.brief", {
            "hostId": self.host_id, "adapterId": adapter_id, "instanceId": instance_id,
            "taskId": task_id, "claimId": claim_id, "offset": offset, "length": length,
        })


def _brief_digest(claim):
    reference = claim["assignment"]["instructionRef"]
    digest = reference["digest"]
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("host brief digest invalid")
    if reference["ref"] != "artifact:" + digest[7:]:
        raise ValueError("host brief reference is not portable")
    return digest


def _download_brief(client, claim, digest):
    data = bytearray()
    size = None
    while size is None or len(data) < size:
        offset = len(data)
        chunk = client.brief_chunk(claim["adapterId"], claim["instanceId"], claim["taskId"],
                                   claim["claimId"], offset, 4096)
        if (not isinstance(chunk, dict) or chunk.get("taskId") != claim["taskId"]
                or chunk.get("claimId") != claim["claimId"] or chunk.get("digest") != digest
                or chunk.get("offset") != offset or not isinstance(chunk.get("size"), int)
                or isinstance(chunk["size"], bool) or not 1 <= chunk["size"] <= 1024 * 1024
                or (size is not None and chunk["size"] != size)):
            raise ValueError("host brief response identity mismatch")
        size = chunk["size"]
        try:
            raw = base64.b64decode(chunk["dataBase64"], validate=True)
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError("host brief chunk encoding invalid") from exc
        if not raw or len(raw) > 4096 or len(data) + len(raw) > size:
            raise ValueError("host brief chunk length invalid")
        data.extend(raw)
    if hashlib.sha256(data).hexdigest() != digest[7:]:
        raise ValueError("host brief digest mismatch")
    return bytes(data)


def _publish_brief(directory, target, data, digest):
    fd, pending = tempfile.mkstemp(prefix=".pending-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o400)
        try:
            os.link(pending, target)
        except FileExistsError:
            if hashlib.sha256(target.read_bytes()).hexdigest() != digest[7:]:
                raise ValueError("host brief cache digest mismatch")
        handle = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(handle)
        finally:
            os.close(handle)
    finally:
        os.unlink(pending)


def _cached_brief(target, digest):
    if target.is_symlink():
        raise ValueError("host brief target is a symlink")
    if not target.exists():
        return False
    data = target.read_bytes()
    if not data or len(data) > 1024 * 1024 or hashlib.sha256(data).hexdigest() != digest[7:]:
        raise ValueError("host brief cache digest mismatch")
    return True


def fetch_brief(client, claim, run):
    """The brief of a claim, in its run directory, mode 0400. It is downloaded before the task's folder is
    looked at."""
    digest = _brief_digest(claim)
    if not _cached_brief(run.brief, digest):
        _publish_brief(run.path, run.brief, _download_brief(client, claim, digest), digest)
    return run.brief


def _claim(client, adapter_id, instance_id):
    """The task R hands this instance, checked against who asked; None when R has none."""
    claim = client.claim_host(adapter_id, instance_id)
    if claim is None:
        return None
    if not isinstance(claim, dict):
        raise ValueError("host claim response invalid")
    if not isinstance(claim.get("assignment"), dict):
        raise ValueError("host claim assignment invalid")
    target = claim["assignment"].get("target")
    capability = claim.get("capability")
    if (claim.get("hostId") != client.host_id or claim.get("adapterId") != adapter_id
            or claim.get("instanceId") != instance_id
            or target != {"kind": "cli", "hostId": client.host_id, "adapterId": adapter_id}
            or not isinstance(claim.get("taskId"), str) or not claim["taskId"]
            or not isinstance(claim.get("generation"), int) or isinstance(claim["generation"], bool)
            or claim["generation"] < 1 or not isinstance(claim.get("claimId"), str)
            or not claim["claimId"] or not isinstance(capability, dict)
            or capability.get("taskId") != claim["taskId"]
            or capability.get("generation") != claim["generation"]
            or capability.get("producerId") != adapter_id
            or not isinstance(capability.get("token"), str) or not capability["token"]):
        raise ValueError("host claim identity mismatch")
    assignment = claim["assignment"]
    if not isinstance(assignment.get("inputRevision"), dict) or not assignment.get("resultContract"):
        raise ValueError("host claim contract invalid")
    return claim


RUN_ADAPTER = "opencode"
SLOT_GROUP = "agent-work-enc1"
CATALOG_RECHECK_SECONDS = 60.0


def build_clone(repository: str, sha: str, destino: Path) -> None:
    """The reviewer's disposable clone (SUA-03, 4.8). No hardlinks: no object of the clone is a file of the
    real repo. No origin: a push has nowhere to go. Idempotent: a host that died after cloning finds the
    clone detached at the very revision it asked for and with no remote, and anything else is rebuilt."""
    if destino.exists():
        head = subprocess.run(["git", "-C", str(destino), "rev-parse", "HEAD"], capture_output=True, text=True,
                              timeout=30)
        remotes = subprocess.run(["git", "-C", str(destino), "remote"], capture_output=True, text=True, timeout=30)
        clean = subprocess.run(["git", "-C", str(destino), "status", "--porcelain=v1", "--untracked-files=all",
                                "--ignored=traditional"], capture_output=True, text=True, timeout=60)
        if (head.returncode == 0 and head.stdout.strip() == sha and not remotes.stdout.strip()
                and clean.returncode == 0 and not clean.stdout.strip()):
            return
        shutil.rmtree(destino, ignore_errors=True)
    clone = subprocess.run(["git", "clone", "--no-hardlinks", "--no-checkout", repository, str(destino)],
                           capture_output=True, text=True, timeout=300)
    if clone.returncode != 0:
        raise ValueError(f"git clone failed: {clone.stderr.strip()[:300]}")
    detach = subprocess.run(["git", "-C", str(destino), "checkout", "--detach", sha], capture_output=True,
                            text=True, timeout=120)
    if detach.returncode != 0:
        shutil.rmtree(destino, ignore_errors=True)
        raise ValueError(f"git checkout --detach {sha[:12]} failed: {detach.stderr.strip()[:300]}")
    remote = subprocess.run(["git", "-C", str(destino), "remote", "remove", "origin"], capture_output=True,
                            text=True, timeout=30)
    if remote.returncode != 0:
        raise ValueError("git remote remove origin failed")


def contrastar_writes_source(record: SessionRecord, perfil: dict) -> bool:
    """Lo anotado de writesSource contrastado con el perfil que esta pasada volvió a leer del
    checkout. La sesión no queda confinada (docs/evidence/agent-work/coverage.json,
    directoryGuard.limitation), así que sessions/<op>/contexto.json está a su alcance y lo que ella
    pudo editar no decide sola: si difieren, gana el checkout — el registro se reescribe con su
    valor y el anotado queda guardado en writesSourceRecorded. True cuando reescribió."""
    try:
        grabado = json.loads(record.context.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    if not isinstance(grabado, dict) or not isinstance(grabado.get("writesSource"), bool) \
            or grabado["writesSource"] == perfil["writesSource"]:
        return False
    atomic_json(record.context, {**grabado, "writesSource": perfil["writesSource"],
                                 "writesSourceRecorded": grabado["writesSource"]})
    return True


def claim_run_once(client, *, host, manager, backend, instance_id, deps):
    """Claim one task and launch its own opencode process inside the slot's group, or refuse it with an
    incident. A slot whose group holds processes of no task has no room either: nothing is claimed that
    could not be launched. A replayed claim converges: it finishes a refusal or a launch that a dead host
    left half done, and never launches twice."""
    if not manager.can_take(instance_id):
        return None
    if not manager.held() and backend.boundary():
        return None
    claim = _claim(client, RUN_ADAPTER, instance_id)
    if claim is None:
        return None
    capability, assignment = claim["capability"], claim["assignment"]
    key = OperationKey(client.host_id, claim["taskId"], claim["generation"], instance_id)
    operation = operation_id(key)
    run = RunDir.for_operation(host.state_dir, operation)
    brief = fetch_brief(client, claim, run)
    view = manager.reserve(key, session_name(operation), "TaskCreated", claim={
        "hostId": client.host_id, "taskId": claim["taskId"], "generation": claim["generation"],
        "instanceId": instance_id, "producerId": RUN_ADAPTER, "capability": capability["token"],
        "adapterId": RUN_ADAPTER})
    authorized = AuthorizedOperation(
        key=key, producer_id=RUN_ADAPTER, capability=capability["token"], session=session_name(operation),
        workspace_ref="", brief_ref=str(brief), brief_digest=assignment["instructionRef"]["digest"][7:],
        input_revision=assignment["inputRevision"], result_contract=assignment["resultContract"],
        claim_id=claim["claimId"], adapter_id=RUN_ADAPTER, run=run)
    registered = host.spool.get(operation)
    refused = json.loads(registered["operation_json"]).get("refused") if registered else None
    if refused is not None:
        return host.refuse(key, authorized, client.admit_host, refused)
    waiting = registered is None or registered["status"] in ("registered", "deferred", "attempted")
    if not (waiting and view.state in ("Reserved", "Launching")):
        return HostObservation(registered["status"], registered["assignment_ref"])
    record = SessionRecord.for_operation(host.state_dir, operation)
    plan = deps.plan(assignment, brief.read_bytes(), run=run, record=record.path, operation=operation)
    if not isinstance(plan, LaunchSpec):
        why = explicar(plan, registrado=True)
        if registered is not None:
            raise ValueError(f"the launch of a registered operation is now refused: {why.causa}")
        return host.refuse(key, authorized, client.admit_host, {"causa": why.causa, "frase": why.frase})
    if plan.perfil is not None and plan.config is not None:
        # El paquete de la corrida, copiado ANTES de registrar la asignación: el protocolo que la
        # asignación le dice al CLI depende de si su perfil escribe fuente, y un protocolo que cambia
        # entre intentos no puede registrarse dos veces (SUA-03, 4.5). Un host que murió después de
        # copiar encuentra la copia entera y solo re-lee su digest de la copia. Y lo anotado de
        # writesSource se contrasta aquí con el perfil de esta pasada, antes de que la asignación
        # y el lanzamiento lean el registro: si difiere, el checkout gana y queda anotado.
        try:
            if not run.context.exists():
                contexto.construir(plan.package.source, plan.package.manifest, plan.perfil, run.context,
                                   adaptaciones=contexto.leer_adaptaciones())
        except contexto.ContextoIncompleto as error:
            why = explicar(ContextoIncompleto(str(error)), registrado=registered is not None)
            if registered is not None:
                raise ValueError(f"the launch of a registered operation is now refused: {why.causa}") from error
            return host.refuse(key, authorized, client.admit_host, {"causa": why.causa, "frase": why.frase})
        contrastar_writes_source(record, plan.perfil)
        if not record.context.exists():
            atomic_json(record.context, {"poteto": contexto.digest_del_paquete(run.context),
                                         "tools": "sha256:" + hashlib.sha256(canonical(plan.config).encode()).hexdigest(),
                                         "writesSource": plan.perfil["writesSource"],
                                         "specialist": plan.perfil["id"],
                                         "generation": plan.package.manifest["generation"],
                                         "profile": contexto.digest_de_perfil(plan.perfil)})

    def launch(_assignment_ref, _session):
        deps.recheck(plan)
        if not writes_source(assignment, state_dir=host.state_dir, operation=key) \
                and not record.repo_before.exists():
            # The photo of the real repo, before the run can touch it (SUA-03, 4.8). Ignored files only
            # count when the run works in a clone: a reviewer without one leaves __pycache__ and must
            # not see its good result refused. The mode travels in the photo for the after-read.
            revision = assignment["inputRevision"]
            en_clon = plan.perfil is not None and not plan.perfil["writesSource"] \
                and revision.get("kind") == "code"
            protected = revision.get("repository") if revision.get("kind") == "code" else None
            photo = None
            if protected is not None:
                try:
                    photo = repo_photo(str(protected), ignored=en_clon)
                except PhotoFailed:
                    # Un repo git admitido cuya foto falló (un HEAD por nacer incluido) no lanza:
                    # sin foto previa, el resultado del revisor se aceptaría sin comparar nada
                    # (SUA-03, bots: fallar cerrado). La entrega queda uncertain y la resuelve R.
                    raise
                except OSError:
                    photo = None
            if photo is not None:
                atomic_json(record.repo_before, {"repo": str(protected), "photo": photo, "ignored": en_clon})
        if plan.perfil is not None and not plan.perfil["writesSource"] \
                and assignment["inputRevision"].get("kind") == "code":
            build_clone(assignment["inputRevision"]["repository"], assignment["inputRevision"]["sha"], run.repo)
        argv = opencode_argv(plan, deps.opencode_bin, task_id=claim["taskId"])
        try:
            launched = manager.ensure_launched(key, lambda nonce: backend.launch(plan, nonce, argv, opencode_env(plan)))
        except BoundaryBusy as busy:
            atomic_json(record.blocked, {"boundary": list(busy.processes)})
            raise DeliveryDeferred(str(busy)) from busy
        if launched.state != "Running":
            raise RuntimeError(f"the launch did not attach: {launched.state} {launched.reason}".rstrip())

    observation = host.apply(key, replace(authorized, workspace_ref=str(plan.workspace.root)), launch,
                             client.admit_host)
    if registered is not None and registered["status"] == "attempted":
        # The host died between recording this attempt and attaching its session.
        try:
            launch(observation.assignment_ref, authorized.session)
        except DeliveryDeferred:
            host.spool.delivery_deferred(operation)
            return HostObservation("deferred", observation.assignment_ref)
    return observation


def _commit(checkout):
    try:
        done = subprocess.run(["git", "-C", str(checkout), "rev-parse", "HEAD"], capture_output=True, text=True,
                              timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    sha = done.stdout.strip()
    return sha if done.returncode == 0 and re.fullmatch(r"[0-9a-f]{40,64}", sha) else "unknown"


class RunHost:
    """The run-per-task route of one slot. Each pass loads the provider policy once, and beats and
    authorizes with that same value, so a `git pull` of the host's checkout takes effect with no relaunch."""

    def __init__(self, client, host, manager, backend, *, instance_id, checkout, state_root, opencode_bin,
                 allowed_root, canary=False, accept_deadline_seconds=ACCEPT_DEADLINE_SECONDS,
                 result_deadline_seconds=RESULT_DEADLINE_SECONDS, clock=time.time):
        self.client, self.host, self.manager, self.backend = client, host, manager, backend
        self.instance_id = instance_id
        self.checkout = Path(checkout)
        self.state_root = Path(state_root)
        self.opencode_bin = Path(opencode_bin)
        self.allowed_root = Path(allowed_root)
        self.canary = canary
        self.accept_deadline_seconds = accept_deadline_seconds
        self.result_deadline_seconds = result_deadline_seconds
        self.clock = clock
        self.catalogs = CatalogStore(self.opencode_bin, self.state_root)
        self.started_at = clock()
        self.commit = _commit(self.checkout)
        self.policy = ProviderPolicy.load(self.checkout / POLICY_FILE)
        self._catalog = None
        self._catalog_at = 0.0
        self._opened = {}

    def catalog(self, *, fresh=False):
        """What opencode lists. Asked again before each launch plan, and once a minute for the beat."""
        if fresh or self._catalog is None or self.clock() - self._catalog_at >= CATALOG_RECHECK_SECONDS:
            self._catalog, self._catalog_at = self.catalogs.current(), self.clock()
        return self._catalog

    def _launched_model(self, operation):
        try:
            argv = json.loads(SessionRecord.locate(self.host.state_dir, operation).argv.read_text())
            return argv[argv.index("-m") + 1]
        except (OSError, ValueError, IndexError, TypeError):
            return None

    def beat(self):
        """Write host.json: what `encargo.py preparar` reads to know this host lives, with which policy and
        which opencode it decides, and whether its slot can take a task."""
        self.policy = ProviderPolicy.load(self.checkout / POLICY_FILE)
        try:
            version = self.catalog().cli_version
        except CatalogUnavailable:
            version = "unknown"
        slot, blocked, task_id, model, since = "free", (), None, None, None
        held = self.manager.held()
        if held:
            slot, task_id = "running", held[0]["task_id"]
            model = self._launched_model(held[0]["operation_id"])
            since = self.host.spool.attempted_at(held[0]["operation_id"])
        else:
            blocked = tuple(str(process) for process in self.backend.boundary())
            slot = "blocked" if blocked else "free"
        beat = HostBeat(os.getpid(), self.started_at, self.clock(), str(self.checkout), self.commit, version,
                        self.policy.digest, slot, blocked, task_id, model, since, str(self.host.state_dir),
                        self.canary)
        atomic_json(self.state_root / HOST_BEAT_FILE, beat.document())
        return beat

    def package(self, brief: bytes) -> "Package | ContextoIncompleto | PerfilRechazado | None":
        """What this checkout holds for a brief that asks for a profile (SUA-03, 4.5): the manifest whole
        and the profiles, with the source the launcher copies from. A brief without a profile carries no
        package and runs as always; one with a profile and a checkout without a package, or with a fixed
        generation that does not match, stays on the ground."""
        header = LaunchHeader.parse(brief)
        if isinstance(header, MalformedHeader) or header.profile is None:
            return None
        base = self.checkout / CONTEXT_DIR
        try:
            manifest = json.loads((base / "poteto.v1.json").read_text(encoding="utf-8"))
            contexto.comprobar_generacion(manifest, json.loads((base / "generaciones.json").read_text(encoding="utf-8")))
            profiles = json.loads((base / "perfiles.v1.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            return ContextoIncompleto(f"el paquete del checkout no se pudo leer: {error}")
        try:
            perfil = contexto.perfil(profiles, header.profile)
        except KeyError:
            return PerfilRechazado("perfil-desconocido", f"ningún perfil se llama {header.profile}")
        fuente = None
        try:
            fuente = contexto.fuente_del_paquete(manifest)
            # La primera frontera con disco (4.5): cada archivo de la fuente coincide con el manifiesto
            # antes de planear. La segunda es la copia, que construye y relee el paso de lanzamiento.
            contexto.comprobar_fuente(manifest, perfil, fuente)
        except contexto.ContextoIncompleto as error:
            return ContextoIncompleto(str(error))
        return Package(manifest, profiles, fuente)

    def plan(self, assignment, brief, *, run, record, operation):
        """The launch of one claim, or why not. An opencode that does not answer its version has no
        certified route. A provider or a model the catalog lacks is looked up once more: the operator may
        just have run `opencode auth login`."""
        try:
            coverage = json.loads((self.checkout / COVERAGE_FILE).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            coverage = {}
        route = Route.load(coverage, self.client.host_id)
        package = self.package(brief)
        if not isinstance(package, (Package, type(None))):
            return package
        try:
            catalog = self.catalog(fresh=True)
        except CatalogUnavailable:
            return route.open_for("sin contestar su versión", canary=False)

        def planned(listed):
            return plan_launch(assignment, brief, policy=self.policy, catalog=listed, route=route,
                               cli_version=listed.cli_version, allowed_root=self.allowed_root, run=run,
                               record=record, operation=operation, canary=self.canary, package=package,
                               now=datetime.fromtimestamp(self.clock(), tz=timezone.utc))

        plan = planned(catalog)
        if (isinstance(plan, (ProviderNotConfigured, ModelNotListed))
                and self.clock() - catalog.listed_at > CATALOG_RECHECK_SECONDS):
            try:
                self._catalog, self._catalog_at = self.catalogs.refresh(), self.clock()
            except CatalogUnavailable:
                return plan
            plan = planned(self._catalog)
        return plan

    def recheck(self, plan):
        """The launcher checks again what it was handed: the model that reaches `opencode -m` is the one
        authorize permits with this pass's policy and catalog, whoever built the plan."""
        if authorize(ExactModel(plan.model.model), self.policy, self.catalog()) != plan.model:
            raise ValueError(f"{plan.model.model} is not what authorize permits now; nothing was launched")

    def claim(self):
        return claim_run_once(self.client, host=self.host, manager=self.manager, backend=self.backend,
                              instance_id=self.instance_id, deps=self)

    def _session_directory(self, key):
        operation = operation_id(key)
        if operation not in self._opened:
            opened = session_directory(SessionRecord.locate(self.host.state_dir, operation).path)
            if opened is None:
                return None
            self._opened[operation] = opened
        return self._opened[operation]

    def watch(self):
        detected = self.host.detect_run_failures(
            self.client.host_id, self.manager.session_exit, now=self.clock(),
            accept_deadline_seconds=self.accept_deadline_seconds,
            result_deadline_seconds=self.result_deadline_seconds,
            session_directory=self._session_directory, stop_session=self.manager.stop_session)
        self.write_fleets()
        return detected

    def write_fleets(self):
        """The flota.v1 of each launched run whose session is proven gone: its logs are final. A run
        without a package has no document; one that cannot be read now is tried on the next pass. The
        reviewer's clone dies with its run (SUA-03, 4.8): what it left there is lost on purpose. A fleet
        that was written never changes, so the pass skips it with one stat instead of the whole spool
        row."""
        written = []
        for row in self.host.spool.closure_rows():
            if row["state"] != "AbsenceVerified":
                continue
            run = RunDir(self.host.state_dir / "runs" / row["operation_id"])
            if run.repo.exists():
                shutil.rmtree(run.repo, ignore_errors=True)
            if run.fleet.exists():
                continue
            current = self.host.spool.get(row["operation_id"])
            if current is None:
                continue
            assignment = json.loads(current["operation_json"])
            if assignment.get("adapterId") != RUN_ADAPTER or "refused" in assignment:
                continue
            try:
                path = flota.escribir(assignment, state_dir=self.host.state_dir, policy=self.policy)
            except (OSError, ValueError, KeyError, TypeError):
                continue
            if path is not None:
                written.append(path)
        return written


def hold_spool(state_dir):
    """One host per spool. The lock dies with the process that holds it, so a dead host never keeps it."""
    lock = open(Path(state_dir) / "host.lock", "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        return None
    return lock


def transfer_gateway_projections(client, *, evidence_root, progress_state_dir, progress_client, host=None):
    """Drain bounded pages; a lost response leaves the same native intent for retry."""
    processed = 0
    after_task_id = None
    for _ in range(100):
        rows = client.list_pending(after_task_id=after_task_id, limit=100)
        if not rows:
            return processed
        for row in rows:
            task_id = row.get("taskId")
            if not isinstance(task_id, str) or not task_id or (after_task_id and task_id <= after_task_id):
                raise RuntimeError("native projection Gateway page is unordered")
            operation_key = (host.operation_key_for(client.host_id, task_id, row.get("generation"))
                             if host is not None else None)
            if operation_key is None:
                transfer_projection(row, host_id=client.host_id, evidence_root=evidence_root,
                                    progress_state_dir=progress_state_dir,
                                    progress_client=progress_client, acknowledge_native=client.ack)
            else:
                transfer_host_projection(row, host=host, operation_key=operation_key,
                                         progress_state_dir=progress_state_dir,
                                         progress_client=progress_client, acknowledge_native=client.ack)
            processed += 1
            after_task_id = task_id
        if len(rows) < 100:
            return processed
    raise RuntimeError("native projection Gateway page limit exceeded")


PublishFailure = namedtuple("PublishFailure", "queue attempts retry_at")


class ProgressPublisher:
    """Sends the durable progress queue to the board with `progress-client publish --corrida <c>`.

    One call per queued corrida per pass, newest queue first, at most PER_PASS calls. A failed call
    leaves its files queued: the next pass retries it, later failures of the same queue back off to
    MAX_BACKOFF seconds, and any change to that queue makes it due again. Hosts of one machine share the
    state dir, so a pass publishes only while it holds the dir's lock; a busy lock skips the pass."""
    PER_PASS = 4
    TIMEOUT_SECONDS = 30
    BACKOFF_BASE_SECONDS = 15
    MAX_BACKOFF = 300.0

    def __init__(self, progress_client, state_dir, *, clock=time.monotonic):
        self.progress_client = progress_client
        self.state_dir = state_dir
        self.clock = clock
        self.failures = {}

    def _queues(self):
        runs = Path(self.state_dir) / "runs"
        if not runs.is_dir() or runs.is_symlink():
            return {}
        queues = {}
        for queue in runs.glob("*/queue"):
            if queue.is_symlink() or queue.parent.is_symlink() or not queue.is_dir():
                continue
            stamps = {}
            for path in queue.glob("*.json"):
                try:
                    stamps[path.name] = path.stat().st_mtime_ns
                except FileNotFoundError:
                    continue
            if stamps:
                queues[queue.parent.name] = (frozenset(stamps), max(stamps.values()))
        return queues

    def publish(self, gateway):
        """Publishes with the Gateway client's openclaw binary. Returns the events the progress client
        published and one error per failed corrida."""
        queues = self._queues()
        if not queues:
            self.failures = {}
            return 0, []
        with open(Path(self.state_dir) / ".host-publish.lock", "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 0, []
            return self._publish(gateway, queues)

    def _publish(self, gateway, queues):
        now = self.clock()
        self.failures = {corrida: failure for corrida, failure in self.failures.items() if corrida in queues}
        due = sorted((corrida for corrida, (names, _) in queues.items()
                      if corrida not in self.failures or self.failures[corrida].queue != names
                      or now >= self.failures[corrida].retry_at),
                     key=lambda corrida: (-queues[corrida][1], corrida))
        published, errors = 0, []
        for corrida in due[:self.PER_PASS]:
            command = [sys.executable, str(self.progress_client), "--state-dir", str(self.state_dir),
                       "--openclaw-bin", gateway.openclaw_bin, "publish", "--corrida", corrida]
            error = None
            try:
                completed = subprocess.run(command, capture_output=True, text=True,
                                           timeout=self.TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                error = f"progress publish timed out for corrida {corrida} after {self.TIMEOUT_SECONDS} s"
            except OSError as exc:
                error = f"progress publish unavailable for corrida {corrida}: {' '.join(str(exc).split())[:300]}"
            else:
                if completed.returncode:
                    error = f"progress publish rejected corrida {corrida}: {_rejection(completed)}"
                else:
                    try:
                        count = json.loads(completed.stdout).get("published")
                    except (json.JSONDecodeError, AttributeError):
                        count = None
                    if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                        error = f"progress publish returned no count for corrida {corrida}"
            if error is None:
                published += count
                self.failures.pop(corrida, None)
                continue
            names = queues[corrida][0]
            previous = self.failures.get(corrida)
            attempts = previous.attempts + 1 if previous and previous.queue == names else 1
            delay = 0 if attempts == 1 else min(self.MAX_BACKOFF, self.BACKOFF_BASE_SECONDS * 2 ** (attempts - 1))
            self.failures[corrida] = PublishFailure(names, attempts, now + delay)
            errors.append(error)
        return published, errors


def close_pass(client, *, host, cli_release=None, cli_cancel=None, cli_retry=None, close_host=None):
    """Report results, release acknowledged sessions, release cancelled tasks, retry pending cleanups and
    send the closures to R. Claims and delivers nothing. Returns counts, the report error and the other
    errors."""
    receipts = []
    report_error = None
    try:
        receipts = host.flush(client.host_id, client.report_host_result)
    except (OSError, RuntimeError, ValueError) as exc:
        report_error = exc
    counts, errors = {}, []
    for name, step in (("released", cli_release), ("cancelled", cli_cancel), ("recovered", cli_retry)):
        if step is None:
            continue
        try:
            counts[name], step_errors = step()
        except (OSError, RuntimeError, ValueError) as exc:
            counts[name], step_errors = 0, [str(exc)]
        errors += step_errors
    try:
        counts["closed"], closure_errors = host.flush_closures(client.host_id, close_host or client.close_host)
    except (OSError, RuntimeError, ValueError) as exc:
        counts["closed"], closure_errors = 0, [str(exc)]
    return {"reported": len(receipts), **counts}, report_error, errors + closure_errors


def spool_resources(db):
    rows = db.execute("SELECT r.operation_id,r.task_id,r.instance_id,r.state,r.reason,o.status "
                      "FROM resources r LEFT JOIN operations o ON o.operation_id=r.operation_id "
                      "ORDER BY r.operation_id").fetchall()
    return {row["operation_id"]: dict(row) for row in rows}


def read_spool_resources(state_dir):
    """Each resource as the spool holds it on disk, read-only, before Host opens and migrates it."""
    path = Path(state_dir) / "host.sqlite"
    if not path.is_file():
        return {}
    db = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        return spool_resources(db)
    except sqlite3.OperationalError as exc:
        if "no such table" not in str(exc):
            raise OSError(str(exc)) from exc
        return {}
    finally:
        db.close()


def close_only(client, *, host, manager, before):
    """One closing pass over a spool no host runs any more, for the instances its own rows name. before is
    read_spool_resources from before the spool was opened. Returns the report (each resource before and after,
    and the closure receipts R sent back) and whether the run failed: a session still held, or a closure
    that did not reach R, fails it with its own error."""
    receipts = []

    def close_host(*args):
        receipt = client.close_host(*args)
        receipts.append(receipt)
        return receipt

    counts, report_error, errors = close_pass(
        client, host=host, cli_release=manager.release_acknowledged,
        cli_cancel=lambda: manager.release_cancelled(client.host_cancellation),
        cli_retry=manager.retry_cleanup, close_host=close_host)
    if report_error is not None:
        errors.insert(0, f"report failed: {report_error}")
    with host.spool.connection() as db:
        after = spool_resources(db)
    resources = [{"operationId": op_id, "taskId": row["task_id"], "instanceId": row["instance_id"],
                  "operation": row["status"],
                  "before": [before.get(op_id, {}).get("state"), before.get(op_id, {}).get("reason")],
                  "after": [row["state"], row["reason"]],
                  "lastSent": host.spool.closure_last(op_id)}
                 for op_id, row in after.items()]
    report = {"counts": counts, "errors": errors, "rClosures": receipts, "resources": resources}
    return report, bool(errors)


def pump_once(client, *, host, evidence_root, progress_state_dir, progress_client,
              cli_claim=None, cli_watch=None, cli_release=None, cli_cancel=None, cli_retry=None,
              progress_publisher=None, cli_beat=None):
    """Beat, settle closures (close_pass), detect silent CLI failures, claim authorized work, drain
    projections and publish the progress queue in one code-only pass."""
    beat_errors = []
    if cli_beat is not None:
        try:
            cli_beat()
        except (OSError, RuntimeError, ValueError) as exc:
            beat_errors = [f"host beat failed: {exc}"]
    counts, report_error, errors = close_pass(client, host=host, cli_release=cli_release,
                                              cli_cancel=cli_cancel, cli_retry=cli_retry)
    errors = beat_errors + errors
    detected = 0
    watch_errors = []
    if cli_watch is not None:
        try:
            detected = len(cli_watch())
        except (OSError, RuntimeError, ValueError) as exc:
            watch_errors = [str(exc)]
    incidents_sent = 0
    incident_errors = []
    try:
        incidents_sent, incident_errors = host.flush_incidents(
            client.host_id, client.report_host_incident)
    except (OSError, RuntimeError, ValueError) as exc:
        incident_errors = [str(exc)]
    claimed = None
    claim_error = None
    if cli_claim is not None:
        try:
            claimed = cli_claim()
        except (OSError, RuntimeError, ValueError) as exc:
            claim_error = exc
    transferred = transfer_gateway_projections(
        client, evidence_root=evidence_root, progress_state_dir=progress_state_dir,
        progress_client=progress_client, host=host,
    )
    publisher = progress_publisher or ProgressPublisher(progress_client, progress_state_dir)
    published, publish_errors = publisher.publish(client)
    raised = [error for error in (report_error, claim_error) if error is not None]
    errors += watch_errors + incident_errors + publish_errors
    if len(raised) == 1 and not errors:
        raise raised[0]
    if raised or errors:
        raise RuntimeError("; ".join([*map(str, raised), *errors])) from (raised[0] if raised else None)
    result = {**counts, "transferred": transferred, "published": published, "incidents": incidents_sent}
    if cli_claim is not None:
        result["claimed"] = 1 if claimed is not None else 0
    if cli_watch is not None:
        result["detected"] = detected
    return result


def watch_pump(client, *, host, evidence_root, progress_state_dir, progress_client,
               stop_event, interval=1.0, cli_claim=None, cli_watch=None, cli_release=None, cli_cancel=None,
               cli_retry=None, cli_beat=None):
    """Poll with code; a failed pass leaves durable host and native work for retry."""
    if not 0 < interval <= 5:
        raise ValueError("poll interval must be between zero and five seconds")
    last_error = None
    publisher = ProgressPublisher(progress_client, progress_state_dir)
    while not stop_event.is_set():
        try:
            result = pump_once(
                client, host=host, evidence_root=evidence_root,
                progress_state_dir=progress_state_dir, progress_client=progress_client,
                cli_claim=cli_claim, cli_watch=cli_watch, cli_release=cli_release, cli_cancel=cli_cancel,
                cli_retry=cli_retry, progress_publisher=publisher, cli_beat=cli_beat,
            )
        except (OSError, RuntimeError, ValueError) as exc:
            error = str(exc)
            if error != last_error:
                print("agent-work pump: " + error, file=sys.stderr, flush=True)
            last_error = error
        else:
            last_error = None
            if any(result.values()):
                print(json.dumps(result, sort_keys=True), flush=True)
        stop_event.wait(interval)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Transfer native task results to progress events")
    parser.add_argument("--openclaw-bin", required=True)
    parser.add_argument("--host-id", required=True)
    parser.add_argument("--expect-url", required=True)
    parser.add_argument("--evidence-root")
    parser.add_argument("--progress-state-dir")
    parser.add_argument("--progress-client")
    parser.add_argument("--host-state-dir")
    parser.add_argument("--claim-once", action="store_true")
    parser.add_argument("--cli-instance-id")
    parser.add_argument("--cli-tmux-socket")
    parser.add_argument("--tmux-bin", default="tmux")
    parser.add_argument("--workspace-root",
                        help="claim tasks and run one opencode process per task, in a git repo under this root")
    parser.add_argument("--opencode-bin", default="/opt/homebrew/bin/opencode")
    parser.add_argument("--slot-group",
                        help=f"group whose processes are the slot's boundary (default {SLOT_GROUP}); "
                             "--close-only requires it")
    parser.add_argument("--state-root", help="where host.json and catalogo.json live (default: the parent of "
                                             "--host-state-dir)")
    parser.add_argument("--accept-deadline-seconds", type=float, default=ACCEPT_DEADLINE_SECONDS)
    parser.add_argument("--result-deadline-seconds", type=float, default=RESULT_DEADLINE_SECONDS)
    parser.add_argument("--canary", action="store_true",
                        help="also launch on a sandbox-tested-uncertified route or a new opencode version")
    parser.add_argument("--flush-results", action="store_true")
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--close-only", action="store_true",
                        help="one closing pass over --host-state-dir, for the instances its rows name; never claims")
    args = parser.parse_args(argv)
    client = GatewayProjectionClient(args.openclaw_bin, args.host_id, args.expect_url)
    if args.close_only:
        if not all((args.host_state_dir, args.cli_tmux_socket, args.slot_group)):
            parser.error("--close-only requires --host-state-dir, --cli-tmux-socket and --slot-group")
        if args.claim_once or args.watch or args.flush_results or args.cli_instance_id or args.workspace_root:
            parser.error("--close-only takes its instances from the spool and never claims")
        from resources import ResourceManager
        before = read_spool_resources(args.host_state_dir)
        host = Host(args.host_id, args.host_state_dir)
        backend = GroupBoundaryBackend(args.tmux_bin, args.cli_tmux_socket, args.slot_group)
        report, failed = close_only(
            client, host=host, manager=ResourceManager(host.spool, args.host_id, backend), before=before)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 1 if failed else 0
    cli_claim = None
    cli_watch = None
    cli_release = None
    cli_cancel = None
    cli_retry = None
    cli_beat = None
    host = None
    if args.workspace_root:
        if not all((args.host_state_dir, args.cli_instance_id, args.cli_tmux_socket)):
            parser.error("--workspace-root requires --host-state-dir, --cli-instance-id and --cli-tmux-socket")
        from resources import ResourceManager
        # The run directory goes into opencode's permission by its real path (/private/var, not /var).
        host = Host(args.host_id, Path(args.host_state_dir).resolve())
        held = hold_spool(host.state_dir)
        if held is None:
            parser.error(f"another host already runs on the spool {host.state_dir}")
        backend = GroupBoundaryBackend(args.tmux_bin, args.cli_tmux_socket, args.slot_group or SLOT_GROUP)
        manager = ResourceManager(host.spool, args.host_id, backend)
        run = RunHost(client, host, manager, backend, instance_id=args.cli_instance_id,
                      checkout=CHECKOUT, state_root=args.state_root or host.state_dir.parent,
                      opencode_bin=args.opencode_bin, allowed_root=args.workspace_root, canary=args.canary,
                      accept_deadline_seconds=args.accept_deadline_seconds,
                      result_deadline_seconds=args.result_deadline_seconds)
        cli_claim, cli_watch, cli_beat = run.claim, run.watch, run.beat
        cli_release, cli_retry = manager.release_acknowledged, manager.retry_cleanup
        cli_cancel = lambda: manager.release_cancelled(client.host_cancellation)
    elif args.claim_once or args.cli_instance_id or args.cli_tmux_socket:
        parser.error("a host claims only with --workspace-root")
    if args.claim_once:
        if args.watch or args.flush_results:
            parser.error("--claim-once excludes --watch and --flush-results")
        if cli_beat is not None:
            cli_beat()
        observation = cli_claim()
        print(json.dumps({"claimed": observation.status if observation else None}))
        return 0
    if args.watch:
        if args.flush_results or not args.host_state_dir:
            parser.error("--watch requires --host-state-dir and excludes --flush-results")
        if not all((args.evidence_root, args.progress_state_dir, args.progress_client)):
            parser.error("--watch requires evidence and progress paths")
        stop = threading.Event()
        old_term = signal.signal(signal.SIGTERM, lambda *_: stop.set())
        old_int = signal.signal(signal.SIGINT, lambda *_: stop.set())
        try:
            watch_pump(
                client, host=host or Host(args.host_id, args.host_state_dir),
                evidence_root=args.evidence_root, progress_state_dir=args.progress_state_dir,
                progress_client=args.progress_client, stop_event=stop,
                cli_claim=cli_claim, cli_watch=cli_watch, cli_release=cli_release, cli_cancel=cli_cancel,
                cli_retry=cli_retry, cli_beat=cli_beat,
            )
        finally:
            signal.signal(signal.SIGTERM, old_term)
            signal.signal(signal.SIGINT, old_int)
        return 0
    if args.flush_results:
        if not args.host_state_dir:
            parser.error("--flush-results requires --host-state-dir")
        host = Host(args.host_id, args.host_state_dir)
        reported, report_error = 0, None
        try:
            reported = len(host.flush(args.host_id, client.report_host_result))
        except (OSError, RuntimeError, ValueError) as exc:
            report_error = exc
        try:
            closed, closure_errors = host.flush_closures(args.host_id, client.close_host)
        except (OSError, RuntimeError, ValueError) as exc:
            closed, closure_errors = 0, [str(exc)]
        if report_error is not None:
            print(f"agent-work flush: {report_error}", file=sys.stderr, flush=True)
        for error in closure_errors:
            print(f"agent-work closure: {error}", file=sys.stderr, flush=True)
        print(json.dumps({"closed": closed, "reported": reported}))
        return 1 if report_error is not None or closure_errors else 0
    if not all((args.evidence_root, args.progress_state_dir, args.progress_client)):
        parser.error("projection transfer requires evidence and progress paths")
    count = transfer_gateway_projections(
        client, evidence_root=args.evidence_root, progress_state_dir=args.progress_state_dir,
        progress_client=args.progress_client,
        host=Host(args.host_id, args.host_state_dir) if args.host_state_dir else None,
    )
    print(json.dumps({"transferred": count}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
