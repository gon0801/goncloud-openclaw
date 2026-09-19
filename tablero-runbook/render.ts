import { SIGUIENTE_PASO_MAX, TEXTO_MAX, type Derivado, type ProgresoDoc, validarFase } from "./contrato.ts";

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

const CSS = `:root{color-scheme:light dark}
*{box-sizing:border-box}
body{font:14px/1.45 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;margin:0;padding:24px;background:#f6f7f9;color:#1c2430}
main{max-width:1080px;margin:0 auto}
h1{font-size:22px;margin:0 0 4px}
h2{font-size:15px;margin:28px 0 8px;text-transform:uppercase;letter-spacing:.06em;color:#5b6675}
.atencion{background:#8a1c1c;color:#fff;padding:12px 16px;border-radius:8px;margin:0 0 16px;font-weight:600}
.siguiente{font-size:17px;margin:8px 0 20px;padding:10px 14px;background:#eef3fb;border-left:4px solid #2b5cb8;border-radius:6px}
.resumen{display:flex;flex-wrap:wrap;gap:12px;margin:0 0 8px}
.resumen div{background:#fff;border:1px solid #dde3ea;border-radius:8px;padding:8px 14px}
.resumen .num{font-size:20px;font-weight:700;display:block}
.barra{height:8px;background:#dde3ea;border-radius:4px;overflow:hidden;margin:6px 0 2px}
.barra i{display:block;height:100%;background:#2f9e44}
table{border-collapse:collapse;width:100%;background:#fff;border:1px solid #dde3ea;border-radius:8px}
th,td{text-align:left;padding:7px 10px;border-top:1px solid #e6eaf0;vertical-align:top;font-size:13px}
th{border-top:0;background:#eef1f5;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.estado{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;background:#e5e8ec}
.estado.mergeado{background:#d9f0dd}.estado.atorado{background:#f6d7d7}.estado.en-cola,.estado.esperando-ventana{background:#fdeecb}
.gh{display:inline-block;margin-top:3px;font-size:12px;padding:1px 7px;border-radius:8px}
.gh-off{background:#e5e8ec;color:#444}.gh-ok{background:#dce8f8}.gh-unk{background:#f0e0d0}
.mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}
ul.res{margin:0;padding-left:16px}
.eventos li{margin:4px 0}
footer{margin-top:28px;color:#5b6675;font-size:12px;border-top:1px solid #ccd4dd;padding-top:10px}
nav.fases a{margin-right:10px}
a{color:#2b5cb8}`;

/**
 * Pinta el tablero. Determinístico: nada de Date.now() adentro (el tiempo llega
 * vía `derivado`), así la ruta HTTP y `runbook.progress.get` producen el MISMO
 * HTML byte a byte.
 */
export function renderTablero(
  doc: ProgresoDoc,
  derivado: Derivado,
  github?: GithubCruce,
  fases?: string[],
): string {
  const filasCarriles = (Array.isArray(doc.carriles) ? doc.carriles : []).map((c) => {
    const prTxt =
      c.pr === null || c.pr === undefined
        ? "—"
        : `${t(c.repo, 160)} <span class="mono">#${t(c.pr, 10)}</span>`;
    const gh = rotuloGithub(github, c.repo, c.pr ?? null);
    const residuales = (Array.isArray(c.residuales) ? c.residuales : [])
      .map((r) => `<li>${t(r)}</li>`)
      .join("");
    const detenido = c.detenido_por ? `<div class="det">${t(c.detenido_por)}</div>` : "";
    const ue = c.ultimo_evento
      ? `<div>${t(c.ultimo_evento.at, 40)}</div><div>${t(c.ultimo_evento.que, 120)}</div>`
      : "—";
    return `<tr>
<td><strong>${t(c.id, 100)}</strong><div>${t(c.nombre)}</div></td>
<td><span class="estado ${t(c.estado, 30)}">${t(c.estado, 30)}</span>${detenido}</td>
<td>${prTxt}${gh ? `<div>${gh}</div>` : ""}</td>
<td>${t(c.ci, 20)}</td>
<td>${t(c.coderabbit, 20)}</td>
<td>${residuales ? `<ul class="res">${residuales}</ul>` : "—"}</td>
<td>${ue}</td>
</tr>`;
  }).join("\n");

  const filasCola = (Array.isArray(doc.cola) ? doc.cola : []).map((q) => {
    const prs = (Array.isArray(q.prs) ? q.prs : [])
      .map((p) => {
        const gh = rotuloGithub(github, p.repo, p.pr ?? null);
        return `<li><span class="mono">${t(p.repo, 160)}#${t(p.pr ?? "—", 10)}</span>${gh ? ` ${gh}` : ""}</li>`;
      })
      .join("");
    return `<tr>
<td><strong>${t(q.id, 100)}</strong></td>
<td><span class="estado ${t(q.estado, 30)}">${t(q.estado, 30)}</span>${q.detenido_por ? `<div class="det">${t(q.detenido_por)}</div>` : ""}</td>
<td>${t(q.ventana ?? "—", 120)}</td>
<td>${prs ? `<ul class="res">${prs}</ul>` : "—"}</td>
<td>${t(q.verificado ?? "—", 20)}</td>
</tr>`;
  }).join("\n");

  const eventos = (Array.isArray(doc.eventos) ? doc.eventos : [])
    .slice(-20)
    .reverse()
    .map((e) => `<li><span class="mono">${t(e.at, 40)}</span> ${e.carril ? `[${t(e.carril, 100)}] ` : ""}${t(e.que)}${e.situacion ? ` <em>(${t(e.situacion, 120)})</em>` : ""}</li>`)
    .join("\n");

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
<h1>${t(doc.titulo)}</h1>
<p class="siguiente">${t(doc.siguiente_paso, SIGUIENTE_PASO_MAX)}</p>
<div class="resumen">
<div><span class="num">${t(derivado.mergeados)}/${t(derivado.totalCarriles)}</span>mergeados</div>
<div class="barra-wrap"><div class="barra"><i style="width:${t(Math.min(100, Math.max(0, derivado.porcentajeMergeado)), 3)}%"></i></div>${t(derivado.porcentajeMergeado)}%</div>
<div><span class="num">${t(derivado.carrilesAtorados.length)}</span>atorados${derivado.carrilesAtorados.length ? ` <span class="mono">(${derivado.carrilesAtorados.map((id) => t(id, 100)).join(", ")})</span>` : ""}</div>
<div><span class="num">${derivado.siguienteCola ? t(derivado.siguienteCola.id, 100) : "—"}</span>siguiente de cola${derivado.siguienteCola ? ` (${t(derivado.siguienteCola.estado, 30)})` : ""}</div>
<div><span class="num">${derivado.minutosDesdeUltimoEvento === null ? "—" : t(derivado.minutosDesdeUltimoEvento)}</span>min desde el último evento</div>
<div><span class="num" style="font-size:14px">${github === undefined ? "GitHub: sin verificar" : "GitHub"}</span>${github === undefined ? "cruce apagado" : "cruce activo"}</div>
</div>
<h2>Carriles</h2>
<table>
<tr><th>Carril</th><th>Estado</th><th>Repo / PR</th><th>CI</th><th>CodeRabbit</th><th>Residuales</th><th>Último evento</th></tr>
${filasCarriles}
</table>
<h2>Cola de merge</h2>
<table>
<tr><th>Ítem</th><th>Estado</th><th>Ventana</th><th>PRs</th><th>Verificado</th></tr>
${filasCola}
</table>
<h2>Eventos (últimos 20)</h2>
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
