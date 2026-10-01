#!/usr/bin/env python3
"""Behavior tests for the durable Mac progress event client."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


CLI = Path(__file__).resolve().parents[1] / "mac" / "progress-events.py"
SHA = "a" * 40


class ProgressClientTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.input = self.root / "listo.txt"
        self.input.write_text("LISTO " + SHA + "\n", encoding="utf-8")
        self.log = self.root / "calls.jsonl"
        self.mode = self.root / "mode"
        self.mode.write_text("ok")
        self.bin = self.root / "openclaw"
        self.bin.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
assert args[:2] == ['gateway', 'call'] and args[-1] == '--json'
method = args[2]
params = json.loads(args[args.index('--params') + 1])
with open(os.environ['FAKE_LOG'], 'a') as f:
    f.write(json.dumps({'method':method,'params':params})+'\\n')
mode = pathlib.Path(os.environ['FAKE_MODE']).read_text().strip()
if mode == 'offline':
    sys.exit(1)
if mode == 'lost-ack' and method == 'runbook.progress.event':
    calls = [json.loads(line) for line in pathlib.Path(os.environ['FAKE_LOG']).read_text().splitlines()]
    if len([item for item in calls if item['method'] == 'runbook.progress.event']) == 1:
        sys.exit(1)
if mode == 'warning-prefix':
    print('Config warning: optional plugin was skipped')
if method == 'runbook.progress.get':
    lanes = [{'id':'B3'}] if mode == 'open-race' else []
    if mode == 'worker-conflict':
        lanes = [{'id':'B3','worker':{'id':'new-worker'},'ultimo_evento':{'at':'2026-09-30T12:02:00Z'}}]
    if mode == 'worker-safe-conflict':
        lanes = [{'id':'B3','worker':None,'ultimo_evento':{'at':'2026-09-30T11:59:00Z'}}]
    if mode == 'worker-fractional-conflict':
        lanes = [{'id':'B3','worker':{'id':'worker-1'},'ultimo_evento':{'at':'2026-09-30T12:02:00.500Z'}}]
    if mode == 'worker-native-conflict':
        lanes = [{'id':'B3','worker':{'id':'old-worker'},'ultimo_evento':{'at':'2026-09-30T12:02:00Z'}}]
    print(json.dumps({'ok':True,'revision':7,'doc':{'schema':'runbook-progress.v1','corrida':'run-1','fase':'9','lead':{'actualizado':'now'},'carriles':lanes}}))
elif mode in ('open-race', 'open-race-mismatch') and method == 'runbook.progress.event' and params['kind'] == 'run.opened':
    print(json.dumps({'ok':False,'reason':'corrida ya existe'}))
elif mode == 'legacy-stale' and method == 'runbook.progress.event' and params['kind'] == 'run.opened':
    print(json.dumps({'ok':False,'reason':'legacy projection changed or invalid'}))
elif mode == 'legacy-stale-old' and method == 'runbook.progress.event' and params['id'] == 'opened-old':
    print(json.dumps({'ok':False,'reason':'legacy projection changed or invalid'}))
elif mode == 'wrong-sha':
    print(json.dumps({'ok':False,'razon':'SHA revisado distinto'}))
elif mode == 'worker-stale-generation':
    print(json.dumps({'ok':False,'reason':'worker anterior al estado del carril'}))
elif mode in ('revision-conflict-generic', 'worker-conflict', 'worker-fractional-conflict'):
    print(json.dumps({'ok':False,'reason':'revision conflict','revision':7}))
elif mode in ('revision-conflict', 'worker-safe-conflict', 'worker-native-conflict'):
    calls = [json.loads(line) for line in pathlib.Path(os.environ['FAKE_LOG']).read_text().splitlines()]
    events = [item for item in calls if item['method'] == 'runbook.progress.event']
    print(json.dumps({'ok':False,'reason':'revision conflict','revision':7} if len(events) == 1 else {'ok':True,'revision':8}))
else:
    print(json.dumps({'ok':True,'revision':8}))
""")
        self.bin.chmod(0o755)

    def cli(self, *args, ok=True):
        env = dict(os.environ, FAKE_LOG=str(self.log), FAKE_MODE=str(self.mode))
        result = subprocess.run([sys.executable, str(CLI), "--state-dir", str(self.state),
                                 "--openclaw-bin", str(self.bin), *args],
                                text=True, capture_output=True, env=env)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def ready(self, *extra, ok=True):
        return self.cli("record-ready", "--corrida", "run-1", "--carril", "B3",
                        "--intento", "try-1", "--ronda", "1", "--sha", SHA,
                        "--evidence-file", str(self.input), *extra, ok=ok)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_duplicate_preserves_original_evidence_and_event(self):
        first = json.loads(self.ready().stdout)
        event = self.state / "runs" / "run-1" / "queue" / (first["id"] + ".json")
        evidence = self.state / "runs" / "run-1" / "evidence" / (first["id"] + ".json")
        original = evidence.read_bytes()
        second = json.loads(self.ready().stdout)
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(original, evidence.read_bytes())
        self.assertEqual(len(list(event.parent.glob("*.json"))), 1)
        self.assertEqual(json.loads(event.read_text())["evidence"]["sha"], hashlib.sha256(original).hexdigest())

    def test_conflicting_content_for_same_round_is_rejected(self):
        self.ready()
        self.input.write_text("LISTO " + SHA + "\nchanged\n")
        self.ready(ok=False)
        self.assertEqual(len(list((self.state / "runs" / "run-1" / "evidence").glob("*.json"))), 1)

    def test_wrong_sha_rejected_locally_and_by_gateway(self):
        self.ready("--sha", "bad", ok=False)
        self.ready("--sha", "b" * 40, ok=False)
        self.assertFalse((self.state / "runs").exists())
        self.ready()
        self.mode.write_text("wrong-sha")
        self.cli("publish", "--corrida", "run-1", ok=False)
        self.assertEqual(len(list((self.state / "runs" / "run-1" / "queue").glob("*.json"))), 1)

    def test_verdict_is_saved_with_reviewed_sha_and_hash(self):
        self.input.write_text("VEREDICTO aprobado " + SHA + "\n")
        result = self.cli("record-verdict", "--corrida", "run-1", "--carril", "B3",
                          "--intento", "try-1", "--ronda", "1", "--sha", SHA,
                          "--verdict", "aprobado", "--evidence-file", str(self.input))
        identifier = json.loads(result.stdout)["id"]
        base = self.state / "runs" / "run-1"
        evidence = json.loads((base / "evidence" / (identifier + ".json")).read_text())
        event = json.loads((base / "queue" / (identifier + ".json")).read_text())
        self.assertEqual(evidence["sha"], SHA)
        self.assertEqual(event["verdict"], "aprobado")
        self.assertEqual(event["evidence"]["ref"], "evidence/" + identifier + ".json")

    def test_invalid_identifiers_do_not_escape_state_dir(self):
        self.ready("--carril", "../B3", ok=False)
        self.cli("publish", "--corrida", "../run-1", ok=False)
        self.assertFalse(self.state.exists())

    def test_offline_publish_retries_same_id(self):
        event_id = json.loads(self.ready("--expected-revision", "7").stdout)["id"]
        self.mode.write_text("offline")
        self.cli("publish", "--corrida", "run-1", ok=False)
        self.mode.write_text("ok")
        self.cli("publish", "--corrida", "run-1")
        attempts = [x["params"] for x in self.calls() if x["method"] == "runbook.progress.event"]
        self.assertEqual([x["id"] for x in attempts], [event_id, event_id])
        self.assertEqual(attempts[0]["evidence"], attempts[1]["evidence"])
        self.assertEqual(len(list((self.state / "runs" / "run-1" / "queue").glob("*.json"))), 0)

    def test_publish_all_retries_offline_queue_without_new_event(self):
        identifier = json.loads(self.ready().stdout)["id"]
        self.mode.write_text("offline")
        self.cli("publish-all", ok=False)
        queued = self.state / "runs" / "run-1" / "queue" / (identifier + ".json")
        self.assertTrue(queued.exists())
        self.mode.write_text("ok")
        self.cli("publish-all")
        self.assertFalse(queued.exists())
        self.assertTrue((self.state / "runs" / "run-1" / "sent" / (identifier + ".json")).exists())

    def test_revision_conflict_retries_ready_with_same_identity(self):
        identifier = json.loads(self.ready("--expected-revision", "6").stdout)["id"]
        self.mode.write_text("revision-conflict")
        self.cli("publish", "--corrida", "run-1")
        events = [x["params"] for x in self.calls() if x["method"] == "runbook.progress.event"]
        self.assertEqual([x["expectedRevision"] for x in events], [6, 7])
        self.assertEqual([x["id"] for x in events], [identifier, identifier])

    def test_revision_conflict_retries_round_start_before_ready(self):
        start = {"kind": "round.started", "id": "start-b3-r1", "corrida": "run-1",
                 "at": "2026-09-30T00:00:00Z", "expectedRevision": 6,
                 "carril": "B3", "intento": "try-1", "ronda": 1, "baseSha": SHA}
        source = self.root / "start.json"
        source.write_text(json.dumps(start))
        self.cli("queue-event", "--event-json", str(source))
        self.mode.write_text("revision-conflict")
        self.cli("publish", "--corrida", "run-1")
        events = [x["params"] for x in self.calls() if x["method"] == "runbook.progress.event"]
        self.assertEqual([x["kind"] for x in events], ["round.started", "round.started"])
        self.assertEqual([x["expectedRevision"] for x in events], [6, 7])
        self.assertTrue((self.state / "runs" / "run-1" / "sent" / "start-b3-r1.json").exists())

    def test_stale_worker_cannot_replace_newer_worker(self):
        event = {"kind": "part.worker", "id": "old-worker", "corrida": "run-1",
                 "at": "2026-09-30T12:01:00Z", "expectedRevision": 1,
                 "carril": "B3", "worker": {"id": "old-worker"}, "note": "old"}
        source = self.root / "worker.json"
        source.write_text(json.dumps(event))
        self.cli("queue-event", "--event-json", str(source))
        self.mode.write_text("worker-conflict")
        self.cli("publish", "--corrida", "run-1", ok=False)
        events = [x["params"] for x in self.calls() if x["method"] == "runbook.progress.event"]
        self.assertEqual(len(events), 1)
        self.assertTrue((self.state / "runs" / "run-1" / "rejected" / "old-worker.json").exists())

    def test_worker_rebases_only_if_lane_has_no_newer_worker(self):
        event = {"kind": "part.worker", "id": "worker-1", "corrida": "run-1",
                 "at": "2026-09-30T12:01:00Z", "expectedRevision": 1,
                 "carril": "B3", "worker": {"id": "worker-1"}, "note": "active"}
        source = self.root / "worker.json"
        source.write_text(json.dumps(event))
        self.cli("queue-event", "--event-json", str(source))
        self.mode.write_text("worker-safe-conflict")
        self.cli("publish", "--corrida", "run-1")
        events = [x["params"] for x in self.calls() if x["method"] == "runbook.progress.event"]
        self.assertEqual([x["expectedRevision"] for x in events], [1, 7])

    def test_worker_rebase_compares_fractional_timestamps_as_instants(self):
        event = {"kind": "part.worker", "id": "worker-1", "corrida": "run-1",
                 "at": "2026-09-30T12:02:00Z", "expectedRevision": 1,
                 "carril": "B3", "worker": {"id": "worker-1"}, "note": "old"}
        source = self.root / "worker.json"
        source.write_text(json.dumps(event))
        self.cli("queue-event", "--event-json", str(source))
        self.mode.write_text("worker-fractional-conflict")
        self.cli("publish", "--corrida", "run-1", ok=False)
        events = [x["params"] for x in self.calls() if x["method"] == "runbook.progress.event"]
        self.assertEqual(len(events), 1)
        self.assertTrue((self.state / "runs" / "run-1" / "rejected" / "worker-1.json").exists())

    def test_native_worker_rebases_by_generation_and_quarantines_stale_generation(self):
        event = {"kind": "part.worker", "id": "worker-generation-2", "corrida": "run-1",
                 "at": "2026-09-30T12:02:00Z", "expectedRevision": 1,
                 "carril": "B3", "worker": {"id": "new-worker"}, "note": "successor",
                 "source": "native", "generation": 2}
        source = self.root / "worker.json"
        source.write_text(json.dumps(event))
        self.cli("queue-event", "--event-json", str(source))
        self.mode.write_text("worker-native-conflict")
        self.cli("publish", "--corrida", "run-1")
        sent = self.state / "runs" / "run-1" / "sent" / "worker-generation-2.json"
        self.assertTrue(sent.exists())
        events = [x["params"] for x in self.calls() if x["method"] == "runbook.progress.event"]
        self.assertEqual([x["expectedRevision"] for x in events], [1, 7])
        stale = {**event, "id": "worker-generation-1", "generation": 1}
        source.write_text(json.dumps(stale))
        self.cli("queue-event", "--event-json", str(source))
        self.mode.write_text("worker-stale-generation")
        self.cli("publish", "--corrida", "run-1", ok=False)
        rejected = self.state / "runs" / "run-1" / "rejected" / "worker-generation-1.json"
        self.assertTrue(rejected.exists())
        self.assertEqual(json.loads((rejected.parent / "worker-generation-1.conflict.json").read_text())["reason"], "stale worker")
        self.cli("queue-event", "--event-json", str(source), ok=False)
        self.assertFalse((self.state / "runs" / "run-1" / "queue" / "worker-generation-1.json").exists())

    def test_lost_ack_retries_exact_accepted_command(self):
        self.ready()
        self.mode.write_text("lost-ack")
        self.cli("publish", "--corrida", "run-1", ok=False)
        self.cli("publish", "--corrida", "run-1")
        events = [x["params"] for x in self.calls() if x["method"] == "runbook.progress.event"]
        self.assertEqual(events[0], events[1])

    def test_historical_evidence_records_provenance(self):
        self.input.write_text("LISTO legacy abbreviated\n")
        self.ready(ok=False)
        identifier = json.loads(self.ready("--historical", "--source", "u3a-transcript").stdout)["id"]
        base = self.state / "runs" / "run-1"
        evidence = json.loads((base / "evidence" / (identifier + ".json")).read_text())
        event = json.loads((base / "queue" / (identifier + ".json")).read_text())
        self.assertTrue(evidence["historical"])
        self.assertEqual(evidence["source"], "u3a-transcript")
        self.assertEqual(evidence["contentHash"], hashlib.sha256(self.input.read_bytes()).hexdigest())
        self.assertEqual(event["source"], "historical:u3a-transcript")

    def test_run_opened_publishes_before_later_event(self):
        generic = {"kind": "run.opened", "id": "opened-1", "corrida": "run-1", "at": "2026-09-30T00:00:00Z",
                   "doc": {"schema": "runbook-progress.v1", "corrida": "run-1"}, "roundBudget": {"B3": 2}}
        self.ready("--expected-revision", "7")
        source = self.root / "event.json"
        source.write_text(json.dumps(generic))
        self.cli("queue-event", "--event-json", str(source))
        self.cli("publish", "--corrida", "run-1")
        events = [x["params"] for x in self.calls() if x["method"] == "runbook.progress.event"]
        self.assertEqual([x["kind"] for x in events], ["run.opened", "round.ready"])

    def test_sync_writes_views_from_one_gateway_revision(self):
        estado = self.root / "estado.md"
        phase = self.root / "phase.json"
        self.cli("sync", "--corrida", "run-1", "--estado", str(estado), "--phase-json", str(phase))
        payload = json.loads(phase.read_text())
        metadata = json.loads(Path(str(phase) + ".revision.json").read_text())
        self.assertEqual(metadata["revision"], 7)
        self.assertEqual(payload["schema"], "runbook-progress.v1")
        self.assertIn("revisión: 7", estado.read_text())
        self.assertIn(metadata["syncedAt"], estado.read_text())
        state_doc = json.loads(estado.read_text().split("```json\n", 1)[1].split("\n```", 1)[0])
        self.assertEqual(state_doc, payload)

    def test_gateway_warning_before_json_is_ignored(self):
        self.mode.write_text("warning-prefix")
        phase = self.root / "phase.json"
        self.cli("sync", "--corrida", "run-1", "--estado", str(self.root / "estado.md"),
                 "--phase-json", str(phase))
        self.assertEqual(json.loads(phase.read_text())["corrida"], "run-1")

    def test_generic_conflict_rejects_original_command_and_unblocks_queue(self):
        event = {"kind": "attention.changed", "id": "attention-1", "corrida": "run-1",
                 "at": "2026-09-30T00:00:00Z", "expectedRevision": 6,
                 "necesaria": True, "motivo": "esperando revisión"}
        source = self.root / "event.json"
        source.write_text(json.dumps(event))
        self.cli("queue-event", "--event-json", str(source))
        queued = self.state / "runs" / "run-1" / "queue" / "attention-1.json"
        before = queued.read_bytes()
        self.mode.write_text("revision-conflict-generic")
        failed = self.cli("publish", "--corrida", "run-1", ok=False)
        self.assertIn("revision conflict", failed.stderr)
        self.assertFalse(queued.exists())
        rejected = self.state / "runs" / "run-1" / "rejected" / "attention-1.json"
        self.assertEqual(rejected.read_bytes(), before)
        metadata = json.loads((rejected.parent / "attention-1.conflict.json").read_text())
        self.assertEqual(metadata["revision"], 7)
        self.assertFalse((self.state / "runs" / "run-1" / "sent" / "attention-1.json").exists())
        self.assertEqual(json.loads(self.cli("publish", "--corrida", "run-1").stdout)["published"], 0)

    def test_import_race_retires_matching_open_and_publishes_worker(self):
        opened = {"kind": "run.opened", "id": "opened-1", "corrida": "run-1",
                  "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1", "carriles": [{"id": "B3"}]},
                  "roundBudget": {"B3": 2}}
        worker = {"kind": "part.worker", "id": "worker-1", "corrida": "run-1",
                  "at": "2026-09-30T00:00:01Z", "carril": "B3", "worker": {}, "note": "activo"}
        for name, event in (("open", opened), ("worker", worker)):
            source = self.root / (name + ".json")
            source.write_text(json.dumps(event))
            self.cli("queue-event", "--event-json", str(source))
        self.mode.write_text("open-race")
        self.cli("publish", "--corrida", "run-1")
        base = self.state / "runs" / "run-1"
        self.assertTrue((base / "superseded" / "opened-1.json").exists())
        self.assertEqual(json.loads((base / "superseded" / "opened-1.superseded.json").read_text())["revision"], 7)
        self.assertTrue((base / "sent" / "worker-1.json").exists())

    def test_import_race_with_missing_lane_keeps_open_queued(self):
        opened = {"kind": "run.opened", "id": "opened-1", "corrida": "run-1",
                  "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1", "carriles": [{"id": "B3"}]},
                  "roundBudget": {"B3": 2}}
        source = self.root / "open.json"
        source.write_text(json.dumps(opened))
        self.cli("queue-event", "--event-json", str(source))
        self.mode.write_text("open-race-mismatch")
        self.cli("publish", "--corrida", "run-1", ok=False)
        base = self.state / "runs" / "run-1"
        self.assertTrue((base / "queue" / "opened-1.json").exists())
        self.assertFalse((base / "superseded" / "opened-1.json").exists())

    def test_superseded_import_cannot_be_requeued_ahead_of_current_snapshot(self):
        old = {"kind": "run.opened", "id": "opened-old", "corrida": "run-1",
               "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1", "titulo": "old"},
               "roundBudget": {}, "importLegacy": True}
        source = self.root / "open.json"
        source.write_text(json.dumps(old))
        self.cli("queue-event", "--event-json", str(source))
        self.mode.write_text("legacy-stale")
        self.cli("publish", "--corrida", "run-1")
        base = self.state / "runs" / "run-1"
        self.assertTrue((base / "superseded" / "opened-old.json").exists())
        retry = json.loads(self.cli("queue-event", "--event-json", str(source)).stdout)
        self.assertFalse(retry["queued"])
        self.assertFalse((base / "queue" / "opened-old.json").exists())
        # Un segundo publicador pudo haberla puesto en cola antes del archivado.
        (base / "queue" / "opened-old.json").write_bytes((base / "superseded" / "opened-old.json").read_bytes())
        current = {**old, "id": "opened-current", "doc": {"corrida": "run-1", "titulo": "current"}}
        source.write_text(json.dumps(current))
        self.cli("queue-event", "--event-json", str(source))
        self.mode.write_text("legacy-stale-old")
        self.cli("publish", "--corrida", "run-1")
        self.assertTrue((base / "sent" / "opened-current.json").exists())
        self.assertFalse((base / "queue" / "opened-old.json").exists())
        self.assertEqual([call["params"]["id"] for call in self.calls() if call["method"] == "runbook.progress.event"],
                         ["opened-old", "opened-current"])

    def test_crash_after_supersede_metadata_finishes_with_original_decision(self):
        spec = importlib.util.spec_from_file_location("progress_client", CLI)
        client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(client)
        base = self.state / "runs" / "run-1"
        queue = base / "queue"
        queue.mkdir(parents=True)
        doc = {"corrida": "run-1", "carriles": [{"id": "B3"}]}
        event = {"kind": "run.opened", "id": "opened-old", "corrida": "run-1",
                 "at": "2026-09-30T00:00:00Z", "doc": doc, "roundBudget": {}, "importLegacy": True}
        (queue / "opened-old.json").write_bytes(client.encoded(event))
        args = type("Args", (), {"state_dir": str(self.state), "corrida": "run-1"})()
        save = client.create_immutable

        def crash_before_archive(path, data):
            if path.name == "opened-old.json":
                raise OSError("caida")
            return save(path, data)

        with mock.patch.object(client, "gateway", return_value={"ok": False, "reason": "legacy projection changed or invalid"}), \
             mock.patch.object(client, "create_immutable", side_effect=crash_before_archive):
            with self.assertRaises(OSError):
                client.publish(args)
        metadata = base / "superseded" / "opened-old.superseded.json"
        self.assertTrue(metadata.exists())
        self.assertTrue((queue / "opened-old.json").exists())
        with mock.patch.object(client, "gateway", return_value={"ok": False, "reason": "corrida ya existe"}), \
             mock.patch.object(client, "get", return_value={"revision": 1, "doc": doc}):
            client.publish(args)
        self.assertFalse((queue / "opened-old.json").exists())
        self.assertTrue((base / "superseded" / "opened-old.json").exists())
        self.assertEqual(json.loads(metadata.read_text())["reason"], "legacy projection changed or invalid")

    def test_recovery_ignores_changed_remote_lanes(self):
        spec = importlib.util.spec_from_file_location("progress_client", CLI)
        client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(client)
        base = self.state / "runs" / "run-1"
        queue = base / "queue"
        queue.mkdir(parents=True)
        old = {"kind": "run.opened", "id": "opened-old", "corrida": "run-1",
               "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1", "carriles": [{"id": "B3"}]},
               "roundBudget": {}, "importLegacy": True}
        current = {**old, "id": "opened-current", "doc": {"corrida": "run-1", "carriles": [{"id": "B4"}]}}
        (queue / "opened-old.json").write_bytes(client.encoded(old))
        args = type("Args", (), {"state_dir": str(self.state), "corrida": "run-1"})()
        save = client.create_immutable

        def crash_before_archive(path, data):
            if path.name == "opened-old.json":
                raise OSError("caida")
            return save(path, data)

        with mock.patch.object(client, "gateway", return_value={"ok": False, "reason": "legacy projection changed or invalid"}), \
             mock.patch.object(client, "create_immutable", side_effect=crash_before_archive):
            with self.assertRaises(OSError):
                client.publish(args)
        self.assertTrue((base / "superseded" / "opened-old.superseded.json").exists())
        (queue / "opened-current.json").write_bytes(client.encoded(current))
        calls = []

        def remote(_args, _method, event):
            calls.append(event["id"])
            if event["id"] == "opened-old":
                return {"ok": False, "reason": "corrida ya existe"}
            return {"ok": True, "revision": 2}

        with mock.patch.object(client, "gateway", side_effect=remote), \
             mock.patch.object(client, "get", return_value={"revision": 1, "doc": {"corrida": "run-1", "carriles": [{"id": "B4"}]}}):
            client.publish(args)
        self.assertEqual(calls, ["opened-current"])
        self.assertFalse((queue / "opened-old.json").exists())
        self.assertTrue((base / "superseded" / "opened-old.json").exists())
        self.assertTrue((base / "sent" / "opened-current.json").exists())

    def test_recovery_survives_archive_before_queue_removal_and_offline_gateway(self):
        spec = importlib.util.spec_from_file_location("progress_client", CLI)
        client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(client)
        base = self.state / "runs" / "run-1"
        queue = base / "queue"
        queue.mkdir(parents=True)
        event = {"kind": "run.opened", "id": "opened-old", "corrida": "run-1",
                 "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1"},
                 "roundBudget": {}, "importLegacy": True}
        pending = queue / "opened-old.json"
        pending.write_bytes(client.encoded(event))
        args = type("Args", (), {"state_dir": str(self.state), "corrida": "run-1"})()
        with mock.patch.object(client, "gateway", return_value={"ok": False, "reason": "legacy projection changed or invalid"}), \
             mock.patch.object(client.Path, "unlink", side_effect=OSError("caida")):
            with self.assertRaises(OSError):
                client.publish(args)
        archive = base / "superseded" / pending.name
        self.assertTrue(archive.exists())
        self.assertTrue(pending.exists())
        original_decision = archive.with_suffix(".superseded.json").read_bytes()
        with mock.patch.object(client, "gateway", side_effect=AssertionError("consulta remota durante recuperación")):
            client.publish(args)
            client.publish(args)
        self.assertFalse(pending.exists())
        self.assertEqual(archive.read_bytes(), client.encoded(event))
        self.assertEqual(archive.with_suffix(".superseded.json").read_bytes(), original_decision)

    def test_recovery_rejects_mismatched_identity_and_requeue(self):
        spec = importlib.util.spec_from_file_location("progress_client", CLI)
        client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(client)
        base = self.state / "runs" / "run-1"
        queue = base / "queue"
        queue.mkdir(parents=True)
        event = {"kind": "run.opened", "id": "opened-old", "corrida": "run-1",
                 "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1", "carriles": [{"id": "B3"}]},
                 "roundBudget": {}, "importLegacy": True}
        pending = queue / "opened-old.json"
        pending.write_bytes(client.encoded(event))
        client.supersede_import(base, pending, event, "legacy projection changed or invalid")
        archive = base / "superseded" / pending.name
        original_archive = archive.read_bytes()
        source = self.root / "event.json"
        source.write_bytes(client.encoded(event))
        self.assertFalse(json.loads(self.cli("queue-event", "--event-json", str(source)).stdout)["queued"])
        changed = {**event, "doc": {"corrida": "run-1", "carriles": [{"id": "B4"}]}}
        source.write_bytes(client.encoded(changed))
        self.assertIn("no coinciden", self.cli("queue-event", "--event-json", str(source), ok=False).stderr)
        pending.write_bytes(client.encoded(changed))
        with mock.patch.object(client, "gateway", side_effect=AssertionError("envío de evento ajeno")):
            with self.assertRaisesRegex(ValueError, "no coinciden"):
                client.publish(type("Args", (), {"state_dir": str(self.state), "corrida": "run-1"})())
        for invalid in ({**event, "id": "another-id"}, {**event, "corrida": "another-run"}):
            with self.assertRaises(ValueError):
                client.recover_superseded_import(base, pending, invalid)
        self.assertEqual(archive.read_bytes(), original_archive)
        self.assertTrue(pending.exists())

    def test_recovery_rejects_unverifiable_metadata(self):
        spec = importlib.util.spec_from_file_location("progress_client", CLI)
        client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(client)
        base = self.state / "runs" / "run-1"
        queue = base / "queue"
        queue.mkdir(parents=True)
        event = {"kind": "run.opened", "id": "opened-old", "corrida": "run-1",
                 "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1"},
                 "roundBudget": {}, "importLegacy": True}
        pending = queue / "opened-old.json"
        pending.write_bytes(client.encoded(event))
        decision = base / "superseded" / "opened-old.superseded.json"
        decision.parent.mkdir(parents=True)
        decision.write_text(json.dumps({"id": "opened-old", "reason": "legacy projection changed or invalid"}))
        with self.assertRaisesRegex(ValueError, "sin hash verificable"):
            client.publish(type("Args", (), {"state_dir": str(self.state), "corrida": "run-1"})())
        self.assertTrue(pending.exists())
        self.assertFalse((decision.parent / "opened-old.json").exists())
        decision.write_text("{")
        with self.assertRaisesRegex(ValueError, "metadatos de importación inválidos"):
            client.publish(type("Args", (), {"state_dir": str(self.state), "corrida": "run-1"})())
        self.assertTrue(pending.exists())

    def test_recovery_converges_for_two_publishers(self):
        spec = importlib.util.spec_from_file_location("progress_client", CLI)
        client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(client)
        base = self.state / "runs" / "run-1"
        queue = base / "queue"
        queue.mkdir(parents=True)
        event = {"kind": "run.opened", "id": "opened-old", "corrida": "run-1",
                 "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1"},
                 "roundBudget": {}, "importLegacy": True}
        pending = queue / "opened-old.json"
        pending.write_bytes(client.encoded(event))
        decision_path = base / "superseded" / "opened-old.superseded.json"
        first = {"schema": "progress-import-superseded.v1", "corrida": "run-1", "id": "opened-old",
                 "eventHash": hashlib.sha256(client.encoded(event)).hexdigest(),
                 "reason": "corrida ya existe", "revision": 1, "at": "2026-09-30T00:00:01Z"}
        save = client.create_immutable

        def interleave(path, data):
            if path == decision_path:
                save(path, client.encoded(first))
            return save(path, data)

        with mock.patch.object(client, "create_immutable", side_effect=interleave):
            client.supersede_import(base, pending, event, "legacy projection changed or invalid", 2)
        self.assertEqual(json.loads(decision_path.read_text()), first)
        self.assertFalse(pending.exists())
        self.assertEqual((base / "superseded" / "opened-old.json").read_bytes(), client.encoded(event))

    def test_requeue_during_pending_recovery_is_idempotent(self):
        spec = importlib.util.spec_from_file_location("progress_client", CLI)
        client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(client)
        base = self.state / "runs" / "run-1"
        queue = base / "queue"
        queue.mkdir(parents=True)
        event = {"kind": "run.opened", "id": "opened-old", "corrida": "run-1",
                 "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1"},
                 "roundBudget": {}, "importLegacy": True}
        source = self.root / "open.json"
        source.write_bytes(client.encoded(event))
        pending = queue / "opened-old.json"
        pending.write_bytes(client.encoded(event))
        decision = base / "superseded" / "opened-old.superseded.json"
        decision.parent.mkdir(parents=True)
        decision.write_bytes(client.encoded({
            "schema": "progress-import-superseded.v1", "corrida": "run-1", "id": "opened-old",
            "eventHash": hashlib.sha256(client.encoded(event)).hexdigest(),
            "reason": "legacy projection changed or invalid", "revision": None,
            "at": "2026-09-30T00:00:01Z"}))
        result = json.loads(self.cli("queue-event", "--event-json", str(source)).stdout)
        self.assertEqual(result, {"id": "opened-old", "queued": False, "superseded": True})
        self.assertFalse(pending.exists())
        self.assertEqual((decision.parent / pending.name).read_bytes(), client.encoded(event))
        self.assertEqual(json.loads(self.cli("publish", "--corrida", "run-1").stdout)["published"], 0)
        self.assertFalse(self.calls())

    def test_other_publisher_finishes_archive_during_retry(self):
        spec = importlib.util.spec_from_file_location("progress_client", CLI)
        client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(client)
        base = self.state / "runs" / "run-1"
        queue = base / "queue"
        queue.mkdir(parents=True)
        old = {"kind": "run.opened", "id": "opened-old", "corrida": "run-1",
               "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1"},
               "roundBudget": {}, "importLegacy": True}
        current = {**old, "id": "opened-current"}
        pending = queue / "opened-old.json"
        pending.write_bytes(client.encoded(old))
        (queue / "opened-current.json").write_bytes(client.encoded(current))
        decision = base / "superseded" / "opened-old.superseded.json"
        decision.parent.mkdir(parents=True)
        decision.write_bytes(client.encoded({
            "schema": "progress-import-superseded.v1", "corrida": "run-1", "id": "opened-old",
            "eventHash": hashlib.sha256(client.encoded(old)).hexdigest(),
            "reason": "legacy projection changed or invalid", "revision": None,
            "at": "2026-09-30T00:00:01Z"}))
        read = Path.read_text
        raced = False
        calls = []

        def other_publisher_finishes(path, *args, **kwargs):
            nonlocal raced
            if path == decision and not raced:
                raced = True
                client.recover_superseded_import(base, pending, old)
            return read(path, *args, **kwargs)

        def remote(_args, _method, event):
            calls.append(event["id"])
            return {"ok": True, "revision": 2}

        args = type("Args", (), {"state_dir": str(self.state), "corrida": "run-1"})()
        with mock.patch.object(client.Path, "read_text", other_publisher_finishes), \
             mock.patch.object(client, "gateway", side_effect=remote):
            client.publish(args)
        self.assertEqual(calls, ["opened-current"])
        self.assertFalse(pending.exists())
        self.assertTrue((base / "superseded" / pending.name).exists())
        self.assertTrue((base / "sent" / "opened-current.json").exists())

    def test_other_publisher_removes_queue_during_recovery_read(self):
        spec = importlib.util.spec_from_file_location("progress_client", CLI)
        client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(client)
        base = self.state / "runs" / "run-1"
        queue = base / "queue"
        queue.mkdir(parents=True)
        event = {"kind": "run.opened", "id": "opened-old", "corrida": "run-1",
                 "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1"},
                 "roundBudget": {}, "importLegacy": True}
        pending = queue / "opened-old.json"
        pending.write_bytes(client.encoded(event))
        client.supersede_import(base, pending, event, "legacy projection changed or invalid")
        pending.write_bytes(client.encoded(event))
        read = Path.read_bytes
        raced = False

        def other_publisher_removes(path):
            nonlocal raced
            if path == pending and not raced:
                raced = True
                path.unlink()
                raise FileNotFoundError(path)
            return read(path)

        with mock.patch.object(client.Path, "read_bytes", other_publisher_removes), \
             mock.patch.object(client, "gateway", side_effect=AssertionError("envío duplicado")):
            client.publish(type("Args", (), {"state_dir": str(self.state), "corrida": "run-1"})())
        self.assertTrue(raced)
        self.assertFalse(pending.exists())
        self.assertEqual((base / "superseded" / pending.name).read_bytes(), client.encoded(event))

    def test_other_publisher_removes_queue_during_publish_scan(self):
        spec = importlib.util.spec_from_file_location("progress_client", CLI)
        client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(client)
        base = self.state / "runs" / "run-1"
        queue = base / "queue"
        queue.mkdir(parents=True)
        old = {"kind": "run.opened", "id": "opened-old", "corrida": "run-1",
               "at": "2026-09-30T00:00:00Z", "doc": {"corrida": "run-1"},
               "roundBudget": {}, "importLegacy": True}
        current = {**old, "id": "opened-current"}
        pending = queue / "opened-old.json"
        pending.write_bytes(client.encoded(old))
        client.supersede_import(base, pending, old, "legacy projection changed or invalid")
        pending.write_bytes(client.encoded(old))
        (queue / "opened-current.json").write_bytes(client.encoded(current))
        read = Path.read_text
        raced = False

        def other_publisher_removes(path, *args, **kwargs):
            nonlocal raced
            if path == pending and not raced:
                raced = True
                path.unlink()
                raise FileNotFoundError(path)
            return read(path, *args, **kwargs)

        calls = []

        def remote(_args, _method, event):
            calls.append(event["id"])
            return {"ok": True, "revision": 2}

        with mock.patch.object(client.Path, "read_text", other_publisher_removes), \
             mock.patch.object(client, "gateway", side_effect=remote):
            client.publish(type("Args", (), {"state_dir": str(self.state), "corrida": "run-1"})())
        self.assertTrue(raced)
        self.assertEqual(calls, ["opened-current"])
        self.assertTrue((base / "sent" / "opened-current.json").exists())


if __name__ == "__main__":
    unittest.main()
