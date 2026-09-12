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

// Declararse incapaz sin intentar (2026-09-12): ingenieria le dijo a David "Tipear dentro de
// ttys001 desde aca - no hay skill instalada para eso" sin correr un solo comando. Los mismos
// osascript que no intento devolvieron despues la app al frente, 10 ventanas de Terminal, y una
// ventana nueva donde se escribio y ejecuto un comando. Cero bloqueos de permisos. Mismo patron
// que costo la corrida de las 7:00 del 2026-09-11 en operaciones.
//
// El discriminador es "¿lo intentaste?", NO "¿que concluiste?": quien corre el comando, falla y
// reporta el error textual pasa limpio. Solo se rechaza la incapacidad declarada con cero exec.
//
// Las negativas por CRITERIO no se tocan: el 2026-09-11 Claw se nego a reiniciar el gateway
// ("es accion del propietario") y tenia razon. Ese caso pasa aunque no haya corrido nada.

/** Incapacidad TECNICA: dice que no se puede por falta de herramienta o capacidad. */
const INCAPACITY_RE =
  /no hay (?:ninguna |una )?(?:skill|herramienta)|no (?:tengo|existe) (?:esa |la |una |ninguna )?(?:skill|herramienta|capacidad)|sin (?:skill|herramienta) (?:instalada|disponible)|no (?:hay|tengo) (?:forma|manera|modo) de|no puedo (?:hacerlo|ejecutar|correr|tipear|escribir|controlar|acceder|abrir|leer)|no (?:es|resulta) posible (?:hacerlo|ejecutar|correr)|no tool (?:is )?(?:installed|available) for|there is no (?:skill|tool)/i;

/** Negativa por CRITERIO o por permiso: legitima, no se bloquea aunque no haya corrido nada. */
const JUDGMENT_REFUSAL_RE =
  /no voy a\b|me niego\b|accion del (?:propietario|dueno|dueño)|del (?:propietario|dueno|dueño)\b|requiere (?:tu |su )?autoriza|sin (?:tu |su )?autoriza|lo decide (?:david|el (?:propietario|dueno|dueño))|por seguridad\b|destructiv|irreversible|no me corresponde|permission denied|approval cannot safely bind/i;

export function blockedWithoutTryingVerdict(
  text: unknown,
  execCount: number,
): string | undefined {
  if (execCount > 0) return undefined; // lo intento: cualquier conclusion es suya
  if (typeof text !== "string" || text.length === 0) return undefined; // fail-open
  if (JUDGMENT_REFUSAL_RE.test(text)) return undefined; // negativa por criterio, no por incapacidad
  if (!INCAPACITY_RE.test(text)) return undefined;
  return (
    "Cierre rechazado por summa-gate: estas declarando que no se puede sin haber corrido un solo " +
    "comando en este turno (cero llamadas a exec). Intenta el comando real una vez antes de " +
    "concluir. Si falla, reporta el error textual: eso si es un bloqueo, y pasa. " +
    "Que no exista una skill con el nombre de la tarea no significa que la capacidad no exista: " +
    "las capacidades viven en exec. En la Mac, exec host=node mas osascript maneja la interfaz " +
    "grafica (app al frente, ventanas de Terminal, abrir una ventana y ejecutar dentro). " +
    "Si tu negativa es por criterio y no por incapacidad (por ejemplo, una accion que le toca al " +
    "propietario), dilo con esas palabras y este candado no te detiene."
  );
}
