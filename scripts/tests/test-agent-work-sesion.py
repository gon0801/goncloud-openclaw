#!/usr/bin/env python3
"""The run-per-task route of B22: one opencode process per task, launched inside the slot's group.

Three layers. Launch: the argv, the environment, the launch script and what opencode said, with no host.
Decisions: whole passes of the pump over a backend that answers from a script, so the host's choices run
anywhere, CI included. Live: the same passes over a private tmux server, the real group agent-work-enc1 and
an opencode double that is a real process; skipped with its reason where that group does not exist.

No case reads or signals the machine's own host: each one has its checkout copy, state root, spool, opencode
double and tmux server. The live cases share one thing with a live host, the slot's group, and skip while
that group holds a process.
"""

import base64
import contextlib
import grp
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import replace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
sys.path.insert(0, str(ROOT / "scripts"))
import contexto  # noqa: E402
import encargo  # noqa: E402
import sesion  # noqa: E402
from contracts import HostBeat, OperationKey, RunDir, SessionRecord, operation_id  # noqa: E402
from host import Host  # noqa: E402
from modelos import ModelId, ProviderPolicy  # noqa: E402
from native_gateway import RunHost, fetch_brief, hold_spool, pump_once  # noqa: E402
from resources import BoundaryBusy, ResourceManager  # noqa: E402
from sesion import (BoundaryProcess, ClosureProof, GroupBoundaryBackend, ModelCall, PermissionDenied,  # noqa: E402
                    RunEvents, SessionExit, launch_script, opencode_argv, opencode_env, parse_boundary, read_events)
from spool import canonical, incident_identity  # noqa: E402
from sistema_agentes import contrato  # noqa: E402

EVIDENCE = Path("docs/evidence/agent-work")
LISTING = (ROOT / "scripts/tests/fixtures/agent-work/opencode/models-1.18.35.txt").read_text()
PSTACK = Path.home() / ".claude/plugins/cache/pstack-claude/pstack/0.9.84"
TMUX = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
GATEWAY = ROOT / "scripts/agent-work/native_gateway.py"
FAKE_R = ROOT / "scripts/tests/fixtures/agent-work/fake-r-host.py"
SLOT_GROUP = "agent-work-enc1"
DEFAULT = "zai-coding-plan/glm-5.3-flash"
LINE = ("Open assignment JSON at {}. First write agent-work.accept.v1 atomically to acceptRef with schema, hostId, "
        "taskId, generation, instanceId, claimId and capability copied from the assignment. Then follow briefRef "
        "and write agent-work.result.v1 atomically to resultRef. Keep every helper script and scratch file inside "
        "the directory that holds acceptRef, and touch nothing in /tmp or any other path outside it and "
        "workspaceRef: the CLI denies those commands.")
# Shapes measured on opencode 1.18.35 (docs/evidence/agent-work/B22-fase0.md: M3c, M2 and M6, M3b).
CREATED = ('timestamp=2026-10-13T00:57:58.663Z level=INFO run=18f0109d message=created id=ses_ecd3bd778ffe2Ws3LL1t3bfkl1 '
           'slug=witty-planet version=1.18.35 projectID=53a94db2 directory={} path="" workspaceID=undefined\n')
STREAM = ("timestamp=2026-10-13T00:57:58.866Z level=INFO run=18f0109d message=stream providerID={} modelID={} "
          "session.id=ses_ecd3bd778ffe2Ws3LL1t3bfkl1 small={} agent={} mode=primary\n")
DENIED = "\x1b[93m\x1b[1m! \x1b[0mpermission requested: external_directory ({}); auto-rejecting\n"
REJECTED = "The user rejected permission to use this specific tool call."
STAMP = 1791851313467

# One `run` per case name, read from the file `case` next to the double. It records what it was launched with
# before it does anything else.
OPENCODE_DOUBLE = r'''#!__PYTHON__
import hashlib, json, os, re, signal, sys, time

here = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
if args == ["--version"]:
    print(open(os.path.join(here, "version")).read().strip())
    sys.exit(0)
if args[:1] == ["models"]:
    sys.stdout.write(open(os.path.join(here, "listing")).read())
    sys.exit(0)
case = open(os.path.join(here, "case")).read().strip()
model = args[args.index("-m") + 1]


def note(name, value):
    with open(os.path.join(here, name + ".tmp"), "w") as stream:
        json.dump(value, stream)
    os.rename(os.path.join(here, name + ".tmp"), os.path.join(here, name))


def atomic(path, value):
    with open(path + ".tmp", "w") as stream:
        json.dump(value, stream)
    os.rename(path + ".tmp", path)


def event(kind, **fields):
    sys.stdout.write(json.dumps(dict(type=kind, timestamp=__STAMP__, sessionID="ses_doble", **fields)) + "\n")
    sys.stdout.flush()


def log(line):
    sys.stderr.write(line)
    sys.stderr.flush()


note("seen.json", {"argv": args, "PWD": os.environ.get("PWD"), "cwd": os.getcwd(), "rgid": os.getgid(),
                   "TMPDIR": os.environ.get("TMPDIR"), "scratch_mode": oct(os.stat(os.environ["TMPDIR"]).st_mode & 0o7777),
                   "pid": os.getpid(), "config": os.environ.get("OPENCODE_CONFIG_CONTENT"),
                   "managed": os.environ.get("AGENT_WORK_MANAGED"),
                   "autoupdate": os.environ.get("OPENCODE_DISABLE_AUTOUPDATE"),
                   "stdin_is_dev_null": os.path.samestat(os.fstat(0), os.stat("/dev/null"))})
if case == "error":
    event("error", error={"name": "UnknownError",
                          "data": {"message": "Unexpected server error. Check server logs for details."}})
    log('timestamp=2026-10-13T00:28:41.182Z level=ERROR run=b35d3b06 message=failed ref=err_c749d686 '
        'error="ProviderModelNotFoundError: Model not found: %s."\n' % model)
    sys.exit(1)
log(__CREATED__.format("/otra/carpeta" if case == "stray" else os.environ.get("PWD")))
provider, _, name = model.partition("/")
log(__STREAM__.format(provider, name, "true", "title"))
log(__STREAM__.format(provider, name, "false", "build"))
event("step_start", part={"type": "step-start"})
if case in ("hang", "stray"):
    time.sleep(300)
assignment = json.load(open(re.search(r"Open assignment JSON at (\S+)\. First", args[-1]).group(1)))
atomic(assignment["acceptRef"], assignment["protocol"]["accept"])
if case == "no-result":
    sys.exit(0)
if case == "hang-accepted":
    time.sleep(300)
if case == "denied":
    log(__DENIED__.format("/fuera/*"))
    event("tool_use", part={"type": "tool", "tool": "bash", "state": {
        "status": "error", "input": {"command": "mkdir -p /fuera"}, "error": __REJECTED__}})
    event("step_finish", part={"type": "step-finish", "reason": "tool-calls"})
    sys.exit(0)
if case in ("child", "stubborn-child"):
    if os.fork() == 0:
        os.setsid()
        if os.fork() == 0:
            if case == "stubborn-child":
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            note("child.json", {"pid": os.getpid(), "rgid": os.getgid()})
            os.execv("/bin/sleep", ["/bin/sleep", "300"]) if case == "child" else time.sleep(300)
        os._exit(0)
    while not os.path.exists(os.path.join(here, "child.json")):
        time.sleep(0.02)
content = b"hecho por el doble\n"
artifact = os.path.join(assignment["workspaceRef"], "b22-doble.txt")
with open(artifact, "wb") as stream:
    stream.write(content)
atomic(assignment["resultRef"], dict(assignment["protocol"]["result"], typedPayload={"evidenceRef": "b22-doble.txt"},
                                     artifactRef=artifact, digest=hashlib.sha256(content).hexdigest()))
event("text", part={"type": "text", "text": "listo"})
event("step_finish", part={"type": "step-finish", "reason": "stop"})
'''.replace("__PYTHON__", sys.executable).replace("__STAMP__", str(STAMP)).replace("__CREATED__", repr(CREATED)) \
    .replace("__STREAM__", repr(STREAM)).replace("__DENIED__", repr(DENIED)).replace("__REJECTED__", repr(REJECTED))


class FakeR:
    """The Gateway as this host sees it: one task on offer, replayed on every claim until its result or its
    cancellation, and a record of every call."""
    host_id = "mac-local"
    openclaw_bin = "/isolated/openclaw"

    def __init__(self):
        self.task = None
        self.claims, self.admits, self.reports, self.closures, self.incidents = [], [], [], [], []
        self.cancelled = {}

    def offer(self, task_id, brief, revision, generation=1, contract="ready.v1"):
        self.task = {"taskId": task_id, "brief": brief, "revision": revision, "generation": generation,
                     "contract": contract}

    def claim_host(self, adapter_id, instance_id):
        self.claims.append((adapter_id, instance_id))
        if self.task is None:
            return None
        task, digest = self.task, hashlib.sha256(self.task["brief"]).hexdigest()
        return {"hostId": self.host_id, "adapterId": adapter_id, "instanceId": instance_id, "taskId": task["taskId"],
                "generation": task["generation"], "claimId": f"claim-{task['taskId']}",
                "capability": {"taskId": task["taskId"], "generation": task["generation"], "producerId": adapter_id,
                               "token": f"CAPACIDAD-{task['taskId']}"},
                "assignment": {"target": {"kind": "cli", "hostId": self.host_id, "adapterId": adapter_id},
                               "inputRevision": task["revision"], "resultContract": task["contract"],
                               "instructionRef": {"ref": "artifact:" + digest, "digest": "sha256:" + digest}}}

    def brief_chunk(self, adapter_id, instance_id, task_id, claim_id, offset, length):
        brief = self.task["brief"]
        return {"taskId": task_id, "claimId": claim_id, "digest": "sha256:" + hashlib.sha256(brief).hexdigest(),
                "offset": offset, "size": len(brief),
                "dataBase64": base64.b64encode(brief[offset:offset + length]).decode()}

    def admit_host(self, assignment):
        self.admits.append(assignment["taskId"])
        return {"state": "host-admitted", "claimId": assignment["claimId"], "hostId": assignment["hostId"],
                "instanceId": assignment["instanceId"], "generation": assignment["generation"]}

    def report_host_result(self, result, artifact):
        self.reports.append((result["taskId"], artifact))
        self.task = None
        return {**{field: result[field] for field in ("hostId", "taskId", "generation", "instanceId", "producerId")},
                "resultId": hashlib.sha256(canonical(result).encode()).hexdigest(),
                "receiptId": f"rcpt-{result['taskId']}"}

    def close_host(self, assignment, state, reason, digest):
        self.closures.append((assignment["taskId"], state, reason, digest))
        return {"taskId": assignment["taskId"], "generation": assignment["generation"], "state": state,
                "evidenceDigest": digest}

    def cancel(self, task_id):
        self.cancelled[task_id] = f"cancel-{task_id}"
        self.task = None

    def host_cancellation(self, assignment):
        return self.cancelled.get(assignment["taskId"])

    def report_host_incident(self, assignment, incident):
        self.incidents.append((assignment["taskId"], incident["kind"], incident.get("episodeId")))
        incident_key, digest = incident_identity(assignment["generation"], incident)
        return {"taskId": assignment["taskId"], "generation": assignment["generation"], "incidentKey": incident_key,
                "incidentDigest": digest}

    def list_pending(self, after_task_id=None, limit=100):
        return []


class HostDied(BaseException):
    """Stops a pass where a host process would have died: nothing after it runs, as after SIGKILL."""


class ScriptedBackend:
    """A slot whose sessions, exits and boundary a case scripts. launch keeps the argv it would have run."""
    boot_id = "00000000-0000-0000-0000-000000000001"
    socket = "scripted"

    def __init__(self):
        self.sessions, self.left, self.launches, self.stops = {}, {}, [], []
        self.foreign = tuple
        self.survivors = ()
        self.dies = None
        self.last_closure = None

    def boundary(self):
        """foreign answers each read: a case can let a process appear between the claim and the launch."""
        return tuple(self.foreign())

    def launch(self, spec, nonce, argv, env):
        if self.boundary():
            raise BoundaryBusy(self.boundary())
        if self.dies == "before-launching":
            raise HostDied
        self.launches.append({"session": spec.session, "argv": argv, "env": env, "cwd": str(spec.workspace.root)})
        SessionRecord(spec.record).argv.write_text(json.dumps(list(argv)))
        self.sessions[spec.session] = {"bootId": self.boot_id, "nonce": nonce, "socket": self.socket,
                                       "sessionName": spec.session, "sessionId": f"${len(self.launches)}",
                                       "paneId": f"%{len(self.launches)}", "panePid": 4000 + len(self.launches)}
        if self.dies == "after-launching":
            raise HostDied

    def observe(self, session):
        return self.sessions.get(session)

    def exit_of(self, identity):
        if self.sessions.get(identity["sessionName"]) != identity:
            return SessionExit(None)
        return self.left.get(identity["sessionName"])

    def stop(self, identity):
        self.stops.append(identity["sessionName"])
        self.sessions.pop(identity["sessionName"], None)
        return True

    def _swept(self, before):
        self.last_closure = ClosureProof(True, True, tuple(before), tuple(f"SIGTERM {row.split()[0]}" for row in before),
                                         tuple(self.survivors))
        return self.last_closure.absent

    def prove_absent(self, identity):
        self.sessions.pop(identity["sessionName"], None)
        return self._swept(self.survivors)

    def prove_slot_empty(self):
        return self._swept(self.boundary() + tuple(self.survivors))


class Slot(unittest.TestCase):
    """One slot of a Mac that is not this one: a checkout with the repo's policy and coverage, a state root,
    an opencode double, a task repo under the operator's root, and the Gateway double."""
    CASE = "result"

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.checkout = self.root / "checkout"
        (self.checkout / EVIDENCE).mkdir(parents=True)
        for name in ("proveedores-permitidos.json", "coverage.json"):
            shutil.copy(ROOT / EVIDENCE / name, self.checkout / EVIDENCE / name)
        self.state = self.root / "state"
        self.spool = self.state / "enc-1"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "opencode").write_text(OPENCODE_DOUBLE)
        (self.bin / "opencode").chmod(0o755)
        (self.bin / "version").write_text("1.18.35\n")
        (self.bin / "listing").write_text(LISTING)
        (self.bin / "case").write_text(self.CASE)
        self.repo = self.root / "dev" / "demo"
        self.repo.mkdir(parents=True)
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        for command in (["init", "-q"], ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q",
                                         "--allow-empty", "-m", "base"]):
            subprocess.run(["git", "-C", str(self.repo), *command], check=True, env=env, capture_output=True)
        self.revision = {"kind": "code", "repository": str(self.repo), "sha": "a" * 40}
        self.r = FakeR()
        self.ahead = 0.0

    def start(self, backend, canary=False):
        """A host process over this slot: the first one, or the one that replaces a dead one."""
        self.backend = backend
        self.host = Host("mac-local", self.spool)
        self.manager = ResourceManager(self.host.spool, "mac-local", backend)
        self.run = RunHost(self.r, self.host, self.manager, backend, instance_id="enc-1", checkout=self.checkout,
                           state_root=self.state, opencode_bin=self.bin / "opencode", allowed_root=self.root / "dev",
                           canary=canary, clock=lambda: time.time() + self.ahead)

    def one_pass(self):
        """What the pump prints for one pass: its counts, or its error."""
        try:
            return pump_once(self.r, host=self.host, evidence_root=str(self.root / "evidence"),
                             progress_state_dir=str(self.root / "progress"), progress_client="unused",
                             cli_claim=self.run.claim, cli_watch=self.run.watch,
                             cli_release=self.manager.release_acknowledged,
                             cli_cancel=lambda: self.manager.release_cancelled(self.r.host_cancellation),
                             cli_retry=self.manager.retry_cleanup, cli_beat=self.run.beat)
        except (OSError, RuntimeError, ValueError) as error:
            return str(error)

    def changes(self):
        """One pass, as the counts that are not zero; or its error."""
        outcome = self.one_pass()
        return outcome if isinstance(outcome, str) else {name: count for name, count in outcome.items() if count}

    def operation(self, task_id="task-1"):
        return operation_id(OperationKey("mac-local", task_id, 1, "enc-1"))

    def run_dir(self, task_id="task-1"):
        return RunDir(self.spool / "runs" / self.operation(task_id))

    def record(self, task_id="task-1"):
        return SessionRecord.locate(self.spool, self.operation(task_id))

    def session(self, task_id="task-1"):
        return f"enc-{self.operation(task_id)[:12]}"

    def held(self, task_id="task-1"):
        """(operation status, resource state, resource reason) as the spool holds them."""
        with self.host.spool.connection() as db:
            row = db.execute("SELECT o.status,r.state,r.reason FROM resources r LEFT JOIN operations o "
                             "ON o.operation_id=r.operation_id WHERE r.operation_id=?",
                             (self.operation(task_id),)).fetchone()
        return tuple(row)

    def incidents(self):
        with self.host.spool.connection() as db:
            return [row[0] for row in db.execute("SELECT incident_key FROM incidents ORDER BY rowid")]

    def beat(self):
        return json.loads((self.state / "host.json").read_text())

    def estado(self, task_id="task-1"):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = encargo.main(["--checkout", str(self.checkout), "--state-root", str(self.state),
                                 "--opencode", str(self.bin / "opencode"), "estado", "--tarea", task_id])
        self.assertNotIn("CAPACIDAD", out.getvalue(), "estado printed the task's capability")
        return code, json.loads(out.getvalue())

    def cli_writes(self, task_id="task-1", result=True):
        """What a CLI that follows the assignment leaves in its run directory."""
        assignment = json.loads(self.run_dir(task_id).assignment.read_text())
        Path(assignment["acceptRef"]).write_text(json.dumps(assignment["protocol"]["accept"]))
        if result:
            artifact = Path(assignment["workspaceRef"]) / "hecho.txt"
            artifact.write_text("hecho\n")
            Path(assignment["resultRef"]).write_text(json.dumps({
                **assignment["protocol"]["result"], "typedPayload": {"evidenceRef": "hecho.txt"},
                "artifactRef": str(artifact), "digest": hashlib.sha256(b"hecho\n").hexdigest()}))

    def edit_policy(self, change):
        path = self.checkout / EVIDENCE / "proveedores-permitidos.json"
        document = json.loads(path.read_text())
        change(document)
        path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")


class Launch(Slot):
    def spec(self, brief=b"haz el saludo\n"):
        self.start(ScriptedBackend())
        operation = self.operation()
        return self.run.plan({"inputRevision": self.revision}, brief, run=RunDir.for_operation(self.spool, operation),
                             record=self.spool / "sessions" / operation, operation=operation)

    def test_the_task_travels_as_one_argument_and_the_argv_never_approves(self):
        spec = self.spec(b"agent-work.launch.v1\nmodel: zai-coding-plan/glm-5.3\n---\nhaz el saludo\n")
        argv = opencode_argv(spec, Path("/opt/homebrew/bin/opencode"), task_id="task-1")
        self.assertEqual(argv, ("/opt/homebrew/bin/opencode", "run", "-m", "zai-coding-plan/glm-5.3", "--format", "json",
                                "--print-logs", "--log-level", "INFO", "--title", "task-1",
                                LINE.format(self.spool / "runs" / self.operation() / "assignment.json")))
        for approving in ("--auto", "-i"):
            self.assertNotIn(approving, argv)
        with self.assertRaisesRegex(ValueError, "no empieza con guion"):
            opencode_argv(spec, Path("/opt/homebrew/bin/opencode"), task_id="--auto")

    def test_the_model_brief_py_writes_is_the_one_the_host_launches(self):
        instructions = self.root / "instructions"
        instructions.mkdir()
        done = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/agent-work/brief.py"), "--root",
                               str(instructions), "--host", "mac-local", "--adapter", "opencode",
                               "--model", "zai-coding-plan/glm-5.3"], input=b"haz el saludo\n", capture_output=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        digest = json.loads(done.stdout)["instructionRef"]["ref"].removeprefix("artifact:")
        argv = opencode_argv(self.spec((instructions / digest).read_bytes()), Path("/opt/homebrew/bin/opencode"),
                             task_id="task-1")
        self.assertEqual(argv[:4], ("/opt/homebrew/bin/opencode", "run", "-m", "zai-coding-plan/glm-5.3"))

    def test_the_environment_opens_the_task_folder_and_only_its_run_directory(self):
        spec = self.spec()
        env = opencode_env(spec)
        self.assertEqual(env["PWD"], str(self.repo))
        config = json.loads(env.pop("OPENCODE_CONFIG_CONTENT"))
        # Live canary A 2026-10-13: glm left its helper script in /tmp, `rm /tmp/…` was denied and the
        # session ended with the work done and no result. The scratch folder is inside the one allowed key.
        self.assertEqual(env, {"PWD": str(self.repo), "TMPDIR": f"{self.spool}/runs/{self.operation()}/tmp",
                               "OPENCODE_DISABLE_AUTOUPDATE": "1", "AGENT_WORK_MANAGED": "1"})
        self.assertEqual(config, {
            "permission": {"external_directory": {"*": "deny", f"{self.spool}/runs/{self.operation()}/**": "allow"}},
            "enabled_providers": ["zai-coding-plan"], "small_model": DEFAULT})
        # opencode applies the last rule that matches: the run directory has to come after the deny.
        self.assertEqual(list(config["permission"]["external_directory"].items()),
                         [("*", "deny"), (f"{self.spool}/runs/{self.operation()}/**", "allow")])
        token = opencode_env(self.spec(b"agent-work.launch.v1\nmodel: deepseek/deepseek-v4-pro\n---\n"))
        self.assertEqual(json.loads(token["OPENCODE_CONFIG_CONTENT"])["enabled_providers"], ["deepseek"])

    def launched(self, script, **environment):
        return subprocess.run(["/bin/sh"], input=script, capture_output=True, text=True, cwd="/",
                              env={**os.environ, **environment})

    def test_the_launch_script_fixes_folder_environment_and_streams_right_before_the_exec(self):
        spec = self.spec()
        spec.record.mkdir(parents=True)
        probe = ("import json, os, sys; print(json.dumps([os.environ['PWD'], os.getcwd(), os.environ['SECRET'], "
                 "os.path.samestat(os.fstat(0), os.stat('/dev/null')), sys.argv[1:]])); "
                 "print('a los logs', file=sys.stderr)")
        argv = (sys.executable, "-c", probe, "un argumento con 'comillas' y $HOME")
        script = launch_script(spec, argv, {"PWD": str(self.repo), "SECRET": "a b\n$(echo no)"}, os.getgid())
        done = self.launched(script, PWD="/otra/carpeta")
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))
        self.assertEqual(json.loads((spec.record / "events.jsonl").read_text()),
                         [str(self.repo), str(self.repo), "a b\n$(echo no)", True,
                          ["un argumento con 'comillas' y $HOME"]])
        self.assertEqual((spec.record / "stderr.log").read_text(), "a los logs\n")
        self.assertEqual(oct(spec.run.scratch.stat().st_mode & 0o7777), "0o700")

    def test_the_launch_script_runs_nothing_outside_the_slot_group_or_the_task_folder(self):
        spec = self.spec()
        spec.record.mkdir(parents=True)
        argv = ("/usr/bin/touch", str(self.root / "corrio"))
        outside_group = self.launched(launch_script(spec, argv, {}, os.getgid() + 1))
        self.assertEqual(outside_group.returncode, 98)
        gone = replace(spec, workspace=sesion.Workspace(self.root / "dev" / "borrada"))
        self.assertEqual(self.launched(launch_script(gone, argv, {}, os.getgid())).returncode, 97)
        spec.run.scratch.write_text("un archivo donde va la carpeta")
        self.assertEqual(self.launched(launch_script(spec, argv, {}, os.getgid())).returncode, 96)
        spec.run.scratch.unlink()
        self.assertFalse((self.root / "corrio").exists())
        self.assertEqual(self.launched(launch_script(spec, argv, {}, os.getgid())).returncode, 0)
        self.assertTrue((self.root / "corrio").exists())

    def write_run(self, events, stderr):
        record = SessionRecord.for_operation(self.spool, self.operation())
        record.events.write_text(events)
        record.stderr.write_text(stderr)
        return record.path

    # The two message=stream lines of B22-fase0.md:146-147, M1.
    TITLE_CALL = ("timestamp=2026-10-13T00:28:42.184Z level=INFO run=4a0a032c message=stream providerID=zai-coding-plan "
                  "modelID=glm-5.3-flash session.id=ses_ecd56a597ffe6GHqp405Otldki small=true agent=title mode=primary\n")
    BUILD_CALL = ("timestamp=2026-10-13T00:28:42.563Z level=INFO run=4a0a032c message=stream providerID=zai-coding-plan "
                  "modelID={} session.id=ses_ecd56a597ffe6GHqp405Otldki small=false agent={} mode=primary\n")

    def test_the_model_in_use_is_read_from_the_logs(self):
        asked = "zai-coding-plan/glm-5.3-flash"
        same = read_events(self.write_run("", self.TITLE_CALL + self.BUILD_CALL.format("glm-5.3-flash", "build")))
        self.assertEqual(sesion.model_in_use(same, asked), (asked, None))
        other = read_events(self.write_run("", self.TITLE_CALL + self.BUILD_CALL.format("glm-5.3-flash", "build")
                                           + self.BUILD_CALL.format("glm-5.3", "build")))
        self.assertEqual(sesion.model_in_use(other, asked),
                         (None, "opencode usó zai-coding-plan/glm-5.3 y se pidió zai-coding-plan/glm-5.3-flash"))
        # Only the title call, or only a child's: the session of the task never called the model.
        for stderr in (self.TITLE_CALL, self.BUILD_CALL.format("glm-5.3-flash", "poteto-agent"), ""):
            with self.subTest(stderr=stderr):
                self.assertEqual(sesion.model_in_use(read_events(self.write_run("", stderr)), asked),
                                 (None, "opencode no registró ninguna llamada"))
        self.assertEqual(sesion.model_in_use(same, None),
                         (None, "opencode usó zai-coding-plan/glm-5.3-flash y no se sabe qué se pidió"))
        self.assertEqual(sesion.model_in_use(None, asked), (None, "no se pueden leer los logs de opencode"))
        self.assertEqual(same.calls, (ModelCall("title", asked, True), ModelCall("build", asked, False)))

    def test_allowed_and_denied_evaluations_are_both_measured(self):
        said = read_events(self.write_run("", (
            "timestamp=2026-10-13T05:17:40.100Z level=INFO run=79db3a9f message=evaluated permission=bash "
            'pattern="touch b.txt" action.permission=* action.action=allow action.pattern=*\n'
            "timestamp=2026-10-13T05:17:45.444Z level=INFO run=838095b8 message=evaluated "
            "permission=external_directory pattern=/Users/dn/.agents/pstack-plataformas/* "
            "action.permission=external_directory action.pattern=* action.action=deny\n"
            "timestamp=2026-10-13T05:17:46.100Z level=INFO run=79db3a9f message=evaluated permission=bash "
            'pattern="ls" action.permission=* action.action=allow action.pattern=*\n')))
        self.assertEqual(said.evaluations, ("bash:allow", "external_directory:deny"))
        self.assertEqual(said.denied, (PermissionDenied("external_directory", "/Users/dn/.agents/pstack-plataformas/*"),))
        self.assertEqual(read_events(self.write_run("", "")).evaluations, ())

    def test_what_opencode_said_names_the_folder_the_providers_and_the_denied_permission(self):
        events = "".join(json.dumps(event) + "\n" for event in (
            {"type": "step_start", "timestamp": STAMP, "sessionID": "ses_1", "part": {"type": "step-start"}},
            {"type": "tool_use", "timestamp": STAMP + 5, "sessionID": "ses_1", "part": {
                "type": "tool", "tool": "bash", "state": {"status": "error", "error": REJECTED}}},
            {"type": "step_finish", "timestamp": STAMP + 9, "sessionID": "ses_1", "part": {"reason": "tool-calls"}}))
        stderr = ('timestamp=2026-10-13T00:57:58.532Z level=INFO run=18f0109d message="creating instance" directory=/otra\n'
                  + CREATED.format("/Users/dn/dev/demo")
                  + STREAM.format("zai-coding-plan", "glm-5.3-flash", "true", "title")
                  + STREAM.format("zai-coding-plan", "glm-5.3-flash", "false", "build") + DENIED.format("/tmp/fuera/*"))
        said = read_events(self.write_run(events + "esto no es JSON\n", stderr))
        self.assertEqual(said, RunEvents(
            first_at=STAMP / 1000, denied=(PermissionDenied("external_directory", "/tmp/fuera/*"),), error=None,
            session_directory="/Users/dn/dev/demo", providers_called=("zai-coding-plan",),
            tail=(*events.splitlines(), "esto no es JSON"), log_errors=(),
            calls=(ModelCall("title", "zai-coding-plan/glm-5.3-flash", True),
                   ModelCall("build", "zai-coding-plan/glm-5.3-flash", False)),
            evaluations=("external_directory:ask",)))
        self.assertEqual(sesion.session_directory(self.spool / "sessions" / self.operation()), "/Users/dn/dev/demo")
        # Measured on opencode 1.18.35 with the "deny" rule (B22-canarios.md, M7): the model gets the error
        # and the session goes on, so these come with a result as often as without one.
        by_rule = read_events(self.write_run(
            json.dumps({"type": "tool_use", "timestamp": STAMP, "part": {"type": "tool", "tool": "read", "state": {
                "status": "error", "error": sesion.DENIED_BY_RULE + " Here are some of the relevant rules [...]"}}}) + "\n",
            "timestamp=2026-10-13T05:17:45.444Z level=INFO run=838095b8 message=evaluated permission=external_directory "
            "pattern=/Users/dn/.agents/pstack-plataformas/* action.permission=external_directory action.pattern=* "
            "action.action=deny\n"
            "timestamp=2026-10-13T05:17:55.889Z level=INFO run=838095b8 message=evaluated permission=edit "
            "pattern=fin.txt action.permission=* action.action=allow action.pattern=*\n"))
        self.assertEqual(by_rule.denied, (PermissionDenied("external_directory", "/Users/dn/.agents/pstack-plataformas/*"),))
        only_in_the_flow = read_events(self.write_run(
            json.dumps({"type": "tool_use", "timestamp": STAMP, "part": {"type": "tool", "tool": "read", "state": {
                "status": "error", "error": sesion.DENIED_BY_RULE + " Here are some of the relevant rules [...]"}}}) + "\n", ""))
        self.assertEqual(only_in_the_flow.denied, (PermissionDenied("tool:read", ""),))
        without_the_line = read_events(self.write_run(events, CREATED.format('"/Users/dn/dev/con espacio"')))
        self.assertEqual((without_the_line.denied, without_the_line.session_directory),
                         ((PermissionDenied("tool:bash", ""),), "/Users/dn/dev/con espacio"))

    def test_the_cause_of_an_error_comes_from_the_logs_and_not_from_the_flow(self):
        flow = json.dumps({"type": "error", "timestamp": STAMP, "sessionID": "ses_1", "error": {
            "name": "UnknownError", "data": {"message": "Unexpected server error. Check server logs for details."}}}) + "\n"
        failed = ('timestamp=2026-10-13T00:28:41.182Z level=ERROR run=b35d3b06 message=failed ref=err_c749d686 '
                  'error="ProviderModelNotFoundError: Model not found: zai/glm-5.3. Did you mean: glm-5.3?"\n')
        said = read_events(self.write_run(flow, failed))
        self.assertEqual((said.error, said.log_errors, said.session_directory, said.providers_called),
                         ("ProviderModelNotFoundError: Model not found: zai/glm-5.3. Did you mean: glm-5.3?",
                          (failed.rstrip("\n"),), None, ()))
        self.assertEqual(read_events(self.write_run(flow, "")).error,
                         "Unexpected server error. Check server logs for details.")
        self.assertIsNone(read_events(self.spool / "sessions" / ("0" * 64)))
        self.assertIsNone(sesion.session_directory(self.spool / "sessions" / ("0" * 64)))


TABLE = """\
  {uid}   {gid}  8998 Tue Oct 13 00:58:21 2026     /bin/sleep 90
  {uid}    20  8999 Tue Oct 13 00:58:21 2026     /bin/zsh -l
  {other}   {gid}  9000 Tue Oct 13 00:58:21 2026     /bin/sleep 90
  {uid}   {gid}  9005 Tue Oct 13 00:58:22 2026     /bin/sh -c printf 'dos
  {uid}   {gid}     1 Tue Oct 13 00:00:00 2026 /sbin/launchd
lineas'
"""


class Boundary(unittest.TestCase):
    """The slot's process boundary over a process table a case writes: who is in it, and who gets a signal."""
    GID = 4242

    def setUp(self):
        self.uid = os.getuid()
        self.alive = {}
        self.sent = []
        self.ignore = set()

    def process(self, pid, lstart="Tue Oct 13 00:58:21 2026", command="/bin/sleep 90", gid=None):
        self.alive[pid] = (self.uid, self.GID if gid is None else gid, lstart, command)

    def table(self, pids=None):
        return "".join(f"  {uid}   {gid} {pid:5} {lstart}     {command}\n"
                       for pid, (uid, gid, lstart, command) in self.alive.items() if pids is None or pid in pids)

    def kill(self, pid, sent):
        self.sent.append((pid, sent.name))
        if pid not in self.alive:
            raise ProcessLookupError
        if sent == signal.SIGKILL or pid not in self.ignore:
            del self.alive[pid]

    def backend(self, kill=None, process=None):
        return GroupBoundaryBackend("tmux-not-used", "b22f2-boundary", "any-group", "boot-1", gid=self.GID,
                                    grace_seconds=0.3, table=self.table, kill=kill or self.kill,
                                    process=process or (lambda pid: self.table({pid})), sleep=lambda _: None)

    def test_the_boundary_is_this_users_processes_whose_real_group_is_the_slots(self):
        table = TABLE.format(uid=self.uid, gid=self.GID, other=self.uid + 1)
        self.assertEqual(parse_boundary(table, self.uid, self.GID), (
            BoundaryProcess(8998, "Tue Oct 13 00:58:21 2026", "/bin/sleep 90"),
            BoundaryProcess(9005, "Tue Oct 13 00:58:22 2026", "/bin/sh -c printf 'dos"),
            BoundaryProcess(1, "Tue Oct 13 00:00:00 2026", "/sbin/launchd")),
            "a row forged inside another command's argv can only add a process to the boundary")
        self.assertEqual(str(parse_boundary(table, self.uid, self.GID)[0]), "8998 Tue Oct 13 00:58:21 2026 /bin/sleep 90")
        self.assertEqual(parse_boundary(table, self.uid, 20),
                         (BoundaryProcess(8999, "Tue Oct 13 00:58:21 2026", "/bin/zsh -l"),))

    def test_a_sweep_terms_then_kills_and_proves_the_slot_empty(self):
        self.process(700)
        self.process(701, command="python3 terco.py")
        self.process(702, gid=20)
        self.ignore = {701}
        backend = self.backend()
        self.assertTrue(backend.prove_slot_empty())
        self.assertEqual(self.sent, [(700, "SIGTERM"), (701, "SIGTERM"), (701, "SIGKILL")])
        self.assertEqual(backend.last_closure, ClosureProof(
            pane_gone=True, session_gone=True,
            boundary_before=("700 Tue Oct 13 00:58:21 2026 /bin/sleep 90", "701 Tue Oct 13 00:58:21 2026 python3 terco.py"),
            signals=("SIGTERM 700", "SIGTERM 701", "SIGKILL 701"), boundary_after=()))
        self.assertEqual(sorted(self.alive), [702], "a process outside the slot's group got a signal")

    def test_a_survivor_of_the_sweep_is_never_reported_as_absence(self):
        self.process(700)
        backend = self.backend(kill=lambda pid, sent: self.sent.append((pid, sent.name)))
        self.assertFalse(backend.prove_slot_empty())
        self.assertEqual(self.sent, [(700, "SIGTERM"), (700, "SIGKILL")])
        self.assertEqual((backend.last_closure.absent, backend.last_closure.boundary_after),
                         (False, ("700 Tue Oct 13 00:58:21 2026 /bin/sleep 90",)))
        self.assertFalse(ClosureProof(True, False, (), (), ()).absent)
        self.assertFalse(ClosureProof(False, True, (), (), ()).absent)
        self.assertTrue(ClosureProof(True, True, ("700 x",), ("SIGTERM 700",), ()).absent)

    def test_a_signal_goes_only_to_a_pid_whose_group_and_birth_were_just_confirmed(self):
        self.process(700)
        self.process(701)
        truth = {700: self.table({700}).replace("00:58:21", "00:59:59"),
                 701: self.table({701}).replace(f" {self.GID} ", " 20 ")}
        backend = self.backend(process=truth.__getitem__)
        self.assertFalse(backend.prove_slot_empty())
        self.assertEqual(self.sent, [], "a reused pid, or one that left the group, got a signal")

    def test_the_slot_group_is_never_the_hosts_own_or_one_the_user_is_not_in(self):
        with self.assertRaisesRegex(ValueError, "cannot be the host's own group"):
            GroupBoundaryBackend("tmux", "b22f2-boundary", "any-group", "boot-1", gid=os.getgid())
        with self.assertRaisesRegex(ValueError, "slot group b22-no-existe does not exist"):
            GroupBoundaryBackend("tmux", "b22f2-boundary", "b22-no-existe", "boot-1")
        foreign = next((entry.gr_name for entry in grp.getgrall()
                        if entry.gr_gid != os.getgid() and not entry.gr_mem), None)
        if foreign is not None:
            with self.assertRaisesRegex(ValueError, f"not a member of the slot group {foreign}"):
                GroupBoundaryBackend("tmux", "b22f2-boundary", foreign, "boot-1")


class Decisions(Slot):
    """Whole passes of the pump. The CLI is the case itself: it writes what a session would, and says when the
    process left."""

    def setUp(self):
        super().setUp()
        self.start(ScriptedBackend())
        self.r.offer("task-1", b"haz el saludo\n", self.revision)

    def launched(self):
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.assertEqual(len(self.backend.launches), 1)

    def left(self, code, task_id="task-1"):
        self.backend.left[self.session(task_id)] = SessionExit(code)

    def test_a_claimed_task_launches_its_own_process_with_the_default_model(self):
        self.assertEqual(self.one_pass(), {"reported": 0, "released": 0, "cancelled": 0, "recovered": 0, "closed": 0,
                                           "transferred": 0, "published": 0, "incidents": 0, "claimed": 1,
                                           "detected": 0})
        run = self.run_dir()
        self.assertEqual(self.backend.launches, [{
            "session": self.session(), "cwd": str(self.repo),
            "argv": (str(self.bin / "opencode"), "run", "-m", DEFAULT, "--format", "json", "--print-logs", "--log-level",
                     "INFO", "--title", "task-1", LINE.format(run.assignment)),
            "env": {"PWD": str(self.repo), "TMPDIR": str(run.path / "tmp"), "OPENCODE_DISABLE_AUTOUPDATE": "1",
                    "AGENT_WORK_MANAGED": "1",
                    "OPENCODE_CONFIG_CONTENT": json.dumps({
                        "permission": {"external_directory": {"*": "deny", f"{run.path}/**": "allow"}},
                        "enabled_providers": ["zai-coding-plan"], "small_model": DEFAULT}, separators=(",", ":"))}}])
        self.assertEqual((self.r.claims, self.r.admits), ([("opencode", "enc-1")], ["task-1"]))
        self.assertEqual(self.held(), ("attempted", "Running", ""))
        self.assertEqual(sorted(path.name for path in run.path.iterdir()), ["assignment.json", "brief"])
        self.assertEqual([oct(path.stat().st_mode & 0o777) for path in (run.path, run.assignment, run.brief)],
                         ["0o700", "0o400", "0o400"])
        self.assertEqual(run.brief.read_bytes(), b"haz el saludo\n")
        assignment = json.loads(run.assignment.read_text())
        self.assertEqual({name: assignment[name] for name in ("workspaceRef", "briefRef", "acceptRef", "resultRef")},
                         {"workspaceRef": str(self.repo), "briefRef": str(run.brief), "acceptRef": str(run.accept),
                          "resultRef": str(run.result)})
        self.assertFalse((self.repo / "managed-briefs").exists(), "the brief landed in the task's repo")
        self.assertEqual(self.one_pass()["claimed"], 1, "the replayed claim stopped being answered")
        self.assertEqual((len(self.backend.launches), self.r.admits), (1, ["task-1"]), "a replayed claim launched again")

    def test_the_beat_says_who_decides_and_what_the_slot_holds(self):
        self.r.task = None
        self.one_pass()
        policy = ProviderPolicy.load(self.checkout / EVIDENCE / "proveedores-permitidos.json")
        beat = self.beat()
        self.assertLess(abs(beat.pop("beatAt") - time.time()) + abs(beat.pop("startedAt") - time.time()), 10)
        self.assertEqual(beat, {"pid": os.getpid(), "checkout": str(self.checkout), "commit": "unknown",
                                "cliVersion": "1.18.35", "policyDigest": policy.digest, "slot": "free", "blockedBy": [],
                                "taskId": None, "model": None, "since": None, "spool": str(self.spool), "canary": False})
        self.assertEqual(HostBeat.read(self.state).spool, str(self.spool))
        self.r.offer("task-1", b"agent-work.launch.v1\nmodel: deepseek/deepseek-v4-pro\n---\nhaz el saludo\n",
                     self.revision)
        self.one_pass()
        self.one_pass()
        beat = self.beat()
        self.assertLess(time.time() - beat["since"], 10)
        self.assertEqual((beat["slot"], beat["taskId"], beat["model"]), ("running", "task-1", "deepseek/deepseek-v4-pro"))
        self.edit_policy(lambda document: document["providers"].pop())
        self.one_pass()
        self.assertNotEqual(self.beat()["policyDigest"], policy.digest, "a pull of the checkout needed a relaunch")

    def test_a_result_is_reported_and_the_slot_frees_once_its_boundary_is_proven_empty(self):
        self.launched()
        self.cli_writes()
        self.left(0)
        self.backend.survivors = ("4321 Tue Oct 13 00:58:21 2026 /bin/sleep 300",)
        self.assertEqual(self.one_pass(), {"reported": 1, "released": 0, "cancelled": 0, "recovered": 0, "closed": 1,
                                           "transferred": 0, "published": 0, "incidents": 0, "claimed": 0,
                                           "detected": 0}, "a survivor in the boundary counted as a released slot")
        self.assertEqual(self.r.reports, [("task-1", b"hecho\n")])
        self.assertEqual(self.held(), ("acknowledged", "CleanupPending", "descendant absence unverified"))
        claims = len(self.r.claims)
        self.assertEqual(self.changes(), {})
        self.assertEqual(len(self.r.claims), claims, "the host asked for work with a survivor in its slot")
        self.assertEqual(self.beat()["slot"], "running")
        self.backend.survivors = ()
        self.assertEqual(self.changes(),
                         {"recovered": 1, "closed": 1})
        self.assertEqual(self.held(), ("acknowledged", "AbsenceVerified", ""))

        def digest(survivors):
            return hashlib.sha256(canonical({
                "evidence": {"kind": "result", "receipt": "rcpt-task-1"},
                "proof": {"pane_gone": True, "session_gone": True, "boundary_before": survivors,
                          "signals": [f"SIGTERM {row.split()[0]}" for row in survivors],
                          "boundary_after": survivors}}).encode()).hexdigest()

        self.assertEqual(self.r.closures, [
            ("task-1", "CleanupPending", "descendant absence unverified",
             digest(["4321 Tue Oct 13 00:58:21 2026 /bin/sleep 300"])),
            ("task-1", "AbsenceVerified", "", digest([]))])
        self.assertEqual(self.estado(), (0, {
            "ok": True, "tarea": "task-1", "modelo": DEFAULT, "cobro": "subscription", "estado": "acknowledged",
            "cierre": "AbsenceVerified", "explicacion": None, "permisosNegados": [], "proveedoresLlamados": [],
            "carpetaDeSesion": None, "salida": None, "logTail": [],
            # SUA-03: a run without a package has no flota.v1, and the double wrote no logs.
            "modeloUsado": None, "modeloUsadoRazon": "no se pueden leer los logs de opencode", "permisos": [],
            "flota": None}))
        self.r.offer("task-2", b"otro\n", self.revision)
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.assertEqual((self.beat()["slot"], len(self.backend.launches)), ("free", 2))

    def stream(self, model, agent, small="false"):
        provider, _, name = model.partition("/")
        return (f"timestamp=2026-10-13T00:28:42.563Z level=INFO run=4a0a032c message=stream providerID={provider} "
                f"modelID={name} session.id=ses_ecd56a597ffe6GHqp405Otldki small={small} agent={agent} mode=primary\n")

    def packaged(self, profile="ingenieria"):
        """What G3's launcher leaves for a run with a package: the copy in the run, and what the host
        recorded of it at launch."""
        run = self.run_dir()
        run.context.mkdir(parents=True, exist_ok=True)
        (run.context / "poteto.v1.json").write_text(json.dumps({"generation": 1}))
        perfil = contexto.perfil(contexto.leer_json(contexto.PERFILES), profile)
        (run.context / "perfil.json").write_bytes(contexto.canonico(perfil))
        record = self.record()
        record.context.parent.mkdir(parents=True, exist_ok=True)
        record.context.write_text(json.dumps({
            "poteto": "sha256:" + "a" * 64, "tools": "sha256:" + "b" * 64,
            "writesSource": perfil["writesSource"], "specialist": perfil["id"], "generation": 1,
            "profile": contexto.digest_de_perfil(perfil)}))
        return perfil

    def checkout_contexto(self):
        """The checkout a G3 host reads: the package files next to its policy and coverage."""
        destino = self.checkout / "scripts" / "agent-work" / "contexto"
        destino.mkdir(parents=True)
        for name in ("poteto.v1.json", "generaciones.json", "perfiles.v1.json"):
            shutil.copy(ROOT / "scripts/agent-work/contexto" / name, destino / name)

    @unittest.skipUnless(PSTACK.is_dir(), "pide pstack 0.9.84 instalado en esta Mac")
    def test_a_profile_whose_source_expired_by_the_hosts_clock_is_refused_even_by_a_canary(self):
        # context.admite does not skip an expired source for a canary, and the clock it judges with is
        # the host's (SUA-03, 4.4): the sources of every profile expire on 2027-01-14.
        self.checkout_contexto()
        self.start(ScriptedBackend(), canary=True)
        self.ahead = 100 * 24 * 3600.0
        self.r.offer("task-1", b"agent-work.launch.v1\nprofile: ingenieria\n---\nhaz el saludo\n", self.revision)
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.assertEqual(self.backend.launches, [], "a profile whose source expired never launched")
        _, answer = self.estado()
        self.assertEqual(answer["explicacion"]["causa"], "perfil-sin-competencia")
        self.assertIn("venció", answer["explicacion"]["frase"])

    @unittest.skipUnless(PSTACK.is_dir(), "pide pstack 0.9.84 instalado en esta Mac")
    def test_a_package_source_that_drifted_is_refused_and_launches_nothing(self):
        self.checkout_contexto()
        drifted = self.root / "pstack"
        shutil.copytree(PSTACK, drifted)
        (drifted / "skills/how/SKILL.md").write_text("otra cosa\n")
        with mock.patch.object(contexto, "fuente_del_paquete", lambda manifest, plugins=None: drifted):
            self.start(ScriptedBackend(), canary=True)
            self.r.offer("task-1", b"agent-work.launch.v1\nprofile: ingenieria\n---\nhaz el saludo\n", self.revision)
            self.assertEqual(self.one_pass()["claimed"], 1)
            self.assertEqual(self.backend.launches, [], "a source that differs from the manifest never launched")
            self.assertFalse(self.run_dir().context.exists(), "nothing was copied either")
            _, answer = self.estado()
            self.assertEqual(answer["explicacion"]["causa"], "contexto-incompleto")
            self.assertIn("skills/how/SKILL.md", answer["explicacion"]["frase"])

    def git_out(self, *args):
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        done = subprocess.run(["git", *args], capture_output=True, text=True, env=env, check=True)
        return done.stdout.strip()

    @unittest.skipUnless(PSTACK.is_dir(), "pide pstack 0.9.84 instalado en esta Mac")
    def test_a_profiled_task_launches_with_its_package_and_a_reviewer_in_a_clone(self):
        self.checkout_contexto()
        self.start(ScriptedBackend(), canary=True)
        self.r.offer("task-1", b"agent-work.launch.v1\nprofile: ingenieria\n---\nhaz el saludo\n", self.revision)
        self.launched()
        run = self.run_dir()
        config = json.loads(self.backend.launches[0]["env"]["OPENCODE_CONFIG_CONTENT"])
        self.assertEqual(config["instructions"], [str(run.context / "AGENTS.md")])
        self.assertEqual(config["skills"], {"paths": [str(run.context / "skills")]})
        self.assertEqual(config["agent"], {name: {"model": DEFAULT} for name in sesion.LOCAL_AGENTS})
        self.assertEqual(sorted(path.name for path in run.context.iterdir()),
                         ["AGENTS.md", "perfil.json", "poteto.v1.json", "skills"])
        digests = json.loads(self.record().context.read_text())
        self.assertEqual(set(digests), {"poteto", "tools", "writesSource", "specialist", "generation", "profile"})
        self.assertEqual((digests["writesSource"], digests["specialist"], digests["generation"]),
                         (True, "ingenieria", 1))
        # What the host annotated is the digest of the copy it read back, not a value it made up (4.5).
        self.assertEqual(digests["poteto"], contexto.digest_del_paquete(run.context))
        self.cli_writes()
        self.left(0)
        self.backend.survivors = ("4321 Tue Oct 13 00:58:21 2026 /bin/sleep 300",)
        self.one_pass()
        self.backend.survivors = ()
        self.one_pass()
        flota = json.loads(run.fleet.read_text())
        self.assertEqual(flota["specialist"], "ingenieria")
        self.assertEqual(flota["attestations"][0], {"what": "poteto", "digest": digests["poteto"]})
        self.assertEqual(flota["attestations"][2]["digest"], digests["tools"])

        revision = {"kind": "code", "repository": str(self.repo),
                    "sha": self.git_out("-C", str(self.repo), "rev-parse", "HEAD")}
        self.r.offer("task-2", b"agent-work.launch.v1\nprofile: revision\n---\nrevisa\n", revision,
                     contract="review.v1")
        self.assertEqual(self.one_pass()["claimed"], 1)
        run2, clone = self.run_dir("task-2"), self.run_dir("task-2").repo
        self.assertEqual(self.git_out("-C", str(clone), "rev-parse", "HEAD"), revision["sha"])
        self.assertEqual(self.git_out("-C", str(clone), "remote"), "", "the reviewer's clone has no origin")
        common = self.git_out("-C", str(clone), "rev-parse", "--git-common-dir")
        self.assertNotIn(str(self.repo), common, "the reviewer's clone shares nothing with the real .git")
        # --no-hardlinks (4.8): no object file of the clone is the same inode as one of the real repo,
        # or the session's shell would be writing the real repo's objects through the clone.
        real_inodes = {path.stat().st_ino for path in (self.repo / ".git/objects").rglob("*") if path.is_file()}
        cloned_objects = [path for path in (clone / ".git/objects").rglob("*") if path.is_file()]
        self.assertTrue(cloned_objects, "the clone has no objects to compare")
        self.assertFalse({path.stat().st_ino for path in cloned_objects} & real_inodes,
                         "a clone object shares an inode with the real repo")
        launched2 = self.backend.launches[1]
        self.assertEqual((launched2["cwd"], launched2["env"]["PWD"]), (str(clone), str(clone)))
        digests2 = json.loads(self.record("task-2").context.read_text())
        self.assertEqual(digests2["writesSource"], False, "the reviewer's run may not write source")
        assignment2 = json.loads(run2.assignment.read_text())
        self.assertEqual(assignment2["workspaceRef"], str(clone))
        photo = json.loads(self.record("task-2").repo_before.read_text())
        self.assertEqual(photo["repo"], str(self.repo), "the photo is of the real repo, not of the clone")
        artifact = run2.path / "hallazgos.md"
        artifact.write_text("sin hallazgos\n")
        Path(assignment2["acceptRef"]).write_text(json.dumps(assignment2["protocol"]["accept"]))
        Path(assignment2["resultRef"]).write_text(json.dumps({
            **assignment2["protocol"]["result"], "typedPayload": {"verdict": "approved"},
            "artifactRef": str(artifact), "digest": hashlib.sha256(b"sin hallazgos\n").hexdigest()}))
        self.left(0, "task-2")
        self.backend.survivors = ("4321 Tue Oct 13 00:58:21 2026 /bin/sleep 300",)
        self.one_pass()
        self.assertTrue(clone.exists(), "the clone died before its run was proven absent")
        self.backend.survivors = ()
        self.one_pass()
        self.assertEqual((self.r.reports[-1][0], self.held("task-2")[1]), ("task-2", "AbsenceVerified"))
        self.assertFalse(clone.exists(), "the clone survives its own closure")

    def test_a_run_with_a_package_leaves_its_flota_document_when_it_closes(self):
        self.launched()
        perfil = self.packaged()
        record = self.record()
        record.events.write_text("")
        record.stderr.write_text(
            self.stream(DEFAULT, "title", "true") + self.stream(DEFAULT, "build")
            + self.stream("zai-coding-plan/glm-5.3", "poteto-agent")
            + "timestamp=2026-10-13T05:17:40.100Z level=INFO run=79db3a9f message=evaluated permission=bash "
              'pattern="ls" action.permission=* action.action=allow action.pattern=*\n')
        self.cli_writes()
        self.left(0)
        self.backend.survivors = ("4321 Tue Oct 13 00:58:21 2026 /bin/sleep 300",)
        self.one_pass()
        self.assertEqual(self.held(), ("acknowledged", "CleanupPending", "descendant absence unverified"))
        self.assertFalse(self.run_dir().fleet.exists(), "flota.json was written before the absence was proven")
        self.backend.survivors = ()
        self.one_pass()
        self.assertEqual(self.held(), ("acknowledged", "AbsenceVerified", ""))
        written = json.loads(self.run_dir().fleet.read_text())
        self.assertEqual(written, {
            "schema": "sistema-agentes.flota.v1", "rootId": "task-1", "unitId": "task-1", "attempt": 1,
            "specialist": "ingenieria", "host": "mac-local", "executor": "opencode", "accountRef": "glm",
            "model": {"id": DEFAULT}, "generation": 1, "permissions": ["bash:allow"],
            "attestations": [{"what": "poteto", "digest": "sha256:" + "a" * 64},
                             {"what": "profile", "digest": contexto.digest_de_perfil(perfil)},
                             {"what": "tools", "digest": "sha256:" + "b" * 64}],
            "children": [{"agent": "poteto-agent", "model": "zai-coding-plan/glm-5.3"}]})
        self.assertEqual(contrato.validar(written), [])
        self.assertEqual(self.estado()[1]["flota"], written)
        # What was launched does not change: a later pass does not rewrite the document.
        record.stderr.write_text(self.stream("zai-coding-plan/glm-5.3", "build"))
        self.one_pass()
        self.assertEqual(json.loads(self.run_dir().fleet.read_text()), written)

    def test_a_model_the_provider_swapped_is_named_in_flota_and_estado(self):
        self.launched()
        self.packaged("revision")
        record = self.record()
        record.events.write_text("")
        record.stderr.write_text(self.stream("zai-coding-plan/glm-5.3", "build"))
        # SUA-03: a revision profile does not write source, so its artifact lives in the run folder.
        assignment = json.loads(self.run_dir().assignment.read_text())
        artifact = self.run_dir().path / "hallazgos.txt"
        artifact.write_text("hecho\n")
        Path(assignment["acceptRef"]).write_text(json.dumps(assignment["protocol"]["accept"]))
        Path(assignment["resultRef"]).write_text(json.dumps({
            **assignment["protocol"]["result"], "typedPayload": {"evidenceRef": "hallazgos.txt"},
            "artifactRef": str(artifact), "digest": hashlib.sha256(b"hecho\n").hexdigest()}))
        self.left(0)
        self.one_pass()
        self.one_pass()
        reason = f"opencode usó zai-coding-plan/glm-5.3 y se pidió {DEFAULT}"
        written = json.loads(self.run_dir().fleet.read_text())
        self.assertEqual((written["model"], written["specialist"], written["permissions"], written["children"]),
                         ({"id": None, "reason": reason}, "revision", [], []))
        self.assertEqual(contrato.validar(written), [])
        _, answer = self.estado()
        self.assertEqual((answer["modelo"], answer["modeloUsado"], answer["modeloUsadoRazon"]), (DEFAULT, None, reason))

    def test_estado_names_the_providers_refusal_that_was_measured(self):
        for said, cause in (("The usage limit has been reached.", "proveedor-sin-cuota"),
                            ("Your current subscription plan does not yet include access to GLM-5.3-Highspeed.",
                             "proveedor-sin-modelo"),
                            ("Session expired, sign in again.", "launch-failed")):
            with self.subTest(cause=cause):
                self.setUp()
                self.launched()
                record = self.record()
                record.events.write_text(json.dumps({"type": "error", "timestamp": STAMP, "error": {
                    "name": "APIError", "data": {"message": said}}}) + "\n")
                record.stderr.write_text("")
                self.left(1)
                self.assertEqual(self.one_pass()["detected"], 1)
                _, answer = self.estado()
                self.assertEqual((answer["explicacion"]["causa"], answer["explicacion"]["accion"]),
                                 (cause, "cancelar"))
                self.assertTrue(answer["explicacion"]["frase"].startswith(
                    f"opencode salió sin acusar recibo. opencode dijo: {said}."), answer["explicacion"]["frase"])

    def git(self, *args):
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                        *args], check=True, env=env, capture_output=True)

    def review_writes(self, artifact):
        """What a reviewer that follows the assignment leaves: its acceptance, artifact and result."""
        assignment = json.loads(self.run_dir().assignment.read_text())
        Path(assignment["acceptRef"]).write_text(json.dumps(assignment["protocol"]["accept"]))
        artifact.write_text("sin hallazgos\n")
        Path(assignment["resultRef"]).write_text(json.dumps({
            **assignment["protocol"]["result"], "typedPayload": {"verdict": "approved"},
            "artifactRef": str(artifact), "digest": hashlib.sha256(b"sin hallazgos\n").hexdigest()}))
        return assignment

    def test_a_profile_the_session_edited_decides_nothing(self):
        # runs/<op>/ is the one folder the session may write (B22-S7): whether its run may write the repo
        # is what the host recorded in sessions/<op>, which the session cannot reach (SUA-03, 4.8).
        self.r.offer("task-1", b"revisa el saludo\n", self.revision, contract="review.v1")
        self.packaged("revision")
        perfil_path = self.run_dir().context / "perfil.json"
        perfil = json.loads(perfil_path.read_text())
        perfil["writesSource"] = True
        perfil_path.write_bytes(contexto.canonico(perfil))
        self.launched()
        (self.repo / "nuevo.py").write_text("escrito por el revisor\n")
        self.review_writes(self.run_dir().path / "hallazgos.md")
        self.left(0)
        self.one_pass()
        self.assertEqual(self.r.reports, [], "a flipped profile in the run copy changed nothing")
        self.assertEqual(self.r.incidents, [("task-1", "invalid-result", "reviewer-wrote-source")])

    def test_a_review_artifact_lives_in_the_run_folder(self):
        self.r.offer("task-1", b"revisa el saludo\n", self.revision, contract="review.v1")
        self.launched()
        assignment = self.review_writes(self.run_dir().path / "hallazgos.md")
        self.assertEqual(assignment["protocol"]["fill"]["artifactRef"],
                         "the absolute path of the artifact file, inside the directory that holds resultRef, "
                         "never inside workspaceRef")
        self.left(0)
        self.one_pass()
        self.assertEqual(self.r.reports, [("task-1", b"sin hallazgos\n")])
        self.assertEqual(self.r.incidents, [])

    def test_a_review_artifact_in_the_repo_is_refused(self):
        # A review without a profile works in the real repo, so its photo is the G2 one, without ignored
        # files: the ignored artifact does not move it, and what refuses it is where the artifact is.
        # The location rule stays as the belt for a run whose photo never existed, too.
        (self.repo / ".gitignore").write_text("hallazgos.md\n")
        self.git("add", ".gitignore")
        self.git("commit", "-q", "-m", "ignora")
        self.r.offer("task-1", b"revisa el saludo\n", self.revision, contract="review.v1")
        self.launched()
        self.review_writes(self.repo / "hallazgos.md")
        self.left(0)
        self.one_pass()
        self.assertEqual(self.r.reports, [])
        self.assertEqual(self.r.incidents, [("task-1", "invalid-result", "invalid-result")])
        # A run whose host never photographed its repo is still refused for where the artifact is.
        self.setUp()
        (self.repo / ".gitignore").write_text("hallazgos.md\n")
        self.git("add", ".gitignore")
        self.git("commit", "-q", "-m", "ignora")
        self.r.offer("task-1", b"revisa el saludo\n", self.revision, contract="review.v1")
        self.launched()
        self.record().repo_before.unlink()
        self.review_writes(self.repo / "hallazgos.md")
        self.left(0)
        self.one_pass()
        self.assertEqual(self.r.reports, [])
        self.assertEqual(self.r.incidents, [("task-1", "invalid-result", "invalid-result")])

    def test_a_reviewer_that_changed_the_real_repo_has_its_result_refused(self):
        self.r.offer("task-1", b"revisa el saludo\n", self.revision, contract="review.v1")
        self.launched()
        before = json.loads(self.record().repo_before.read_text())
        self.assertEqual((before["repo"], set(before["photo"])),
                         (str(self.repo), {"head", "refs", "status", "diff", "config", "hooks", "exclude"}))
        (self.repo / "nuevo.py").write_text("escrito por el revisor\n")
        self.review_writes(self.run_dir().path / "hallazgos.md")
        self.left(0)
        self.one_pass()
        self.assertEqual(self.r.reports, [])
        self.assertEqual(self.r.incidents, [("task-1", "invalid-result", "reviewer-wrote-source")])
        _, answer = self.estado()
        self.assertEqual(answer["explicacion"], {
            "causa": "reviewer-wrote-source", "accion": "cancelar",
            "frase": "El revisor dejó cambiado el repo del encargo, y el host no aceptó su resultado. "
                     f"En {self.repo} cambió el status. El host no deshizo nada."})
        self.assertTrue((self.repo / "nuevo.py").exists(), "the host undid what the reviewer wrote")

    def test_a_reviewer_that_only_left_ignored_files_or_committed_is_told_apart(self):
        # A review without a profile works in the real repo: its photo is the G2 one, without ignored
        # files, so the __pycache__ its tests leave must not refuse a good result (SUA-03, 4.8). A
        # commit leaves status and diff clean: HEAD and the refs still tell.
        (self.repo / ".gitignore").write_text("__pycache__/\n")
        self.git("add", ".gitignore")
        self.git("commit", "-q", "-m", "ignora")
        self.r.offer("task-1", b"revisa el saludo\n", self.revision, contract="review.v1")
        self.launched()
        self.assertEqual(json.loads(self.record().repo_before.read_text())["ignored"], False,
                         "a review without a clone keeps the G2 photo")
        (self.repo / "__pycache__").mkdir()
        (self.repo / "__pycache__" / "x.pyc").write_bytes(b"\0")
        self.review_writes(self.run_dir().path / "hallazgos.md")
        self.left(0)
        self.one_pass()
        self.assertEqual((len(self.r.reports), self.r.incidents), (1, []))
        # A commit leaves status and diff clean: HEAD and the refs still tell.
        self.r.offer("task-2", b"revisa otra vez\n", self.revision, contract="review.v1")
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.git("commit", "-q", "--allow-empty", "-m", "del revisor")
        assignment = json.loads(self.run_dir("task-2").assignment.read_text())
        Path(assignment["acceptRef"]).write_text(json.dumps(assignment["protocol"]["accept"]))
        artifact = self.run_dir("task-2").path / "hallazgos.md"
        artifact.write_text("ok\n")
        Path(assignment["resultRef"]).write_text(json.dumps({
            **assignment["protocol"]["result"], "typedPayload": {"verdict": "approved"},
            "artifactRef": str(artifact), "digest": hashlib.sha256(b"ok\n").hexdigest()}))
        self.left(0, "task-2")
        self.one_pass()
        self.assertEqual(self.r.incidents, [("task-2", "invalid-result", "reviewer-wrote-source")])
        self.assertEqual(json.loads(self.record("task-2").repo_after.read_text())["changed"], ["head", "refs"])

    def test_a_reviewer_that_planted_a_hook_or_changed_the_git_config_is_refused(self):
        for change, changed in (
                (lambda: (self.repo / ".git/hooks/pre-commit").write_text("#!/bin/sh\ncurl x\n"), ["hooks"]),
                (lambda: self.git("config", "core.hooksPath", "/tmp/ganchos"), ["config"])):
            with self.subTest(changed=changed):
                self.setUp()
                task = "task-1"
                self.r.offer(task, f"revisa {task}\n".encode(), self.revision, contract="review.v1")
                self.assertEqual(self.one_pass().get("claimed"), 1)
                change()
                assignment = json.loads(self.run_dir(task).assignment.read_text())
                Path(assignment["acceptRef"]).write_text(json.dumps(assignment["protocol"]["accept"]))
                artifact = self.run_dir(task).path / "hallazgos.md"
                artifact.write_text("ok\n")
                Path(assignment["resultRef"]).write_text(json.dumps({
                    **assignment["protocol"]["result"], "typedPayload": {"verdict": "approved"},
                    "artifactRef": str(artifact), "digest": hashlib.sha256(b"ok\n").hexdigest()}))
                self.left(0, task)
                self.one_pass()
                self.assertIn((task, "invalid-result", "reviewer-wrote-source"), self.r.incidents)
                self.assertEqual(json.loads(self.record(task).repo_after.read_text())["changed"], changed)
                self.assertEqual(self.r.reports, [])

    def test_a_task_that_may_write_its_repo_has_no_photo(self):
        self.launched()
        self.cli_writes()
        self.left(0)
        self.one_pass()
        self.assertFalse(self.record().repo_before.exists())
        self.assertEqual((len(self.r.reports), self.r.incidents), (1, []))

    def test_estado_says_why_the_launch_script_left_before_reaching_opencode(self):
        for code, why in ((96, "El host no pudo crear la carpeta temporal del encargo."),
                          (97, "El host no pudo entrar a la carpeta del encargo."),
                          (98, "El proceso no quedó en el grupo del slot y el host no lanzó opencode.")):
            with self.subTest(code=code):
                self.setUp()
                self.launched()
                record = self.record()
                record.events.write_text("")
                record.stderr.write_text("")
                self.left(code)
                self.assertEqual(self.one_pass()["detected"], 1)
                _, answer = self.estado()
                self.assertEqual((answer["salida"], answer["explicacion"]["frase"]),
                                 (code, f"opencode salió sin acusar recibo. {why}"))

    def test_a_process_that_leaves_without_accepting_is_launch_failed_whatever_its_exit_code(self):
        for code in (1, 0):
            with self.subTest(code=code):
                self.setUp()
                self.launched()
                record = self.record()
                record.events.write_text(json.dumps({"type": "error", "timestamp": STAMP, "error": {
                    "name": "UnknownError", "data": {"message": "Unexpected server error."}}}) + "\n")
                record.stderr.write_text('timestamp=2026-10-13T00:28:41Z level=ERROR run=b3 message=failed '
                                         f'error="Model not found: {DEFAULT}. CAPACIDAD-task-1"\n')
                self.left(code)
                self.assertEqual(self.one_pass()["detected"], 1)
                self.assertEqual(self.incidents(), ["host:1:transport-unavailable:launch-failed"])
                self.assertEqual(self.held(), ("uncertain", "Running", ""),
                                 "a process that left fast ended as an uncertain launch identity")
                self.assertEqual(json.loads(record.exit.read_text()), {"code": code})
                self.ahead = 4000
                self.assertEqual((self.one_pass()["detected"], self.r.incidents),
                                 (0, [("task-1", "transport-unavailable", "launch-failed")]))
                _, answer = self.estado()
                self.assertEqual((answer["estado"], answer["salida"], answer["explicacion"]), ("uncertain", code, {
                    "causa": "launch-failed", "accion": "cancelar",
                    "frase": "opencode salió sin acusar recibo. opencode dijo: Model not found: "
                             f"{DEFAULT}. <capacidad>."}))
                self.r.cancel("task-1")
                self.assertEqual(self.changes(),
                                 {"cancelled": 1, "closed": 1})
                self.assertEqual(self.held(), ("cancelled", "AbsenceVerified", ""))
                self.assertEqual(self.r.closures[-1][:3], ("task-1", "AbsenceVerified", ""))

    def test_a_denied_permission_ends_the_session_and_estado_names_it(self):
        self.launched()
        self.cli_writes(result=False)
        record = self.record()
        record.events.write_text(json.dumps({"type": "tool_use", "timestamp": STAMP, "part": {
            "tool": "bash", "state": {"status": "error", "error": REJECTED}}}) + "\n")
        record.stderr.write_text(CREATED.format(self.repo)
                                 + STREAM.format("zai-coding-plan", "glm-5.3-flash", "false", "build")
                                 + DENIED.format("/fuera/*"))
        self.left(0)
        self.assertEqual(self.one_pass()["detected"], 1)
        self.assertEqual(self.one_pass()["detected"], 0)
        self.assertEqual(self.incidents(), ["host:1:transport-unavailable:session-closed"])
        self.assertEqual(self.r.incidents, [("task-1", "transport-unavailable", "session-closed")])
        self.assertEqual(self.held(), ("delivered", "Running", ""))
        code, answer = self.estado()
        self.assertEqual((code, answer["permisosNegados"], answer["explicacion"], answer["carpetaDeSesion"],
                          answer["proveedoresLlamados"], answer["salida"]),
                         (0, ["external_directory:/fuera/*"], {
                             "causa": "session-closed", "accion": "cancelar",
                             "frase": "La sesión terminó sin entregar resultado. opencode negó external_directory "
                                      "sobre /fuera/*."}, str(self.repo), ["zai-coding-plan"], 0))

    def test_a_session_opened_in_another_folder_is_stopped_in_that_pass(self):
        self.launched()
        self.record().events.write_text("")
        self.record().stderr.write_text(CREATED.format("/otra/carpeta"))
        self.assertEqual((self.one_pass()["detected"], self.backend.stops), (1, [self.session()]))
        self.assertEqual(self.incidents(), ["host:1:transport-unavailable:launch-failed"])
        self.assertEqual(self.held(), ("uncertain", "Running", ""))
        self.assertEqual((self.one_pass()["detected"], self.backend.stops), (0, [self.session()]))
        code, answer = self.estado()
        self.assertEqual((answer["carpetaDeSesion"], answer["explicacion"]["frase"]),
                         ("/otra/carpeta", "opencode salió sin acusar recibo. La sesión abrió en /otra/carpeta."))

    def test_a_session_in_the_task_folder_is_left_alone(self):
        self.launched()
        self.record().events.write_text("")
        self.record().stderr.write_text(CREATED.format(self.repo))
        self.assertEqual((self.one_pass()["detected"], self.backend.stops, self.incidents()), (0, [], []))

    def test_silence_is_reported_at_each_deadline_and_not_before(self):
        self.launched()
        self.ahead = 299
        self.assertEqual(self.one_pass()["detected"], 0)
        self.ahead = 301
        self.assertEqual(self.one_pass()["detected"], 1)
        self.assertEqual((self.incidents(), self.held()),
                         (["host:1:transport-unavailable:delivery-unaccepted"], ("uncertain", "Running", "")))

    def test_an_accepted_task_has_an_hour_and_an_invalid_result_is_its_own_incident(self):
        self.launched()
        self.cli_writes(result=False)
        self.ahead = 3590
        self.assertEqual((self.one_pass()["detected"], self.held()), (0, ("delivered", "Running", "")))
        self.ahead = 3605
        self.assertEqual(self.one_pass()["detected"], 1)
        self.assertEqual(self.incidents(), ["host:1:deadline-missed:deadline"])
        self.run_dir().result.write_text('{"schema": "otra cosa"}')
        self.assertEqual(self.one_pass()["detected"], 1)
        self.assertEqual(self.incidents(), ["host:1:deadline-missed:deadline", "host:1:invalid-result:invalid-result"])

    def test_a_process_of_no_task_in_the_slot_group_blocks_the_claim(self):
        self.backend.foreign = lambda: ("9001 Tue Oct 13 00:58:21 2026 /bin/sleep 600",)
        self.assertEqual(self.changes(), {})
        self.assertEqual(self.r.claims, [], "the host claimed a task it could not launch")
        beat = self.beat()
        self.assertEqual((beat["slot"], beat["blockedBy"], beat["taskId"]),
                         ("blocked", ["9001 Tue Oct 13 00:58:21 2026 /bin/sleep 600"], None))
        self.backend.foreign = tuple
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.assertEqual((self.r.claims, len(self.backend.launches)), ([("opencode", "enc-1")], 1))

    def test_a_launch_deferred_by_a_busy_boundary_fails_after_five_minutes(self):
        self.backend.foreign = lambda: ("9001 Tue Oct 13 00:58:21 2026 /bin/sleep 600",) if self.r.claims else ()
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.assertEqual((self.held(), self.backend.launches, self.r.admits),
                         (("deferred", "Reserved", ""), [], ["task-1"]))
        self.assertEqual(json.loads(self.record().blocked.read_text()),
                         {"boundary": ["9001 Tue Oct 13 00:58:21 2026 /bin/sleep 600"]})
        self.assertEqual(self.one_pass()["detected"], 0)
        self.assertEqual((self.held(), self.r.admits), (("deferred", "Reserved", ""), ["task-1"]), "a retry admitted again")
        self.ahead = 301
        self.assertEqual(self.one_pass()["detected"], 1)
        self.assertEqual((self.incidents(), self.held()),
                         (["host:1:transport-unavailable:launch-failed"], ("uncertain", "Reserved", "")))
        self.backend.foreign = tuple
        self.one_pass()
        self.assertEqual(self.backend.launches, [], "a launch declared failed was launched afterwards")
        self.assertEqual(self.estado()[1]["explicacion"], {
            "causa": "slot-bloqueado", "accion": "cancelar",
            "frase": "El slot de encargos tiene procesos que no son de ningún encargo: "
                     "9001 Tue Oct 13 00:58:21 2026 /bin/sleep 600."})
        self.r.cancel("task-1")
        self.one_pass()
        self.assertEqual(self.held(), ("cancelled", "AbsenceVerified", ""))

    @unittest.skipUnless(PSTACK.is_dir(), "pide pstack 0.9.84 instalado en esta Mac")
    def test_a_profiled_launch_deferred_by_a_busy_boundary_retries_with_the_same_assignment(self):
        # exploracion is the one CLI profile whose writesSource disagrees with its contract: the protocol
        # the assignment spells out must not change between the attempt and its retry (SU A-03, 4.5).
        self.checkout_contexto()
        self.start(ScriptedBackend(), canary=True)
        revision = {"kind": "code", "repository": str(self.repo),
                    "sha": self.git_out("-C", str(self.repo), "rev-parse", "HEAD")}
        self.r.offer("task-1", b"agent-work.launch.v1\nprofile: exploracion\n---\nexplora\n", revision)
        self.backend.foreign = lambda: ("9001 Tue Oct 13 00:58:21 2026 /bin/sleep 600",) if self.r.claims else ()
        outcome = self.one_pass()
        self.assertEqual(self.held(), ("deferred", "Reserved", ""))
        self.assertTrue((self.run_dir().context / "perfil.json").is_file(), "the copy precedes the assignment")
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.assertEqual(self.r.admits, ["task-1"], "the retry registered the same assignment")
        self.backend.foreign = tuple
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.assertEqual((len(self.backend.launches), self.r.admits), (1, ["task-1"]))
        # exploracion may not write source: the registered protocol says so, whatever its contract says.
        protocol = json.loads(self.run_dir().assignment.read_text())["protocol"]
        self.assertEqual(protocol["fill"]["artifactRef"],
                         "the absolute path of the artifact file, inside the directory that holds resultRef, "
                         "never inside workspaceRef")

    def refused(self, causa, piece):
        self.assertEqual(self.changes(), {"claimed": 1})
        self.assertEqual((self.backend.launches, self.r.admits, self.incidents()),
                         ([], ["task-1"], ["host:1:transport-unavailable:launch-refused"]))
        self.assertEqual(self.held(), ("registered", "Reserved", ""))
        self.one_pass()
        self.assertEqual((self.r.admits, self.r.incidents),
                         (["task-1"], [("task-1", "transport-unavailable", "launch-refused")]),
                         "a replayed refusal was admitted or reported again")
        code, answer = self.estado()
        self.assertEqual((code, answer["modelo"], answer["estado"], answer["explicacion"]["causa"],
                          answer["explicacion"]["accion"]), (0, None, "registered", causa, "cancelar"))
        self.assertIn(piece, answer["explicacion"]["frase"])
        self.r.cancel("task-1")
        self.assertEqual(self.changes(), {"cancelled": 1, "closed": 1})
        self.assertEqual((self.held(), self.backend.launches), (("cancelled", "AbsenceVerified", ""), []))

    def test_a_closed_provider_in_the_brief_is_refused_with_an_incident_and_nothing_runs(self):
        self.r.offer("task-1", b"agent-work.launch.v1\nmodel: opencode-go/deepseek-v4-pro\n---\nhaz el saludo\n",
                     self.revision)
        self.refused("proveedor-no-permitido", "«open code go es solamente para main»")

    def test_an_old_brief_is_refused_once_the_default_provider_loses_its_grant(self):
        self.edit_policy(lambda document: document.update(
            providers=[entry for entry in document["providers"] if entry["name"] == "deepseek"]))
        self.refused("proveedor-no-permitido", "zai-coding-plan no tiene permiso para encargos.")

    def test_a_folder_outside_the_operators_root_is_refused(self):
        outside = self.root / "fuera"
        (outside / ".git").mkdir(parents=True)
        self.r.offer("task-1", b"haz el saludo\n", {"kind": "code", "repository": str(outside), "sha": "a" * 40})
        self.refused("carpeta-no-permitida", f"{outside} está fuera de la carpeta de repos permitida.")

    def test_a_revision_that_is_no_code_or_artifact_is_refused(self):
        self.r.offer("task-1", b"haz el saludo\n", {"kind": "otra-cosa", "repository": str(self.repo)})
        self.refused("carpeta-no-permitida", "no es una carpeta de encargo válida.")

    def test_a_repository_pathlib_cannot_read_is_refused_and_not_a_crash(self):
        self.r.offer("task-1", b"haz el saludo\n", {"kind": "code", "repository": "/Users/dn/dev/a\0b", "sha": "a" * 40})
        self.refused("carpeta-no-permitida", "/Users/dn/dev/a\x00b no es una carpeta de encargo válida.")

    def route_status(self, status):
        coverage = self.checkout / EVIDENCE / "coverage.json"
        document = json.loads(coverage.read_text())
        document["hostAdapterCoverage"]["mac-local"]["opencode"] = status
        coverage.write_text(json.dumps(document))

    def test_without_canary_a_sandbox_tested_route_launches_nothing(self):
        self.route_status("sandbox-tested-uncertified")
        self.refused("ruta-no-certificada", "todavía no está certificada")

    def test_a_canary_host_launches_on_a_sandbox_tested_route_and_says_so_in_its_beat(self):
        self.route_status("sandbox-tested-uncertified")
        self.start(self.backend, canary=True)
        self.launched()
        self.assertEqual((self.held(), self.beat()["canary"]), (("attempted", "Running", ""), True))

    def test_the_canary_does_not_open_a_route_that_was_never_sandbox_tested(self):
        self.route_status("blocked")
        self.start(self.backend, canary=True)
        self.refused("ruta-no-certificada", "todavía no está certificada")

    def test_a_new_opencode_version_closes_the_repos_certified_route(self):
        (self.bin / "version").write_text("1.18.36\n")
        self.start(self.backend)
        self.refused("ruta-no-certificada", "Ruta certificada para 1.18.35, la Mac tiene opencode 1.18.36.")

    def test_a_canary_host_launches_with_an_opencode_version_the_route_does_not_have_yet(self):
        (self.bin / "version").write_text("1.18.36\n")
        self.start(self.backend, canary=True)
        self.launched()
        self.assertEqual(self.held(), ("attempted", "Running", ""))

    def test_an_opencode_that_does_not_answer_refuses_the_task_instead_of_leaving_it_mute(self):
        (self.bin / "version").write_text("")
        self.start(self.backend)
        self.refused("ruta-no-certificada",
                     "Ruta certificada para 1.18.35, la Mac tiene opencode sin contestar su versión.")

    def died(self, where):
        self.backend.dies = where
        with self.assertRaises(HostDied):
            pump_once(self.r, host=self.host, evidence_root=str(self.root / "e"), progress_state_dir=str(self.root / "p"),
                      progress_client="unused", cli_claim=self.run.claim)
        self.backend.dies = None
        self.start(self.backend)

    def test_a_clone_left_with_a_remote_is_built_again(self):
        from native_gateway import build_clone

        sha = self.git_out("-C", str(self.repo), "rev-parse", "HEAD")
        destino = self.root / "clon"
        build_clone(str(self.repo), sha, destino)
        self.assertEqual(self.git_out("-C", str(destino), "remote"), "")
        subprocess.run(["git", "-C", str(destino), "remote", "add", "origin", str(self.repo)], check=True,
                       capture_output=True)
        build_clone(str(self.repo), sha, destino)
        self.assertEqual(self.git_out("-C", str(destino), "remote"), "",
                         "a clone whose origin came back is rebuilt, not reused")
        self.assertEqual(self.git_out("-C", str(destino), "rev-parse", "HEAD"), sha)

    def test_a_clone_with_leftovers_is_built_again(self):
        from native_gateway import build_clone

        sha = self.git_out("-C", str(self.repo), "rev-parse", "HEAD")
        destino = self.root / "clon-sucio"
        build_clone(str(self.repo), sha, destino)
        (destino / "dejado.txt").write_text("de un intento anterior\n")
        build_clone(str(self.repo), sha, destino)
        self.assertFalse((destino / "dejado.txt").exists(), "a dirty clone was reused")
        self.assertEqual(self.git_out("-C", str(destino), "rev-parse", "HEAD"), sha)

    @unittest.skipUnless(PSTACK.is_dir(), "pide pstack 0.9.84 instalado en esta Mac")
    def test_a_new_file_in_an_ignored_dir_that_already_existed_is_caught(self):
        # A review WITH its package works in a clone, so the real repo must stay as its photo took it,
        # ignored files included (SUA-03, 4.8): --ignored=traditional lists the files inside an ignored
        # directory, which --ignored=matching would collapse into one entry.
        self.checkout_contexto()
        self.start(ScriptedBackend(), canary=True)
        (self.repo / ".gitignore").write_text("__pycache__/\n")
        self.git("add", ".gitignore")
        self.git("commit", "-q", "-m", "ignora")
        (self.repo / "__pycache__").mkdir()
        (self.repo / "__pycache__" / "viejo.pyc").write_bytes(b"\0")
        revision = {"kind": "code", "repository": str(self.repo),
                    "sha": self.git_out("-C", str(self.repo), "rev-parse", "HEAD")}
        self.r.offer("task-1", b"agent-work.launch.v1\nprofile: revision\n---\nrevisa\n", revision,
                     contract="review.v1")
        self.launched()
        self.assertEqual(json.loads(self.record().repo_before.read_text())["ignored"], True,
                         "a reviewer in a clone sums ignored files")
        self.assertTrue(self.run_dir().repo.is_dir(), "the reviewer works in a clone")
        (self.repo / "__pycache__" / "nuevo.pyc").write_bytes(b"\0")
        self.review_writes(self.run_dir().path / "hallazgos.md")
        self.left(0)
        self.one_pass()
        self.assertEqual(self.r.reports, [], "a new file inside an old ignored dir went unseen")
        self.assertEqual(self.r.incidents, [("task-1", "invalid-result", "reviewer-wrote-source")])
        self.assertEqual(json.loads(self.record().repo_after.read_text())["changed"], ["status"])

    def test_a_host_that_died_before_launching_launches_once_it_is_back(self):
        self.died("before-launching")
        self.assertEqual((self.held(), self.backend.launches), (("attempted", "Launching", ""), []))
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.assertEqual((self.held(), len(self.backend.launches), self.r.admits),
                         (("attempted", "Running", ""), 1, ["task-1"]))
        self.one_pass()
        self.assertEqual(len(self.backend.launches), 1)

    def test_a_host_that_died_after_launching_adopts_its_session_and_never_launches_twice(self):
        self.died("after-launching")
        self.assertEqual((self.held(), len(self.backend.launches)), (("attempted", "Launching", ""), 1))
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.assertEqual((self.held(), len(self.backend.launches)), (("attempted", "Running", ""), 1))

    def test_a_lost_launch_with_a_busy_boundary_is_never_relaunched_and_closes_by_the_boundary(self):
        self.died("before-launching")
        self.backend.foreign = lambda: ("9001 Tue Oct 13 00:58:21 2026 /bin/sleep 600",)
        self.assertEqual(self.one_pass(), "the launch did not attach: CleanupPending launch outcome uncertain")
        self.assertEqual((self.held(), self.backend.launches),
                         (("attempted", "CleanupPending", "launch outcome uncertain"), []))
        self.backend.foreign = tuple
        self.one_pass()
        self.assertEqual(self.backend.launches, [], "an uncertain launch was launched again")
        self.backend.survivors = ("9001 Tue Oct 13 00:58:21 2026 /bin/sleep 600",)
        self.r.cancel("task-1")
        self.assertEqual(self.one_pass(),
                         f"{self.operation()}: cancelled; resource CleanupPending: launch outcome uncertain")
        self.backend.survivors = ()
        self.assertEqual(self.changes(), {"cancelled": 1, "closed": 1})
        self.assertEqual(self.held(), ("cancelled", "AbsenceVerified", ""))

    def test_a_reservation_whose_host_died_before_registering_closes_once_r_cancels_its_task(self):
        with mock.patch.object(self.host.spool, "get", side_effect=HostDied), self.assertRaises(HostDied):
            self.run.claim()
        self.start(self.backend)
        self.assertEqual(self.held(), (None, "Reserved", ""))
        asked = []
        read = self.r.host_cancellation
        self.r.host_cancellation = lambda assignment: asked.append(assignment) or read(assignment)
        self.r.task = None
        self.assertEqual((self.changes(), self.held()), ({}, (None, "Reserved", "")))
        self.r.cancel("task-1")
        self.assertEqual(self.changes(), {"cancelled": 1, "closed": 1})
        self.assertEqual(asked, 2 * [{"hostId": "mac-local", "taskId": "task-1", "generation": 1, "instanceId": "enc-1",
                                      "producerId": "opencode", "capability": "CAPACIDAD-task-1",
                                      "adapterId": "opencode"}])
        self.assertEqual(self.held(), (None, "AbsenceVerified", ""))
        self.assertEqual(self.r.closures, [("task-1", "AbsenceVerified", "", hashlib.sha256(
            b'{"kind":"cancel","receipt":"cancel-task-1"}').hexdigest())])
        self.assertEqual((self.changes(), len(asked), len(self.r.closures)), ({}, 2, 1), "R was asked or told twice")
        self.assertEqual((self.backend.launches, self.backend.stops), ([], []))
        self.r.offer("task-2", b"otro\n", self.revision)
        self.assertEqual(self.one_pass()["claimed"], 1)

    def test_a_plan_whose_model_authorize_does_not_permit_is_never_launched(self):
        """Whoever builds the plan, the launcher asks authorize again before the model reaches `opencode -m`.
        PermittedModel has no constructor and refuses dataclasses.replace; what is left is to fabricate one on
        purpose, field by field."""
        planned = self.run.plan

        def forged(*args, **kwargs):
            plan = planned(*args, **kwargs)
            with self.assertRaises(TypeError):
                replace(plan.model, model=ModelId("opencode-go", "deepseek-v4-pro"))
            fabricated = object.__new__(type(plan.model))
            for name in ("billing", "policy_digest", "cli_version"):
                object.__setattr__(fabricated, name, getattr(plan.model, name))
            object.__setattr__(fabricated, "model", ModelId("opencode-go", "deepseek-v4-pro"))
            return replace(plan, model=fabricated)

        self.run.plan = forged
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.assertEqual(self.backend.launches, [], "a model of a closed provider reached the launcher")
        self.run.plan = planned
        self.assertEqual(self.one_pass()["claimed"], 1)
        self.assertEqual([launch["argv"][3] for launch in self.backend.launches], [DEFAULT])

    def test_one_spool_takes_one_host(self):
        first = hold_spool(self.spool)
        self.assertIsNotNone(first)
        self.assertIsNone(hold_spool(self.spool))
        first.close()
        again = hold_spool(self.spool)
        self.assertIsNotNone(again)
        again.close()

    def test_a_brief_that_is_not_what_its_digest_says_never_reaches_the_run_directory(self):
        self.r.offer("task-1", b"haz el saludo\n", self.revision)
        claim = self.r.claim_host("opencode", "enc-1")
        run = RunDir.for_operation(self.spool, self.operation())
        self.r.task["brief"] = b"haz otra cosa\n"
        with self.assertRaisesRegex(ValueError, "host brief response identity mismatch"):
            fetch_brief(self.r, claim, run)
        self.assertEqual(list(run.path.iterdir()), [])
        self.r.task["brief"] = b"haz el saludo\n"
        self.assertEqual(fetch_brief(self.r, claim, run).read_bytes(), b"haz el saludo\n")
        self.r.task = None
        self.assertEqual(fetch_brief(self.r, claim, run), run.brief, "a cached brief was downloaded again")

    def test_only_an_acceptance_bound_to_this_assignment_counts(self):
        self.launched()
        key = OperationKey("mac-local", "task-1", 1, "enc-1")
        run = self.run_dir()
        good = json.loads(run.assignment.read_text())["protocol"]["accept"]
        self.assertEqual(good, {"schema": "agent-work.accept.v1", "hostId": "mac-local", "taskId": "task-1",
                                "generation": 1, "instanceId": "enc-1", "claimId": "claim-task-1",
                                "capability": "CAPACIDAD-task-1"})
        elsewhere = self.root / "elsewhere.json"
        elsewhere.write_text(json.dumps(good))
        forgeries = {
            "the delivery line": f"Open assignment JSON at {run.assignment}.".encode(),
            "another capability": json.dumps({**good, "capability": "CAPACIDAD-task-2"}).encode(),
            "a capability that is not ASCII": json.dumps({**good, "capability": "CAPACIDÁD-task-1"}).encode(),
            "another claim": json.dumps({**good, "claimId": "claim-other"}).encode(),
            "another task": json.dumps({**good, "taskId": "task-other"}).encode(),
            "another host": json.dumps({**good, "hostId": "host-two"}).encode(),
            "another instance": json.dumps({**good, "instanceId": "instance-other"}).encode(),
            "another generation": json.dumps({**good, "generation": 2}).encode(),
            "a boolean generation": json.dumps({**good, "generation": True}).encode(),
            "a float generation": json.dumps({**good, "generation": 1.0}).encode(),
            "a number capability": json.dumps({**good, "capability": 7}).encode(),
            "UTF-16": json.dumps(good).encode("utf-16"),
            "a text generation": json.dumps({**good, "generation": "1"}).encode(),
            "the result schema": json.dumps({**good, "schema": "agent-work.result.v1"}).encode(),
            "an extra field": json.dumps({**good, "note": "taken"}).encode(),
            "no capability": json.dumps({k: v for k, v in good.items() if k != "capability"}).encode(),
            "not an object": json.dumps([good]).encode(),
            "empty": b"",
            "not UTF-8": b"\xff\xfe{}",
            "padded past 4096 bytes": b" " * 4096 + json.dumps(good).encode(),
        }
        for name, content in forgeries.items():
            with self.subTest(name):
                run.accept.write_bytes(content)
                self.assertFalse(self.host.take_acceptance("mac-local", key))
        run.accept.unlink()
        with self.subTest("a symlink to a valid acceptance"):
            run.accept.symlink_to(elsewhere)
            try:
                self.assertFalse(self.host.take_acceptance("mac-local", key))
            finally:
                run.accept.unlink()
        with self.subTest("a directory"):
            run.accept.mkdir()
            try:
                self.assertFalse(self.host.take_acceptance("mac-local", key))
            finally:
                run.accept.rmdir()
        self.assertEqual(self.held(), ("attempted", "Running", ""))
        run.accept.write_bytes(json.dumps(good).encode())
        self.assertTrue(self.host.take_acceptance("mac-local", key))
        self.assertEqual(self.held(), ("delivered", "Running", ""))

    def test_an_acceptance_the_host_cannot_read_is_not_a_missing_acceptance(self):
        self.launched()
        self.cli_writes(result=False)
        self.run_dir().accept.chmod(0)
        self.ahead = 301
        self.assertEqual((self.one_pass()["detected"], self.held()), (0, ("attempted", "Running", "")))
        self.run_dir().accept.chmod(0o600)
        self.assertEqual((self.one_pass()["detected"], self.held()), (0, ("delivered", "Running", "")))

    def test_a_valid_result_without_acceptance_counts_and_an_invalid_one_does_not(self):
        self.launched()
        self.cli_writes()
        self.run_dir().accept.unlink()
        self.assertEqual((self.one_pass()["reported"], self.r.reports), (1, [("task-1", b"hecho\n")]))
        self.setUp()
        self.launched()
        self.run_dir().result.write_text('{"schema": "otra cosa"}')
        self.ahead = 301
        self.assertEqual((self.one_pass()["detected"], self.r.reports), (1, []))
        self.assertEqual((self.incidents(), self.held()),
                         (["host:1:transport-unavailable:delivery-unaccepted"], ("uncertain", "Running", "")))

    def crash_writing(self, event, table):
        """Fail that write of the spool, as a full disk would, until the returned call undoes it."""
        def run(statement):
            with contextlib.closing(sqlite3.connect(self.spool / "host.sqlite")) as db:
                db.execute(statement)
                db.commit()

        run(f"CREATE TRIGGER crash BEFORE {event} ON {table} BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        return lambda: run("DROP TRIGGER crash")

    def test_uncertain_and_its_incident_survive_a_crash_together(self):
        for table, event in (("incidents", "INSERT"), ("operations", "UPDATE")):
            with self.subTest(crash_writing=table):
                self.setUp()
                self.launched()
                self.ahead = 301
                recover = self.crash_writing(event, table)
                with self.assertRaises(sqlite3.DatabaseError):
                    self.run.watch()
                recover()
                self.assertEqual(self.run.watch(), ["host:1:transport-unavailable:delivery-unaccepted"],
                                 "the crash lost the incident")
                self.assertEqual((self.incidents(), self.held()),
                                 (["host:1:transport-unavailable:delivery-unaccepted"], ("uncertain", "Running", "")))

    def test_the_launch_and_its_attempt_clock_are_one_write(self):
        self.crash_writing("INSERT", "delivery_attempts")
        with self.assertRaises(sqlite3.DatabaseError):
            self.run.claim()
        self.assertEqual((self.backend.launches, self.held()), ([], ("registered", "Reserved", "")))


def slot_gid():
    try:
        return grp.getgrnam(SLOT_GROUP).gr_gid
    except KeyError:
        return None


def slot_group_processes():
    table = subprocess.run(["ps", "-A", "-o", "uid=,rgid=,pid=,lstart=,command="], capture_output=True, text=True,
                           env={**os.environ, "TZ": "UTC", "LC_ALL": "C"}).stdout
    return parse_boundary(table, os.getuid(), slot_gid())


@unittest.skipUnless(shutil.which("tmux"), "needs tmux")
@unittest.skipUnless(slot_gid() is not None,
                     f"needs the group {SLOT_GROUP} with this user in it; create it once with: sudo dseditgroup -o create "
                     f"{SLOT_GROUP} && sudo dseditgroup -o edit -a \"$USER\" -t user {SLOT_GROUP}")
class LiveSlot(Slot):
    """The opencode double as a real process in the real slot group, on this case's own tmux server."""

    def setUp(self):
        busy = slot_group_processes()
        if busy:
            self.skipTest(f"the group {SLOT_GROUP} holds live processes, a task of this machine's host may be running; "
                          f"this case would sweep them: {'; '.join(map(str, busy))}")
        super().setUp()
        self.socket = f"b22f2-{os.getpid()}-{self.id().rsplit('.', 1)[-1][-24:]}"
        self.addCleanup(self.clean)
        self.elsewhere = self.root / "otra" / "carpeta"
        self.elsewhere.mkdir(parents=True)
        # The server a host session runs on was started somewhere else, with that PWD; its keeper session
        # stays in the user's own group.
        subprocess.run([TMUX, "-L", self.socket, "-f", "/dev/null", "new-session", "-d", "-s", "keeper", "sleep 600"],
                       check=True, cwd=self.elsewhere, env={**os.environ, "PWD": str(self.elsewhere)})
        self.start(GroupBoundaryBackend(TMUX, self.socket, SLOT_GROUP, grace_seconds=1.0))
        self.r.offer("task-1", b"haz el saludo\n", self.revision)

    def clean(self):
        socket = subprocess.run([TMUX, "-L", self.socket, "display-message", "-p", "#{socket_path}"],
                                capture_output=True, text=True).stdout.strip()
        subprocess.run([TMUX, "-L", self.socket, "kill-server"], capture_output=True)
        if socket.endswith(f"/{self.socket}"):
            with contextlib.suppress(OSError):
                os.unlink(socket)
        for name in ("seen.json", "child.json"):
            with contextlib.suppress(OSError, ValueError, KeyError):
                pid = json.loads((self.bin / name).read_text())["pid"]
                if any(process.pid == pid for process in slot_group_processes()):
                    os.kill(pid, signal.SIGKILL)
        deadline = time.monotonic() + 5
        while slot_group_processes() and time.monotonic() < deadline:
            time.sleep(0.05)

    def passes(self, done, seconds=15.0):
        """Pump until done() holds; every pass on the way is returned."""
        seen, deadline = [], time.monotonic() + seconds
        while time.monotonic() < deadline:
            seen.append(self.one_pass())
            if done():
                return seen
            time.sleep(0.1)
        self.fail(f"not reached in {seconds} s; passes: {seen[-3:]}; held: {self.held()}; "
                  f"stderr: {self.record().stderr.read_text() if self.record().stderr.exists() else None}")

    def seen(self):
        return json.loads((self.bin / "seen.json").read_text())

    def sessions(self):
        listed = subprocess.run([TMUX, "-L", self.socket, "list-sessions", "-F", "#{session_name}"],
                                capture_output=True, text=True)
        return sorted(listed.stdout.split())

    def closed(self):
        return self.held()[1] == "AbsenceVerified"


class LiveResult(LiveSlot):
    def test_a_task_that_ends_with_its_result_leaves_nothing_behind(self):
        self.passes(self.closed)
        self.assertEqual(self.held(), ("acknowledged", "AbsenceVerified", ""))
        self.assertEqual(self.r.reports, [("task-1", b"hecho por el doble\n")])
        self.assertEqual((self.repo / "b22-doble.txt").read_text(), "hecho por el doble\n")
        self.assertEqual(sorted(path.name for path in self.run_dir().path.iterdir()),
                         ["accept.json", "assignment.json", "brief", "result.json", "tmp"])
        seen = self.seen()
        self.assertEqual((seen["PWD"], seen["cwd"], seen["rgid"], seen["stdin_is_dev_null"], seen["managed"],
                          seen["autoupdate"]), (str(self.repo), str(self.repo), slot_gid(), True, "1", "1"))
        self.assertEqual((seen["TMPDIR"], seen["scratch_mode"]), (str(self.run_dir().path / "tmp"), "0o700"))
        self.assertEqual(seen["argv"], ["run", "-m", DEFAULT, "--format", "json", "--print-logs", "--log-level", "INFO",
                                        "--title", "task-1", LINE.format(self.run_dir().assignment)])
        self.assertEqual(json.loads(seen["config"])["permission"],
                         {"external_directory": {"*": "deny", f"{self.run_dir().path}/**": "allow"}})
        self.assertEqual((self.sessions(), slot_group_processes()), (["keeper"], ()))
        self.assertFalse((self.repo / "managed-briefs").exists())
        self.assertEqual({path.name: path.group() for path in (self.repo / "b22-doble.txt", self.run_dir().accept)},
                         {"b22-doble.txt": self.repo.group(), "accept.json": self.run_dir().path.group()},
                         "a file born in the slot group took that group")
        proof = json.loads(self.host.spool.closure_proof(self.operation()))
        self.assertEqual((proof["pane_gone"], proof["session_gone"], proof["boundary_after"]), (True, True, []))
        self.assertEqual(self.r.closures, [("task-1", "AbsenceVerified", "", hashlib.sha256(canonical({
            "evidence": {"kind": "result", "receipt": "rcpt-task-1"}, "proof": proof}).encode()).hexdigest())])
        self.assertEqual(self.estado(), (0, {
            "ok": True, "tarea": "task-1", "modelo": DEFAULT, "cobro": "subscription", "estado": "acknowledged",
            "cierre": "AbsenceVerified", "explicacion": None, "permisosNegados": [],
            "proveedoresLlamados": ["zai-coding-plan"], "carpetaDeSesion": str(self.repo), "salida": None,
            "logTail": [json.dumps({"type": kind, "timestamp": STAMP, "sessionID": "ses_doble", "part": part})
                        for kind, part in (("step_start", {"type": "step-start"}),
                                           ("text", {"type": "text", "text": "listo"}),
                                           ("step_finish", {"type": "step-finish", "reason": "stop"}))],
            "modeloUsado": DEFAULT, "modeloUsadoRazon": None, "permisos": [], "flota": None}))


    def test_the_session_opens_in_the_task_folder_whatever_folder_the_host_and_its_tmux_server_started_in(self):
        """opencode opens its session where PWD says. The server of this case started in otra/carpeta with
        that PWD, and so does the host here."""
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(self.elsewhere)
        with mock.patch.dict(os.environ, {"PWD": str(self.elsewhere)}):
            self.passes(lambda: (self.bin / "seen.json").exists())
        seen = self.seen()
        self.assertEqual(seen["PWD"], str(self.repo))
        self.assertEqual(seen["cwd"], str(self.repo))
        self.passes(self.closed)


class LiveNoResult(LiveSlot):
    CASE = "no-result"

    def test_a_task_that_ends_without_its_result_is_session_closed(self):
        self.passes(lambda: self.incidents())
        self.assertEqual((self.incidents(), self.held()),
                         (["host:1:transport-unavailable:session-closed"], ("delivered", "Running", "")))
        self.r.cancel("task-1")
        self.passes(self.closed)
        self.assertEqual((self.held(), self.sessions(), slot_group_processes()),
                         (("cancelled", "AbsenceVerified", ""), ["keeper"], ()))


class LiveError(LiveSlot):
    CASE = "error"

    def test_a_process_that_fails_in_under_a_second_is_launch_failed_and_not_an_uncertain_identity(self):
        started = time.monotonic()
        self.passes(lambda: self.incidents())
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual((self.incidents(), self.held()),
                         (["host:1:transport-unavailable:launch-failed"], ("uncertain", "Running", "")))
        code, answer = self.estado()
        self.assertEqual((answer["salida"], answer["explicacion"]), (1, {
            "causa": "launch-failed", "accion": "cancelar",
            "frase": "opencode salió sin acusar recibo. opencode dijo: ProviderModelNotFoundError: Model not found: "
                     f"{DEFAULT}.."}))
        self.r.cancel("task-1")
        self.passes(self.closed)
        self.assertEqual((self.sessions(), slot_group_processes()), (["keeper"], ()))


class LiveFastExit(LiveSlot):
    def test_a_process_that_died_before_the_host_looked_is_still_the_session_of_its_resource(self):
        operation = self.operation()
        key = OperationKey("mac-local", "task-1", 1, "enc-1")
        plan = self.run.plan({"inputRevision": self.revision}, b"haz el saludo\n",
                             run=RunDir.for_operation(self.spool, operation),
                             record=SessionRecord.locate(self.spool, operation).path, operation=operation)
        self.manager.reserve(key, plan.session, "TaskCreated")

        def launch_and_let_it_die(nonce):
            self.backend.launch(plan, nonce, ("/usr/bin/false",), {})
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                dead = subprocess.run([TMUX, "-L", self.socket, "display-message", "-p", "-t", f"={plan.session}:",
                                       "#{pane_dead}"], capture_output=True, text=True).stdout.strip()
                if dead == "1":
                    return
                time.sleep(0.05)
            self.fail("the pane never died")

        view = self.manager.ensure_launched(key, launch_and_let_it_die)
        self.assertEqual((view.state, view.reason), ("Running", ""))
        self.assertEqual(self.manager.session_exit(key), SessionExit(1))
        self.assertEqual(self.manager.close(key, {"kind": "cancel", "receipt": "cancel-1"}).state, "AbsenceVerified")
        self.assertEqual((self.sessions(), slot_group_processes()), (["keeper"], ()))


class LiveHang(LiveSlot):
    CASE = "hang"

    def test_a_process_that_hangs_is_unaccepted_at_the_deadline_and_dies_with_the_cancellation(self):
        self.passes(lambda: (self.bin / "seen.json").exists())
        self.assertEqual((self.one_pass()["detected"], self.held()), (0, ("attempted", "Running", "")))
        hung = self.seen()["pid"]
        self.assertIn(hung, [process.pid for process in slot_group_processes()])
        self.ahead = 301
        self.assertEqual(self.one_pass()["detected"], 1)
        self.assertEqual(self.incidents(), ["host:1:transport-unavailable:delivery-unaccepted"])
        self.r.cancel("task-1")
        self.passes(self.closed)
        self.assertEqual((self.held(), self.sessions(), slot_group_processes()),
                         (("cancelled", "AbsenceVerified", ""), ["keeper"], ()))
        with self.assertRaises(ProcessLookupError):
            os.kill(hung, 0)


class LiveChild(LiveSlot):
    CASE = "child"

    def test_a_detached_child_is_found_in_the_boundary_and_swept_before_the_slot_frees(self):
        self.passes(self.closed)
        child = json.loads((self.bin / "child.json").read_text())
        self.assertEqual(child["rgid"], slot_gid(), "the detached child left the slot's group")
        proof = json.loads(self.host.spool.closure_proof(self.operation()))
        self.assertEqual((len(proof["boundary_before"]), proof["boundary_before"][0].split()[0], proof["signals"],
                          proof["boundary_after"]), (1, str(child["pid"]), [f"SIGTERM {child['pid']}"], []))
        self.assertTrue(proof["boundary_before"][0].endswith("/bin/sleep 300"))
        self.assertEqual((self.held(), slot_group_processes()), (("acknowledged", "AbsenceVerified", ""), ()))
        with self.assertRaises(ProcessLookupError):
            os.kill(child["pid"], 0)


class LiveStubbornChild(LiveSlot):
    CASE = "stubborn-child"

    def test_a_child_that_ignores_term_is_killed_and_only_then_the_closure_is_absence(self):
        self.passes(self.closed)
        child = json.loads((self.bin / "child.json").read_text())["pid"]
        proof = json.loads(self.host.spool.closure_proof(self.operation()))
        self.assertEqual((proof["signals"], proof["boundary_after"]), ([f"SIGTERM {child}", f"SIGKILL {child}"], []))
        self.assertEqual(slot_group_processes(), ())


class LiveDenied(LiveSlot):
    CASE = "denied"

    def test_a_denied_permission_is_a_closed_session_with_its_cause_and_never_a_permission_incident(self):
        self.passes(lambda: self.incidents())
        self.assertEqual(self.incidents(), ["host:1:transport-unavailable:session-closed"])
        self.assertEqual(self.r.incidents, [("task-1", "transport-unavailable", "session-closed")])
        code, answer = self.estado()
        self.assertEqual((answer["permisosNegados"], answer["salida"], answer["explicacion"]["frase"]),
                         (["external_directory:/fuera/*"], 0,
                          "La sesión terminó sin entregar resultado. opencode negó external_directory sobre /fuera/*."))


class LiveStray(LiveSlot):
    CASE = "stray"

    def test_a_session_that_opens_in_another_folder_is_killed_in_the_pass_that_reads_it(self):
        self.passes(lambda: self.incidents())
        self.assertEqual((self.incidents(), self.held()),
                         (["host:1:transport-unavailable:launch-failed"], ("uncertain", "Running", "")))
        self.assertEqual(self.sessions(), ["keeper"], "the session that opened in /otra/carpeta kept running")
        self.assertEqual(self.estado()[1]["carpetaDeSesion"], "/otra/carpeta")
        self.r.cancel("task-1")
        self.passes(self.closed)
        self.assertEqual(slot_group_processes(), ())


class LiveForeign(LiveSlot):
    def test_a_foreign_process_in_the_slot_group_keeps_the_host_from_claiming(self):
        marker = self.root / "ajeno.pid"
        subprocess.run([TMUX, "-L", self.socket, "new-session", "-d", "-s", "ajeno",
                        f"echo 'echo $$ > {marker}; exec /bin/sleep 300' | /usr/bin/newgrp {SLOT_GROUP}"], check=True)
        deadline = time.monotonic() + 10
        while not (marker.exists() and marker.read_text().strip()) and time.monotonic() < deadline:
            time.sleep(0.05)
        foreign = int(marker.read_text())
        self.addCleanup(subprocess.run, ["kill", "-KILL", str(foreign)], capture_output=True)
        self.assertEqual(self.changes(), {})
        self.assertEqual(self.r.claims, [])
        beat = self.beat()
        self.assertEqual((beat["slot"], len(beat["blockedBy"]), beat["blockedBy"][0].split()[0]),
                         ("blocked", 1, str(foreign)))
        self.assertTrue(beat["blockedBy"][0].endswith("/bin/sleep 300"))
        operation = self.operation()
        plan = self.run.plan({"inputRevision": self.revision}, b"haz el saludo\n",
                             run=RunDir.for_operation(self.spool, operation),
                             record=SessionRecord.locate(self.spool, operation).path, operation=operation)
        with self.assertRaisesRegex(BoundaryBusy, f"slot boundary holds 1 process.es.: {foreign} "):
            self.backend.launch(plan, "a" * 32, ("/usr/bin/true",), {})
        self.assertEqual(self.sessions(), ["ajeno", "keeper"], "a session was launched on top of a foreign process")
        os.kill(foreign, signal.SIGKILL)
        self.passes(lambda: self.r.claims)
        self.assertEqual(self.beat()["slot"], "free")


class LiveEntrypoint(LiveSlot):
    """native_gateway.py as lanzar-encargos.sh starts it, against a Gateway binary that has no task."""

    def gateway(self, *flags):
        (self.root / "r.json").write_text('{"cancellations": {}, "results": [], "closures": {}}')
        started = subprocess.Popen(
            [sys.executable, str(GATEWAY), "--openclaw-bin", str(FAKE_R), "--host-id", "mac-local",
             "--expect-url", "ws://127.0.0.1:1", "--host-state-dir", str(self.spool), "--state-root", str(self.state),
             "--evidence-root", str(self.root / "evidence"), "--progress-state-dir", str(self.root / "progress"),
             "--progress-client", "unused", "--watch", "--cli-instance-id", "enc-1", "--cli-tmux-socket", self.socket,
             "--tmux-bin", TMUX, "--workspace-root", str(self.root / "dev"), "--opencode-bin", str(self.bin / "opencode"),
             "--slot-group", SLOT_GROUP, *flags],
            env={**os.environ, "FAKE_R_STATE": str(self.root / "r.json"), "FAKE_R_LOG": str(self.root / "r.log")},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: started.poll() is None and (started.kill(), started.communicate()))
        return started

    def test_the_host_beats_holds_its_spool_alone_and_leaves_on_term(self):
        first = self.gateway("--canary")
        deadline = time.monotonic() + 15
        while not (self.root / "r.log").exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        beat = HostBeat.read(self.state)
        self.assertEqual((beat.pid, beat.slot, beat.canary, beat.spool, beat.checkout, beat.cli_version, beat.task_id),
                         (first.pid, "free", True, str(self.spool), str(ROOT), "1.18.35", None))
        self.assertEqual(beat.policy_digest,
                         hashlib.sha256((ROOT / EVIDENCE / "proveedores-permitidos.json").read_bytes()).hexdigest())
        self.assertEqual(json.loads((self.root / "r.log").read_text().splitlines()[0]), {
            "method": "managedTasks.host.claim",
            "params": {"hostId": "mac-local", "adapterId": "opencode", "instanceId": "enc-1"}})
        second = self.gateway()
        try:
            out, err = second.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            self.fail("a second host kept running on the spool the first one holds")
        self.assertEqual((second.returncode, out), (2, ""))
        self.assertIn(f"another host already runs on the spool {self.spool}", err)
        self.assertIsNone(first.poll(), "the second host took the first one down")
        first.terminate()
        first.communicate(timeout=15)
        self.assertEqual(first.returncode, 0)


class LiveCloseOnly(LiveSlot):
    CASE = "hang"

    def test_a_closing_pass_over_a_spool_without_host_kills_the_session_of_a_cancelled_task(self):
        """The reversal of phase 2: `--close-only --slot-group` as the runbook writes it."""
        self.passes(lambda: (self.bin / "seen.json").exists())
        hung = self.seen()["pid"]
        self.assertEqual((self.held(), self.sessions()), (("attempted", "Running", ""), [self.session(), "keeper"]))
        (self.root / "r.json").write_text(json.dumps(
            {"cancellations": {"task-1": "cancel-1"}, "results": [], "closures": {}}))
        closing = subprocess.run(
            [sys.executable, str(GATEWAY), "--openclaw-bin", str(FAKE_R), "--host-id", "mac-local",
             "--expect-url", "ws://127.0.0.1:1", "--host-state-dir", str(self.spool), "--close-only",
             "--slot-group", SLOT_GROUP, "--cli-tmux-socket", self.socket, "--tmux-bin", TMUX],
            env={**os.environ, "FAKE_R_STATE": str(self.root / "r.json"), "FAKE_R_LOG": str(self.root / "r.log")},
            capture_output=True, text=True, timeout=60)
        self.assertEqual((closing.returncode, closing.stderr), (0, ""))
        report = json.loads(closing.stdout)
        self.assertEqual((report["counts"], report["errors"]),
                         ({"reported": 0, "released": 0, "cancelled": 1, "recovered": 0, "closed": 1}, []))
        self.assertEqual([(row["taskId"], row["operation"], row["before"], row["after"]) for row in report["resources"]],
                         [("task-1", "cancelled", ["Running", ""], ["AbsenceVerified", ""])])
        self.assertEqual([(sent["state"], sent["taskId"]) for sent in report["rClosures"]],
                         [("AbsenceVerified", "task-1")])
        self.assertEqual((self.sessions(), slot_group_processes()), (["keeper"], ()))
        with self.assertRaises(ProcessLookupError):
            os.kill(hung, 0)


if __name__ == "__main__":
    unittest.main()
