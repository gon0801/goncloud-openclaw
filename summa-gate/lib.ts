/**
 * Funciones puras de summa-gate (exportadas para tests sin cargar el plugin).
 */

import { isAbsolute, resolve, sep } from "node:path";

export type Role = "implementer" | "verifier" | "reviewer" | "adversary";

const GH_PR_MERGE_RE = /(?:^|[^A-Za-z0-9])gh\s+pr\s+merge(?:\s|$)/;
const GH_API_RE = /(?:^|[^A-Za-z0-9])gh\s+api(?:\s|$)/;
const GH_API_MERGE_PATH_RE = /\/merge(?:[\s/'"`]|$)/;
const GIT_PUSH_RE = /(?:^|[^A-Za-z0-9])git\s+push\b/;
const GIT_PUSH_PROTECTED_RE =
  /push\s+.*(\sorigin\s+[+:]?(master|main)|\sHEAD:(master|main)|refs\/heads\/(master|main)|[A-Za-z0-9._/-]+:(master|main)|\s[+:]?(master|main))(\s|$)/;

export function mergeGuardVerdict(command: string): string | undefined {
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

// Canal entre agentes (2026-09-11): la respuesta de un sessions_send regresa por un camino que muere en
// silencio cuando el turno que despacho ya cerro, y sin timeoutSeconds la espera es de solo 30 s.
// Pasan: esperas explicitas, envios a sesiones de main y fire-and-forget que piden reporte de vuelta.
const SEND_RETURN_ADDRESS_RE = /agent:main:[A-Za-z0-9._:-]+/;

export type SessionsSendParams = {
  agentId?: unknown;
  sessionKey?: unknown;
  timeoutSeconds?: unknown;
  message?: unknown;
};

function sendTargetAgent(params: SessionsSendParams): string | undefined {
  if (typeof params.agentId === "string" && params.agentId) return params.agentId;
  if (typeof params.sessionKey === "string") return /^agent:([^:]+):/.exec(params.sessionKey)?.[1];
  return undefined;
}

function sendTimeout(params: SessionsSendParams): number | undefined {
  const raw = params.timeoutSeconds;
  if (typeof raw === "number") return raw;
  if (typeof raw === "string" && /^\d+$/.test(raw)) return Number(raw);
  return undefined;
}

export function sessionsSendGuardVerdict(
  requesterAgentId: string | undefined,
  params: SessionsSendParams,
): string | undefined {
  if (requesterAgentId !== "main") return undefined;
  if (sendTargetAgent(params) === "main") return undefined;
  const timeout = sendTimeout(params);
  if (timeout !== undefined && timeout > 0) return undefined;
  const message = typeof params.message === "string" ? params.message : "";
  if (timeout === 0 && SEND_RETURN_ADDRESS_RE.test(message)) return undefined;
  return (
    "Envio bloqueado por summa-gate: un sessions_send de Claw a otro agente sin espera explicita pierde la respuesta " +
    "si el agente tarda mas de lo que esperas (sin timeoutSeconds la espera es de 30 s; 2026-09-11: 41 respuestas perdidas). " +
    "Usa una de estas: (1) tarea nueva: sessions_spawn agentId=<agente> mode=run con todo el contexto en task; el resultado te llega solo. " +
    "(2) seguir un trabajo en la sesion del agente: timeoutSeconds 0 y en el mensaje \"Cuando termines, reportame con sessions_send " +
    "a sessionKey <tu sesion, p. ej. agent:main:main>, timeoutSeconds 0\". (3) pregunta rapida que vas a esperar: timeoutSeconds explicito (p. ej. 120)."
  );
}

const DOC_RE = /\.(md|mdx|markdown|rst|txt|adoc|org)$/i;
const LOCKFILE_RE =
  /(^|[/\\])(package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|cargo\.lock|poetry\.lock|composer\.lock|gemfile\.lock|go\.sum|pubspec\.lock)$/i;

export function isDocOrLock(path: string): boolean {
  return DOC_RE.test(path) || LOCKFILE_RE.test(path);
}

export function labelRegex(label: string): RegExp {
  return new RegExp(`(^|\\n)[ \\t]*${label}:`);
}

const ADVERSARY_ZONE_RE = /(?:^|[/\\])\.saikit[/\\](findings|scratch)(?:[/\\]|$)/;
const ABSOLUTE_PATH_RE = /^(?:[A-Za-z]:[\\/]|[\\/]|~)/;
const REDIRECT_RE = /(?:^|[\s;|&])(?:\d?>>?|\btee)\s*("([^"]*)"|'([^']*)'|(\S+))/g;
const REDIRECT_ALLOWLIST = new Set(["/dev/null", "/dev/stdout", "/dev/stderr", "NUL"]);

export function adversaryPathAllowed(target: string, workspaceDir?: string): boolean {
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
  return !ABSOLUTE_PATH_RE.test(target);
}

export function redirectTargets(command: string): string[] {
  const targets: string[] = [];
  for (const match of command.matchAll(REDIRECT_RE)) {
    const target = match[2] ?? match[3] ?? match[4];
    if (target && !REDIRECT_ALLOWLIST.has(target)) targets.push(target);
  }
  return targets;
}

/**
 * Map label/agent text to a pipeline role.
 * implementer/engineer/fix must be checked before verif|test|qa so labels like
 * "implementer: fix failing tests" classify as implementer, not verifier.
 * Word boundaries keep substrings like "prefix" / "fixture" from matching "fix".
 */
export function canonicalRole(text: string): Role | undefined {
  const t = text.toLowerCase();
  if (/\badversar(?:y|ial)?\b|\bcritic\b/.test(t)) return "adversary";
  if (/\breview(?:er|s|ing)?\b|\baudit(?:or|s|ing)?\b/.test(t)) return "reviewer";
  if (
    /\bimplement(?:er|ers|ation|ing)?\b|\bengineer(?:s|ing)?\b|\bcoder(?:s)?\b|\bfix(?:es|ing|ed)?\b/.test(
      t,
    )
  ) {
    return "implementer";
  }
  if (/\bverif(?:y|ies|ied|ying|ier|ication)?\b|\btests?\b|\bqa\b/.test(t)) {
    return "verifier";
  }
  return undefined;
}
