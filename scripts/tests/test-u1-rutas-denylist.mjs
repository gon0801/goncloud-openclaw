import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  existsSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";

const BIN = process.env.SYNC_SEGURO_BIN
  ? resolve(process.env.SYNC_SEGURO_BIN)
  : resolve("scripts/sync-seguro");
const stageScript = join(BIN, "stage-selected.mjs");
const publishScript = join(BIN, "publish-selected.mjs");

const GOOD = "summa-gate/index.ts";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "u1-rutas-"));
  const source = join(root, "source");
  const stage = join(root, "stage");
  const runtime = join(root, "runtime");
  const state = join(root, "state");
  mkdirSync(source);
  mkdirSync(runtime);
  return { root, source, stage, runtime, state };
}

function sha(text) {
  return createHash("sha256").update(text).digest("hex");
}

function writeManifest(f, entries) {
  const manifest = join(f.root, "selection.json");
  writeFileSync(manifest, JSON.stringify({ version: 1, policyVersion: 1, files: entries }));
  return manifest;
}

function runStage(manifest, f, ...flags) {
  return spawnSync(process.execPath, [stageScript, manifest, f.source, f.stage, ...flags], {
    encoding: "utf8",
  });
}

function runPublish(manifest, f) {
  return spawnSync(
    process.execPath, [publishScript, manifest, f.stage, f.runtime, f.state, "--apply"],
    { encoding: "utf8" },
  );
}

function plantFile(root, rel, content) {
  const full = join(root, rel);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, content);
}

const ESCAPES = [
  "../escape",
  "/absoluto/x.ts",
  "C:/win/abs.ts",
  "C:\\win\\back.ts",
  "//srv/share/x.ts",
  "summa-gate/../../escape.ts",
  "summa-gate/x:stream",
  "summa-gate/con.ts",
  "summa-gate/trailing. ",
  "summa-gate/back\\slash.ts",
  "tablero-runbook/.oculto.ts",
  "agents/usuario/agent/workshop-skills/a/SKILL.md",
];

for (const bad of ESCAPES) {
  test(`escape rechazado en stage y publish: ${bad}`, () => {
    const f = fixture();
    const manifest = writeManifest(f, [{ path: bad, sha256: sha("x\n") }]);
    const staged = runStage(manifest, f, "--apply");
    assert.notEqual(staged.status, 0, `stage aceptó ${bad}`);
    assert.match(staged.stderr, /unsafe selection path/, bad);
    assert.equal(existsSync(f.stage), false, bad);
    const published = runPublish(manifest, f);
    assert.notEqual(published.status, 0, `publish aceptó ${bad}`);
    assert.match(published.stderr, /unsafe selection path/, bad);
    assert.equal(existsSync(f.state), false, bad);
  });
}

const DENYLIST = [
  ["bases", "summa-gate/x.sqlite"],
  ["bases", "agents/main/agent/workshop-skills/a/y.db"],
  ["credenciales", "summa-gate/.env.local"],
  ["credenciales", "summa-gate/k.pem"],
  ["credenciales", "tablero-runbook/openclaw.json"],
  ["sesiones", "summa-gate/sessions/x.ts"],
  ["logs", "summa-gate/logs/x.ts"],
  ["herramientas", "summa-gate/tools/x.ts"],
  ["modelos", "summa-gate/models/m.gguf"],
  ["launchers generados", "summa-gate/x.cmd"],
  ["launchers generados", "tablero-runbook/y.vbs"],
];

for (const [category, bad] of DENYLIST) {
  test(`denylist (${category}) rechaza aunque el archivo exista: ${bad}`, () => {
    const f = fixture();
    // El archivo existe en fuente y stage con hash consistente: ni así pasa.
    plantFile(f.source, bad, "contenido\n");
    plantFile(f.stage, bad, "contenido\n");
    const manifest = writeManifest(f, [{ path: bad, sha256: sha("contenido\n") }]);
    const staged = runStage(manifest, f, "--apply");
    assert.notEqual(staged.status, 0, `stage aceptó ${bad}`);
    assert.match(staged.stderr, new RegExp(`denylisted ${category}`), bad);
    const published = runPublish(manifest, f);
    assert.notEqual(published.status, 0, `publish aceptó ${bad}`);
    assert.match(published.stderr, new RegExp(`denylisted ${category}`), bad);
    assert.equal(existsSync(f.state), false, bad);
  });
}

test("rutas buenas pasan dry-run sin escribir (desactivado por defecto)", () => {
  const f = fixture();
  const good = [GOOD, "agents/main/agent/workshop-skills/a/SKILL.md", "gateway-watchdog.ps1"];
  const entries = good.map((path, i) => {
    plantFile(f.source, path, `file ${i}\n`);
    return { path, sha256: sha(`file ${i}\n`) };
  });
  const manifest = writeManifest(f, entries);
  const dry = runStage(manifest, f);
  assert.equal(dry.status, 0, dry.stderr);
  assert.equal(existsSync(f.stage), false);
  assert.match(dry.stdout, /no stage written/);
});

test("publish rechaza destino symlinkeado antes de escribir", () => {
  const f = fixture();
  plantFile(f.stage, GOOD, "nuevo\n");
  const manifest = writeManifest(f, [{ path: GOOD, sha256: sha("nuevo\n") }]);
  symlinkSync(f.source, join(f.runtime, "summa-gate"));
  const published = runPublish(manifest, f);
  assert.notEqual(published.status, 0);
  assert.equal(existsSync(f.state), false);
});
