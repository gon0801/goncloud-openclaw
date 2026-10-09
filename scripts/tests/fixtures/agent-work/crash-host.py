#!/usr/bin/env python3
"""A host process for crash_boundaries that claims one CLI assignment and stops for good at one
point, so the test can kill it with SIGKILL there. Usage:

    crash-host.py <gateway-url> <host-dir> <tmux-socket> <session> <workspace> <stop>

<stop> is where the host stops: `reserved` (the resource is reserved and nothing is launched),
`launching` (the launch began and the session is not marked yet), `marked` (the session carries
the launch's nonce and nothing attached it) or `typed` (the assignment was typed into the CLI and
nothing recorded it). The host prints `STOP <stop>` and then waits.
"""

import os
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
sys.path.insert(0, str(ROOT / "scripts" / "tests"))
from host import Host, TmuxTransport  # noqa: E402
from native_gateway import GatewayProjectionClient, claim_cli_once  # noqa: E402
from resources import ResourceManager, TmuxBackend  # noqa: E402
from test_agent_work_main_cli_loop_e2e import ADAPTER, HOST_ID, certified_coverage  # noqa: E402

STOPS = ("reserved", "launching", "marked", "typed")


def stop(point):
    print(f"STOP {point}", flush=True)
    while True:
        time.sleep(60)


def main(url, host_dir, socket, session, workspace, point):
    if point not in STOPS:
        sys.exit(f"stop must be one of {STOPS}")
    tmux = shutil.which("tmux")
    host = Host(HOST_ID, Path(host_dir))
    backend = TmuxBackend(tmux, socket)
    manager = ResourceManager(host.spool, HOST_ID, backend)
    deliver = TmuxTransport(tmux, socket).deliver
    if point == "reserved":
        manager.begin_launch = lambda key: stop(point)
    elif point == "launching":
        backend.mark = lambda session_name, nonce: stop(point)
    elif point == "marked":
        mark = backend.mark
        backend.mark = lambda session_name, nonce: (mark(session_name, nonce), stop(point))
    else:
        def deliver_then_stop(assignment_ref, target):
            TmuxTransport(tmux, socket).deliver(assignment_ref, target)
            stop(point)
        deliver = deliver_then_stop
    _, certified = certified_coverage()
    client = GatewayProjectionClient(os.environ["CRASH_HOST_OPENCLAW"], HOST_ID, url)
    claim_cli_once(client, host=host, manager=manager, adapter_id=ADAPTER, instance_id="crash-instance",
                   session=session, workspace_root=Path(workspace), deliver=deliver, coverage=certified)
    print("NO STOP", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 7:
        sys.exit(__doc__)
    main(*sys.argv[1:])
