#!/usr/bin/env python3
import http.server
import json
import os
import pathlib
import signal
import socket
import subprocess
import tempfile
import threading
import time


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    source = pathlib.Path(os.environ.get("AGENT_WORK_RUNTIME_SOURCE", "/Users/dn/dev/openclaw-agent-work"))
    calls = []

    class FakeProvider(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            request = self.rfile.read(length)
            calls.append(request.decode())
            payload = {
                "id": "agent-work-probe",
                "object": "chat.completion",
                "created": 0,
                "model": "falso-1",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    fake = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeProvider)
    thread = threading.Thread(target=fake.serve_forever, daemon=True)
    thread.start()
    gateway_port = free_port()
    with tempfile.TemporaryDirectory(prefix="agent-work-t0-") as trial:
        root = pathlib.Path(trial)
        profile = root.name
        state = root / "state"
        workspace = root / "workspace"
        state.mkdir()
        workspace.mkdir()
        config = {
            "gateway": {"mode": "local", "port": gateway_port, "bind": "loopback", "auth": {"mode": "none"}},
            "discovery": {"mdns": {"mode": "off"}},
            "cron": {"enabled": False},
            "channels": {},
            "agents": {"defaults": {"workspace": str(workspace), "model": {"primary": "falso/falso-1"}}},
            "models": {"providers": {"falso": {
                "baseUrl": f"http://127.0.0.1:{fake.server_address[1]}/v1",
                "api": "openai-completions",
                "apiKey": "probe-only",
                "models": [{"id": "falso-1", "name": "Probe", "reasoning": False,
                            "input": ["text"], "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                            "contextWindow": 8192, "maxTokens": 1024}],
            }}},
        }
        config_path = state / "openclaw.json"
        config_path.write_text(json.dumps(config))
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("OPENCLAW_") and not key.endswith(("_API_KEY", "_TOKEN", "_SECRET"))}
        env.update(OPENCLAW_STATE_DIR=str(state), OPENCLAW_CONFIG_PATH=str(config_path),
                   OPENCLAW_PROFILE=profile)
        command = ["pnpm", "openclaw", "--profile", profile]
        log_path = root / "gateway.log"
        gateway = None

        def start_gateway():
            nonlocal gateway
            log = log_path.open("ab")
            gateway = subprocess.Popen(command + ["gateway", "run", "--port", str(gateway_port),
                                                   "--bind", "loopback", "--auth", "none"],
                                       cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            log.close()
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if gateway.poll() is not None:
                    raise RuntimeError(f"gateway exited {gateway.returncode}: {log_path.read_text()[-2000:]}")
                with socket.socket() as probe:
                    probe.settimeout(0.2)
                    if probe.connect_ex(("127.0.0.1", gateway_port)) == 0:
                        return
                time.sleep(0.2)
            raise RuntimeError(f"gateway startup timed out: {log_path.read_text()[-2000:]}")

        def stop_gateway():
            nonlocal gateway
            if gateway is None:
                return
            try:
                os.killpg(gateway.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                gateway.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(gateway.pid, signal.SIGKILL)
                gateway.wait(timeout=5)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                group = subprocess.check_output(["ps", "-Ao", "pgid=,stat="], text=True)
                living = any(int(fields[0]) == gateway.pid and not fields[1].startswith("Z")
                             for line in group.splitlines() if (fields := line.split()))
                with socket.socket() as probe:
                    probe.settimeout(0.2)
                    if not living and probe.connect_ex(("127.0.0.1", gateway_port)) != 0:
                        break
                time.sleep(0.2)
            else:
                raise RuntimeError("isolated gateway process group or port stayed active after stop")
            gateway = None

        def rpc(method, params):
            result = subprocess.run(command + ["gateway", "call", method, "--port", str(gateway_port),
                                               "--params", json.dumps(params), "--json", "--timeout", "20000"],
                                    cwd=source, env=env, text=True, capture_output=True, timeout=35)
            if result.returncode:
                raise RuntimeError(f"{method} failed: {result.stdout[-1000:]} {result.stderr[-1000:]}\n{log_path.read_text()[-2000:]}")
            return json.loads(result.stdout)

        def wait_calls(count):
            deadline = time.monotonic() + 30
            while len(calls) < count and time.monotonic() < deadline:
                time.sleep(0.1)
            if len(calls) < count:
                raise RuntimeError(f"expected {count} provider calls, got {len(calls)}: {log_path.read_text()[-2000:]}")

        try:
            start_gateway()
            created = rpc("sessions.create", {"agentId": "main"})
            session_key = created.get("sessionKey") or created.get("key")
            if not session_key:
                raise RuntimeError(f"sessions.create response lacks key: {created}")
            marker = "agent-work-t0-stable-request"
            params = {"key": session_key, "message": f"Reply with ok. Marker: {marker}",
                      "idempotencyKey": "agent-work-t0-stable"}
            first = rpc("sessions.send", params)
            if first != {"runId": "agent-work-t0-stable", "status": "started"}:
                raise RuntimeError(f"first admission unexpected: {first}")
            first_outcome = rpc("agent.wait", {"runId": first["runId"], "timeoutMs": 20000})
            if first_outcome.get("status") not in ("ok", "error"):
                raise RuntimeError(f"first run did not settle before restart: {first_outcome}")
            wait_calls(1)
            before = sum(marker in call for call in calls)
            stop_gateway()
            start_gateway()
            second = rpc("sessions.send", params)
            if second != first:
                raise RuntimeError(f"second admission unexpected: {second}")
            second_outcome = rpc("agent.wait", {"runId": second["runId"], "timeoutMs": 20000})
            if second_outcome.get("status") not in ("ok", "error"):
                raise RuntimeError(f"second run did not settle: {second_outcome}")
            after = sum(marker in call for call in calls)
            print(json.dumps({"source": str(source), "sessionKey": session_key,
                              "first": first, "firstOutcome": first_outcome.get("status"),
                              "second": second, "secondOutcome": second_outcome.get("status"),
                              "markedProviderCallsBeforeRestart": before,
                              "markedProviderCallsAfterRestart": after,
                              "duplicateAdmitted": after > before},
                             sort_keys=True))
            if after <= before:
                raise RuntimeError("baseline changed: duplicate was not admitted")
        finally:
            stop_gateway()
            fake.shutdown()


if __name__ == "__main__":
    main()
