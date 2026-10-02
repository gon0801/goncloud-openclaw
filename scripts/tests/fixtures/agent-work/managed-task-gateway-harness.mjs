#!/usr/bin/env node

// The Python integration test owns the corrida record. This helper owns an
// isolated, source-backed R Gateway so the test exercises the authenticated
// WebSocket boundary without changing the R checkout.
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
const [{ startGatewayWithClient, disconnectGatewayClient, getGatewayE2ePortBlock }, store, normalization] =
  await Promise.all([
    load("src/gateway/test-helpers.e2e.ts"),
    load("src/agents/tasks/managed-task.store.ts"),
    load("packages/normalization-core/dist/index.mjs"),
  ]);
const { stableStringify } = normalization;
const digest = (value) => createHash("sha256").update(stableStringify(value)).digest("hex");

await fs.mkdir(stateDir, { recursive: true });
const port = await getGatewayE2ePortBlock();
const { client, server } = await startGatewayWithClient({
  cfg: {
    gateway: { mode: "local", bind: "loopback", port },
    channels: {},
    cron: { enabled: false },
    plugins: { enabled: false },
  },
  configPath: path.join(stateDir, "openclaw.json"),
  token,
  port,
  scopes: ["operator.admin"],
});
await server.startupSettled;
process.stdout.write(`${JSON.stringify({ type: "ready", port, url: `ws://127.0.0.1:${port}` })}\n`);

async function execute(command) {
  if (command.op === "seed") {
    const caller = command.caller;
    const revision = command.revision ?? {
      kind: "code",
      repository: "repo",
      sha: "a".repeat(40),
    };
    const payload = command.payload ?? {
      verdict: "approved",
      evidenceRef: "artifact:review",
    };
    const task = await store.registerManagedTask({
      caller,
      key: command.key ?? "cross-gateway-review",
      assignment: {
        target: { kind: "agent", agentId: "adversary" },
        instructionRef: { ref: "artifact:brief", digest: "sha256:brief" },
        inputRevision: revision,
        resultContract: "review.v1",
        continuation: { kind: "director", corridaId: caller.corridaId },
      },
    });
    if (command.budgetProfile) {
      const budget = await load("src/agents/tasks/managed-task.budget.store.ts");
      await budget.createManagedTaskBudget({
        caller,
        rootTaskId: task.taskId,
        profile: command.budgetProfile,
      });
    }
    const result = await store.reportManagedTaskResult({
      capability: task.producerCapability,
      result: {
        kind: "produced",
        payload,
        artifactRef: "artifact:review",
        digest: `sha256:${digest(payload)}`,
        observedRevision: revision,
      },
    });
    return { task, result, caller, revision, payload };
  }
  if (command.op === "inspect") {
    return await store.inspectManagedTask({ caller: command.caller, taskId: command.taskId });
  }
  if (command.op === "rpc") {
    return await client.request(command.method, command.params);
  }
  if (command.op === "stop") {
    await disconnectGatewayClient(client);
    await server.close({ reason: "cross-repository director resolve test complete" });
    return { stopped: true };
  }
  throw new Error(`unknown operation ${command.op}`);
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of input) {
  if (!line.trim()) continue;
  const command = JSON.parse(line);
  try {
    const result = await execute(command);
    process.stdout.write(`${JSON.stringify({ type: "result", result })}\n`);
    if (command.op === "stop") break;
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ type: "error", error: String(error?.stack ?? error) })}\n`);
  }
}
process.exit(0);
