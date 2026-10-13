#!/usr/bin/env python3
"""Provider policy, opencode catalog, authorize, the refusal phrases and the launch plan (B22).

The catalog fixture is the real output of `/opt/homebrew/bin/opencode models`, opencode 1.18.35, captured
2026-10-13T01:11Z on David's MacBook. Regenerate it when a provider logs in or out and rewrite the counts
below in the same change.
"""

import collections
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import types
import typing
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import contracts  # noqa: E402
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
        self.assertEqual(sorted(policy.closed), ["opencode", "opencode-go", "zai"])
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
        self.assertEqual(policy.closed["opencode-go"].decision.quote, "open code go es solamente para main")
        self.assertEqual(policy.digest, hashlib.sha256(POLICY.read_bytes()).hexdigest())

    def test_the_repo_policy_is_already_in_the_format_permitir_writes(self):
        policy = ProviderPolicy.load(POLICY)
        self.assertEqual(modelos.policy_document(policy.grants, policy.closed), POLICY.read_bytes())

    def test_a_grant_without_a_bound_id_never_comes_out_of_grant_for(self):
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
            ("schema, providers y closed", lambda doc: doc.update(apodos={})),
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

    def test_a_permitted_model_cannot_be_built_outside_authorize(self):
        with self.assertRaisesRegex(TypeError, "solo sale de authorize"):
            PermittedModel(ModelId("opencode-go", "deepseek-v4-pro"), "subscription", "digest", "1.18.35")


class Authorize(Policies):
    def setUp(self):
        super().setUp()
        self.policy = ProviderPolicy.load(POLICY)

    def ask(self, request, *extra, policy=None):
        return authorize(request, policy or self.policy, catalog(*extra))

    def test_a_request_without_a_model_runs_the_default_on_the_subscription(self):
        answer = self.ask(DefaultModel())
        self.assertEqual((answer.model, answer.billing), (DEFAULT, "subscription"))

    def test_the_default_model_is_refused_when_its_provider_has_no_grant(self):
        self.assertEqual(self.ask(DefaultModel(), policy=self.only_deepseek()),
                         ProviderNotAllowed(models=(DEFAULT,), allowed=("deepseek",), closures=(), awaiting_login=()))

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
        refusal = authorize(DefaultModel(), self.only_deepseek(), catalog())
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

    def test_the_phrases_carry_the_values_david_needs(self):
        self.assertEqual(explicar(modelos.RouteNotCertified("1.18.36", ("1.18.35",))).frase,
                         "Ruta certificada para 1.18.35, la Mac tiene 1.18.36.")
        self.assertEqual(explicar(modelos.RouteNotCertified("1.18.35", ())).frase,
                         "La ruta de encargos por opencode todavía no está certificada. La Mac tiene opencode 1.18.35.")
        self.assertEqual(explicar(modelos.HostDown(600.0)).frase, "El host de encargos no corre desde hace 10 min.")
        self.assertEqual(explicar(modelos.HostDown(None)).frase, "El host de encargos nunca corrió en esta Mac.")
        self.assertEqual(explicar(modelos.HostMismatch("policy", "aaaa", "bbbb")).frase,
                         "El host de encargos corre con otra política: el host tiene aaaa y aquí hay bbbb.")
        self.assertEqual(explicar(PolicyUnreadable("la cita no trae quote (en el permiso deepseek)")).frase,
                         "La política de proveedores no se puede leer (la cita no trae quote (en el permiso "
                         "deepseek)). No corre ningún encargo hasta arreglarla.")
        similar = explicar(ModelNotListed(ModelId("zai-coding-plan", "glm-5.3-flahs"), (DEFAULT,)))
        self.assertEqual((similar.accion, similar.candidatos), ("preguntar-a-david", ("zai-coding-plan/glm-5.3-flash",)))
        self.assertEqual(explicar(modelos.WorkspaceRefused("/tmp/x", "not-a-git-toplevel")).frase,
                         "/tmp/x no es la raíz de un repo git con un commit.")

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

    def test_a_header_the_host_does_not_understand_is_refused_not_ignored(self):
        for brief, why in (
            (b"agent-work.launch.v1\nmodel: zai-coding-plan/glm-5.3\neffort: high\n---\n", "effort"),
            (b"agent-work.launch.v1\nmodel: zai-coding-plan/glm-5.3\nprosa sin cierre\n", "prosa sin cierre"),
            (b"agent-work.launch.v1\nmodel: zai-coding-plan/glm-5.3\n", "---"),
            (b"agent-work.launch.v1\nmodel: Zai/glm\n---\n", "Zai/glm"),
            (b"agent-work.launch.v1\nmodel: zai/glm-5.3\nmodel: opencode-go/kimi-k3\n---\n", "model"),
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
        self.assertEqual(self.route("certified", ("1.18.35", "1.18.20")).open_for("1.18.36", canary=False),
                         modelos.RouteNotCertified("1.18.36", ("1.18.20", "1.18.35")))
        self.assertEqual(self.route("sandbox-tested-uncertified").open_for("1.18.35", canary=False),
                         modelos.RouteNotCertified("1.18.35", ()))

    def test_a_canary_also_opens_a_sandbox_tested_route_and_a_new_version_but_never_a_disabled_one(self):
        self.assertIsNone(self.route("sandbox-tested-uncertified").open_for("1.18.35", canary=True))
        self.assertIsNone(self.route("certified").open_for("1.18.36", canary=True))
        self.assertEqual(self.route("disabled-operator-billing").open_for("1.18.35", canary=True),
                         modelos.RouteNotCertified("1.18.35", ()))

    def test_todays_coverage_opens_the_run_per_task_route_only_for_a_canary_host(self):
        coverage = json.loads(COVERAGE.read_text())
        route = sesion.Route.load(coverage, "mac-local")
        self.assertEqual(route, sesion.Route("mac-local", "opencode", "run-per-task", "sandbox-tested-uncertified",
                                             frozenset({"1.18.35"})))
        self.assertEqual(route.open_for("1.18.35", canary=False), modelos.RouteNotCertified("1.18.35", ()))
        self.assertEqual(modelos.explicar(route.open_for("1.18.35", canary=False)).frase,
                         "La ruta de encargos por opencode todavía no está certificada. La Mac tiene opencode 1.18.35.")
        self.assertIsNone(route.open_for("1.18.35", canary=True))

    def test_the_route_reads_its_measured_versions_from_coverage(self):
        coverage = {"hostAdapterCoverage": {"mac-local": {"opencode": "certified"}},
                    "hostAdapterRoute": {"mac-local": {"opencode": {
                        "form": "run-per-task", "certifiedCliVersions": {"1.18.35": "B22-fase0.md"}}}}}
        self.assertEqual(sesion.Route.load(coverage, "mac-local"),
                         sesion.Route("mac-local", "opencode", "run-per-task", "certified", frozenset({"1.18.35"})))
        self.assertIsNone(sesion.Route.load(coverage, "mac-local").open_for("1.18.35", canary=False))
        for broken in ({"form": "adopted-session", "certifiedCliVersions": {"1.18.35": "x"}}, {"form": "run-per-task"},
                       {"form": "run-per-task", "certifiedCliVersions": ["1.18.35"]}, "certified"):
            with self.subTest(broken):
                coverage["hostAdapterRoute"]["mac-local"]["opencode"] = broken
                self.assertEqual(sesion.Route.load(coverage, "mac-local").open_for("1.18.35", canary=False),
                                 modelos.RouteNotCertified("1.18.35", ()))
        self.assertEqual(sesion.Route.load(coverage, "windows-remote").status, "absent")


class Plans(Policies):
    OPERATION = "ab" * 32

    def setUp(self):
        super().setUp()
        self.root = self.root.resolve()
        self.allowed = self.root / "dev"
        self.repo = self.allowed / "demo"
        (self.repo / ".git").mkdir(parents=True)
        self.run = contracts.RunDir.for_operation(self.root / "spool", self.OPERATION)
        self.route = sesion.Route("mac-local", "opencode", "run-per-task", "certified", frozenset({"1.18.35"}))

    def plan(self, brief=b"Revisa el commit aaaa\n", *, policy=None, revision=None, route=None, cli="1.18.35",
             canary=False):
        assignment = {"target": {"kind": "cli", "hostId": "mac-local", "adapterId": "opencode"},
                      "inputRevision": revision or {"kind": "code", "repository": str(self.repo), "sha": "a" * 40}}
        return sesion.plan_launch(assignment, brief, policy=policy or ProviderPolicy.load(POLICY), catalog=catalog(),
                                  route=route or self.route, cli_version=cli, allowed_root=self.allowed, run=self.run,
                                  record=self.root / "spool/sessions" / self.OPERATION, operation=self.OPERATION,
                                  canary=canary)

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
        self.assertEqual(refusal.models, (ModelId("zai-coding-plan", "glm-5.3-flash"),))
        self.assertIsInstance(refusal, ProviderNotAllowed)
        self.assertNotIsInstance(refusal, sesion.LaunchSpec)
        answer = explicar(refusal, registrado=True)
        self.assertEqual((answer.causa, answer.accion), ("proveedor-no-permitido", "cancelar"))

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

    def test_a_route_that_is_not_open_refuses_before_reading_the_brief(self):
        uncertified = sesion.Route("mac-local", "opencode", "run-per-task", "sandbox-tested-uncertified",
                                   frozenset({"1.18.35"}))
        broken = b"agent-work.launch.v1\nmodel: Zai/glm\n---\n"
        self.assertEqual(self.plan(broken, route=uncertified), modelos.RouteNotCertified("1.18.35", ()))
        self.assertEqual(self.plan(cli="1.18.36"), modelos.RouteNotCertified("1.18.36", ("1.18.35",)))
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
                                (str(self.allowed), "outside-root"), (None, "not-absolute")):
            with self.subTest(repository):
                answer = self.plan(revision={"kind": "code", "repository": repository, "sha": "a" * 40})
                self.assertEqual(answer, modelos.WorkspaceRefused(str(repository), why))

    def test_a_task_without_repo_works_in_a_new_folder_inside_its_run(self):
        spec = self.plan(revision={"kind": "artifact", "ref": "artifact:aa", "digest": "sha256:aa"})
        self.assertEqual(spec.workspace.root, self.run.path / "work")
        self.assertTrue(spec.workspace.root.is_dir())


if __name__ == "__main__":
    unittest.main()
