#!/usr/bin/env python3
"""An isolated host for rehearsing the cutover and its rollback on a consistent copy of the live
gateway: no channels, no credentials, cron scheduler off unless asked, sandboxed without network.

Usage: ensayo_host.py up <copy> <prefix> [port]   prints ENSAYO=<dir> CLI=<dir>/oc-cli PID=<pid>
"""
import json
import os
import re
import secrets
import signal
from contextlib import closing
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SANDBOX = """(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (remote ip "localhost:*"))
(allow network-outbound (remote unix-socket))
"""
NODE_BIN = Path(os.environ.get("NODE_BIN", Path.home() / ".openclaw/tools/node/bin"))
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def listener(port):
    found = subprocess.run(["lsof", "-nP", "-t", f"-iTCP:{port}", "-sTCP:LISTEN"],
                           capture_output=True, text=True).stdout.split()
    return int(found[0]) if found else None


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def copy_state(copy, state):
    """The copy's databases and its sanitized config, laid out as an OPENCLAW_STATE_DIR."""
    (state / "state").mkdir(parents=True, exist_ok=True)
    for stale in (state / "state").glob("openclaw.sqlite*"):
        stale.unlink()
    shutil.copyfile(copy / "openclaw.sqlite", state / "state/openclaw.sqlite")
    for database in sorted(copy.glob("agent-*.sqlite")):
        agent = state / "agents" / database.stem.removeprefix("agent-") / "agent"
        agent.mkdir(parents=True, exist_ok=True)
        for stale in agent.glob("openclaw-agent.sqlite*"):
            stale.unlink()
        shutil.copyfile(database, agent / "openclaw-agent.sqlite")


def sanitized_config(copy_config, state, token, port):
    config = json.loads(Path(copy_config).read_text())
    config.pop("channels", None)
    gateway = config["gateway"]
    gateway.update(port=port, bind="loopback", auth={"mode": "token", "token": token})
    gateway.pop("tailscale", None)
    for provider in config.get("models", {}).get("providers", {}).values():
        if "apiKey" in provider:
            provider["apiKey"] = "REDACTED-ensayo"
    config.setdefault("cron", {})["enabled"] = False
    return json.loads(json.dumps(config).replace("/Users/gon/.openclaw", str(state)))


class EnsayoHost:
    def __init__(self, root, port):
        self.root, self.port = Path(root), port
        self.state = self.root / "oc"
        self.home = self.root / "home"
        self.cli = self.root / "oc-cli"
        self.process = None
        self.log = None

    @classmethod
    def create(cls, copy, prefix, port=18799):
        if listener(port):
            raise RuntimeError(f"port {port} is busy; stop that gateway first")
        root = Path(tempfile.mkdtemp(prefix="ensayo-gateway-"))
        root.chmod(0o700)
        host = cls(root, port)
        host.home.mkdir()
        copy_state(Path(copy), host.state)
        token = secrets.token_hex(16)
        (root / "token").write_text(token)
        config = sanitized_config(Path(copy) / "openclaw.json", host.state, token, port)
        host.write_config(config)
        (root / "sandbox.sb").write_text(SANDBOX)
        host.write_cli(prefix)
        return host

    def write_config(self, config):
        path = self.state / "openclaw.json"
        path.write_text(json.dumps(config, indent=2))
        path.chmod(0o600)

    def write_cli(self, prefix):
        self.cli.write_text(f"#!/bin/sh\nexec env HOME={self.home} OPENCLAW_STATE_DIR={self.state} "
                            f"{prefix}/bin/openclaw \"$@\"\n")
        self.cli.chmod(0o755)

    def ready(self, log):
        return "[gateway] ready" in ANSI.sub("", log.read_text(errors="replace")) if log.exists() else False

    def start(self, prefix, *, skip_cron=True, timeout=180):
        """Start the gateway of <prefix> on this state; returns its log, or raises with the log tail."""
        self.write_cli(prefix)
        log = self.root / f"gateway-{int(time.time() * 1000)}.log"
        env = {"HOME": str(self.home), "OPENCLAW_STATE_DIR": str(self.state), "OPENCLAW_SKIP_CHANNELS": "1",
               "PATH": f"{NODE_BIN}:/usr/bin:/bin:/usr/sbin:/sbin"}
        if skip_cron:
            env["OPENCLAW_SKIP_CRON"] = "1"
        with open(log, "w") as stream:
            process = subprocess.Popen(
                ["sandbox-exec", "-f", str(self.root / "sandbox.sb"), "env",
                 *[f"{key}={value}" for key, value in env.items()],
                 f"{prefix}/bin/openclaw", "gateway", "--port", str(self.port), "--bind", "loopback"],
                cwd=self.root, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
                start_new_session=True)
        self.process, self.log = process, log
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.ready(log) and listener(self.port):
                (self.root / "gateway.pid").write_text(str(listener(self.port)))
                return log
            if process.poll() is not None:
                break
            time.sleep(1)
        self.stop()
        tail = ANSI.sub("", log.read_text(errors="replace"))[-1500:]
        raise RuntimeError(f"gateway of {prefix} did not start:\n{tail}")

    def stop(self, timeout=60):
        """Stop the gateway and wait for its process to exit: it frees the port before it frees the
        state directory, and the next gateway refuses a state another one still owns."""
        others = {pid for pid in (listener(self.port),) if pid}
        own = self.process if self.process is not None and self.process.poll() is None else None
        if own is not None:
            others.discard(own.pid)
            own.send_signal(signal.SIGTERM)
        for pid in others:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            # poll() reaps our own child; a dead but unreaped child still answers kill(pid, 0).
            own_alive = own is not None and own.poll() is None
            alive = [pid for pid in others if _alive(pid)]
            if not own_alive and not alive and not listener(self.port):
                return
            time.sleep(0.5)
        raise RuntimeError(f"gateway on port {self.port} did not stop")

    def restore(self, snapshot):
        """The pre-install photo back in place: its databases and its config, sanitized again."""
        snapshot = Path(snapshot)
        copy_state(snapshot, self.state)
        token = (self.root / "token").read_text()
        self.write_config(sanitized_config(snapshot / "openclaw.json", self.state, token, self.port))

    def config(self):
        return json.loads((self.state / "openclaw.json").read_text())

    def schema(self):
        # mode=ro reads through the WAL; immutable=1 would miss a migration not yet checkpointed.
        with closing(sqlite3.connect(f"file:{self.state / 'state/openclaw.sqlite'}?mode=ro", uri=True)) as db:
            return db.execute("PRAGMA user_version").fetchone()[0]


def main():
    if len(sys.argv) < 4 or sys.argv[1] != "up":
        sys.exit(__doc__)
    host = EnsayoHost.create(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 18799)
    host.start(sys.argv[3])
    print(f"ENSAYO={host.root} CLI={host.cli} PID={(host.root / 'gateway.pid').read_text()}")


if __name__ == "__main__":
    main()
