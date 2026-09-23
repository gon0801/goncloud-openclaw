import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync,
  symlinkSync, utimesSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";

const script = resolve("scripts/recovery/stage-selected.mjs");

function fixture(paths = ["summa-gate/index.ts"]) {
  const root = mkdtempSync(join(tmpdir(), "recovery-stage-"));
  const source = join(root, "source");
  const stage = join(root, "stage");
  mkdirSync(source);
  const files = paths.map((path, i) => {
    const full = join(source, path);
    mkdirSync(dirname(full), { recursive: true });
    const content = `file ${i}\n`;
    writeFileSync(full, content);
    return { path, sha256: createHash("sha256").update(content).digest("hex") };
  });
  const manifest = join(root, "selection.json");
  writeFileSync(manifest, JSON.stringify({ version: 1, files }));
  const run = (...flags) => spawnSync(process.execPath, [script, manifest, source, stage, ...flags], {
    encoding: "utf8",
  });
  return { root, source, stage, manifest, files, run };
}

test("dry-run validates exact selection without writing; apply stages once", () => {
  const f = fixture(["summa-gate/index.ts", "agents/main/agent/workshop-skills/a/SKILL.md"]);
  const preview = f.run();
  assert.equal(preview.status, 0, preview.stderr);
  assert.equal(existsSync(f.stage), false);

  const first = f.run("--apply");
  assert.equal(first.status, 0, first.stderr);
  assert.equal(readFileSync(join(f.stage, f.files[0].path), "utf8"), "file 0\n");
  const old = new Date("2020-01-01T00:00:00Z");
  utimesSync(join(f.stage, f.files[0].path), old, old);
  const second = f.run("--apply");
  assert.equal(second.status, 0, second.stderr);
  assert.equal(lstatSync(join(f.stage, f.files[0].path)).mtimeMs, old.getTime());
});

test("refuses changed source or existing stage without overwriting", () => {
  const f = fixture();
  writeFileSync(join(f.source, f.files[0].path), "different");
  const changed = f.run("--apply");
  assert.notEqual(changed.status, 0);
  assert.equal(existsSync(f.stage), false);

  writeFileSync(join(f.source, f.files[0].path), "file 0\n");
  assert.equal(f.run("--apply").status, 0);
  writeFileSync(join(f.stage, f.files[0].path), "tampered");
  const conflict = f.run("--apply");
  assert.notEqual(conflict.status, 0);
  assert.equal(readFileSync(join(f.stage, f.files[0].path), "utf8"), "tampered");
});

test("rejects traversal, secret, ADS and duplicate paths before staging", () => {
  for (const path of [
    "../escape", "credentials/token.json", "summa-gate/openclaw.json",
    "summa-gate/x:stream", "agents/usuario/agent/workshop-skills/a/SKILL.md",
    "agents/main/agent/workshop-skills/a/SKILL.md.bak-20260912",
  ]) {
    const f = fixture();
    f.files[0].path = path;
    if (!path.startsWith("../") && !path.includes(":")) {
      const full = join(f.source, path);
      mkdirSync(dirname(full), { recursive: true });
      writeFileSync(full, "file 0\n");
    }
    writeFileSync(f.manifest, JSON.stringify({ version: 1, files: f.files }));
    const result = f.run("--apply");
    assert.notEqual(result.status, 0, path);
    assert.match(result.stderr, /unsafe selection path|outside recovery allowlist/, path);
    assert.equal(existsSync(f.stage), false, path);
  }
  const f = fixture();
  f.files.push({ ...f.files[0] });
  writeFileSync(f.manifest, JSON.stringify({ version: 1, files: f.files }));
  assert.notEqual(f.run("--apply").status, 0);
  assert.equal(existsSync(f.stage), false);
});

test("rejects extra files in an existing stage", () => {
  const f = fixture();
  assert.equal(f.run("--apply").status, 0);
  writeFileSync(join(f.stage, "extra.txt"), "do not remove");
  const result = f.run("--apply");
  assert.notEqual(result.status, 0);
  assert.equal(readFileSync(join(f.stage, "extra.txt"), "utf8"), "do not remove");
});

test("rejects symlinked source components and overlapping roots", () => {
  const f = fixture();
  const link = join(f.source, "tablero-runbook");
  symlinkSync(join(f.source, "summa-gate"), link);
  f.files[0].path = "tablero-runbook/index.ts";
  writeFileSync(f.manifest, JSON.stringify({ version: 1, files: f.files }));
  assert.notEqual(f.run("--apply").status, 0);
  assert.equal(existsSync(f.stage), false);

  const nested = spawnSync(process.execPath, [script, f.manifest, f.source, join(f.source, "stage"), "--apply"], { encoding: "utf8" });
  assert.notEqual(nested.status, 0);
  assert.equal(existsSync(join(f.source, "stage")), false);
});

test("refuses to use a live .openclaw directory as source", () => {
  const f = fixture();
  const live = join(f.root, ".openclaw");
  mkdirSync(live);
  mkdirSync(join(live, "summa-gate"));
  writeFileSync(join(live, "summa-gate", "index.ts"), "file 0\n");
  const result = spawnSync(process.execPath, [script, f.manifest, live, f.stage, "--apply"], {
    encoding: "utf8",
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /live.*source/i);
  assert.equal(existsSync(f.stage), false);
});

test("refuses to stage inside a live .openclaw directory", () => {
  const f = fixture();
  const live = join(f.root, ".openclaw");
  mkdirSync(live);
  const destination = join(live, "staging");
  const result = spawnSync(process.execPath, [script, f.manifest, f.source, destination, "--apply"], {
    encoding: "utf8",
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /live.*stage/i);
  assert.equal(existsSync(destination), false);
});
