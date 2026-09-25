/**
 * summa-gate — port nativo (OpenClaw plugin) del harness bash `summonaikit`.
 *
 * Features:
 *  1. merge-guard (siempre activo): bloquea `gh pr merge` y `git push` a
 *     master/main; las rutas API de merge exigen implementer/ingenieria.
 *  2. Sentinel `-saikit[:lane]` en `before_prompt_build`: arma la sesión,
 *     persiste estado en disco e inyecta el contrato de ceremonia.
 *  3. Standing rules ligeras en el primer prompt de cada sesión.
 *  4. Evidencia post-tool en `after_tool_call` (implemented / verified).
 *  5. Gate de cierre en `before_agent_finalize`: exige el recibo
 *     SUMMONAIKIT HARNESS RECEIPT con sus 6 etiquetas y verificación real.
 *  6. Confinamiento del subagente `adversary` a .saikit/findings y
 *     .saikit/scratch (best-effort, fail-open).
 *  7. Tracking de roles de subagentes y orden implementer → verifier/reviewer
 *     en lane=full.
 *  8. Canal entre agentes: bloquea el `sessions_send` de main a otro agente
 *     (pierde la respuesta), salvo avisos [AVISO SIN RESPUESTA] o reporte de
 *     vuelta a su sessionKey.
 *
 * Solo módulos builtin de node + el plugin-sdk. Sin dependencias npm.
 */

import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

import {
  type Role,
  type SessionsSendParams,
  adversaryPathAllowed,
  commandChangesCwd,
  canonicalRole,
  isDocOrLock,
  sessionsSendGuardVerdict,
  labelRegex,
  mergeGuardVerdict,
  redirectTargets,
} from "./lib.ts";

import { buildRecord, isTurnRecordable, writeRecord } from "./observer.ts";

import {
  DIAGNOSTIC_NAMESPACE,
  buildDiagnosticContract,
  classifyCompletedProbe,
  classifyIncident,
  isTaskLevelIncapacity,
  parseDiagnosticConfig,
  reduceDiagnosticState,
  shouldRequestRevision,
  type DiagnosticObservation,
  type DiagnosticState,
  type IncidentId,
} from "./diagnostic-guard.ts";

// ---------------------------------------------------------------------------
// Estado persistido por sesión
// ---------------------------------------------------------------------------

type Lane = "fast" | "full";

type SessionState = {
  taskHash: string;
  armedAt: number;
  cycle: number;
  implemented: boolean;
  verified: boolean;
  lane: Lane;
  autopilot: boolean;
  agentsSeen: Role[];
};

const STATE_DIR = join(homedir(), ".openclaw", "summa-gate", "state");
const STATE_TTL_MS = 14 * 24 * 60 * 60 * 1000; // 14 días

function sanitizeSessionKey(key: string): string {
  return key.replace(/[^A-Za-z0-9._-]/g, "_") || "unknown";
}

function statePath(sessionKey: string): string {
  return join(STATE_DIR, `${sanitizeSessionKey(sessionKey)}.json`);
}

function loadState(sessionKey: string): SessionState | undefined {
  try {
    const raw = readFileSync(statePath(sessionKey), "utf8");
    const parsed = JSON.parse(raw) as SessionState;
    if (typeof parsed !== "object" || parsed === null) return undefined;
    if (!Array.isArray(parsed.agentsSeen)) parsed.agentsSeen = [];
    return parsed;
  } catch {
    return undefined;
  }
}

function saveState(sessionKey: string, state: SessionState): void {
  try {
    mkdirSync(STATE_DIR, { recursive: true });
    writeFileSync(statePath(sessionKey), `${JSON.stringify(state, null, 2)}\n`, "utf8");
  } catch {
    // fail-open: sin disco no hay gate, pero no rompemos el turno
  }
}

function deleteState(sessionKey: string): void {
  try {
    rmSync(statePath(sessionKey), { force: true });
  } catch {
    // fail-open
  }
}

function sweepStaleState(now: number): void {
  try {
    for (const entry of readdirSync(STATE_DIR)) {
      if (!entry.endsWith(".json")) continue;
      const full = join(STATE_DIR, entry);
      try {
        if (now - statSync(full).mtimeMs > STATE_TTL_MS) rmSync(full, { force: true });
      } catch {
        // archivo individual ilegible: se ignora
      }
    }
  } catch {
    // dir inexistente: nada que barrer
  }
}

function sha256(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

// ---------------------------------------------------------------------------
// Diagnostic guard: tool-result observation adapter + per-run lock queue
// ---------------------------------------------------------------------------

type DiagnosticRunContext = {
  setRunContext: (args: { runId: string; namespace: string; value: unknown }) => boolean;
  getRunContext: (args: { runId: string; namespace: string }) => unknown;
  clearRunContext: (args: { runId: string; namespace?: string }) => void;
};

type ToolResultEventLike = {
  toolCallId?: unknown;
  toolName?: unknown;
  args?: unknown;
  isError?: unknown;
  result?: unknown;
};

type ToolResultContextLike = {
  runtime?: unknown;
  agentId?: unknown;
  sessionId?: unknown;
  sessionKey?: unknown;
  runId?: unknown;
};

/**
 * Map a host tool-result event to a pure observation. Follows the SDK shape
 * (AgentToolResultMiddlewareEvent): toolName/args/isError/result come from
 * the event; identity (runId) comes ONLY from ctx. Never throws.
 */
function diagnosticObservationFromEvent(event: ToolResultEventLike): DiagnosticObservation | undefined {
  const toolName = typeof event.toolName === "string" ? event.toolName : "";
  if (!toolName) return undefined;
  const rawArgs = event.args;
  const args =
    rawArgs !== null && typeof rawArgs === "object"
      ? (rawArgs as Record<string, unknown>)
      : {};
  return { toolName, args, isError: event.isError === true ? true : undefined, result: event.result };
}

const PROBE_CATEGORY_ALLOWLIST: ReadonlySet<string> = new Set([
  "executable_discovery",
  "known_install_location",
  "capability_verification",
  "resolved_config",
  "profile_retry",
  "browser_capability",
  "explicit_agent_scope",
  "explicit_session_scope",
  "database_fault_check",
]);

const EXPECTED_CATEGORIES_BY_INCIDENT: Record<string, string[]> = {
  "path_miss:gh_cli": ["executable_discovery", "known_install_location", "capability_verification"],
  "wrong_profile:browser_claw": ["resolved_config", "profile_retry", "browser_capability"],
  "session_scope:sessions_search": ["explicit_agent_scope", "explicit_session_scope", "database_fault_check"],
};

/**
 * Validate untrusted runContext content into a DiagnosticState. Anything
 * off the exact V1 allowlist (unknown incident, required triple mismatch,
 * foreign completed entries, wrong types) is rejected as absent. Never throws.
 */
function asDiagnosticState(value: unknown): DiagnosticState | undefined {
  if (value === null || typeof value !== "object") return undefined;
  const rec = value as Record<string, unknown>;
  if (rec["version"] !== 1) return undefined;
  const incidentId = rec["incidentId"];
  if (
    incidentId !== "path_miss:gh_cli" &&
    incidentId !== "wrong_profile:browser_claw" &&
    incidentId !== "session_scope:sessions_search"
  ) {
    return undefined;
  }
  if (!Array.isArray(rec["requiredCategories"]) || !Array.isArray(rec["completedCategories"])) {
    return undefined;
  }
  if (typeof rec["revisionRequested"] !== "boolean") return undefined;
  const required = rec["requiredCategories"];
  if (
    required.length !== 3 ||
    !required.every((item): item is string => typeof item === "string") ||
    new Set(required).size !== 3
  ) {
    return undefined;
  }
  const expected: ReadonlySet<string> = new Set(
    EXPECTED_CATEGORIES_BY_INCIDENT[incidentId as string] ?? [],
  );
  if (!required.every((item: string) => expected.has(item))) return undefined;
  const completed = rec["completedCategories"];
  if (
    !completed.every(
      (item): item is string =>
        typeof item === "string" && PROBE_CATEGORY_ALLOWLIST.has(item) && expected.has(item),
    )
  ) {
    return undefined;
  }
  // Duplicates are rejected, not deduplicated: a stored state claiming the
  // same probe three times is corrupt, and must fail open instead of
  // reading as a completed investigation.
  if (new Set(completed as string[]).size !== (completed as string[]).length) {
    return undefined;
  }
  return {
    version: 1,
    incidentId: incidentId as IncidentId,
    requiredCategories: [...(required as string[])] as DiagnosticState["requiredCategories"],
    completedCategories: [...(completed as string[])] as DiagnosticState["completedCategories"],
    revisionRequested: rec["revisionRequested"],
  };
}

// Module-local Map<runId, Promise<void>> used ONLY as a lock queue: keys are
// runIds, values are void promises carrying no diagnostic data. Diagnostic
// state itself lives in api.runContext under DIAGNOSTIC_NAMESPACE.
const diagnosticLocks = new Map<string, Promise<void>>();

function enqueueDiagnosticUpdate(runId: string, task: () => Promise<void>): Promise<void> {
  const prev = diagnosticLocks.get(runId) ?? Promise.resolve();
  const run = prev.then(task, task);
  let settled: Promise<void>;
  const cleanup = (): void => {
    if (diagnosticLocks.get(runId) === settled) diagnosticLocks.delete(runId);
  };
  settled = run.then(cleanup, cleanup);
  diagnosticLocks.set(runId, settled);
  return run;
}

// ---------------------------------------------------------------------------
// 2/3. Sentinel, armado y standing rules
// ---------------------------------------------------------------------------

const SENTINEL_RE = /(?:^|[^A-Za-z0-9])-saikit(?::([a-z]+))?(?![A-Za-z0-9])/;

const STANDING_RULES = `[summa-gate] Reglas permanentes de esta sesión:
1. La batería completa de pruebas se corre UNA sola vez por tarea, idealmente en CI/PR; no la repitas localmente si el mismo SHA ya fue validado por commit, push o CI.
2. Creá las ramas desde origin/<default> actualizado y verificá el punto de partida con git log antes de trabajar.
3. No te bloquees esperando jobs en background: revisá primero su estado y seguí con otra cosa.
4. Antes de re-intentar una acción que falló, diagnosticá la causa raíz; no repitas a ciegas.
5. "Approved executables: none" es la lista de atajos pre-aprobados, NO un bloqueo de exec: intentá el comando real antes de decir que no podés. Un bloqueo de verdad es el binder negando un comando concreto con su error (ej. "approval cannot safely bind this command"); eso se reporta con el comando y el error exactos. La ausencia de una skill con el nombre de la tarea tampoco es un bloqueo: las capacidades viven en exec.`;

function buildContract(lane: Lane, autopilot: boolean): string {
  const laneNote =
    lane === "fast"
      ? "Lane FAST: no se exige orden de subagentes; el resto del contrato aplica igual."
      : autopilot
        ? "Lane FULL + AUTOPILOT: cierre autónomo permitido, pero el recibo sigue siendo obligatorio y se exige el orden de subagentes."
        : "Lane FULL: si usaste subagentes, implementer debe aparecer antes que verifier y reviewer.";
  return `[summa-gate] CONTRATO DE CEREMONIA (sentinel -saikit detectado)
${laneNote}

Esta sesión quedó ARMADA. Al finalizar la tarea, tu respuesta final DEBE cerrar
con un bloque de recibo exactamente así:

SUMMONAIKIT HARNESS RECEIPT
Understand: <qué entendiste de la tarea>
Implement: <qué cambiaste, archivos tocados>
Verify: <qué corriste para verificar y su resultado>
Review: <qué revisión hiciste o quién revisó>
Close: <estado final, sha/PR si aplica>
Retro: <qué mejorar del proceso>

Reglas del recibo:
- Las 6 etiquetas son obligatorias, en ese orden, cada una en su línea.
- Verify exige evidencia REAL: haber corrido tests de verdad en este turno
  (npm test, pytest, vitest, go test, etc. con resultado exitoso). Si la
  verificación no aplica, declará el skip EXPLÍCITO con su razón
  (ej: "Verify: skip de verificación — cambio solo de docs").
- Si el recibo declara un rol que no corrió como subagente, aclaralo con
  "ROLE FALLBACK: <ROL>" (ej: ROLE FALLBACK: IMPLEMENTER).

Escotillas (permiten cerrar SIN recibo, una sola por respuesta):
- "SUMMONAIKIT HARNESS PAUSED" — necesitás una aclaración del operador.
- "SUMMONAIKIT HARNESS DELEGATED - awaiting <rol>" — quedaste esperando el
  resultado de un subagente.

Recordatorios operativos:
- No uses gh pr merge ni git push a master/main: el merge-guard los bloquea
  siempre, con o sin sentinel. Main y reviewer tampoco pueden usar rutas API de merge.
- En autopilot del kit, seguí saikit-merge.sh después de la preaprobación de fase
  y el recibo exigido por el repo.
- Con una orden fechada del dueño en el brief para la lane SAIKIT, implementer/ingenieria
  pueden ejecutar el merge GraphQL con expectedHeadOid. El guard también permite
  rutas REST de merge a esos agentes; la orden del dueño determina la ruta autorizada.
- El sentinel es por turno: un prompt sin -saikit desarma la ceremonia.`;
}

// ---------------------------------------------------------------------------
// 4. Evidencia post-tool
// ---------------------------------------------------------------------------

const WRITE_TOOLS = new Set([
  "write",
  "edit",
  "apply_patch",
  "multiedit",
  "notebook_edit",
  "str_replace",
]);

function extractPathParam(params: Record<string, unknown>): string | undefined {
  for (const key of ["file_path", "path", "filePath", "target_file"]) {
    const value = params[key];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return undefined;
}

const TEST_RUNNER_RE =
  /(?:^|[\s;&|`(])((npm|pnpm|yarn|bun)(\s+run)?\s+test|pytest|vitest|jest|cargo\s+test|go\s+test|rspec|phpunit|dotnet\s+test|gradle(w)?\s+test|mvn\s+test)(?=[\s;&|`)]|$)/;
const ECHO_PREFIX_RE = /^\s*(echo|printf)\b/;
const FAILURE_SIGNAL_RE =
  /AssertionError|Traceback|\b\d+\s+failed\b|\bFAIL(?:ED)?\b|BUILD FAILED|error TS/;

function extractExitCode(result: unknown): number | undefined {
  if (typeof result !== "object" || result === null) return undefined;
  const rec = result as Record<string, unknown>;
  for (const key of ["exitCode", "exit_code", "code"]) {
    const value = rec[key];
    if (typeof value === "number" && Number.isInteger(value)) return value;
  }
  return undefined;
}

function resultBlob(result: unknown): string {
  if (typeof result === "string") return result;
  try {
    return JSON.stringify(result) ?? "";
  } catch {
    return "";
  }
}

// ---------------------------------------------------------------------------
// 5. Gate de cierre
// ---------------------------------------------------------------------------

const RECEIPT_RE = /SUMMONAIKIT HARNESS RECEIPT/;
const RECEIPT_LABELS = ["Understand", "Implement", "Verify", "Review", "Close", "Retro"] as const;
const PAUSED_TOKEN = "SUMMONAIKIT HARNESS PAUSED";
const DELEGATED_TOKEN = "SUMMONAIKIT HARNESS DELEGATED - awaiting";
const VERIFY_SKIP_PROSE_RE =
  /skip de verificaci[oó]n|verificaci[oó]n omitida|verification skipped|verify[ -]?skip|no (se )?(corrieron|ejecutaron) (los )?tests/i;

function roleFallbackRegex(role: Role): RegExp {
  return new RegExp(`ROLE FALLBACK:\\s*${role}`, "i");
}

// ---------------------------------------------------------------------------
// 6. Confinamiento adversary
// ---------------------------------------------------------------------------

const ADVERSARY_AGENT_ID = "adversary";
const ABSOLUTE_PATH_RE = /^(?:[A-Za-z]:[\\/]|[\\/]|~)/;

// ---------------------------------------------------------------------------
// 7. Tracking de subagentes (+ canonicalRole en lib.ts)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Plugin entry
// ---------------------------------------------------------------------------

type Logger = {
  debug?: (message: string) => void;
  info: (message: string) => void;
  warn: (message: string) => void;
  error: (message: string) => void;
};

export default definePluginEntry({
  id: "summa-gate",
  name: "Summa Gate",
  description:
    "Port del harness summonaikit: merge-guard, sentinel -saikit, evidencia de verificación, gate de cierre y confinamiento de adversary.",
  register(api) {
    const log: Logger = api.logger;
    // sessionKeys que ya recibieron las standing rules en este proceso.
    const promptSeenSessions = new Set<string>();

    // -- 1. Merge-guard (siempre activo) ------------------------------------
    // 6.5c: pasa ctx.agentId — la mutacion GraphQL de merge y las rutas REST de merge de
    // api.github.com se permiten solo a implementer/ingenieria (orden del dueño en el brief, 6.5b);
    // main y el resto siguen bloqueados.
    api.on(
      "before_tool_call",
      (event, ctx) => {
        const command = typeof event.params?.command === "string" ? event.params.command : "";
        if (!command) return;
        const reason = mergeGuardVerdict(command, ctx.agentId);
        if (reason) return { block: true, blockReason: reason };
      },
      { matcher: ["exec"] },
    );

    // -- 8. Canal entre agentes: sessions_send de Claw que pierde la respuesta --
    api.on(
      "before_tool_call",
      (event, ctx) => {
        const reason = sessionsSendGuardVerdict(
          ctx.agentId,
          (event.params ?? {}) as SessionsSendParams,
          (ctx as { sessionKey?: string }).sessionKey,
        );
        if (reason) return { block: true, blockReason: reason };
      },
      { matcher: ["sessions_send"] },
    );

    // -- 6. Confinamiento adversary -----------------------------------------
    api.on("before_tool_call", (event, ctx) => {
      if (ctx.agentId !== ADVERSARY_AGENT_ID) return;
      const workspaceDir = (ctx as { workspaceDir?: string }).workspaceDir;

      if (WRITE_TOOLS.has(event.toolName)) {
        const target = extractPathParam(event.params ?? {});
        if (!target) return; // fail-open: sin path no bloqueamos
        if (!adversaryPathAllowed(target, workspaceDir)) {
          return {
            block: true,
            blockReason: `Confinamiento adversary (summa-gate): escritura fuera de zona permitida. El agente adversary solo puede escribir dentro de su workspace o en paths bajo .saikit/findings y .saikit/scratch. Destino: ${target}`,
          };
        }
        return;
      }

      if (event.toolName === "exec") {
        const command = typeof event.params?.command === "string" ? event.params.command : "";
        if (!command) return;
        // Los destinos RELATIVOS tambien se validan. Hasta 2026-09-16 esta rama
        // hacia `continue` sobre todo lo no absoluto, con el comentario
        // "relativos: dentro del workspace": eso es una suposicion, no un hecho.
        // `../../outside` es relativo y sale de la zona, asi que el adversary
        // podia escribir fuera con una redireccion y el guardia ni la miraba.
        // `adversaryPathAllowed` ya resuelve el relativo contra el workspace; el
        // error estaba en no llamarlo. Sin `workspaceDir` la funcion cae a su
        // regla vieja (relativo = permitido), asi que ese caso no cambia.
        // Ver `commandChangesCwd`: con un cambio de directorio en el comando,
        // un destino relativo puede aterrizar en cualquier parte y resolverlo
        // contra el workspace da un permiso falso.
        const cambiaCwd = commandChangesCwd(command);
        for (const target of redirectTargets(command)) {
          if (cambiaCwd && !ABSOLUTE_PATH_RE.test(target)) {
            return {
              block: true,
              blockReason: `Confinamiento adversary (summa-gate): el comando cambia de directorio, asi que un destino relativo no se puede ubicar; usa una ruta absoluta dentro de la zona permitida. Destino: ${target}`,
            };
          }
          if (!adversaryPathAllowed(target, workspaceDir)) {
            return {
              block: true,
              blockReason: `Confinamiento adversary (summa-gate): redirección fuera de zona permitida (solo workspace, .saikit/findings, .saikit/scratch). Destino: ${target}`,
            };
          }
        }
      }
    });

    // -- Diagnostic guard: tool-result guidance + per-run state -------------
    //
    // Placed AFTER the merge guard, sessions_send guard, and adversary
    // confinement, inside its own try/catch: if the host lacks
    // registerAgentToolResultMiddleware (or it throws), the three existing
    // protections stay registered. The catch logs only the fixed text plus
    // the error class, never the error message (it could carry tool output).
    //
    // Mode off registers nothing, restoring prior behavior. In observe and
    // enforce the middleware appends the same static guidance; only
    // before_agent_finalize (Task 5) may request a revision, and only in
    // enforce. For Codex native tools the host may observe without
    // re-injecting transformed content; reinjection is not claimed here.
    const diagnosticToolResult = async (event: unknown, ctx: unknown): Promise<unknown> => {
      const evt = ((event ?? {}) as ToolResultEventLike) ?? {};
      const c = ((ctx ?? {}) as ToolResultContextLike) ?? {};
      // runId comes ONLY from ctx (SDK AgentToolResultMiddlewareContext).
      // Event-carried runId values are ignored; sessionKey is never a
      // substitute. Without an exact non-empty runId: no guidance, no state.
      const runId =
        typeof c.runId === "string" && c.runId.length > 0 ? c.runId : undefined;
      if (!runId) return undefined;
      const observation = diagnosticObservationFromEvent(evt);
      if (!observation) return undefined;
      // The transform spreads evt.result into a new object: only safe for
      // real result objects. A primitive/array result would corrupt into
      // indexed keys, so contract violations fail open with no state change.
      if (!evt.result || typeof evt.result !== "object" || Array.isArray(evt.result)) {
        return undefined;
      }
      const runContext = (api as unknown as { runContext?: DiagnosticRunContext }).runContext;
      if (!runContext) return undefined;
      return enqueueDiagnosticUpdate(runId, async (): Promise<unknown> => {
        let prev: DiagnosticState | undefined;
        try {
          prev = asDiagnosticState(
            runContext.getRunContext({ runId, namespace: DIAGNOSTIC_NAMESPACE }),
          );
        } catch {
          prev = undefined;
        }
        const incident = classifyIncident(observation);
        const effective: IncidentId | undefined = prev?.incidentId ?? incident ?? undefined;
        // Unknown errors fail open: no guidance, no state write.
        if (!effective) return undefined;
        // The incident-classified call itself is the trigger, never a probe.
        const category =
          incident === undefined ? classifyCompletedProbe(effective, observation) : undefined;
        const next = reduceDiagnosticState(prev, effective, category);
        let stored = false;
        try {
          stored = runContext.setRunContext({ runId, namespace: DIAGNOSTIC_NAMESPACE, value: next }) !== false;
        } catch {
          stored = false;
        }
        if (!stored) {
          // Degraded counting, but the guidance below is still valid for
          // this step; the queue itself stays alive via enqueueDiagnosticUpdate.
          log.warn("summa-gate diagnostic: state write failed");
        }
        log.info(
          `summa-gate diagnostic: incident=${next.incidentId} ` +
            `completed=${next.completedCategories.length} revised=${next.revisionRequested}`,
        );
        const rawContent = (evt.result as { content?: unknown } | undefined)?.content;
        const content = Array.isArray(rawContent) ? rawContent : [];
        return {
          result: {
            ...((evt.result ?? {}) as Record<string, unknown>),
            content: [...content, { type: "text", text: buildDiagnosticContract(next) }],
          },
        };
      }).catch(() => undefined);
    };

    const diagnosticConfig = parseDiagnosticConfig(
      (api as unknown as { pluginConfig?: unknown }).pluginConfig,
    );
    if (diagnosticConfig.mode !== "off") {
      try {
        (
          api as unknown as {
            registerAgentToolResultMiddleware: (
              handler: (event: unknown) => unknown,
              opts: { runtimes: string[] },
            ) => unknown;
          }
        ).registerAgentToolResultMiddleware(diagnosticToolResult, {
          runtimes: ["openclaw", "codex"],
        });
        log.info(`summa-gate: diagnostic guard registered (mode=${diagnosticConfig.mode})`);
      } catch (err) {
        const ctor =
          err !== null && typeof err === "object"
            ? (err as { constructor?: { name?: unknown } }).constructor
            : undefined;
        const name = typeof ctor?.name === "string" && ctor.name ? ctor.name : "Error";
        log.warn(`summa-gate diagnostic: registration failed (${name})`);
      }
    }

    // -- 2/3. Sentinel + standing rules -------------------------------------
    api.on("before_prompt_build", (event, ctx) => {
      const sessionKey = ctx.sessionKey ?? ctx.sessionId ?? "unknown";
      const parts: string[] = [];

      if (!promptSeenSessions.has(sessionKey)) {
        promptSeenSessions.add(sessionKey);
        parts.push(STANDING_RULES);
      }

      const prompt = typeof event.prompt === "string" ? event.prompt : "";
      const match = SENTINEL_RE.exec(prompt);

      if (match) {
        const suffix = match[1];
        const lane: Lane = suffix === "fast" ? "fast" : "full";
        const autopilot = suffix === "autopilot";
        if (suffix && suffix !== "fast" && suffix !== "autopilot") {
          log.info(`summa-gate: sufijo desconocido "-saikit:${suffix}"; lane=full`);
        }
        sweepStaleState(Date.now());
        saveState(sessionKey, {
          taskHash: sha256(prompt),
          armedAt: Date.now(),
          cycle: 0,
          implemented: false,
          verified: false,
          lane,
          autopilot,
          agentsSeen: [],
        });
        parts.push(buildContract(lane, autopilot));
        log.info(`summa-gate: sesión ${sessionKey} armada (lane=${lane}${autopilot ? ", autopilot" : ""})`);
      } else {
        // Prompt sin sentinel: si la sesión estaba armada, se desarma.
        deleteState(sessionKey);
      }

      if (parts.length > 0) return { appendContext: parts.join("\n\n") };
    });

    // -- 4. Evidencia post-tool ----------------------------------------------
    api.on("after_tool_call", (event, ctx) => {
      const sessionKey = ctx.sessionKey;
      if (!sessionKey) return;
      const state = loadState(sessionKey);
      if (!state) return; // solo sesiones armadas

      let dirty = false;

      if (WRITE_TOOLS.has(event.toolName)) {
        const target = extractPathParam(event.params ?? {});
        if (!target || !isDocOrLock(target)) {
          if (!state.implemented) {
            state.implemented = true;
            dirty = true;
          }
        }
      }

      if (event.toolName === "exec") {
        const command = typeof event.params?.command === "string" ? event.params.command : "";
        if (
          command &&
          TEST_RUNNER_RE.test(command) &&
          !ECHO_PREFIX_RE.test(command) &&
          !event.error
        ) {
          const exitCode = extractExitCode(event.result);
          const failed =
            (exitCode !== undefined && exitCode !== 0) ||
            FAILURE_SIGNAL_RE.test(resultBlob(event.result));
          if (!failed && !state.verified) {
            state.verified = true;
            dirty = true;
          }
        }
      }

      if (dirty) saveState(sessionKey, state);
    });

    // -- 5. Gate de cierre ----------------------------------------------------
    //
    // ALCANCE REAL (Fase 1 / 1.2 - 2026-09-12, PR Fase1.2):
    //   El `revise` retornado por este handler SE DESCARTA SILENCIOSAMENTE
    //   cuando el turno tuvo efecto lateral (`hadDeterministicSideEffect`).
    //   Eso lo hace el runtime de OpenClaw, no este plugin. En la practica,
    //   este gate solo bloquea cierres en turnos donde el agente NO emitio
    //   herramientas mutantes (exec con side effect, write, sessions_send /
    //   sessions_spawn aceptado, cron add, etc.).
    //
    // Cita del runtime instalado (OpenClaw 2026.9.4, host del gateway Mac):
    //   builtin-openclaw-B-H-7lKk.mjs, lineas 13039-13042
    //   sha256: 0a8c813e535c92d03f69bc58381518ba0e6ac6e46f3adda54138c5f668340ea8
    //
    //     if (event.hadDeterministicSideEffect) {
    //       log$6.warn(`before_agent_finalize requested revision after potential side effects; finalizing runId=... sessionId=...`);
    //       return;
    //     }
    //
    // Evidencia empirica (Fase 1 / 1.1, PR #18): en 5 corridas de
    // `openclaw logs` en la ventana del 2026-09-12T11:05-T12:05 (~50 min),
    // cero `summa-gate: revise solicitado` y cero `before_agent_finalize requested revision after potential side effects`. Conclusion: sin
    // datos para mover la exigencia a `before_prompt_build`; se documenta
    // el alcance real y queda para Fase 2 / 2.2 como dato de entrada.
    //
    // Lo que NO cubre este gate hoy:
    //   - Turnos donde el agente trabajo (exec, write, sessions_spawn,
    //     cron add): el revise que este handler emite SE DESCARTA en runtime.
    //   - Turnos donde faltaba un item del recibo y el agente ya cerro con
    //     side effects: la falta se pierde silenciosamente (sin log de WARN).
    //
    // Lo que SI cubre:
    //   - Turnos de conversacion pura sin herramientas mutantes.
    //   - Turnos donde el agente declaro PAUSED / DELEGATED (escotillas).
    //
    api.on("before_agent_finalize", (event, ctx) => {
      const sessionKey = ctx.sessionKey ?? event.sessionKey;
      if (!sessionKey) return;
      const state = loadState(sessionKey);
      if (!state) return; // solo sesiones armadas

      const text = event.lastAssistantMessage;
      if (typeof text !== "string" || text.length === 0) {
        log.warn("summa-gate: before_agent_finalize sin lastAssistantMessage; fail-open");
        return;
      }

      // Escotillas: cierre permitido, la sesión SIGUE armada.
      if (text.includes(PAUSED_TOKEN) || text.includes(DELEGATED_TOKEN)) return;

      const missing: string[] = [];

      if (!RECEIPT_RE.test(text)) {
        missing.push("el bloque `SUMMONAIKIT HARNESS RECEIPT`");
      }
      for (const label of RECEIPT_LABELS) {
        if (!labelRegex(label).test(text)) {
          missing.push(`la etiqueta \`${label}:\``);
        }
      }

      if (!state.verified && !VERIFY_SKIP_PROSE_RE.test(text)) {
        missing.push(
          "evidencia de verificación real (no se detectó una corrida de tests exitosa en este turno) o una declaración explícita de skip de verificación con su razón",
        );
      }

      if (state.lane === "full" && state.agentsSeen.length > 0) {
        const idxImplementer = state.agentsSeen.indexOf("implementer");
        for (const role of ["verifier", "reviewer"] as const) {
          const idx = state.agentsSeen.indexOf(role);
          if (idx === -1) continue;
          if (idxImplementer === -1) {
            if (!roleFallbackRegex("implementer").test(text)) {
              missing.push(
                `orden de subagentes: corrió ${role} sin implementer previo; declará \`ROLE FALLBACK: IMPLEMENTER\` en el recibo si el rol fue cubierto por el agente principal`,
              );
            }
          } else if (idxImplementer > idx) {
            missing.push(
              `orden de subagentes: implementer apareció después de ${role}; en lane=full implementer debe correr antes (o declarar ROLE FALLBACK)`,
            );
          }
        }
      }

      if (missing.length === 0) {
        deleteState(sessionKey);
        log.info(`summa-gate: cierre limpio, sesión ${sessionKey} desarmada`);
        return;
      }

      const reason = [
        "Cierre rechazado por summa-gate. Falta para cerrar la ceremonia:",
        ...missing.map((item) => `- ${item}`),
        "",
        "Rehacé tu respuesta final incluyendo el bloque SUMMONAIKIT HARNESS RECEIPT con las 6 etiquetas (Understand, Implement, Verify, Review, Close, Retro), cada una en su línea. Si necesitás una aclaración usá `SUMMONAIKIT HARNESS PAUSED`; si esperás un subagente, `SUMMONAIKIT HARNESS DELEGATED - awaiting <rol>`.",
      ].join("\n");

      log.info(`summa-gate: revise solicitado (${missing.length} faltantes)`);
      return {
        action: "revise" as const,
        reason,
        retry: {
          instruction: reason,
          idempotencyKey: "summa-gate-receipt",
          maxAttempts: 2,
        },
      };
    });

    // -- Diagnostic guard: best-effort same-run revision ----------------------
    //
    // DIAGNOSTIC REVISE SCOPE (kimi cross-review): this revise is best-effort
    // like the receipt gate above. The runtime silently discards
    // `action: "revise"` after deterministic side effects
    // (`hadDeterministicSideEffect`, same citation as the receipt gate), so
    // an enforce revise may not run in turns whose incident trigger counts
    // as one. If BOTH handlers revise the same finalize, the host merges
    // them (runtime `mergeBeforeAgentFinalize`: reasons concatenated, first
    // handler's retry wins, ours kept as candidate) — never a double pass.
    // In every non-revise case the final is delivered normally.
    //
    // Observe logs the symbolic decision and never revises. Enforce may
    // request exactly one same-run revision (maxAttempts 1, idempotency key
    // bound to this runId) when all of these hold: a recognized incident is
    // tracked for the exact runId, the final text is a task-level incapacity
    // conclusion, fewer than three categories completed, and no revision was
    // requested yet. Anything else (missing/ambiguous runId, cron/heartbeat
    // origin, completed investigation, failed state write) delivers the
    // final normally. This handler never blocks, never terminates, never
    // schedules, and never continues another run: its only non-empty return
    // is the single same-run revise below. State transitions are recorded
    // by the tool-result middleware; the decision is read here, inside
    // before_agent_finalize, while run context is still available.
    if (diagnosticConfig.mode !== "off") {
      api.on("before_agent_finalize", async (event, ctx) => {
        const evt = ((event ?? {}) as {
          runId?: unknown;
          lastAssistantMessage?: unknown;
        }) ?? {};
        const c = ((ctx ?? {}) as {
          runId?: unknown;
          trigger?: unknown;
        }) ?? {};
        const eventRunId =
          typeof evt.runId === "string" && evt.runId.length > 0 ? evt.runId : undefined;
        const ctxRunId =
          typeof c.runId === "string" && c.runId.length > 0 ? c.runId : undefined;
        // Exact runId required; missing or ambiguous correlation fails open.
        if (!eventRunId && !ctxRunId) return undefined;
        if (eventRunId && ctxRunId && eventRunId !== ctxRunId) return undefined;
        const runId = (eventRunId ?? ctxRunId) as string;
        // Automation origins receive guidance only, never a revision: a new
        // model step here could repeat business actions. The SDK-real signal
        // is ctx.trigger (mirrors bundled memory-core); inputProvenance.kind
        // can never be cron/heartbeat (SDK allows only external_user,
        // inter_session, internal_system), so it is not consulted.
        const trigger = typeof c.trigger === "string" ? c.trigger : undefined;
        if (trigger === "cron" || trigger === "heartbeat") return undefined;
        const runContext = (api as unknown as { runContext?: DiagnosticRunContext }).runContext;
        if (!runContext) return undefined;
        return enqueueDiagnosticUpdate(runId, async (): Promise<unknown> => {
          let state: DiagnosticState | undefined;
          try {
            state = asDiagnosticState(
              runContext.getRunContext({ runId, namespace: DIAGNOSTIC_NAMESPACE }),
            );
          } catch {
            state = undefined;
          }
          if (!state) return undefined;
          // Final text is inspected transiently and discarded: never stored,
          // never logged, never added to any record.
          const text =
            typeof evt.lastAssistantMessage === "string" ? evt.lastAssistantMessage : "";
          const incapacity = text ? isTaskLevelIncapacity(text) : false;
          log.info(
            `summa-gate diagnostic finalize: incident=${state.incidentId} ` +
              `completed=${state.completedCategories.length} ` +
              `revised=${state.revisionRequested} incapacity=${incapacity}`,
          );
          if (diagnosticConfig.mode !== "enforce") return undefined;
          if (!shouldRequestRevision(state, text)) return undefined;
          const next: DiagnosticState = {
            version: 1,
            incidentId: state.incidentId,
            requiredCategories: [...state.requiredCategories],
            completedCategories: [...state.completedCategories],
            revisionRequested: true,
          };
          let stored = false;
          try {
            stored =
              runContext.setRunContext({ runId, namespace: DIAGNOSTIC_NAMESPACE, value: next }) !== false;
          } catch {
            stored = false;
          }
          if (!stored) {
            // Fail open: deliver the final normally.
            return undefined;
          }
          return {
            action: "revise" as const,
            reason:
              "A recognized first-path failure was converted into a task-level incapacity conclusion before three distinct diagnostic categories completed.",
            retry: {
              instruction: buildDiagnosticContract(next),
              idempotencyKey: `summa-diagnostic:${runId}`,
              maxAttempts: 1,
            },
          };
        }).catch(() => undefined);
      });
    }

    // -- 7. Tracking de subagentes -------------------------------------------
    api.on("subagent_spawned", (event, ctx) => {
      const sessionKey = ctx.requesterSessionKey;
      if (!sessionKey) return;
      const state = loadState(sessionKey);
      if (!state) return;
      const role = canonicalRole(`${event.agentId ?? ""} ${event.label ?? ""}`);
      if (!role) return;
      if (!state.agentsSeen.includes(role)) {
        state.agentsSeen.push(role);
        saveState(sessionKey, state);
        log.info(`summa-gate: subagente registrado rol=${role} sesión=${sessionKey}`);
      }
    });

    // Limpieza de memoria al cerrar sesión (el estado en disco lo barre el TTL).
    // -- 9. Observador de rendiciones ---------------------------------------
    //
    // ALCANCE (Fase 2 / 2.1 - 2026-09-12, PR Fase2.1):
    //   Observador, NO candado. El handler de agent_end escribe UNA LINEA POR CADA
    //   turno en ~/.openclaw/summa-gate/rendiciones.jsonl: la metrica es una tasa
    //   (detecciones/turnos) y sin el denominador el archivo no responde la pregunta
    //   para la que existe. `detected` marca los turnos con `nonReplaySafeCount === 0`
    //   y texto con forma de incapacidad — esos son los que un humano revisa, y son los
    //   unicos que llevan `textPreview`, para que el medidor no sea un archivo de
    //   transcripciones. (Este comentario decia la conducta filtrada, que era falsa:
    //   corregido tras el cross-review de codex del 2026-09-12, que lo cazo aunque el
    //   docstring de observer.ts ya estaba arreglado.) No
    //   modifica el turno: agent_end corre via `runVoidHook` en el runtime, que
    //   descarta el valor de retorno (cita: hook-runner-global-BhDCl4qm.mjs,
    //   runAgentEnd en linea 1003 llama runVoidHook linea 778-796; el
    //   comentario oficial del runtime en linea 996-1001 dice "Allows plugins
    //   to analyze completed conversations. Runs handlers in parallel.").
    //   El timeout default por hook es 3e4 ms (DEFAULT_VOID_HOOK_TIMEOUT_MS_BY_HOOK
    //   linea 452). Por eso el handler hace append sincrono y sale: nada de
    //   red, nada de leer archivos grandes.
    //
    //   Si el handler supera el timeout, el runtime lo corta y registra warn;
    //   el jsonl gana una linea de menos ese turno, nunca se rompe el gate
    //   de recibo ni el resto del flujo del agente.
    api.on("agent_end", (event, ctx) => {
      try {
        const sessionKey =
          (ctx as { sessionKey?: string }).sessionKey ??
          (event as { sessionKey?: string }).sessionKey ??
          "unknown";
        const agent = (ctx as { agentId?: string }).agentId;
        const inputProvenanceKind = (ctx as { inputProvenance?: { kind?: string } })
          .inputProvenance?.kind;
        const messages = (event as { messages?: unknown }).messages;
        // Un agent_end sin ningun mensaje del asistente es un evento de ciclo de vida, no un
        // turno. Registrarlo inflaba el denominador (13 de 80 en los datos vivos del
        // 2026-09-12) y por lo tanto bajaba artificialmente la tasa que esto mide.
        if (!isTurnRecordable(messages as Parameters<typeof isTurnRecordable>[0])) return;
        const record = buildRecord(
          Date.now(),
          sessionKey,
          agent,
          inputProvenanceKind,
          messages as Parameters<typeof buildRecord>[4],
        );
        writeRecord(record);
      } catch (err) {
        // Fail-open: a broken observer must never block the turn. The runtime
        // would still log the hook failure on its own; we add one warn so an
        // operator scanning summa-gate logs can correlate.
        log.warn(`summa-gate observer: agent_end failed: ${String(err)}`);
      }
    });

    api.on("session_end", (event) => {
      if (event.sessionKey) promptSeenSessions.delete(event.sessionKey);
    });

    log.info("summa-gate: plugin registrado (merge-guard activo, sentinel -saikit listo)");
  },
});
