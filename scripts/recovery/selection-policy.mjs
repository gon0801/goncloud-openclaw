import { isAbsolute } from "node:path";

const agentIds = new Set([
  "main", "operaciones", "ingenieria", "implementer",
  "reviewer", "adversary", "verifier", "scout",
]);
const forbidden = /^(?:\.git|credentials|sessions|logs|tools|models|cache|state|backups)$/i;
const forbiddenFile = /(?:^openclaw\.json(?:\..*)?$|\.env(?:\..*)?$|\.(?:sqlite(?:-wal|-shm)?|wal|shm|pem|key|pfx|p12|exe|dll|zip)(?:\..*)?$|\.bak(?:[-.].*)?$)/i;
const reserved = /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$/i;

export function selectionParts(path) {
  if (typeof path !== "string" || !path || isAbsolute(path) || path.includes("\\") || /[:\x00-\x1f\x7f]/.test(path)) {
    throw new Error("unsafe selection path");
  }
  const parts = path.split("/");
  if (parts.some((part) => !part || part === "." || part === ".." || part.startsWith(".backup-") ||
      reserved.test(part) || /[. ]$/.test(part) || forbidden.test(part) || forbiddenFile.test(part))) {
    throw new Error("unsafe selection path");
  }
  const plugin = ["summa-gate", "tablero-runbook"].includes(parts[0]) && parts.length > 1;
  const skill = parts[0] === "agents" && agentIds.has(parts[1]) && parts.length > 5 &&
    parts[2] === "agent" && parts[3] === "workshop-skills";
  if (!plugin && !skill && path !== "gateway-watchdog.ps1") {
    throw new Error("unsafe selection path: outside recovery allowlist");
  }
  return parts;
}
