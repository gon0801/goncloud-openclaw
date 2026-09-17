/**
 * tablero-runbook/github.ts — cruce con GitHub, APAGADO por defecto (Fase 7 / 7.5).
 *
 * Con `github.enabled: true`, cada GET del tablero consulta el estado vivo de
 * cada PR con `gh pr view` por `execFile` con `shell:false` (argv literal, nunca
 * shell). Lo que devuelve se rotula "GitHub" en el tablero para distinguirlo de
 * lo reportado por el lead; cualquier fallo pinta "GitHub: unknown". Con
 * `enabled: false` no se ejecuta NADA y el tablero dice "GitHub: sin verificar".
 *
 * Presupuestos de la DoD (exportados y anclados por test):
 *  - total 8 s por render (deadline que mata lo que siga vivo);
 *  - máximo 10 PRs por render;
 *  - `Promise.allSettled` con concurrencia ≤ 4;
 *  - caché de 60 s por PR (éxitos Y fallos: no martillar un gh roto);
 *  - `child.kill()` real al vencer el presupuesto, con SIGKILL.
 *
 * ghPath viene de configSchema.github.ghPath (default
 * `C:\Users\ehven\.openclaw\tools\bin\gh.exe`, nunca PATH) y DEBE terminar en
 * `.exe`: un `.cmd` reabre el bug de quoting de Windows (Fase 5 / 5.6). El
 * subcomando es fijo (`pr view`); no se pasa ningún otro.
 *
 * Solo se consulta `repo`/`pr` que pasan la validación de forma (mismo patrón
 * que validarProgreso): `a/b; calc.exe` o `--template x` no se ejecutan nunca,
 * aunque lleguen hasta aquí por un doc corrupto en disco.
 */
import { execFile } from "node:child_process";
import { REPO_RE, clavePr, type GithubCruce, type ProgresoDoc } from "./lib.ts";

export const GH_PRESUPUESTO_MS = 8_000;
export const GH_MAX_PRS = 10;
export const GH_CONCURRENCIA = 4;
export const GH_CACHE_MS = 60_000;
export const DEFAULT_GH_PATH = "C:\\Users\\ehven\\.openclaw\\tools\\bin\\gh.exe";
/** Subcomando fijo: nada fuera de `pr view` se ejecuta jamás. */
export const GH_SUBCOMANDO = ["pr", "view"] as const;
export const GH_JSON_FIELDS = "mergeable,mergeStateStatus,statusCheckRollup";

export type GithubConfig = { enabled: boolean; ghPath: string };

export function leerGithubConfig(pluginConfig: unknown): GithubConfig {
  const pc =
    pluginConfig !== null && typeof pluginConfig === "object"
      ? (pluginConfig as Record<string, unknown>)
      : {};
  const gh =
    pc["github"] !== null && typeof pc["github"] === "object" && !Array.isArray(pc["github"])
      ? (pc["github"] as Record<string, unknown>)
      : {};
  return {
    enabled: gh["enabled"] === true,
    ghPath: typeof gh["ghPath"] === "string" && gh["ghPath"].length > 0 ? gh["ghPath"] : DEFAULT_GH_PATH,
  };
}

// ---------------------------------------------------------------------------
// Inyectables de test: el exec real, el reloj y los tiempos. Producción usa
// execFile de node:fs child_process con shell:false y killSignal SIGKILL.
// ---------------------------------------------------------------------------

type ExecFileLike = (
  cmd: string,
  args: readonly string[],
  opts: Record<string, unknown>,
  cb: (err: Error | null, stdout: string) => void,
) => { kill: (signal?: string) => void };

let execInyectado: ExecFileLike | undefined;
/** Solo tests: espía o sustituye el execFile sin tocar el modulo de node. */
export function _setGhExecForTest(fn: ExecFileLike | undefined): void {
  execInyectado = fn;
}

type Tiempos = { presupuesto: number; cache: number };

let cache = new Map<string, { at: number; valor: string | null }>();
/** Solo tests: arranca la caché de cero. */
export function _resetGhCacheForTest(): void {
  cache = new Map();
}

function prValido(repo: unknown, pr: unknown): pr is number {
  return (
    typeof repo === "string" &&
    REPO_RE.test(repo) &&
    typeof pr === "number" &&
    Number.isInteger(pr) &&
    pr >= 1 &&
    pr < 10_000_000
  );
}

/** Los PRs a cruzar, en orden de aparición, deduplicados y con tope. */
export function prsACruzar(doc: ProgresoDoc): Array<{ repo: string; pr: number }> {
  const vistos = new Set<string>();
  const lista: Array<{ repo: string; pr: number }> = [];
  const considerar = (repo: unknown, pr: unknown): void => {
    if (!prValido(repo, pr)) return;
    const clave = clavePr(repo, pr);
    if (vistos.has(clave)) return;
    vistos.add(clave);
    lista.push({ repo, pr });
  };
  for (const c of Array.isArray(doc?.carriles) ? doc.carriles : []) considerar(c?.repo, c?.pr);
  for (const q of Array.isArray(doc?.cola) ? doc.cola : []) {
    for (const p of Array.isArray(q?.prs) ? q.prs : []) considerar(p?.repo, p?.pr);
  }
  return lista.slice(0, GH_MAX_PRS);
}

function resumirPr(stdout: string): string | null {
  let json: Record<string, unknown>;
  try {
    json = JSON.parse(stdout) as Record<string, unknown>;
  } catch {
    return null;
  }
  if (json === null || typeof json !== "object") return null;
  const partes: string[] = [String(json["mergeStateStatus"] ?? "UNKNOWN")];
  const rollup = json["statusCheckRollup"];
  if (Array.isArray(rollup) && rollup.length > 0) {
    const ok = rollup.filter(
      (c: unknown) =>
        c !== null && typeof c === "object" &&
        ((c as Record<string, unknown>)["conclusion"] === "SUCCESS" ||
          (c as Record<string, unknown>)["status"] === "SUCCESS"),
    ).length;
    partes.push(`checks ${ok}/${rollup.length}`);
  }
  partes.push(`mergeable=${json["mergeable"] === null || json["mergeable"] === undefined ? "unknown" : String(json["mergeable"])}`);
  return partes.join(" · ").slice(0, 100);
}

/**
 * El cruce. `tiempos` solo lo usan los tests para achicar presupuesto/caché;
 * producción corre con las constantes exportadas. Nunca lanza: cada fallo
 * individual es un `null` en el mapa ("GitHub: unknown").
 */
export async function cruzarGitHub(
  doc: ProgresoDoc,
  cfg: GithubConfig,
  tiempos?: Partial<Tiempos>,
): Promise<GithubCruce> {
  const presupuesto = tiempos?.presupuesto ?? GH_PRESUPUESTO_MS;
  const cacheMs = tiempos?.cache ?? GH_CACHE_MS;
  const ahora = Date.now();
  const deadline = ahora + presupuesto;

  const resultado: GithubCruce = {};
  const objetivos = prsACruzar(doc);

  // ghPath debe terminar en .exe (.cmd reabre el bug de quoting de Windows).
  // Sin esa garantía no se ejecuta NADA: todas las filas quedan en unknown.
  const ghPathOk = cfg.ghPath.endsWith(".exe");
  if (!ghPathOk) {
    for (const { repo, pr } of objetivos) resultado[clavePr(repo, pr)] = null;
    return resultado;
  }

  const exec = execInyectado ?? (execFile as unknown as ExecFileLike);

  // Caché primero: ni gh.exe gratis.
  const pendientes: Array<{ repo: string; pr: number }> = [];
  for (const o of objetivos) {
    const clave = `${cfg.ghPath}|${clavePr(o.repo, o.pr)}`;
    const memo = cache.get(clave);
    if (memo !== undefined && ahora - memo.at < cacheMs) {
      resultado[clavePr(o.repo, o.pr)] = memo.valor;
    } else {
      pendientes.push(o);
    }
  }
  if (pendientes.length === 0) return resultado;

  // Presupuesto TOTAL: este timer mata con SIGKILL todo lo que siga vivo al
  // vencer, además del timeout por llamada que trae execFile.
  const vivos = new Set<{ kill: (signal?: string) => void }>();
  const verdugo = setTimeout(() => {
    for (const child of vivos) {
      try {
        child.kill("SIGKILL");
      } catch {
        // ya murió: nada que hacer
      }
    }
  }, presupuesto);
  verdugo.unref?.();

  const consultar = ({ repo, pr }: { repo: string; pr: number }): Promise<void> =>
    new Promise((resolver) => {
      const restante = deadline - Date.now();
      if (restante <= 0) {
        resultado[clavePr(repo, pr)] = null;
        resolver();
        return;
      }
      const args = [...GH_SUBCOMANDO, String(pr), "-R", repo, "--json", GH_JSON_FIELDS];
      let child: { kill: (signal?: string) => void };
      try {
        child = exec(
          cfg.ghPath,
          args,
          { shell: false, timeout: Math.max(200, restante), killSignal: "SIGKILL", windowsHide: true },
          (err, stdout) => {
            vivos.delete(child);
            const valor = err ? null : resumirPr(stdout);
            resultado[clavePr(repo, pr)] = valor;
            cache.set(`${cfg.ghPath}|${clavePr(repo, pr)}`, { at: Date.now(), valor });
            resolver();
          },
        );
        vivos.add(child);
      } catch {
        resultado[clavePr(repo, pr)] = null;
        resolver();
      }
    });

  // allSettled con concurrencia <= GH_CONCURRENCIA: tandas de a lo sumo 4.
  for (let i = 0; i < pendientes.length; i += GH_CONCURRENCIA) {
    await Promise.allSettled(pendientes.slice(i, i + GH_CONCURRENCIA).map(consultar));
    if (Date.now() >= deadline) break;
  }
  clearTimeout(verdugo);
  return resultado;
}
