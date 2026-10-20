// Resumen de la bitacora de Jev: node report.mjs [ruta]
import { readFileSync } from "node:fs";
const path = process.argv[2] ?? new URL("decisions.jsonl", import.meta.url).pathname;
let raw = "";
try { raw = readFileSync(path, "utf8"); } catch (e) { console.error(`no pude leer ${path}: ${e.message}`); process.exit(1); }
const rows = [], malas = [];
for (const l of raw.split("\n").filter(Boolean)) { try { rows.push(JSON.parse(l)); } catch { malas.push(l); } }
const count = (f) => rows.reduce((m, r) => { const k = f(r); if (k != null) m[k] = (m[k] ?? 0) + 1; return m; }, {});
const out = {
  archivo: path,
  total: rows.length,
  por_estado: count((r) => r.status),
  fallas: rows.filter((r) => r.status === "failure").length,
  fallas_por_error: count((r) => (r.status === "failure" ? r.error : null)),
  por_tipo_consulta: count((r) => r.kind),
  ruteo_por_agente: count((r) => (r.kind === "ruteo" && r.status !== "failure" ? r.answer : null)),
  ruteo_por_agente_y_estado: count((r) => (r.kind === "ruteo" && r.status !== "failure" ? `${r.answer}|${r.status}` : null)),
  modelos: count((r) => r.model),
  lineas_ilegibles: malas.length,
};
console.log(JSON.stringify(out, null, 2));
