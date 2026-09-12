/**
 * summa-gate observer — append-only jsonl that records `agent_end` turns whose
 * final assistant text looks like a capability refusal AND that did not perform
 * a non-replay-safe tool call earlier in the turn.
 *
 * Why this lives separately from `lib.ts`:
 * - lib.ts is pure helpers consumed by the gate of receipt and by
 *   `mergeGuardVerdict`. Anything that touches the filesystem (jsonl write,
 *   rotation) belongs here so the gate stays testable in memory.
 * - The handler that wires this into `agent_end` lives in index.ts and
 *   returns nothing. The runtime discards the value (runVoidHook in
 *   hook-runner-global-BhDCl4qm.mjs, runAgentEnd at line 1003, timeout 3e4 ms
 *   from DEFAULT_VOID_HOOK_TIMEOUT_MS_BY_HOOK at line 452). That is the proof
 *   cited in 2.1 DoD that this hook is Observe by type.
 *
 * What this observer is NOT:
 * - It does not refuse or modify the turn. Even if a recorded line screams
 *   "the agent gave up", the runtime has already finalized the delivery.
 *   The cost of a false positive here is one extra line in a jsonl, never a
 *   refused task. That asymmetry is why the detector over-registers.
 *
 * Rotation policy (declared here, not scattered ad-hoc in the writer):
 * - When the live jsonl would cross ~5 MB after this write, rename it to
 *   `rendiciones.<unix-ms>.1.jsonl` and start a fresh file. One backup level
 *   only. No compression, no deletion. Operators tail the jsonl; cheap.
 */

import { appendFileSync, mkdirSync, renameSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// Public constants — exported for tests + so wiring in index.ts does not
// have to learn the file layout.
// ---------------------------------------------------------------------------

export const OBSERVER_DIR = join(homedir(), ".openclaw", "summa-gate");
export const OBSERVER_FILE_DEFAULT = join(OBSERVER_DIR, "rendiciones.jsonl");
let observerFileOverride: string | undefined;
/** Test-only override for the jsonl path. Production wiring reads the
 *  module-level constant via the OBSERVER_FILE() accessor. */
export function _setObserverFileForTest(p: string | undefined): void {
  observerFileOverride = p;
}
export function OBSERVER_FILE(): string {
  return observerFileOverride ?? OBSERVER_FILE_DEFAULT;
}
export const OBSERVER_MAX_BYTES = 5 * 1024 * 1024; // 5 MB
export const TEXT_PREVIEW_CHARS = 300;

// ---------------------------------------------------------------------------
// "Forma de incapacidad" — declared once, exported so tests and wiring
// share the same definition.
//
// D1: declarative first-person inability phrases in Spanish (the model's
//     primary working language on this gateway). Anchored on whole words so
//     substrings inside other words do not match.
// D2: literal tokens from the canonical incident on 2026-09-12 (the case the
//     refused-task gate was originally meant to catch). Carrying the literal
//     markers is what lets reviewers trace a 2.1 line back to the original
//     report without guessing at paraphrases.
//
// Both OR-combined. Over-registration is the explicit design: a false
// positive costs one extra jsonl line, never a refused task.
// ---------------------------------------------------------------------------

const INCAPACITY_DECLARATIVE_RE =
  /\b(?:no (?:me )?(?:puedo|es posible)|no tengo|esta bloqueado|sin herramienta|no se puede|bloqueado|fuera de (?:mi )?alcance|carezco de|no me es posible|no dispongo|no cuento con|no esta soportado|no existe la capacidad|me falta la capacidad|faltan? (?:las? )?(?:skill|habilidades?|capacidad(?:es)?)|no hay (?:una |ninguna )?(?:funci[oó]n|opci[oó]n|forma|herramienta|capacidad|skill)|tecnicamente imposible|requeriria una skill)\b|(?:i'?m unable to|i don'?t have (?:the )?(?:ability|tool|skill)|there(?:'s| is) no (?:tool|skill|capability|way) (?:for|to|available)|i (?:can'?t|cannot) (?:run|do|execute|access)|no (?:skill|tool|method|way) (?:is )?installed|(?:is|isn'?t|aren'?t) (?:installed|available)|(?:not|unavailable) available|unavailable to me|that capability)/i;

const INCAPACITY_INCIDENT_TOKENS = [
  "requires credentials before opening a websocket",
  "gateway browser.request requires credentials",
  "host_impediment",
  "ERR_SQLITE_ERROR",
  "unable to open database file",
  "COMPANION_APP_UNAVAILABLE",
];

function regexQuoteLiteral(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export const INCAPACITY_RE = new RegExp(
  "(?:" +
    INCAPACITY_DECLARATIVE_RE.source +
    "|" +
    INCAPACITY_INCIDENT_TOKENS.map(regexQuoteLiteral).join("|") +
    ")",
  "i",
);

// ---------------------------------------------------------------------------
// Side-effect classification — mirrors the runtime's `hadDeterministicSideEffect`.
// We re-derive it from the message tool names instead of trusting
// `event.hadDeterministicSideEffect` (which the runtime does not surface to
// observer hooks) so the observer does not depend on undocumented fields the
// runtime may rename in a future version.
// ---------------------------------------------------------------------------

const NON_REPLAY_SAFE_TOOL_NAMES: ReadonlySet<string> = new Set([
  // Execution / shell
  "exec",
  "bash",
  "process",
  // Filesystem rewrites (read is replay-safe, so it is implicit; never listed here)
  "write",
  "edit",
  "apply_patch",
  "multiedit",
  "notebook_edit",
  // Cross-agent / cross-session with observable effect
  "sessions_send",
  "sessions_spawn",
  // Automation / node / secrets requests can hit the network or the filesystem
  "cron",
  "nodes",
  "secrets",
]);

export function isNonReplaySafeTool(name: unknown): boolean {
  return typeof name === "string" && NON_REPLAY_SAFE_TOOL_NAMES.has(name);
}

export type AgentEndMessage = {
  role?: unknown;
  content?: unknown;
  toolName?: unknown;
  name?: unknown;
};

export type AgentEndEventLike = {
  type?: unknown;
  // The runtime delivers `messages` here. The watcher-side field is
  // intentionally permissive: malformed turns must not crash the observer.
  messages?: AgentEndMessage[];
};

export type ObserverRecord = {
  ts: number;
  sessionKey: string;
  agent?: string;
  inputProvenanceKind?: string;
  // `hadRead` mide "hubo algun read en este turno", no "se leyo un SKILL.md".
  // El runtime no expone la ruta del `read` al observer hook; cualquier
  // `read` (docs, TSV, jsonl, registry) cuenta igual. La medida ideal
  // ("consulto su skill y aun asi se rindi") no es observable hoy.
  // Anclar este contrato: el nombre describe lo que el dato dice,
  // no lo que el operador querria medir (lo opuesto al error `unknown`
  // vs `0` de Fase 1).
  hadRead: boolean;
  tools: Record<string, number>;
  nonReplaySafeCount: number;
  detected: boolean;
  textLen: number;
  textPreview: string;
};

// ---------------------------------------------------------------------------
// Pure helpers — easy to unit-test without touching the filesystem.
// ---------------------------------------------------------------------------

export function toolNamesFromMessages(messages: AgentEndMessage[] | undefined | null): string[] {
  if (!Array.isArray(messages)) return [];
  const names: string[] = [];
  for (const m of messages) {
    if (!m || typeof m !== "object") continue;
    if (typeof m.toolName === "string") names.push(m.toolName);
    else if (typeof m.name === "string") names.push(m.name);
  }
  return names;
}

export function lastAssistantText(messages: AgentEndMessage[] | undefined | null): string {
  if (!Array.isArray(messages)) return "";
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (!m || typeof m !== "object") continue;
    if (m.role !== "assistant" && m.role !== "model") continue;
    const content = m.content;
    if (typeof content === "string") return content;
    if (Array.isArray(content)) {
      let merged = "";
      for (const part of content) {
        if (part && typeof part === "object" && typeof (part as { text?: unknown }).text === "string") {
          merged += (part as { text: string }).text;
        }
      }
      if (merged) return merged;
    }
  }
  return "";
}

function hadReadInTurn(toolNames: string[]): boolean {
  // Mide "hubo algun read en este turno". NO mide "se leyo un SKILL.md":
  // el runtime no entrega el `path` de cada `read` al observer hook, asi
  // que un read a un doc, a un jsonl, o al registry de skills cuenta
  // igual. Si el operador quiere "consulto su skill y aun asi se
  // rindi" tiene que correlacionarlo con el transcript del modelo; no
  // puede inferirlo de este campo.
  return toolNames.includes("read");
}

export function buildRecord(
  ts: number,
  sessionKey: string,
  agent: string | undefined,
  inputProvenanceKind: string | undefined,
  messages: AgentEndMessage[] | undefined | null,
): ObserverRecord {
  const toolNames = toolNamesFromMessages(messages);
  const counts: Record<string, number> = {};
  let nonReplaySafeCount = 0;
  for (const n of toolNames) {
    counts[n] = (counts[n] ?? 0) + 1;
    if (isNonReplaySafeTool(n)) nonReplaySafeCount += 1;
  }
  const text = lastAssistantText(messages);
  const detected = nonReplaySafeCount === 0 && text.length > 0 && INCAPACITY_RE.test(text);
  return {
    ts,
    sessionKey,
    agent,
    inputProvenanceKind,
    hadRead: hadReadInTurn(toolNames),
    tools: counts,
    nonReplaySafeCount,
    detected,
    textLen: text.length,
    textPreview: text.slice(0, TEXT_PREVIEW_CHARS),
  };
}

// ---------------------------------------------------------------------------
// Writer — append a record as a single jsonl line, rotating when the file
// would exceed OBSERVER_MAX_BYTES. Single backup level, atomic rename, no
// compression, fail-open if anything goes wrong (caller wraps in try/catch).
// ---------------------------------------------------------------------------

export function writeRecord(record: ObserverRecord): { rotated: boolean; bytesAfter: number } {
  mkdirSync(OBSERVER_DIR, { recursive: true });
  const line = JSON.stringify(record) + "\n";

  let bytesBefore = 0;
  try {
    bytesBefore = statSync(OBSERVER_FILE()).size;
  } catch {
    bytesBefore = 0;
  }
  const livePath = OBSERVER_FILE();
  let rotated = false;
  let bytesAfter: number;
  if (bytesBefore > 0 && bytesBefore + Buffer.byteLength(line, "utf8") > OBSERVER_MAX_BYTES) {
    const ts = Date.now();
    // Backup lives NEXT TO the live path (not under OBSERVER_DIR), so the
    // test-only override that points the live file into a tmpdir rotates
    // into the SAME tmpdir instead of dumping the backup into the real
    // plugin install dir. Production wiring keeps OBSERVER_FILE() pointing
    // at ~/.openclaw/summa-gate/rendiciones.jsonl, so the backup lands at
    // ~/.openclaw/summa-gate/rendiciones.<unix-ms>.1.jsonl in that case.
    // Suffix convention: `<base>.<ts>.1.jsonl`, so the backup keeps the
    // `.jsonl` extension and tail operators can do `tail ./*.<ts>.1.jsonl`.
    const rotatedPath = `${livePath}.${ts}.1.jsonl`;
    renameSync(livePath, rotatedPath);
    rotated = true;
    bytesAfter = Buffer.byteLength(line, "utf8");
  } else {
    bytesAfter = bytesBefore + Buffer.byteLength(line, "utf8");
  }
  appendFileSync(livePath, line, "utf8");
  return { rotated, bytesAfter };
}
