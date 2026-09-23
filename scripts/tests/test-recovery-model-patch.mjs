import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const script = resolve("scripts/recovery/build-model-patch.mjs");
const ids = [
  "main",
  "operaciones",
  "ingenieria",
  "implementer",
  "reviewer",
  "adversary",
  "verifier",
  "scout",
];

function run(manifest) {
  const dir = mkdtempSync(join(tmpdir(), "recovery-models-"));
  const file = join(dir, "manifest.json");
  writeFileSync(file, JSON.stringify(manifest));
  return spawnSync(process.execPath, [script, file], { encoding: "utf8" });
}

test("builds ordered model chains and per-agent thinking without credentials", () => {
  const agents = Object.fromEntries(
    ids.map((id) => [
      id,
      {
        chain: [`provider/${id}`, "fallback/shared"],
        thinking: id === "main" ? { "fallback/shared": "xhigh" } : {},
      },
    ]),
  );
  const result = run({ version: 1, defaultsFrom: "main", agents });

  assert.equal(result.status, 0, result.stderr);
  const patch = JSON.parse(result.stdout);
  assert.deepEqual(patch.agents.defaults.model, {
    primary: "provider/main",
    fallbacks: ["fallback/shared"],
  });
  assert.deepEqual(patch.agents.entries.main.model, {
    primary: "provider/main",
    fallbacks: ["fallback/shared"],
  });
  assert.deepEqual(patch.agents.entries.scout.model, {
    primary: "provider/scout",
    fallbacks: ["fallback/shared"],
  });
  assert.deepEqual(patch.agents.entries.main.models, {
    "fallback/shared": { params: { thinking: "xhigh" } },
  });
  assert.equal(Object.keys(patch.agents.entries).length, 8);
  assert.deepEqual(Object.keys(patch), ["agents"]);
  assert.equal(result.stdout.includes("credentials"), false);
});

test("rejects duplicate model IDs before emitting a patch", () => {
  const agents = Object.fromEntries(
    ids.map((id) => [id, { chain: [`provider/${id}`, "fallback/shared"], thinking: {} }]),
  );
  agents.reviewer.chain = ["provider/reviewer", "provider/reviewer"];
  const result = run({ version: 1, defaultsFrom: "main", agents });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /duplicate model.*reviewer/i);
  assert.equal(result.stdout, "");
});

test("published recovery manifest preserves every screenshot chain in order", () => {
  const expected = {
    main: "opencode-go-resp/muse-spark-1.3-contributor|anthropic/claude-opus-5|meta/muse-spark-1.3|xai/grok-4.6|zai/glm-5.3|openai/gpt-5.6-sol|kimi/k3",
    operaciones: "opencode-go/deepseek-v4.1-flash|zai/glm-5.3-flash|openai/gpt-5.6-terra|anthropic/claude-sonnet-5|xai/grok-4.6|kimi/kimi-for-coding|meta/muse-spark-1.3",
    ingenieria: "opencode-go-resp/muse-spark-1.3-contributor|openai/gpt-5.6-sol|kimi/k3|zai/glm-5.3|meta/muse-spark-1.3|anthropic/claude-opus-5|xai/grok-4.6",
    implementer: "opencode-go-resp/muse-spark-1.3-contributor|meta/muse-spark-1.3|zai/glm-5.3-flash|xai/grok-4.6|anthropic/claude-sonnet-5|openai/gpt-5.6-terra|kimi/kimi-for-coding",
    reviewer: "opencode-go/deepseek-v4.1-flash|anthropic/claude-fable-5-1|kimi/k3|openai/gpt-6-astra|meta/muse-spark-1.3|xai/grok-4.6|zai/glm-5.3",
    adversary: "opencode-go/deepseek-v4.1-flash|xai/grok-4.6|kimi/k3|zai/glm-5.3|meta/muse-spark-1.3|anthropic/claude-opus-5|openai/gpt-5.6-sol",
    verifier: "opencode-go/deepseek-v4.1-flash|zai/glm-5.3-flash|meta/muse-spark-1.3|kimi/kimi-for-coding|anthropic/claude-sonnet-5|openai/gpt-5.6-terra|deepseek/deepseek-flash",
    scout: "opencode-go/deepseek-v4.1-flash|zai/glm-5.3-flash|meta/muse-spark-1.3|kimi/kimi-for-coding|deepseek/deepseek-flash|anthropic/claude-sonnet-5|openai/gpt-5.6-terra",
  };
  const result = spawnSync(
    process.execPath,
    [script, resolve("config/recovery-models-2026-09-19.json")],
    { encoding: "utf8" },
  );

  assert.equal(result.status, 0, result.stderr);
  const patch = JSON.parse(result.stdout);
  assert.deepEqual(Object.keys(patch.agents.entries), ids);
  for (const id of ids) {
    const { primary, fallbacks } = patch.agents.entries[id].model;
    assert.deepEqual([primary, ...fallbacks], expected[id].split("|"), id);
  }
  assert.deepEqual(patch.agents.defaults.model, patch.agents.entries.main.model);
  assert.equal(
    patch.agents.entries.operaciones.models["kimi/kimi-for-coding"].params.thinking,
    "high",
  );
  assert.equal(patch.agents.entries.verifier.models["kimi/kimi-for-coding"], undefined);
  assert.equal(
    patch.agents.entries.main.models["anthropic/claude-opus-5"].params.thinking,
    "xhigh",
  );
});

test("writes the private patch once and rejects a different existing file", () => {
  const dir = mkdtempSync(join(tmpdir(), "recovery-output-"));
  const manifestPath = join(dir, "manifest.json");
  const outputPath = join(dir, "patch.json");
  const agents = Object.fromEntries(
    ids.map((id) => [id, { chain: [`provider/${id}`], thinking: {} }]),
  );
  writeFileSync(manifestPath, JSON.stringify({ version: 1, defaultsFrom: "main", agents }));

  const command = () =>
    spawnSync(process.execPath, [script, manifestPath, outputPath], {
      encoding: "utf8",
    });
  const first = command();
  assert.equal(first.status, 0, first.stderr);
  assert.equal(first.stdout, "");
  const content = readFileSync(outputPath, "utf8");
  assert.equal(JSON.parse(content).agents.entries.main.model.primary, "provider/main");

  const old = new Date("2020-01-01T00:00:00Z");
  utimesSync(outputPath, old, old);
  const second = command();
  assert.equal(second.status, 0, second.stderr);
  assert.equal(statSync(outputPath).mtimeMs, old.getTime());

  writeFileSync(outputPath, "other data");
  const conflict = command();
  assert.notEqual(conflict.status, 0);
  assert.match(conflict.stderr, /existing patch differs/i);
  assert.equal(readFileSync(outputPath, "utf8"), "other data");
});

test("does not silently drop a ninth agent from the recovery manifest", () => {
  const agents = Object.fromEntries(
    ids.map((id) => [id, { chain: [`provider/${id}`], thinking: {} }]),
  );
  agents.usuario = { chain: ["provider/usuario"], thinking: {} };
  const result = run({ version: 1, defaultsFrom: "main", agents });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unexpected agent.*usuario/i);
  assert.equal(result.stdout, "");
});

test("rejects thinking settings for a model outside that agent's chain", () => {
  const agents = Object.fromEntries(
    ids.map((id) => [id, { chain: [`provider/${id}`], thinking: {} }]),
  );
  agents.main.thinking["other/model"] = "xhigh";
  const result = run({ version: 1, defaultsFrom: "main", agents });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /thinking model.*main/i);
  assert.equal(result.stdout, "");
});
