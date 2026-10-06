#!/usr/bin/env node

// A source-backed, isolated R Gateway with one certified fixture host. The
// Python test drives native requester tools and G's real CLI transport.
// Defaults reproduce cli_gateway; CROSS_* variables pick another requester
// session, host, or a loopback model provider that counts every request.
import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import readline from "node:readline";
import { pathToFileURL } from "node:url";

const root = process.env.AGENT_WORK_RUNTIME_SOURCE;
const stateDir = process.env.OPENCLAW_STATE_DIR;
const token = process.env.CROSS_GATEWAY_TOKEN;
if (!root || !stateDir || !token) {
  throw new Error("AGENT_WORK_RUNTIME_SOURCE, OPENCLAW_STATE_DIR, and CROSS_GATEWAY_TOKEN are required");
}
const requesterAgentId = process.env.CROSS_REQUESTER_AGENT_ID || "ingenieria";
const sessionKey = process.env.CROSS_REQUESTER_SESSION_KEY || "agent:ingenieria:main";
const hostId = process.env.CROSS_HOST_ID || "e2e-host";
const hostAdapter = process.env.CROSS_HOST_ADAPTER || "codex";
const countingProvider = process.env.CROSS_PROVIDER === "loopback";
if (!sessionKey.startsWith(`agent:${requesterAgentId}:`)) {
  throw new Error("CROSS_REQUESTER_SESSION_KEY must belong to CROSS_REQUESTER_AGENT_ID");
}
const load = (relative) => import(pathToFileURL(path.join(root, relative)).href);
const [
  gateway, identity, sessions, toolModule, callerModule, artifactModule, hostModule, stateDb, mockModel,
] = await Promise.all([
  load("src/gateway/test-helpers.e2e.ts"),
  load("src/infra/device-identity.ts"),
  load("src/config/sessions/session-accessor.ts"),
  load("src/agents/tools/managed-tasks-tool.ts"),
  load("src/agents/tools/gateway-caller-context.ts"),
  load("src/agents/tasks/managed-task.artifact.ts"),
  load("src/agents/tasks/managed-task.host.ts"),
  load("src/state/openclaw-state-db.ts"),
  load("src/gateway/test-openai-responses-model.ts"),
]);

await fs.mkdir(stateDir, { recursive: true });
const deviceIdentity = identity.loadOrCreateDeviceIdentity();
const sessionId = "cross-cli-session";
const storePath = path.join(stateDir, "sessions.json");
const sessionIds = new Map([[sessionKey, sessionId]]);
await sessions.upsertSessionEntryCore(
  { agentId: requesterAgentId, sessionKey, storePath },
  { sessionId, updatedAt: Date.now() },
);

// Every session-queue row, so a test can see which session a result wakes.
function sessionDeliveries() {
  return stateDb.openOpenClawStateDatabase().db.prepare(
    "SELECT id, status, entry_kind, session_key, entry_json, enqueued_at FROM delivery_queue_entries WHERE queue_name = 'session' ORDER BY enqueued_at, id",
  ).all().map((row) => {
    const entry = JSON.parse(row.entry_json);
    return {
      id: row.id, status: row.status, kind: row.entry_kind ?? entry.kind,
      sessionKey: row.session_key ?? entry.sessionKey ?? null, agentId: entry.agentId ?? null,
      contextKey: entry.contextKey ?? null, managedTaskDelivery: entry.managedTaskDelivery === true,
      deliveryStartedAt: entry.deliveryStartedAt ?? null, enqueuedAt: row.enqueued_at,
    };
  });
}

const providerRequests = [];
let provider;
if (countingProvider) {
  const listener = createServer((request, response) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8");
      providerRequests.push({
        at: Date.now(), method: request.method, path: request.url,
        wakeTasks: [...body.matchAll(/Managed task (\S+) generation \d+ has a final result/g)]
          .map((match) => match[1]),
        // Host incidents the model was told about; the session history repeats earlier ones.
        incidentWakes: [...body.matchAll(/Managed task (\S+) generation \d+ recorded incident ([a-z-]+);/g)]
          .map((match) => ({ taskId: match[1], kind: match[2] })),
        startedDeliveries: sessionDeliveries().filter((row) => row.deliveryStartedAt !== null)
          .map(({ sessionKey: key, contextKey, enqueuedAt }) => ({ sessionKey: key, contextKey, enqueuedAt })),
      });
      const item = {
        type: "message", id: randomUUID(), role: "assistant", status: "completed",
        content: [{ type: "output_text", text: "NO_REPLY", annotations: [] }],
      };
      const events = [
        { type: "response.output_item.added", output_index: 0, item },
        { type: "response.output_item.done", output_index: 0, item },
        { type: "response.completed", response: {
          id: randomUUID(), status: "completed", output: [item],
          usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
        } },
      ];
      response.writeHead(200, { "content-type": "text/event-stream" });
      for (const event of events) response.write(`data: ${JSON.stringify(event)}\n\n`);
      response.end("data: [DONE]\n\n");
    });
  });
  await new Promise((resolve, reject) => {
    listener.once("error", reject);
    listener.listen(0, "127.0.0.1", resolve);
  });
  provider = {
    listener,
    ...mockModel.buildMockOpenAiResponsesProvider(
      `http://127.0.0.1:${listener.address().port}/v1`, "agent-work-loopback"),
  };
}
const profile = {
  maxConcurrentTasks: 2, maxDepth: 2, maxChildren: 2, maxModelCalls: 2,
  maxInputTokens: 1000, maxOutputTokens: 1000, maxCacheReadTokens: 1000,
  maxContextTokens: 1000, maxTreeTokens: 2000, maxAutomaticRecoveryCalls: 1,
};
const port = await gateway.getGatewayE2ePortBlock();
const agentList = [{ id: requesterAgentId }];
const config = {
  gateway: { mode: "local", bind: "loopback", port },
  channels: {}, cron: { enabled: false }, plugins: { enabled: false },
  session: { store: storePath },
  agents: provider
    ? {
      defaults: {
        workspace: path.join(stateDir, "workspace"), skipBootstrap: true,
        model: { primary: provider.modelRef },
        models: { [provider.modelRef]: { params: { transport: "sse", openaiWsWarmup: false } } },
      },
      list: agentList,
    }
    : { list: agentList },
  ...(provider
    ? { models: { mode: "replace", providers: { [provider.providerId]: provider.config } } }
    : {}),
  managedTasks: {
    enabled: true, instructionRoot: stateDir, runTimeoutSeconds: 60, profile,
    hosts: { [hostId]: { deviceId: deviceIdentity.deviceId, adapters: [hostAdapter] } },
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
  // A turn may name another session of the same agent, such as a cron run.
  const turnSessionKey = command.sessionKey ?? sessionKey;
  if (!turnSessionKey.startsWith(`agent:${requesterAgentId}:`)) {
    throw new Error("requester turn session belongs to another agent");
  }
  if (!sessionIds.has(turnSessionKey)) {
    sessionIds.set(turnSessionKey, `cross-cli-${randomUUID()}`);
    await sessions.upsertSessionEntryCore(
      { agentId: requesterAgentId, sessionKey: turnSessionKey, storePath },
      { sessionId: sessionIds.get(turnSessionKey), updatedAt: Date.now() },
    );
  }
  const bytes = Buffer.from("Review the fixture change and return one verdict.\n");
  const expectedDigest = createHash("sha256").update(bytes).digest("hex");
  const tools = toolModule.createManagedTaskTools({
    source: {
      agentId: requesterAgentId, sessionKey: turnSessionKey,
      sessionId: sessionIds.get(turnSessionKey), runId,
      senderId: "fixture-person", channel: "discord", accountId: "fixture-team",
    },
    profile, config, spawnContext: {}, runTimeoutSeconds: 60,
    resolveInstructionRef: async (ref) => {
      if (ref === "artifact:fixture-source") return bytes;
      if (ref === `artifact:${expectedDigest}`) {
        // routing.py writes the brief into instructionRoot, read as in production;
        // the fixture-source brief exists only in the artifact store.
        return fs.access(path.join(stateDir, expectedDigest)).then(
          () => hostModule.resolveManagedTaskHostCapability(config).resolveInstructionRef(ref),
          () => artifactModule.readManagedTaskArtifact(ref),
        );
      }
      throw new Error("unrecognized fixture instruction reference");
    },
  });
  const tool = tools.find((entry) => entry.name === name);
  if (!tool) throw new Error("native requester tool missing");
  const result = await callerModule.withGatewayToolCallerIdentity(
    {
      agentId: requesterAgentId, sessionKey: turnSessionKey,
      operationalRunInstance: { instanceId: runId, runId },
      receiptAuthority: () => true,
    },
    () => tool.execute(`cross-${command.action}`, command.args),
  );
  return result.details;
}

const operations = {
  tool: runTool,
  deliveries: async () => sessionDeliveries(),
  provider: async () => ({ enabled: Boolean(provider), requests: providerRequests }),
  sessions: async () => sessions.listSessionEntryKeysReadOnly({ agentId: requesterAgentId, storePath }),
  stop: async () => ({ stopped: true }),
};
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of input) {
  if (!line.trim()) continue;
  const command = JSON.parse(line);
  try {
    const operation = Object.hasOwn(operations, command.op) ? operations[command.op] : undefined;
    if (!operation) throw new Error(`unknown operation ${command.op}`);
    const result = await operation(command);
    process.stdout.write(`${JSON.stringify({ type: "result", result })}\n`);
    if (command.op === "stop") break;
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ type: "error", error: String(error?.stack ?? error) })}\n`);
  }
}
await gateway.disconnectGatewayClient(client);
await server.close({ reason: "cross-repository CLI host test complete" });
if (provider) {
  provider.listener.closeAllConnections();
  await new Promise((resolve) => provider.listener.close(resolve));
}
