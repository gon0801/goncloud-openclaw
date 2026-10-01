from dataclasses import dataclass
import hashlib
import json


@dataclass(frozen=True)
class OperationKey:
    host_id: str
    task_id: str
    generation: int
    instance_id: str


def operation_id(key: OperationKey) -> str:
    identity = [key.host_id, key.task_id, key.generation, key.instance_id]
    return hashlib.sha256(json.dumps(identity, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


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


@dataclass(frozen=True)
class HostObservation:
    status: str
    assignment_ref: str


@dataclass(frozen=True)
class ResultReceipt:
    result_id: str
