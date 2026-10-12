#!/usr/bin/env python3
"""lanzar-host.sh on a private tmux server, with an opencode double and a host double."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "scripts/agent-work/lanzar-host.sh"
TMUX = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
# Both doubles keep their argv while they live (no exec), so pgrep sees them as the real ones.
OPENCODE_DOUBLE = """#!/bin/bash
{ printf '%s\\n' "$@"; printf 'OPENCODE_DISABLE_AUTOUPDATE=%s\\nOPENCODE_CONFIG_CONTENT=%s\\nPWD=%s\\n' \
  "$OPENCODE_DISABLE_AUTOUPDATE" "$OPENCODE_CONFIG_CONTENT" "$PWD"; } > "$(dirname "$0")/opencode-$$.txt"
sleep 300 & wait
"""
HOST_DOUBLE = """#!/bin/bash
{ printf '%s\\n' "$@"; printf 'OPENCLAW_BIN=%s\\nLANG=%s\\nPWD=%s\\n' "$OPENCLAW_BIN" "$LANG" "$PWD"; } \
  > "$(dirname "$0")/host-$$.txt"
echo "host double up"
sleep 300 & wait
"""


@unittest.skipUnless(shutil.which("tmux") and shutil.which("pgrep"), "needs tmux and pgrep")
class LanzarHost(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.socket = f"b19-lanzar-{os.getpid()}-{self.id().rsplit('.', 1)[-1][-20:]}"
        self.addCleanup(subprocess.run, [TMUX, "-L", self.socket, "kill-server"], capture_output=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in (("opencode", OPENCODE_DOUBLE), ("python-host", HOST_DOUBLE)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.workspace = self.root / "repo"
        self.workspace.mkdir()
        self.state = self.root / "state"
        self.env = {**os.environ, "AGENT_WORK_TMUX": TMUX, "AGENT_WORK_TMUX_SOCKET": self.socket,
                    "AGENT_WORK_OPENCODE": str(self.bin / "opencode"), "AGENT_WORK_STATE_ROOT": str(self.state),
                    "AGENT_WORK_PROGRESS_DIR": str(self.root / "progress"),
                    "AGENT_WORK_PROGRESS_CLIENT": str(self.root / "progress-events.py"),
                    "OPENCLAW_BIN": "/isolated/openclaw", "AGENT_WORK_PYTHON": str(self.bin / "python-host"),
                    "AGENT_WORK_SETTLE_SECONDS": "0.5"}
        self.instance = f"ds{os.getpid()}{self.id()[-6:].replace('_', '')}"
        # Its own name: the launcher looks for other hosts with pgrep, which also sees a live host of the machine.
        self.session = f"s-{self.instance}"

    def launch(self, *args):
        return subprocess.run(["bash", str(LAUNCHER), *args], capture_output=True, text=True, env=self.env,
                              timeout=30)

    def tmux(self, *args):
        return subprocess.run([TMUX, "-L", self.socket, *args], capture_output=True, text=True)

    def recorded(self, prefix):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            files = sorted(self.bin.glob(f"{prefix}-*.txt"))
            if files and files[0].read_text().endswith("\n") and "PWD=" in files[0].read_text():
                return [path.read_text().splitlines() for path in files]
            time.sleep(0.1)
        return []

    def sessions(self):
        return sorted(self.tmux("list-sessions", "-F", "#{session_name}").stdout.split())

    def test_an_alias_starts_its_model_session_and_a_host_with_the_live_flags(self):
        launched = self.launch("--canario", "opencode@zai-coding-plan/glm-5.3", self.instance, self.session,
                               str(self.workspace))
        self.assertEqual(launched.returncode, 0, launched.stderr)
        spool = self.state / self.instance
        self.assertEqual(launched.stdout.splitlines()[-1],
                         f"HOST {self.instance} opencode@zai-coding-plan/glm-5.3 zai-coding-plan/glm-5.3 "
                         f"sesión={self.session} spool={spool}")
        self.assertEqual(self.sessions(), sorted([self.session, f"host-{self.instance}"]))
        self.assertEqual(self.recorded("opencode"), [[
            "-m", "zai-coding-plan/glm-5.3", "OPENCODE_DISABLE_AUTOUPDATE=1",
            'OPENCODE_CONFIG_CONTENT={"permission":{"external_directory":{"' + str(spool) + '/**":"allow"}}}',
            f"PWD={self.workspace}"]])
        self.assertEqual(self.recorded("host"), [[
            "scripts/agent-work/native_gateway.py", "--openclaw-bin", "/isolated/openclaw",
            "--host-id", "mac-local", "--expect-url", "ws://127.0.0.1:18789",
            "--host-state-dir", str(spool), "--evidence-root", str(self.state / "evidence"),
            "--progress-state-dir", str(self.root / "progress"),
            "--progress-client", str(self.root / "progress-events.py"), "--watch",
            "--cli-adapter-id", "opencode@zai-coding-plan/glm-5.3", "--cli-instance-id", self.instance,
            "--cli-session", self.session, "--cli-workspace-root", str(self.workspace),
            "--cli-tmux-socket", self.socket, "--cli-deadline-seconds", "3600", "--cli-canary",
            "OPENCLAW_BIN=/isolated/openclaw", "LANG=en_US.UTF-8", f"PWD={ROOT}"]])
        self.assertEqual((spool / "host.log").read_text(), "host double up\n")
        self.assertEqual(oct(spool.stat().st_mode & 0o777), "0o700")

    def test_the_default_alias_runs_glm_on_the_coding_plan_and_no_canary_flag(self):
        launched = self.launch("opencode", self.instance, self.session, str(self.workspace))
        self.assertEqual(launched.returncode, 0, launched.stderr)
        self.assertEqual(self.recorded("opencode")[0][:2], ["-m", "zai-coding-plan/glm-5.3-flash"])
        host = self.recorded("host")[0]
        self.assertEqual(host[host.index("--cli-adapter-id") + 1], "opencode")
        self.assertNotIn("--cli-canary", host)

    def test_a_second_run_reuses_the_session_and_the_host(self):
        args = ("opencode@zai-coding-plan/glm-5.2", self.instance, self.session, str(self.workspace))
        self.assertEqual(self.launch(*args).returncode, 0)
        again = self.launch(*args)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(again.stdout.splitlines()[:2],
                         [f"opencode: la sesión {self.session} ya corre zai-coding-plan/glm-5.2",
                          f"host: host-{self.instance} ya corre"])
        self.assertEqual(len(self.recorded("host")), 1, "a second host started for the same instance")
        self.assertEqual(len(self.recorded("opencode")), 1)
        self.assertEqual(self.sessions(), sorted([self.session, f"host-{self.instance}"]))

    def test_the_same_instance_with_another_alias_is_refused(self):
        self.assertEqual(self.launch("opencode@zai-coding-plan/glm-5.2", self.instance, self.session,
                                     str(self.workspace)).returncode, 0)
        other = self.launch("opencode@zai-coding-plan/glm-4.7", self.instance, f"{self.session}-b", str(self.workspace))
        self.assertEqual((other.returncode, other.stderr),
                         (1, f"lanzar-host: host-{self.instance} ya corre con otro comando "
                             f"(ver {self.state / self.instance}/host-cmd.txt)\n"))
        self.assertEqual(len(self.recorded("host")), 1)

    def test_a_session_that_runs_another_model_is_never_adopted(self):
        self.tmux("new-session", "-d", "-s", self.session, "-c", str(self.workspace),
                  str(self.bin / "opencode"), "-m", "zai-coding-plan/glm-5.2")
        refused = self.launch("opencode@zai-coding-plan/glm-5.3", self.instance, self.session,
                              str(self.workspace))
        self.assertEqual((refused.returncode, refused.stderr),
                         (1, f"lanzar-host: la sesión {self.session} no corre zai-coding-plan/glm-5.3: "
                             f"{self.bin / 'opencode'} -m zai-coding-plan/glm-5.2\n"))
        self.assertEqual(self.sessions(), [self.session])

    def test_a_session_whose_permission_names_another_spool_is_never_adopted(self):
        self.tmux("new-session", "-d", "-s", self.session, "-c", str(self.workspace),
                  "-e", 'OPENCODE_CONFIG_CONTENT={"permission":{"external_directory":{"/old/**":"allow"}}}',
                  str(self.bin / "opencode"), "-m", "zai-coding-plan/glm-5.3")
        refused = self.launch("opencode@zai-coding-plan/glm-5.3", self.instance, self.session,
                              str(self.workspace))
        self.assertEqual(refused.returncode, 1)
        self.assertIn(f"la sesión {self.session} no permite el spool", refused.stderr)
        self.assertEqual(self.sessions(), [self.session])

    def test_a_host_of_the_same_instance_outside_the_launcher_blocks_a_second_one(self):
        stray = subprocess.Popen(["python3", "-c", "import time; time.sleep(60)", "--cli-instance-id", self.instance])
        self.addCleanup(stray.wait)
        self.addCleanup(stray.kill)
        refused = self.launch("opencode@zai-coding-plan/glm-5.3", self.instance, self.session,
                              str(self.workspace))
        self.assertEqual((refused.returncode, refused.stderr),
                         (1, f"lanzar-host: otro host ya usa la instancia {self.instance} o la sesión {self.session} "
                             f"(pid {stray.pid})\n"))
        self.assertEqual(self.recorded("host"), [])
        self.assertEqual(self.sessions(), [], "a refused launch left an opencode session behind")

    def test_a_bad_alias_starts_nothing(self):
        for alias, error in (("opencode@zai/glm-4.7", "adapter opencode@zai/glm-4.7 bills per token; use zai-coding-plan/"),
                             ("opencode@opencode-go/kimi-k3", "adapter opencode@opencode-go/kimi-k3 spends the "
                              "opencode Go subscription, reserved for main; use zai-coding-plan/"),
                             ("codex", "adapter codex is not an opencode adapter")):
            refused = self.launch(alias, self.instance, self.session, str(self.workspace))
            self.assertEqual((refused.returncode, refused.stderr), (2, f"lanzar-host: {error}\n"))
        self.assertEqual(self.sessions(), [])
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main()
