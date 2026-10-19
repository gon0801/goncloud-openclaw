#!/usr/bin/env python3
"""lanzar-encargos.sh on a private tmux server, with a host double: what it starts, reuses and refuses.

The launcher finds its host by its own tmux session and its own spool, never by the machine's process
table, so a host that lives on this machine changes nothing here.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "scripts/agent-work/lanzar-encargos.sh"
TMUX = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
# The double records each start and then lives until it is told to die.
HOST_DOUBLE = """#!/bin/bash
here=$(dirname "$0")
{ printf '%s\\n' "$@"; printf 'OPENCLAW_BIN=%s\\nLANG=%s\\nPWD=%s\\nPATH=%s\\n' "$OPENCLAW_BIN" "$LANG" "$PWD" "$PATH"; } \
  > "$here/host-$$.txt"
echo "host double $$ up"
trap 'kill $waiting; exit 0' TERM
sleep 300 > /dev/null 2>&1 & waiting=$!
wait
"""


@unittest.skipUnless(shutil.which("tmux"), "needs tmux")
class LanzarEncargos(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.socket = f"b22f2-lanzar-{os.getpid()}-{self.id().rsplit('.', 1)[-1][-20:]}"
        self.addCleanup(self.clean)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in (("python-host", HOST_DOUBLE), ("opencode", "#!/bin/sh\nexit 0\n")):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.dev = self.root / "dev"
        self.dev.mkdir()
        self.state = self.root / "state"
        # Any group of this user lets the launcher start; the real slot group matters to the host itself.
        self.group = subprocess.run(["id", "-gn"], capture_output=True, text=True, check=True).stdout.strip()
        self.env = {**os.environ, "AGENT_WORK_TMUX": TMUX, "AGENT_WORK_TMUX_SOCKET": self.socket,
                    "AGENT_WORK_OPENCODE": str(self.bin / "opencode"), "AGENT_WORK_STATE_ROOT": str(self.state),
                    "AGENT_WORK_PROGRESS_DIR": str(self.root / "progress"),
                    "AGENT_WORK_PROGRESS_CLIENT": str(self.root / "progress-events.py"),
                    "OPENCLAW_BIN": "/isolated/openclaw", "AGENT_WORK_PYTHON": str(self.bin / "python-host"),
                    "AGENT_WORK_SLOT_GROUP": self.group, "AGENT_WORK_WORKSPACE_ROOT": str(self.dev),
                    "AGENT_WORK_SETTLE_SECONDS": "0.5", "AGENT_WORK_RESTART_SECONDS": "0.3",
                    # Sin shims por omisión: el caso feliz avisa y arranca igual (adenda G-sin-candados).
                    "AGENT_WORK_CANDADOS_SHIMS": str(self.root / "shims-que-no-estan")}
        self.env.pop("AGENT_WORK_SUCESION_RUNTIME_SOURCE", None)

    def clean(self):
        socket = self.tmux("display-message", "-p", "#{socket_path}").stdout.strip()
        self.tmux("kill-server")
        if socket.endswith(f"/{self.socket}"):
            Path(socket).unlink(missing_ok=True)

    def launch(self, *args, **env):
        return subprocess.run(["bash", str(LAUNCHER), *args], capture_output=True, text=True,
                              env={**self.env, **env}, timeout=30)

    def tmux(self, *args):
        return subprocess.run([TMUX, "-L", self.socket, *args], capture_output=True, text=True)

    def starts(self, count=1):
        """Every start of the host double so far, oldest first, once there are count of them."""
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            files = sorted(self.bin.glob("host-*.txt"), key=lambda path: path.stat().st_mtime_ns)
            if len(files) >= count and all("PWD=" in path.read_text() for path in files):
                return [(int(path.stem.split("-")[1]), path.read_text().splitlines()) for path in files]
            time.sleep(0.05)
        return []

    def sessions(self):
        return sorted(self.tmux("list-sessions", "-F", "#{session_name}").stdout.split())

    def test_it_starts_the_one_host_that_launches_a_session_per_task(self):
        launched = self.launch()
        self.assertEqual((launched.returncode, launched.stdout), (0, launched.stdout))
        spool = self.state / "enc-1"
        self.assertEqual(launched.stdout.splitlines()[:1], ["host: host-encargos arrancó"])
        self.assertEqual(self.sessions(), ["host-encargos"])
        [registro] = self.starts()
        lineas = registro[1]
        tope = lineas.index("OPENCLAW_BIN=/isolated/openclaw")
        self.assertEqual(lineas[:tope], [
            "scripts/agent-work/native_gateway.py", "--openclaw-bin", "/isolated/openclaw",
            "--host-id", "mac-local", "--expect-url", "ws://127.0.0.1:18789",
            "--host-state-dir", str(spool), "--state-root", str(self.state),
            "--evidence-root", str(self.state / "evidence"), "--progress-state-dir", str(self.root / "progress"),
            "--progress-client", str(self.root / "progress-events.py"), "--watch",
            "--cli-instance-id", "enc-1", "--cli-tmux-socket", self.socket, "--tmux-bin", TMUX,
            "--workspace-root", str(self.dev), "--opencode-bin", str(self.bin / "opencode"),
            "--slot-group", self.group])
        self.assertEqual(lineas[tope:tope + 3],
                         ["OPENCLAW_BIN=/isolated/openclaw", "LANG=en_US.UTF-8", f"PWD={ROOT}"])
        # Adenda G-sin-candados: sin carpeta de shims, avisa y arranca igual.
        self.assertEqual(lineas[tope + 3], f"PATH={os.environ['PATH']}")
        self.assertIn(f"no existen los shims de candados ({self.root / 'shims-que-no-estan'}); "
                      "el host corre sin ellos", launched.stderr)
        self.assertEqual(oct(spool.stat().st_mode & 0o777), "0o700")
        self.assertNotIn("AGENT_WORK_SUCESION_RUNTIME_SOURCE", (spool / "host-cmd.txt").read_text())

    def test_the_launched_host_carries_the_candados_shims_at_the_front_of_its_path(self):
        # Adenda G-sin-candados (2026-10-19): el entorno del proceso lanzado trae los shims de
        # quality-kit al frente del PATH.
        shims = self.root / "shims"
        shims.mkdir()
        launched = self.launch(AGENT_WORK_CANDADOS_SHIMS=str(shims))
        self.assertEqual(launched.returncode, 0)
        self.assertEqual(launched.stderr, "")
        [registro] = self.starts()
        linea_path = next(linea for linea in registro[1] if linea.startswith("PATH="))
        self.assertTrue(linea_path.startswith(f"PATH={shims}:"))
        self.assertTrue(linea_path.endswith(os.environ["PATH"]))

    def test_canario_reaches_the_host_and_a_second_run_reuses_it(self):
        launched = self.launch("--canario")
        self.assertEqual(launched.stdout.splitlines()[-1], "HOST enc-1 opencode sesión=host-encargos "
                         f"spool={self.state / 'enc-1'} grupo={self.group} canario")
        self.assertEqual(self.starts()[0][1][-6:-4], [self.group, "--canary"])
        again = self.launch("--canario")
        self.assertEqual((again.returncode, again.stdout.splitlines()[0]), (0, "host: host-encargos ya corre"))
        self.assertEqual(len(self.starts()), 1, "a second host started")

    def test_a_host_that_is_killed_is_back_within_seconds_with_another_pid(self):
        self.assertEqual(self.launch().returncode, 0)
        first = self.starts()[0][0]
        os.kill(first, 15)
        started = self.starts(2)
        self.assertEqual(len(started), 2, "the host did not come back")
        self.assertNotEqual(started[1][0], first)
        log = (self.state / "enc-1" / "host.log").read_text().splitlines()
        self.assertEqual(log, [f"host double {first} up", f"host double {started[1][0]} up"])
        self.assertEqual(self.sessions(), ["host-encargos"])

    def test_another_command_on_the_running_host_is_refused_and_nothing_changes(self):
        self.assertEqual(self.launch().returncode, 0)
        refused = self.launch("--canario")
        spool = self.state / "enc-1"
        self.assertEqual((refused.returncode, refused.stdout),
                         (1, ""))
        self.assertIn(f"lanzar-encargos: host-encargos ya corre con otro comando (ver {spool}/host-cmd.txt). "
                      f"Para cambiarlo, apágalo antes: {TMUX} -L {self.socket} kill-session "
                      "-t host-encargos", refused.stderr)
        self.assertEqual(len(self.starts()), 1)
        self.assertNotIn("--canary", (spool / "host-cmd.txt").read_text())

    def test_without_the_slot_group_it_says_the_command_an_administrator_runs_and_starts_nothing(self):
        refused = self.launch(AGENT_WORK_SLOT_GROUP="b22-grupo-que-no-existe")
        user = subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()
        self.assertEqual((refused.returncode, refused.stdout, refused.stderr), (2, "", (
            f"lanzar-encargos: el grupo b22-grupo-que-no-existe no existe o {user} no pertenece a él. Lo crea un "
            "administrador, una vez: sudo dseditgroup -o create b22-grupo-que-no-existe && sudo dseditgroup -o edit "
            f"-a {user} -t user b22-grupo-que-no-existe\n")))
        self.assertEqual((self.sessions(), self.state.exists()), ([], False))
        for args, env in ((["de-mas"], {}), ([], {"AGENT_WORK_OPENCODE": str(self.bin / "no-existe")}),
                          ([], {"AGENT_WORK_WORKSPACE_ROOT": str(self.root / "no-existe")})):
            self.assertEqual((self.launch(*args, **env).returncode, self.sessions()), (2, []))

    def test_an_agent_work_opencode_that_cannot_run_names_its_path_and_starts_nothing(self):
        """An explicit override never gets swapped for another binary: it is launched or its path
        is named, so a typo cannot quietly run a different opencode (CodeRabbit 4309456561)."""
        falso = self.bin / "path-falso"
        falso.mkdir()
        (falso / "opencode").write_text("#!/bin/sh\nexit 0\n")
        (falso / "opencode").chmod(0o755)
        roto = self.bin / "opencode-roto"
        roto.write_text("#!/bin/sh\nexit 0\n")
        refused = self.launch(PATH=f"{falso}:/usr/bin:/bin", AGENT_WORK_OPENCODE=str(roto))
        self.assertEqual((refused.returncode, refused.stderr),
                         (2, f"lanzar-encargos: no es ejecutable {roto}\n"))
        self.assertEqual(self.sessions(), [])

    def test_pasa_el_r_de_sucesion_por_flag_o_por_ambiente(self):
        por_flag = self.root / "runtime-flag"
        por_ambiente = self.root / "runtime-ambiente"
        por_flag.mkdir()
        por_ambiente.mkdir()
        primero = self.launch("--runtime-source", str(por_flag))
        self.assertEqual(primero.returncode, 0, primero.stderr)
        comando = (self.state / "enc-1" / "host-cmd.txt").read_text()
        self.assertIn(f"AGENT_WORK_SUCESION_RUNTIME_SOURCE={por_flag}", comando)
        self.assertEqual(self.tmux("kill-session", "-t", "host-encargos").returncode, 0)
        segundo = self.launch(AGENT_WORK_SUCESION_RUNTIME_SOURCE=str(por_ambiente))
        self.assertEqual(segundo.returncode, 0, segundo.stderr)
        self.assertIn(f"AGENT_WORK_SUCESION_RUNTIME_SOURCE={por_ambiente}",
                      (self.state / "enc-1" / "host-cmd.txt").read_text())

    def test_a_host_of_this_machine_outside_the_launcher_does_not_stop_it(self):
        """What the process table shows is not this launcher's business: the host itself locks its spool."""
        stray = subprocess.Popen(["python3", "-c", "import time; time.sleep(60)", "native_gateway.py", "--watch",
                                  "--cli-instance-id", "enc-1", "--workspace-root", str(self.dev)])
        self.addCleanup(stray.wait)
        self.addCleanup(stray.kill)
        self.assertEqual(self.launch().returncode, 0)
        self.assertEqual(len(self.starts()), 1)


if __name__ == "__main__":
    unittest.main()
