import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  lstatSync, mkdirSync, mkdtempSync, readFileSync,
  readdirSync, realpathSync, renameSync, writeFileSync,
} from "node:fs";
import { basename, dirname, join, resolve, sep } from "node:path";
import { POLICY_VERSION, canonicalEolBytes, selectionParts } from "./selection-policy.mjs";

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
if (manifest.version !== 1 || manifest.policyVersion !== POLICY_VERSION ||
    !Array.isArray(manifest.files) || !manifest.files.length) {
  throw new Error("invalid selection manifest");
}

const seen = new Set();

function hash(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

const files = manifest.files.map((entry) => {
  const parts = selectionParts(entry.path);
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
  if (!lstatSync(cursor).isFile()) {
    throw new Error("selected source hash differs");
  }
  // B6: proveniencia de principio a fin. El hash contra el vivo no basta: un
  // manifiesto preparado a mano (commit declarado + bytes sin commitear)
  // pasaba stage y publish. Cada byte debe ser idéntico al del commit que el
  // manifiesto declara, leído de la fuente git — igual que en build.
  if (!/^[a-f0-9]{40}$/i.test(manifest.commit ?? "")) {
    throw new Error("selection commit missing or invalid");
  }
  // maxBuffer explícito: el de 1 MiB por defecto mataría al hijo (ENOBUFS,
  // status null) ante un blob grande y la proveniencia fallaría aunque el
  // byte esté commiteado. El pipeline ya lee archivos completos a memoria.
  const pinned = spawnSync("git", ["-C", source, "show", `${manifest.commit}:${entry.path}`], {
    encoding: "buffer",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (pinned.status !== 0) {
    throw new Error(`selected source missing from pinned commit ${manifest.commit}: ${entry.path}`);
  }
  const pinnedSha = createHash("sha256").update(pinned.stdout).digest("hex");
  if (pinnedSha !== entry.sha256.toLowerCase()) {
    throw new Error(`selected source differs from pinned commit ${manifest.commit}: ${entry.path}`);
  }
  // D1: el vivo puede traer CRLF del checkout (core.autocrlf=true); la
  // identidad se decide en bytes canónicos contra el blob pinneado, igual
  // que en build. Lo que se stagea son los bytes del blob, no los del vivo.
  const liveCanon = createHash("sha256").update(canonicalEolBytes(readFileSync(cursor))).digest("hex");
  const pinnedCanon = createHash("sha256").update(canonicalEolBytes(pinned.stdout)).digest("hex");
  if (liveCanon !== pinnedCanon) {
    throw new Error(`selected source differs from pinned commit ${manifest.commit}: ${entry.path}`);
  }
  return { path: entry.path, sha256: entry.sha256.toLowerCase(), blob: pinned.stdout };
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
    writeFileSync(target, file.blob);
    if (hash(target) !== file.sha256) throw new Error("staged read-back hash differs");
  }
  if (lstatSync(actualStage, { throwIfNoEntry: false })) {
    throw new Error("stage appeared during copy");
  }
  renameSync(temp, actualStage);
} catch (error) {
  // Sin borrados recursivos (política U1): el temporal huérfano se queda para
  // inspección y se reporta su ruta en vez de limpiarse solo.
  process.stderr.write(`stage failed; orphan temp left for inspection: ${temp}\n`);
  throw error;
}
process.stdout.write(`${files.length} selected files staged\n`);
