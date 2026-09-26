/**
 * Funciones puras de summa-gate (exportadas para tests sin cargar el plugin).
 */

import { isAbsolute, resolve, sep } from "node:path";

export type Role = "implementer" | "verifier" | "reviewer" | "adversary";

// Canal entre agentes (2026-09-11): la respuesta de un sessions_send regresa por un camino que muere en
// silencio cuando el turno que despacho ya cerro, y ninguna espera lo arregla (30 s explicitos = el
// default; el agente puede tardar mas que cualquier espera). Por eso las esperas no abren el candado.
// Pasan: envios a sesiones de main, avisos marcados que no esperan respuesta y encargos que llevan la
// etiqueta exacta de reporte de vuelta con la sessionKey de quien despacha (verificado en vivo el 09-11).
// La etiqueta es literal a proposito: buscar "sessions_send" y la sessionKey sueltas dejaba pasar un
// texto que solo las mencionaba, incluso negando el reporte (revision cruzada grok, 09-11).
export const SEND_NOTICE_MARKER = "[AVISO SIN RESPUESTA]";
export const SEND_RETURN_TAG = "[REPORTE DE VUELTA:";

export type SessionsSendParams = {
  agentId?: unknown;
  sessionKey?: unknown;
  session_key?: unknown;
  label?: unknown;
  timeoutSeconds?: unknown;
  message?: unknown;
};

function normalized(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim().toLowerCase() : undefined;
}

/** Destino como lo resuelve la herramienta: sessionKey (o session_key), luego label, luego agentId. */
function sendTargetsMain(params: SessionsSendParams): boolean {
  const key = normalized(params.sessionKey) ?? normalized(params.session_key);
  if (key) return key === "main" || key.startsWith("agent:main:");
  if (normalized(params.label)) return false;
  return normalized(params.agentId) === "main";
}

export function sessionsSendGuardVerdict(
  requesterAgentId: string | undefined,
  params: SessionsSendParams,
  requesterSessionKey?: string,
): string | undefined {
  if (normalized(requesterAgentId) !== "main") return undefined;
  if (sendTargetsMain(params)) return undefined;
  const message = typeof params.message === "string" ? params.message : "";
  if (message.trimStart().toUpperCase().startsWith(SEND_NOTICE_MARKER)) return undefined;
  if (requesterSessionKey) {
    const expectedTag = `${SEND_RETURN_TAG} ${requesterSessionKey}]`.toUpperCase();
    if (message.toUpperCase().includes(expectedTag)) return undefined;
  }
  const returnKey = requesterSessionKey ?? "agent:main:main";
  return (
    "Envio bloqueado por summa-gate: la respuesta de un sessions_send de Claw a otro agente se pierde si el agente tarda " +
    "mas que la espera, y ninguna espera lo evita (2026-09-11: 41 respuestas perdidas). Usa una de estas: " +
    "(1) tarea o pregunta: sessions_spawn agentId=<agente> mode=run con todo el contexto en task; el resultado te llega solo como turno nuevo. " +
    `(2) seguir un trabajo en la sesion del agente: empieza el mensaje con la etiqueta exacta "${SEND_RETURN_TAG} ${returnKey}]" y pidele ahi que te reporte con sessions_send al terminar (timeoutSeconds 0); mencionar sessions_send en el texto no abre nada. ` +
    `(3) aviso que no necesita respuesta: empieza el mensaje con ${SEND_NOTICE_MARKER}.`
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

// Un comando que cambia de directorio invalida la resolucion estatica de
// cualquier destino RELATIVO: el shell corre el `cd` antes de abrir la
// redireccion, asi que `cd .. && printf x > outside` escribe en el padre aunque
// `outside` parezca del workspace. Medido 2026-09-16 al cerrar el escape por
// rutas relativas: el primer arreglo dejaba pasar justo esta forma.
// No se intenta seguir el `cd` para deducir el destino real: eso es interpretar
// shell, y el guardia es lexico por diseño. Se bloquea y se declara.
const CWD_CHANGE_RE = /(?:^|[\s;|&(])(?:cd|pushd|popd)(?:\s|$)/;

export function commandChangesCwd(command: string): boolean {
  return CWD_CHANGE_RE.test(command);
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
