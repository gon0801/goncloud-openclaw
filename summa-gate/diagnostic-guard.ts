/**
 * summa-gate diagnostic guard — pure allowlisted core (Fase 5 / 5.3).
 *
 * Version 1 recognizes exactly three incident/subject pairs backed by
 * sanitized evidence. Everything else fails open (returns undefined).
 *
 * Privacy: this module never logs, persists, or interpolates observed
 * content. Classification builds one bounded transient string view
 * (at most MAX_INSPECTED_CHARS total over args + result), matches it,
 * then discards it. State holds only symbolic ids and booleans.
 * Guidance is static text parameterized solely by incident id and the
 * symbolic category ids that remain.
 *
 * This module is dependency-free (no observer.ts import: the observer's
 * broad lexical detector must never gate enforcement) and side-effect
 * free (no fs, no console, no network).
 */

export type DiagnosticMode = "off" | "observe" | "enforce";

export type IncidentId =
  | "path_miss:gh_cli"
  | "wrong_profile:browser_claw"
  | "session_scope:sessions_search";

export type ProbeCategory =
  | "executable_discovery"
  | "known_install_location"
  | "capability_verification"
  | "resolved_config"
  | "profile_retry"
  | "browser_capability"
  | "explicit_agent_scope"
  | "explicit_session_scope"
  | "database_fault_check";

export interface DiagnosticConfig {
  mode: DiagnosticMode;
  requiredProbeCategories: 3;
  maxRevisionAttempts: 1;
}

export interface DiagnosticState {
  version: 1;
  incidentId: IncidentId;
  requiredCategories: ProbeCategory[];
  completedCategories: ProbeCategory[];
  revisionRequested: boolean;
}

export interface DiagnosticObservation {
  toolName: string;
  args: Record<string, unknown>;
  isError?: boolean;
  result: unknown;
}

/** Exact runContext namespace for per-run diagnostic state. */
export const DIAGNOSTIC_NAMESPACE = "summa-gate/diagnostic-guard/v1";

/** Total inspection budget (chars) over args + result per classification. */
export const MAX_INSPECTED_CHARS = 8192;

/** The only absolute path allowed inside static guidance. */
export const KNOWN_GH_EXE = "C:\\Users\\ehven\\.openclaw\\tools\\bin\\gh.exe";

export const INCIDENT_CATEGORIES: Record<IncidentId, ProbeCategory[]> = {
  "path_miss:gh_cli": ["executable_discovery", "known_install_location", "capability_verification"],
  "wrong_profile:browser_claw": ["resolved_config", "profile_retry", "browser_capability"],
  "session_scope:sessions_search": [
    "explicit_agent_scope",
    "explicit_session_scope",
    "database_fault_check",
  ],
};

const KNOWN_INCIDENTS = new Set<string>(Object.keys(INCIDENT_CATEGORIES));

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

function isDiagnosticMode(value: unknown): value is DiagnosticMode {
  return value === "off" || value === "observe" || value === "enforce";
}

export function parseDiagnosticConfig(raw: unknown): DiagnosticConfig {
  let mode: DiagnosticMode = "observe";
  if (raw !== null && typeof raw === "object") {
    const rec = raw as Record<string, unknown>;
    const nested =
      rec["diagnosticGuard"] !== null && typeof rec["diagnosticGuard"] === "object"
        ? (rec["diagnosticGuard"] as Record<string, unknown>)
        : rec;
    const candidate = nested["mode"];
    if (isDiagnosticMode(candidate)) mode = candidate;
  }
  // V1 freezes both counts: unknown/foreign values cannot widen the gate.
  return { mode, requiredProbeCategories: 3, maxRevisionAttempts: 1 };
}

// ---------------------------------------------------------------------------
// Bounded transient inspection
// ---------------------------------------------------------------------------

const COMMAND_FIELDS = ["command", "cmd", "input"] as const;

/** Attempted command, read ONLY from the allowlisted command fields. */
function attemptedCommand(args: Record<string, unknown> | undefined | null): string {
  if (!args || typeof args !== "object") return "";
  for (const field of COMMAND_FIELDS) {
    const value = (args as Record<string, unknown>)[field];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return "";
}

/** First executable token of a shell command, lowercased (gh.exe -> gh). */
function firstExecutableToken(command: string): string {
  let rest = command.trim().replace(/^\(+/, "");
  // Strip leading `sudo ` repetitions without interpreting anything else.
  for (;;) {
    const m = /^sudo\s+/i.exec(rest);
    if (!m) break;
    rest = rest.slice(m[0].length);
  }
  const token = rest.split(/\s+/, 1)[0] ?? "";
  const stripped = token.replace(/^["'`]+|["'`]+$/g, "");
  const base = stripped.split(/[\\/]/).pop() ?? "";
  return base.replace(/\.exe$/i, "").toLowerCase();
}

function pushBounded(out: { text: string }, chunk: string): void {
  const budget = MAX_INSPECTED_CHARS - out.text.length;
  if (budget <= 0) return;
  out.text += chunk.slice(0, budget);
}

/**
 * One bounded transient view over the attempted command plus a cycle-safe
 * walk of args scope fields and the result. Never retained: callers match
 * it and drop it.
 */
function inspectView(
  args: Record<string, unknown> | undefined | null,
  result: unknown,
): string {
  const out = { text: "" };
  const command = attemptedCommand(args);
  if (command) pushBounded(out, `${command}\n`);
  const seen = new Set<object>();
  const walk = (value: unknown): void => {
    if (out.text.length >= MAX_INSPECTED_CHARS) return;
    if (typeof value === "string") {
      pushBounded(out, `${value}\n`);
      return;
    }
    if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") {
      pushBounded(out, `${String(value)}\n`);
      return;
    }
    if (value === null || value === undefined) return;
    if (typeof value !== "object") return;
    if (seen.has(value)) return;
    seen.add(value);
    if (Array.isArray(value)) {
      for (const item of value) {
        walk(item);
        if (out.text.length >= MAX_INSPECTED_CHARS) return;
      }
      return;
    }
    for (const key of Object.keys(value)) {
      walk((value as Record<string, unknown>)[key]);
      if (out.text.length >= MAX_INSPECTED_CHARS) return;
    }
  };
  // Structured scope evidence (agentId/sessionKeys/profile) rides along so
  // probe classification can see subjects without widening command fields.
  if (args && typeof args === "object") {
    for (const key of ["agentId", "sessionKeys", "sessionKey", "profile", "action"]) {
      walk((args as Record<string, unknown>)[key]);
      if (out.text.length >= MAX_INSPECTED_CHARS) return;
    }
  }
  walk(result);
  return out.text;
}

/** Structured-failure equivalent of isError === true. Never matches text alone. */
function hasStructuredFailure(result: unknown): boolean {
  if (result === null || typeof result !== "object") return false;
  const rec = result as Record<string, unknown>;
  if (typeof rec["status"] === "string" && rec["status"].toLowerCase() === "error") return true;
  if (typeof rec["error"] === "string" && rec["error"].trim().length > 0) return true;
  if (rec["ok"] === false || rec["success"] === false) return true;
  for (const key of ["exitCode", "exit_code", "code"]) {
    const value = rec[key];
    if (typeof value === "number" && Number.isInteger(value) && value !== 0) return true;
  }
  return false;
}

function hasFailure(input: DiagnosticObservation): boolean {
  return input.isError === true || hasStructuredFailure(input.result);
}

// ---------------------------------------------------------------------------
// Incident classification (allowlisted tool + subject + failure + signature)
// ---------------------------------------------------------------------------

const GH_FAILURE_RES = [
  /command not found/i,
  /not recognized as an (internal or external )?command/i,
  /\benoent\b/i,
];

const BROWSER_CREDENTIAL_RES = [
  /requires credentials before opening a websocket/i,
  /gateway browser\.request requires credentials/i,
];

// The real incident drives the CLI via exec with the GLOBAL --profile flag
// (see browser-cli-claw-profile/SKILL.md:12-15). The --browser-profile form
// is the correct one and never marks the incident. NOTE: --profile also
// matches inside --browser-profile, hence the explicit exclusion.
const OPENCLAW_BROWSER_CMD_RE = /\bopenclaw\s+browser\b/i;
const GLOBAL_PROFILE_RE = /--profile(\s+|=)claw/i;
const BROWSER_PROFILE_RE = /--browser-profile(\s+|=)claw/i;

function matchesAny(view: string, patterns: RegExp[]): boolean {
  return patterns.some((re) => re.test(view));
}

const SESSION_DB_RES = [/unable to open database file/i, /ERR_SQLITE_ERROR/];

export function classifyIncident(input: DiagnosticObservation): IncidentId | undefined {
  if (!input || typeof input.toolName !== "string") return undefined;
  const args =
    input.args !== null && typeof input.args === "object"
      ? (input.args as Record<string, unknown>)
      : {};
  if (!hasFailure(input)) return undefined;
  const view = inspectView(args, input.result);

  if (input.toolName === "exec" || input.toolName === "bash") {
    const command = attemptedCommand(args);
    if (!command) return undefined;
    if (firstExecutableToken(command) === "gh") {
      if (matchesAny(view, GH_FAILURE_RES)) return "path_miss:gh_cli";
      return undefined;
    }
    // Browser global-profile miss: CLI via exec with the GLOBAL flag.
    // A tool-style profile=claw means the BROWSER profile (valid), so the
    // `browser` tool can never raise this incident.
    if (
      OPENCLAW_BROWSER_CMD_RE.test(command) &&
      GLOBAL_PROFILE_RE.test(command) &&
      !BROWSER_PROFILE_RE.test(command) &&
      matchesAny(view, BROWSER_CREDENTIAL_RES)
    ) {
      return "wrong_profile:browser_claw";
    }
    return undefined;
  }

  if (input.toolName === "sessions_search") {
    // The incident is the UNSCOPED lookup. A scoped failure carries explicit
    // scope and can only ever count as a database_fault_check probe.
    if (nonEmptyString(args["agentId"]) || hasSessionScope(args)) return undefined;
    if (matchesAny(view, SESSION_DB_RES)) return "session_scope:sessions_search";
    return undefined;
  }

  return undefined;
}

// ---------------------------------------------------------------------------
// Completed-probe classification (completed call, incident subject)
// ---------------------------------------------------------------------------

function isCompleted(result: unknown): boolean {
  if (result === undefined || result === null) return false;
  if (typeof result === "object") {
    const rec = result as Record<string, unknown>;
    if (rec["aborted"] === true || rec["cancelled"] === true || rec["cancelRequested"] === true) {
      return false;
    }
  }
  return true;
}

function nonEmptyString(value: unknown): boolean {
  return typeof value === "string" && value.trim().length > 0;
}

function nonEmptyStringArray(value: unknown): boolean {
  return (
    Array.isArray(value) &&
    value.some((item) => typeof item === "string" && item.trim().length > 0)
  );
}

function hasSessionScope(args: Record<string, unknown>): boolean {
  return nonEmptyStringArray(args["sessionKeys"]) || nonEmptyString(args["sessionKey"]);
}

function classifyGhProbe(command: string): ProbeCategory | undefined {
  // Probes validate the EXECUTED command segment, never result text: an
  // `echo`, a fully-quoted documentary mention, or a text search (rg/grep)
  // whose line happens to name the right words must not advance the count.
  if (isDocumentaryCommand(command)) return undefined;
  if (
    splitShellSegments(command).some(
      (segment) =>
        segmentInvokesGh(segment) &&
        (/--version\b/.test(segment) || /\bauth\s+status\b/.test(segment)),
    )
  ) {
    return "capability_verification";
  }
  if (
    segmentMatches(command, KNOWN_LOCATION_FIRST, /gh\.exe/i) ||
    segmentMatches(command, KNOWN_LOCATION_FIRST, /\.openclaw[\\/]tools[\\/]bin/i)
  ) {
    return "known_install_location";
  }
  if (segmentMatches(command, DISCOVERY_FIRST, /\bgh(\.exe)?\b/i)) {
    return "executable_discovery";
  }
  return undefined;
}

function classifyBrowserProbe(
  toolName: string,
  args: Record<string, unknown>,
  command: string,
): ProbeCategory | undefined {
  if (toolName === "browser") {
    // Structured tool calls are validated by action/params, never by output.
    const action = args["action"];
    if (typeof action === "string" && /^(tabs|evaluate|screenshot|navigate|open|snapshot)$/i.test(action.trim())) {
      return "browser_capability";
    }
    const browserProfile = args["browserProfile"] ?? args["browser_profile"];
    if (typeof browserProfile === "string" && browserProfile.toLowerCase() === "claw") {
      return "profile_retry";
    }
    return undefined;
  }
  if (toolName !== "exec" && toolName !== "bash") return undefined;
  if (isDocumentaryCommand(command)) return undefined;
  if (segmentMatches(command, OPENCLAW_FIRST, BROWSER_PROFILE_RE)) return "profile_retry";
  if (
    segmentMatches(command, CONFIG_INSPECT_FIRST, /\bopenclaw\.json\b/) ||
    segmentMatches(command, CONFIG_INSPECT_FIRST, /\bopenclaw\b.{0,200}\bconfig\b/i) ||
    segmentMatches(command, CONFIG_INSPECT_FIRST, /\bconfig\b.{0,200}\bopenclaw\b/i)
  ) {
    return "resolved_config";
  }
  return undefined;
}

function classifySessionProbe(
  args: Record<string, unknown>,
  result: unknown,
): ProbeCategory | undefined {
  const scopedAgent = nonEmptyString(args["agentId"]);
  const scopedSession = hasSessionScope(args);
  // The fault marker must come from the RESULT alone: a query string that
  // merely mentions the fault is not a fault.
  if (scopedAgent && scopedSession && matchesAny(inspectView({}, result), SESSION_DB_RES)) {
    return "database_fault_check";
  }
  if (scopedSession) return "explicit_session_scope";
  if (scopedAgent) return "explicit_agent_scope";
  return undefined;
}

/** A command that documents instead of executing: echo/printf or fully quoted. */
function isDocumentaryCommand(command: string): boolean {
  const trimmed = command.trim();
  if (!trimmed) return true;
  const first = trimmed[0];
  const last = trimmed[trimmed.length - 1];
  if (trimmed.length > 1 && (first === '"' || first === "'" || first === "`") && last === first) {
    return true;
  }
  const token = firstExecutableToken(command);
  return token === "echo" || token === "printf";
}

/**
 * Split a shell line into `&&` / `||` / `;` / pipe segments, respecting
 * single/double/back quotes so probes hidden inside quoted text never
 * count. Backticks are treated as opaque (conservative: a missed exotic
 * probe only delays counting, while a faked one would wrongly complete
 * the investigation).
 */
function splitShellSegments(command: string): string[] {
  const segments: string[] = [];
  let current = "";
  let quote: string | null = null;
  const push = (): void => {
    if (current.trim()) segments.push(current.trim());
    current = "";
  };
  let i = 0;
  while (i < command.length) {
    const ch = command[i];
    if (quote) {
      current += ch;
      if (ch === quote) quote = null;
      i++;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === "`") {
      quote = ch;
      current += ch;
      i++;
      continue;
    }
    const next = command[i + 1];
    if ((ch === "&" && next === "&") || (ch === "|" && next === "|")) {
      push();
      i += 2;
      continue;
    }
    if (ch === "|" || ch === ";") {
      push();
      i++;
      continue;
    }
    current += ch;
    i++;
  }
  push();
  return segments;
}

/**
 * True when some segment actually INVOKES the probe: its first executable
 * token is allowlisted for the category and the category pattern matches
 * the same segment. Text-search tools (rg, grep, …) can never contribute,
 * no matter what words the rest of the line contains.
 */
function segmentMatches(
  command: string,
  allowedFirst: ReadonlySet<string>,
  pattern: RegExp,
): boolean {
  for (const segment of splitShellSegments(command)) {
    if (!allowedFirst.has(firstExecutableToken(segment))) continue;
    if (pattern.test(segment)) return true;
  }
  return false;
}

function segmentInvokesGh(segment: string): boolean {
  return firstExecutableToken(segment) === "gh";
}

const DISCOVERY_FIRST: ReadonlySet<string> = new Set(["which", "where", "get-command", "command"]);
const KNOWN_LOCATION_FIRST: ReadonlySet<string> = new Set([
  "gh",
  "test-path",
  "get-item",
  "get-childitem",
  "ls",
  "dir",
  "stat",
]);
const CONFIG_INSPECT_FIRST: ReadonlySet<string> = new Set([
  "openclaw",
  "cat",
  "get-content",
  "type",
  "ls",
  "dir",
]);
const OPENCLAW_FIRST: ReadonlySet<string> = new Set(["openclaw"]);
const SQLITE_FIRST: ReadonlySet<string> = new Set(["sqlite3"]);

export function classifyCompletedProbe(
  incidentId: IncidentId,
  input: DiagnosticObservation,
): ProbeCategory | undefined {
  if (!KNOWN_INCIDENTS.has(incidentId)) return undefined;
  if (!input || typeof input.toolName !== "string") return undefined;
  if (!isCompleted(input.result)) return undefined;
  const args =
    input.args !== null && typeof input.args === "object"
      ? (input.args as Record<string, unknown>)
      : {};
  // Categories derive from the executed command / structured params.
  // Result text only proves the call completed; it never selects a category.
  const command = attemptedCommand(args);

  if (incidentId === "path_miss:gh_cli") {
    if (input.toolName !== "exec" && input.toolName !== "bash") return undefined;
    return classifyGhProbe(command);
  }
  if (incidentId === "wrong_profile:browser_claw") {
    return classifyBrowserProbe(input.toolName, args, command);
  }
  // session_scope:sessions_search — probes are scoped sessions_search calls
  // (or an exec/sqlite inspection for the database fault).
  if (input.toolName === "sessions_search") {
    return classifySessionProbe(args, input.result);
  }
  if ((input.toolName === "exec" || input.toolName === "bash") && !isDocumentaryCommand(command)) {
    if (segmentMatches(command, SQLITE_FIRST, /\bsqlite3\b/i)) return "database_fault_check";
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// State reducer (symbolic only; repeats never advance)
// ---------------------------------------------------------------------------

export function reduceDiagnosticState(
  state: DiagnosticState | undefined,
  incidentId: IncidentId,
  category?: ProbeCategory,
): DiagnosticState {
  const required = [...INCIDENT_CATEGORIES[incidentId]];
  if (!state) {
    return {
      version: 1,
      incidentId,
      requiredCategories: required,
      completedCategories:
        category !== undefined && required.includes(category) ? [category] : [],
      revisionRequested: false,
    };
  }
  // One run investigates its first incident; a later different incident
  // does not reset or advance the tracked one.
  if (state.incidentId !== incidentId) {
    return {
      version: 1,
      incidentId: state.incidentId,
      requiredCategories: [...state.requiredCategories],
      completedCategories: [...state.completedCategories],
      revisionRequested: state.revisionRequested,
    };
  }
  const completed = [...state.completedCategories];
  if (
    category !== undefined &&
    state.requiredCategories.includes(category) &&
    !completed.includes(category)
  ) {
    completed.push(category);
  }
  return {
    version: 1,
    incidentId: state.incidentId,
    requiredCategories: [...state.requiredCategories],
    completedCategories: completed,
    revisionRequested: state.revisionRequested,
  };
}

// ---------------------------------------------------------------------------
// Static guidance (no observed content is ever interpolated)
// ---------------------------------------------------------------------------

const TERMINAL_LABELS = "NOT_FOUND_AFTER_CHECKS, DENIED, AUTH_FAILED, or WRONG_HOST";

function contractShell(
  incidentId: IncidentId,
  remaining: ProbeCategory[],
  completed: ProbeCategory[],
  body: string,
): string {
  const remainingLines = remaining.map((c) => `- ${c}`).join("\n");
  const completedLine =
    completed.length > 0
      ? `Categories completed so far (already completed, do not repeat): ${completed.join(", ")}\n`
      : "";
  return (
    `<diagnostic-contract incident="${incidentId}">\n` +
    `The initial failure proves only that attempted path failed. It does not prove the capability is missing, unavailable, or inaccessible.\n` +
    `Complete three distinct diagnostic categories before reporting a task-level conclusion.\n` +
    `Remaining categories:\n${remainingLines}\n` +
    completedLine +
    `${body}\n` +
    `Do not repeat external side effects. All probes must be read-only.\n` +
    `Report presence only as SET, UNSET, FOUND, or NOT_FOUND. Never print values, tokens, credentials, or environment content.\n` +
    `</diagnostic-contract>`
  );
}

function ghBody(): string {
  return (
    `Recovery sequence, in order:\n` +
    `1. Inspect the runtime executable inventory for the requested command.\n` +
    `2. Check the fixed known location ${KNOWN_GH_EXE} without printing environment values.\n` +
    `3. Invoke the found binary by absolute path for a read-only --version probe.\n` +
    `4. Verify auth/capability status by presence only (SET/UNSET); never print credential values.\n` +
    `5. Only after three distinct categories completed, report one of ${TERMINAL_LABELS}.`
  );
}

function browserBody(): string {
  return (
    `Recovery sequence, in order:\n` +
    `1. Inspect the resolved config path the failing call used (which profile it resolved to).\n` +
    `2. Retry once with --browser-profile claw on a read-only action.\n` +
    `3. Verify the browser capability with the correct profile.\n` +
    `Only after three distinct categories completed, report one of ${TERMINAL_LABELS}.`
  );
}

function sessionBody(): string {
  return (
    `Recovery sequence, in order:\n` +
    `1. Retry with an explicit agentId.\n` +
    `2. Retry with explicit sessionKeys.\n` +
    `3. Inspect for a database fault only after scoped retries still fail.\n` +
    `Only after three distinct categories completed, report one of ${TERMINAL_LABELS}.`
  );
}

export function buildDiagnosticContract(state: DiagnosticState): string {
  const remaining = state.requiredCategories.filter(
    (c) => !state.completedCategories.includes(c),
  );
  const completed = state.requiredCategories.filter((c) =>
    state.completedCategories.includes(c),
  );
  if (state.incidentId === "path_miss:gh_cli") {
    return contractShell(state.incidentId, remaining, completed, ghBody());
  }
  if (state.incidentId === "wrong_profile:browser_claw") {
    return contractShell(state.incidentId, remaining, completed, browserBody());
  }
  return contractShell(state.incidentId, remaining, completed, sessionBody());
}

// ---------------------------------------------------------------------------
// Task-level incapacity (narrow; never the observer's broad detector)
// ---------------------------------------------------------------------------

const INCAPACITY_PATTERNS = [
  /\bi\s+(cannot|can'?t|am\s+unable\s+to|am\s+not\s+able\s+to|have\s+no\s+(way|access)|don'?t\s+have\s+(access|the\s+(ability|capability)))\b[^.!?\n]{0,200}\b(access|use|reach|run|execute|proceed|do this)\b[^.!?\n]{0,80}\bin\s+this\s+(run|session|environment|runtime|setup)\b/i,
  /\bthe\s+capability\s+is\s+(unavailable|not\s+available|missing)\b/i,
  /\bno\s+tengo\s+acceso\b/i,
  /\bla\s+capacidad\s+no\s+est[áa]\s+disponible\b/i,
  /\bno\s+(puedo|hay\s+manera|es\s+posible)\b[^.!?\n]{0,200}\ben\s+esta\s+(corrida|sesi[oó]n|ejecuci[oó]n)\b/i,
];

const ATTRIBUTION_RE =
  /\b(reviewer|revisor|adversar|report\s+(claims|notes|says|found)|informe|se[ñn]ala|historical|previously|earlier|quoted?|as\s+noted|the\s+report)\b/i;

const FORWARD_ACTION_RE =
  /\b(i\s+will|i'?ll\s+(try|inspect|check|verify)|voy\s+a|will\s+(try|inspect|check|verify|retry)|next\s+step)\b/i;

function stripQuotedSpans(text: string): string {
  return text
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`[^`]*`/g, " ")
    .replace(/"[^"]*"/g, " ")
    .replace(/'[^']*'/g, " ");
}

function lastSubstantiveParagraph(text: string): string {
  const paragraphs = text
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
  return paragraphs.length > 0 ? paragraphs[paragraphs.length - 1] : text.trim();
}

export function isTaskLevelIncapacity(finalText: string): boolean {
  if (typeof finalText !== "string" || finalText.trim().length === 0) return false;
  const paragraph = lastSubstantiveParagraph(finalText);
  if (FORWARD_ACTION_RE.test(paragraph)) return false;
  const unquoted = stripQuotedSpans(paragraph);
  const sentences = unquoted.split(/(?<=[.!?])\s+/);
  return sentences.some(
    (sentence) =>
      INCAPACITY_PATTERNS.some((re) => re.test(sentence)) && !ATTRIBUTION_RE.test(sentence),
  );
}

export function shouldRequestRevision(state: DiagnosticState, finalText: string): boolean {
  if (!state || state.revisionRequested) return false;
  // Threshold over DISTINCT valid categories: triplicated or foreign
  // entries must never read as a completed investigation.
  const distinctDone = new Set(state.completedCategories).size;
  const distinctRequired = new Set(state.requiredCategories).size;
  if (distinctDone >= distinctRequired) return false;
  return isTaskLevelIncapacity(finalText);
}
