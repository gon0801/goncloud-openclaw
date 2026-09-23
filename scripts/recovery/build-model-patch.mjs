import { existsSync, readFileSync, writeFileSync } from "node:fs";

const requiredAgents = [
  "main",
  "operaciones",
  "ingenieria",
  "implementer",
  "reviewer",
  "adversary",
  "verifier",
  "scout",
];

function modelPolicy(agent, id) {
  if (new Set(agent.chain).size !== agent.chain.length) {
    throw new Error(`duplicate model in ${id}`);
  }
  if (Object.keys(agent.thinking).some((model) => !agent.chain.includes(model))) {
    throw new Error(`thinking model outside chain in ${id}`);
  }
  const [primary, ...fallbacks] = agent.chain;
  const models = Object.fromEntries(
    Object.entries(agent.thinking).map(([id, thinking]) => [
      id,
      { params: { thinking } },
    ]),
  );
  return { model: { primary, fallbacks }, models };
}

const manifest = JSON.parse(readFileSync(process.argv[2], "utf8"));
const unexpected = Object.keys(manifest.agents).find(
  (id) => !requiredAgents.includes(id),
);
if (unexpected) {
  throw new Error(`unexpected agent: ${unexpected}`);
}
const entries = Object.fromEntries(
  requiredAgents.map((id) => [id, modelPolicy(manifest.agents[id], id)]),
);
const defaults = modelPolicy(manifest.agents[manifest.defaultsFrom], "defaults");
const patch = `${JSON.stringify({ agents: { defaults, entries } }, null, 2)}\n`;
const outputPath = process.argv[3];
if (outputPath) {
  if (existsSync(outputPath)) {
    if (readFileSync(outputPath, "utf8") !== patch) {
      throw new Error("existing patch differs");
    }
  } else {
    writeFileSync(outputPath, patch, { flag: "wx" });
  }
} else {
  process.stdout.write(patch);
}
