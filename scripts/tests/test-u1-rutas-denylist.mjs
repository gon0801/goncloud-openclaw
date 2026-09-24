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
  // C1: --apply recibe la fuente (aquí un directorio existente; las pruebas de
  // política fallan antes de la validación de proveniencia y no la alcanzan).
  return spawnSync(
    process.execPath, [publishScript, manifest, f.stage, f.runtime, f.state, f.source, "--apply"],
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

const CREDENCIALES_SKILLS = [
  "agents/main/agent/workshop-skills/a/secrets.json",
  "summa-gate/app-secrets.json",
  "tablero-runbook/credentials.json",
  "agents/main/agent/workshop-skills/a/secrets-prod.json",
  "agents/main/agent/workshop-skills/a/credential_backup.json",
  "summa-gate/secret-backup.json",
];

for (const bad of CREDENCIALES_SKILLS) {
  test(`denylist (credenciales) rechaza almacén de secretos commiteado: ${bad} (C2)`, () => {
    const f = fixture();
    // C2 (Codex): la allowlist de skills admitía cualquier archivo, incluido
    // un secrets.json commiteado. La fuente es un checkout git con commit y el
    // manifiesto lo declara: ni así pasa.
    plantFile(f.source, bad, '{"token":"NO-PUBLICAR"}\n');
    plantFile(f.stage, bad, '{"token":"NO-PUBLICAR"}\n');
    const git = (...args) => spawnSync("git", args, { cwd: f.source, encoding: "utf8" });
    assert.equal(git("init", "-q").status, 0);
    assert.equal(git("add", ".").status, 0);
    assert.equal(
      git("-c", "user.email=u1@test", "-c", "user.name=u1", "commit", "-qm", "v1").status, 0,
    );
    const manifest = join(f.root, "selection.json");
    writeFileSync(manifest, JSON.stringify({
      version: 1,
      policyVersion: 1,
      commit: git("rev-parse", "HEAD").stdout.trim(),
      files: [{ path: bad, sha256: sha('{"token":"NO-PUBLICAR"}\n') }],
    }));
    const staged = runStage(manifest, f, "--apply");
    assert.notEqual(staged.status, 0, `stage aceptó ${bad}`);
    assert.match(staged.stderr, /denylisted credenciales/, bad);
    const published = runPublish(manifest, f);
    assert.notEqual(published.status, 0, `publish aceptó ${bad}`);
    assert.match(published.stderr, /denylisted credenciales/, bad);
    assert.equal(existsSync(f.state), false, bad);
  });
}

test("rutas buenas pasan dry-run sin escribir (desactivado por defecto)", () => {
  const f = fixture();
  // secretary-notes.md y accreditation.ts contienen "secret"/"credential" como
  // subcadena pero no son almacenes: la denylist C2 no debe alcanzarlos.
  const good = [
    GOOD,
    "agents/main/agent/workshop-skills/a/SKILL.md",
    "agents/main/agent/workshop-skills/a/secretary-notes.md",
    "summa-gate/accreditation.ts",
    "gateway-watchdog.ps1",
  ];
  const entries = good.map((path, i) => {
    plantFile(f.source, path, `file ${i}\n`);
    return { path, sha256: sha(`file ${i}\n`) };
  });
  // B6: el dry-run también valida proveniencia — fuente commiteada y commit
  // declarado en el manifiesto.
  const git = (...args) => spawnSync("git", args, { cwd: f.source, encoding: "utf8" });
  assert.equal(git("init", "-q").status, 0);
  assert.equal(git("add", ".").status, 0);
  assert.equal(
    git("-c", "user.email=u1@test", "-c", "user.name=u1", "commit", "-qm", "v1").status, 0,
  );
  const manifest = join(f.root, "selection.json");
  writeFileSync(manifest, JSON.stringify({
    version: 1,
    policyVersion: 1,
    commit: git("rev-parse", "HEAD").stdout.trim(),
    files: entries,
  }));
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
