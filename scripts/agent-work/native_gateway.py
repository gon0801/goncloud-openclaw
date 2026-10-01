"""Authenticated Gateway transport for the native projection queue."""

import argparse
import hashlib
import json
import subprocess

from host import Host
from progress_bridge import transfer_host_projection, transfer_projection
from spool import canonical


class GatewayProjectionClient:
    def __init__(self, openclaw_bin, host_id, expected_url=None):
        if not host_id or not isinstance(host_id, str):
            raise ValueError("publisher host required")
        self.openclaw_bin = str(openclaw_bin)
        self.host_id = host_id
        self.expected_url = expected_url

    def _call(self, method, params):
        command = [self.openclaw_bin, "gateway", "call", method,
                   "--params", json.dumps(params, sort_keys=True, separators=(",", ":")),
                   "--json", "--timeout", "30000"]
        if self.expected_url:
            command.extend(("--expect-url", self.expected_url))
        try:
            response = subprocess.run(command, capture_output=True, text=True, timeout=35)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RuntimeError("native projection Gateway unavailable") from exc
        if response.returncode:
            raise RuntimeError("native projection Gateway rejected request")
        try:
            parsed = json.loads(response.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError("native projection Gateway returned invalid JSON") from exc
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

    def report_host_result(self, result):
        if not isinstance(result, dict) or result.get("hostId") != self.host_id:
            raise ValueError("host report identity mismatch")
        result_id = hashlib.sha256(canonical(result).encode()).hexdigest()
        return self._call("managedTasks.host.report", {
            "hostId": self.host_id, "resultId": result_id, "result": result,
        })


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


def main(argv=None):
    parser = argparse.ArgumentParser(description="Transfer native task results to progress events")
    parser.add_argument("--openclaw-bin", required=True)
    parser.add_argument("--host-id", required=True)
    parser.add_argument("--expect-url", required=True)
    parser.add_argument("--evidence-root")
    parser.add_argument("--progress-state-dir")
    parser.add_argument("--progress-client")
    parser.add_argument("--host-state-dir")
    parser.add_argument("--flush-results", action="store_true")
    args = parser.parse_args(argv)
    client = GatewayProjectionClient(args.openclaw_bin, args.host_id, args.expect_url)
    if args.flush_results:
        if not args.host_state_dir:
            parser.error("--flush-results requires --host-state-dir")
        receipts = Host(args.host_id, args.host_state_dir).flush(args.host_id, client.report_host_result)
        print(json.dumps({"reported": len(receipts)}))
        return 0
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
