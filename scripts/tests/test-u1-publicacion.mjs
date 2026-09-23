import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync,
  readdirSync, statSync, symlinkSync, utimesSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";

const BIN = process.env.SYNC_SEGURO_BIN
  ? resolve(process.env.SYNC_SEGURO_BIN)
  : resolve("scripts/sync-seguro");
const stageScript = join(BIN, "stage-selected.mjs");
const publishScript = join(BIN, "publish-selected.mjs");

function sha(text) {
  return createHash("sha256").update(text).digest("hex");
}

function fixture(paths = ["summa-gate/index.ts", "tablero-runbook/index.ts"]) {
  const root = mkdtempSync(join(tmpdir(), "u1-publicacion-"));
  const source = join(root, "source");
  const stage = join(root, "stage");
  const runtime = join(root, "runtime");
  const state = join(root, "state");
  mkdirSync(source);
  mkdirSync(runtime);
  const files = paths.map((path, i) => {
    const target = join(source, path);
    mkdirSync(dirname(target), { recursive: true });
    const content = `nuevo ${i}\n`;
    writeFileSync(target, content);
    return { path, sha256: sha(content) };
  });
  const manifest = join(root, "selection.json");
  writeFileSync(manifest, JSON.stringify({ version: 1, policyVersion: 1, files }));
  const staged = spawnSync(process.execPath, [stageScript, manifest, source, stage, "--apply"], {
    encoding: "utf8",
  });
  assert.equal(staged.status, 0, staged.stderr);
  const run = (mode, env = {}) => spawnSync(
    process.execPath, [publishScript, manifest, stage, runtime, state, mode],
    { encoding: "utf8", env: { ...process.env, ...env } },
  );
  const runWith = (manifestPath, mode, env = {}) => spawnSync(
    process.execPath, [publishScript, manifestPath, stage, runtime, state, mode],
    { encoding: "utf8", env: { ...process.env, ...env } },
  );
  return { root, source, stage, runtime, state, manifest, files, run, runWith };
}

function snapshotMtimes(root) {
  const out = new Map();
  const visit = (dir) => {
    for (const name of readdirSync(dir)) {
      const full = join(dir, name);
      const st = lstatSync(full);
      out.set(full, [st.mtimeMs, st.size, st.isDirectory() ? "d" : "f"]);
      if (st.isDirectory() && !st.isSymbolicLink()) visit(full);
    }
  };
  visit(root);
  return out;
}

function freezeMtimes(root, date) {
  const visit = (dir) => {
    for (const name of readdirSync(dir)) {
      const full = join(dir, name);
      const st = lstatSync(full);
      if (st.isDirectory() && !st.isSymbolicLink()) visit(full);
      if (!st.isSymbolicLink()) utimesSync(full, date, date);
    }
  };
  visit(root);
}

test("publica, crea journal+respaldo, y el rollback restaura bytes previos", () => {
  const f = fixture();
  const existing = join(f.runtime, f.files[0].path);
  mkdirSync(dirname(existing), { recursive: true });
  writeFileSync(existing, "viejo\n");
  const first = f.run("--apply");
  assert.equal(first.status, 0, first.stderr);
  assert.equal(readFileSync(existing, "utf8"), "nuevo 0\n");
  assert.equal(readFileSync(join(f.runtime, f.files[1].path), "utf8"), "nuevo 1\n");
  const journalPath = join(f.state, "journal.json");
  assert.equal(existsSync(journalPath), true);
  const journal = JSON.parse(readFileSync(journalPath, "utf8"));
  assert.equal(journal.entries.length, 2);
  assert.equal(
    readFileSync(join(f.state, "backup", f.files[0].path), "utf8"), "viejo\n",
  );

  const rollback = f.run("--rollback");
  assert.equal(rollback.status, 0, rollback.stderr);
  assert.equal(readFileSync(existing, "utf8"), "viejo\n");
  assert.equal(existsSync(join(f.runtime, f.files[1].path)), false);
  assert.equal(f.run("--rollback").status, 0);
});

test("segundo ciclo sin cambios = cero escrituras (idempotencia medida)", () => {
  const f = fixture();
  assert.equal(f.run("--apply").status, 0);
  const old = new Date("2020-01-01T00:00:00Z");
  freezeMtimes(f.runtime, old);
  freezeMtimes(f.state, old);
  const beforeRuntime = snapshotMtimes(f.runtime);
  const beforeState = snapshotMtimes(f.state);
  const second = f.run("--apply");
  assert.equal(second.status, 0, second.stderr);
  assert.match(second.stdout, /already published/);
  assert.deepEqual(snapshotMtimes(f.runtime), beforeRuntime);
  assert.deepEqual(snapshotMtimes(f.state), beforeState);
  // Cinturón y tirantes: ningún mtime se movió del 2020.
  for (const [, [mtime]] of snapshotMtimes(f.runtime)) {
    assert.equal(mtime, old.getTime());
  }
});

test("falla tras el primer archivo revierte solo y la re-corrida completa", () => {
  const f = fixture();
  const existing = join(f.runtime, f.files[0].path);
  mkdirSync(dirname(existing), { recursive: true });
  writeFileSync(existing, "viejo\n");
  const failed = f.run("--apply", { SYNC_SEGURO_FAULT: "after-first" });
  assert.notEqual(failed.status, 0);
  assert.equal(readFileSync(existing, "utf8"), "viejo\n");
  assert.equal(existsSync(join(f.runtime, f.files[1].path)), false);
  const retry = f.run("--apply");
  assert.equal(retry.status, 0, retry.stderr);
  assert.equal(readFileSync(existing, "utf8"), "nuevo 0\n");
  assert.equal(readFileSync(join(f.runtime, f.files[1].path), "utf8"), "nuevo 1\n");
});

test("kill simulado deja mitad publicado y la re-corrida reanuda sin corromper", () => {
  const f = fixture();
  const killed = f.run("--apply", { SYNC_SEGURO_FAULT: "kill-after-first" });
  assert.equal(killed.status, 7);
  assert.equal(readFileSync(join(f.runtime, f.files[0].path), "utf8"), "nuevo 0\n");
  assert.equal(existsSync(join(f.runtime, f.files[1].path)), false);
  const retry = f.run("--apply");
  assert.equal(retry.status, 0, retry.stderr);
  assert.equal(readFileSync(join(f.runtime, f.files[0].path), "utf8"), "nuevo 0\n");
  assert.equal(readFileSync(join(f.runtime, f.files[1].path), "utf8"), "nuevo 1\n");
  assert.equal(
    sha(readFileSync(join(f.runtime, f.files[0].path), "utf8")), f.files[0].sha256,
  );
});

test("falla antes del rename no deja temporal ni cambio en el runtime", () => {
  const f = fixture();
  const failed = f.run("--apply", { SYNC_SEGURO_FAULT: "before-rename" });
  assert.notEqual(failed.status, 0);
  assert.equal(existsSync(join(f.runtime, f.files[0].path)), false);
  assert.equal(existsSync(join(f.runtime, "summa-gate")), false);
});

test("edición viva pendiente se conserva: se reporta y se sigue con el resto", () => {
  const f = fixture();
  assert.equal(f.run("--apply").status, 0);
  // Nueva versión staged para ambos archivos.
  const v2 = f.files.map((entry, i) => {
    const content = `nuevo v2 ${i}\n`;
    writeFileSync(join(f.stage, entry.path), content);
    return { path: entry.path, sha256: sha(content) };
  });
  const manifest2 = join(f.root, "selection2.json");
  writeFileSync(manifest2, JSON.stringify({ version: 1, policyVersion: 1, files: v2 }));
  // Pero el vivo del primero cambió por fuera (difiere del instalado y del staged).
  const live0 = join(f.runtime, f.files[0].path);
  writeFileSync(live0, "edición del operador\n");
  const state2 = join(f.root, "state2");
  const second = spawnSync(
    process.execPath, [publishScript, manifest2, f.stage, f.runtime, state2, "--apply"],
    { encoding: "utf8" },
  );
  assert.equal(second.status, 0, second.stderr);
  assert.match(second.stdout, new RegExp(`SKIPPED live-edit ${f.files[0].path}`));
  assert.equal(readFileSync(live0, "utf8"), "edición del operador\n");
  assert.equal(readFileSync(join(f.runtime, f.files[1].path), "utf8"), "nuevo v2 1\n");
  // El rollback del segundo ciclo restaura lo publicado y respeta la edición.
  const rollback = spawnSync(
    process.execPath, [publishScript, manifest2, f.stage, f.runtime, state2, "--rollback"],
    { encoding: "utf8" },
  );
  assert.equal(rollback.status, 0, rollback.stderr);
  assert.equal(readFileSync(join(f.runtime, f.files[1].path), "utf8"), "nuevo 1\n");
  assert.equal(readFileSync(live0, "utf8"), "edición del operador\n");
});

test("read-back: si lo instalado no coincide, falla fuerte y es recuperable", () => {
  const f = fixture();
  const existing = join(f.runtime, f.files[0].path);
  mkdirSync(dirname(existing), { recursive: true });
  writeFileSync(existing, "viejo\n");
  const failed = f.run("--apply", { SYNC_SEGURO_FAULT: "corrupt-readback" });
  assert.notEqual(failed.status, 0);
  assert.match(failed.stderr, /read-back/);
  // Estado: el primer archivo quedó tocado por la falla inyectada; el operador
  // lo repara a su contenido previo y el rollback cierra el ciclo.
  writeFileSync(existing, "viejo\n");
  const rollback = f.run("--rollback");
  assert.equal(rollback.status, 0, rollback.stderr);
  assert.equal(readFileSync(existing, "utf8"), "viejo\n");
  assert.equal(existsSync(join(f.runtime, f.files[1].path)), false);
});

test("rollback se niega ante una edición posterior a la publicación", () => {
  const f = fixture();
  assert.equal(f.run("--apply").status, 0);
  const target = join(f.runtime, f.files[0].path);
  writeFileSync(target, "cambio ajeno posterior");
  const result = f.run("--rollback");
  assert.notEqual(result.status, 0);
  assert.equal(readFileSync(target, "utf8"), "cambio ajeno posterior");
});

test("rollback rechaza un journal con directorios fuera de la selección", () => {
  const f = fixture();
  assert.equal(f.run("--apply").status, 0);
  const journalPath = join(f.state, "journal.json");
  const journal = JSON.parse(readFileSync(journalPath, "utf8"));
  journal.createdDirs = ["."];
  writeFileSync(journalPath, JSON.stringify(journal));
  const result = f.run("--rollback");
  assert.notEqual(result.status, 0);
  assert.equal(readFileSync(join(f.runtime, f.files[0].path), "utf8"), "nuevo 0\n");
});

test("una transacción previa distinta aborta en vez de mezclarse", () => {
  const f = fixture();
  assert.equal(f.run("--apply").status, 0);
  // Nuevo staged/manifiesto contra la MISMA transacción: no coincide.
  const v2 = f.files.map((entry) => {
    const content = `otra versión ${entry.path}\n`;
    writeFileSync(join(f.stage, entry.path), content);
    return { path: entry.path, sha256: sha(content) };
  });
  const manifest2 = join(f.root, "selection2.json");
  writeFileSync(manifest2, JSON.stringify({ version: 1, policyVersion: 1, files: v2 }));
  const again = f.runWith(manifest2, "--apply");
  assert.notEqual(again.status, 0);
  assert.match(again.stderr, /prior transaction pending/);
  assert.equal(statSync(join(f.runtime, f.files[0].path)).size, "nuevo 0\n".length);
});

test("ya-publicado se adopta: v1 presente → edición viva → v2 la conserva (B2)", () => {
  const f = fixture();
  // El vivo ya trae los bytes v1 pero el ledger no los registra.
  for (const [i, entry] of f.files.entries()) {
    const target = join(f.runtime, entry.path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, `nuevo ${i}\n`);
  }
  const first = f.run("--apply");
  assert.equal(first.status, 0, first.stderr);
  assert.match(first.stdout, /already published/);
  // La rama sin cambios adopta: el ledger registra lo ya coincidente.
  const ledgerPath = join(f.runtime, ".ledger", "sync-seguro-installed.json");
  assert.equal(existsSync(ledgerPath), true, "la adopción debe registrar el ledger");
  const ledger = JSON.parse(readFileSync(ledgerPath, "utf8"));
  for (const entry of f.files) {
    assert.equal(ledger.files[entry.path.toLowerCase()], entry.sha256);
  }
  // El operador edita el vivo; publish v2 debe conservar la edición.
  const live0 = join(f.runtime, f.files[0].path);
  writeFileSync(live0, "edición del operador\n");
  const v2 = f.files.map((entry, i) => {
    const content = `nuevo v2 ${i}\n`;
    writeFileSync(join(f.stage, entry.path), content);
    return { path: entry.path, sha256: sha(content) };
  });
  const manifest2 = join(f.root, "selection2.json");
  writeFileSync(manifest2, JSON.stringify({ version: 1, policyVersion: 1, files: v2 }));
  const state2 = join(f.root, "state2");
  const second = spawnSync(
    process.execPath, [publishScript, manifest2, f.stage, f.runtime, state2, "--apply"],
    { encoding: "utf8" },
  );
  assert.equal(second.status, 0, second.stderr);
  assert.match(second.stdout, new RegExp(`SKIPPED live-edit ${f.files[0].path}`));
  assert.equal(readFileSync(live0, "utf8"), "edición del operador\n");
  assert.equal(readFileSync(join(f.runtime, f.files[1].path), "utf8"), "nuevo v2 1\n");
});

test(".ledger symlinkeado a fuera: apply falla cerrado sin escribir fuera (B3)", () => {
  const f = fixture();
  const outside = mkdtempSync(join(tmpdir(), "u1-b3-fuera-"));
  symlinkSync(outside, join(f.runtime, ".ledger"));
  const result = f.run("--apply");
  assert.notEqual(result.status, 0, `apply debió fallar cerrado, stdout: ${result.stdout}`);
  assert.deepEqual(readdirSync(outside), [], "nada del ledger debe salir del runtime");
});
