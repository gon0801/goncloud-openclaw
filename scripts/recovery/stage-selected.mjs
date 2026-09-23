import { createHash } from "node:crypto";
import {
  copyFileSync, lstatSync, mkdirSync, mkdtempSync, readFileSync,
  readdirSync, realpathSync, renameSync, rmSync,
} from "node:fs";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";

const [manifestPath, sourceArg, stageArg, flag] = process.argv.slice(2);
if (!manifestPath || !sourceArg || !stageArg || (flag && flag !== "--apply")) {
  process.stderr.write("usage: node stage-selected.mjs <selection.json> <source> <stage> [--apply]\n");
  process.exit(2);
}

const source = realpathSync(sourceArg);
if (source.split(sep).some((part) => part.toLowerCase() === ".openclaw")) {
  throw new Error("live runtime cannot be recovery source");
}
const stage = resolve(stageArg);
const parent = realpathSync(dirname(stage));
const actualStage = join(parent, basename(stage));
if (actualStage.split(sep).some((part) => part.toLowerCase() === ".openclaw")) {
  throw new Error("live runtime cannot be recovery stage");
}
const norm = (value) => process.platform === "win32" ? value.toLowerCase() : value;
const within = (child, root) => norm(child) === norm(root) || norm(child).startsWith(`${norm(root)}${sep}`);
if (within(actualStage, source) || within(source, actualStage)) {
  throw new Error("source and stage roots overlap");
}

const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
if (manifest.version !== 1 || !Array.isArray(manifest.files) || !manifest.files.length) {
  throw new Error("invalid selection manifest");
}

const forbidden = /^(?:\.git|credentials|sessions|logs|tools|models|cache|state|backups)$/i;
const forbiddenFile = /(?:^openclaw\.json(?:\..*)?$|\.env(?:\..*)?$|\.(?:sqlite(?:-wal|-shm)?|wal|shm|pem|key|pfx|p12|exe|dll|zip)(?:\..*)?$|\.bak(?:[-.].*)?$)/i;
const reserved = /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$/i;
const agentIds = new Set(["main", "operaciones", "ingenieria", "implementer", "reviewer", "adversary", "verifier", "scout"]);
const seen = new Set();

function safePath(path) {
  if (typeof path !== "string" || !path || isAbsolute(path) || path.includes("\\") || /[:\x00-\x1f\x7f]/.test(path)) {
    throw new Error("unsafe selection path");
  }
  const parts = path.split("/");
  if (parts.some((part) => !part || part === "." || part === ".." || reserved.test(part) || /[. ]$/.test(part) || forbidden.test(part) || forbiddenFile.test(part))) {
    throw new Error("unsafe selection path");
  }
  const plugin = ["summa-gate", "tablero-runbook"].includes(parts[0]) && parts.length > 1;
  const skill = parts[0] === "agents" && agentIds.has(parts[1]) && parts.length > 5 && parts[2] === "agent" && parts[3] === "workshop-skills";
  if (!plugin && !skill && path !== "gateway-watchdog.ps1") {
    throw new Error("path outside recovery allowlist");
  }
  return parts;
}

function hash(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

const files = manifest.files.map((entry) => {
  const parts = safePath(entry.path);
  if (!/^[a-f0-9]{64}$/i.test(entry.sha256)) {
    throw new Error("selection hash missing or invalid");
  }
  const key = entry.path.toLowerCase();
  if (seen.has(key)) {
    throw new Error("duplicate selection path");
  }
  seen.add(key);
  let cursor = source;
  for (const part of parts) {
    cursor = join(cursor, part);
    const stat = lstatSync(cursor);
    if (stat.isSymbolicLink()) {
      throw new Error("symlink in selected source");
    }
  }
  if (!lstatSync(cursor).isFile() || hash(cursor) !== entry.sha256.toLowerCase()) {
    throw new Error("selected source hash differs");
  }
  return { path: entry.path, sourcePath: cursor, sha256: entry.sha256.toLowerCase() };
});

function stageFiles(root) {
  const found = [];
  function visit(dir, prefix = "") {
    for (const item of readdirSync(dir, { withFileTypes: true })) {
      if (item.isSymbolicLink()) throw new Error("symlink in existing stage");
      const rel = prefix ? `${prefix}/${item.name}` : item.name;
      if (item.isDirectory()) visit(join(dir, item.name), rel);
      else if (item.isFile()) found.push(rel);
      else throw new Error("non-file in existing stage");
    }
  }
  visit(root);
  return found.sort();
}

const existing = lstatSync(actualStage, { throwIfNoEntry: false });
if (existing) {
  if (!existing.isDirectory()) throw new Error("stage exists but is not a directory");
  const expected = files.map((file) => file.path).sort();
  if (JSON.stringify(stageFiles(actualStage)) !== JSON.stringify(expected)) {
    throw new Error("existing stage file set differs");
  }
  for (const file of files) {
    if (hash(join(actualStage, ...file.path.split("/"))) !== file.sha256) {
      throw new Error("existing stage hash differs");
    }
  }
  process.stdout.write(`${files.length} selected files already staged\n`);
  process.exit(0);
}

if (flag !== "--apply") {
  process.stdout.write(`${files.length} selected files verified; no stage written\n`);
  process.exit(0);
}

const temp = mkdtempSync(join(parent, `${basename(stage)}.tmp-`));
try {
  for (const file of files) {
    const target = join(temp, ...file.path.split("/"));
    mkdirSync(dirname(target), { recursive: true });
    copyFileSync(file.sourcePath, target);
    if (hash(target) !== file.sha256) throw new Error("staged read-back hash differs");
  }
  if (lstatSync(actualStage, { throwIfNoEntry: false })) {
    throw new Error("stage appeared during copy");
  }
  renameSync(temp, actualStage);
} finally {
  if (lstatSync(temp, { throwIfNoEntry: false })) rmSync(temp, { recursive: true });
}
process.stdout.write(`${files.length} selected files staged\n`);
