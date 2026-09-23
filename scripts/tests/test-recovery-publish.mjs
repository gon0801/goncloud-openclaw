import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, statSync,
  renameSync, rmSync, symlinkSync, utimesSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";

const stageScript = resolve("scripts/recovery/stage-selected.mjs");
const publishScript = resolve("scripts/recovery/publish-selected.mjs");

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "recovery-publish-"));
  const source = join(root, "source");
  const stage = join(root, "stage");
  const runtime = join(root, "runtime");
  const transaction = join(root, "transaction");
  mkdirSync(source);
  mkdirSync(runtime);
  const paths = ["summa-gate/index.ts", "tablero-runbook/index.ts"];
  const files = paths.map((path, i) => {
    const target = join(source, path);
    mkdirSync(dirname(target), { recursive: true });
    const content = `new ${i}\n`;
    writeFileSync(target, content);
    return { path, sha256: createHash("sha256").update(content).digest("hex") };
  });
  const manifest = join(root, "selection.json");
  writeFileSync(manifest, JSON.stringify({ version: 1, files }));
  const staged = spawnSync(process.execPath, [stageScript, manifest, source, stage, "--apply"], { encoding: "utf8" });
  assert.equal(staged.status, 0, staged.stderr);
  const run = (mode, env = {}) => spawnSync(process.execPath, [publishScript, manifest, stage, runtime, transaction, mode], {
    encoding: "utf8", env: { ...process.env, ...env },
  });
  return { root, source, stage, runtime, transaction, manifest, files, run };
}

test("publishes exact files, creates rollback transaction, and is idempotent", () => {
  const f = fixture();
  const existing = join(f.runtime, f.files[0].path);
  mkdirSync(dirname(existing), { recursive: true });
  writeFileSync(existing, "old\n");
  const first = f.run("--apply");
  assert.equal(first.status, 0, first.stderr);
  assert.equal(readFileSync(existing, "utf8"), "new 0\n");
  assert.equal(readFileSync(join(f.runtime, f.files[1].path), "utf8"), "new 1\n");
  assert.equal(existsSync(join(f.transaction, "journal.json")), true);

  const old = new Date("2020-01-01T00:00:00Z");
  utimesSync(existing, old, old);
  const second = f.run("--apply");
  assert.equal(second.status, 0, second.stderr);
  assert.equal(statSync(existing).mtimeMs, old.getTime());
});

test("rollback restores replaced files and removes newly published files", () => {
  const f = fixture();
  const existing = join(f.runtime, f.files[0].path);
  mkdirSync(dirname(existing), { recursive: true });
  writeFileSync(existing, "old\n");
  assert.equal(f.run("--apply").status, 0);
  const rollback = f.run("--rollback");
  assert.equal(rollback.status, 0, rollback.stderr);
  assert.equal(readFileSync(existing, "utf8"), "old\n");
  assert.equal(existsSync(join(f.runtime, f.files[1].path)), false);
  assert.equal(f.run("--rollback").status, 0);
});

test("rollback works even when the staging directory is unavailable", () => {
  const f = fixture();
  assert.equal(f.run("--apply").status, 0);
  rmSync(f.stage, { recursive: true });
  const result = f.run("--rollback");
  assert.equal(result.status, 0, result.stderr);
  assert.equal(existsSync(join(f.runtime, f.files[0].path)), false);
});

test("fault after first publication rolls back automatically", () => {
  const f = fixture();
  const existing = join(f.runtime, f.files[0].path);
  mkdirSync(dirname(existing), { recursive: true });
  writeFileSync(existing, "old\n");
  const result = f.run("--apply", { RECOVERY_PUBLISH_FAULT: "after-first" });
  assert.notEqual(result.status, 0);
  assert.equal(readFileSync(existing, "utf8"), "old\n");
  assert.equal(existsSync(join(f.runtime, f.files[1].path)), false);
});

test("fault before rename leaves no temporary file or runtime change", () => {
  const f = fixture();
  const result = f.run("--apply", { RECOVERY_PUBLISH_FAULT: "before-rename" });
  assert.notEqual(result.status, 0);
  assert.equal(existsSync(join(f.runtime, f.files[0].path)), false);
  const dir = join(f.runtime, "summa-gate");
  assert.equal(existsSync(dir), false);
});

test("rollback refuses to overwrite a post-publication edit", () => {
  const f = fixture();
  assert.equal(f.run("--apply").status, 0);
  const target = join(f.runtime, f.files[0].path);
  writeFileSync(target, "someone else's change");
  const result = f.run("--rollback");
  assert.notEqual(result.status, 0);
  assert.equal(readFileSync(target, "utf8"), "someone else's change");
});

test("rollback refuses a journal directory that points at runtime root", () => {
  const f = fixture();
  assert.equal(f.run("--apply").status, 0);
  const journalPath = join(f.transaction, "journal.json");
  const journal = JSON.parse(readFileSync(journalPath, "utf8"));
  journal.createdDirs = ["."];
  writeFileSync(journalPath, JSON.stringify(journal));
  const result = f.run("--rollback");
  assert.notEqual(result.status, 0);
  assert.equal(readFileSync(join(f.runtime, f.files[0].path), "utf8"), "new 0\n");
});

test("refuses symlinked runtime destinations before writing", () => {
  const f = fixture();
  symlinkSync(f.source, join(f.runtime, "summa-gate"));
  const result = f.run("--apply");
  assert.notEqual(result.status, 0);
  assert.equal(existsSync(f.transaction), false);
});

test("refuses a forbidden path even if a staged file and manifest both request it", () => {
  const f = fixture();
  const unsafe = "agents/usuario/agent/workshop-skills/a/SKILL.md";
  const old = join(f.stage, f.files[0].path);
  const replacement = join(f.stage, unsafe);
  mkdirSync(dirname(replacement), { recursive: true });
  renameSync(old, replacement);
  f.files[0].path = unsafe;
  writeFileSync(f.manifest, JSON.stringify({ version: 1, files: f.files }));
  const result = f.run("--apply");
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unsafe selection/i);
  assert.equal(existsSync(f.transaction), false);
});
