import { createHash } from "node:crypto";
import {
  closeSync, copyFileSync, existsSync, fsyncSync, lstatSync, mkdirSync,
  openSync, readFileSync, readdirSync, realpathSync, renameSync, rmdirSync,
  unlinkSync, writeFileSync,
} from "node:fs";
import { basename, dirname, join, resolve, sep } from "node:path";
import { selectionParts } from "./selection-policy.mjs";

const [manifestPath, stageArg, runtimeArg, transactionArg, mode] = process.argv.slice(2);
if (!manifestPath || !stageArg || !runtimeArg || !transactionArg || !["--apply", "--rollback"].includes(mode)) {
  process.stderr.write("usage: node publish-selected.mjs <selection.json> <stage> <runtime> <transaction> --apply|--rollback\n");
  process.exit(2);
}

const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
if (manifest.version !== 1 || !Array.isArray(manifest.files) || !manifest.files.length) {
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
  return join(root, ...relative.split("/"));
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

function syncJson(path, value) {
  const fd = openSync(path, "wx");
  try {
    writeFileSync(fd, `${JSON.stringify(value, null, 2)}\n`);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}

function syncFile(path) {
  // Windows FlushFileBuffers requires a writable handle.
  const fd = openSync(path, "r+");
  try { fsyncSync(fd); } finally { closeSync(fd); }
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

function restore(journal) {
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
  // Check every destination before changing any of them.
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
      const temp = `${target}.recovery-rollback-${process.pid}`;
      try {
        copyFileSync(pathFor(txn, `backup/${entry.path}`), temp);
        renameSync(temp, target);
      } finally {
        if (lstatSync(temp, { throwIfNoEntry: false })) unlinkSync(temp);
      }
    } else {
      unlinkSync(target);
    }
  }
  for (const dir of [...new Set(journal.createdDirs)].reverse()) {
    try { rmdirSync(pathFor(runtime, dir)); } catch (error) {
      if (error.code !== "ENOTEMPTY" && error.code !== "ENOENT") throw error;
    }
  }
}

if (mode === "--rollback") {
  const journal = JSON.parse(readFileSync(join(txn, "journal.json"), "utf8"));
  restore(journal);
  process.stdout.write("selected publication rolled back\n");
  process.exit(0);
}

const changes = files.flatMap((file) => {
  const target = pathFor(runtime, file.path);
  const oldSha = existsSync(target) ? hash(target) : null;
  return oldSha === file.sha256.toLowerCase() ? [] : [{
    path: file.path, oldSha, newSha: file.sha256.toLowerCase(),
  }];
});
if (!changes.length) {
  process.stdout.write(`${files.length} selected files already published\n`);
  process.exit(0);
}
if (lstatSync(txn, { throwIfNoEntry: false })) throw new Error("transaction path already exists");
mkdirSync(txn);
const createdDirs = [];
for (const entry of changes) {
  if (entry.oldSha) {
    const backup = pathFor(txn, `backup/${entry.path}`);
    mkdirSync(dirname(backup), { recursive: true });
    copyFileSync(pathFor(runtime, entry.path), backup);
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
const journal = { version: 1, entries: changes, createdDirs };
syncJson(join(txn, "journal.json"), journal);

try {
  for (const [index, entry] of changes.entries()) {
    const target = pathFor(runtime, entry.path);
    const current = existsSync(target) ? hash(target) : null;
    if (current !== entry.oldSha) throw new Error("runtime changed during publication");
    mkdirSync(dirname(target), { recursive: true });
    const temp = `${target}.recovery-new-${process.pid}`;
    try {
      copyFileSync(pathFor(stage, entry.path), temp);
      if (hash(temp) !== entry.newSha) throw new Error("temporary read-back hash differs");
      if (index === 0 && process.env.RECOVERY_PUBLISH_FAULT === "before-rename") {
        throw new Error("injected pre-rename publication fault");
      }
      renameSync(temp, target);
    } finally {
      if (lstatSync(temp, { throwIfNoEntry: false })) unlinkSync(temp);
    }
    if (hash(target) !== entry.newSha) throw new Error("published read-back hash differs");
    if (index === 0 && process.env.RECOVERY_PUBLISH_FAULT === "after-first") {
      throw new Error("injected post-first publication fault");
    }
  }
} catch (error) {
  restore(journal);
  throw error;
}
process.stdout.write(`${changes.length} selected files published; rollback transaction retained\n`);
