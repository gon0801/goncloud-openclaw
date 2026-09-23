import { readFileSync } from "node:fs";

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
const entries = Object.fromEntries(
  requiredAgents.map((id) => [id, modelPolicy(manifest.agents[id], id)]),
);
const defaults = modelPolicy(manifest.agents[manifest.defaultsFrom], "defaults");
process.stdout.write(`${JSON.stringify({ agents: { defaults, entries } }, null, 2)}\n`);
