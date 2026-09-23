import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";

const BIN = process.env.SYNC_SEGURO_BIN
  ? resolve(process.env.SYNC_SEGURO_BIN)
  : resolve("scripts/sync-seguro");
const script = join(BIN, "build-selection.mjs");

function fixture(paths) {
  const root = mkdtempSync(join(tmpdir(), "u1-selection-"));
  const git = (...args) => spawnSync("git", args, { cwd: root, encoding: "utf8" });
  assert.equal(git("init", "-q").status, 0);
  for (const path of paths) {
    const full = join(root, path);
    mkdirSync(dirname(full), { recursive: true });
    writeFileSync(full, `content: ${path}\n`);
  }
  assert.equal(git("add", ".").status, 0);
  assert.equal(git("-c", "user.email=u1@test", "-c", "user.name=u1", "commit", "-qm", "init").status, 0);
  const output = join(root, "selection.json");
  const run = () => spawnSync(process.execPath, [script, root, output], { encoding: "utf8" });
  return { root, output, run };
}

test("selecciona fuente trackeada del runtime, no tests ni respaldos", () => {
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
  assert.equal(manifest.policyVersion, 1);
  assert.equal(f.run().status, 0);
});

test("falla cerrado con un secreto trackeado bajo fuente del runtime", () => {
  const f = fixture(["summa-gate/index.ts", "summa-gate/.env.local"]);
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.equal(result.stdout, "");
});

test("exige revisión antes de seleccionar un ejecutable nuevo del plugin", () => {
  const f = fixture(["summa-gate/index.ts", "summa-gate/unreviewed.mjs"]);
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unreviewed plugin file/i);
});

test("rechaza bytes dirty: lo modificado sin commit no entra al manifiesto (B4)", () => {
  const f = fixture(["summa-gate/index.ts"]);
  writeFileSync(join(f.root, "summa-gate/index.ts"), "dirty sin commit\n");
  const dirtyOut = join(f.root, "selection-dirty.json");
  const result = spawnSync(process.execPath, [script, f.root, dirtyOut], { encoding: "utf8" });
  let accepted = "";
  if (result.status === 0) {
    const m = JSON.parse(readFileSync(dirtyOut, "utf8"));
    accepted = ` ACEPTÓ dirty (sha=${m.files[0].sha256.slice(0, 12)}… sin commit)`;
  }
  assert.notEqual(result.status, 0, `build debe rechazar bytes dirty sin commit.${accepted}`);
  assert.match(result.stderr, /differs from pinned commit/);
});

test("el manifiesto registra el SHA del commit pinned (B4)", () => {
  const f = fixture(["summa-gate/index.ts", "gateway-watchdog.ps1"]);
  const head = spawnSync("git", ["-C", f.root, "rev-parse", "HEAD"], { encoding: "utf8" }).stdout.trim();
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  const manifest = JSON.parse(readFileSync(f.output, "utf8"));
  assert.match(manifest.commit ?? "", /^[a-f0-9]{40}$/, "el manifiesto debe registrar el commit");
  assert.equal(manifest.commit, head);
});

test("rechaza un runtime vivo .openclaw como fuente", () => {
  const root = mkdtempSync(join(tmpdir(), "u1-selection-"));
  const live = join(root, ".openclaw");
  mkdirSync(join(live, "summa-gate"), { recursive: true });
  writeFileSync(join(live, "summa-gate", "index.ts"), "x\n");
  const git = (...args) => spawnSync("git", args, { cwd: live, encoding: "utf8" });
  assert.equal(git("init", "-q").status, 0);
  assert.equal(git("add", ".").status, 0);
  const output = join(root, "selection.json");
  const result = spawnSync(process.execPath, [script, live, output], { encoding: "utf8" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /live runtime cannot be recovery source/);
});
