import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import {
  existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";

// Bloqueante PR #134: el temporal predecible `<destino>.recovery-new-<pid>`
// se creaba con copyFileSync, que sigue symlinks. Un symlink plantado en esa
// ruta hacia fuera del runtime hacía que publish sobrescribiera el archivo de
// fuera y dejara el destino como symlink. El sync seguro usa temporal
// impredecible creado con O_EXCL, que nunca sigue un symlink plantado.
//
// SYNC_SEGURO_BIN permite correr esta misma prueba contra otra copia de los
// scripts (se usó para demostrar el rojo contra el código vulnerable de #134
// en /tmp, sin meter ese código al repo). Por defecto prueba el árbol.
//
const BIN = process.env.SYNC_SEGURO_BIN
  ? resolve(process.env.SYNC_SEGURO_BIN)
  : resolve("scripts/sync-seguro");
const publishScript = join(BIN, "publish-selected.mjs");

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "u1-symlink-temp-"));
  const source = join(root, "source");
  const stage = join(root, "stage");
  const runtime = join(root, "runtime");
  const state = join(root, "state");
  mkdirSync(join(stage, "summa-gate"), { recursive: true });
  mkdirSync(join(source, "summa-gate"), { recursive: true });
  mkdirSync(join(runtime, "summa-gate"), { recursive: true });
  // 1 MiB para que el hijo pase tiempo hasheando mientras plantamos el symlink.
  const staged = `nuevo-${"x".repeat(1024 * 1024)}\n`;
  writeFileSync(join(stage, "summa-gate", "index.ts"), staged);
  // C1: lo staged está commiteado en la fuente para pasar la proveniencia.
  writeFileSync(join(source, "summa-gate", "index.ts"), staged);
  const git = (...args) => spawnSync("git", args, { cwd: source, encoding: "utf8" });
  assert.equal(git("init", "-q").status, 0);
  assert.equal(git("add", ".").status, 0);
  assert.equal(
    git("-c", "user.email=u1@test", "-c", "user.name=u1", "commit", "-qm", "v1").status, 0,
  );
  const target = join(runtime, "summa-gate", "index.ts");
  writeFileSync(target, "viejo\n");
  const outside = join(root, "fuera.txt");
  const sentinel = "SECRETO-NO-TOCAR\n";
  writeFileSync(outside, sentinel);
  const manifest = join(root, "selection.json");
  writeFileSync(manifest, JSON.stringify({
    version: 1,
    policyVersion: 1,
    commit: git("rev-parse", "HEAD").stdout.trim(),
    files: [{
      path: "summa-gate/index.ts",
      sha256: createHash("sha256").update(staged).digest("hex"),
    }],
  }));
  return { root, manifest, source, stage, runtime, state, target, outside, sentinel, staged };
}

function runPublishSync(f) {
  return spawnSync(
    process.execPath,
    [publishScript, f.manifest, f.stage, f.runtime, f.state, f.source, "--apply"],
    { encoding: "utf8" },
  );
}

test("un symlink plantado en el temporal predecible no escribe fuera del runtime", async () => {
  const f = fixture();
  const child = spawn(
    process.execPath,
    [publishScript, f.manifest, f.stage, f.runtime, f.state, f.source, "--apply"],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  // El pid del hijo se conoce en cuanto spawn regresa; el hijo tarda decenas
  // de ms (arranque de node + validación + hash + journal) antes de tocar el
  // temporal, así que el symlink queda plantado a tiempo.
  const planted = `${f.target}.recovery-new-${child.pid}`;
  if (!existsSync(planted)) symlinkSync(f.outside, planted);
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (d) => { stdout += d; });
  child.stderr.on("data", (d) => { stderr += d; });
  const status = await new Promise((done) => child.on("close", done));
  assert.equal(status, 0, `publish salió ${status}: ${stderr}${stdout}`);
  assert.equal(
    readFileSync(f.outside, "utf8"), f.sentinel,
    "el archivo de fuera del runtime fue sobrescrito por el temporal",
  );
  assert.equal(
    lstatSync(f.target).isSymbolicLink(), false,
    "el destino quedó como symlink hacia fuera del runtime",
  );
  assert.equal(readFileSync(f.target, "utf8"), f.staged);
});

test("sin ataque, el apply publica y deja el destino como archivo regular", () => {
  const f = fixture();
  const r = runPublishSync(f);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(lstatSync(f.target).isSymbolicLink(), false);
  assert.equal(readFileSync(f.target, "utf8"), f.staged);
  assert.equal(readFileSync(f.outside, "utf8"), f.sentinel);
});
