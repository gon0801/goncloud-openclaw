import { readFileSync } from "node:fs";

const [manifestPath, configPath] = process.argv.slice(2);
if (!manifestPath || !configPath) {
  process.stderr.write("usage: node verify-models.mjs <manifest> <config>\n");
  process.exit(2);
}

function load(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

const manifest = load(manifestPath);
const config = load(configPath);
const entries = config.agents?.entries ?? {};
const issues = [];

function check(name, expected, actual) {
  if (!actual) {
    issues.push(`${name}: missing`);
    return;
  }
  const chain = [actual.model?.primary, ...(actual.model?.fallbacks ?? [])];
  if (JSON.stringify(chain) !== JSON.stringify(expected.chain)) {
    issues.push(`${name}: chain differs`);
  }
  for (const [model, thinking] of Object.entries(expected.thinking)) {
    if (actual.models?.[model]?.params?.thinking !== thinking) {
      issues.push(`${name}: thinking differs`);
      break;
    }
  }
}

for (const [id, expected] of Object.entries(manifest.agents)) {
  check(id, expected, entries[id]);
}
for (const id of Object.keys(entries)) {
  if (!Object.hasOwn(manifest.agents, id)) {
    issues.push(`${id}: unexpected agent`);
  }
}
check("defaults", manifest.agents[manifest.defaultsFrom], config.agents?.defaults);

if (issues.length) {
  process.stderr.write(`${issues.join("\n")}\n`);
  process.exit(1);
}
process.stdout.write(`${Object.keys(manifest.agents).length} agent chains match\n`);
