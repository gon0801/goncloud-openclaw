// node render-local-vs-gateway.mjs <dir con tablero-runbook de 5d435d2> <gateway-get1.json>
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
const [dir, get] = process.argv.slice(2);
const { renderTablero } = await import(pathToFileURL(path.resolve(dir, "tablero-runbook/render.ts")).href);
const r = JSON.parse(fs.readFileSync(get, "utf8"));
const linea = (h) => (h.match(/<li>worker:.*?<\/li>/) || [""])[0].replace(/<[^>]+>/g, "");
console.log("render.ts de 5d435d2:", linea(renderTablero(r.doc, r.derivado)));
console.log("gateway             :", linea(r.html));
