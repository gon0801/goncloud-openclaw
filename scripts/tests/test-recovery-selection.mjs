import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";

const script = resolve("scripts/recovery/build-selection.mjs");

function fixture(paths) {
  const root = mkdtempSync(join(tmpdir(), "recovery-selection-"));
  const git = (...args) => spawnSync("git", args, { cwd: root, encoding: "utf8" });
  assert.equal(git("init", "-q").status, 0);
  for (const path of paths) {
    const full = join(root, path);
    mkdirSync(dirname(full), { recursive: true });
    writeFileSync(full, `content: ${path}\n`);
  }
  assert.equal(git("add", ".").status, 0);
  const output = join(root, "selection.json");
  const run = () => spawnSync(process.execPath, [script, root, output], { encoding: "utf8" });
  return { root, output, run };
}

test("selects tracked runtime source, not tests, fixtures or skill backups", () => {
  const f = fixture([
    "gateway-watchdog.ps1",
    "summa-gate/index.ts",
    "summa-gate/index.test.ts",
    "summa-gate/verify-corpus.mjs",
    "tablero-runbook/render.ts",
    "tablero-runbook/fixtures/sample.json",
    "agents/main/agent/workshop-skills/a/SKILL.md",
    "agents/main/agent/workshop-skills/.backup-old/a/SKILL.md",
    "agents/main/agent/workshop-skills/a/SKILL.md.bak-20260912",
    "docs/plan.md",
  ]);
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  const manifest = JSON.parse(readFileSync(f.output, "utf8"));
  assert.deepEqual(manifest.files.map((entry) => entry.path), [
    "agents/main/agent/workshop-skills/a/SKILL.md",
    "gateway-watchdog.ps1",
    "summa-gate/index.ts",
    "tablero-runbook/render.ts",
  ]);
  assert.equal(manifest.files.every((entry) => /^[a-f0-9]{64}$/.test(entry.sha256)), true);
  assert.equal(f.run().status, 0);
});

test("fails closed when a tracked secret appears under a runtime source", () => {
  const f = fixture(["summa-gate/index.ts", "summa-gate/.env.local"]);
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.equal(result.stdout, "");
});

test("requires review before selecting a new plugin executable", () => {
  const f = fixture(["summa-gate/index.ts", "summa-gate/unreviewed.mjs"]);
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unreviewed plugin file/i);
});
