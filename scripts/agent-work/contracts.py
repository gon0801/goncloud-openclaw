from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re


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


@dataclass(frozen=True)
class HostObservation:
    status: str
    assignment_ref: str


@dataclass(frozen=True)
class ResultReceipt:
    result_id: str


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

    @staticmethod
    def for_operation(spool: Path, operation: str) -> "RunDir":
        if not re.fullmatch(r"[0-9a-f]{64}", operation):
            raise ValueError("operation id must be 64 hex characters")
        path = Path(spool) / "runs" / operation
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        return RunDir(path)
