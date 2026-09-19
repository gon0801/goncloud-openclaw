import {
  NOTAS_TOPE,
  SIGUIENTE_PASO_MAX,
  TEXTO_MAX,
  type Carril,
  type ColaItem,
  type Derivado,
  type ProgresoDoc,
  validarFase,
} from "./contrato.ts";

const ESC_MAP: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

/** La única función de escape del plugin. Se aplica en el punto de interpolación. */
export function esc(s: string): string {
  return s.replace(/[&<>"']/g, (ch) => ESC_MAP[ch] ?? ch);
}

/**
 * Trunca ANTES de escapar: escapar primero y truncar después puede cortar una
 * entidad a la mitad ("&am…"), que es exactamente el mutante que la batería
 * clava. El marcador "…" no forma parte del tope.
 */
export function truncar(s: string, max: number): string {
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

/** El único camino al HTML para un valor dinámico: truncar primero, escapar después. */
function t(v: unknown, max: number = TEXTO_MAX): string {
  const s = typeof v === "string" ? v : String(v ?? "");
  return esc(truncar(s, max));
}

// ---------------------------------------------------------------------------
// renderTablero — HTML autocontenido: CSS inline, sin scripts, sin fuentes remotas.
// ---------------------------------------------------------------------------

/** Mapa `owner/repo#123` → estado vivo de GitHub; `null` = intentó y no pudo ("unknown"). */
export type GithubCruce = Record<string, string | null>;

export function clavePr(repo: string, pr: number | null): string {
  return `${repo}#${pr}`;
}

function rotuloGithub(github: GithubCruce | undefined, repo: string, pr: number | null): string {
  if (pr === null || pr === undefined) return "";
  if (github === undefined) return '<span class="gh gh-off">GitHub: sin verificar</span>';
  const valor = github[clavePr(repo, pr)];
  return valor === null || valor === undefined
    ? '<span class="gh gh-unk">GitHub: unknown</span>'
    : `<span class="gh gh-ok">GitHub: ${t(valor, 100)}</span>`;
}

type Fila =
  | { kind: "cola"; item: ColaItem; carril: Carril | undefined }
  | { kind: "carril-suelto"; carril: Carril };

function hallarCarril(item: ColaItem, carriles: Carril[]): Carril | undefined {
  const porId = carriles.find((c) => c.id === item.id);
  if (porId) return porId;
  const porTarea = carriles.find((c) => Array.isArray(c.tareas) && c.tareas.includes(item.id));
  if (porTarea) return porTarea;
  const m = /^Q(\d+)$/i.exec(item.id);
  if (!m) return undefined;
  const n = Number(m[1]);
  if (n >= 1 && n <= carriles.length) return carriles[n - 1];
  return undefined;
}

function armarFilas(doc: ProgresoDoc): Fila[] {
  const carriles = Array.isArray(doc.carriles) ? doc.carriles : [];
  const cola = Array.isArray(doc.cola) ? doc.cola : [];
  const usadas = new Set<string>();
  const filas: Fila[] = cola.map((item) => {
    const carril = hallarCarril(item, carriles);
    if (carril) usadas.add(carril.id);
    return { kind: "cola", item, carril };
  });
  for (const carril of carriles) {
    if (!usadas.has(carril.id)) filas.push({ kind: "carril-suelto", carril });
  }
  return filas;
}

function colaCuenta(f: Fila): f is Fila & { kind: "cola" } {
  return f.kind === "cola" && f.carril?.estado !== "omitido";
}

function porcentajeGlobalDe(filas: Fila[]): number {
  let sum = 0;
  let n = 0;
  for (const f of filas) {
    if (!colaCuenta(f)) continue;
    if (typeof f.item.avance === "number") {
      sum += f.item.avance;
      n += 1;
    }
  }
  return n === 0 ? 0 : Math.round(sum / n);
}

function conteoMaster(filas: Fila[]): { n: number; m: number } {
  let n = 0;
  let m = 0;
  for (const f of filas) {
    if (!colaCuenta(f)) continue;
    m += 1;
    if (f.carril?.estado === "mergeado" || f.item.estado === "verificado" || f.item.avance === 100) {
      n += 1;
    }
  }
  return { n, m };
}

function pintarPrs(
  github: GithubCruce | undefined,
  carril: Carril | undefined,
  item: ColaItem | undefined,
): string {
  const chunks: string[] = [];
  const vistos = new Set<string>();
  const add = (repo: string, pr: number | null | undefined): void => {
    if (pr === null || pr === undefined) return;
    const k = clavePr(repo, pr);
    if (vistos.has(k)) return;
    vistos.add(k);
    const gh = rotuloGithub(github, repo, pr);
    chunks.push(
      `${t(repo, 160)} <span class="mono">#${t(pr, 10)}</span>${gh ? `<div>${gh}</div>` : ""}`,
    );
  };
  if (carril) add(carril.repo, carril.pr);
  if (item && Array.isArray(item.prs)) {
    for (const p of item.prs) add(p.repo, p.pr);
  }
  return chunks.join("");
}

function residualesBajo(carril: Carril | undefined): string {
  const rs = carril && Array.isArray(carril.residuales) ? carril.residuales : [];
  if (rs.length === 0) return "";
  return `<tr class="bajo"><td colspan="6"><ul class="res">${rs.map((r) => `<li>${t(r)}</li>`).join("")}</ul></td></tr>`;
}

function pintarAvance(avance: unknown): string {
  if (typeof avance !== "number") return "";
  const w = Math.min(100, Math.max(0, avance));
  return `<div class="barra av"><i style="width:${t(w, 3)}%"></i></div>${t(avance)}%`;
}

function celdaEstado(estado: string, detenido: string | null | undefined): string {
  return `<span class="estado ${t(estado, 30)}">${t(estado, 30)}</span>${
    detenido ? `<div class="det">${t(detenido)}</div>` : ""
  }`;
}

function pintarFila(f: Fila, github: GithubCruce | undefined): string {
  if (f.kind === "cola") {
    const estado = f.carril?.estado ?? f.item.estado;
    const detenido = f.carril?.detenido_por ?? f.item.detenido_por;
    const ronda = f.carril?.ronda;
    return `<tr>
<td><strong>${t(f.item.id, 100)}</strong></td>
<td>${f.carril ? t(f.carril.id, 100) : ""}</td>
<td>${celdaEstado(estado, detenido)}</td>
<td>${ronda === undefined || ronda === null ? "" : t(ronda)}</td>
<td>${pintarPrs(github, f.carril, f.item)}</td>
<td>${pintarAvance(f.item.avance)}</td>
</tr>
${residualesBajo(f.carril)}`;
  }
  const c = f.carril;
  return `<tr>
<td></td>
<td>${t(c.id, 100)}</td>
<td>${celdaEstado(c.estado, c.detenido_por)}</td>
<td>${c.ronda === undefined || c.ronda === null ? "" : t(c.ronda)}</td>
<td>${pintarPrs(github, c, undefined)}</td>
<td></td>
</tr>
${residualesBajo(c)}`;
}

function cabecera(doc: ProgresoDoc): string {
  const fase = t(doc.fase, 12);
  const titulo = t(doc.titulo);
  if (doc.proyecto) return `${fase} · ${t(doc.proyecto)} — ${titulo}`;
  return `${fase} — ${titulo}`;
}

const CSS = `:root{color-scheme:dark}
*{box-sizing:border-box}
body{font:14px/1.45 ui-sans-serif,system-ui,Segoe UI,sans-serif;margin:0;padding:24px;background:#12141a;color:#e7eaf0}
main{max-width:1100px;margin:0 auto}
h1{font-size:22px;margin:0 0 8px}
h2{font-size:13px;margin:28px 0 8px;text-transform:uppercase;letter-spacing:.06em;color:#8b93a7}
.atencion{background:#8a1c1c;color:#fff;padding:12px 16px;border-radius:8px;margin:0 0 16px;font-weight:600}
.siguiente{font-size:16px;margin:8px 0 20px;padding:10px 14px;background:#1c2433;border-left:4px solid #5b8def;border-radius:6px}
.global{font-size:22px;font-weight:700;margin:0 0 6px;letter-spacing:.02em}
.sub{color:#8b93a7;margin:0 0 12px}
.barra{height:8px;background:#2a3140;border-radius:4px;overflow:hidden;margin:6px 0 16px}
.barra.av{margin:4px 0 2px;max-width:120px}
.barra i{display:block;height:100%;background:#3dba6b}
table{border-collapse:collapse;width:100%;background:#1a1d26;border:1px solid #2a3140;border-radius:8px}
th,td{text-align:left;padding:7px 10px;border-top:1px solid #2a3140;vertical-align:top;font-size:13px}
th{border-top:0;background:#222733;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:#8b93a7}
.estado{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;background:#2a3140}
.estado.mergeado{background:#1e4d32}.estado.atorado{background:#5a2222}.estado.omitido{background:#3a3f4d;color:#8b93a7}
.estado.en-cola,.estado.esperando-ventana{background:#5a4a1e}
.gh{display:inline-block;margin-top:3px;font-size:12px;padding:1px 7px;border-radius:8px}
.gh-off{background:#2a3140;color:#c5c9d3}.gh-ok{background:#1e334d}.gh-unk{background:#4a3220}
.mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}
ul.res{margin:0;padding-left:16px}
.eventos li,.notas li{margin:4px 0}
.det{margin-top:4px;color:#f0b4b4}
footer{margin-top:28px;color:#8b93a7;font-size:12px;border-top:1px solid #2a3140;padding-top:10px}
nav.fases a{margin-right:10px}
a{color:#8bb4ff}`;

/**
 * Pinta el tablero. Determinístico: nada de Date.now() adentro (el tiempo llega
 * vía `doc.lead.actualizado`), así la ruta HTTP y `runbook.progress.get` producen
 * el MISMO HTML byte a byte.
 */
export function renderTablero(
  doc: ProgresoDoc,
  derivado: Derivado,
  github?: GithubCruce,
  fases?: string[],
): string {
  const filas = armarFilas(doc);
  const pct = porcentajeGlobalDe(filas);
  const master = conteoMaster(filas);
  const cuerpo = filas.map((f) => pintarFila(f, github)).join("\n");

  const eventos = (Array.isArray(doc.eventos) ? doc.eventos : [])
    .slice(-20)
    .reverse()
    .map((e) => `<li><span class="mono">${t(e.at, 40)}</span> ${e.carril ? `[${t(e.carril, 100)}] ` : ""}${t(e.que)}${e.situacion ? ` <em>(${t(e.situacion, 120)})</em>` : ""}</li>`)
    .join("\n");

  const notas = (Array.isArray(doc.notas) ? doc.notas : [])
    .slice(0, NOTAS_TOPE)
    .map((line) => `<li>${t(line, TEXTO_MAX)}</li>`)
    .join("");

  const banner =
    doc.atencion_requerida?.necesaria === true
      ? `<div class="atencion">⚠ ${t(doc.atencion_requerida.motivo ?? "Atención requerida")} <span class="mono">desde ${t(doc.atencion_requerida.desde ?? "—", 40)}</span></div>`
      : "";

  const navFases = (fases ?? [])
    .filter((f) => f !== doc.fase && validarFase(f))
    .map((f) => `<a href="/runbook/tablero/${encodeURIComponent(f)}">Fase ${t(f, 12)}</a>`)
    .join("");
  const nav = navFases ? `<nav class="fases">Fases: ${navFases}</nav>` : "";

  return `<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${t(doc.titulo)}</title>
<style>${CSS}</style>
</head>
<body>
${banner}
<main>
<h1>${cabecera(doc)}</h1>
<div class="global">%GLOBAL ${t(pct)} %</div>
<div class="barra"><i style="width:${t(pct, 3)}%"></i></div>
<p class="sub">${t(doc.lead?.actualizado, 40)} · ${t(master.n)} de ${t(master.m)} ítems en master · ${t(derivado.carrilesAtorados.length)} atorados</p>
<p class="siguiente">${t(doc.siguiente_paso, SIGUIENTE_PASO_MAX)}</p>
<h2>Carriles</h2>
<table>
<tr><th>ÍTEM</th><th>CARRIL</th><th>ESTADO</th><th>RONDAS</th><th>PR</th><th>AVANCE</th></tr>
${cuerpo}
</table>
${notas ? `<ul class="notas">${notas}</ul>` : ""}
<ul class="eventos">
${eventos || "<li>—</li>"}
</ul>
${nav}
<footer>La fuente de verdad es el runbook (${t(doc.runbook, 200)}); este tablero es una copia que solo pinta lo que el lead escribió. Lo rotulado "GitHub" viene del cruce vivo; lo demás lo reportó el lead.</footer>
</main>
</body>
</html>
`;
}
