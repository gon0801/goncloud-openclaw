/**
 * raices.ts — frontera de disco de la vista de raíces (SUA-06 §4.4). Fail-open
 * con estados con nombre: ningún fallo de disco lanza; todo camino termina en
 * un estado de la unión ArchivoRaiz. Cero HTML (eso vive en render.ts).
 */
import { closeSync, constants, fstatSync, lstatSync, openSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { isAbsolute, join, relative, sep } from "node:path";

import { validarRootId } from "./contrato.ts";
import { type ProyeccionDoc, validarProyeccion } from "./proyeccion.ts";

export type ArchivoRaiz =
  | { estado: "ausente" }
  | { estado: "enlace" }
  | { estado: "fuera" }
  | { estado: "ilegible"; detalle: string }
  | { estado: "json-roto" }
  | { estado: "invalida"; razones: string[] }
  | { estado: "ok"; doc: ProyeccionDoc };

/** Identidad de disco/URL = STEM; nav precomputado saca la política de URL del render. */
export type ItemRaiz = { stem: string; nav: boolean; archivo: ArchivoRaiz };

export type VistaRaices =
  | { estado: "vacio" }
  | { estado: "error"; detalle: string }
  | { estado: "ok"; items: ItemRaiz[] };

function errno(err: unknown): string {
  const code = (err as { code?: unknown } | null)?.code;
  return typeof code === "string" ? code : "error";
}

export function leerArchivoRaiz(raicesDir: string, stem: string): ArchivoRaiz {
  const rutaArchivo = join(raicesDir, "proyecciones", `${stem}.json`);
  let st;
  try {
    st = lstatSync(rutaArchivo);
  } catch (err) {
    if (errno(err) === "ENOENT") return { estado: "ausente" };
    return { estado: "ilegible", detalle: errno(err) };
  }
  if (st.isSymbolicLink()) return { estado: "enlace" };
  // Un FIFO bloquearía el readFileSync síncrono y con él todo el gateway.
  if (!st.isFile()) return { estado: "ilegible", detalle: "no-regular" };

  // La contención es contra raicesDir REAL: un proyecciones/ reemplazado por
  // symlink que escape no se lee, aunque cada archivo dentro parezca legítimo.
  let base;
  try {
    base = realpathSync(raicesDir);
  } catch (err) {
    if (errno(err) === "ENOENT") return { estado: "ausente" };
    return { estado: "ilegible", detalle: errno(err) };
  }
  let real;
  try {
    real = realpathSync(rutaArchivo);
  } catch (err) {
    if (errno(err) === "ENOENT") return { estado: "ausente" };
    return { estado: "ilegible", detalle: errno(err) };
  }
  const rel = relative(base, real);
  if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return { estado: "fuera" };

  // Un solo descriptor sin seguir enlaces: si el archivo cambió desde el lstat
  // por un enlace o un FIFO, el open falla o el fstat lo rechaza.
  let crudo: string;
  let fd: number | undefined;
  try {
    fd = openSync(rutaArchivo, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    if (!fstatSync(fd).isFile()) return { estado: "ilegible", detalle: "no-regular" };
    crudo = readFileSync(fd, "utf8");
  } catch (err) {
    if (errno(err) === "ELOOP") return { estado: "enlace" };
    return { estado: "ilegible", detalle: errno(err) };
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
  let doc: unknown;
  try {
    doc = JSON.parse(crudo);
  } catch {
    return { estado: "json-roto" };
  }
  const v = validarProyeccion(doc);
  return v.ok ? { estado: "ok", doc: doc as ProyeccionDoc } : { estado: "invalida", razones: v.razones };
}

export function leerRaices(raicesDir: string): VistaRaices {
  let nombres: string[];
  try {
    nombres = readdirSync(join(raicesDir, "proyecciones"));
  } catch (err) {
    if (errno(err) === "ENOENT") return { estado: "vacio" };
    return { estado: "error", detalle: errno(err) };
  }
  const items = nombres
    .filter((n) => n.endsWith(".json"))
    .map((n) => n.slice(0, -5))
    .sort()
    .map((stem) => {
      // Borrado entre readdir y lstat: ausente se salta, no es una fila.
      const archivo = leerArchivoRaiz(raicesDir, stem);
      return archivo.estado === "ausente" ? undefined : { stem, nav: validarRootId(stem), archivo };
    })
    .filter((item): item is ItemRaiz => item !== undefined);
  return items.length === 0 ? { estado: "vacio" } : { estado: "ok", items };
}
