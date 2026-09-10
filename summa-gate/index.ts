/**
 * summa-gate — port nativo (OpenClaw plugin) del harness bash `summonaikit`.
 *
 * Features:
 *  1. merge-guard (siempre activo): bloquea `gh pr merge`, `gh api …/merge`
 *     y `git push` a master/main en `before_tool_call` (matcher exec).
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
import { isAbsolute, join, resolve, sep } from "node:path";

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

// ---------------------------------------------------------------------------
// Estado persistido por sesión
// ---------------------------------------------------------------------------

type Lane = "fast" | "full";
type Role = "implementer" | "verifier" | "reviewer" | "adversary";

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
// 1. Merge-guard
// ---------------------------------------------------------------------------

const GH_PR_MERGE_RE = /(?:^|[^A-Za-z0-9])gh\s+pr\s+merge(?:\s|$)/;
const GH_API_RE = /(?:^|[^A-Za-z0-9])gh\s+api(?:\s|$)/;
const GH_API_MERGE_PATH_RE = /\/merge(?:[\s/'"`]|$)/;
const GIT_PUSH_RE = /(?:^|[^A-Za-z0-9])git\s+push\b/;
// Port directo del regex del harness bash: destino master|main en cualquier forma.
const GIT_PUSH_PROTECTED_RE =
  /push\s+.*(\sorigin\s+[+:]?(master|main)|\sHEAD:(master|main)|refs\/heads\/(master|main)|[A-Za-z0-9._/-]+:(master|main)|\s[+:]?(master|main))(\s|$)/;

function mergeGuardVerdict(command: string): string | undefined {
  if (GH_PR_MERGE_RE.test(command)) {
    return "Merge bloqueado por summa-gate: `gh pr merge` está prohibido desde el agente (también encadenado con &&/;). El merge lo hace el operador o el flujo autorizado del repo.";
  }
  if (GH_API_RE.test(command) && GH_API_MERGE_PATH_RE.test(command)) {
    return "Merge bloqueado por summa-gate: `gh api …/merge` está prohibido desde el agente. El merge lo hace el operador o el flujo autorizado del repo.";
  }
  if (GIT_PUSH_RE.test(command) && GIT_PUSH_PROTECTED_RE.test(command)) {
    return "Push bloqueado por summa-gate: `git push` a master/main está prohibido desde el agente (incluye origin master, +master, HEAD:main, refs/heads/main y delete-ref :main).";
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// 2/3. Sentinel, armado y standing rules
// ---------------------------------------------------------------------------

const SENTINEL_RE = /(?:^|[^A-Za-z0-9])-saikit(?::([a-z]+))?(?![A-Za-z0-9])/;

const STANDING_RULES = `[summa-gate] Reglas permanentes de esta sesión:
1. La batería completa de pruebas se corre UNA sola vez por tarea, idealmente en CI/PR; no la repitas localmente si el mismo SHA ya fue validado por commit, push o CI.
2. Creá las ramas desde origin/<default> actualizado y verificá el punto de partida con git log antes de trabajar.
3. No te bloquees esperando jobs en background: revisá primero su estado y seguí con otra cosa.
4. Antes de re-intentar una acción que falló, diagnosticá la causa raíz; no repitas a ciegas.`;

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
- No uses gh pr merge, gh api …/merge ni git push a master/main: el
  merge-guard de este plugin los bloquea siempre, con o sin sentinel.
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

const DOC_RE = /\.(md|mdx|markdown|rst|txt|adoc|org)$/i;
const LOCKFILE_RE =
  /(^|[/\\])(package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|cargo\.lock|poetry\.lock|composer\.lock|gemfile\.lock|go\.sum|pubspec\.lock)$/i;

function isDocOrLock(path: string): boolean {
  return DOC_RE.test(path) || LOCKFILE_RE.test(path);
}

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

function labelRegex(label: string): RegExp {
  return new RegExp(`(^|\\n)[ \\t]*${label}:`);
}

function roleFallbackRegex(role: Role): RegExp {
  return new RegExp(`ROLE FALLBACK:\\s*${role}`, "i");
}

// ---------------------------------------------------------------------------
// 6. Confinamiento adversary
// ---------------------------------------------------------------------------

const ADVERSARY_AGENT_ID = "adversary";
const ADVERSARY_ZONE_RE = /(?:^|[/\\])\.saikit[/\\](findings|scratch)(?:[/\\]|$)/;
const ABSOLUTE_PATH_RE = /^(?:[A-Za-z]:[\\/]|[\\/]|~)/;
// Redirecciones obvias: `>`, `>>`, `2>`, `tee <target>`. Best-effort.
const REDIRECT_RE = /(?:^|[\s;|&])(?:\d?>>?|\btee)\s*("([^"]*)"|'([^']*)'|(\S+))/g;
const REDIRECT_ALLOWLIST = new Set(["/dev/null", "/dev/stdout", "/dev/stderr", "NUL"]);

function normalizeSlashes(p: string): string {
  return p.replace(/\\/g, "/");
}

function isInsideDir(target: string, dir: string): boolean {
  const rel = resolve(dir, ".") ;
  const abs = resolve(dir, target);
  return abs === rel || abs.startsWith(rel + sep);
}

function adversaryPathAllowed(target: string, workspaceDir?: string): boolean {
  if (ADVERSARY_ZONE_RE.test(target)) return true;
  if (workspaceDir) {
    try {
      const abs = isAbsolute(target) ? resolve(target) : resolve(workspaceDir, target);
      const root = resolve(workspaceDir);
      if (abs === root || abs.startsWith(root + sep)) return true;
    } catch {
      // fallthrough: fail-open más abajo
    }
    return false;
  }
  // Sin workspace del host: paths relativos se asumen dentro del workspace
  // (mismo criterio best-effort del harness bash); absolutos fuera de zona, no.
  return !ABSOLUTE_PATH_RE.test(target);
}

function redirectTargets(command: string): string[] {
  const targets: string[] = [];
  for (const match of command.matchAll(REDIRECT_RE)) {
    const target = match[2] ?? match[3] ?? match[4];
    if (target && !REDIRECT_ALLOWLIST.has(target)) targets.push(target);
  }
  return targets;
}

// ---------------------------------------------------------------------------
// 7. Tracking de subagentes
// ---------------------------------------------------------------------------

function canonicalRole(text: string): Role | undefined {
  const t = text.toLowerCase();
  if (/review|audit/.test(t)) return "reviewer";
  if (/verif|test|qa/.test(t)) return "verifier";
  if (/adversar|critic/.test(t)) return "adversary";
  if (/implement|engineer|coder|fix/.test(t)) return "implementer";
  return undefined;
}

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
    api.on(
      "before_tool_call",
      (event) => {
        const command = typeof event.params?.command === "string" ? event.params.command : "";
        if (!command) return;
        const reason = mergeGuardVerdict(command);
        if (reason) return { block: true, blockReason: reason };
      },
      { matcher: ["exec"] },
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
        for (const target of redirectTargets(command)) {
          if (!ABSOLUTE_PATH_RE.test(target)) continue; // relativos: dentro del workspace
          if (!adversaryPathAllowed(target, workspaceDir)) {
            return {
              block: true,
              blockReason: `Confinamiento adversary (summa-gate): redirección a path absoluto fuera de zona permitida (solo workspace, .saikit/findings, .saikit/scratch). Destino: ${target}`,
            };
          }
        }
      }
    });

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
    api.on("session_end", (event) => {
      if (event.sessionKey) promptSeenSessions.delete(event.sessionKey);
    });

    log.info("summa-gate: plugin registrado (merge-guard activo, sentinel -saikit listo)");
  },
});
