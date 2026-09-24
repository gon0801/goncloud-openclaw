import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync,
  symlinkSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";

const BIN = process.env.SYNC_SEGURO_BIN
  ? resolve(process.env.SYNC_SEGURO_BIN)
  : resolve("scripts/sync-seguro");
const buildScript = join(BIN, "build-selection.mjs");
const stageScript = join(BIN, "stage-selected.mjs");
const publishScript = join(BIN, "publish-selected.mjs");

function sha(text) {
  return createHash("sha256").update(text).digest("hex");
}

function git(cwd, ...args) {
  return spawnSync("git", args, { cwd, encoding: "utf8" });
}

// Repo fuente con UN commit: lo commiteado es v1, el vivo puede moverse a v2.
function gitSource(files) {
  const root = mkdtempSync(join(tmpdir(), "u1-b6-"));
  const source = join(root, "source");
  for (const [path, content] of Object.entries(files)) {
    const full = join(source, path);
    mkdirSync(dirname(full), { recursive: true });
    writeFileSync(full, content);
  }
  assert.equal(git(source, "init", "-q").status, 0);
  assert.equal(git(source, "add", ".").status, 0);
  assert.equal(
    git(source, "-c", "user.email=u1@test", "-c", "user.name=u1", "commit", "-qm", "v1").status, 0,
  );
  const head = git(source, "rev-parse", "HEAD").stdout.trim();
  return { root, source, head };
}

test("B6: manifiesto a mano con bytes sin commit se rechaza; no se publica (proveniencia)", () => {
  const v1 = "versión commiteada\n";
  const v2 = "versión SIN commit, preparada a mano\n";
  const f = gitSource({ "summa-gate/index.ts": v1 });
  writeFileSync(join(f.source, "summa-gate/index.ts"), v2);
  const manifest = join(f.root, "selection.json");
  writeFileSync(manifest, JSON.stringify({
    version: 1,
    policyVersion: 1,
    commit: f.head,
    files: [{ path: "summa-gate/index.ts", sha256: sha(v2) }],
  }));
  const stage = join(f.root, "stage");
  const runtime = join(f.root, "runtime");
  const state = join(f.root, "state");
  mkdirSync(runtime);
  const staged = spawnSync(
    process.execPath, [stageScript, manifest, f.source, stage, "--apply"], { encoding: "utf8" },
  );
  let extra = "";
  if (staged.status === 0) {
    // Pre-fix: el stage acepta bytes que no están en el commit declarado y el
    // publish los lleva al vivo. Se cita lo que nunca debió publicarse.
    const published = spawnSync(
      process.execPath, [publishScript, manifest, stage, runtime, state, "--apply"],
      { encoding: "utf8" },
    );
    const target = join(runtime, "summa-gate/index.ts");
    const live = existsSync(target) ? readFileSync(target, "utf8") : "<ausente>";
    extra = ` PUBLICÓ SIN COMMIT (stage rc=0, publish rc=${published.status}, vivo=${JSON.stringify(live)})`;
  }
  assert.notEqual(staged.status, 0, `stage debe rechazar bytes fuera del commit declarado.${extra}`);
  assert.match(staged.stderr, /pinned commit/);
  assert.equal(existsSync(stage), false, "nada a medio stager");
  assert.equal(
    existsSync(join(runtime, "summa-gate/index.ts")), false, "lo sin commit no llega al vivo",
  );
});

test("B6 control: build→stage→publish desde bytes commiteados sigue en verde", () => {
  const f = gitSource({
    "summa-gate/index.ts": "a commiteado\n",
    "tablero-runbook/index.ts": "b commiteado\n",
  });
  const manifest = join(f.root, "selection.json");
  const built = spawnSync(process.execPath, [buildScript, f.source, manifest], { encoding: "utf8" });
  assert.equal(built.status, 0, built.stderr);
  const stage = join(f.root, "stage");
  const staged = spawnSync(
    process.execPath, [stageScript, manifest, f.source, stage, "--apply"], { encoding: "utf8" },
  );
  assert.equal(staged.status, 0, staged.stderr);
  const runtime = join(f.root, "runtime");
  const state = join(f.root, "state");
  mkdirSync(runtime);
  const published = spawnSync(
    process.execPath, [publishScript, manifest, stage, runtime, state, f.source, "--apply"],
    { encoding: "utf8" },
  );
  assert.equal(published.status, 0, published.stderr);
  assert.equal(readFileSync(join(runtime, "summa-gate/index.ts"), "utf8"), "a commiteado\n");
  assert.equal(readFileSync(join(runtime, "tablero-runbook/index.ts"), "utf8"), "b commiteado\n");
});

function backupFixture(linkSetup) {
  const root = mkdtempSync(join(tmpdir(), "u1-b7-"));
  const source = join(root, "source");
  const stage = join(root, "stage");
  const runtime = join(root, "runtime");
  const state = join(root, "state");
  const outside = join(root, "fuera");
  mkdirSync(join(stage, "summa-gate"), { recursive: true });
  mkdirSync(join(source, "summa-gate"), { recursive: true });
  mkdirSync(join(runtime, "summa-gate"), { recursive: true });
  mkdirSync(state);
  mkdirSync(outside);
  const staged = "nuevo\n";
  writeFileSync(join(stage, "summa-gate/index.ts"), staged);
  // C1: lo staged está commiteado en la fuente para pasar la proveniencia de
  // publish y llegar al gate del respaldo.
  writeFileSync(join(source, "summa-gate/index.ts"), staged);
  writeFileSync(join(runtime, "summa-gate/index.ts"), "viejo\n");
  const sentinel = "SECRETO-NO-TOCAR\n";
  writeFileSync(join(outside, "sagrado.txt"), sentinel);
  assert.equal(git(source, "init", "-q").status, 0);
  assert.equal(git(source, "add", ".").status, 0);
  assert.equal(
    git(source, "-c", "user.email=u1@test", "-c", "user.name=u1", "commit", "-qm", "v1").status, 0,
  );
  const manifest = join(root, "selection.json");
  writeFileSync(manifest, JSON.stringify({
    version: 1,
    policyVersion: 1,
    commit: git(source, "rev-parse", "HEAD").stdout.trim(),
    files: [{ path: "summa-gate/index.ts", sha256: sha(staged) }],
  }));
  linkSetup(state, outside);
  const run = () => spawnSync(
    process.execPath, [publishScript, manifest, stage, runtime, state, source, "--apply"],
    { encoding: "utf8" },
  );
  return { root, runtime, state, outside, sentinel, run };
}

function checkConfined(f, result, where) {
  const listing = JSON.stringify(readdirSync(f.outside).sort());
  const extra = ` rc=${result.status} fuera=${listing}`;
  assert.notEqual(result.status, 0, `apply con respaldo ${where} debe fallar cerrado.${extra}`);
  assert.match(result.stderr, /unsafe backup/, `stderr: ${result.stderr}`);
  assert.deepEqual(readdirSync(f.outside), ["sagrado.txt"], "nada se escribe fuera de la txn");
  assert.equal(
    readFileSync(join(f.outside, "sagrado.txt"), "utf8"), f.sentinel, "fuera queda intacto",
  );
  assert.equal(
    readFileSync(join(f.runtime, "summa-gate/index.ts"), "utf8"),
    "viejo\n",
    "el vivo no se toca cuando el respaldo es inseguro",
  );
}

test("B7: txn sin journal con backup symlinkeado falla cerrado sin escribir fuera", () => {
  const f = backupFixture((state, outside) => symlinkSync(outside, join(state, "backup")));
  checkConfined(f, f.run(), "symlinkeado");
});

test("B7: symlink en un intermedio del respaldo también falla cerrado", () => {
  const f = backupFixture((state, outside) => {
    mkdirSync(join(state, "backup"));
    symlinkSync(outside, join(state, "backup", "summa-gate"));
  });
  checkConfined(f, f.run(), "con intermedio symlinkeado");
});

test("B7 control: txn parcial legítima sin journal (respaldos reales) se recupera", () => {
  const root = mkdtempSync(join(tmpdir(), "u1-b7-"));
  const source = join(root, "source");
  const stage = join(root, "stage");
  const runtime = join(root, "runtime");
  const state = join(root, "state");
  mkdirSync(join(stage, "summa-gate"), { recursive: true });
  mkdirSync(join(source, "summa-gate"), { recursive: true });
  mkdirSync(join(runtime, "summa-gate"), { recursive: true });
  mkdirSync(state);
  const staged = "nuevo\n";
  writeFileSync(join(stage, "summa-gate/index.ts"), staged);
  writeFileSync(join(source, "summa-gate/index.ts"), staged);
  writeFileSync(join(runtime, "summa-gate/index.ts"), "viejo\n");
  assert.equal(git(source, "init", "-q").status, 0);
  assert.equal(git(source, "add", ".").status, 0);
  assert.equal(
    git(source, "-c", "user.email=u1@test", "-c", "user.name=u1", "commit", "-qm", "v1").status, 0,
  );
  const manifest = join(root, "selection.json");
  writeFileSync(manifest, JSON.stringify({
    version: 1,
    policyVersion: 1,
    commit: git(source, "rev-parse", "HEAD").stdout.trim(),
    files: [{ path: "summa-gate/index.ts", sha256: sha(staged) }],
  }));
  // Corte mkdir→journal con respaldo parcial real (no symlink): se recupera.
  const partial = join(state, "backup", "summa-gate", "index.ts");
  mkdirSync(dirname(partial), { recursive: true });
  writeFileSync(partial, "viejo\n");
  const result = spawnSync(
    process.execPath, [publishScript, manifest, stage, runtime, state, source, "--apply"],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(join(runtime, "summa-gate/index.ts"), "utf8"), staged);
  assert.equal(existsSync(join(state, "journal.json")), true);
});
