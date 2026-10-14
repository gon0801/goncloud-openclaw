#!/usr/bin/env python3
"""raiz_controlador: a managed root driven through the real R Gateway, and main woken by R (SUA-02, I04).

The requester opens a root and reconciles it with its root tools, as a person's message would.
That turn ends. A unit's result wakes main through R's session queue; the loopback provider acts
as main's model and calls managed_roots_reconcile once with the facts the test gives it; R
accepts the unit and binds and admits the next one with no person's turn in between.

The three plans of the contract (`planes/validos/`) and one imported Plans.md open the same way.
No host process runs: R's own store reports a result with the task's producer capability, so the
case touches no slot group and no host of this machine.
"""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "tests"))
sys.path.insert(0, str(ROOT / "scripts"))
from sistema_agentes.importar_plans import importar  # noqa: E402
from test_agent_work_main_cli_loop_e2e import ADAPTER, HOST_ID, LoopGateway, built_runtime  # noqa: E402

PLANS = ROOT / "scripts/tests/fixtures/sistema-agentes/planes/validos"
BRIEF = b"Implement the unit and return ready.v1 with its evidence.\n"
DIGEST = hashlib.sha256(BRIEF).hexdigest()
REPO = "owner-01/repo-a"
AUTHORITY = {
    "actions": ["implement"],
    "repos": [REPO],
    "accounts": [],
    "destinations": [],
    "deadline": None,
    "mode": "implement",
}
ASSIGNMENT = {
    "target": {"kind": "cli", "hostId": HOST_ID, "adapterId": ADAPTER},
    "instructionRef": {"ref": f"artifact:{DIGEST}", "digest": f"sha256:{DIGEST}"},
    "inputRevision": {"kind": "code", "repository": "fixture", "sha": "a" * 40},
    "resultContract": "ready.v1",
    "continuation": {"kind": "requester"},
}
EVIDENCE = {"evidenceRef": "evidence/a.txt"}


def ready_result():
    """A ready.v1 result as a producer reports it."""
    payload = json.dumps(EVIDENCE, separators=(",", ":"), sort_keys=True).encode()
    return {
        "kind": "produced",
        "payload": EVIDENCE,
        "artifactRef": "artifact:evidence",
        "digest": f"sha256:{hashlib.sha256(payload).hexdigest()}",
        "observedRevision": ASSIGNMENT["inputRevision"],
    }


def unit(unit_id, depends=()):
    return {
        "unitId": unit_id,
        "title": f"Unit {unit_id}",
        "dependsOn": list(depends),
        "criteria": [{"criterionId": f"{unit_id}1", "text": f"{unit_id} passes", "verifier": "verifier"}],
        "scope": {"repos": [REPO], "mode": "implement"},
    }


def coverage_of(plan):
    """A request of one line per criterion and per assumption, each covering what it names."""
    lines, coverage = [], []
    for item in plan["units"]:
        for criterion in item["criteria"]:
            lines.append(criterion["text"])
            coverage.append(
                {"sentence": criterion["text"], "role": "criterion", "criterionIds": [criterion["criterionId"]]}
            )
    for assumption in plan["assumptions"]:
        lines.append(assumption)
        coverage.append({"sentence": assumption, "role": "assumption"})
    return {"text": "\n".join(lines), "coverage": coverage}


class RaizControladorE2E(unittest.TestCase):
    def setUp(self):
        self.runtime = built_runtime(self)
        temp = tempfile.TemporaryDirectory(prefix="agent-work-raiz-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.facts = self.root / "facts.json"
        self.facts.write_text("{}")
        self.gateway = LoopGateway(self.runtime, self.root, extra_env={
            "CROSS_ROOT_REQUESTERS": "1", "CROSS_PROVIDER_SCRIPT": "root-reconcile",
            "CROSS_TOOLS_PROFILE": "full", "CROSS_ROOT_FACTS": str(self.facts),
        })
        self.addCleanup(self.gateway.close)
        # The brief lives in the Gateway's instruction root, where a woken turn reads it too.
        (self.gateway.state_dir / DIGEST).write_bytes(BRIEF)

    def root_tool(self, action, args, run_id="person-turn"):
        return self.gateway.call("roottool", action=action, args=args, runId=run_id)

    def read(self, root_id):
        return self.gateway.call("rpc", method="managedTasks.root.read", params={"rootId": root_id})

    def open_root(self, key, request, plan):
        opened = self.root_tool("open", {"idempotencyKey": key, "request": request,
                                         "authority": AUTHORITY, "plan": plan})
        self.assertTrue(opened.get("ok"), opened)
        return opened["value"]["rootId"]

    def test_the_turn_ends_and_the_root_continues(self):
        plan = {"units": [unit("a"), unit("b", ["a"])], "assumptions": []}
        root_id = self.open_root("raiz-a-b", coverage_of(plan), plan)
        first = self.root_tool("reconcile", {
            "rootId": root_id,
            "facts": {"assignments": [{"unitId": "a", "assignment": ASSIGNMENT, "relay": False}]},
        })
        self.assertEqual([c["unitId"] for c in first["decision"]["createdAttempts"]], ["a"], first)
        self.assertEqual(first["admitted"][0]["admission"]["state"], "host-pending", first)
        # The person's turn is over. What main brings when R wakes it for a: a's claim and b's brief.
        self.facts.write_text(json.dumps({"a": {
            "assignments": [{"unitId": "b", "assignment": ASSIGNMENT, "relay": False}],
            "claims": [{
                "planRevision": 1, "unitId": "a", "attempt": 1, "criterionId": "a1",
                "artifactRef": {"ref": "artifact:check-a", "digest": f"sha256:{'c' * 64}"},
                "environment": {"host": HOST_ID, "versions": {}}, "procedure": "fixture check",
                "outcome": "passed", "at": "2026-10-14T12:00:00Z", "expiresAt": None, "role": "verifier",
            }],
            "effects": [],
        }}))
        task_a = self.read(root_id)["units"][0]["taskId"]
        before = len(self.gateway.provider_requests())
        self.gateway.call("report", taskId=task_a, result=ready_result())

        def b_bound():
            units = self.read(root_id)["units"]
            return units if any(u["unitId"] == "b" for u in units) else None

        deadline = time.monotonic() + 120
        units = None
        while units is None and time.monotonic() < deadline:
            units = b_bound()
            time.sleep(0.5)
        self.assertIsNotNone(units, f"b was never bound; provider: {self.gateway.provider_requests()[before:]}")
        self.assertEqual(
            [(u["unitId"], u["attempt"], u["state"]) for u in units],
            [("a", 1, "accepted"), ("b", 1, "admitted")],
        )
        woken = self.gateway.provider_requests()[before:]
        reconciles = [r for r in woken if r["answered"] == "managed_roots_reconcile"]
        # One wake, one reconciliation: the model brought the facts once and R did the rest.
        self.assertEqual(
            [(r["rootWakes"][-1]["rootId"], r["rootWakes"][-1]["unitId"]) for r in reconciles],
            [(root_id, "a")],
        )
        self.assertIn("managed_roots_reconcile", reconciles[0]["toolNames"])
        print(f"RAIZ_CONTROLADOR_TURN_ENDS root={root_id} provider_requests={len(woken)} "
              f"reconciles={len(reconciles)} units={[(u['unitId'], u['state']) for u in units]}", flush=True)

    def test_three_inputs_open_and_bind_their_ready_units(self):
        cases = {}
        for name in ("pedido-chico", "fila-importada", "pedido-compuesto"):
            fixture = json.loads((PLANS / f"{name}.json").read_text())
            cases[name] = {"units": fixture["plan"]["units"], "assumptions": fixture["plan"]["assumptions"]}
        imported = importar(
            (ROOT / "scripts/tests/fixtures/importar-plans/Plans.md").read_text(encoding="utf-8"),
            ["7.2", "7.3"],
            REPO,
        )
        bound = {}
        for name, plan in cases.items():
            root_id = self.open_root(name, coverage_of(plan), plan)
            ready = [u["unitId"] for u in plan["units"] if not u["dependsOn"]]
            reconciled = self.root_tool("reconcile", {"rootId": root_id, "facts": {"assignments": [
                {"unitId": unit_id, "assignment": ASSIGNMENT, "relay": False} for unit_id in ready
            ]}})
            bound[name] = sorted(c["unitId"] for c in reconciled["decision"]["createdAttempts"])
        # The importer's request covers itself: R accepts its coverage as it comes.
        root_id = self.open_root("plans-7.2-7.3", imported["request"], imported["plan"])
        bound["importado"] = [u["unitId"] for u in self.read(root_id)["unbound"] if u["state"] == "ready"]
        self.assertEqual(bound, {
            "pedido-chico": ["unit-a"],
            "fila-importada": ["unit-a"],
            "pedido-compuesto": ["unit-a", "unit-b"],
            "importado": ["7.2"],
        })
        print(f"RAIZ_CONTROLADOR_THREE_INPUTS bound={json.dumps(bound, sort_keys=True)}", flush=True)


if __name__ == "__main__":
    unittest.main()
