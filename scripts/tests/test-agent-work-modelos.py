#!/usr/bin/env python3
"""Provider policy, opencode catalog, authorize, the refusal phrases and the launch plan (B22).

The catalog fixture is the real output of `/opt/homebrew/bin/opencode models`, opencode 1.18.35, captured
2026-10-13T01:11Z on David's MacBook. Regenerate it when a provider logs in or out and rewrite the counts
below in the same change.
"""

import collections
import copy
import dataclasses
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import typing
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import contracts  # noqa: E402
import contexto  # noqa: E402
import modelos  # noqa: E402
import sesion  # noqa: E402
from modelos import (ByName, Catalog, DefaultModel, ExactModel, ModelId, ModelOutsideGrant, NameIsAmbiguous,  # noqa: E402
                     NameMatchesNothing, ModelNotListed, PermittedModel, PolicyUnreadable, ProviderNotAllowed,
                     ProviderNotConfigured, ProviderPolicy, authorize, explicar)

LISTING = (ROOT / "scripts/tests/fixtures/agent-work/opencode/models-1.18.35.txt").read_text()
POLICY = ROOT / "docs/evidence/agent-work/proveedores-permitidos.json"
COVERAGE = ROOT / "docs/evidence/agent-work/coverage.json"
DEFAULT = ModelId("zai-coding-plan", "glm-5.3-flash")
AWAITING_TODAY = ("claude",)
QWEN_OF_ALIBABA = ("alibaba-token-plan/qwen3.6-flash", "alibaba-token-plan/qwen3.6-plus",
                   "alibaba-token-plan/qwen3.7-max", "alibaba-token-plan/qwen3.7-plus",
                   "alibaba-token-plan/qwen3.8-flash", "alibaba-token-plan/qwen3.8-max")


def catalog(*extra):
    return Catalog.from_listing(LISTING + "\n".join(extra), cli_version="1.18.35", listed_at=0.0)


def ids(models):
    return tuple(str(model) for model in models)


class Policies(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.document = json.loads(POLICY.read_text())

    def write(self, document=None):
        path = self.root / "proveedores-permitidos.json"
        path.write_text(json.dumps(self.document if document is None else document))
        return path

    def without_filters(self):
        for entry in self.document["providers"]:
            entry.pop("models", None)
        return ProviderPolicy.load(self.write())

    def only_deepseek(self):
        return ProviderPolicy.load(self.write({
            "schema": "agent-work.provider-policy.v1", "closed": [],
            "providers": [entry for entry in self.document["providers"] if entry["name"] == "deepseek"]}))


class PolicyFile(Policies):
    def test_the_repo_policy_carries_eight_grants_and_three_closures_each_with_its_citation(self):
        policy = ProviderPolicy.load(POLICY)
        self.assertIsNone(policy.unreadable)
        self.assertEqual([(grant.name, grant.provider, grant.billing) for grant in policy.grants], [
            ("glm", "zai-coding-plan", "subscription"), ("claude", "anthropic", "subscription"),
            ("grok", "xai", "subscription"), ("gpt", "openai", "subscription"), ("muse", "meta", "subscription"),
            ("kimi", "kimi-code-plan-cn", "subscription"), ("qwen", "alibaba-token-plan", "subscription"),
            ("deepseek", "deepseek", "per-token")])
        self.assertEqual([grant.name for grant in policy.grants if grant.models], ["qwen"])
        qwen = policy.grant_for("alibaba-token-plan").models
        self.assertEqual((qwen.include, qwen.exclude, qwen.decision.ref, qwen.decision.on, qwen.decision.quote),
                         (("qwen*",), ("qwen-image*",), "P10890", "2026-10-13",
                          "sí, esos seis modelos de qwen están bien"))
        decisions = ([grant.decision for grant in policy.grants] + [c.decision for c in policy.closed.values()]
                     + [qwen.decision])
        self.assertEqual(len(decisions), 12)
        for decision in decisions:
            self.assertEqual(decision.by, "David")
            self.assertRegex(decision.on, r"^2026-10-(03|12|13)$")
            self.assertRegex(decision.ref, r"^P\d+$")
            self.assertGreater(len(decision.quote), 20)
        self.assertEqual(policy.digest, hashlib.sha256(POLICY.read_bytes()).hexdigest())

    def test_the_closed_providers_are_exactly_these_three_each_with_davids_words(self):
        """The only way to reopen a closed provider is a PR that edits the policy file with David's new
        phrase. No command does it. That PR has to change this test too, in plain sight."""
        closed = ProviderPolicy.load(POLICY).closed
        self.assertEqual({provider: (closure.decision.by, closure.decision.on, closure.decision.ref,
                                     closure.decision.quote) for provider, closure in closed.items()}, {
            "opencode-go": ("David", "2026-10-12", "P10845", "open code go es solamente para main"),
            "opencode": ("David", "2026-10-12", "P10867", "de opencode solo tengo go"),
            "zai": ("David", "2026-10-03", "P9840",
                    "pero open ode debe usar solo zcode sus iption no la suscripcion opencode go ni zen"),
        })

    def test_the_repo_policy_is_already_in_the_format_permitir_writes(self):
        policy = ProviderPolicy.load(POLICY)
        self.assertEqual(modelos.policy_document(policy.grants, policy.closed, policy.default_grant, policy.owner_telegram_chat), POLICY.read_bytes())

    def test_a_grant_without_a_bound_id_never_comes_out_of_grant_for(self):
        # SUA-04 (4.2): un permiso sin id no lleva default, y defaultGrant no lo puede nombrar.
        self.document["providers"][0].pop("default")
        del self.document["defaultGrant"]
        self.document["providers"][0]["provider"] = None
        policy = ProviderPolicy.load(self.write())
        self.assertIsNone(policy.unreadable)
        self.assertIsNone(policy.grant_for("zai-coding-plan"))
        self.assertIsNone(policy.grant_for("glm"))
        self.assertEqual(policy.grant_for("deepseek").name, "deepseek")

    def assert_closes_everything(self, names):
        policy = ProviderPolicy.load(self.write())
        self.assertEqual(policy.grants, ())
        self.assertEqual(dict(policy.closed), {})
        for name in names:
            self.assertIn(name, policy.unreadable)
        self.assertEqual(authorize(DefaultModel(), policy, catalog()), PolicyUnreadable(policy.unreadable))
        self.assertEqual(authorize(ExactModel(DEFAULT), policy, catalog()), PolicyUnreadable(policy.unreadable))
        self.assertEqual(authorize(ByName("glm 5.3 flash"), policy, catalog()), PolicyUnreadable(policy.unreadable))

    def test_an_entry_without_its_quote_closes_the_whole_file_and_names_the_entry(self):
        del self.document["providers"][7]["decision"]["quote"]
        self.assert_closes_everything(["deepseek"])

    def test_an_empty_quote_closes_the_whole_file(self):
        self.document["closed"][0]["decision"]["quote"] = "  "
        self.assert_closes_everything(["opencode-go", "quote"])

    def test_a_billing_outside_the_two_values_closes_the_whole_file(self):
        self.document["providers"][0]["billing"] = "free"
        self.assert_closes_everything(["glm", "billing"])

    def test_a_provider_granted_and_closed_closes_the_whole_file(self):
        self.document["closed"].append({"provider": "meta", "decision": self.document["closed"][0]["decision"]})
        self.assert_closes_everything(["meta"])

    def test_a_model_filter_with_an_empty_or_malformed_pattern_closes_the_whole_file(self):
        for label, change in (
            ("''", lambda models: models.update(include=[""])),
            ("include", lambda models: models.update(include=[])),
            ("'qwen image*'", lambda models: models.update(exclude=["qwen image*"])),
            ("'qwen[36]*'", lambda models: models.update(include=["qwen[36]*"])),
            ("'qwen?'", lambda models: models.update(include=["qwen*", "qwen?"])),
            ("None", lambda models: models.update(exclude=[None])),
            ("exclude", lambda models: models.update(exclude="qwen-image*")),
            ("decision", lambda models: models.pop("decision")),
            ("quote", lambda models: models["decision"].pop("quote")),
            ("include", lambda models: models.update(regex="qwen.*")),
        ):
            with self.subTest(label):
                self.document = json.loads(POLICY.read_text())
                change(self.document["providers"][6]["models"])
                self.assert_closes_everything(["qwen", label])

    def test_a_filter_admits_what_matches_an_include_and_no_exclude(self):
        decision = ProviderPolicy.load(POLICY).grants[0].decision
        only = modelos.ModelFilter(("glm-5.3*", "glm-4.7"), ("*-flash",), decision)
        self.assertEqual([name for name in ("glm-5.3", "glm-5.3-highspeed", "glm-5.3-flash", "glm-4.7", "glm-4.70",
                                            "xglm-5.3", "glm-5x3") if only.admits(name)],
                         ["glm-5.3", "glm-5.3-highspeed", "glm-4.7"])

    def test_an_unknown_key_a_bad_date_or_a_repeated_grant_closes_the_whole_file(self):
        for label, change in (
            ("schema, providers, closed", lambda doc: doc.update(apodos={})),
            ("glm", lambda doc: doc["providers"][0].update(models=["glm-5.3"])),
            ("12-10-2026", lambda doc: doc["providers"][1]["decision"].update(on="12-10-2026")),
            ("2026-13-40", lambda doc: doc["providers"][1]["decision"].update(on="2026-13-40")),
            ("xai", lambda doc: doc["providers"][3].update(provider="xai")),
            ("glm", lambda doc: doc["providers"][4].update(name="glm")),
            ("schema", lambda doc: doc.update(schema="agent-work.provider-policy.v2")),
        ):
            with self.subTest(label):
                self.document = json.loads(POLICY.read_text())
                change(self.document)
                self.assert_closes_everything([label])

    def test_a_missing_file_or_broken_json_permits_nothing(self):
        missing = ProviderPolicy.load(self.root / "no-esta.json")
        self.assertEqual((missing.grants, missing.digest), ((), None))
        self.assertIn("no-esta.json", missing.unreadable)
        self.assertEqual(authorize(DefaultModel(), missing, catalog()), PolicyUnreadable(missing.unreadable))
        broken = self.root / "proveedores-permitidos.json"
        broken.write_text("{")
        policy = ProviderPolicy.load(broken)
        self.assertEqual(policy.grants, ())
        self.assertIn("no es JSON", policy.unreadable)
        self.assertEqual(authorize(DefaultModel(), policy, catalog()), PolicyUnreadable(policy.unreadable))


class ModelIds(unittest.TestCase):
    def test_parse_splits_at_the_first_slash(self):
        self.assertEqual(ModelId.parse("zai-coding-plan/glm-5.3-flash"), DEFAULT)
        self.assertEqual(str(DEFAULT), "zai-coding-plan/glm-5.3-flash")
        self.assertEqual(ModelId.parse("openrouter/anthropic/claude-5:beta@x"),
                         ModelId("openrouter", "anthropic/claude-5:beta@x"))

    def test_parse_refuses_what_is_not_provider_slash_model(self):
        for text in ("glm", "Zai/glm", "/glm", "zai/", "zai/glm 5", "-zai/glm", "zai/glm\n", "zai/" + "a" * 129,
                     "zai/glm;rm", "zai/$(id)"):
            with self.subTest(text):
                self.assertEqual(ModelId.parse(text), modelos.MalformedModel(text))

    def test_a_request_with_one_slashed_word_is_an_exact_id(self):
        self.assertEqual(modelos.pedido(None), DefaultModel())
        self.assertEqual(modelos.pedido("  glm   5.3 "), ByName("glm 5.3"))
        self.assertEqual(modelos.pedido("zai/glm-5.3"), ExactModel(ModelId("zai", "glm-5.3")))
        self.assertEqual(modelos.pedido("Zai/glm"), modelos.MalformedModel("Zai/glm"))


class CatalogPartition(unittest.TestCase):
    def setUp(self):
        self.policy = ProviderPolicy.load(POLICY)
        self.catalog = catalog()

    def test_the_real_listing_counts_216_ids_in_ten_providers(self):
        self.assertEqual(len(self.catalog.models), 216)
        self.assertEqual({provider: len(self.catalog.of(provider)) for provider in (
            "zai-coding-plan", "meta", "openai", "xai", "deepseek", "kimi-code-plan-cn", "alibaba-token-plan",
            "opencode-go", "opencode", "zai", "anthropic")}, {
            "zai-coding-plan": 7, "meta": 6, "openai": 24, "xai": 13, "deepseek": 2, "kimi-code-plan-cn": 4,
            "alibaba-token-plan": 27, "opencode-go": 31, "opencode": 84, "zai": 18, "anthropic": 0})

    def test_every_listed_id_is_permitted_or_refused_by_its_provider_and_none_lacks_a_decision(self):
        permitted, refused, outside = collections.Counter(), collections.Counter(), collections.Counter()
        billing = collections.Counter()
        for model in self.catalog.models:
            answer = authorize(ExactModel(model), self.policy, self.catalog)
            if isinstance(answer, PermittedModel):
                self.assertEqual((answer.model, answer.policy_digest, answer.cli_version),
                                 (model, self.policy.digest, "1.18.35"))
                permitted[model.provider] += 1
                billing[answer.billing] += 1
            elif isinstance(answer, ModelOutsideGrant):
                self.assertEqual((answer.models, [grant.name for grant in answer.grants]), ((model,), ["qwen"]))
                outside[model.provider] += 1
            else:
                self.assertIsInstance(answer, ProviderNotAllowed)
                self.assertEqual(answer.models, (model,))
                self.assertEqual([closure.provider for closure in answer.closures], [model.provider])
                refused[model.provider] += 1
        self.assertEqual(dict(permitted), {"zai-coding-plan": 7, "meta": 6, "openai": 24, "xai": 13, "deepseek": 2,
                                           "kimi-code-plan-cn": 4, "alibaba-token-plan": 6})
        self.assertEqual(dict(outside), {"alibaba-token-plan": 21})
        self.assertEqual(dict(refused), {"opencode-go": 31, "opencode": 84, "zai": 18})
        self.assertEqual((sum(permitted.values()), sum(outside.values()), sum(refused.values())), (62, 21, 133))
        self.assertEqual(dict(billing), {"subscription": 60, "per-token": 2})
        self.assertEqual(set(refused), set(self.policy.closed))

    def test_the_qwen_grant_covers_only_the_six_qwen_text_models_of_the_alibaba_plan(self):
        self.assertEqual(tuple(sorted(str(model) for model in self.catalog.of("alibaba-token-plan")
                                      if isinstance(authorize(ExactModel(model), self.policy, self.catalog),
                                                    PermittedModel))), QWEN_OF_ALIBABA)
        qwen = self.policy.grant_for("alibaba-token-plan")
        for name in ("deepseek-v4-pro", "glm-5.3", "kimi-k2.7-code", "qwen-image-2.0", "qwen-image-2.0-pro",
                     "wan2.7-image", "happyhorse-1.1-t2v", "MiniMax-M2.5"):
            with self.subTest(name):
                model = ModelId("alibaba-token-plan", name)
                self.assertIn(model, self.catalog.models)
                self.assertEqual(authorize(ExactModel(model), self.policy, self.catalog),
                                 ModelOutsideGrant((model,), (qwen,)))

    def test_a_permitted_model_cannot_be_built_or_rewritten_outside_authorize(self):
        closed = ModelId("opencode-go", "deepseek-v4-pro")
        real = authorize(DefaultModel(), self.policy, self.catalog)
        with self.assertRaisesRegex(TypeError, "solo sale de authorize"):
            PermittedModel(closed, "subscription", "digest", "1.18.35")
        with self.assertRaisesRegex(TypeError, "solo sale de authorize"):
            PermittedModel(model=closed, billing="subscription", policy_digest="digest", cli_version="1.18.35")
        with self.assertRaisesRegex(TypeError, "solo sale de authorize"):
            dataclasses.replace(real, model=closed)
        with self.assertRaises(dataclasses.FrozenInstanceError):
            real.model = closed
        self.assertEqual((real.model, real.billing, real.policy_digest, real.cli_version),
                         (DEFAULT, "subscription", self.policy.digest, "1.18.35"))
        self.assertEqual(copy.copy(real), authorize(ExactModel(DEFAULT), self.policy, self.catalog))
        self.assertIn("glm-5.3-flash", repr(real))


class Authorize(Policies):
    def setUp(self):
        super().setUp()
        self.policy = ProviderPolicy.load(POLICY)

    def ask(self, request, *extra, policy=None):
        return authorize(request, policy or self.policy, catalog(*extra))

    def test_a_request_without_a_model_runs_the_default_on_the_subscription(self):
        answer = self.ask(DefaultModel())
        self.assertEqual((answer.model, answer.billing), (DEFAULT, "subscription"))

    def test_a_request_of_an_unknown_kind_never_falls_back_to_the_default_model(self):
        malformed = modelos.pedido("Zai/glm")
        self.assertEqual(self.ask(malformed), modelos.MalformedModel("Zai/glm"))
        for request in (None, "zai-coding-plan/glm-5.3", DEFAULT, object()):
            with self.subTest(request), self.assertRaises(TypeError):
                self.ask(request)

    def test_a_policy_without_a_default_grant_has_no_default_model(self):
        # SUA-04 (4.2): el modelo por omisión sale de defaultGrant, no de un id fijo en el código.
        # Una política que no lo nombra (only_deepseek) no tiene modelo por omisión que correr.
        answer = self.ask(DefaultModel(), policy=self.only_deepseek())
        self.assertIsInstance(answer, modelos.SinModeloPorOmision)

    def test_owner_telegram_chat_is_digits_or_the_policy_does_not_load(self):
        # SUA-04 (4.8): ownerTelegramChat es el chat del dueño y son solo dígitos.
        self.assertEqual(self.policy.owner_telegram_chat, "6470689715")
        self.document["ownerTelegramChat"] = "647o689715"
        policy = ProviderPolicy.load(self.write())
        self.assertEqual(policy.grants, ())
        self.assertIn("ownerTelegramChat", policy.unreadable)

    def test_default_validation_closes_the_policy(self):
        # SUA-04 (4.2): la línea es del proveedor del permiso, el since parsea a esa línea y
        # defaultGrant nombra un permiso que existe y trae default. Si no, nada corre.
        for label, change in (
            ("de su proveedor", lambda doc: doc["providers"][0]["default"].update(line="otro/glm-{}-flash")),
            ("parsea a su línea", lambda doc: doc["providers"][0]["default"].update(since="zai-coding-plan/glm-5.3")),
            ("con default", lambda doc: doc.update(defaultGrant="no-esta")),
            ("con default", lambda doc: doc.update(defaultGrant="claude")),
            ("sin id ligado no lleva default", lambda doc: doc["providers"][1].update(
                provider=None, default={"line": "anthropic/claude-{}", "since": "anthropic/claude-opus-5-5"})),
        ):
            with self.subTest(label):
                self.document = json.loads(POLICY.read_text())
                change(self.document)
                policy = ProviderPolicy.load(self.write())
                self.assertEqual(policy.grants, ())
                self.assertIn(label, policy.unreadable)

    def test_a_request_without_a_model_uses_the_promoted_actual_from_succession(self):
        # SUA-04 (4.2, I10): con sucesion.json, el efectivo es su actual, sin tocar la política.
        state = self.root / "state"
        state.mkdir()
        (state / "sucesion.json").write_text(json.dumps({
            "schema": "agent-work.succession.v1",
            "lines": {"zai-coding-plan/glm-{}-flash": {"actual": "zai-coding-plan/glm-5.4-flash"}}}))
        answer = authorize(DefaultModel(), self.policy, catalog("zai-coding-plan/glm-5.4-flash"),
                           state_root=state)
        self.assertEqual(str(answer.model), "zai-coding-plan/glm-5.4-flash")
        self.assertEqual(modelos.effective_default(self.policy, state),
                         (ModelId("zai-coding-plan", "glm-5.4-flash"), "promovido desde sucesion.json"))

    def test_an_unreadable_succession_falls_back_to_since_with_its_cause(self):
        state = self.root / "state"
        state.mkdir()
        (state / "sucesion.json").write_text("{")
        answer = authorize(DefaultModel(), self.policy, catalog(), state_root=state)
        self.assertEqual(answer.model, DEFAULT)
        model, causa = modelos.effective_default(self.policy, state)
        self.assertEqual(model, DEFAULT)
        self.assertIn("sucesion.json no es JSON", causa)

    def test_a_closed_provider_is_refused_with_davids_words_even_though_the_model_exists(self):
        model = ModelId("opencode-go", "deepseek-v4-pro")
        self.assertIn(model, catalog().models)
        answer = self.ask(ExactModel(model))
        self.assertEqual(answer, ProviderNotAllowed(
            models=(model,), allowed=("glm", "claude", "grok", "gpt", "muse", "kimi", "qwen", "deepseek"),
            closures=(self.policy.closed["opencode-go"],), awaiting_login=AWAITING_TODAY))
        self.assertEqual(self.ask(ExactModel(ModelId("zai", "glm-5.3"))).closures, (self.policy.closed["zai"],))

    def test_the_provider_is_judged_before_the_catalog(self):
        answer = self.ask(ExactModel(ModelId("opencode-go", "no-existe")))
        self.assertEqual(answer.models, (ModelId("opencode-go", "no-existe"),))
        self.assertIsInstance(answer, ProviderNotAllowed)
        self.assertEqual(self.ask(ExactModel(ModelId("mistral", "large"))).closures, ())

    def test_a_granted_provider_that_lists_nothing_is_missing_its_login_not_its_model(self):
        self.assertEqual(self.ask(ExactModel(ModelId("anthropic", "claude-opus-5-5"))),
                         ProviderNotConfigured("claude", "anthropic", "anthropic/claude-opus-5-5"))

    def test_a_model_its_provider_does_not_list_names_the_similar_ones(self):
        self.assertEqual(self.ask(ExactModel(ModelId("zai-coding-plan", "no-existe"))),
                         ModelNotListed(ModelId("zai-coding-plan", "no-existe"), ()))
        answer = self.ask(ExactModel(ModelId("zai-coding-plan", "glm-5.3-flahs")))
        self.assertEqual(answer.similar[0], DEFAULT)

    def test_davids_words_resolve_to_the_one_model_that_holds_them_all(self):
        for words, expected in (("glm 5.3 highspeed", "zai-coding-plan/glm-5.3-highspeed"),
                                ("GLM 5.3 Flash", "zai-coding-plan/glm-5.3-flash"),
                                ("grok 4.7", "xai/grok-4.7"), ("muse wonder", "meta/muse-wonder-1.0"),
                                ("gpt 5.5", "openai/gpt-5.5"), ("qwen3.8 max", "alibaba-token-plan/qwen3.8-max"),
                                ("glm 5.3", "zai-coding-plan/glm-5.3"), ("deepseek v4 pro", "deepseek/deepseek-v4-pro"),
                                ("deepseek flash", "deepseek/deepseek-flash")):
            with self.subTest(words):
                self.assertEqual(str(self.ask(ByName(words)).model), expected)
        self.assertEqual(self.ask(ByName("deepseek v4 pro")).billing, "per-token")

    def test_deepseek_by_name_only_reaches_davids_own_api_account(self):
        self.assertEqual(self.ask(ByName("deepseek")), NameIsAmbiguous(
            "deepseek", (ModelId("deepseek", "deepseek-flash"), ModelId("deepseek", "deepseek-v4-pro")),
            (("deepseek", "per-token"),)))

    def test_words_that_only_match_outside_a_filter_say_the_grant_does_not_cover_them(self):
        qwen = self.policy.grant_for("alibaba-token-plan")
        self.assertEqual(self.ask(ByName("kimi k2.7 code")),
                         ModelOutsideGrant((ModelId("alibaba-token-plan", "kimi-k2.7-code"),), (qwen,)))
        self.assertEqual(self.ask(ByName("wan image")), ModelOutsideGrant(
            (ModelId("alibaba-token-plan", "wan2.7-image"), ModelId("alibaba-token-plan", "wan2.7-image-pro")), (qwen,)))
        self.assertEqual(self.ask(ExactModel(ModelId("alibaba-token-plan", "qwen3.8-maxx"))).similar,
                         (ModelId("alibaba-token-plan", "qwen3.8-max"), ModelId("alibaba-token-plan", "qwen3.7-max"),
                          ModelId("alibaba-token-plan", "qwen3.8-flash")))
        self.assertEqual(self.ask(ExactModel(ModelId("alibaba-token-plan", "qwen-image-2.1"))).similar, ())

    def test_without_the_filter_a_name_in_two_providers_is_ambiguous_and_shows_how_each_one_bills(self):
        self.policy = self.without_filters()
        self.assertEqual(self.ask(ByName("deepseek v4 pro")), NameIsAmbiguous(
            "deepseek v4 pro",
            (ModelId("alibaba-token-plan", "deepseek-v4-pro"), ModelId("alibaba-token-plan", "deepseek-v4-pro-0813"),
             ModelId("deepseek", "deepseek-v4-pro")),
            (("alibaba-token-plan", "subscription"), ("deepseek", "per-token"))))
        answer = self.ask(ByName("deepseek"))
        self.assertEqual(ids(answer.candidates), (
            "alibaba-token-plan/deepseek-v3.2", "alibaba-token-plan/deepseek-v4-flash",
            "alibaba-token-plan/deepseek-v4-flash-0731", "alibaba-token-plan/deepseek-v4-pro",
            "alibaba-token-plan/deepseek-v4-pro-0813", "alibaba-token-plan/deepseek-v4.1-flash",
            "deepseek/deepseek-flash", "deepseek/deepseek-v4-pro"))
        self.assertEqual(answer.billing, (("alibaba-token-plan", "subscription"), ("deepseek", "per-token")))

    def test_a_bare_provider_word_asks_which_of_its_models(self):
        counts = {words: len(self.ask(ByName(words)).candidates)
                  for words in ("glm", "muse", "qwen", "kimi", "grok", "gpt", "kimi k3")}
        self.assertEqual(counts, {"glm": 7, "muse": 6, "qwen": 6, "kimi": 4, "grok": 13, "gpt": 24, "kimi k3": 2})
        self.assertEqual(ids(self.ask(ByName("kimi k3")).candidates),
                         ("kimi-code-plan-cn/k3", "kimi-code-plan-cn/k3-256k"))
        self.assertEqual(ids(self.ask(ByName("qwen")).candidates), QWEN_OF_ALIBABA)
        self.assertEqual(ids(self.ask(ByName("grok imagine")).candidates), (
            "xai/grok-imagine-image", "xai/grok-imagine-image-quality", "xai/grok-imagine-video",
            "xai/grok-imagine-video-1.5", "xai/grok-imagine-video-1.5-lite"))

    def test_the_identical_name_wins_only_when_one_provider_has_it(self):
        self.assertEqual(str(self.ask(ByName("gpt 6 sol")).model), "openai/gpt-6-sol")
        self.assertEqual(str(self.ask(ByName("gpt 6 astra")).model), "openai/gpt-6-astra")
        self.assertEqual(ids(self.ask(ByName("gpt astra")).candidates),
                         ("openai/gpt-6-astra", "openai/gpt-6-astra-fast", "openai/gpt-6-astra-ultrafast"))
        self.assertEqual(ids(self.ask(ByName("glm 5.3"), policy=self.without_filters()).candidates), (
            "alibaba-token-plan/glm-5.3", "zai-coding-plan/glm-5.3", "zai-coding-plan/glm-5.3-flash",
            "zai-coding-plan/glm-5.3-highspeed"))

    def test_a_granted_word_without_models_is_missing_its_login_before_any_closed_match(self):
        self.assertIn(ModelId("opencode", "claude-opus-5-5"), catalog().models)
        self.assertEqual(self.ask(ByName("claude opus")), ProviderNotConfigured("claude", "anthropic", "claude opus"))
        self.document["providers"][5]["provider"] = None
        unbound = ProviderPolicy.load(self.write())
        self.assertEqual(self.ask(ByName("kimi k3"), policy=unbound), ProviderNotConfigured("kimi", None, "kimi k3"))

    def test_once_anthropic_lists_models_claude_resolves_like_any_other_name(self):
        extra = ("anthropic/claude-opus-5-5", "anthropic/claude-fable-5-1")
        self.assertEqual(self.ask(ByName("claude"), *extra), NameIsAmbiguous(
            "claude", (ModelId("anthropic", "claude-fable-5-1"), ModelId("anthropic", "claude-opus-5-5")),
            (("anthropic", "subscription"),)))
        answer = self.ask(ByName("claude opus"), *extra)
        self.assertEqual((str(answer.model), answer.billing), ("anthropic/claude-opus-5-5", "subscription"))

    def test_words_that_only_closed_providers_hold_are_refused_with_every_match(self):
        answer = self.ask(ByName("big pickle"))
        self.assertEqual(answer, ProviderNotAllowed(
            models=(ModelId("opencode", "big-pickle"),),
            allowed=("glm", "claude", "grok", "gpt", "muse", "kimi", "qwen", "deepseek"),
            closures=(self.policy.closed["opencode"],), awaiting_login=AWAITING_TODAY))
        both = self.ask(ByName("claude-opus-4-8"), policy=self.only_deepseek())
        self.assertEqual(sorted({model.provider for model in both.models}), ["opencode"])

    def test_words_nothing_holds_and_empty_words_match_nothing(self):
        for words in ("no existe tal", "", "   "):
            with self.subTest(words):
                answer = self.ask(ByName(words))
                self.assertIsInstance(answer, NameMatchesNothing)
                self.assertEqual((len(answer.allowed_models), answer.awaiting_login), (62, AWAITING_TODAY))


class Explicar(Policies):
    def setUp(self):
        super().setUp()
        self.policy = ProviderPolicy.load(POLICY)

    def test_a_closed_provider_is_explained_with_davids_citation(self):
        refusal = authorize(ExactModel(ModelId("opencode-go", "deepseek-v4-pro")), self.policy, catalog())
        self.assertEqual(explicar(refusal), modelos.Explicacion(
            "proveedor-no-permitido",
            "opencode-go está cerrado para encargos. David, 2026-10-12: «open code go es solamente para main». "
            "Permitidos con sesión: glm, grok, gpt, muse, kimi, qwen, deepseek. "
            "Permitidos sin sesión todavía: claude.", "no-registrar"))

    def test_a_registered_refusal_keeps_its_phrase_and_asks_to_cancel(self):
        refusal = authorize(ExactModel(DEFAULT), self.only_deepseek(), catalog())
        before, after = explicar(refusal), explicar(refusal, registrado=True)
        self.assertEqual((before.causa, before.accion), ("proveedor-no-permitido", "no-registrar"))
        self.assertEqual((after.causa, after.accion, after.candidatos), ("proveedor-no-permitido", "cancelar", ()))
        self.assertEqual(after.frase, "zai-coding-plan no tiene permiso para encargos. Permitidos con sesión: deepseek.")
        self.assertEqual(before.frase, after.frase)

    def test_claude_is_not_sent_to_a_login_that_opencode_does_not_offer(self):
        answer = explicar(authorize(ByName("claude opus"), self.policy, catalog()))
        self.assertEqual(answer, modelos.Explicacion(
            "proveedor-sin-sesion",
            "claude está permitido, pero su suscripción no entra por opencode, que de anthropic solo acepta "
            "llave de API. Su ruta propia está pendiente (fila B22-S5 de followups.md).", "no-registrar"))
        self.assertNotIn("auth login", answer.frase)

    def test_a_grant_without_login_or_without_id_says_what_is_missing(self):
        self.assertEqual(explicar(ProviderNotConfigured("grok", "xai", "grok 4.7")).frase,
                         "grok está permitido, pero opencode en la Mac no lista ningún modelo de xai. "
                         "Falta correr opencode auth login.")
        self.assertEqual(explicar(ProviderNotConfigured("kimi", None, "kimi k3")), modelos.Explicacion(
            "proveedor-sin-sesion",
            "kimi está permitido, pero falta iniciar sesión con opencode auth login y ligar su id con "
            "encargo.py permitir kimi --proveedor <id>.", "no-registrar"))

    def test_a_model_outside_the_filter_exists_but_its_grant_does_not_cover_it(self):
        refusal = authorize(ExactModel(ModelId("alibaba-token-plan", "deepseek-v4-pro")), self.policy, catalog())
        self.assertEqual(explicar(refusal), modelos.Explicacion(
            "modelo-fuera-del-permiso",
            "opencode lista alibaba-token-plan/deepseek-v4-pro, pero queda fuera del permiso de qwen. "
            "De alibaba-token-plan solo entran qwen*, salvo qwen-image*.", "no-registrar"))
        several = explicar(authorize(ByName("wan image"), self.policy, catalog()), registrado=True)
        self.assertEqual((several.accion, several.frase), (
            "cancelar", "opencode lista alibaba-token-plan/wan2.7-image, alibaba-token-plan/wan2.7-image-pro, pero "
            "quedan fuera del permiso de qwen. De alibaba-token-plan solo entran qwen*, salvo qwen-image*."))

    def test_an_ambiguous_name_asks_david_with_the_ids_and_how_each_provider_bills(self):
        self.policy = self.without_filters()
        answer = explicar(authorize(ByName("deepseek v4 pro"), self.policy, catalog()))
        self.assertEqual(answer, modelos.Explicacion(
            "nombre-ambiguo",
            "«deepseek v4 pro» coincide con 3 modelos permitidos. De alibaba-token-plan, por suscripción: "
            "alibaba-token-plan/deepseek-v4-pro, alibaba-token-plan/deepseek-v4-pro-0813. De deepseek, por token: "
            "deepseek/deepseek-v4-pro. Falta saber cuál.", "preguntar-a-david",
            ("alibaba-token-plan/deepseek-v4-pro", "alibaba-token-plan/deepseek-v4-pro-0813",
             "deepseek/deepseek-v4-pro")))
        self.assertEqual(explicar(authorize(ByName("deepseek v4 pro"), self.policy, catalog()), registrado=True).accion,
                         "cancelar")

    def test_every_refusal_and_host_state_has_its_cause_from_the_closed_vocabulary(self):
        cases = {
            modelos.MalformedModel("Zai/glm"): "modelo-mal-formado",
            PolicyUnreadable("sin cita en el permiso deepseek"): "politica-ilegible",
            modelos.SinModeloPorOmision(): "sin-modelo-por-omision",
            ProviderNotAllowed((DEFAULT,), (), (), ()): "proveedor-no-permitido",
            ProviderNotConfigured("grok", "xai", "grok"): "proveedor-sin-sesion",
            ModelNotListed(ModelId("zai-coding-plan", "glm-5.3-flahs"), (DEFAULT,)): "modelo-no-existe",
            ModelOutsideGrant((ModelId("alibaba-token-plan", "glm-5.3"),),
                              (self.policy.grant_for("alibaba-token-plan"),)): "modelo-fuera-del-permiso",
            NameMatchesNothing("nada", (DEFAULT,), ("claude",)): "nombre-sin-coincidencia",
            NameIsAmbiguous("glm", (DEFAULT,), (("zai-coding-plan", "subscription"),)): "nombre-ambiguo",
            modelos.MalformedHeader("llave desconocida: effort"): "cabecera-mal-formada",
            modelos.WorkspaceRefused("/tmp/x", "outside-root"): "carpeta-no-permitida",
            modelos.RouteNotCertified("1.18.36", ("1.18.35",)): "ruta-no-certificada",
            modelos.GenerationNotCertified(2, (1,)): "generacion-no-certificada",
            modelos.ContextoIncompleto("skills/how/SKILL.md no coincide con el manifiesto"): "contexto-incompleto",
            modelos.PerfilRechazado("perfil-ausente", "el brief no trae perfil"): "perfil-ausente",
            modelos.HostDown(None): "sin-host",
            modelos.HostMismatch("policy", "aaaa", "bbbb"): "host-desfasado",
            modelos.SlotBlocked(("123 Mon Oct 12 sleep 300",)): "slot-bloqueado",
        }
        self.assertEqual({type(case) for case in cases},
                         set(typing.get_args(modelos.Refusal)) | {modelos.HostDown, modelos.HostMismatch,
                                                                 modelos.SlotBlocked})
        self.assertEqual({type(case).__name__: explicar(case).causa for case in cases},
                         {type(case).__name__: causa for case, causa in cases.items()})
        with self.assertRaises(TypeError):
            explicar(DefaultModel())

    def test_a_profile_refusal_keeps_the_cause_the_admission_answered(self):
        caso = modelos.PerfilRechazado("perfil-sin-competencia",
                                       "el perfil meli no tiene competencia vigente en la ruta mac-local/opencode")
        self.assertEqual(explicar(caso), modelos.Explicacion(caso.causa, caso.frase, "no-registrar"))
        self.assertEqual(explicar(caso, registrado=True),
                         modelos.Explicacion(caso.causa, caso.frase, "cancelar"))

    def test_words_that_match_nothing_name_the_providers_david_can_ask_for_not_every_model(self):
        answer = explicar(authorize(ByName("no existe tal"), self.policy, catalog()))
        self.assertEqual(answer, modelos.Explicacion(
            "nombre-sin-coincidencia",
            "Ningún modelo permitido coincide con «no existe tal». Hay modelos permitidos de alibaba-token-plan (6), "
            "deepseek (2), kimi-code-plan-cn (4), meta (6), openai (24), xai (13), zai-coding-plan (7). "
            "Permitidos sin sesión todavía: claude.", "no-registrar"))

    def test_the_phrases_carry_the_values_david_needs(self):
        self.assertEqual(explicar(modelos.RouteNotCertified("1.18.36", ("1.18.35",))).frase,
                         "Ruta certificada para 1.18.35, la Mac tiene opencode 1.18.36.")
        self.assertEqual(explicar(modelos.RouteNotCertified("1.18.35", ())).frase,
                         "La ruta de encargos por opencode todavía no está certificada. La Mac tiene opencode 1.18.35.")
        # Orden r2: la generación avisa y el encargo corre; explicar nombra con las mismas
        # palabras que el aviso, por si algo todavía se lo pasa.
        self.assertEqual(explicar(modelos.GenerationNotCertified(2, (1,))).frase,
                         "generación del paquete no certificada: 2 (certificadas: 1); el encargo corre.")
        self.assertEqual(explicar(modelos.GenerationNotCertified(2, ())).frase,
                         "generación del paquete no certificada: 2 (certificadas: ninguna); el encargo corre.")
        self.assertEqual(explicar(modelos.ContextoIncompleto("skills/how/SKILL.md no coincide con el "
                                                             "manifiesto")).frase,
                         "El paquete de poteto no coincide con su manifiesto: skills/how/SKILL.md no coincide con "
                         "el manifiesto. No se lanza nada.")
        self.assertEqual(explicar(modelos.HostDown(600.0)).frase, "El host de encargos no corre desde hace 10 min.")
        self.assertEqual(explicar(modelos.HostDown(None)).frase, "El host de encargos nunca corrió en esta Mac.")
        self.assertEqual(explicar(modelos.HostMismatch("policy", "aaaa", "bbbb")).frase,
                         "El host de encargos corre con otra política: el host tiene aaaa y aquí hay bbbb.")
        self.assertEqual(explicar(PolicyUnreadable("la cita no trae quote (en el permiso deepseek)")).frase,
                         "La política de proveedores no se puede leer (la cita no trae quote (en el permiso "
                         "deepseek)). No corre ningún encargo hasta arreglarla.")
        similar = explicar(ModelNotListed(ModelId("zai-coding-plan", "glm-5.3-flahs"), (DEFAULT,)))
        self.assertEqual((similar.accion, similar.candidatos), ("preguntar-a-david", ("zai-coding-plan/glm-5.3-flash",)))
        self.assertEqual({why: explicar(modelos.WorkspaceRefused("/tmp/x", why)).frase for why in (
            "not-absolute", "outside-root", "not-a-git-toplevel", "missing", "no-commit", "invalid")}, {
            "not-absolute": "/tmp/x no es una ruta absoluta.",
            "outside-root": "/tmp/x está fuera de la carpeta de repos permitida.",
            "not-a-git-toplevel": "/tmp/x no es la raíz de un repo git.",
            "missing": "/tmp/x no existe.",
            "no-commit": "/tmp/x es un repo git sin ningún commit.",
            "invalid": "/tmp/x no es una carpeta de encargo válida."})

    def test_an_incident_episode_asks_to_cancel_and_names_what_opencode_left(self):
        events = types.SimpleNamespace(
            denied=(types.SimpleNamespace(permission="external_directory", pattern="/tmp/*"),),
            error=None, session_directory="/Users/dn/dev/demo")
        self.assertEqual(explicar("session-closed", eventos=events), modelos.Explicacion(
            "session-closed",
            "La sesión terminó sin entregar resultado. opencode negó external_directory sobre /tmp/*.", "cancelar"))
        failed = types.SimpleNamespace(denied=(), error="Model not found: zai/glm-9", session_directory=None)
        self.assertEqual(explicar("launch-failed", eventos=failed).frase,
                         "opencode salió sin acusar recibo. opencode dijo: Model not found: zai/glm-9.")
        self.assertEqual(explicar("deadline", eventos=failed).frase,
                         "El modelo acusó recibo y no entregó dentro del plazo.")
        self.assertEqual(explicar("launch-refused").accion, "cancelar")
        with self.assertRaises(ValueError):
            explicar("no-es-un-episodio")


class Headers(unittest.TestCase):
    def test_a_brief_without_the_schema_line_has_no_header(self):
        for brief in (b"Revisa el commit aaaa\n", b"", b"model: zai/glm-5.3\n---\n", b"agent-work.launch.v2\n---\n"):
            with self.subTest(brief):
                self.assertEqual(sesion.LaunchHeader.parse(brief), sesion.LaunchHeader(None))

    def test_the_header_names_the_model(self):
        brief = b"agent-work.launch.v1\nmodel: zai-coding-plan/glm-5.3\n---\nRevisa el commit aaaa\n"
        self.assertEqual(sesion.LaunchHeader.parse(brief), sesion.LaunchHeader(ModelId("zai-coding-plan", "glm-5.3")))
        self.assertEqual(sesion.LaunchHeader.parse(b"agent-work.launch.v1\n---\nprosa\n"), sesion.LaunchHeader(None))

    def test_the_header_names_the_profile(self):
        brief = b"agent-work.launch.v1\nprofile: ingenieria\n---\nprosa\n"
        self.assertEqual(sesion.LaunchHeader.parse(brief), sesion.LaunchHeader(None, "ingenieria"))
        both = b"agent-work.launch.v1\nmodel: zai/glm-5.3\nprofile: revision\n---\nprosa\n"
        self.assertEqual(sesion.LaunchHeader.parse(both),
                         sesion.LaunchHeader(ModelId("zai", "glm-5.3"), "revision"))

    def test_a_header_the_host_does_not_understand_is_refused_not_ignored(self):
        for brief, why in (
            (b"agent-work.launch.v1\nmodel: zai-coding-plan/glm-5.3\neffort: high\n---\n", "effort"),
            (b"agent-work.launch.v1\nmodel: zai-coding-plan/glm-5.3\nprosa sin cierre\n", "prosa sin cierre"),
            (b"agent-work.launch.v1\nmodel: zai-coding-plan/glm-5.3\n", "---"),
            (b"agent-work.launch.v1\nmodel: Zai/glm\n---\n", "Zai/glm"),
            (b"agent-work.launch.v1\nmodel: zai/glm-5.3\nmodel: opencode-go/kimi-k3\n---\n", "model"),
            (b"agent-work.launch.v1\nmodel: zai/glm-5.3\nprofile: ingenieria\nprofile: meli\n---\n", "profile"),
            (b"agent-work.launch.v1\nprofile: Ingenieria\n---\n", "Ingenieria"),
            (b"agent-work.launch.v1\nmodel: \xff\xfe\n---\n", "UTF-8"),
            (b"agent-work.launch.v1\r\nmodel: zai/glm-5.3\r\n---\r\n", "primera línea"),
            (b" agent-work.launch.v1\nmodel: zai/glm-5.3\n---\n", "primera línea"),
            (b"agent-work.launch.v1\nmodel: zai/glm-5.3\r\n---\n", "model"),
            (b"agent-work.launch.v1\n" + b"\n" * 40 + b"---\n", "''"),
        ):
            with self.subTest(brief):
                answer = sesion.LaunchHeader.parse(brief)
                self.assertIsInstance(answer, modelos.MalformedHeader)
                self.assertIn(why, answer.why)


class Routes(unittest.TestCase):
    def route(self, status, versions=("1.18.35",)):
        return sesion.Route("mac-local", "opencode", "run-per-task", status, frozenset(versions))

    def test_a_certified_route_opens_only_for_a_measured_cli_version(self):
        self.assertIsNone(self.route("certified").open_for("1.18.35", canary=False))
        # G-sin-candados (David, 2026-10-19): una versión fuera de certifiedCliVersions ya no
        # cierra la ruta; contesta el aviso y el encargo corre.
        self.assertEqual(self.route("certified", ("1.18.35", "1.18.20")).open_for("1.18.36", canary=False),
                         modelos.VersionSinCertificar("1.18.36", ("1.18.20", "1.18.35")))
        self.assertEqual(self.route("sandbox-tested-uncertified").open_for("1.18.35", canary=False),
                         modelos.RouteNotCertified("1.18.35", ()))

    def test_a_canary_also_opens_a_sandbox_tested_route_and_a_new_version_but_never_a_disabled_one(self):
        self.assertIsNone(self.route("sandbox-tested-uncertified").open_for("1.18.35", canary=True))
        self.assertIsNone(self.route("certified").open_for("1.18.36", canary=True))
        self.assertEqual(self.route("disabled-operator-billing").open_for("1.18.35", canary=True),
                         modelos.RouteNotCertified("1.18.35", ()))

    def test_the_repos_coverage_certifies_the_run_per_task_route_for_opencode_1_18_35_and_no_other_version(self):
        coverage = json.loads(COVERAGE.read_text())
        self.assertEqual(coverage["hostAdapterRoute"]["mac-local"]["opencode"]["form"], "run-per-task")
        route = sesion.Route.load(coverage, "mac-local")
        self.assertEqual(route, sesion.Route("mac-local", "opencode", "run-per-task", "certified",
                                             frozenset({"1.18.35", "2.0.29"}), frozenset({"1", "2"})))
        # 2.0.29: decisión de David del 2026-10-18 con el hueco conocido del shell
        # (docs/evidence/agent-work/opencode-2.0.29-recertificacion.md).
        self.assertIsNone(route.open_for("2.0.29", canary=False))
        self.assertIsNone(route.open_for("1.18.35", canary=False))
        self.assertIsNone(route.open_for("1.18.35", 1, canary=False),
                          "M-16 certifies generation 1 of the package (SUA-03-mediciones.md)")
        self.assertIsNone(route.open_for("1.18.35", 2, canary=False),
                          "M-16 (generación 2) certifies generation 2 of the package")
        # G-sin-candados: la versión nueva avisa y corre; la frase lleva las palabras del encargo.
        self.assertEqual(route.open_for("1.18.36", canary=False),
                         modelos.VersionSinCertificar("1.18.36", ("1.18.35", "2.0.29")))
        self.assertEqual(modelos.frase_version_sin_certificar(route.open_for("1.18.36", canary=False)),
                         "versión no certificada: 1.18.36 (certificadas: 1.18.35, 2.0.29); el encargo corre.")
        self.assertIsNone(route.open_for("1.18.36", canary=True))

    def test_the_adopted_session_certificate_does_not_open_the_run_per_task_route_even_for_a_canary(self):
        """The coverage of before B22 phase 2: B8 had certified mac-local/opencode over an adopted session, and
        no entry declared the run-per-task route."""
        coverage = json.loads(COVERAGE.read_text())
        coverage["hostAdapterCoverage"]["mac-local"]["opencode"] = "certified"
        del coverage["hostAdapterRoute"]
        route = sesion.Route.load(coverage, "mac-local")
        self.assertEqual(route, sesion.Route("mac-local", "opencode", "run-per-task", "absent", frozenset()))
        for canary in (False, True):
            self.assertEqual(route.open_for("1.18.35", canary=canary), modelos.RouteNotCertified("1.18.35", ()))

    def test_a_coverage_of_the_wrong_shape_is_an_absent_route_not_a_crash(self):
        entry = {"form": "run-per-task", "certifiedCliVersions": {"1.18.35": "B22-fase0.md"}}
        for coverage in ([], "certified", None, 7, {"hostAdapterCoverage": [], "hostAdapterRoute": []},
                         {"hostAdapterCoverage": {"mac-local": "certified"}, "hostAdapterRoute": {"mac-local": "x"}},
                         {"hostAdapterCoverage": {"mac-local": {"opencode": "certified"}},
                          "hostAdapterRoute": {"mac-local": ["opencode"]}},
                         {"hostAdapterCoverage": {"mac-local": {"opencode": ["certified"]}},
                          "hostAdapterRoute": {"mac-local": {"opencode": entry}}},
                         {"hostAdapterCoverage": "certified", "hostAdapterRoute": {"mac-local": {"opencode": entry}}}):
            with self.subTest(coverage):
                route = sesion.Route.load(coverage, "mac-local")
                self.assertEqual(route.status, "absent")
                self.assertEqual(route.open_for("1.18.35", canary=True).cli_version, "1.18.35")

    def test_the_route_reads_its_measured_versions_from_coverage(self):
        coverage = {"hostAdapterCoverage": {"mac-local": {"opencode": "certified"}},
                    "hostAdapterRoute": {"mac-local": {"opencode": {
                        "form": "run-per-task", "certifiedCliVersions": {"1.18.35": "B22-fase0.md"}}}}}
        self.assertEqual(sesion.Route.load(coverage, "mac-local"),
                         sesion.Route("mac-local", "opencode", "run-per-task", "certified", frozenset({"1.18.35"})))
        self.assertIsNone(sesion.Route.load(coverage, "mac-local").open_for("1.18.35", canary=False))
        for broken, status in (({"form": "adopted-session", "certifiedCliVersions": {"1.18.35": "x"}}, "absent"),
                               ({"form": "run-per-task"}, "certified"),
                               ({"form": "run-per-task", "certifiedCliVersions": ["1.18.35"]}, "certified"),
                               ({"form": "run-per-task", "certifiedCliVersions": {"1.18.36": "x", 7: "y"}}, "certified"),
                               ("certified", "absent")):
            with self.subTest(broken):
                coverage["hostAdapterRoute"]["mac-local"]["opencode"] = broken
                route = sesion.Route.load(coverage, "mac-local")
                self.assertEqual(route.status, status)
                self.assertNotIn("1.18.35", route.certified_cli_versions)
                # G-sin-candados: una ruta certified sin versiones legibles ya no niega; avisa.
                tipo = modelos.RouteNotCertified if route.status == "absent" else modelos.VersionSinCertificar
                self.assertIsInstance(route.open_for("1.18.35", canary=False), tipo)
        self.assertEqual(sesion.Route.load(coverage, "windows-remote").status, "absent")

    def test_the_route_opens_by_package_generation_and_the_canary_skips_the_gate(self):
        def route(generations):
            return sesion.Route("mac-local", "opencode", "run-per-task", "certified", frozenset({"1.18.35"}),
                                frozenset(generations))
        self.assertIsNone(route({"1": "M-13"}).open_for("1.18.35", 1, canary=False))
        self.assertEqual(route({"1": "M-13"}).open_for("1.18.35", 2, canary=False),
                         modelos.GenerationNotCertified(2, (1,)))
        self.assertEqual(route({}).open_for("1.18.35", 1, canary=False), modelos.GenerationNotCertified(1, ()))
        self.assertIsNone(route({"1": "M-13"}).open_for("1.18.35", 2, canary=True),
                          "the canary recertifies a generation")
        self.assertEqual(route({"2": "x", "10": "y"}).open_for("1.18.35", 1, canary=False),
                         modelos.GenerationNotCertified(1, (2, 10)))
        self.assertIsNone(route({"1": "M-13"}).open_for("1.18.35", canary=False),
                          "a brief without a package only asks the version of the CLI")

    def test_the_repos_coverage_certifies_generations_1_and_2_of_the_package(self):
        # M-16 certificó la generación 1 (corrida 5 + corrida 8) y la 2 (banco
        # sobre la generación 2, dos corridas): la 3 sigue sin certificar.
        route = sesion.Route.load(json.loads(COVERAGE.read_text(encoding="utf-8")), "mac-local")
        self.assertEqual(route.certified_context_generations, frozenset({"1", "2"}))
        self.assertIsNone(route.open_for("1.18.35", 1, canary=False))
        self.assertIsNone(route.open_for("1.18.35", 2, canary=False))
        self.assertEqual(route.open_for("1.18.35", 3, canary=False), modelos.GenerationNotCertified(3, (1, 2)))
        self.assertIsNone(route.open_for("1.18.35", 3, canary=True))

    def test_la_generacion_y_la_version_sin_certificar_corren_con_los_dos_avisos_juntos(self):
        # G-sin-candados r2 (David, 2026-10-19, cr:4311182166): la certificación de la generación
        # del paquete también pasa a solo aviso; con versión y generación sin certificar, open_for
        # junta los dos avisos en un solo resultado y el encargo corre.
        def con_generaciones(generations, versions=("1.18.35",)):
            return sesion.Route("mac-local", "opencode", "run-per-task", "certified", frozenset(versions),
                                frozenset(generations))
        caso = con_generaciones({"1": "M-13"}).open_for("1.18.36", 2, canary=False)
        self.assertEqual(caso, modelos.VersionSinCertificar(
            "1.18.36", ("1.18.35",), "opencode", modelos.GenerationNotCertified(2, (1,))))
        self.assertEqual(
            modelos.frase_version_sin_certificar(caso),
            "versión no certificada: 1.18.36 (certificadas: 1.18.35); el encargo corre. "
            "generación del paquete no certificada: 2 (certificadas: 1); el encargo corre.")
        # La generación sola también es solo aviso, con sus palabras propias.
        self.assertEqual(con_generaciones({"1": "M-13"}).open_for("1.18.35", 2, canary=False),
                         modelos.GenerationNotCertified(2, (1,)))
        self.assertEqual(modelos.frase_avisos_de_ruta(modelos.GenerationNotCertified(2, (1,))),
                         "generación del paquete no certificada: 2 (certificadas: 1); el encargo corre.")
        # Un canario no ve ninguno de los dos avisos; una ruta sin certificar sí frena igual que
        # siempre, y la puerta de avisos no la confunde con un aviso.
        self.assertIsNone(con_generaciones({"1": "M-13"}).open_for("1.18.36", 2, canary=True))
        cerrada = sesion.Route("mac-local", "opencode", "run-per-task", "absent", frozenset())
        self.assertIsInstance(cerrada.open_for("1.18.36", 2, canary=False), modelos.RouteNotCertified)
        self.assertIsNone(modelos.frase_avisos_de_ruta(cerrada.open_for("1.18.36", 2, canary=False)))

    def coverage_certified(self, status="certified"):
        return {"hostAdapterCoverage": {"mac-local": {"opencode": status, "claude": status}},
                "hostAdapterRoute": {"mac-local": {
                    "opencode": {"form": "run-per-task", "certifiedCliVersions": {"1.18.35": "B22-fase0.md"}},
                    "claude": {"form": "run-per-task", "certifiedCliVersions": {"2.1.301": "SUA-04"}}}}}

    def medidas_verde(self, version="1.19.3", estado="verde", ruta="mac-local/opencode"):
        return {"schema": "agent-work.cli-versions.v1",
                "routes": {ruta: {version: {"estado": estado, "medidoEn": "2026-10-17T23:40:00Z"}}}}

    def test_una_version_verde_abre_la_ruta_certified_sin_estar_en_coverage(self):
        route = sesion.Route.load(self.coverage_certified(), "mac-local", medidas=self.medidas_verde())
        self.assertIsNone(route.open_for("1.19.3", canary=False))
        # G-sin-candados: las demás versiones ya no cierran, avisan.
        self.assertEqual(route.open_for("1.19.4", canary=False),
                         modelos.VersionSinCertificar("1.19.4", ("1.18.35", "1.19.3")))
        self.assertIsNone(route.open_for("1.18.35", canary=False))
        for estado in ("rojo", "probando", "infraestructura"):
            with self.subTest(estado=estado):
                route = sesion.Route.load(self.coverage_certified(), "mac-local",
                                          medidas=self.medidas_verde(estado=estado))
                # Solo el verde suma la versión a las certificadas; las demás corren con su aviso
                # (y el rojo terminal se lo niega _freno/preparar, no la ruta).
                self.assertEqual(route.open_for("1.19.3", canary=False),
                                 modelos.VersionSinCertificar("1.19.3", ("1.18.35",)))
        ajena = sesion.Route.load(self.coverage_certified(), "mac-local", "claude",
                                  self.medidas_verde())
        self.assertEqual(ajena.open_for("1.19.3", canary=False),
                         modelos.VersionSinCertificar("1.19.3", ("2.1.301",), "claude"))

    def test_una_ruta_sandbox_no_suma_un_verde_escrito_a_mano(self):
        # Prueba 6: sandbox-tested-uncertified no se recertifica sola.
        medidas = self.medidas_verde()
        route = sesion.Route.load(self.coverage_certified("sandbox-tested-uncertified"), "mac-local",
                                  medidas=medidas)
        self.assertEqual(route.status, "sandbox-tested-uncertified")
        self.assertNotIn("1.19.3", route.certified_cli_versions)
        self.assertEqual(route.open_for("1.19.3", canary=False), modelos.RouteNotCertified("1.19.3", ()))
        self.assertEqual(route.open_for("1.18.35", canary=False), modelos.RouteNotCertified("1.18.35", ()))

    def test_un_registro_ilegible_deja_la_ruta_como_la_deja_coverage(self):
        # Prueba 7: JSON roto, forma mala o archivo ausente no abren ni cierran nada.
        coverage = self.coverage_certified()
        sola = sesion.Route.load(coverage, "mac-local")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            checkout = root / "checkout"
            (checkout / "docs/evidence/agent-work").mkdir(parents=True)
            (checkout / "docs/evidence/agent-work/coverage.json").write_text(json.dumps(coverage), encoding="utf-8")
            state = root / "state"
            state.mkdir()
            self.assertEqual(sesion.cargar_ruta(checkout, state, "mac-local"), sola)
            (state / "versiones-medidas.json").write_text("{no es json", encoding="utf-8")
            self.assertEqual(sesion.cargar_ruta(checkout, state, "mac-local"), sola)
            (state / "versiones-medidas.json").write_text(json.dumps(["verde"]), encoding="utf-8")
            self.assertEqual(sesion.cargar_ruta(checkout, state, "mac-local"), sola)
            (state / "versiones-medidas.json").write_text(json.dumps(self.medidas_verde()), encoding="utf-8")
            abierta = sesion.cargar_ruta(checkout, state, "mac-local")
            self.assertIsNone(abierta.open_for("1.19.3", canary=False))
            self.assertEqual(abierta.open_for("1.19.4", canary=False),
                             modelos.VersionSinCertificar("1.19.4", ("1.18.35", "1.19.3")))


class Plans(Policies):
    OPERATION = "ab" * 32

    def setUp(self):
        super().setUp()
        self.root = self.root.resolve()
        self.allowed = self.root / "dev"
        self.repo = self.allowed / "demo"
        (self.repo / ".git").mkdir(parents=True)
        self.run = contracts.RunDir.for_operation(self.root / "spool", self.OPERATION)
        self.route = sesion.Route("mac-local", "opencode", "run-per-task", "certified", frozenset({"1.18.35"}),
                                  frozenset({"1"}))

    def package(self, generation=1):
        """What the host reads from its checkout for a brief that asks for a profile."""
        manifest = contexto.leer_json(contexto.MANIFIESTO)
        manifest["generation"] = generation
        return sesion.Package(manifest, contexto.leer_json(contexto.PERFILES), self.root / "pstack")

    def plan(self, brief=b"Revisa el commit aaaa\n", *, policy=None, revision=None, route=None, cli="1.18.35",
             canary=False, assignment=..., package=None, now=None):
        if assignment is ...:
            assignment = {"target": {"kind": "cli", "hostId": "mac-local", "adapterId": "opencode"},
                          "inputRevision": revision or {"kind": "code", "repository": str(self.repo), "sha": "a" * 40}}
        return sesion.plan_launch(assignment, brief, policy=policy or ProviderPolicy.load(POLICY), catalog=catalog(),
                                  route=route or self.route, cli_version=cli, allowed_root=self.allowed, run=self.run,
                                  record=self.root / "spool/sessions" / self.OPERATION, operation=self.OPERATION,
                                  canary=canary, package=package, now=now)

    def profiled(self, profile="ingenieria", contract="ready.v1", revision=None, **kwargs):
        brief = f"agent-work.launch.v1\nprofile: {profile}\n---\nprosa\n".encode()
        kwargs.setdefault("canary", True)
        kwargs.setdefault("now", self.now())
        kwargs.setdefault("assignment", {"target": {"kind": "cli", "hostId": "mac-local", "adapterId": "opencode"},
                                         "inputRevision": revision or {"kind": "code", "repository": str(self.repo),
                                                                       "sha": "a" * 40},
                                         "resultContract": contract})
        kwargs.setdefault("package", self.package())
        return self.plan(brief, **kwargs)

    def test_the_run_folder_is_private_and_holds_the_four_protocol_files(self):
        self.assertEqual(self.run.path, self.root / "spool/runs" / self.OPERATION)
        self.assertEqual(self.run.path.stat().st_mode & 0o777, 0o700)
        self.assertEqual([path.name for path in (self.run.assignment, self.run.brief, self.run.accept, self.run.result)],
                         ["assignment.json", "brief", "accept.json", "result.json"])
        self.assertEqual(contracts.RunDir.for_operation(self.root / "spool", self.OPERATION), self.run)
        for operation in ("../fuera", "AB" * 32, "ab" * 31):
            with self.subTest(operation), self.assertRaises(ValueError):
                contracts.RunDir.for_operation(self.root / "spool", operation)

    def test_an_old_brief_without_header_plans_the_default_model_in_the_repo(self):
        spec = self.plan()
        self.assertEqual((spec.model.model, spec.model.billing), (DEFAULT, "subscription"))
        self.assertEqual((spec.workspace.root, spec.run, spec.session),
                         (self.repo, self.run, "enc-abababababab"))
        self.assertEqual(spec.record, self.root / "spool/sessions" / self.OPERATION)

    def test_the_header_model_is_the_one_planned(self):
        spec = self.plan(b"agent-work.launch.v1\nmodel: zai-coding-plan/glm-4.7\n---\nprosa\n")
        self.assertEqual(str(spec.model.model), "zai-coding-plan/glm-4.7")

    def test_an_old_brief_is_refused_when_the_default_provider_lost_its_grant(self):
        refusal = self.plan(policy=self.only_deepseek())
        self.assertIsInstance(refusal, modelos.SinModeloPorOmision)
        self.assertNotIsInstance(refusal, sesion.LaunchSpec)
        answer = explicar(refusal, registrado=True)
        self.assertEqual((answer.causa, answer.accion), ("sin-modelo-por-omision", "cancelar"))

    def test_a_header_cannot_reach_a_closed_provider_or_a_model_nobody_lists(self):
        closed = self.plan(b"agent-work.launch.v1\nmodel: opencode-go/deepseek-v4-pro\n---\n")
        self.assertEqual([closure.provider for closure in closed.closures], ["opencode-go"])
        self.assertEqual(self.plan(b"agent-work.launch.v1\nmodel: zai-coding-plan/no-existe\n---\n"),
                         ModelNotListed(ModelId("zai-coding-plan", "no-existe"), ()))
        self.assertIsInstance(self.plan(b"agent-work.launch.v1\nmodel: zai/glm-5.3\neffort: high\n---\n"),
                              modelos.MalformedHeader)
        outside = self.plan(b"agent-work.launch.v1\nmodel: alibaba-token-plan/deepseek-v4-pro\n---\n")
        self.assertEqual(outside.models, (ModelId("alibaba-token-plan", "deepseek-v4-pro"),))
        self.assertIsInstance(outside, ModelOutsideGrant)

    def test_a_closed_route_refuses_but_an_uncertified_version_plans_with_its_aviso(self):
        uncertified = sesion.Route("mac-local", "opencode", "run-per-task", "sandbox-tested-uncertified",
                                   frozenset({"1.18.35"}))
        broken = b"agent-work.launch.v1\nmodel: Zai/glm\n---\n"
        self.assertEqual(self.plan(broken, route=uncertified), modelos.RouteNotCertified("1.18.35", ()))
        # G-sin-candados (David, 2026-10-19): la versión sin certificar ya no niega el plan; sale
        # con su aviso y el resto del plan igual.
        spec = self.plan(cli="1.18.36")
        self.assertIsInstance(spec, sesion.LaunchSpec)
        self.assertEqual(spec.aviso, "versión no certificada: 1.18.36 (certificadas: 1.18.35); "
                                     "el encargo corre.")
        self.assertIsInstance(self.plan(broken, route=uncertified, canary=True), modelos.MalformedHeader)
        self.assertEqual(self.plan(route=uncertified, canary=True).workspace.root, self.repo)

    def test_the_task_folder_must_be_a_git_root_under_the_operators_root(self):
        (self.repo / "sub").mkdir()
        outside = self.root / "fuera"
        (outside / ".git").mkdir(parents=True)
        (self.allowed / "enlace").symlink_to(outside)
        (self.allowed / "sin-git").mkdir()
        for repository, why in ((str(self.repo / "sub"), "not-a-git-toplevel"), (str(outside), "outside-root"),
                                (str(self.allowed / "enlace"), "outside-root"), ("dev/demo", "not-absolute"),
                                (str(self.allowed / "no-esta"), "missing"), (str(self.allowed / "sin-git"),
                                                                             "not-a-git-toplevel"),
                                (str(self.allowed), "outside-root"), (None, "invalid"), (7, "invalid"),
                                (str(self.repo) + "\0/x", "invalid"), ("", "not-absolute")):
            with self.subTest(repository):
                answer = self.plan(revision={"kind": "code", "repository": repository, "sha": "a" * 40})
                self.assertEqual(answer, modelos.WorkspaceRefused(str(repository), why))

    def test_an_assignment_without_a_usable_input_revision_is_refused_not_a_crash(self):
        target = {"kind": "cli", "hostId": "mac-local", "adapterId": "opencode"}
        for assignment, path in (({"target": target}, "None"), ({"target": target, "inputRevision": None}, "None"),
                                 ({"target": target, "inputRevision": [str(self.repo)]}, f"['{self.repo}']"),
                                 ({"target": target, "inputRevision": str(self.repo)}, str(self.repo)),
                                 ({"target": target, "inputRevision": {"repository": str(self.repo)}},
                                  f"{{'repository': '{self.repo}'}}"),
                                 ({"target": target, "inputRevision": {"kind": "url", "repository": str(self.repo)}},
                                  f"{{'kind': 'url', 'repository': '{self.repo}'}}"),
                                 ([], "None"), (None, "None")):
            with self.subTest(assignment):
                self.assertEqual(self.plan(assignment=assignment), modelos.WorkspaceRefused(path, "invalid"))

    def test_a_symlink_loop_is_refused_on_every_python(self):
        (self.allowed / "bucle").symlink_to(self.allowed / "bucle")
        answer = self.plan(revision={"kind": "code", "repository": str(self.allowed / "bucle" / "x")})
        self.assertIsInstance(answer, modelos.WorkspaceRefused)
        self.assertIn(answer.why, ("invalid", "missing"))

    def test_a_code_revision_without_a_usable_sha_is_refused_before_launch(self):
        for sha in (None, 123, "zzz", "a" * 39, "a" * 65, True):
            with self.subTest(sha=sha):
                revision = {"kind": "code", "repository": str(self.repo), "sha": sha}
                self.assertEqual(self.plan(revision=revision),
                                 modelos.WorkspaceRefused(str(revision), "invalid"))
        self.assertIsInstance(self.plan(revision={"kind": "code", "repository": str(self.repo), "sha": "b" * 40}),
                              sesion.LaunchSpec)

    def test_a_task_without_repo_works_in_a_new_folder_inside_its_run(self):
        spec = self.plan(revision={"kind": "artifact", "ref": "artifact:aa", "digest": "sha256:aa"})
        self.assertEqual(spec.workspace.root, self.run.path / "work")
        self.assertTrue(spec.workspace.root.is_dir())

    def test_a_brief_without_a_profile_is_refused_before_launch(self):
        answer = self.plan(package=self.package(), now=self.now())
        self.assertEqual(answer, modelos.PerfilRechazado("perfil-ausente",
                                                         "el brief no trae perfil y la corrida lleva paquete"))
        self.assertFalse((self.run.path / "contexto").exists(), "a refused brief copied nothing")
        self.assertIsInstance(self.plan(canary=True, package=self.package(), now=self.now()),
                              modelos.PerfilRechazado, "the canary does not invent a default profile either")

    def test_a_brief_without_a_package_runs_as_it_always_did(self):
        spec = self.plan(b"agent-work.launch.v1\n---\nprosa\n")
        self.assertIsNone(spec.perfil)
        self.assertIsNone(spec.config)
        self.assertEqual(spec.workspace.root, self.repo)

    def test_an_unknown_profile_is_refused_by_its_name(self):
        brief = b"agent-work.launch.v1\nprofile: no-existe\n---\nprosa\n"
        self.assertEqual(self.plan(brief, canary=True, package=self.package(), now=self.now()),
                         modelos.PerfilRechazado("perfil-desconocido", "ningún perfil se llama no-existe"))

    def test_a_profile_runs_only_when_it_admits_the_route_the_contract_and_its_competence(self):
        spec = self.profiled()
        self.assertEqual((spec.perfil["id"], spec.workspace.root), ("ingenieria", self.repo))
        brief = b"agent-work.launch.v1\nprofile: meli\n---\nprosa\n"
        fuera = self.plan(brief, canary=True, package=self.package(), now=self.now(),
                          assignment={"target": {"kind": "cli", "hostId": "mac-local", "adapterId": "opencode"},
                                      "inputRevision": {"kind": "code", "repository": str(self.repo), "sha": "a" * 40},
                                      "resultContract": "ready.v1"})
        self.assertEqual(fuera.causa, "perfil-no-atiende-ruta")
        revision = self.profiled(contract="review.v1")
        self.assertEqual(revision.causa, "perfil-no-admite-contrato")
        # La competence real ya está certificada por M-16 (r5): el perfil sin
        # competencia se arma en una copia con su ruta CLI en pending.
        paquete = self.package()
        perfiles_pendientes = copy.deepcopy(paquete.profiles)
        for perfil in perfiles_pendientes["profiles"]:
            if perfil["id"] == "ingenieria":
                perfil["competence"]["mac-local/opencode"] = {
                    "status": "pending", "model": None, "evidence": None,
                    "at": None, "validUntil": None,
                }
        pendiente = sesion.Package(paquete.manifest, perfiles_pendientes, paquete.source)
        sin = self.profiled(canary=False, package=pendiente)
        self.assertEqual(sin.causa, "perfil-sin-competencia")

    def test_the_planned_config_delivers_the_package_and_the_model_of_the_encargo(self):
        spec = self.profiled()
        env = sesion.opencode_env(spec)
        config = json.loads(env["OPENCODE_CONFIG_CONTENT"])
        self.assertEqual(config["instructions"], [str(self.run.context / "AGENTS.md")])
        self.assertEqual(config["skills"], {"paths": [str(self.run.context / "skills")]})
        self.assertEqual(config["agent"], {name: {"model": str(spec.model.model)} for name in sesion.LOCAL_AGENTS})
        self.assertNotIn("edit", config["permission"], "ingenieria writes source and keeps the edit tool")

    def test_a_reviewer_runs_in_a_clone_that_cannot_edit(self):
        spec = self.profiled("revision", "review.v1")
        self.assertEqual(spec.workspace.root, self.run.path / "repo")
        config = json.loads(sesion.opencode_env(spec)["OPENCODE_CONFIG_CONTENT"])
        self.assertEqual(config["permission"]["edit"], "deny")
        artifact = self.profiled("revision", "review.v1",
                                 revision={"kind": "artifact", "ref": "artifact:aa", "digest": "sha256:aa"})
        self.assertEqual(artifact.workspace.root, self.run.path / "work", "an artifact run has no repo to clone")

    def test_a_reviewer_that_could_edit_is_refused(self):
        original = sesion.run_config

        def sin_deny(run, model, writes):
            config = original(run, model, writes=writes)
            config["permission"].pop("edit", None)
            return config

        with mock.patch.object(sesion, "run_config", sin_deny):
            refusal = self.profiled("revision", "review.v1")
        self.assertEqual(refusal.causa, "revisor-con-escritura")

    def test_a_run_that_denies_a_required_tool_is_refused(self):
        original = sesion.run_config

        def sin_task(run, model, writes):
            config = original(run, model, writes=writes)
            config["permission"]["task"] = "deny"
            return config

        with mock.patch.object(sesion, "run_config", sin_task):
            refusal = self.profiled("revision", "review.v1")
        self.assertEqual(refusal.causa, "herramienta-negada")
        self.assertIn("task", refusal.frase)

    def test_a_plan_with_a_package_demands_the_hosts_clock(self):
        with self.assertRaises(TypeError):
            self.profiled(now=None)
        self.assertIsNone(self.plan().perfil, "a packageless plan runs without a clock, as always")

    def now(self):
        return datetime(2026, 10, 15, tzinfo=timezone.utc)


DOBLE_OPENCODE = r'''#!/usr/bin/env python3
import json, sys
from pathlib import Path
argv = sys.argv[1:]
raiz = Path(__file__).parent
registro = raiz / "argv.log"
registro.open("a").write(json.dumps(argv) + "\n")
if argv[:1] == ["--version"]:
    print((raiz / "version").read_text().strip())
    raise SystemExit(0)
if argv[:1] == ["models"]:
    print((raiz / "listing").read_text().strip())
    raise SystemExit(0)
raise SystemExit(9)
'''


class VersionDeSalida(unittest.TestCase):
    def test_la_salida_firmada_de_la_2_da_su_version_y_la_de_la_1x_sigue_valiendo(self):
        self.assertEqual(modelos.version_de_salida("opencode v2.0.29"), "2.0.29")
        self.assertEqual(modelos.version_de_salida("1.18.35"), "1.18.35")
        self.assertEqual(modelos.version_de_salida("opencode v2.0.29-beta.1"), "2.0.29-beta.1")

    def test_una_salida_sin_version_no_inventa_una(self):
        for salida in ("", "opencode", "v", "opencode v", "no hay numeros aqui"):
            with self.subTest(salida=salida):
                self.assertIsNone(modelos.version_de_salida(salida))

    def test_el_ultimo_token_de_version_gana(self):
        self.assertEqual(modelos.version_de_salida("opencode v2.0.29 canal latest"), "2.0.29")
        self.assertEqual(modelos.version_de_salida("build 7 v3.1.4"), "3.1.4")


class OpencodePorOmision(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.raiz = Path(temp.name).resolve()
        self._env = {clave: os.environ.get(clave) for clave in ("AGENT_WORK_OPENCODE", "HOME")}
        self.addCleanup(self._restaurar)

    def _restaurar(self):
        for clave, valor in self._env.items():
            if valor is None:
                os.environ.pop(clave, None)
            else:
                os.environ[clave] = valor

    def test_agent_work_opencode_manda_sobre_todo(self):
        suyo = self.raiz / "suyo" / "opencode"
        suyo.parent.mkdir(parents=True)
        suyo.write_text("#!/bin/sh\n")
        suyo.chmod(0o755)
        os.environ["AGENT_WORK_OPENCODE"] = str(suyo)
        self.assertEqual(modelos.opencode_por_omision(), suyo)

    def test_el_opencode_local_de_la_2_antes_que_el_path(self):
        local = self.raiz / "casa" / ".opencode" / "bin" / "opencode"
        local.parent.mkdir(parents=True)
        local.write_text("#!/bin/sh\n")
        local.chmod(0o755)
        en_path = self.raiz / "path" / "opencode"
        en_path.parent.mkdir(parents=True)
        en_path.write_text("#!/bin/sh\n")
        en_path.chmod(0o755)
        os.environ.pop("AGENT_WORK_OPENCODE", None)
        os.environ["HOME"] = str(self.raiz / "casa")
        with mock.patch("shutil.which", return_value=str(en_path)):
            self.assertEqual(modelos.opencode_por_omision(), local)

    def test_sin_local_el_path_responde(self):
        en_path = self.raiz / "path" / "opencode"
        en_path.parent.mkdir(parents=True)
        en_path.write_text("#!/bin/sh\n")
        en_path.chmod(0o755)
        os.environ.pop("AGENT_WORK_OPENCODE", None)
        os.environ["HOME"] = str(self.raiz / "casa-sin-opencode")
        with mock.patch("shutil.which", return_value=str(en_path)):
            self.assertEqual(modelos.opencode_por_omision(), en_path)

    def test_un_local_sin_permiso_de_ejecucion_no_manda(self):
        local = self.raiz / "casa" / ".opencode" / "bin" / "opencode"
        local.parent.mkdir(parents=True)
        local.write_text("#!/bin/sh\n")
        en_path = self.raiz / "path" / "opencode"
        en_path.parent.mkdir(parents=True)
        en_path.write_text("#!/bin/sh\n")
        en_path.chmod(0o755)
        os.environ.pop("AGENT_WORK_OPENCODE", None)
        os.environ["HOME"] = str(self.raiz / "casa")
        with mock.patch("shutil.which", return_value=str(en_path)):
            self.assertEqual(modelos.opencode_por_omision(), en_path)

    def test_sin_nada_queda_el_de_homebrew_de_la_1x(self):
        os.environ.pop("AGENT_WORK_OPENCODE", None)
        os.environ["HOME"] = str(self.raiz / "casa-vacia")
        with mock.patch("shutil.which", return_value=None):
            self.assertEqual(modelos.opencode_por_omision(), Path("/opt/homebrew/bin/opencode"))


class CatalogoV2(unittest.TestCase):
    """El catálogo contra un doble que firma como la 2: `--version` contesta "opencode v2.0.29"
    (medido, G-opencode2-r1) y cada argv que recibe queda en argv.log."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.raiz = Path(temp.name).resolve()
        self.bin = self.raiz / "bin"
        self.bin.mkdir()
        (self.bin / "opencode").write_text(DOBLE_OPENCODE)
        (self.bin / "opencode").chmod(0o755)
        (self.bin / "listing").write_text(LISTING)

    def argv(self):
        lineas = (self.bin / "argv.log").read_text().splitlines()
        return [json.loads(linea) for linea in lineas]

    def store(self):
        return modelos.CatalogStore(self.bin / "opencode", self.raiz / "state")

    def test_la_version_firmada_por_la_2_se_guarda_sin_su_firma(self):
        (self.bin / "version").write_text("opencode v2.0.29\n")
        catalog = self.store().refresh()
        self.assertEqual(catalog.cli_version, "2.0.29")
        self.assertEqual((self.raiz / "state" / "catalogo.json").exists(), True)
        guardado = json.loads((self.raiz / "state" / "catalogo.json").read_text())
        self.assertEqual(guardado["cliVersion"], "2.0.29")

    def test_la_2_no_recibe_refresh_porque_su_models_no_lo_tiene(self):
        (self.bin / "version").write_text("opencode v2.0.29\n")
        self.store().refresh(upstream=True)
        self.assertIn(["models"], self.argv())

    def test_la_1x_sigue_pidiendo_refresh(self):
        (self.bin / "version").write_text("1.18.35\n")
        self.store().refresh(upstream=True)
        self.assertIn(["models", "--refresh"], self.argv())

    def test_una_version_sin_firma_valida_no_abre_el_catalogo(self):
        (self.bin / "version").write_text("opencode sin numero\n")
        with self.assertRaises(modelos.CatalogUnavailable):
            self.store().refresh()


if __name__ == "__main__":
    unittest.main()
