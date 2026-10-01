#!/usr/bin/env python3
"""Seed one isolated CLI host spool for the native Gateway integration test."""

import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "agent-work"))

from contracts import AuthorizedOperation, OperationKey  # noqa: E402
from host import Host  # noqa: E402
from native_gateway import GatewayProjectionClient  # noqa: E402


def main():
    root = Path(sys.argv[1])
    spec = json.loads(sys.argv[2])
    workspace = root / "workspace"
    workspace.mkdir(parents=True)
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


if __name__ == "__main__":
    main()
