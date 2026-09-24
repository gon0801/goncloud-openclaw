import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync,
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

// C1 (Codex): publish aceptaba un manifiesto y un staging hechos a mano sin
// comprobar el commit de origen: con un commit inexistente y hashes
// consistentes terminaba rc=0 e instalaba bytes jamás commiteados. Desde el
// fix, publish --apply exige la fuente git y re-valida cada byte contra
// `git show <commit>:<ruta>` antes de crear la transacción; --rollback no
// instala bytes staged y conserva sus 4 argumentos.

function sha(text) {
  return createHash("sha256").update(text).digest("hex");
}

function git(cwd, ...args) {
  return spawnSync("git", args, { cwd, encoding: "utf8" });
}

function gitSource(files) {
  const root = mkdtempSync(join(tmpdir(), "u1-c1-"));
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
  return { root, source, head: git(source, "rev-parse", "HEAD").stdout.trim() };
}

test("C1: publish directo con manifiesto+stage fabricados se rechaza; nada llega al vivo", () => {
  const root = mkdtempSync(join(tmpdir(), "u1-c1-"));
  const stage = join(root, "stage");
  const runtime = join(root, "runtime");
  const txn = join(root, "txn");
  mkdirSync(join(stage, "summa-gate"), { recursive: true });
  mkdirSync(runtime, { recursive: true });
  const bytes = "FABRICADO A MANO, JAMÁS COMMITEADO\n";
  writeFileSync(join(stage, "summa-gate", "evil.ts"), bytes);
  const manifest = join(root, "selection.json");
  writeFileSync(manifest, JSON.stringify({
    version: 1,
    policyVersion: 1,
    commit: "0".repeat(40),
    files: [{ path: "summa-gate/evil.ts", sha256: sha(bytes) }],
  }));
  const result = spawnSync(
    process.execPath, [publishScript, manifest, stage, runtime, txn, "--apply"],
    { encoding: "utf8" },
  );
  const target = join(runtime, "summa-gate", "evil.ts");
  const live = existsSync(target) ? readFileSync(target, "utf8") : "<ausente>";
  const extra = ` PUBLICÓ FABRICADO (rc=${result.status}, vivo=${JSON.stringify(live)})`;
  assert.notEqual(result.status, 0, `publish directo fabricado debe rechazarse.${extra}`);
  assert.equal(existsSync(target), false, "lo fabricado no llega al vivo");
});

test("C1: publish --apply rechaza un commit inexistente aunque el stage coincida", () => {
  const f = gitSource({ "summa-gate/index.ts": "v1 commiteado\n" });
  const stage = join(f.root, "stage");
  mkdirSync(join(stage, "summa-gate"), { recursive: true });
  writeFileSync(join(stage, "summa-gate", "index.ts"), "v1 commiteado\n");
  const runtime = join(f.root, "runtime");
  const txn = join(f.root, "txn");
  mkdirSync(runtime);
  const manifest = join(f.root, "selection.json");
  writeFileSync(manifest, JSON.stringify({
    version: 1,
    policyVersion: 1,
    commit: "f".repeat(40),
    files: [{ path: "summa-gate/index.ts", sha256: sha("v1 commiteado\n") }],
  }));
  const result = spawnSync(
    process.execPath, [publishScript, manifest, stage, runtime, txn, f.source, "--apply"],
    { encoding: "utf8" },
  );
  assert.notEqual(result.status, 0, "commit inexistente debe rechazarse");
  assert.match(result.stderr, /pinned commit/, `stderr: ${result.stderr}`);
  assert.equal(existsSync(join(runtime, "summa-gate", "index.ts")), false, "nada al vivo");
  assert.equal(existsSync(txn), false, "sin transacción ante proveniencia rota");
});

test("C1: publish --apply rechaza staged que difiere de lo commiteado", () => {
  const f = gitSource({ "summa-gate/index.ts": "v1 commiteado\n" });
  const stage = join(f.root, "stage");
  mkdirSync(join(stage, "summa-gate"), { recursive: true });
  writeFileSync(join(stage, "summa-gate", "index.ts"), "v2 solo en stage\n");
  const runtime = join(f.root, "runtime");
  const txn = join(f.root, "txn");
  mkdirSync(runtime);
  const manifest = join(f.root, "selection.json");
  writeFileSync(manifest, JSON.stringify({
    version: 1,
    policyVersion: 1,
    commit: f.head,
    files: [{ path: "summa-gate/index.ts", sha256: sha("v2 solo en stage\n") }],
  }));
  const result = spawnSync(
    process.execPath, [publishScript, manifest, stage, runtime, txn, f.source, "--apply"],
    { encoding: "utf8" },
  );
  assert.notEqual(result.status, 0, "staged fuera del commit debe rechazarse");
  assert.match(result.stderr, /differs from pinned commit/, `stderr: ${result.stderr}`);
  assert.equal(existsSync(join(runtime, "summa-gate", "index.ts")), false, "nada al vivo");
  assert.equal(existsSync(txn), false, "sin transacción ante proveniencia rota");
});

test("blob mayor a 1 MiB pasa build→stage→publish sin fingir proveniencia rota", () => {
  // El maxBuffer de 1 MiB por defecto de spawnSync mataba al `git show`
  // (ENOBUFS, status null) y la proveniencia fallaba aunque el byte estuviera
  // commiteado — a veces en verde por carrera, a veces en rojo. Los tres
  // gates (build, stage, publish) usan un tope explícito.
  const big = `grande-${"x".repeat(2 * 1024 * 1024)}\n`;
  const f = gitSource({ "summa-gate/big.ts": big });
  const manifest = join(f.root, "selection.json");
  const built = spawnSync(process.execPath, [buildScript, f.source, manifest], { encoding: "utf8" });
  assert.equal(built.status, 0, built.stderr);
  const stage = join(f.root, "stage");
  const staged = spawnSync(
    process.execPath, [stageScript, manifest, f.source, stage, "--apply"], { encoding: "utf8" },
  );
  assert.equal(staged.status, 0, staged.stderr);
  const runtime = join(f.root, "runtime");
  const txn = join(f.root, "txn");
  mkdirSync(runtime);
  const published = spawnSync(
    process.execPath, [publishScript, manifest, stage, runtime, txn, f.source, "--apply"],
    { encoding: "utf8" },
  );
  assert.equal(published.status, 0, published.stderr);
  assert.equal(readFileSync(join(runtime, "summa-gate", "big.ts"), "utf8"), big);
});

test("C1 control: build→stage→publish con fuente en verde; rollback conserva 4 args", () => {
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
  const txn = join(f.root, "txn");
  mkdirSync(runtime);
  const published = spawnSync(
    process.execPath, [publishScript, manifest, stage, runtime, txn, f.source, "--apply"],
    { encoding: "utf8" },
  );
  assert.equal(published.status, 0, published.stderr);
  assert.equal(readFileSync(join(runtime, "summa-gate", "index.ts"), "utf8"), "a commiteado\n");
  assert.equal(readFileSync(join(runtime, "tablero-runbook", "index.ts"), "utf8"), "b commiteado\n");
  const rollback = spawnSync(
    process.execPath, [publishScript, manifest, stage, runtime, txn, "--rollback"],
    { encoding: "utf8" },
  );
  assert.equal(rollback.status, 0, rollback.stderr);
  assert.equal(existsSync(join(runtime, "summa-gate", "index.ts")), false);
});
