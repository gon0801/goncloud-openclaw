from dataclasses import dataclass


@dataclass(frozen=True)
class OperationKey:
    host_id: str
    task_id: str
    generation: int
    instance_id: str


@dataclass(frozen=True)
class AuthorizedOperation:
    key: OperationKey
    producer_id: str
    capability: str
    session: str
    workspace_ref: str
    brief_ref: str
    brief_digest: str


@dataclass(frozen=True)
class HostObservation:
    status: str
    assignment_ref: str


@dataclass(frozen=True)
class ResultReceipt:
    result_id: str
