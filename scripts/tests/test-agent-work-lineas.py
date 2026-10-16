#!/usr/bin/env python3
"""La regla de línea de SUA-04 (4.1): los casos de model_lines.py de goncloud-hermes, copiados
como fixture literal, uno más por proveedor de la política de G, y la comparación con el archivo
de Hermes cuando está en la máquina."""

import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import lineas  # noqa: E402

HERMES_LINES = Path("/Users/dn/dev/goncloud-hermes/scripts/model_lines.py")

# Los casos de tests/test_model_lines.py de goncloud-hermes, tal cual (ParseTests y
# NewerInLineTests): si la regla de G se aparta de la de Hermes, esto lo dice aquí.
PARSE_OK = {
    "grok-4.7": ("grok-{}", (4, 7)),
    "gpt-5.6-sol": ("gpt-{}-sol", (5, 6)),
    "claude-opus-5-5": ("claude-opus-{}", (5, 5)),
    "glm-5.3-flash": ("glm-{}-flash", (5, 3)),
    "k3": ("k{}", (3,)),
    "muse-spark-1.3-contributor": ("muse-spark-{}-contributor", (1, 3)),
    "deepseek-v4.1-flash": ("deepseek-v{}-flash", (4, 1)),
}
PARSE_NONE = (
    "kimi-for-coding",
    "deepseek-flash",
    "claude-opus-5-5-20260922",
    "grok-4.20-0309-reasoning",
    "muse-spark-1.3-contributor-free",
    "gpt-6-preview",
    "glm-5.3-exp",
    "claude-3-5-sonnet-v2",
)


def catalog(*ids, deprecated=()):
    return {
        **{model: {} for model in ids},
        **{model: {"status": "deprecated"} for model in deprecated},
    }


SUCESOR_CASES = [
    ("grok-4.7", catalog("grok-4.8", "grok-4.20-0309-reasoning"), "grok-4.8"),
    ("gpt-5.6-sol", catalog("gpt-6-sol", "gpt-6.1-sol", "gpt-6-luna"), "gpt-6.1-sol"),
    (
        "claude-opus-5-5",
        catalog("claude-opus-6", "claude-opus-5-5-20260922", "claude-sonnet-6"),
        "claude-opus-6",
    ),
    ("glm-5.3-flash", catalog("glm-5.4", "glm-5.4-flash", "glm-5.3-highspeed"), "glm-5.4-flash"),
    ("k3", catalog("k3-256k", "k4"), "k4"),
    ("kimi-for-coding", catalog("kimi-for-coding", "k4"), None),
    ("deepseek-flash", catalog("deepseek-flash", "deepseek-v5-flash"), None),
    (
        "muse-spark-1.3-contributor",
        catalog("muse-spark-1.4", "muse-spark-1.4-contributor"),
        "muse-spark-1.4-contributor",
    ),
]


class Parse(unittest.TestCase):
    def test_the_single_version_run_becomes_the_line(self):
        for model, expected in PARSE_OK.items():
            with self.subTest(model=model):
                self.assertEqual(lineas.parse(model), expected)

    def test_ids_that_are_not_a_release_to_follow_have_no_line(self):
        for model in PARSE_NONE:
            with self.subTest(model=model):
                self.assertIsNone(lineas.parse(model))
                self.assertFalse(lineas.estable(model))

    def test_edge_cases_the_brief_names(self):
        # Dos versiones con distinto número de partes, un id fechado, un -preview, un -latest
        # y un id sin versión.
        self.assertEqual(lineas.parse("glm-5"), ("glm-{}", (5,)))
        self.assertEqual(lineas.sucesor("glm-5", ["glm-5.3"]), "glm-5.3")
        self.assertIsNone(lineas.sucesor("glm-5.3", ["glm-5"]))
        self.assertIsNone(lineas.parse("glm-5.3-flash-20261016"))
        self.assertIsNone(lineas.parse("glm-5.4-flash-preview"))
        self.assertIsNone(lineas.parse("glm-latest"))
        self.assertIsNone(lineas.parse("glm-flash"))


class Sucesor(unittest.TestCase):
    def test_the_cases_the_owner_will_meet(self):
        for current, available, expected in SUCESOR_CASES:
            with self.subTest(current=current):
                self.assertEqual(lineas.sucesor(current, available), expected)

    def test_versions_compare_zero_padded(self):
        self.assertIsNone(lineas.sucesor("gpt-6-sol", ["gpt-6.0-sol"]))
        self.assertEqual(lineas.sucesor("gpt-6-sol", ["gpt-6.1-sol"]), "gpt-6.1-sol")
        self.assertIsNone(lineas.sucesor("gpt-6.1-sol", ["gpt-6-sol", "gpt-6.1-sol"]))

    def test_one_family_per_provider_of_the_policy(self):
        policy = json.loads(
            (ROOT / "docs/evidence/agent-work/proveedores-permitidos.json").read_text()
        )
        casos = {
            "glm": ("zai-coding-plan/glm-5.3-flash", "zai-coding-plan/glm-5.4-flash"),
            "claude": ("anthropic/claude-opus-5-5", "anthropic/claude-opus-5-6"),
            "grok": ("xai/grok-4.7", "xai/grok-4.8"),
            "gpt": ("openai/gpt-5.6-sol", "openai/gpt-6.1-sol"),
            "muse": ("meta/muse-wonder-1.0", "meta/muse-wonder-1.1"),
            "kimi": ("kimi-code-plan-cn/k3", "kimi-code-plan-cn/k4"),
            "qwen": ("alibaba-token-plan/qwen3.7-max", "alibaba-token-plan/qwen3.8-max"),
            "deepseek": ("deepseek/deepseek-v4.1-flash", "deepseek/deepseek-v4.2-flash"),
        }
        for grant in policy["providers"]:
            with self.subTest(permiso=grant["name"]):
                actual, esperado = casos[grant["name"]]
                self.assertTrue(actual.startswith(grant["provider"] + "/"))
                self.assertEqual(lineas.parse(actual)[0], lineas.parse(esperado)[0])
                # El mismo modelo con otro proveedor nunca es sucesor.
                otro = "otro-proveedor/" + esperado.split("/", 1)[1]
                self.assertEqual(lineas.sucesor(actual, [otro, esperado]), esperado)
                self.assertIsNone(lineas.sucesor(actual, [otro]))


@unittest.skipUnless(
    HERMES_LINES.is_file(), f"no está {HERMES_LINES}: la comparación con Hermes se salta"
)
class HermesComparison(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("hermes_model_lines", HERMES_LINES)
        self.hermes = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.hermes
        spec.loader.exec_module(self.hermes)

    def test_parse_agrees_on_the_copied_cases(self):
        for model in list(PARSE_OK) + list(PARSE_NONE):
            with self.subTest(model=model):
                theirs = self.hermes.parse(model)
                self.assertEqual(
                    lineas.parse(model), None if theirs is None else (theirs.line, theirs.version)
                )

    def test_newer_in_line_agrees_on_the_copied_cases(self):
        for current, available, _ in SUCESOR_CASES:
            with self.subTest(current=current):
                self.assertEqual(
                    lineas.sucesor(current, available),
                    self.hermes.newer_in_line(current, available),
                )


if __name__ == "__main__":
    unittest.main()
