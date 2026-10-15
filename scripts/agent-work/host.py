#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import hmac
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import replace
from pathlib import Path
from typing import Callable

from contracts import (AuthorizedOperation, HostObservation, IncidentRejected, OperationKey, ResultReceipt,
                       SessionRecord, operation_id)
from spool import TERMINAL_STATES, Spool, atomic_json, canonical, closure_digest, incident_identity

MAX_ARTIFACT_BYTES = 10 * 1024 * 1024
RESULT_SCHEMA = "agent-work.result.v1"
SILENT_EPISODES = {"invalid-result": "invalid-result", "transport-unavailable": "session-closed",
                   "deadline-missed": "deadline"}
ACCEPT_SCHEMA = "agent-work.accept.v1"
UNACCEPTED_EPISODE = "delivery-unaccepted"
# Episodes of the run-per-task route. Both travel as episodeId of transport-unavailable, which R accepts;
# what was refused, the exit code and the cause stay in the spool, where `encargo.py estado` reads them.
REFUSED_EPISODE = "launch-refused"
LAUNCH_FAILED_EPISODE = "launch-failed"
ACCEPT_DEADLINE_SECONDS = 300.0
"""From launch to acceptance. Measured three times: 18 s (canary 8), 13.51 s and 16.49 s (B22-fase0.md, M5)."""
RESULT_DEADLINE_SECONDS = 3600.0
"""From acceptance to result. David, P10866: "3. 1 hora"."""
ACCEPT_BOUND = ("hostId", "taskId", "generation", "instanceId", "claimId")
RESULT_BOUND = ("hostId", "taskId", "generation", "instanceId", "producerId", "capability")
MAX_ACCEPT_BYTES = 4096
VERDICTS = ("delivered", "abandoned")
REVIEW_CONTRACT = "review.v1"
REVIEWER_EPISODE = "reviewer-wrote-source"
"""The invalid-result episode of a reviewer whose run changed the task's real repo (SUA-03, 4.8)."""


class ReviewerWroteSource(ValueError):
    """The real repo of a run that may not write it changed between its launch and its result."""

    def __init__(self, changed: list[str]):
        super().__init__(f"{REVIEWER_EPISODE}: {', '.join(changed)}")
        self.changed = changed


def _json_recorded(path: Path) -> dict:
    """What the host recorded there, or an empty dict when it wrote nothing."""
    try:
        recorded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return recorded if isinstance(recorded, dict) else {}


def writes_source(assignment: dict, *, state_dir: Path | None = None,
                  operation: OperationKey | None = None) -> bool:
    """Whether a run may write its task's repo. A run with a package follows what the HOST recorded
    of its profile at launch, in sessions/<op>/contexto.json (SUA-03, 4.8). That file is not out of
    the session's reach: the run's shell is unconfined (docs/evidence/agent-work/coverage.json,
    directoryGuard.limitation), so what it reads here is only as recorded while the host last wrote
    it. What keeps the record honest is split in two. On the claim side, the launcher contrasts the
    record with the profile it re-reads from its own checkout on every claim pass, the checkout
    wins, and the recorded value stays noted (writesSourceRecorded) — a repeated claim after a dead
    host included. On the result side, Host.report reviews a run the host launched with a photo
    whatever the record says by then: the photo's existence is the launch decision. What no fix
    closes, the same directoryGuard.limitation: an unconfined session can delete
    sessions/<op>/repo_before.json and turn its result back into this rule. A run without a
    package keeps the G2 rule: a review never does and everything else may, as today."""
    if state_dir is not None and operation is not None:
        launched = _json_recorded(SessionRecord.locate(state_dir, operation_id(operation)).context)
        if isinstance(launched.get("writesSource"), bool):
            return launched["writesSource"]
    return assignment["resultContract"] != REVIEW_CONTRACT


GIT_REPO_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR")
"""Variables que mudan el repositorio que un git hijo ve: un host que las herede de su propia
carga fotografiaría otro árbol aunque el comando lleve -C. _git las quita de cada comando
(SUA-03, bots: el revisor no puede cambiar el repo del encargo sin cambiar la foto)."""


def _git(repo: str, *args: str) -> bytes:
    env = {name: value for name, value in os.environ.items() if name not in GIT_REPO_VARS}
    try:
        done = subprocess.run(["git", "-C", repo, *args], capture_output=True, timeout=60, env=env)
    except subprocess.TimeoutExpired as exc:
        raise OSError(f"git {args[0]} timed out in {repo}") from exc
    if done.returncode != 0:
        raise OSError(f"git {args[0]} failed in {repo}")
    return done.stdout


class PhotoFailed(OSError):
    """La foto de un repo git admitido no se pudo tomar (un HEAD por nacer incluido): lanzar en él
    una corrida que no puede escribirlo sin foto previa dejaría pasar cualquier cambio, así que el
    lanzamiento aborta (SUA-03, bots: fallar cerrado). No es "no es un repo": eso sigue siendo un
    OSError que el lanzador trata como hoy."""


def _hash_into(total, path: Path) -> None:
    """Into a sha256 en marcha: el destino de un symlink o los bytes de un archivo regular, leídos
    en trozos; cualquier otra cosa no suma nada (su presencia ya viaja en los bytes del status). Un
    archivo que desaparece entre el listado y la lectura no suma: ese swallow es de la carrera, no
    de un permiso que daba igual."""
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            total.update(os.readlink(path).encode("utf-8", "surrogateescape"))
        elif stat.S_ISREG(info.st_mode):
            with path.open("rb") as stream:
                while chunk := stream.read(1 << 20):
                    total.update(chunk)
    except OSError:
        pass


def _status_digest(repo: str, *args: str) -> str:
    """El sha256 de la salida entera del status, leída en streaming —los ignorados de un
    node_modules son más de cien MB y nada de eso se carga entero en memoria— más, por cada
    archivo NO rastreado que lista, sus bytes: un revisor que reescribe un archivo no rastreado
    cambia la foto sin cambiar sus rutas (SUA-03, bots). Los ignorados (marcados `!!`) siguen
    viajando solo por su ruta: su contenido cambia legítimamente (`__pycache__`) y no debe
    negar un resultado bueno."""
    total = hashlib.sha256()
    pending = b""
    env = {name: value for name, value in os.environ.items() if name not in GIT_REPO_VARS}
    with subprocess.Popen(["git", "-C", repo, *args], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, env=env) as done:
        while chunk := done.stdout.read(1 << 20):
            total.update(chunk)
            pending += chunk
            start = 0
            while (nul := pending.find(b"\0", start)) >= 0:
                record = pending[start:nul]
                start = nul + 1
                if record.startswith(b"?? "):
                    _hash_into(total, Path(repo) / record[3:].decode("utf-8", "surrogateescape"))
            pending = pending[start:]
        if done.wait() != 0:
            raise OSError(f"git {args[0]} failed in {repo}")
    return total.hexdigest()


PHOTO_FIELDS = ("head", "refs", "status", "diff", "config", "hooks", "exclude")


def _git_files(folder: Path) -> str:
    """The sha256 of each file under folder, by its relative path: what changed inside .git/hooks."""
    files = sorted(path for path in folder.rglob("*") if path.is_file()) if folder.is_dir() else []
    return hashlib.sha256(canonical([[path.relative_to(folder).as_posix(), hashlib.sha256(path.read_bytes())
                                      .hexdigest()] for path in files]).encode()).hexdigest()


def repo_photo(repo: str, *, ignored: bool = False) -> dict:
    """What a reviewer's run must leave as it was: HEAD, the refs, the status with untracked files
    (hashed with their contents, in streaming), the diff against HEAD, and inside .git its config,
    its hooks, which run code at the next git command, and its local exclude rules, where a
    planted path would hide a file from the status. Ignored files only join the status when the
    run works in a disposable clone (SUA-03, 4.8): a reviewer without one runs its tests where it
    works, and a __pycache__ in the repo must not refuse a good result, so its photo is the G2
    one, byte for byte. Which mode applies is the launcher's call, and it writes it in the
    before-photo so the after-photo reads the same one. OSError when the folder is not a git repo,
    PhotoFailed when it is one and the photo itself failed (a repo without commits included)."""
    git_dir = Path(_git(repo, "rev-parse", "--absolute-git-dir").decode().strip())
    config = git_dir / "config"
    exclude = git_dir / "info" / "exclude"
    status = ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
    if ignored:
        # --ignored=traditional lists the files inside an ignored directory; --ignored=matching would
        # collapse the directory into one entry, and a new file inside one that already existed would
        # never change the photo.
        status.append("--ignored=traditional")
    try:
        return {
            "head": _git(repo, "rev-parse", "HEAD").decode().strip(),
            "refs": hashlib.sha256(_git(repo, "for-each-ref")).hexdigest(),
            "status": _status_digest(repo, *status),
            "diff": hashlib.sha256(_git(repo, "diff", "--binary", "HEAD")).hexdigest(),
            "config": hashlib.sha256(config.read_bytes() if config.is_file() else b"").hexdigest(),
            "hooks": _git_files(git_dir / "hooks"),
            "exclude": hashlib.sha256(exclude.read_bytes() if exclude.is_file() else b"").hexdigest(),
        }
    except OSError as exc:
        raise PhotoFailed(f"la foto de {repo} falló: {exc}") from exc


def photo_changes(before: dict, after: dict) -> list[str]:
    return [field for field in PHOTO_FIELDS if before.get(field) != after.get(field)]


class DeliveryDeferred(Exception):
    """Nothing was launched, so the delivery can be retried."""


def check_deadline(deadline_seconds: float | None) -> None:
    if deadline_seconds is not None and (isinstance(deadline_seconds, bool)
                                         or not isinstance(deadline_seconds, (int, float))
                                         or deadline_seconds <= 0):
        raise ValueError("deadline must be a positive number of seconds")


def read_acceptance(assignment: dict) -> bool:
    """True only for the CLI's own agent-work.accept.v1 bound to this assignment."""
    accept_ref = Path(assignment["acceptRef"])
    if accept_ref.is_symlink() or not accept_ref.exists():
        return False
    info = accept_ref.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_ACCEPT_BYTES:
        return False
    try:
        accept = json.loads(accept_ref.read_bytes().decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    if not isinstance(accept, dict) or set(accept) != {"schema", "capability", *ACCEPT_BOUND}:
        return False
    if accept["schema"] != ACCEPT_SCHEMA or not isinstance(accept["capability"], str):
        return False
    for field in ACCEPT_BOUND:
        if type(accept[field]) is not type(assignment[field]) or accept[field] != assignment[field]:
            return False
    return hmac.compare_digest(accept["capability"].encode("utf-8", "surrogatepass"),
                               assignment["capability"].encode("utf-8", "surrogatepass"))


def delivery_line(assignment_ref: str) -> str:
    """The one line a CLI gets, as the argument it is launched with."""
    return (f"Open assignment JSON at {assignment_ref}. First write agent-work.accept.v1 atomically to "
            "acceptRef with schema, hostId, taskId, generation, instanceId, claimId and capability copied "
            "from the assignment. Then follow briefRef and write agent-work.result.v1 atomically to resultRef.")


def cli_protocol(assignment: dict, *, run: bool = False, state_dir: Path | None = None,
                 operation: OperationKey | None = None) -> dict:
    """The assignment spells out what a CLI writes, because the CLI has nothing else to go on. A review
    with a run folder leaves its artifact there, never in the repo it reviews (SUA-03, 4.8)."""
    artifact_home = ("inside the directory that holds resultRef, never inside workspaceRef"
                     if run and not writes_source(assignment, state_dir=state_dir, operation=operation)
                     else "inside workspaceRef")
    return {
        "steps": [
            "Before any other work, write the accept object as JSON to acceptRef, atomically: create the "
            "temporary file inside the directory that holds acceptRef (never in /tmp or any other "
            "directory), write the JSON there, then rename it onto acceptRef.",
            "Do the work that the file at briefRef describes, inside workspaceRef.",
            "Write, as JSON to resultRef and atomically in the same way (a temporary file inside the "
            "directory that holds resultRef, never in /tmp, renamed onto resultRef), one object: exactly "
            "the fields shown in result with their values unchanged, plus artifactRef, digest and "
            "typedPayload as three more fields at the top level of that same object, each holding what "
            "fill describes for it. Do not write a field named fill. Write no other field.",
            "Keep every helper script and scratch file inside the directory that holds acceptRef, and "
            "create, read or delete nothing in /tmp or anywhere else outside workspaceRef and that directory: "
            "the CLI denies those commands.",
        ],
        "accept": {"schema": ACCEPT_SCHEMA, "capability": assignment["capability"],
                   **{field: assignment[field] for field in ACCEPT_BOUND}},
        "result": {"schema": RESULT_SCHEMA, "kind": "produced",
                   **{field: assignment[field] for field in RESULT_BOUND},
                   "observedRevision": assignment["inputRevision"]},
        "fill": {
            "typedPayload": f"the JSON object that the {assignment['resultContract']} contract and the "
                            "brief ask for",
            "artifactRef": f"the absolute path of the artifact file, {artifact_home}",
            "digest": "the lowercase hex SHA-256 of the artifact file's bytes",
        },
    }


def under(path: str, root: str) -> Path:
    try:
        resolved = Path(path).resolve(strict=True)
    except OSError as exc:
        raise ValueError("reference does not exist") from exc
    if not resolved.is_relative_to(Path(root).resolve(strict=True)) or not resolved.is_file():
        raise ValueError("reference outside authorized workspace")
    return resolved


class Host:
    def __init__(self, host_id: str, state_dir: Path):
        if not host_id:
            raise ValueError("hostId required")
        self.host_id = host_id
        self.state_dir = Path(state_dir)
        self.spool = Spool(self.state_dir, host_id)

    def _host(self, host_id: str) -> None:
        if host_id != self.host_id:
            raise ValueError("hostId mismatch")

    def _snapshot_path(self, op_id: str, result_id: str) -> Path:
        return self.state_dir / "artifacts" / op_id / f"{result_id}.bin"

    @staticmethod
    def _snapshot_bytes(path: Path, expected_digest: str) -> bytes:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        except FileNotFoundError:
            raise
        except OSError as exc:
            raise ValueError("artifact snapshot unavailable") from exc
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_ARTIFACT_BYTES:
                raise ValueError("artifact snapshot invalid")
            raw = stream.read(MAX_ARTIFACT_BYTES + 1)
        if len(raw) > MAX_ARTIFACT_BYTES or hashlib.sha256(raw).hexdigest() != expected_digest:
            raise ValueError("artifact snapshot digest mismatch")
        return raw

    @staticmethod
    def _write_snapshot(path: Path, raw: bytes) -> None:
        root = path.parent.parent
        for directory in (root, path.parent):
            if directory.is_symlink():
                raise ValueError("artifact snapshot directory is a symlink")
            directory.mkdir(mode=0o700, exist_ok=True)
            directory.chmod(0o700)
        fd, pending = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
                os.fchmod(stream.fileno(), 0o400)
            try:
                os.link(pending, path)
            except FileExistsError:
                pass
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            os.unlink(pending)

    def _check(self, key: OperationKey, operation: AuthorizedOperation) -> None:
        self._host(key.host_id)
        if operation.key != key:
            raise ValueError("operation key mismatch")
        if key.generation < 0 or not all((key.task_id, key.instance_id, operation.producer_id,
                                           operation.capability, operation.session, operation.result_contract,
                                           operation.claim_id)) \
                or not isinstance(operation.input_revision, dict):
            raise ValueError("invalid authorized operation")

    def _assignment(self, key: OperationKey, operation: AuthorizedOperation, brief_ref: str) -> dict:
        """What every assignment carries, whatever happens to it next. Its result and acceptance live in the
        run directory when the operation has one, and under inbox/ otherwise."""
        op_id = operation_id(key)
        run = operation.run
        assignment = {
            "schema": "agent-work.assignment.v1",
            "hostId": key.host_id,
            "taskId": key.task_id,
            "generation": key.generation,
            "instanceId": key.instance_id,
            "producerId": operation.producer_id,
            "capability": operation.capability,
            "claimId": operation.claim_id,
            "session": operation.session,
            "workspaceRef": operation.workspace_ref,
            "briefRef": brief_ref,
            "briefDigest": operation.brief_digest,
            "inputRevision": operation.input_revision,
            "resultContract": operation.result_contract,
            "resultRef": str(run.result if run else self.state_dir / "inbox" / f"{op_id}.json"),
        }
        if operation.adapter_id:
            assignment["adapterId"] = operation.adapter_id
            assignment["acceptRef"] = str(run.accept if run else self.state_dir / "inbox" / f"{op_id}.accept.json")
        return assignment

    def _register(self, key: OperationKey, assignment: dict, assignment_ref: Path) -> None:
        op_id = operation_id(key)
        digest = hashlib.sha256(canonical(assignment).encode()).hexdigest()
        current = self.spool.get(op_id)
        if current and current["operation_digest"] != digest:
            raise ValueError("operation key conflicts with different content")
        self.spool.register(op_id, key.instance_id, digest, str(assignment_ref), assignment)

    @staticmethod
    def _admitted(receipt: object, key: OperationKey, claim_id: str) -> None:
        if (not isinstance(receipt, dict) or receipt.get("state") != "host-admitted"
                or receipt.get("claimId") != claim_id
                or receipt.get("hostId") != key.host_id
                or receipt.get("instanceId") != key.instance_id
                or receipt.get("generation") != key.generation):
            raise ValueError("native host admission receipt mismatch")

    def refuse(self, key: OperationKey, operation: AuthorizedOperation, admit: Callable[[dict], dict],
               why: dict) -> HostObservation:
        """A task this host will not launch. Registers it with why (its causa and frase), admits it in R,
        because R takes an incident only from a confirmed admission, and records the launch-refused incident.
        Nothing is launched: the resource stays Reserved until R cancels the task. Running it again changes
        nothing."""
        self._check(key, operation)
        if operation.run is None or not operation.adapter_id:
            raise ValueError("only a run-per-task operation can be refused")
        if set(why) != {"causa", "frase"} or not all(isinstance(text, str) and text for text in why.values()):
            raise ValueError("a refusal carries its causa and its frase")
        assignment = {**self._assignment(key, operation, operation.brief_ref), "refused": why}
        self._register(key, assignment, operation.run.assignment)
        incident = {"kind": "transport-unavailable", "episodeId": REFUSED_EPISODE,
                    "evidenceRef": f"host-operation:{operation_id(key)}"}
        if not self.spool.has_incident(key.task_id, incident_identity(key.generation, incident)[0]):
            self._admitted(admit(assignment), key, operation.claim_id)
            self.record_incident(key.host_id, key, incident)
        return HostObservation("refused", str(operation.run.assignment))

    def apply(self, key: OperationKey, operation: AuthorizedOperation,
              deliver: Callable[[str, str], None],
              admit: Callable[[dict], dict]) -> HostObservation:
        self._check(key, operation)
        # A launched session reads its brief in its run directory, the only folder outside the task's repo
        # it may touch. An operation without one keeps its brief inside the workspace.
        run = operation.run
        brief = under(operation.brief_ref, str(run.path) if run else operation.workspace_ref)
        if hashlib.sha256(brief.read_bytes()).hexdigest() != operation.brief_digest:
            raise ValueError("brief digest mismatch")
        op_id = operation_id(key)
        assignment_ref = run.assignment if run else self.state_dir / "assignments" / f"{op_id}.json"
        assignment = self._assignment(key, replace(operation, workspace_ref=str(Path(operation.workspace_ref).resolve())),
                                      str(brief))
        if operation.adapter_id:
            assignment["protocol"] = cli_protocol(assignment, run=run is not None, state_dir=self.state_dir,
                                                  operation=key)
        self._register(key, assignment, assignment_ref)
        if not run:
            (self.state_dir / "inbox").mkdir(parents=True, exist_ok=True)
        if assignment_ref.is_symlink():
            raise ValueError("assignment reference is a symlink")
        if assignment_ref.exists():
            if json.loads(assignment_ref.read_text()) != assignment:
                raise ValueError("assignment reference changed")
        else:
            atomic_json(assignment_ref, assignment)
            if run:
                assignment_ref.chmod(0o400)
        status = self.spool.get(op_id)["status"]
        if status == "registered":
            self._admitted(admit(assignment), key, operation.claim_id)
        if not self.spool.begin_delivery(op_id):
            status = self.spool.get(op_id)["status"]
            return HostObservation("uncertain" if status == "attempted" else status, str(assignment_ref))
        try:
            deliver(str(assignment_ref), operation.session)
        except DeliveryDeferred:
            self.spool.delivery_deferred(op_id)
            return HostObservation("deferred", str(assignment_ref))
        except Exception:
            return HostObservation("uncertain", str(assignment_ref))
        if "acceptRef" not in assignment:
            self.spool.delivered(op_id)
            return HostObservation("delivered", str(assignment_ref))
        try:
            accepted = self.take_acceptance(key.host_id, key)
        except OSError:
            accepted = False
        return HostObservation("delivered" if accepted else "typed", str(assignment_ref))

    def report(self, host_id: str, result: dict) -> ResultReceipt:
        self._host(host_id)
        if not isinstance(result, dict) or result.get("schema") != RESULT_SCHEMA or result.get("kind") != "produced":
            raise ValueError("result schema or kind mismatch")
        required = ("hostId", "taskId", "generation", "instanceId", "producerId", "capability",
                    "observedRevision", "typedPayload", "artifactRef", "digest")
        if any(field not in result for field in required) or not isinstance(result["typedPayload"], dict):
            raise ValueError("partial final result")
        # A CLI may copy extra fields (a model copied claimId from the assignment); R's report schema is strict.
        result = {field: result[field] for field in ("schema", "kind", *required)}
        self._host(result["hostId"])
        if not isinstance(result["generation"], int) or isinstance(result["generation"], bool):
            raise ValueError("invalid generation")
        key = OperationKey(result["hostId"], result["taskId"], result["generation"], result["instanceId"])
        op_id = operation_id(key)
        current = self.spool.get(op_id)
        if current is None:
            raise ValueError("unknown or old generation")
        assignment = json.loads(current["operation_json"])
        for field in ("hostId", "taskId", "generation", "instanceId", "producerId"):
            if result[field] != assignment[field]:
                raise ValueError(f"result {field} mismatch")
        if not hmac.compare_digest(str(result["capability"]), assignment["capability"]):
            raise ValueError("producer capability mismatch")
        if result["observedRevision"] != assignment["inputRevision"]:
            raise ValueError("observed revision mismatch")
        encoded = canonical(result).encode()
        if len(encoded) > 1024 * 1024:
            raise ValueError("result too large")
        result_id = hashlib.sha256(encoded).hexdigest()
        if current["result_id"] and current["result_id"] != result_id:
            raise ValueError("conflicting final result")
        snapshot = self._snapshot_path(op_id, result_id)
        try:
            self._snapshot_bytes(snapshot, result["digest"])
        except FileNotFoundError:
            if current["result_id"]:
                raise ValueError("recorded artifact snapshot missing")
            # A run-per-task operation keeps its result in its own run folder (RunDir).
            run_folder = Path(assignment["resultRef"]).parent
            # La decisión de lanzamiento no se re-lee de un archivo que la sesión pudo editar
            # durante su corrida: una foto previa solo se escribe cuando el host lanzó al revisor
            # sin permiso de escritura, así que su existencia ES esa decisión y el resultado se
            # compara con ella pase lo que pase con lo anotado. Sin foto previa (una carpeta que
            # no es repo git, un host anterior a SUA-03) sigue la regla del contrato.
            record = SessionRecord.locate(self.state_dir, op_id)
            reviewed = run_folder == self.state_dir / "runs" / op_id and (
                record.repo_before.exists() or not writes_source(
                    assignment, state_dir=self.state_dir, operation=key))
            if reviewed:
                self._check_repo(op_id)
            home = str(run_folder) if reviewed else assignment["workspaceRef"]
            artifact = under(result["artifactRef"], home)
            with artifact.open("rb") as stream:
                raw = stream.read(MAX_ARTIFACT_BYTES + 1)
            if len(raw) > MAX_ARTIFACT_BYTES:
                raise ValueError("artifact too large")
            if hashlib.sha256(raw).hexdigest() != result["digest"]:
                raise ValueError("artifact digest mismatch")
            self._write_snapshot(snapshot, raw)
            self._snapshot_bytes(snapshot, result["digest"])
        self.spool.record(op_id, result_id, result, self.state_dir / "results" / f"{op_id}.json")
        return ResultReceipt(result_id)

    def _check_repo(self, op_id: str) -> None:
        """The real repo of a run that may not write it is as its photo before launch said. A run launched
        without a photo (by a host from before SUA-03, or in a folder that is not a git repo) has nothing to
        compare. A change already measured (repo_after on disk) is not measured again: a refused result
        stays in awaiting_results, and re-photographing the real repo on every pass cost six git commands
        twice per pass (SUA-03, bots); the recorded verdict is raised as it was recorded."""
        record = SessionRecord.locate(self.state_dir, op_id)
        try:
            before = json.loads(record.repo_before.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return
        recorded = _json_recorded(record.repo_after).get("changed")
        if isinstance(recorded, list) and recorded and all(isinstance(field, str) for field in recorded):
            raise ReviewerWroteSource(recorded)
        after = repo_photo(before["repo"], ignored=bool(before.get("ignored")))
        changed = photo_changes(before["photo"], after)
        if changed:
            atomic_json(record.repo_after, {"repo": before["repo"], "photo": after, "changed": changed})
            raise ReviewerWroteSource(changed)

    def result_snapshot(self, host_id: str, key: OperationKey) -> tuple[dict, bytes]:
        self._host(host_id)
        self._host(key.host_id)
        row = self.spool.get(operation_id(key))
        if row is None or not row["result_id"] or not row["result_json"]:
            raise ValueError("result is not recorded for this identity")
        result = json.loads(row["result_json"])
        if hashlib.sha256(canonical(result).encode()).hexdigest() != row["result_id"]:
            raise ValueError("recorded result identity mismatch")
        try:
            raw = self._snapshot_bytes(self._snapshot_path(operation_id(key), row["result_id"]), result["digest"])
        except FileNotFoundError as exc:
            raise ValueError("recorded artifact snapshot missing") from exc
        return result, raw

    def operation_key_for(self, host_id: str, task_id: str, generation: int) -> OperationKey | None:
        self._host(host_id)
        assignment = self.spool.find_assignment(task_id, generation)
        if assignment is None:
            return None
        return OperationKey(assignment["hostId"], assignment["taskId"],
                            assignment["generation"], assignment["instanceId"])

    def collect(self, host_id: str, key: OperationKey) -> ResultReceipt | None:
        self._host(host_id)
        self._host(key.host_id)
        current = self.spool.get(operation_id(key))
        if current is None:
            raise ValueError("unknown operation")
        result_ref = Path(json.loads(current["operation_json"])["resultRef"])
        if result_ref.is_symlink():
            raise ValueError("result reference is a symlink")
        if not result_ref.exists():
            return None
        if not result_ref.is_file():
            raise ValueError("result reference is not a regular file")
        if result_ref.stat().st_size > 1024 * 1024:
            raise ValueError("result too large")
        return self.report(host_id, json.loads(result_ref.read_text()))

    def take_acceptance(self, host_id: str, key: OperationKey) -> bool:
        """True only when the CLI's own agent-work.accept.v1 for this assignment is on disk; promotes it."""
        self._host(host_id)
        op_id = operation_id(key)
        current = self.spool.get(op_id)
        if current is None:
            raise ValueError("unknown operation")
        assignment = json.loads(current["operation_json"])
        if "acceptRef" not in assignment or not read_acceptance(assignment):
            return False
        self.spool.delivered(op_id)
        return True

    def resolve_delivery(self, host_id: str, key: OperationKey, verdict: str, reason: str) -> str:
        """The operator settles an attempted or uncertain delivery; nothing is ever typed again.
        abandoned frees the instance and releases its adopted session without touching the CLI."""
        self._host(host_id)
        self._host(key.host_id)
        if verdict not in VERDICTS or not reason.strip():
            raise ValueError("verdict must be delivered or abandoned, with a reason")
        op_id = operation_id(key)
        if self.spool.get(op_id) is None:
            raise ValueError("unknown operation")
        if not self.spool.resolve_delivery(op_id, verdict, reason, time.time()):
            raise ValueError(f"operation is {self.spool.get(op_id)['status']}, not attempted or uncertain")
        return verdict

    def _end_delivery(self, key: OperationKey, episode: str) -> list[str]:
        """A delivery that will never be accepted: uncertain together with its incident. The incident key
        when this call made the change."""
        op_id = operation_id(key)
        incident = {"kind": "transport-unavailable", "episodeId": episode, "evidenceRef": f"host-operation:{op_id}"}
        incident_key, digest = incident_identity(key.generation, incident)
        changed = self.spool.delivery_uncertain(op_id, key.task_id, incident_key, canonical(incident), digest,
                                                deferred=True)
        return [incident_key] if changed else []

    def detect_run_failures(self, host_id: str, session_exit: Callable[[OperationKey], object | None], *,
                            now: float, accept_deadline_seconds: float, result_deadline_seconds: float,
                            session_directory: Callable[[OperationKey], str | None] | None = None,
                            stop_session: Callable[[OperationKey], object] | None = None) -> list[str]:
        """The silent failures of launched sessions, one incident each. session_exit answers None while the
        process lives and an object with its exit code once it left; session_directory answers the folder
        opencode opened the session in.

        A process that left without its acceptance is launch-failed, and one that accepted and left without
        a result is session-closed, both in the pass after the exit and whatever the exit code: opencode
        ends with 0 after denying a permission. A session opened outside the task's folder is stopped. A
        launch deferred since accept_deadline_seconds ago ends as launch-failed. No dialog is read:
        `opencode run` never waits for a permission."""
        self._host(host_id)
        check_deadline(accept_deadline_seconds)
        check_deadline(result_deadline_seconds)
        detected = []
        for assignment in self.spool.awaiting_results():
            key = OperationKey(assignment["hostId"], assignment["taskId"],
                               assignment["generation"], assignment["instanceId"])
            op_id = operation_id(key)
            current = self.spool.get(op_id)
            if current is None or not assignment.get("adapterId") or "refused" in assignment:
                continue
            status = current["status"]
            if status == "deferred":
                first = self.spool.first_deferred_at(op_id)
                if first is not None and now - first >= accept_deadline_seconds:
                    detected += self._end_delivery(key, LAUNCH_FAILED_EPISODE)
                continue
            if status not in ("attempted", "delivered"):
                continue
            # The exit is read before the files: a CLI writes them before it leaves, so files read after an
            # exit are final.
            left = session_exit(key)
            if left is not None:
                record = SessionRecord.for_operation(self.state_dir, op_id)
                if not record.exit.exists():
                    atomic_json(record.exit, {"code": left.code})
            opened = session_directory(key) if session_directory is not None else None
            strayed = opened is not None and opened != assignment["workspaceRef"]
            if strayed and left is None and stop_session is not None:
                stop_session(key)
            invalid, episode = False, None
            try:
                accepted = status == "delivered" or self.take_acceptance(host_id, key)
                if self.collect(host_id, key) is not None:
                    continue
            except ReviewerWroteSource:
                invalid, episode = True, REVIEWER_EPISODE
            except ValueError:
                invalid = True
            except OSError:
                continue
            if not accepted:
                attempted = self.spool.attempted_at(op_id)
                if strayed or left is not None:
                    detected += self._end_delivery(key, LAUNCH_FAILED_EPISODE)
                elif attempted is not None and now - attempted >= accept_deadline_seconds:
                    detected += self._end_delivery(key, UNACCEPTED_EPISODE)
                continue
            delivered = self.spool.delivered_at(op_id)
            if invalid:
                kind = "invalid-result"
            elif left is not None:
                kind = "transport-unavailable"
            elif delivered is not None and now - delivered >= result_deadline_seconds:
                kind = "deadline-missed"
            else:
                continue
            incident = {"kind": kind, "episodeId": episode or SILENT_EPISODES[kind],
                        "evidenceRef": f"host-operation:{op_id}"}
            incident_key = incident_identity(key.generation, incident)[0]
            if not self.spool.has_incident(key.task_id, incident_key):
                self.record_incident(host_id, key, incident)
                detected.append(incident_key)
        return detected

    def pending(self, host_id: str) -> list[dict]:
        self._host(host_id)
        for assignment in self.spool.awaiting_results():
            key = OperationKey(assignment["hostId"], assignment["taskId"],
                               assignment["generation"], assignment["instanceId"])
            op_id = operation_id(key)
            try:
                self.collect(host_id, key)
            except (ValueError, OSError) as exc:
                self.spool.note_inbox_error(op_id, str(exc))
                continue
            self.spool.clear_inbox_error(op_id)
        return self.spool.pending()

    def inbox_errors(self, host_id: str) -> list[dict]:
        self._host(host_id)
        return self.spool.inbox_errors()

    def flush(self, host_id: str, report_to_runtime: Callable[[dict, bytes], dict]) -> list[dict]:
        self._host(host_id)
        receipts, failure = [], None
        for result in self.pending(host_id):
            result_id = hashlib.sha256(canonical(result).encode()).hexdigest()
            key = OperationKey(result["hostId"], result["taskId"], result["generation"], result["instanceId"])
            op_id = operation_id(key)
            try:
                snapshot_result, artifact_bytes = self.result_snapshot(host_id, key)
                if snapshot_result != result:
                    raise ValueError("pending result identity mismatch")
            except (ValueError, OSError) as exc:
                self.spool.note_inbox_error(op_id, str(exc))
                continue
            try:
                receipt = report_to_runtime(result, artifact_bytes)
                identity = ("hostId", "taskId", "generation", "instanceId", "producerId")
                if not isinstance(receipt, dict) or any(receipt.get(field) != result[field] for field in identity) \
                        or receipt.get("resultId") != result_id or not receipt.get("receiptId"):
                    raise ValueError("runtime receipt identity mismatch")
            except (OSError, RuntimeError, ValueError) as exc:
                # R may refuse one result (a cancelled task); the others still go, and the pass reports the first.
                self.spool.note_inbox_error(op_id, f"report failed: {exc}")
                failure = failure or exc
                continue
            self.spool.clear_inbox_error(op_id)
            self.spool.acknowledge(op_id, receipt)
            receipts.append(receipt)
        if failure is not None:
            raise failure
        return receipts

    def flush_closures(self, host_id: str,
                       close_to_runtime: Callable[[dict, str, str, str], dict]) -> tuple[int, list[str]]:
        """Send every changed resource closure; each one fails alone."""
        self._host(host_id)
        closed, errors = 0, []
        rows = self.spool.closure_rows()
        seen_terminals = {(row["task_id"], row["generation"]) for row in rows
                          if row["state"] in TERMINAL_STATES}
        for row in rows:
            op_id = row["operation_id"]
            try:
                current = self.spool.get(op_id)
                # A reservation whose operation was never registered closes with the claim it kept.
                assignment = (json.loads(current["operation_json"]) if current is not None
                              else self.spool.reservation_claim(op_id))
                if assignment is None:
                    self.spool.note_inbox_error(op_id, "closure without assignment")
                    continue
                digest = closure_digest(row["evidence_json"], self.spool.closure_proof(op_id))
                last = self.spool.closure_last(op_id)
                if last and (last["state"], last["reason"], last["evidence_digest"]) \
                        == (row["state"], row["reason"], digest):
                    self.spool.clear_inbox_error(op_id)
                    continue
                if row["state"] == "CleanupPending" and (
                        (row["task_id"], row["generation"]) in seen_terminals
                        or self.spool.closure_terminal(row["task_id"], row["generation"])
                        is not None):
                    continue
                receipt = close_to_runtime(assignment, row["state"], row["reason"], digest)
                self.spool.closure_record(op_id, row["task_id"], row["generation"],
                                          row["instance_id"], row["state"], row["reason"], digest)
                self.spool.clear_inbox_error(op_id)
                closed += 1
            except (OSError, RuntimeError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
                self.spool.note_inbox_error(op_id, f"closure failed: {exc}")
                errors.append(f"{op_id}: {exc}")
        return closed, errors

    def record_incident(self, host_id: str, key: OperationKey, incident: dict) -> dict:
        self._host(host_id)
        self._host(key.host_id)
        current = self.spool.get(operation_id(key))
        if current is None:
            raise ValueError("unknown operation")
        assignment = json.loads(current["operation_json"])
        adapter = assignment.get("adapterId")
        generation = assignment.get("generation")
        if not isinstance(adapter, str) or not adapter.strip() \
                or not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
            raise ValueError("operation cannot carry host incidents")
        incident_key, incident_digest = incident_identity(generation, incident)
        return self.spool.record_incident(key.task_id, incident_key, operation_id(key),
                                          canonical(incident), incident_digest)

    def flush_incidents(self, host_id: str, send: Callable[[dict, dict], dict]) -> tuple[int, list[str]]:
        """Send every pending incident; each one fails alone and rejections never retry."""
        self._host(host_id)
        sent, errors = 0, []
        for row in self.spool.pending_incidents():
            try:
                current = self.spool.get(row["operation_id"])
                if current is None:
                    raise ValueError("incident without assignment")
                assignment = json.loads(current["operation_json"])
                receipt = send(assignment, json.loads(row["incident_json"]))
                self.spool.incident_sent(row["task_id"], row["incident_key"], receipt)
                sent += 1
            except IncidentRejected as exc:
                self.spool.incident_failed(row["task_id"], row["incident_key"], str(exc), rejected=True)
                errors.append(f"{row['operation_id']}: {exc}")
            except (OSError, RuntimeError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
                self.spool.incident_failed(row["task_id"], row["incident_key"], str(exc))
                errors.append(f"{row['operation_id']}: {exc}")
        return sent, errors

    def receipt(self, host_id: str, key: OperationKey) -> dict | None:
        self._host(host_id)
        self._host(key.host_id)
        row = self.spool.get(operation_id(key))
        if row is None:
            raise ValueError("unknown operation")
        return json.loads(row["receipt_json"]) if row["receipt_json"] else None


USAGE = "usage: host.py resolve-delivery <hostId> <stateDir> <taskId> <generation> delivered|abandoned <reason>"


def main(argv: list[str]) -> str:
    if len(argv) == 7 and argv[0] == "resolve-delivery":
        host = Host(argv[1], Path(argv[2]))
        key = host.operation_key_for(argv[1], argv[3], int(argv[4]))
        if key is None:
            raise ValueError("no host operation for that task generation")
        return host.resolve_delivery(argv[1], key, argv[5], argv[6])
    raise SystemExit(USAGE)


if __name__ == "__main__":
    try:
        print(main(sys.argv[1:]))
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc)) from exc
