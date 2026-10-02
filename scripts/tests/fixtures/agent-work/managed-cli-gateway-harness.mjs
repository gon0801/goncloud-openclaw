#!/usr/bin/env node

// A source-backed, isolated R Gateway with one certified fixture host. The
// Python test drives native requester tools and G's real CLI transport.
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";
import { pathToFileURL } from "node:url";

const root = process.env.AGENT_WORK_RUNTIME_SOURCE;
const stateDir = process.env.OPENCLAW_STATE_DIR;
const token = process.env.CROSS_GATEWAY_TOKEN;
if (!root || !stateDir || !token) {
  throw new Error("AGENT_WORK_RUNTIME_SOURCE, OPENCLAW_STATE_DIR, and CROSS_GATEWAY_TOKEN are required");
}
const load = (relative) => import(pathToFileURL(path.join(root, relative)).href);
const [gateway, identity, sessions, toolModule, callerModule, artifactModule] = await Promise.all([
  load("src/gateway/test-helpers.e2e.ts"),
  load("src/infra/device-identity.ts"),
  load("src/config/sessions/session-accessor.ts"),
  load("src/agents/tools/managed-tasks-tool.ts"),
  load("src/agents/tools/gateway-caller-context.ts"),
  load("src/agents/tasks/managed-task.artifact.ts"),
]);

await fs.mkdir(stateDir, { recursive: true });
const deviceIdentity = identity.loadOrCreateDeviceIdentity();
const sessionKey = "agent:ingenieria:main";
const sessionId = "cross-cli-session";
const storePath = path.join(stateDir, "sessions.json");
await sessions.upsertSessionEntryCore(
  { agentId: "ingenieria", sessionKey, storePath },
  { sessionId, updatedAt: Date.now() },
);
const profile = {
  maxConcurrentTasks: 2, maxDepth: 2, maxChildren: 2, maxModelCalls: 2,
  maxInputTokens: 1000, maxOutputTokens: 1000, maxCacheReadTokens: 1000,
  maxContextTokens: 1000, maxTreeTokens: 2000, maxAutomaticRecoveryCalls: 1,
};
const port = await gateway.getGatewayE2ePortBlock();
const config = {
  gateway: { mode: "local", bind: "loopback", port },
  channels: {}, cron: { enabled: false }, plugins: { enabled: false },
  session: { store: storePath }, agents: { list: [{ id: "ingenieria" }] },
  managedTasks: {
    enabled: true, instructionRoot: stateDir, runTimeoutSeconds: 60, profile,
    hosts: { "e2e-host": { deviceId: deviceIdentity.deviceId, adapters: ["codex"] } },
  },
};
const { client, server } = await gateway.startGatewayWithClient({
  cfg: config, configPath: path.join(stateDir, "openclaw.json"), token, port,
  scopes: ["operator.admin"], deviceIdentity,
});
await server.startupSettled;
process.stdout.write(`${JSON.stringify({ type: "ready", url: `ws://127.0.0.1:${port}` })}\n`);

async function runTool(command) {
  const name = `managed_tasks_${command.action}`;
  const runId = command.runId;
  if (!runId || !["submit", "admit", "inspect", "resolve"].includes(command.action)) {
    throw new Error("invalid requester tool command");
  }
  const bytes = Buffer.from("Review the fixture change and return one verdict.\n");
  const expectedDigest = createHash("sha256").update(bytes).digest("hex");
  const tools = toolModule.createManagedTaskTools({
    source: {
      agentId: "ingenieria", sessionKey, sessionId, runId,
      senderId: "fixture-person", channel: "discord", accountId: "fixture-team",
    },
    profile, config, spawnContext: {}, runTimeoutSeconds: 60,
    resolveInstructionRef: async (ref) => {
      if (ref === "artifact:fixture-source") return bytes;
      if (ref === `artifact:${expectedDigest}`) return artifactModule.readManagedTaskArtifact(ref);
      throw new Error("unrecognized fixture instruction reference");
    },
  });
  const tool = tools.find((entry) => entry.name === name);
  if (!tool) throw new Error("native requester tool missing");
  const result = await callerModule.withGatewayToolCallerIdentity(
    {
      agentId: "ingenieria", sessionKey,
      operationalRunInstance: { instanceId: runId, runId },
      receiptAuthority: () => true,
    },
    () => tool.execute(`cross-${command.action}`, command.args),
  );
  return result.details;
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of input) {
  if (!line.trim()) continue;
  const command = JSON.parse(line);
  try {
    const result = command.op === "tool"
      ? await runTool(command)
      : command.op === "stop"
        ? { stopped: true }
        : (() => { throw new Error(`unknown operation ${command.op}`); })();
    process.stdout.write(`${JSON.stringify({ type: "result", result })}\n`);
    if (command.op === "stop") break;
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ type: "error", error: String(error?.stack ?? error) })}\n`);
  }
}
await gateway.disconnectGatewayClient(client);
await server.close({ reason: "cross-repository CLI host test complete" });
