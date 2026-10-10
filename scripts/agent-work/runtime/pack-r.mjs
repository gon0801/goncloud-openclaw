import { execFileSync } from "node:child_process";
import { copyFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [sourceDir, outputDir, skipCompat] = process.argv.slice(2);
const { prepareNpmPackageBundle } = await import(
  pathToFileURL(join(sourceDir, "scripts/npm-prepared-bundle.mjs")).href
);
const sha = execFileSync("git", ["-C", sourceDir, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const tsx = (cwd, script, args = []) =>
  execFileSync(process.execPath, ["--import", join(sourceDir, "scripts/tsx.mjs"), script, ...args], {
    cwd,
    stdio: "inherit",
  });

const options = {
  sourceDir,
  outputDir,
  releaseRef: sha,
  npmDistTag: "local",
  producer: { local: true, note: "prepareNpmPackageBundle outside GitHub Actions; not publishable" },
};

if (skipCompat === "--skip-update-compat-check") {
  const shim = join(sourceDir, ".t11-prepack-no-compat.mts");
  options.runRootPack = (directory, destination) => {
    const env = { ...process.env, OPENCLAW_PREPACK_PREPARED: "1", OPENCLAW_PREPACK_ALLOW_UNRELEASED_CHANGELOG: "1" };
    copyFileSync(new URL("./prepack-no-compat.mts", import.meta.url), shim);
    try {
      execFileSync(process.execPath, ["--import", "./scripts/tsx.mjs", shim], { cwd: directory, env, stdio: "inherit" });
    } finally {
      rmSync(shim, { force: true });
    }
    try {
      tsx(sourceDir, join(sourceDir, "scripts/lib/sanitize-bundler-helper-dts-exports.mts"), [join(directory, "dist")]);
      tsx(directory, join(sourceDir, "scripts/write-package-dist-inventory.ts"));
      execFileSync(
        "pnpm",
        ["pack", "--config.ignore-scripts=true", "--config.node-linker=hoisted", "--pack-destination", destination],
        { cwd: directory, env, stdio: "inherit", timeout: 30 * 60 * 1000 },
      );
    } finally {
      execFileSync("pnpm", ["run", "--if-present", "postpack"], { cwd: directory, env, stdio: "inherit" });
    }
  };
}

console.log(JSON.stringify(prepareNpmPackageBundle(options), null, 2));
