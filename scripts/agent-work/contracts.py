from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
from typing import Optional, Tuple

OPERATION_ID = re.compile(r"[0-9a-f]{64}")


@dataclass(frozen=True)
class OperationKey:
    host_id: str
    task_id: str
    generation: int
    instance_id: str


def operation_id(key: OperationKey) -> str:
    identity = [key.host_id, key.task_id, key.generation, key.instance_id]
    return hashlib.sha256(json.dumps(identity, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


class IncidentRejected(RuntimeError):
    """Definitive rejection from R; the incident must not be retried."""


@dataclass(frozen=True)
class RunDir:
    """<spool>/runs/<operation>/: the only folder outside the task's repo that its session may read and
    write. It holds the four protocol files of one run, and no other code builds these paths."""
    path: Path

    @property
    def assignment(self) -> Path:
        return self.path / "assignment.json"

    @property
    def brief(self) -> Path:
        return self.path / "brief"

    @property
    def accept(self) -> Path:
        return self.path / "accept.json"

    @property
    def result(self) -> Path:
        return self.path / "result.json"

    @property
    def context(self) -> Path:
        """The worker's package (SUA-03): poteto, its adaptation and its profile."""
        return self.path / "contexto"

    @property
    def fleet(self) -> Path:
        """The sistema-agentes.flota.v1 document of this attempt, written when the run closes."""
        return self.path / "flota.json"

    @property
    def scratch(self) -> Path:
        """Where the session keeps helper scripts and temporary files: its TMPDIR."""
        return self.path / "tmp"

    @property
    def repo(self) -> Path:
        """The disposable clone where a reviewer works (SUA-03, 4.8), built and deleted by the host."""
        return self.path / "repo"

    @staticmethod
    def for_operation(spool: Path, operation: str) -> "RunDir":
        if not OPERATION_ID.fullmatch(operation):
            raise ValueError("operation id must be 64 hex characters")
        path = Path(spool) / "runs" / operation
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        return RunDir(path)


@dataclass(frozen=True)
class SessionRecord:
    """<spool>/sessions/<operation>/: what the host keeps of one run. The session has no permission here,
    and no other code builds these paths."""
    path: Path

    @property
    def launch(self) -> Path:
        return self.path / "launch.sh"

    @property
    def argv(self) -> Path:
        return self.path / "argv.json"

    @property
    def events(self) -> Path:
        return self.path / "events.jsonl"

    @property
    def stderr(self) -> Path:
        return self.path / "stderr.log"

    @property
    def exit(self) -> Path:
        return self.path / "exit.json"

    @property
    def blocked(self) -> Path:
        return self.path / "blocked.json"

    @property
    def context(self) -> Path:
        """What the launcher handed the run besides its brief: the digests of the copied package and of
        the run config, taken before launch (SUA-03, 4.7). A run without a package has none."""
        return self.path / "contexto.json"

    @property
    def repo_before(self) -> Path:
        """The photo of the task's real repo taken before a run that may not write it (SUA-03, 4.8)."""
        return self.path / "repo-antes.json"

    @property
    def repo_after(self) -> Path:
        return self.path / "repo-despues.json"

    @staticmethod
    def locate(spool: Path, operation: str) -> "SessionRecord":
        """Where the record of that operation is, whether or not the host has written it."""
        if not OPERATION_ID.fullmatch(operation):
            raise ValueError("operation id must be 64 hex characters")
        return SessionRecord(Path(spool) / "sessions" / operation)

    @staticmethod
    def for_operation(spool: Path, operation: str) -> "SessionRecord":
        record = SessionRecord.locate(spool, operation)
        record.path.mkdir(mode=0o700, parents=True, exist_ok=True)
        return record


@dataclass(frozen=True)
class AuthorizedOperation:
    key: OperationKey
    producer_id: str
    capability: str
    session: str
    workspace_ref: str
    brief_ref: str
    brief_digest: str
    input_revision: dict
    result_contract: str
    claim_id: str
    adapter_id: str = ""
    run: Optional[RunDir] = None
    """Set on the run-per-task route: the assignment, the brief, the acceptance and the result live in it."""


@dataclass(frozen=True)
class HostObservation:
    status: str
    assignment_ref: str


@dataclass(frozen=True)
class ResultReceipt:
    result_id: str


HOST_BEAT_FILE = "host.json"
HOST_SLOTS = ("free", "running", "blocked")


@dataclass(frozen=True)
class HostBeat:
    """<state_root>/host.json: what `encargo.py` reads of the host that runs one opencode process per task,
    written when each pass begins. policy_digest and cli_version say which provider policy and which
    opencode the host decides with, and spool where it keeps its operations."""
    pid: int
    started_at: float
    beat_at: float
    checkout: str
    commit: str
    cli_version: str
    policy_digest: Optional[str]
    slot: str
    blocked_by: Tuple[str, ...]
    task_id: Optional[str]
    model: Optional[str]
    since: Optional[float]
    spool: str
    canary: bool
    """A canary host also runs a sandbox-tested route or a new opencode version, to certify it."""

    def document(self) -> dict:
        """What the host writes to host.json, and read() takes back."""
        return {"pid": self.pid, "startedAt": self.started_at, "beatAt": self.beat_at, "checkout": self.checkout,
                "commit": self.commit, "cliVersion": self.cli_version, "policyDigest": self.policy_digest,
                "slot": self.slot, "blockedBy": list(self.blocked_by), "taskId": self.task_id, "model": self.model,
                "since": self.since, "spool": self.spool, "canary": self.canary}

    @staticmethod
    def read(state_root: Path) -> "Optional[HostBeat]":
        """None when no host ever wrote the file, or when what is there is not a beat."""
        try:
            raw = json.loads((Path(state_root) / HOST_BEAT_FILE).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None

        def number(value):
            return isinstance(value, (int, float)) and not isinstance(value, bool)

        def text_or_none(value):
            return value is None or isinstance(value, str)

        if not isinstance(raw, dict):
            return None
        blocked = raw.get("blockedBy")
        if not (isinstance(raw.get("pid"), int) and not isinstance(raw["pid"], bool)
                and number(raw.get("startedAt")) and number(raw.get("beatAt"))
                and all(isinstance(raw.get(key), str) and raw[key]
                        for key in ("checkout", "commit", "cliVersion", "spool"))
                and isinstance(raw.get("canary"), bool)
                and text_or_none(raw.get("policyDigest")) and raw.get("slot") in HOST_SLOTS
                and isinstance(blocked, list) and all(isinstance(item, str) for item in blocked)
                and text_or_none(raw.get("taskId")) and text_or_none(raw.get("model"))
                and (raw.get("since") is None or number(raw["since"]))):
            return None
        return HostBeat(raw["pid"], float(raw["startedAt"]), float(raw["beatAt"]), raw["checkout"], raw["commit"],
                        raw["cliVersion"], raw.get("policyDigest"), raw["slot"], tuple(blocked), raw.get("taskId"),
                        raw.get("model"), raw.get("since"), raw["spool"], raw["canary"])
