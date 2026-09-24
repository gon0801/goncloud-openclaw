import assert from "node:assert/strict";
import { createHash } from "node:crypto";
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

test("falla cerrado con un almacén de secretos trackeado bajo skills (C2)", () => {
  for (const bad of [
    "agents/main/agent/workshop-skills/a/secrets.json",
    "agents/main/agent/workshop-skills/a/credentials.json",
    "agents/main/agent/workshop-skills/a/secrets-prod.json",
    "agents/main/agent/workshop-skills/a/credential_backup.json",
  ]) {
    const f = fixture(["summa-gate/index.ts", bad]);
    const result = f.run();
    let accepted = "";
    if (result.status === 0) {
      const m = JSON.parse(readFileSync(f.output, "utf8"));
      accepted = ` SELECCIONÓ ${JSON.stringify(m.files.map((e) => e.path))}`;
    }
    assert.notEqual(result.status, 0, `build debe rechazar ${bad}.${accepted}`);
    assert.equal(result.stdout, "", bad);
  }
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

test("D1: CRLF del checkout (autocrlf) no rechaza archivos no modificados", () => {
  const f = fixture(["summa-gate/index.ts"]);
  const full = join(f.root, "summa-gate/index.ts");
  const committed = readFileSync(full);
  assert.ok(!committed.includes("\r"), "el fixture se commitea con LF");
  // Simula core.autocrlf=true: el vivo trae CRLF, el commit guarda LF.
  writeFileSync(full, committed.toString("utf8").replaceAll("\n", "\r\n"));
  const crlfOut = join(f.root, "selection-crlf.json");
  const result = spawnSync(process.execPath, [script, f.root, crlfOut], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  const manifest = JSON.parse(readFileSync(crlfOut, "utf8"));
  // El SHA registrado es el del blob pinneado (LF), no el del vivo (CRLF).
  assert.equal(manifest.files[0].sha256, createHash("sha256").update(committed).digest("hex"));
});

test("D1: CRLF no enmascara cambios reales de contenido", () => {
  const f = fixture(["summa-gate/index.ts"]);
  writeFileSync(join(f.root, "summa-gate/index.ts"), "contenido cambiado\r\n");
  const dirtyOut = join(f.root, "selection-crlf-dirty.json");
  const result = spawnSync(process.execPath, [script, f.root, dirtyOut], { encoding: "utf8" });
  assert.notEqual(result.status, 0, "build debe rechazar contenido cambiado aunque traiga CRLF");
  assert.match(result.stderr, /differs from pinned commit/);
});

function gitIn(root, ...args) {
  return spawnSync("git", ["-C", root, ...args], { encoding: "utf8" });
}

test("D1: miles de CRLF se normalizan sin perder bytes", () => {
  const f = fixture(["summa-gate/index.ts"]);
  const full = join(f.root, "summa-gate/index.ts");
  const lf = Buffer.from("línea de texto 0123456789\n".repeat(20000));
  writeFileSync(full, lf);
  assert.equal(gitIn(f.root, "add", ".").status, 0);
  assert.equal(
    gitIn(f.root, "-c", "user.email=u1@test", "-c", "user.name=u1", "commit", "-qm", "big").status, 0,
  );
  writeFileSync(full, Buffer.from(lf.toString("utf8").replaceAll("\n", "\r\n")));
  const out = join(f.root, "selection-big.json");
  const result = spawnSync(process.execPath, [script, f.root, out], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  const manifest = JSON.parse(readFileSync(out, "utf8"));
  assert.equal(manifest.files[0].sha256, createHash("sha256").update(lf).digest("hex"));
});

test("D2: binario con NUL se compara en bytes crudos (difiere aunque lo canónico coincida)", () => {
  const f = fixture(["agents/main/agent/workshop-skills/a/data.dat"]);
  const full = join(f.root, "agents/main/agent/workshop-skills/a/data.dat");
  const blob = Buffer.from([0x00, 0x01, 0x0d, 0x0a, 0x02, 0xff, 0x0d, 0x0a]);
  writeFileSync(full, blob);
  assert.equal(gitIn(f.root, "add", ".").status, 0);
  assert.equal(
    gitIn(f.root, "-c", "user.email=u1@test", "-c", "user.name=u1", "commit", "-qm", "bin").status, 0,
  );
  // El vivo pierde un \r: en bytes crudos difiere del blob, en canónico no.
  writeFileSync(full, Buffer.from([0x00, 0x01, 0x0a, 0x02, 0xff, 0x0d, 0x0a]));
  const out = join(f.root, "selection-bin.json");
  const result = spawnSync(process.execPath, [script, f.root, out], { encoding: "utf8" });
  assert.notEqual(result.status, 0, "build debe rechazar binario distinto en bytes crudos");
  assert.match(result.stderr, /differs from pinned commit/);
});

test("D2 control: binario con NUL sin modificar se acepta con SHA del blob", () => {
  const f = fixture(["agents/main/agent/workshop-skills/a/data.dat"]);
  const full = join(f.root, "agents/main/agent/workshop-skills/a/data.dat");
  const blob = Buffer.from([0x00, 0x01, 0x0d, 0x0a, 0x02, 0xff]);
  writeFileSync(full, blob);
  assert.equal(gitIn(f.root, "add", ".").status, 0);
  assert.equal(
    gitIn(f.root, "-c", "user.email=u1@test", "-c", "user.name=u1", "commit", "-qm", "bin").status, 0,
  );
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  const manifest = JSON.parse(readFileSync(f.output, "utf8"));
  assert.equal(manifest.files[0].sha256, createHash("sha256").update(blob).digest("hex"));
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
