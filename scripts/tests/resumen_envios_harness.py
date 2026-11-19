#!/usr/bin/env python3
import copy
import json
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

from scripts.resumen_envios.delivery import FakeTransportHub, SimulatedCrash
from scripts.resumen_envios.domain import NoticeKey, OrderKey, SourceReport
from scripts.resumen_envios.history import apply_history
from scripts.resumen_envios.policy import decide_order, next_dispatch_day
from scripts.resumen_envios.render import split_telegram
from scripts.resumen_envios.service import CutService
from scripts.resumen_envios.store import Store
from scripts.tests import resumen_envios_oracle as oracle

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "scripts" / "tests" / "fixtures" / "resumen-envios" / "principal.json"


def load_fixture():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def empty_sources(fixture):
    result = copy.deepcopy(fixture["sources"])
    for source in result:
        source["orders"] = []
        for check in source["checks"]:
            if "expected_count" in check:
                check["expected_count"] = 0
                check["observed_count"] = 0
    return result


def amazon_order(native_id, local_date="2026-11-19", client=None):
    return {
        "platform": "amazon",
        "account": "mx",
        "id": native_id,
        "visible_id": native_id,
        "client": client or ("Cliente " + native_id),
        "modality": "self",
        "action": "ship",
        "state": "pending",
        "deadline": {
            "raw": local_date + "T12:00:00-07:00",
            "timezone": "America/Vancouver",
            "local_date": local_date,
        },
        "first_seen_at": "2026-11-19T08:00:00-07:00",
        "lines": [
            {
                "id": native_id + "-L1",
                "sku": "SKU-" + native_id,
                "internal_sku": "INT-" + native_id,
                "quantity": 1,
            }
        ],
    }


def one_order_fixture(kind="ultimo"):
    fixture = load_fixture()
    fixture["sources"] = empty_sources(fixture)
    fixture["sources"][1]["orders"] = [amazon_order("A")]
    fixture["cut"] = {
        "kind": kind,
        "local_date": "2026-11-19" if kind != "principal" else "2026-11-18",
        "at": "2026-11-19T09:00:00-07:00" if kind != "principal" else "2026-11-18T18:30:00-07:00",
    }
    fixture["times"] = [fixture["cut"]["at"]]
    fixture["history"] = {"complete_since": "2026-01-01T00:00:00Z"}
    return fixture


def reports(fixture):
    return [SourceReport.from_dict(raw) for raw in fixture["sources"]]


def notice(native_id, channel, recipient):
    return NoticeKey.for_order(OrderKey("amazon", "mx", native_id), channel, recipient).as_dict()


class Harness(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="resumen-envios-test-")
        self.root = Path(self.temp.name)
        self.hub = FakeTransportHub()
        self.stores = []

    def tearDown(self):
        for store in self.stores:
            store.close()
        self.temp.cleanup()

    def service(self, fixture, db_name="ledger.sqlite"):
        store = Store(self.root / db_name)
        self.stores.append(store)
        apply_history(store, fixture.get("history", {}))
        return CutService(store, self.hub, self.root / "locks", set(fixture.get("holidays", [])))

    def run_all(self, service, fixture, deliver=True):
        result = None
        for at in fixture.get("times", [fixture["cut"]["at"]]):
            result = service.advance_cut(
                fixture["cut"]["kind"],
                fixture["cut"]["local_date"],
                at,
                reports(fixture),
                deliver=deliver,
            )
        return result

    def cut_id(self, fixture):
        return fixture["cut"]["kind"] + ":" + fixture["cut"]["local_date"]

    def summaries(self, recipient=None):
        return [
            entry
            for entry in self.hub.outbox
            if entry["kind"] == "summary" and (recipient is None or entry["recipient"] == recipient)
        ]

    def test_principal_matches_oracle_and_delivers_content_and_photos(self):
        fixture = load_fixture()
        view = self.run_all(self.service(fixture), fixture)
        expected = oracle.evaluate(fixture)
        eligible = sorted(
            decision["order"]["id"]
            for decision in view["assessment"]["decisions"]
            if decision["outcome"] == "eligible"
        )
        self.assertEqual(expected["eligible_ids"], eligible)
        self.assertEqual(expected["source_statuses"], view["assessment"]["source_statuses"])
        self.assertEqual("pending", view["cut"]["state"])
        self.assertEqual(6, len(eligible))
        text = "\n".join(entry["content"] for entry in self.summaries())
        for required in (
            "PANEL-PACK",
            "PANEL-CONF",
            "pago pendiente",
            "SKU interno por confirmar",
            "Texto exacto L1",
            "Texto exacto L2",
        ):
            self.assertIn(required, text)
        for forbidden in (
            "A-DONE",
            "A-FUTURE",
            "ML-CANCEL",
            "ML-SHIPPED",
            "fixture://foto-prohibida",
        ):
            self.assertNotIn(forbidden, text)
        for recipient in ("operation", "david", "isabel"):
            self.assertEqual(1, self.summaries(recipient)[0]["content"].count("A-NEW"))
        photos = [entry for entry in self.hub.outbox if entry["kind"] == "photo"]
        self.assertEqual(3, len(photos))
        self.assertEqual(
            {"L2"},
            {member["line"]["native_line_id"] for photo in photos for member in photo["members"]},
        )
        self.assertLess(
            max(index for index, entry in enumerate(self.hub.outbox) if entry["kind"] == "summary"),
            min(index for index, entry in enumerate(self.hub.outbox) if entry["kind"] == "photo"),
        )

    def test_photo_recovery_sends_only_missing_line_and_can_complete_cut(self):
        fixture = load_fixture()
        service = self.service(fixture)
        self.run_all(service, fixture)
        previous = len(self.hub.outbox)
        for source in fixture["sources"]:
            if source["key"] == "amazon_mx_easy":
                source["orders"][0]["lines"][0]["customization"]["preview"] = (
                    "fixture://preview-line-1"
                )
                source["orders"][1]["lines"][0]["customization"]["preview"] = (
                    "fixture://preview-line-1"
                )
        fixture["cut"] = {
            "kind": "temprano",
            "local_date": "2026-11-19",
            "at": "2026-11-19T05:00:00-07:00",
        }
        fixture["times"] = [fixture["cut"]["at"]]
        view = self.run_all(service, fixture)
        new_entries = self.hub.outbox[previous:]
        self.assertEqual(3, len(new_entries))
        self.assertTrue(all(entry["kind"] == "photo" for entry in new_entries))
        self.assertEqual(
            {"L1"},
            {
                member["line"]["native_line_id"]
                for entry in new_entries
                for member in entry["members"]
            },
        )
        self.assertEqual("complete", view["cut"]["state"])
        self.assertEqual("complete", service.close_cut("principal:2026-11-18"))

    def test_flex_failure_is_partial_and_repaso_recovers_only_flex(self):
        fixture = load_fixture()
        fixture["sources"] = [
            source for source in fixture["sources"] if source["key"] != "amazon_seller_flex"
        ]
        service = self.service(fixture)
        view = self.run_all(service, fixture)
        self.assertEqual("partial", view["cut"]["state"])
        self.assertIn("Resumen parcial", "\n".join(entry["content"] for entry in self.summaries()))
        flex_fixture = load_fixture()
        flex_fixture["cut"] = {
            "kind": "temprano",
            "local_date": "2026-11-19",
            "at": "2026-11-19T05:00:00-07:00",
        }
        flex_fixture["times"] = [flex_fixture["cut"]["at"]]
        before = len(self.hub.outbox)
        self.run_all(service, flex_fixture)
        new_summaries = [entry for entry in self.hub.outbox[before:] if entry["kind"] == "summary"]
        self.assertTrue(new_summaries)
        for entry in new_summaries:
            self.assertIn("A-FLEX", entry["content"])
            self.assertNotIn("A-PAY", entry["content"])

    def test_repaso_works_without_main_list(self):
        fixture = load_fixture()
        fixture["cut"] = {
            "kind": "temprano",
            "local_date": "2026-11-19",
            "at": "2026-11-19T05:00:00-07:00",
        }
        fixture["times"] = [fixture["cut"]["at"]]
        view = self.run_all(self.service(fixture), fixture)
        self.assertEqual(
            6,
            len(
                [
                    decision
                    for decision in view["assessment"]["decisions"]
                    if decision["outcome"] == "eligible"
                ]
            ),
        )
        self.assertTrue(self.summaries())

    def test_incomplete_without_orders_never_claims_empty(self):
        fixture = load_fixture()
        fixture["sources"] = empty_sources(fixture)
        fixture["sources"][3]["checks"][0]["ok"] = False
        fixture["sources"][3]["checks"][0]["reason"] = "timeout ficticio"
        view = self.run_all(self.service(fixture), fixture)
        self.assertEqual("partial", view["cut"]["state"])
        self.assertFalse(self.summaries())
        notices = [entry for entry in self.hub.outbox if entry["kind"] == "cut_notice"]
        self.assertEqual(2, len(notices))
        self.assertTrue(all("Revisión incompleta" in entry["content"] for entry in notices))
        self.assertTrue(all("Sin pedidos" not in entry["content"] for entry in notices))

    def test_complete_empty_principal_only_sends_short_telegram(self):
        fixture = load_fixture()
        fixture["sources"] = empty_sources(fixture)
        view = self.run_all(self.service(fixture), fixture)
        self.assertEqual("complete", view["cut"]["state"])
        self.assertEqual(2, len(self.hub.outbox))
        self.assertTrue(
            all(
                entry["kind"] == "cut_notice" and entry["channel"] == "telegram"
                for entry in self.hub.outbox
            )
        )
        self.assertTrue(all("Sin pedidos" in entry["content"] for entry in self.hub.outbox))

    def test_complete_repaso_without_extras_sends_nothing(self):
        fixture = load_fixture()
        fixture["sources"] = empty_sources(fixture)
        fixture["cut"] = {
            "kind": "temprano",
            "local_date": "2026-11-19",
            "at": "2026-11-19T05:00:00-07:00",
        }
        fixture["times"] = [fixture["cut"]["at"]]
        view = self.run_all(self.service(fixture), fixture)
        self.assertEqual("complete", view["cut"]["state"])
        self.assertEqual([], self.hub.outbox)

    def test_new_due_today_enters_last_and_payment_change_does_not_reopen(self):
        fixture = one_order_fixture()
        service = self.service(fixture)
        self.run_all(service, fixture)
        self.assertEqual(3, len(self.summaries()))
        fixture["sources"][1]["orders"][0]["payment_pending"] = False
        fixture["cut"] = {
            "kind": "temprano",
            "local_date": "2026-11-20",
            "at": "2026-11-20T05:00:00-07:00",
        }
        fixture["times"] = [fixture["cut"]["at"]]
        self.run_all(service, fixture)
        self.assertEqual(3, len(self.summaries()))

    def test_asymmetric_a_then_b_uses_recipient_coverage(self):
        fixture = one_order_fixture()
        fixture["sources"][1]["orders"].append(amazon_order("B"))
        fixture["history"]["confirmed"] = [
            notice("A", "email", "operation"),
            notice("A", "telegram", "david"),
        ]
        fixture["history"]["open"] = [notice("A", "telegram", "isabel")]
        view = self.run_all(self.service(fixture), fixture)
        self.assertEqual("complete", view["cut"]["state"])
        operation = self.summaries("operation")[0]["content"]
        david = self.summaries("david")[0]["content"]
        isabel = self.summaries("isabel")[0]["content"]
        self.assertNotIn("SKU-A ", operation)
        self.assertIn("SKU-B ", operation)
        self.assertNotIn("SKU-A ", david)
        self.assertIn("SKU-B ", david)
        self.assertIn("SKU-A ", isabel)
        self.assertIn("SKU-B ", isabel)

    def test_interruption_after_first_delivery_resumes_only_missing(self):
        fixture = one_order_fixture()
        service = self.service(fixture)
        self.run_all(service, fixture, deliver=False)
        with self.assertRaises(SimulatedCrash):
            service.runner().deliver_pending(current_cut=self.cut_id(fixture), stop_after=1)
        self.assertEqual(1, len(self.hub.outbox))
        view = service.resume_cut(self.cut_id(fixture))
        self.assertEqual(3, len(self.hub.outbox))
        self.assertEqual(3, len({entry["unit_id"] for entry in self.hub.outbox}))
        self.assertEqual("complete", view["cut"]["state"])

    def test_crash_after_accept_is_reconciled_not_repeated(self):
        fixture = one_order_fixture()
        service = self.service(fixture)
        self.run_all(service, fixture, deliver=False)
        first = sorted(
            service.store.pending_units(), key=lambda unit: (unit["created_at"], unit["id"])
        )[0]
        self.hub.rules[first["id"]] = "crash_after_accept"
        with self.assertRaises(SimulatedCrash):
            service.runner().deliver_pending(current_cut=self.cut_id(fixture))
        self.assertEqual(1, len(self.hub.outbox))
        self.assertEqual(1, len(service.store.attempts(("in_flight",))))
        view = service.resume_cut(self.cut_id(fixture))
        self.assertEqual(3, len(self.hub.outbox))
        self.assertEqual(3, len({entry["unit_id"] for entry in self.hub.outbox}))
        self.assertEqual("complete", view["cut"]["state"])

    def test_unsealed_plan_units_are_not_deliverable(self):
        fixture = one_order_fixture()
        service = self.service(fixture)
        original = service.store.create_unit
        checked = {"done": False}

        def resume_during_plan(*args, **kwargs):
            unit = original(*args, **kwargs)
            if not checked["done"]:
                checked["done"] = True
                mid = service.resume_cut(self.cut_id(fixture))
                assert mid["cut"]["state"] == "pending"
                assert self.hub.outbox == []
            return unit

        service.store.create_unit = resume_during_plan
        self.run_all(service, fixture, deliver=False)
        self.assertIsNotNone(service.store.get_cut(self.cut_id(fixture))["sealed_revision"])
        self.assertEqual([], self.hub.outbox)
        view = service.resume_cut(self.cut_id(fixture))
        self.assertEqual("complete", view["cut"]["state"])
        self.assertEqual(3, len(self.hub.outbox))
        self.assertEqual(3, len({entry["unit_id"] for entry in self.hub.outbox}))

    def test_advance_recovers_inflight_from_previous_cut(self):
        fixture = one_order_fixture()
        service = self.service(fixture)
        self.run_all(service, fixture, deliver=False)
        first = sorted(
            service.store.pending_units(), key=lambda unit: (unit["created_at"], unit["id"])
        )[0]
        self.hub.rules[first["id"]] = "crash_after_accept"
        with self.assertRaises(SimulatedCrash):
            service.runner().deliver_pending(current_cut=self.cut_id(fixture))
        self.assertEqual(1, len(service.store.attempts(("in_flight",))))
        view = self.run_all(service, fixture)
        self.assertEqual(3, len(self.hub.outbox))
        self.assertEqual(3, len({entry["unit_id"] for entry in self.hub.outbox}))
        self.assertEqual("complete", view["cut"]["state"])

    def test_uncertain_delivery_blocks_automatic_retry(self):
        fixture = one_order_fixture()
        service = self.service(fixture)
        self.run_all(service, fixture, deliver=False)
        first = sorted(
            service.store.pending_units(), key=lambda unit: (unit["created_at"], unit["id"])
        )[0]
        self.hub.rules[first["id"]] = "unknown_after_accept"
        service.runner().deliver_pending(current_cut=self.cut_id(fixture))
        attempt = service.store.attempts(("unknown",))[0]
        self.hub.lookup_rules[attempt["id"]] = "unknown"
        before = len(self.hub.outbox)
        view = service.resume_cut(self.cut_id(fixture))
        self.assertEqual(before, len(self.hub.outbox))
        self.assertEqual("uncertain", service.store.unit(first["id"])["state"])
        self.assertEqual("pending", view["cut"]["state"])

    def test_authoritative_absence_allows_same_part_retry(self):
        fixture = one_order_fixture()
        service = self.service(fixture)
        self.run_all(service, fixture, deliver=False)
        email = next(unit for unit in service.store.pending_units() if unit["channel"] == "email")
        self.hub.rules[email["id"]] = "unknown_without_accept"
        service.runner().deliver_pending(current_cut=self.cut_id(fixture))
        self.hub.rules[email["id"]] = "accepted"
        view = service.resume_cut(self.cut_id(fixture))
        self.assertEqual(3, len(self.hub.outbox))
        self.assertEqual(
            1, len([entry for entry in self.hub.outbox if entry["unit_id"] == email["id"]])
        )
        self.assertEqual("complete", view["cut"]["state"])

    def test_storage_failure_after_accept_recovers_receipt_without_new_send(self):
        fixture = one_order_fixture()
        service = self.service(fixture)
        self.run_all(service, fixture, deliver=False)
        original = service.store.finish_attempt

        def fail(*args, **kwargs):
            raise RuntimeError("fallo ficticio al guardar")

        service.store.finish_attempt = fail
        with self.assertRaises(RuntimeError):
            service.runner().deliver_pending(current_cut=self.cut_id(fixture))
        self.assertEqual(1, len(self.hub.outbox))
        service.store.finish_attempt = original
        view = service.resume_cut(self.cut_id(fixture))
        self.assertEqual(3, len(self.hub.outbox))
        self.assertEqual(3, len({entry["unit_id"] for entry in self.hub.outbox}))
        self.assertEqual("complete", view["cut"]["state"])

    def test_concurrent_resume_has_one_delivery_per_part(self):
        fixture = one_order_fixture()
        first_service = self.service(fixture, "first.sqlite")
        self.run_all(first_service, fixture, deliver=False)
        first_service.store.close()
        barrier = threading.Barrier(2)

        def work(name):
            store = Store(self.root / "first.sqlite")
            self.stores.append(store)
            service = CutService(store, self.hub, self.root / "locks")
            barrier.wait()
            return service.resume_cut(self.cut_id(fixture))

        with ThreadPoolExecutor(max_workers=2) as executor:
            list(executor.map(work, ("a", "b")))
        self.assertEqual(3, len(self.hub.outbox))
        self.assertEqual(3, len({entry["unit_id"] for entry in self.hub.outbox}))

    def test_concurrent_reconciliation_rechecks_attempt_under_lock(self):
        fixture = one_order_fixture()
        first_service = self.service(fixture, "reconcile.sqlite")
        self.run_all(first_service, fixture, deliver=False)
        email = next(
            unit for unit in first_service.store.pending_units() if unit["channel"] == "email"
        )
        self.hub.rules[email["id"]] = "unknown_without_accept"
        first_service.runner().deliver_pending(current_cut=self.cut_id(fixture))
        self.hub.rules[email["id"]] = "accepted"
        first_service.store.close()
        barrier = threading.Barrier(2)

        def work(_):
            store = Store(self.root / "reconcile.sqlite")
            self.stores.append(store)
            service = CutService(store, self.hub, self.root / "locks")
            barrier.wait()
            return service.resume_cut(self.cut_id(fixture))

        with ThreadPoolExecutor(max_workers=2) as executor:
            list(executor.map(work, ("a", "b")))
        self.assertEqual(3, len(self.hub.outbox))
        self.assertEqual(3, len({entry["unit_id"] for entry in self.hub.outbox}))

    def test_concurrent_advance_has_one_sealed_plan(self):
        fixture = one_order_fixture()
        first_service = self.service(fixture, "shared.sqlite")
        first_service.store.close()
        barrier = threading.Barrier(2)

        def work(_):
            store = Store(self.root / "shared.sqlite")
            self.stores.append(store)
            service = CutService(store, self.hub, self.root / "locks")
            barrier.wait()
            return service.advance_cut(
                "ultimo", "2026-11-19", fixture["cut"]["at"], reports(fixture), deliver=False
            )

        with ThreadPoolExecutor(max_workers=2) as executor:
            list(executor.map(work, ("a", "b")))
        store = Store(self.root / "shared.sqlite")
        self.stores.append(store)
        self.assertEqual(3, len(store.pending_units()))
        self.assertEqual(
            1, store.con.execute("SELECT COUNT(*) FROM plans WHERE sealed=1").fetchone()[0]
        )

    def test_more_than_three_and_fifty_parts_preserve_overflow(self):
        fixture = one_order_fixture()
        fixture["sources"][1]["orders"] = [
            amazon_order("O" + str(index).zfill(2), client="X" * 1900) for index in range(51)
        ]
        view = self.run_all(self.service(fixture), fixture)
        david = self.summaries("david")
        isabel = self.summaries("isabel")
        self.assertEqual(50, len(david))
        self.assertEqual(50, len(isabel))
        self.assertEqual("pending", view["cut"]["state"])
        self.assertTrue(any(issue["kind"] == "capacity" for issue in view["issues"]))
        self.assertEqual(
            51, len(self.summaries("operation")[0]["content"].split("<b>Pedido:</b>")) - 1
        )
        telegram_text = "\n".join(entry["content"] for entry in david)
        self.assertNotIn("O50", telegram_text)
        parts, overflow = split_telegram(["x" * 3801])
        self.assertEqual([], parts)
        self.assertEqual([0], overflow)

    def test_unknown_history_goes_to_reconciliation_without_send(self):
        fixture = one_order_fixture()
        fixture["history"] = {}
        view = self.run_all(self.service(fixture), fixture)
        self.assertEqual("pending", view["cut"]["state"])
        self.assertEqual([], self.hub.outbox)
        self.assertTrue(view["issues"])
        self.assertTrue(all(issue["kind"] == "reconciliation" for issue in view["issues"]))

    def test_unreadable_deadline_requires_platform_membership(self):
        fixture = one_order_fixture()
        order = fixture["sources"][1]["orders"][0]
        order["deadline"] = {
            "raw": None,
            "timezone": "America/Vancouver",
            "local_date": None,
            "display": "verify_required",
        }
        view = self.run_all(self.service(fixture), fixture)
        self.assertEqual("partial", view["cut"]["state"])
        self.assertFalse(self.summaries())
        order["deadline"]["membership_evidence"] = "fixture://pertenencia-al-corte"
        order["internal_sku"] = None
        fixture["sources"][1]["orders"][0]["lines"][0]["internal_sku"] = None
        fixture["cut"] = {
            "kind": "temprano",
            "local_date": "2026-11-19",
            "at": "2026-11-19T05:00:00-07:00",
        }
        fixture["times"] = [fixture["cut"]["at"]]
        view = self.run_all(self.service(fixture), fixture)
        self.assertIn("plazo por verificar", self.summaries("david")[0]["content"])
        self.assertIn("SKU interno por confirmar", self.summaries("david")[0]["content"])

    def test_missing_quantity_is_defect_not_a_fictitious_one(self):
        fixture = one_order_fixture()
        del fixture["sources"][1]["orders"][0]["lines"][0]["quantity"]
        view = self.run_all(self.service(fixture), fixture)
        expected = oracle.evaluate(fixture)
        self.assertEqual("incomplete", view["assessment"]["source_statuses"]["amazon_mx_self"])
        self.assertEqual(expected["source_statuses"], view["assessment"]["source_statuses"])
        self.assertEqual("partial", view["cut"]["state"])
        summaries = self.summaries()
        self.assertTrue(summaries)
        text = "\n".join(entry["content"] for entry in summaries)
        self.assertIn("Cantidad:</b> por verificar", text)
        self.assertNotIn("× 0", text)
        self.assertNotIn("× 1", text)

    def test_non_durable_source_is_incomplete(self):
        fixture = load_fixture()
        fixture["sources"][2]["durable"] = False
        view = self.run_all(self.service(fixture), fixture)
        self.assertEqual("incomplete", view["assessment"]["source_statuses"]["amazon_us_self"])
        self.assertEqual("partial", view["cut"]["state"])

    def test_required_view_and_panel_count_gaps_are_incomplete(self):
        for name, source_key in (("guides", "amazon_mx_easy"), ("count", "ml_pack")):
            with self.subTest(name=name):
                fixture = load_fixture()
                if name == "guides":
                    fixture["sources"][0]["checks"] = [
                        check
                        for check in fixture["sources"][0]["checks"]
                        if check["name"] != "guides"
                    ]
                else:
                    fixture["sources"][4]["checks"][0]["observed_count"] = 1
                view = self.run_all(self.service(fixture, name + ".sqlite"), fixture)
                self.assertEqual("incomplete", view["assessment"]["source_statuses"][source_key])
                self.assertEqual("partial", view["cut"]["state"])
                self.assertIn(
                    "Resumen parcial", "\n".join(entry["content"] for entry in self.hub.outbox)
                )

    def test_conflicting_views_never_claim_complete_or_empty(self):
        fixture = load_fixture()
        fixture["sources"] = empty_sources(fixture)
        pending = amazon_order("CONFLICT")
        delivered = copy.deepcopy(pending)
        delivered["state"] = "delivered_to_carrier"
        fixture["sources"][0]["orders"] = [pending, delivered]
        fixture["cut"] = {
            "kind": "principal",
            "local_date": "2026-11-18",
            "at": "2026-11-18T18:30:00-07:00",
        }
        fixture["times"] = [fixture["cut"]["at"]]
        view = self.run_all(self.service(fixture), fixture)
        expected = oracle.evaluate(fixture)
        self.assertEqual(["CONFLICT"], expected["undetermined_ids"])
        self.assertFalse(expected["complete"])
        self.assertEqual(expected["source_statuses"], view["assessment"]["source_statuses"])
        self.assertEqual("partial", view["cut"]["state"])
        self.assertEqual("incomplete", view["assessment"]["source_statuses"]["amazon_mx_easy"])
        self.assertFalse(self.summaries())
        self.assertEqual(2, len(self.hub.outbox))
        self.assertTrue(all("Revisión incompleta" in entry["content"] for entry in self.hub.outbox))
        self.assertTrue(all("Sin pedidos" not in entry["content"] for entry in self.hub.outbox))

    def test_concurrent_different_cuts_do_not_duplicate_obligations(self):
        fixture = one_order_fixture()
        first_service = self.service(fixture, "cuts.sqlite")
        first_service.store.close()
        barrier = threading.Barrier(2)

        def work(kind):
            store = Store(self.root / "cuts.sqlite")
            self.stores.append(store)
            service = CutService(store, self.hub, self.root / "locks")
            barrier.wait()
            at = "2026-11-19T05:00:00-07:00" if kind == "temprano" else "2026-11-19T09:00:00-07:00"
            return service.advance_cut(kind, "2026-11-19", at, reports(fixture), deliver=False)

        with ThreadPoolExecutor(max_workers=2) as executor:
            list(executor.map(work, ("temprano", "ultimo")))
        store = Store(self.root / "cuts.sqlite")
        self.stores.append(store)
        self.assertEqual(3, len(store.pending_units()))
        self.assertEqual(
            2, store.con.execute("SELECT COUNT(*) FROM plans WHERE sealed=1").fetchone()[0]
        )

    def test_failure_during_plan_does_not_leave_sealed_without_units(self):
        fixture = one_order_fixture()
        service = self.service(fixture)
        original = service.store.create_unit
        calls = {"count": 0}

        def fail_on_second_unit(*args, **kwargs):
            calls["count"] += 1
            if calls["count"] == 2:
                raise RuntimeError("fallo ficticio durante el plan")
            return original(*args, **kwargs)

        service.store.create_unit = fail_on_second_unit
        with self.assertRaises(RuntimeError):
            self.run_all(service, fixture, deliver=False)
        self.assertIsNone(service.store.get_cut(self.cut_id(fixture))["sealed_revision"])
        service.store.create_unit = original
        self.run_all(service, fixture, deliver=False)
        self.assertIsNotNone(service.store.get_cut(self.cut_id(fixture))["sealed_revision"])
        self.assertEqual(3, len(service.store.pending_units()))
        view = service.resume_cut(self.cut_id(fixture))
        self.assertEqual("complete", view["cut"]["state"])
        self.assertEqual(3, len({entry["unit_id"] for entry in self.hub.outbox}))

    def test_timezone_transitions_and_business_calendar(self):
        order = amazon_order("TZ", "2026-03-09")
        parsed = SourceReport.from_dict(
            {"key": "amazon_mx_self", "checks": [], "orders": [order]}
        ).orders[0]
        decision = decide_order(
            parsed, "principal", datetime.fromisoformat("2026-03-08T18:30:00-08:00")
        )
        self.assertEqual("eligible", decision.outcome)
        order["deadline"]["local_date"] = "2026-11-02"
        parsed = SourceReport.from_dict(
            {"key": "amazon_mx_self", "checks": [], "orders": [order]}
        ).orders[0]
        decision = decide_order(
            parsed, "principal", datetime.fromisoformat("2026-11-01T18:30:00-07:00")
        )
        self.assertEqual("eligible", decision.outcome)
        self.assertEqual("2026-11-23", next_dispatch_day(datetime(2026, 11, 20).date()).isoformat())


if __name__ == "__main__":
    unittest.main(verbosity=2)
