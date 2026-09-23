import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { selectionParts } from "./selection-policy.mjs";

const [sourceArg, outputPath] = process.argv.slice(2);
if (!sourceArg || !outputPath) {
  process.stderr.write("usage: node build-selection.mjs <source-git-checkout> <selection.json>\n");
  process.exit(2);
}

const source = realpathSync(sourceArg);
const listed = spawnSync("git", ["-C", source, "ls-files", "-z"], { encoding: "utf8" });
if (listed.status !== 0) throw new Error("cannot list tracked source files");

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
  return { path, sha256: createHash("sha256").update(readFileSync(cursor)).digest("hex") };
});
if (!files.length) throw new Error("empty runtime selection");

const output = `${JSON.stringify({ version: 1, files }, null, 2)}\n`;
if (existsSync(outputPath)) {
  if (readFileSync(outputPath, "utf8") !== output) throw new Error("existing selection differs");
} else {
  writeFileSync(outputPath, output, { flag: "wx" });
}
process.stdout.write(`${files.length} tracked runtime files selected\n`);
