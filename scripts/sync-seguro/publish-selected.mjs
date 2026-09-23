import { createHash, randomBytes } from "node:crypto";
import {
  closeSync, existsSync, fsyncSync, lstatSync, mkdirSync,
  openSync, readFileSync, readdirSync, realpathSync, renameSync,
  rmdirSync, unlinkSync, writeSync,
} from "node:fs";
import { basename, dirname, join, resolve, sep } from "node:path";
import { POLICY_VERSION, selectionParts } from "./selection-policy.mjs";

const [manifestPath, stageArg, runtimeArg, transactionArg, mode] = process.argv.slice(2);
if (!manifestPath || !stageArg || !runtimeArg || !transactionArg || !["--apply", "--rollback"].includes(mode)) {
  process.stderr.write("usage: node publish-selected.mjs <selection.json> <stage> <runtime> <transaction> --apply|--rollback\n");
  process.exit(2);
}

const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
if (manifest.version !== 1 || manifest.policyVersion !== POLICY_VERSION ||
    !Array.isArray(manifest.files) || !manifest.files.length) {
  throw new Error("invalid selection manifest");
}
const files = manifest.files;
const byPath = new Map();
for (const file of files) {
  selectionParts(file.path);
  if (!/^[a-f0-9]{64}$/i.test(file.sha256) || byPath.has(file.path.toLowerCase())) {
    throw new Error("unsafe selection manifest");
  }
  byPath.set(file.path.toLowerCase(), file);
}

const stage = mode === "--apply" ? realpathSync(stageArg) : null;
const runtime = realpathSync(runtimeArg);
const transaction = resolve(transactionArg);
const transactionParent = realpathSync(dirname(transaction));
const txn = join(transactionParent, basename(transaction));
const norm = (path) => process.platform === "win32" ? path.toLowerCase() : path;
const inside = (a, b) => norm(a) === norm(b) || norm(a).startsWith(`${norm(b)}${sep}`);
const roots = stage ? [stage, runtime, txn] : [runtime, txn];
if (roots.some((root, i) => roots.some((other, j) => i !== j && inside(root, other)))) {
  throw new Error("transaction roots overlap");
}

function hash(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function pathFor(root, relative) {
  const target = join(root, ...relative.split("/"));
  if (!inside(target, root)) throw new Error("destination escapes root");
  return target;
}

function checkComponents(root, relative, requireFile = false) {
  let cursor = root;
  const parts = relative.split("/");
  for (let i = 0; i < parts.length; i += 1) {
    cursor = join(cursor, parts[i]);
    const stat = lstatSync(cursor, { throwIfNoEntry: false });
    if (!stat) {
      if (requireFile) throw new Error("selected file missing");
      continue;
    }
    if (stat.isSymbolicLink() || (i < parts.length - 1 && !stat.isDirectory()) ||
        (i === parts.length - 1 && !stat.isFile())) {
      throw new Error("unsafe selected path component");
    }
  }
  return cursor;
}

function allStageFiles(dir, prefix = "") {
  const found = [];
  for (const item of readdirSync(dir, { withFileTypes: true })) {
    if (item.isSymbolicLink()) throw new Error("symlink in stage");
    const rel = prefix ? `${prefix}/${item.name}` : item.name;
    if (item.isDirectory()) found.push(...allStageFiles(join(dir, item.name), rel));
    else if (item.isFile()) found.push(rel);
    else throw new Error("non-file in stage");
  }
  return found;
}

if (mode === "--apply") {
  if (JSON.stringify(allStageFiles(stage).sort()) !== JSON.stringify(files.map((f) => f.path).sort())) {
    throw new Error("stage file set differs from selection");
  }
  for (const file of files) {
    const staged = checkComponents(stage, file.path, true);
    if (hash(staged) !== file.sha256.toLowerCase()) throw new Error("stage hash differs");
    checkComponents(runtime, file.path);
  }
}

// Temporal seguro: nombre impredecible + creación O_EXCL, que falla con
// EEXIST si la ruta ya existe (incluido como symlink) en vez de seguirlo.
// Es el arreglo del bloqueante de PR #134 (temporal predecible + copyFileSync).
function writeTempExclusive(dir, prefix, bytes) {
  const name = `${prefix}.sync-tmp-${randomBytes(16).toString("hex")}`;
  const temp = join(dir, name);
  const fd = openSync(temp, "wx", 0o600);
  try {
    writeSync(fd, bytes);
    fsyncSync(fd);
  } catch (error) {
    try { closeSync(fd); } catch { /* keep original error */ }
    try { unlinkSync(temp); } catch { /* best effort single unlink */ }
    throw error;
  }
  closeSync(fd);
  return temp;
}

function syncFile(path) {
  const fd = openSync(path, "r+");
  try { fsyncSync(fd); } finally { closeSync(fd); }
}

function syncJsonAtomic(path, value) {
  const bytes = `${JSON.stringify(value, null, 2)}\n`;
  mkdirSync(dirname(path), { recursive: true });
  const temp = writeTempExclusive(dirname(path), basename(path), bytes);
  try {
    renameSync(temp, path);
  } catch (error) {
    try { unlinkSync(temp); } catch { /* best effort single unlink */ }
    throw error;
  }
  syncFile(path);
}

function syncJsonExclusive(path, value) {
  const fd = openSync(path, "wx");
  try {
    writeSync(fd, `${JSON.stringify(value, null, 2)}\n`);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}

function parentDirs(relative) {
  const dirs = [];
  let cursor = runtime;
  for (const part of relative.split("/").slice(0, -1)) {
    cursor = join(cursor, part);
    dirs.push(cursor);
  }
  return dirs;
}

// Registro de lo último instalado por este sync. Vive con el runtime (estado
// vivo, no publicado: la política prohíbe `.ledger`) y es lo que permite
// distinguir "contenido viejo pendiente de sync" de "edición viva pendiente".
const LEDGER_DIR = join(runtime, ".ledger");
const INSTALLED_PATH = join(LEDGER_DIR, "sync-seguro-installed.json");

// El ledger vive dentro del runtime: si .ledger existe debe ser un directorio
// real (lstat: un symlink a fuera no vale); si falta se crea. Falla cerrado
// antes de cualquier lectura o escritura del registro.
function ensureLedgerDir() {
  const stat = lstatSync(LEDGER_DIR, { throwIfNoEntry: false });
  if (!stat) {
    mkdirSync(LEDGER_DIR);
    return;
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    throw new Error(".ledger is not a real directory");
  }
}

function loadInstalled() {
  ensureLedgerDir();
  const stat = lstatSync(INSTALLED_PATH, { throwIfNoEntry: false });
  if (!stat) return new Map();
  if (!stat.isFile()) throw new Error("installed record is not a file");
  const data = JSON.parse(readFileSync(INSTALLED_PATH, "utf8"));
  if (data.version !== 1 || typeof data.files !== "object" || data.files === null) {
    throw new Error("installed record corrupt");
  }
  const map = new Map();
  for (const [key, sha] of Object.entries(data.files)) {
    if (typeof sha !== "string" || !/^[a-f0-9]{64}$/i.test(sha)) {
      throw new Error("installed record corrupt");
    }
    map.set(key.toLowerCase(), sha.toLowerCase());
  }
  return map;
}

function saveInstalled(map) {
  ensureLedgerDir();
  const data = {};
  for (const [key, sha] of [...map.entries()].sort()) data[key] = sha;
  syncJsonAtomic(INSTALLED_PATH, { version: 1, files: data });
}

function validateJournal(journal) {
  const expected = new Set(files.map((file) => file.path));
  const allowedDirs = new Set(files.flatMap((file) => {
    const parts = file.path.split("/").slice(0, -1);
    return parts.map((_, index) => parts.slice(0, index + 1).join("/"));
  }));
  if (journal.version !== 1 || !Array.isArray(journal.entries) ||
      journal.entries.some((entry) => !expected.has(entry.path) || !byPath.has(entry.path.toLowerCase()) ||
        entry.newSha !== byPath.get(entry.path.toLowerCase()).sha256.toLowerCase()) ||
      new Set(journal.entries.map((entry) => entry.path)).size !== journal.entries.length ||
      !Array.isArray(journal.createdDirs) ||
      journal.createdDirs.some((dir) => !allowedDirs.has(dir))) {
    throw new Error("transaction journal does not match selection");
  }
}

function restore(journal) {
  validateJournal(journal);
  // Todo destino se verifica antes de cambiar ninguno.
  for (const entry of journal.entries) {
    const target = checkComponents(runtime, entry.path);
    const current = existsSync(target) ? hash(target) : null;
    if (current !== entry.newSha && current !== entry.oldSha) {
      throw new Error("runtime changed after publication; rollback refused");
    }
    if (entry.oldSha) {
      const backup = checkComponents(txn, `backup/${entry.path}`, true);
      if (hash(backup) !== entry.oldSha) throw new Error("rollback backup hash differs");
    }
  }
  for (const entry of [...journal.entries].reverse()) {
    const target = pathFor(runtime, entry.path);
    const current = existsSync(target) ? hash(target) : null;
    if (current === entry.oldSha) continue;
    if (entry.oldSha) {
      const temp = writeTempExclusive(
        dirname(target), basename(target), readFileSync(pathFor(txn, `backup/${entry.path}`)),
      );
      try {
        if (hash(temp) !== entry.oldSha) throw new Error("rollback temp hash differs");
        if (lstatSync(target).isSymbolicLink()) throw new Error("unsafe selected path component");
        renameSync(temp, target);
      } finally {
        if (lstatSync(temp, { throwIfNoEntry: false })) unlinkSync(temp);
      }
      if (hash(target) !== entry.oldSha) throw new Error("rollback read-back hash differs");
    } else {
      const stat = lstatSync(target);
      if (!stat.isFile()) throw new Error("unsafe selected path component");
      unlinkSync(target);
    }
  }
  // rmdir de un solo nivel, solo directorios que este publish creó y solo si
  // quedaron vacíos. Nunca recursivo.
  for (const dir of [...new Set(journal.createdDirs)].reverse()) {
    try { rmdirSync(pathFor(runtime, dir)); } catch (error) {
      if (error.code !== "ENOTEMPTY" && error.code !== "ENOENT") throw error;
    }
  }
}

if (mode === "--rollback") {
  const journal = JSON.parse(readFileSync(join(txn, "journal.json"), "utf8"));
  restore(journal);
  const installed = loadInstalled();
  for (const entry of journal.entries) {
    const key = entry.path.toLowerCase();
    if (entry.oldSha) installed.set(key, entry.oldSha);
    else installed.delete(key);
  }
  saveInstalled(installed);
  process.stdout.write("selected publication rolled back\n");
  process.exit(0);
}

// --- apply ---
const installed = loadInstalled();
const skipped = [];
let adopted = false;
const changes = files.flatMap((file) => {
  const target = pathFor(runtime, file.path);
  const liveSha = existsSync(target) ? hash(target) : null;
  const newSha = file.sha256.toLowerCase();
  if (liveSha === newSha) {
    // Adopción: el vivo ya coincide con lo staged; se registra para que una
    // edición viva posterior se detecte en vez de sobrescribirse.
    const key = file.path.toLowerCase();
    if (installed.get(key) !== newSha) {
      installed.set(key, newSha);
      adopted = true;
    }
    return [];
  }
  // Edición viva pendiente: el archivo vivo difiere tanto de lo último
  // instalado como de lo staged. No se sobrescribe: se reporta y se sigue.
  // Sin registro previo no hay "último instalado" contra el cual comparar:
  // se publica (con respaldo previo, reversible por --rollback).
  const lastSha = installed.get(file.path.toLowerCase()) ?? null;
  if (liveSha !== null && lastSha !== null && liveSha !== lastSha && liveSha !== newSha) {
    skipped.push(file.path);
    return [];
  }
  return [{ path: file.path, oldSha: liveSha, newSha }];
});

if (!changes.length) {
  // La rama sin cambios también persiste: sin esto lo adoptado se perdería y
  // una edición viva posterior se sobrescribiría. En estado estable no hay
  // nada que adoptar y no se escribe (idempotencia medida).
  if (adopted) saveInstalled(installed);
  for (const path of skipped) process.stdout.write(`SKIPPED live-edit ${path}\n`);
  process.stdout.write(skipped.length
    ? `${files.length} selected files already published; ${skipped.length} live edits kept\n`
    : `${files.length} selected files already published\n`);
  process.exit(0);
}

// Transacción: directorio fresco, o reanudación de una interrumpida que pida
// exactamente lo mismo. Sin borrados: un resto ajeno se reporta, no se limpia.
let journal;
let completed = new Set();
let skipNow = new Set();
const existingTxn = lstatSync(txn, { throwIfNoEntry: false });
if (existingTxn) {
  if (!existingTxn.isDirectory()) throw new Error("transaction path already exists");
  const priorRaw = readFileSync(join(txn, "journal.json"), "utf8");
  const prior = JSON.parse(priorRaw);
  const shapeOk = prior && prior.version === 1 && Array.isArray(prior.entries) &&
    Array.isArray(prior.createdDirs) && prior.entries.every((e) => e &&
      typeof e.path === "string" && typeof e.newSha === "string" &&
      (e.oldSha === null || typeof e.oldSha === "string"));
  if (!shapeOk) throw new Error("prior transaction journal corrupt; move it aside first");
  // Reanudación: los cambios frescos deben ser un subconjunto idéntico de la
  // intención previa (lo demás ya quedó publicado), con los mismos skips.
  const subset = changes.every((c) => prior.entries.some((p) =>
    p.path === c.path && p.oldSha === c.oldSha && p.newSha === c.newSha)) &&
    JSON.stringify([...skipped].sort()) === JSON.stringify([...prior.skipped ?? []].sort());
  if (!subset) throw new Error("prior transaction pending; rollback or move it aside first");
  validateJournal(prior);
  journal = prior;
  // Reanudación desde la realidad verificada, no desde lo persistido: lo que
  // sigue en nuevo se salta (aunque el completed no se haya persistido antes
  // del kill); lo que volvió a viejo se reintenta; lo demás aborta.
  const freshPaths = new Set(changes.map((c) => c.path));
  skipNow = new Set(skipped.filter((s) => prior.entries.some((p) => p.path === s)));
  const resumed = new Set();
  for (const entry of journal.entries) {
    if (freshPaths.has(entry.path) || skipNow.has(entry.path)) continue;
    const live = hash(pathFor(runtime, entry.path));
    if (live === entry.newSha) resumed.add(entry.path);
    else {
      throw new Error("interrupted publication left inconsistent state; rollback first");
    }
  }
  completed = resumed;
  journal.completed = [...resumed];
  journal.resumedSkips = [...skipNow];
} else {
  mkdirSync(txn);
  const createdDirs = [];
  for (const entry of changes) {
    if (entry.oldSha) {
      const backup = pathFor(txn, `backup/${entry.path}`);
      mkdirSync(dirname(backup), { recursive: true });
      const bytes = readFileSync(pathFor(runtime, entry.path));
      const tmp = writeTempExclusive(dirname(backup), basename(backup), bytes);
      try {
        renameSync(tmp, backup);
      } finally {
        if (lstatSync(tmp, { throwIfNoEntry: false })) unlinkSync(tmp);
      }
      if (hash(backup) !== entry.oldSha) throw new Error("backup read-back hash differs");
      syncFile(backup);
    }
    for (const dir of parentDirs(entry.path)) {
      if (!lstatSync(dir, { throwIfNoEntry: false })) {
        const rel = dir.slice(runtime.length + 1).split(sep).join("/");
        if (!createdDirs.includes(rel)) createdDirs.push(rel);
      }
    }
  }
  journal = { version: 1, entries: changes, createdDirs, completed: [], skipped };
  syncJsonExclusive(join(txn, "journal.json"), journal);
}

const fault = process.env.SYNC_SEGURO_FAULT ?? "";

try {
  for (const [index, entry] of journal.entries.entries()) {
    if (completed.has(entry.path) || skipNow.has(entry.path)) continue;
    const target = pathFor(runtime, entry.path);
    const current = existsSync(target) ? hash(target) : null;
    if (current !== entry.oldSha) throw new Error("runtime changed during publication");
    mkdirSync(dirname(target), { recursive: true });
    const temp = writeTempExclusive(
      dirname(target), basename(target), readFileSync(pathFor(stage, entry.path)),
    );
    try {
      if (hash(temp) !== entry.newSha) throw new Error("temporary read-back hash differs");
      if (index === 0 && fault === "before-rename") {
        throw new Error("injected pre-rename publication fault");
      }
      const destStat = lstatSync(target, { throwIfNoEntry: false });
      if (destStat && destStat.isSymbolicLink()) throw new Error("unsafe selected path component");
      renameSync(temp, target);
    } finally {
      if (lstatSync(temp, { throwIfNoEntry: false })) unlinkSync(temp);
    }
    if (fault === "corrupt-readback") {
      const fd = openSync(target, "r+");
      try { writeSync(fd, "X"); fsyncSync(fd); } finally { closeSync(fd); }
    }
    if (hash(target) !== entry.newSha) throw new Error("published read-back hash differs");
    completed.add(entry.path);
    journal.completed = [...completed];
    syncJsonAtomic(join(txn, "journal.json"), journal);
    installed.set(entry.path.toLowerCase(), entry.newSha);
    saveInstalled(installed);
    if (index === 0 && fault === "after-first") {
      throw new Error("injected post-first publication fault");
    }
    if (index === 0 && fault === "kill-after-first") {
      // Simula SIGKILL: salida abrupta sin auto-restore ni limpieza. Solo pruebas.
      process.exit(7);
    }
  }
} catch (error) {
  try {
    restore(journal);
  } catch (restoreError) {
    error.message += ` (auto-restore failed: ${restoreError.message})`;
  }
  // El installed pudo adelantarse (se guarda por archivo): se converge hacia
  // la realidad verificada, solo donde el vivo está en su contenido previo.
  try {
    const reverted = loadInstalled();
    for (const entry of journal.entries) {
      const target = pathFor(runtime, entry.path);
      const live = existsSync(target) ? hash(target) : null;
      if (live !== entry.oldSha) continue;
      const key = entry.path.toLowerCase();
      if (entry.oldSha) reverted.set(key, entry.oldSha);
      else reverted.delete(key);
    }
    saveInstalled(reverted);
  } catch { /* restore already attempted; keep original error */ }
  throw error;
}

for (const path of skipped) process.stdout.write(`SKIPPED live-edit ${path}\n`);
process.stdout.write(`${journal.entries.length} selected files published; ` +
  `${skipped.length} live edits kept; rollback transaction retained\n`);
