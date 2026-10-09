"""Prepare one immutable instruction artifact and native submit parameters."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile


class RouteUnavailable(ValueError):
    pass


AGENT_ROUTES = {("ingenieria", "adversary"), ("operaciones", "ingenieria")}
CLI_ROUTES = {("ingenieria", "windows-remote"), ("main", "mac-local")}


def prepare_request(*, requester, target, key, brief, instruction_root,
                    input_revision, result_contract, coverage):
    if requester not in coverage["requesters"] or not key:
        raise RouteUnavailable("requester or stable key is invalid")
    if (requester, target) in AGENT_ROUTES:
        destination = {"kind": "agent", "agentId": target}
    elif "/" in target:
        host_id, adapter_id = target.split("/", 1)
        if (requester, host_id) not in CLI_ROUTES:
            raise RouteUnavailable(f"route {requester} -> {target} is outside the managed perimeter")
        if coverage["hostAdapterCoverage"].get(host_id, {}).get(adapter_id) != "certified":
            raise RouteUnavailable(f"route {target} is not certified")
        destination = {"kind": "cli", "hostId": host_id, "adapterId": adapter_id}
    else:
        raise RouteUnavailable(f"route {requester} -> {target} is outside the managed perimeter")
    if not isinstance(input_revision, dict) or input_revision.get("kind") not in ("code", "artifact"):
        raise ValueError("input revision is invalid")
    if result_contract not in ("review.v1", "ready.v1"):
        raise ValueError("result contract is invalid")
    content = Path(brief).read_bytes()
    if not content or len(content) > 1024 * 1024:
        raise ValueError("brief must contain 1 to 1048576 bytes")
    digest = hashlib.sha256(content).hexdigest()
    root = Path(instruction_root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("instruction root must be an existing directory")
    artifact = root / digest
    pending = None
    try:
        descriptor, pending = tempfile.mkstemp(prefix=".managed-instruction-", dir=root)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(pending, artifact)
        except FileExistsError:
            if artifact.is_symlink() or artifact.read_bytes() != content:
                raise ValueError("instruction artifact differs from digest")
    finally:
        if pending is not None:
            os.unlink(pending)
    return {"key": key, "assignment": {
        "target": destination,
        "instructionRef": {"ref": f"artifact:{digest}", "digest": f"sha256:{digest}"},
        "inputRevision": input_revision,
        "resultContract": result_contract,
        "continuation": {"kind": "requester"},
    }}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--requester", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--brief", type=Path, required=True)
    parser.add_argument("--instruction-root", type=Path, required=True)
    parser.add_argument("--revision-json", required=True)
    parser.add_argument("--result-contract", choices=("review.v1", "ready.v1"), required=True)
    args = parser.parse_args()
    coverage_path = Path(__file__).resolve().parents[2] / "docs/evidence/agent-work/coverage.json"
    print(json.dumps(prepare_request(
        requester=args.requester, target=args.target, key=args.key, brief=args.brief,
        instruction_root=args.instruction_root, input_revision=json.loads(args.revision_json),
        result_contract=args.result_contract, coverage=json.loads(coverage_path.read_text()),
    ), sort_keys=True))


if __name__ == "__main__":
    main()
