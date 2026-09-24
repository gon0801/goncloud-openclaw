import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join, sep } from "node:path";
import { POLICY_VERSION, selectionParts } from "./selection-policy.mjs";

const [sourceArg, outputPath] = process.argv.slice(2);
if (!sourceArg || !outputPath) {
  process.stderr.write("usage: node build-selection.mjs <source-git-checkout> <selection.json>\n");
  process.exit(2);
}

const source = realpathSync(sourceArg);
if (source.split(sep).some((part) => part.toLowerCase() === ".openclaw")) {
  throw new Error("live runtime cannot be recovery source");
}

const listed = spawnSync("git", ["-C", source, "ls-files", "-z"], { encoding: "utf8" });
if (listed.status !== 0) throw new Error("cannot list tracked source files");

// B4: la selección se pinnea al HEAD commiteado. Sin commit no hay
// manifiesto (falla cerrado: un árbol solo stageado no es revisable).
const head = spawnSync("git", ["-C", source, "rev-parse", "HEAD"], { encoding: "utf8" });
if (head.status !== 0 || !/^[a-f0-9]{40}\n?$/.test(head.stdout)) {
  throw new Error("source has no commit; commit first");
}
const commit = head.stdout.trim();

function candidate(path) {
  if (path === "gateway-watchdog.ps1") return true;
  if (path.startsWith("summa-gate/") || path.startsWith("tablero-runbook/")) {
    if (path.endsWith(".test.ts") || path.includes("/fixtures/")) return false;
    if ([
      "summa-gate/backfill-rendiciones.mjs",
      "summa-gate/leer-rendiciones.mjs",
      "summa-gate/verify-corpus.mjs",
    ].includes(path)) return false;
    if (!path.endsWith(".ts") && !path.endsWith("/openclaw.plugin.json") && !path.endsWith("/package.json")) {
      throw new Error("unreviewed plugin file in tracked source");
    }
    return true;
  }
  if (path.startsWith("agents/") && path.includes("/agent/workshop-skills/")) {
    if (path.split("/").some((part) => part.startsWith(".backup-") || /\.bak(?:[-.]|$)/i.test(part))) return false;
    return true;
  }
  return false;
}

const files = listed.stdout.split("\0").filter(Boolean).filter(candidate).sort().map((path) => {
  const parts = selectionParts(path);
  let cursor = source;
  for (const part of parts) {
    cursor = join(cursor, part);
    if (lstatSync(cursor).isSymbolicLink()) throw new Error("symlink in tracked selection");
  }
  if (!lstatSync(cursor).isFile()) throw new Error("tracked selection is not a file");
  // B4: cada byte debe ser idéntico al del commit pinned; lo dirty o
  // stageado-sin-commit se rechaza, no se hashea.
  const bytes = readFileSync(cursor);
  // maxBuffer explícito: el de 1 MiB por defecto mataría al hijo (ENOBUFS,
  // status null) ante un blob grande y la proveniencia fallaría aunque el
  // byte esté commiteado. El pipeline ya lee archivos completos a memoria.
  const pinned = spawnSync("git", ["-C", source, "show", `${commit}:${path}`], {
    encoding: "buffer",
    maxBuffer: 64 * 1024 * 1024,
  });
  const pinnedSha = pinned.status === 0
    ? createHash("sha256").update(pinned.stdout).digest("hex") : null;
  const liveSha = createHash("sha256").update(bytes).digest("hex");
  if (pinnedSha === null || pinnedSha !== liveSha) {
    throw new Error(`tracked selection differs from pinned commit ${commit}: ${path}`);
  }
  return { path, sha256: liveSha };
});
if (!files.length) throw new Error("empty runtime selection");

const output = `${JSON.stringify({ version: 1, policyVersion: POLICY_VERSION, commit, files }, null, 2)}\n`;
if (existsSync(outputPath)) {
  if (readFileSync(outputPath, "utf8") !== output) throw new Error("existing selection differs");
} else {
  writeFileSync(outputPath, output, { flag: "wx" });
}
process.stdout.write(`${files.length} tracked runtime files selected\n`);
