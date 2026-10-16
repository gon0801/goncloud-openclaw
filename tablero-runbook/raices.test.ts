/**
 * raices.test.ts — frontera de raíces (SUA-06 §4.4): espejo del contrato de
 * proyección (contrato.py:413-441 + 110 + 78-108), lectura de
 * <raicesDir>/proyecciones/ y render puro con `ahora` por parámetro. Sin HTTP.
 */
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";

import { validarRootId } from "./contrato.ts";
import { validarProyeccion } from "./proyeccion.ts";
import { leerArchivoRaiz, leerRaices } from "./raices.ts";
import { formatearHace, renderRaices, renderRaiz } from "./render.ts";

/** Base válida: la proyección vigente del fixture de scripts/tests (root-03). */
function docProyeccion(cambios: Record<string, unknown> = {}): Record<string, unknown> {
  return structuredClone({
    schema: "sistema-agentes.proyeccion.v1",
    rootId: "root-03",
    planRevision: 1,
    controlEpoch: 1,
    generatedAt: "2026-10-13T12:00:00Z",
    progress: { declared: 66, observed: 33, accepted: null },
    units: [
      {
        unitId: "unit-c",
        state: "running",
        host: "mac-local",
        executor: "opencode",
        modelId: null,
        nextCheckAt: "2026-10-13T12:05:00Z",
        error: null,
      },
    ],
    freshness: { staleAfterMs: 300000 },
    ...cambios,
  });
}

function dirRaices(): { dir: string; raices: string; limpiar: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "raices-frontera-"));
  const raices = join(dir, "raices");
  return { dir, raices, limpiar: () => rmSync(dir, { recursive: true, force: true }) };
}

function escribirProyeccion(raicesDir: string, stem: string, doc: unknown): void {
  mkdirSync(join(raicesDir, "proyecciones"), { recursive: true });
  writeFileSync(join(raicesDir, "proyecciones", `${stem}.json`), JSON.stringify(doc), "utf8");
}

describe("validarRootId", () => {
  it("acepta lo que casa ^[A-Za-z0-9._-]{1,80}$", () => {
    assert.equal(validarRootId("root-03"), true);
    assert.equal(validarRootId("a.b_c-d"), true);
    assert.equal(validarRootId("x".repeat(80)), true);
  });

  it("rechaza vacío, . y .. solos, barras, demasiado largo y no-strings", () => {
    assert.equal(validarRootId(""), false);
    assert.equal(validarRootId("."), false);
    assert.equal(validarRootId(".."), false);
    assert.equal(validarRootId("a/b"), false);
    assert.equal(validarRootId("x".repeat(81)), false);
    assert.equal(validarRootId(42), false);
    assert.equal(validarRootId(null), false);
  });
});

describe("validarProyeccion (espejo de contrato.py 413-441)", () => {
  it("el doc válido del fixture pasa con cero razones", () => {
    assert.deepEqual(validarProyeccion(docProyeccion()), { ok: true, razones: [] });
  });

  it("objeto raíz CERRADO: campo extra y campo que falta", () => {
    const extra = validarProyeccion(docProyeccion({ extra: 1 }));
    assert.equal(extra.ok, false);
    assert.ok(extra.razones.includes("campo fuera de la tabla: extra"));

    const { units, ...sinUnits } = docProyeccion() as Record<string, unknown>;
    const falta = validarProyeccion(sinUnits);
    assert.equal(falta.ok, false);
    assert.ok(falta.razones.includes("falta el campo: units"));
  });

  it("schema distinto del literal exacto", () => {
    const v = validarProyeccion(docProyeccion({ schema: "sistema-agentes.proyeccion.v2" }));
    assert.equal(v.ok, false);
    assert.ok(v.razones.some((r) => r.includes("sistema-agentes.proyeccion.v1")));
  });

  it("fecha: mes 13, día 32 y forma sin T no pasan (regex + Date.parse)", () => {
    assert.equal(validarProyeccion(docProyeccion({ generatedAt: "2026-13-01T12:00:00Z" })).ok, false);
    assert.equal(validarProyeccion(docProyeccion({ generatedAt: "2026-01-32T12:00:00Z" })).ok, false);
    assert.equal(validarProyeccion(docProyeccion({ generatedAt: "2026-10-13 12:00:00Z" })).ok, false);
    assert.equal(validarProyeccion(docProyeccion({ generatedAt: "2026-10-13T12:00:00.123Z" })).ok, true);
  });

  it("staleAfterMs SIN rango: -1 VALIDA (espejo fiel del contrato)", () => {
    assert.equal(validarProyeccion(docProyeccion({ freshness: { staleAfterMs: -1 } })).ok, true);
  });

  it("progress: cada miembro entero 0..100 o null", () => {
    assert.equal(validarProyeccion(docProyeccion({ progress: { declared: 150, observed: 33, accepted: null } })).ok, false);
    assert.equal(validarProyeccion(docProyeccion({ progress: { declared: "33", observed: 33, accepted: null } })).ok, false);
    assert.equal(validarProyeccion(docProyeccion({ progress: { declared: 33, observed: 33, accepted: true } })).ok, false);
    assert.equal(validarProyeccion(docProyeccion({ progress: { declared: 0, observed: 0, accepted: 0 } })).ok, true);
  });

  it("planRevision/controlEpoch: enteros >= 1", () => {
    assert.equal(validarProyeccion(docProyeccion({ planRevision: 0 })).ok, false);
    assert.equal(validarProyeccion(docProyeccion({ controlEpoch: 1.5 })).ok, false);
    assert.equal(validarProyeccion(docProyeccion({ planRevision: true })).ok, false);
  });

  it("rootId: cadena no vacía (la allowlist vive en validarRootId, no aquí)", () => {
    assert.equal(validarProyeccion(docProyeccion({ rootId: "" })).ok, false);
    assert.equal(validarProyeccion(docProyeccion({ rootId: "cualquier cosa con espacios" })).ok, true);
  });

  it("units: lista (vacía ok) de objetos cerrados con la tabla de unidad", () => {
    assert.equal(validarProyeccion(docProyeccion({ units: [] })).ok, true);
    assert.equal(validarProyeccion(docProyeccion({ units: "no-lista" })).ok, false);
    const unitExtra = docProyeccion();
    (unitExtra["units"] as Record<string, unknown>[])[0]["extra"] = 1;
    const v = validarProyeccion(unitExtra);
    assert.equal(v.ok, false);
    assert.ok(v.razones.includes("campo fuera de la tabla: units[0].extra"));
  });

  it("progress cerrado: extra y faltante con ruta", () => {
    const extra = validarProyeccion(docProyeccion({ progress: { declared: 1, observed: 1, accepted: 1, extra: 1 } }));
    assert.ok(extra.razones.includes("campo fuera de la tabla: progress.extra"));
    const falta = validarProyeccion(docProyeccion({ progress: { declared: 1, observed: 1 } }));
    assert.ok(falta.razones.includes("falta el campo: progress.accepted"));
  });

  it("no-objeto: una sola razón", () => {
    assert.deepEqual(validarProyeccion([1, 2]), { ok: false, razones: ["el documento no es un objeto JSON"] });
    assert.deepEqual(validarProyeccion("x"), { ok: false, razones: ["el documento no es un objeto JSON"] });
  });

  it("campos prohibidos: nombre exacto y sufijo, recursivos como _campos_prohibidos", () => {
    const raiz = docProyeccion({ apiKey: "x" });
    const vRaiz = validarProyeccion(raiz);
    assert.equal(vRaiz.ok, false);
    assert.ok(vRaiz.razones.includes("campo-prohibido: apiKey"));

    const unit = docProyeccion();
    (unit["units"] as Record<string, unknown>[])[0]["user_token"] = "t";
    const vUnit = validarProyeccion(unit);
    assert.equal(vUnit.ok, false);
    assert.ok(vUnit.razones.includes("campo-prohibido: units[0].user_token"));
  });
});

describe("leerRaices / leerArchivoRaiz (frontera de disco)", () => {
  it("sin proyecciones/ es vacio (el emisor aún no corrió)", () => {
    const { raices, limpiar } = dirRaices();
    try {
      assert.deepEqual(leerRaices(raices), { estado: "vacio" });
    } finally {
      limpiar();
    }
  });

  it("dos válidas: ok, orden por stem, nav true, docs dentro", () => {
    const { raices, limpiar } = dirRaices();
    try {
      escribirProyeccion(raices, "root-b", docProyeccion({ rootId: "root-b" }));
      escribirProyeccion(raices, "root-a", docProyeccion({ rootId: "root-a" }));
      const vista = leerRaices(raices);
      assert.equal(vista.estado, "ok");
      if (vista.estado !== "ok") return;
      assert.deepEqual(vista.items.map((i) => i.stem), ["root-a", "root-b"]);
      assert.ok(vista.items.every((i) => i.nav === true && i.archivo.estado === "ok"));
    } finally {
      limpiar();
    }
  });

  it("una inválida no tumba la lista: item invalida con razones", () => {
    const { raices, limpiar } = dirRaices();
    try {
      escribirProyeccion(raices, "mala", docProyeccion({ progress: { declared: 150, observed: 33, accepted: null } }));
      escribirProyeccion(raices, "buena", docProyeccion());
      const vista = leerRaices(raices);
      assert.equal(vista.estado, "ok");
      if (vista.estado !== "ok") return;
      const mala = vista.items.find((i) => i.stem === "mala");
      assert.ok(mala);
      assert.equal(mala?.archivo.estado, "invalida");
      if (mala?.archivo.estado === "invalida") assert.ok(mala.archivo.razones.length > 0);
      assert.equal(vista.items.find((i) => i.stem === "buena")?.archivo.estado, "ok");
    } finally {
      limpiar();
    }
  });

  it("json roto es json-roto; lo que no es .json no se lista", () => {
    const { raices, limpiar } = dirRaices();
    try {
      mkdirSync(join(raices, "proyecciones"), { recursive: true });
      writeFileSync(join(raices, "proyecciones", "roto.json"), "{no-es-json", "utf8");
      writeFileSync(join(raices, "proyecciones", "readme.txt"), "x", "utf8");
      const vista = leerRaices(raices);
      assert.equal(vista.estado, "ok");
      if (vista.estado !== "ok") return;
      assert.equal(vista.items.length, 1);
      assert.equal(vista.items[0]?.archivo.estado, "json-roto");
    } finally {
      limpiar();
    }
  });

  it("stem que no casa la regex se lista escapable (nav false)", () => {
    const { raices, limpiar } = dirRaices();
    try {
      escribirProyeccion(raices, "raiz mala", docProyeccion());
      const vista = leerRaices(raices);
      assert.equal(vista.estado, "ok");
      if (vista.estado !== "ok") return;
      assert.equal(vista.items[0]?.stem, "raiz mala");
      assert.equal(vista.items[0]?.nav, false);
    } finally {
      limpiar();
    }
  });

  it("symlink de ARCHIVO no se lee: enlace, y nada del objetivo", () => {
    const { dir, raices, limpiar } = dirRaices();
    try {
      writeFileSync(join(dir, "sentinela.txt"), "SENTINELA-FUERA", "utf8");
      mkdirSync(join(raices, "proyecciones"), { recursive: true });
      symlinkSync(join(dir, "sentinela.txt"), join(raices, "proyecciones", "fuga.json"));
      const vista = leerRaices(raices);
      assert.equal(vista.estado, "ok");
      if (vista.estado !== "ok") return;
      assert.equal(vista.items[0]?.archivo.estado, "enlace");
    } finally {
      limpiar();
    }
  });

  it("proyecciones/ reemplazado por symlink que escapa: fuera (contención realpath contra raicesDir)", () => {
    const { dir, raices, limpiar } = dirRaices();
    try {
      const fuera = join(dir, "fuera-de-raices");
      mkdirSync(fuera, { recursive: true });
      writeFileSync(join(fuera, "root-03.json"), JSON.stringify(docProyeccion()), "utf8");
      mkdirSync(raices, { recursive: true });
      symlinkSync(fuera, join(raices, "proyecciones"));
      assert.deepEqual(leerArchivoRaiz(raices, "root-03"), { estado: "fuera" });
    } finally {
      limpiar();
    }
  });

  it("archivo inexistente: ausente", () => {
    const { raices, limpiar } = dirRaices();
    try {
      mkdirSync(join(raices, "proyecciones"), { recursive: true });
      assert.deepEqual(leerArchivoRaiz(raices, "nadio"), { estado: "ausente" });
    } finally {
      limpiar();
    }
  });

  it("raicesDir que es un archivo regular: readdir es error con código ENOTDIR", () => {
    const { dir, limpiar } = dirRaices();
    try {
      const archivo = join(dir, "regular.txt");
      writeFileSync(archivo, "x", "utf8");
      const vista = leerRaices(archivo);
      assert.equal(vista.estado, "error");
      if (vista.estado === "error") assert.equal(vista.detalle, "ENOTDIR");
    } finally {
      limpiar();
    }
  });
});

describe("render de raíces (puro, ahora por parámetro)", () => {
  it("formatearHace: límites exactos y clamp >= 0", () => {
    assert.equal(formatearHace(0), "menos de 1 min");
    assert.equal(formatearHace(-5000), "menos de 1 min");
    assert.equal(formatearHace(59999), "menos de 1 min");
    assert.equal(formatearHace(60000), "hace 1 min");
    assert.equal(formatearHace(3599000), "hace 59 min");
    assert.equal(formatearHace(3600000), "hace 1 h");
    assert.equal(formatearHace(86399000), "hace 23 h");
    assert.equal(formatearHace(86400000), "hace 1 d");
    assert.equal(formatearHace(5 * 86400000), "hace 5 d");
  });

  it("lista vacío: 'sin raíces' con nombre, sin tabla", () => {
    const html = renderRaices({ estado: "vacio" }, 0);
    assert.ok(html.includes("sin raíces"));
    assert.ok(!html.includes("<table>"));
  });

  it("lista error: estado con nombre y código", () => {
    const html = renderRaices({ estado: "error", detalle: "ENOTDIR" }, 0);
    assert.ok(html.includes("no se pudo leer el directorio de proyecciones (ENOTDIR)"));
  });

  it("vieja: edad > staleAfterMs pinta 'vieja'; fresca no", () => {
    const GEN = Date.parse("2020-01-01T00:00:00Z");
    const doc = docProyeccion({ generatedAt: "2020-01-01T00:00:00Z", freshness: { staleAfterMs: 300000 } });
    const vieja = renderRaices({ estado: "ok", items: [{ stem: "root-03", nav: true, archivo: { estado: "ok", doc: doc as never } }] }, GEN + 300001);
    assert.ok(vieja.includes('<span class="vieja">vieja</span>'));
    assert.ok(vieja.includes("hace 5 min"));
    const fresca = renderRaices({ estado: "ok", items: [{ stem: "root-03", nav: true, archivo: { estado: "ok", doc: doc as never } }] }, GEN + 299999);
    assert.ok(!fresca.includes('<span class="vieja">'));
  });

  it("lista: fila inválida con primera razón; stem sin nav no lleva link", () => {
    const items = [
      { stem: "root-03", nav: true, archivo: { estado: "ok", doc: docProyeccion() as never } },
      { stem: "raiz mala", nav: false, archivo: { estado: "invalida", razones: ["progress.declared: entero 0..100 o null"] } },
    ];
    const html = renderRaices({ estado: "ok", items }, 0);
    assert.ok(html.includes('href="/runbook/tablero/raices/root-03"'));
    assert.ok(!html.includes('href="/runbook/tablero/raices/raiz%20mala"'));
    assert.ok(html.includes("raiz mala"));
    assert.ok(html.includes("proyección inválida: progress.declared: entero 0..100 o null"));
  });

  it("detalle ok: null es '?' (jamás 0), modelId null es '—', error null es celda vacía", () => {
    const doc = docProyeccion();
    const html = renderRaiz("root-03", { estado: "ok", doc: doc as never }, Date.parse("2026-10-13T12:00:00Z"));
    assert.ok(html.includes('<span class="desconocido">?</span>'));
    assert.ok(!html.includes("width:0%"));
    assert.ok(html.includes("—"));
    assert.ok(html.includes("<td></td>"));
    assert.ok(html.includes("← raíces"));
  });

  it("detalle: tres barras rotuladas declarado/observado/aceptado", () => {
    const doc = docProyeccion({ progress: { declared: 66, observed: 33, accepted: 100 } });
    const html = renderRaiz("root-03", { estado: "ok", doc: doc as never }, Date.parse("2026-10-13T12:00:00Z"));
    for (const rot of ["declarado", "observado", "aceptado"]) assert.ok(html.includes(rot), `falta rótulo ${rot}`);
    assert.ok(html.includes("width:66%"));
    assert.ok(html.includes("width:33%"));
    assert.ok(html.includes("width:100%"));
  });

  it("detalle inválida: 'proyección inválida' con el stem y las razones", () => {
    const html = renderRaiz("root-03", { estado: "invalida", razones: ["schema: se esperaba literal \"sistema-agentes.proyeccion.v1\""] }, 0);
    assert.ok(html.includes("raíz root-03"));
    assert.ok(html.includes("proyección inválida"));
    assert.ok(html.includes("sistema-agentes.proyeccion.v1"));
  });

  it("tope de unidades: 200 filas y '… y N unidades más'", () => {
    const units = Array.from({ length: 250 }, (_, i) => ({
      unitId: `unit-${String(i).padStart(3, "0")}`,
      state: "running",
      host: "mac-local",
      executor: "opencode",
      modelId: null,
      nextCheckAt: "2026-10-13T12:05:00Z",
      error: null,
    }));
    const doc = docProyeccion({ units });
    const html = renderRaiz("root-03", { estado: "ok", doc: doc as never }, Date.parse("2026-10-13T12:00:00Z"));
    assert.ok(html.includes(">unit-199<"));
    assert.ok(!html.includes(">unit-200<"));
    assert.ok(html.includes("… y 50 unidades más"));
  });

  it("XSS: stem y state con HTML salen escapados; el refresh es el único <script>", () => {
    const doc = docProyeccion({
      units: [{
        unitId: "unit-x",
        state: '<script>alert("x")</script>',
        host: "h",
        executor: "e",
        modelId: null,
        nextCheckAt: "2026-10-13T12:05:00Z",
        error: null,
      }],
    });
    const html = renderRaices(
      { estado: "ok", items: [{ stem: 'raiz-<b>"x"', nav: false, archivo: { estado: "ok", doc: doc as never } }] },
      0,
    );
    const detalle = renderRaiz("root-03", { estado: "ok", doc: doc as never }, 0);
    assert.ok(html.includes("&lt;b&gt;"));
    assert.ok(detalle.includes("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"));
    assert.ok(!detalle.includes("<script>alert"));
    assert.ok(!html.includes("<b>"));
    assert.equal(detalle.split("<script").length - 1, 1);
  });
});
