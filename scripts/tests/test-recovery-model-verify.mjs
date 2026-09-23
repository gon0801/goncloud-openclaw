import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const generator = resolve("scripts/recovery/build-model-patch.mjs");
const verifier = resolve("scripts/recovery/verify-models.mjs");
const manifest = resolve("config/recovery-models-2026-09-19.json");

function generatedConfig() {
  const result = spawnSync(process.execPath, [generator, manifest], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

function verify(config) {
  const dir = mkdtempSync(join(tmpdir(), "verify-recovery-models-"));
  const configPath = join(dir, "openclaw.json");
  writeFileSync(configPath, JSON.stringify(config));
  return spawnSync(process.execPath, [verifier, manifest, configPath], {
    encoding: "utf8",
  });
}

test("accepts the eight exact chains and thinking settings", () => {
  const config = generatedConfig();
  config.agents.entries.main.workspace = "C:\\Users\\ehven\\.openclaw\\workspace";
  config.models = { providers: { private: { apiKey: "DO_NOT_PRINT" } } };
  const result = verify(config);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /8 agent chains match/i);
  assert.equal(result.stdout.includes("DO_NOT_PRINT"), false);
});

test("rejects an ordered fallback mismatch without printing config secrets", () => {
  const config = generatedConfig();
  config.agents.entries.reviewer.model.fallbacks.reverse();
  config.models = { providers: { private: { apiKey: "DO_NOT_PRINT" } } };
  const result = verify(config);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /reviewer.*chain/i);
  assert.equal(result.stderr.includes("DO_NOT_PRINT"), false);
});

test("rejects missing and unexpected agents", () => {
  const config = generatedConfig();
  delete config.agents.entries.scout;
  config.agents.entries.unexpected = { model: { primary: "a/b" } };
  const result = verify(config);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /scout.*missing/i);
  assert.match(result.stderr, /unexpected.*agent/i);
});

test("rejects a changed thinking setting or defaults", () => {
  const config = generatedConfig();
  config.agents.entries.main.models["anthropic/claude-opus-5"].params.thinking = "low";
  config.agents.defaults.model.fallbacks.pop();
  const result = verify(config);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /main.*thinking/i);
  assert.match(result.stderr, /defaults.*chain/i);
});
