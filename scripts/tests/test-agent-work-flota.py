#!/usr/bin/env python3
"""El documento flota.v1 de un intento por CLI (SUA-03, 4.7; ensayo I09)."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
sys.path.insert(0, str(ROOT / "scripts"))
import contexto  # noqa: E402
import flota  # noqa: E402
from contracts import OperationKey, RunDir, SessionRecord, operation_id  # noqa: E402
from modelos import POLICY_FILE, ProviderPolicy  # noqa: E402
from sistema_agentes import contrato  # noqa: E402

KEY = OperationKey("mac-local", "task-7", 2, "enc-1")
POTETO = "sha256:" + "a" * 64
TOOLS = "sha256:" + "b" * 64


def stream(model, agent, small="false"):
    provider, _, name = model.partition("/")
    return (
        "timestamp=2026-10-13T00:28:42.563Z level=INFO run=4a0a032c message=stream "
        f"providerID={provider} "
        f"modelID={name} session.id=ses_1 small={small} agent={agent} mode=primary\n"
    )


class Flota(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.state = Path(temp.name)
        op = operation_id(KEY)
        self.run = RunDir.for_operation(self.state, op)
        self.record = SessionRecord.for_operation(self.state, op)
        self.assignment = {
            "hostId": KEY.host_id,
            "taskId": KEY.task_id,
            "generation": KEY.generation,
            "instanceId": KEY.instance_id,
            "resultRef": str(self.run.result),
        }
        self.policy = ProviderPolicy.load(ROOT / POLICY_FILE)
        self.perfil = contexto.perfil(contexto.leer_json(contexto.PERFILES), "exploracion")

    def packaged(self, model="kimi-code-plan-cn/kimi-for-coding", stderr=""):
        self.run.context.mkdir()
        (self.run.context / "poteto.v1.json").write_text(json.dumps({"generation": 1}))
        (self.run.context / "perfil.json").write_bytes(contexto.canonico(self.perfil))
        self.record.context.write_text(json.dumps({"poteto": POTETO, "tools": TOOLS}))
        self.record.argv.write_text(
            json.dumps(["opencode", "run", "-m", model, "--format", "json"])
        )
        self.record.events.write_text("")
        self.record.stderr.write_text(stderr)

    def documento(self):
        return flota.documento(self.assignment, state_dir=self.state, policy=self.policy)

    def test_the_attempt_document_passes_the_contract(self):
        asked = "kimi-code-plan-cn/kimi-for-coding"
        self.packaged(
            stderr=stream("zai-coding-plan/glm-5.3-flash", "title", "true")
            + stream(asked, "build")
            + stream(asked, "poteto-agent")
            + stream(asked, "poteto-agent")
            + stream("zai-coding-plan/glm-5.3", "panel-glm53")
        )
        doc = self.documento()
        self.assertEqual(
            doc,
            {
                "schema": "sistema-agentes.flota.v1",
                "rootId": "task-7",
                "unitId": "task-7",
                "attempt": 2,
                "specialist": "exploracion",
                "host": "mac-local",
                "executor": "opencode",
                "accountRef": "kimi",
                "model": {"id": asked},
                "generation": 1,
                "permissions": [],
                "attestations": [
                    {"what": "poteto", "digest": POTETO},
                    {"what": "profile", "digest": contexto.digest_de_perfil(self.perfil)},
                    {"what": "tools", "digest": TOOLS},
                ],
                "children": [
                    {"agent": "poteto-agent", "model": asked},
                    {"agent": "panel-glm53", "model": "zai-coding-plan/glm-5.3"},
                ],
            },
        )
        self.assertEqual(contrato.validar(doc), [])

    def test_a_model_nobody_can_read_is_null_with_its_reason(self):
        self.packaged(model="openrouter/x")
        doc = self.documento()
        self.assertEqual(
            (doc["model"], doc["accountRef"]),
            ({"id": None, "reason": "opencode no registró ninguna llamada"}, None),
        )
        self.assertEqual(contrato.validar(doc), [])

    def test_a_run_without_a_package_has_no_document(self):
        self.assertIsNone(self.documento())
        self.assertIsNone(flota.escribir(self.assignment, state_dir=self.state, policy=self.policy))
        self.assertFalse(self.run.fleet.exists())
        self.packaged()
        self.record.context.unlink()
        self.assertIsNone(
            self.documento(), "a package without the launcher's digests has no attestation"
        )

    def test_what_was_written_is_not_rewritten(self):
        self.packaged(stderr=stream("kimi-code-plan-cn/kimi-for-coding", "build"))
        path = flota.escribir(self.assignment, state_dir=self.state, policy=self.policy)
        first = path.read_text()
        self.record.stderr.write_text(stream("kimi-code-plan-cn/otro", "build"))
        self.assertEqual(
            flota.escribir(self.assignment, state_dir=self.state, policy=self.policy), path
        )
        self.assertEqual(path.read_text(), first)


if __name__ == "__main__":
    unittest.main()
