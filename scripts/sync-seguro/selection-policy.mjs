import { isAbsolute } from "node:path";

// Allowlist positiva versionada + denylist cerrada del sync selectivo (U1).
//
// Todo lo que llega al runtime pasa por selectionParts: primero la denylist
// (rechazo explícito por categoría, con mensaje que la nombra) y después la
// allowlist (lo que no está nombrado se rechaza). Las dos capas son
// intencionales: si la allowlist se amplía mañana, la denylist sigue cerrada.

export const POLICY_VERSION = 1;

const agentIds = new Set([
  "main", "operaciones", "ingenieria", "implementer",
  "reviewer", "adversary", "verifier", "scout",
]);

// Denylist por categoría (contrato: bases, credenciales, sesiones, logs,
// herramientas, modelos y launchers generados no se publican). Directorios
// completos que nunca salen de la máquina viva.
const deniedDirs = new Map([
  ["bases", /^(?:\.git|state|cache|backups|\.ledger)$/i],
  ["credenciales", /^(?:credentials)$/i],
  ["sesiones", /^(?:sessions)$/i],
  ["logs", /^(?:logs)$/i],
  ["herramientas", /^(?:tools|node_modules)$/i],
  ["modelos", /^(?:models)$/i],
]);

// Archivos por categoría: aunque lleguen al manifiesto se rechazan.
const deniedFiles = new Map([
  ["bases", /\.(?:sqlite(?:-wal|-shm)?|db(?:-wal|-shm)?|wal|shm)(?:\..*)?$/i],
  ["credenciales", /(?:^openclaw\.json(?:\..*)?$|\.env(?:\..*)?$|\.(?:pem|key|pfx|p12)(?:\..*)?$|(?:^|[._-])secrets?(?:$|[._-].*)|(?:^|[._-])credentials?(?:$|[._-].*))/i],
  ["modelos", /\.(?:gguf|ggml|onnx|safetensors|pt|ckpt|bin)(?:\..*)?$/i],
  ["launchers generados", /\.(?:cmd|vbs|lnk|bat|com|scr|msi|exe|dll|zip)(?:\..*)?$/i],
  ["respaldos", /(?:\.bak(?:[-.]|$)|^__MACOSX$)/i],
]);

const reserved = /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$/i;

export function selectionParts(path) {
  if (typeof path !== "string" || !path || isAbsolute(path) || path.includes("\\") ||
      path.includes(":") || /[\x00-\x1f\x7f]/.test(path)) {
    throw new Error("unsafe selection path");
  }
  // Variantes Windows: unidad (C:/...), UNC (//srv/...) y ADS ya cubierto por ":".
  if (/^[a-zA-Z]:/.test(path) || path.startsWith("//")) {
    throw new Error("unsafe selection path");
  }
  const parts = path.split("/");
  for (const part of parts) {
    if (!part || part === "." || part === ".." || part.startsWith(".backup-") ||
        reserved.test(part) || /[. ]$/.test(part)) {
      throw new Error("unsafe selection path");
    }
    for (const [category, re] of deniedDirs) {
      if (re.test(part)) throw new Error(`denylisted ${category} path`);
    }
    for (const [category, re] of deniedFiles) {
      if (re.test(part)) throw new Error(`denylisted ${category} path`);
    }
    if (part.startsWith(".")) throw new Error("unsafe selection path");
  }
  const plugin = ["summa-gate", "tablero-runbook"].includes(parts[0]) && parts.length > 1;
  const skill = parts[0] === "agents" && agentIds.has(parts[1]) && parts.length > 5 &&
    parts[2] === "agent" && parts[3] === "workshop-skills";
  if (!plugin && !skill && path !== "gateway-watchdog.ps1") {
    throw new Error("unsafe selection path: outside recovery allowlist");
  }
  return parts;
}

// D1: comparación canónica de fin de línea. Con core.autocrlf=true el
// checkout convierte LF→CRLF en el working tree mientras el blob guarda LF,
// así que dos contenidos iguales se verían distintos en bytes crudos. Para
// decidir "sin cambios" se comparan los bytes canónicos (CRLF→LF); el SHA
// que se registra y lo que se publica son siempre los bytes del blob
// pinneado. Solo colapsa CR seguido de LF (igual que el clean de git).
export function canonicalEolBytes(buffer) {
  const bytes = Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer);
  const parts = [];
  let start = 0;
  let at = bytes.indexOf("\r\n");
  while (at !== -1) {
    parts.push(bytes.subarray(start, at));
    start = at + 1; // conserva el \n, descarta el \r
    at = bytes.indexOf("\r\n", start);
  }
  parts.push(bytes.subarray(start));
  return Buffer.concat(parts);
}
