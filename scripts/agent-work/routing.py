"""Prepare one immutable instruction artifact and native submit parameters."""

import argparse
import json
from pathlib import Path

from brief import instruction_ref, write_instruction


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
    digest = write_instruction(instruction_root, Path(brief).read_bytes())
    return {"key": key, "assignment": {
        "target": destination,
        "instructionRef": instruction_ref(digest),
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
