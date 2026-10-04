#!/usr/bin/env python3
"""Seed one isolated CLI host spool for the native Gateway integration test.

phase=pending seeds the durable result and leaves a UserAdopted resource in
CleanupPending ("adopted identity uncertain"). phase=gone reopens the same
spool and re-closes that resource with positive pane-gone proof, leaving it
in ReleasedAdopted ("adopted session gone")."""

import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "agent-work"))

from contracts import AuthorizedOperation, OperationKey  # noqa: E402
from host import Host  # noqa: E402
from native_gateway import GatewayProjectionClient  # noqa: E402
from resources import ResourceManager  # noqa: E402


class SeededBackend:
    boot_id = "5eed0000-0000-0000-0000-000000000001"
    socket = "sock-seed"

    def __init__(self, identity, pane_gone):
        self.identity = identity
        self.pane_gone_result = pane_gone

    def observe(self, session):
        return self.identity

    def revoke(self, identity):
        return True

    def pane_gone(self, identity):
        return self.pane_gone_result


def adopt(key, host, identity, pane_gone):
    backend = SeededBackend(identity, pane_gone)
    manager = ResourceManager(host.spool, key.host_id, backend, capacity=2)
    return manager, backend


def main():
    root = Path(sys.argv[1])
    spec = json.loads(sys.argv[2])
    rest = sys.argv[3:]
    phase = rest[rest.index("--phase") + 1] if "--phase" in rest else "pending"
    if phase not in ("pending", "gone"):
        raise SystemExit("phase must be pending or gone")
    workspace = root / "workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    brief = workspace / "brief.txt"
    brief.write_text("Review this revision.\n")
    artifact = workspace / "review.txt"
    artifact.write_text("VEREDICTO aprobado\n")
    key = OperationKey(spec["hostId"], spec["taskId"], spec["generation"], "instance-gateway")
    host = Host(spec["hostId"], root / "host")
    gateway = GatewayProjectionClient(spec["openclawBin"], spec["hostId"], spec["gatewayUrl"])
    host.apply(key, AuthorizedOperation(
        key=key,
        producer_id=spec["producerId"],
        capability=spec["capability"],
        session="worker-gateway",
        workspace_ref=str(workspace),
        brief_ref=str(brief),
        brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
        input_revision=spec["revision"],
        result_contract="review.v1",
        claim_id=spec["claimId"],
        adapter_id=spec.get("adapterId", "codex"),
    ), lambda *_: None, gateway.admit_host)
    host.report(spec["hostId"], {
        "schema": "agent-work.result.v1",
        "kind": "produced",
        "hostId": spec["hostId"],
        "taskId": spec["taskId"],
        "generation": spec["generation"],
        "instanceId": key.instance_id,
        "producerId": spec["producerId"],
        "capability": spec["capability"],
        "observedRevision": spec["revision"],
        "typedPayload": {"verdict": "approved", "evidenceRef": "review.txt"},
        "artifactRef": str(artifact),
        "digest": hashlib.sha256(artifact.read_bytes()).hexdigest(),
    })
    evidence = {"kind": "result", "receipt": "seed-result"}
    manager, backend = adopt(key, host, None, False)
    held = manager.reserve(key, "worker-adopted", "UserAdopted")
    manager.begin_launch(key)
    identity = {"bootId": SeededBackend.boot_id, "nonce": held.nonce,
                "socket": SeededBackend.socket, "sessionName": "worker-adopted",
                "serverPid": 4100, "serverStart": "seed-server-start",
                "sessionId": "@7", "paneId": "%7", "panePid": 4107,
                "paneStart": "seed-pane-start"}
    if phase == "pending":
        backend.identity = identity
        manager.attach(key)
        backend.identity = {**identity, "paneStart": "seed-pane-replaced"}
    else:
        backend.identity = None
        backend.pane_gone_result = True
    view = manager.close(key, evidence)
    print(f"seed-host-result phase={phase} state={view.state} reason={view.reason}")
    shutil.rmtree(workspace)


if __name__ == "__main__":
    main()
