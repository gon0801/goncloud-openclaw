/**
 * progress.test.ts — contrato del dato runbook-progress.v1 (Fase 7 / 7.1, luego 7.3).
 *
 * 7.1: los fixtures versionados son la única fuente; los válidos deben pasar el
 * validador y `invalido.json` debe fallar con CINCO razones nombradas. Este
 * archivo se escribió ANTES de que existiera `lib.ts` (rojo primero): hasta 7.3
 * la importación de abajo falla y la batería no puede estar verde.
 *
 * Declaración de `omitido`: ese estado de carril NO aparece en ningún fixture de
 * Fase 6. Existe en la lista cerrada del spec para runbooks futuros que CANCELEN
 * un carril (spec runbook-progress.v1, "Valores cerrados"); Fase 6 no canceló
 * ninguno, así que inventarlo aquí sería exactamente lo que el spec prohíbe
 * ("lo que no se sabe se escribe unknown o null, nunca se inventa").
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import {
  CARRIL_ESTADOS,
  CI_ESTADOS,
  CODERABBIT_ESTADOS,
  COLA_ESTADOS,
  EVENTOS_TOPE,
  type Evento,
  type ProgresoDoc,
  derivar,
  esc,
  fusionarEventos,
  renderTablero,
  truncar,
  validarFase,
  validarProgreso,
} from "./lib.ts";

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8"));
}

/** Copia profunda mutable para mutar campo por campo sin tocar el fixture. */
function clon<T>(v: T): T {
  return structuredClone(v);
}

describe("validarProgreso sobre fixtures (7.1)", () => {
  for (const nombre of ["prueba999-en-curso", "prueba999-cerrada", "prueba999-diez-prs"]) {
    it(`${nombre}.json pasa`, () => {
      const veredicto = validarProgreso(fixture(`${nombre}.json`));
      assert.equal(
        veredicto.ok,
        true,
        `${nombre} debe validar; razones: ${JSON.stringify(veredicto.razones)}`,
      );
    });
  }

  it("invalido.json falla con exactamente cinco razones nombradas", () => {
    const veredicto = validarProgreso(fixture("invalido.json"));
    assert.equal(veredicto.ok, false);
    assert.equal(
      veredicto.razones.length,
      5,
      `se plantaron cinco problemas; llegaron ${veredicto.razones.length}: ${JSON.stringify(veredicto.razones)}`,
    );
    // Cada razón nombra el campo que la causó, en el orden del fixture:
    // schema, fase, titulo, repo, estado.
    assert.match(veredicto.razones[0], /schema/, "la primera razón debe nombrar schema");
    assert.match(veredicto.razones[1], /fase/, "la segunda razón debe nombrar fase");
    assert.match(veredicto.razones[2], /titulo/, "la tercera razón debe nombrar titulo");
    assert.match(veredicto.razones[3], /repo/, "la cuarta razón debe nombrar repo");
    assert.match(veredicto.razones[4], /estado/, "la quinta razón debe nombrar estado");
  });

  it("ningún fixture de Fase 6 usa el estado omitido (declarado, no representado)", () => {
    for (const nombre of ["prueba999-en-curso", "prueba999-cerrada", "prueba999-diez-prs"]) {
      const crudo = readFileSync(new URL(`./fixtures/${nombre}.json`, import.meta.url), "utf8");
      assert.ok(!crudo.includes("omitido"), `${nombre} no debería contener 'omitido'`);
    }
  });
});

// ---------------------------------------------------------------------------
// 7.3 — núcleo puro. Cada bloque de abajo clava un mutante de la DoD: si se
// quita esc(), se invierte truncar/escapar, se quita el truncado o se acepta
// un valor fuera de lista, ESTA batería se pone en rojo.
// ---------------------------------------------------------------------------

describe("validarFase (7.3)", () => {
  it("acepta las fases con forma cerrada", () => {
    for (const s of ["6", "7", "42", "7.3", "123.456"]) assert.equal(validarFase(s), true, s);
  });

  it("rechaza /, .., path traversal y basura (es clave de disco y URL)", () => {
    for (const s of [
      "../../openclaw.json", "6/../../openclaw.json", "..", ".", "6.", ".6", "-1", "a",
      " 6", "6 ", "", "1234", "6.1234", "#", "%2e%2e",
    ]) {
      assert.equal(validarFase(s), false, `debería rechazar: ${JSON.stringify(s)}`);
    }
    for (const s of [null, undefined, 6, {}, [], Number.NaN]) {
      assert.equal(validarFase(s), false, `debería rechazar no-string: ${String(s)}`);
    }
  });
});

describe("validarProgreso: valores cerrados (7.3)", () => {
  const base = () => clon(fixture("prueba999-en-curso.json")) as ProgresoDoc;

  it("rechaza un estado de carril fuera de lista", () => {
    const d = base();
    d.carriles[0].estado = "volando";
    const v = validarProgreso(d);
    assert.equal(v.ok, false);
    assert.ok(v.razones.some((r) => /estado/.test(r) && /lista cerrada/.test(r)));
  });

  it("rechaza ci y coderabbit fuera de lista", () => {
    const d = base();
    d.carriles[0].ci = "verde-ish";
    d.carriles[0].coderabbit = "ok";
    const v = validarProgreso(d);
    assert.ok(v.razones.some((r) => /\.ci:/.test(r)));
    assert.ok(v.razones.some((r) => /\.coderabbit:/.test(r)));
  });

  it("rechaza estado y verificado de cola fuera de lista", () => {
    const d = base();
    d.cola[0].estado = "navegando";
    d.cola[0].verificado = "quizás";
    const v = validarProgreso(d);
    assert.ok(v.razones.some((r) => /cola\[0\]\.estado/.test(r)));
    assert.ok(v.razones.some((r) => /cola\[0\]\.verificado/.test(r)));
  });

  it("rechaza repo con ';' o que empiece con '-' (inyección de argv)", () => {
    for (const veneno of ["a/b; calc.exe", "--template x", "-algo/mal", "a/b/c", "a/", "/b", ""]) {
      const d = base();
      d.carriles[0].repo = veneno;
      const v = validarProgreso(d);
      assert.equal(v.ok, false, `debería rechazar repo: ${veneno}`);
      assert.ok(v.razones.some((r) => /carriles\[0\]\.repo/.test(r)), veneno);
    }
  });

  it("el veneno de repo también se rechaza en la cola", () => {
    const d = base();
    d.cola[0].prs = [{ repo: "a/b; calc.exe", pr: 1 }];
    const v = validarProgreso(d);
    assert.ok(v.razones.some((r) => /prs\[0\]\.repo/.test(r)));
  });

  it("rechaza pr fuera de rango o no entero", () => {
    for (const pr of [0, -1, 1.5, "15", 10_000_000, Number.NaN]) {
      const d = base();
      d.carriles[0].pr = pr as unknown as number;
      const v = validarProgreso(d);
      assert.equal(v.ok, false, `debería rechazar pr: ${String(pr)}`);
    }
    const d = base();
    d.carriles[0].pr = 9_999_999;
    d.carriles[0].pr = null;
    assert.equal(validarProgreso(d).ok, true, "null y < 10000000 son válidos");
  });

  it("paso_loop satura en 8: un 9 se rechaza", () => {
    const d = base();
    d.carriles[0].paso_loop = 9;
    assert.ok(validarProgreso(d).razones.some((r) => /paso_loop/.test(r)));
    d.carriles[0].paso_loop = 8;
    assert.equal(validarProgreso(d).ok, true);
  });

  it("atorado exige detenido_por (regla 7 del spec), en carriles y en cola", () => {
    const d = base();
    d.carriles[0].estado = "atorado";
    d.carriles[0].detenido_por = null;
    assert.ok(validarProgreso(d).razones.some((r) => /detenido_por.*atorado/.test(r)));
    const d2 = base();
    d2.cola[0].estado = "atorado";
    d2.cola[0].detenido_por = null;
    assert.ok(validarProgreso(d2).razones.some((r) => /detenido_por.*atorado/.test(r)));
  });

  it("rechaza textos de 301 (y siguiente_paso de 161)", () => {
    const d = base();
    d.carriles[0].nombre = "n".repeat(301);
    assert.ok(validarProgreso(d).razones.some((r) => /nombre.*300|nombre.*excede/.test(r)));
    const d2 = base();
    d2.siguiente_paso = "s".repeat(161);
    assert.ok(validarProgreso(d2).razones.some((r) => /siguiente_paso.*160|siguiente_paso.*excede/.test(r)));
  });

  it("rechaza schema distinto y fase con traversal (aunque el resto esté bien)", () => {
    const d = base();
    d.schema = "runbook-progress.v2";
    assert.ok(validarProgreso(d).razones.some((r) => /schema/.test(r)));
    const d2 = base();
    d2.fase = "6/../../openclaw.json";
    assert.ok(validarProgreso(d2).razones.some((r) => /fase/.test(r)));
  });

  it("las listas cerradas exportadas son las del spec (ancla contra deriva)", () => {
    assert.deepEqual([...CARRIL_ESTADOS], [
      "pendiente", "implementando", "revision-cruzada", "coderabbit", "auditoria-lead",
      "en-cola", "mergeado", "atorado", "revertido", "omitido",
    ]);
    assert.deepEqual([...CI_ESTADOS], ["pendiente", "verde", "rojo", "sin-ci", "unknown"]);
    assert.deepEqual([...CODERABBIT_ESTADOS], ["pendiente", "limpio", "con-hallazgos", "sin-cuota", "unknown"]);
    assert.deepEqual([...COLA_ESTADOS], [
      "pendiente", "esperando-ventana", "mergeando", "sync", "verificado", "revertido", "atorado",
    ]);
  });
});

describe("derivar (7.3)", () => {
  const T0 = Date.parse("2026-09-16T19:10:00Z");

  it("en-curso: 1/7 mergeado, G atorado, Q1 siguiente, 30 min del último evento", () => {
    const doc = fixture("prueba999-en-curso.json") as ProgresoDoc;
    const d = derivar(doc, T0);
    assert.equal(d.totalCarriles, 7);
    assert.equal(d.mergeados, 1);
    assert.equal(d.porcentajeMergeado, Math.round(100 / 7));
    assert.deepEqual(d.carrilesAtorados, ["G"]);
    assert.equal(d.siguienteCola?.id, "Q1");
    assert.equal(d.siguienteCola?.estado, "pendiente");
    assert.equal(d.minutosDesdeUltimoEvento, 30);
  });

  it("cerrada: 100%, sin atorados, sin siguiente de cola", () => {
    const doc = fixture("prueba999-cerrada.json") as ProgresoDoc;
    const d = derivar(doc, T0);
    assert.equal(d.porcentajeMergeado, 100);
    assert.deepEqual(d.carrilesAtorados, []);
    assert.equal(d.siguienteCola, null);
  });

  it("sin eventos ni carriles: null y 0, no NaN", () => {
    const doc = clon(fixture("prueba999-en-curso.json")) as ProgresoDoc;
    doc.eventos = [];
    for (const c of doc.carriles) c.ultimo_evento = null;
    const d = derivar(doc, T0);
    assert.equal(d.minutosDesdeUltimoEvento, null);
    const vacio = derivar({ ...doc, carriles: [], cola: [] }, T0);
    assert.equal(vacio.porcentajeMergeado, 0);
    assert.equal(vacio.totalCarriles, 0);
  });
});

describe("renderTablero (7.3)", () => {
  const T0 = Date.parse("2026-09-16T19:10:00Z");

  it("banner de atencion_requerida arriba de todo, y siguiente_paso antes de las tablas", () => {
    const doc = clon(fixture("prueba999-en-curso.json")) as ProgresoDoc;
    doc.atencion_requerida = { necesaria: true, motivo: "Reversa de Q4 falló dos veces", desde: "2026-09-16T18:00:00Z" };
    const html = renderTablero(doc, derivar(doc, T0));
    const iBanner = html.indexOf('class="atencion"');
    const iH1 = html.indexOf("<h1>");
    const iPaso = html.indexOf(doc.siguiente_paso.slice(0, 40));
    const iTabla = html.indexOf("<h2>Carriles</h2>");
    assert.ok(iBanner > -1, "falta el banner");
    assert.ok(iBanner < iH1, "el banner no está arriba de todo");
    assert.ok(iPaso > -1 && iPaso < iTabla, "siguiente_paso no aparece como primera frase");
    // Sin atencion no hay banner (el fixture en-curso tiene necesaria:false).
    const html2 = renderTablero(fixture("prueba999-en-curso.json") as ProgresoDoc, derivar(fixture("prueba999-en-curso.json") as ProgresoDoc, T0));
    assert.ok(!html2.includes('class="atencion"'));
  });

  it("sin cruce: rótulo literal 'GitHub: sin verificar'", () => {
    const doc = fixture("prueba999-en-curso.json") as ProgresoDoc;
    const html = renderTablero(doc, derivar(doc, T0));
    assert.ok(html.includes("GitHub: sin verificar"));
  });

  it("HTML autocontenido: sin scripts, sin fuentes remotas, sin recursos externos", () => {
    const doc = fixture("prueba999-en-curso.json") as ProgresoDoc;
    const html = renderTablero(doc, derivar(doc, T0));
    assert.ok(!html.includes("<script"), "no debe haber scripts");
    assert.ok(!html.includes("<link"), "no debe cargar recursos");
    assert.ok(!html.includes("@import"), "no debe importar CSS externo");
    assert.ok(!/https?:\/\//.test(html), "no debe referenciar nada remoto");
    assert.ok(html.startsWith("<!doctype html>"));
    assert.ok(html.includes("<style>"));
  });

  it("un <script> en titulo, en repo y en un check de GitHub NUNCA aparece literal (mutante quitar esc)", () => {
    const doc = clon(fixture("prueba999-en-curso.json")) as ProgresoDoc;
    doc.titulo = "<script>alert(1)</script>";
    doc.carriles[0].repo = "a/b<script>repo</script>";
    doc.carriles[0].pr = 1;
    doc.siguiente_paso = "<script>paso</script>";
    const github = { "a/b<script>repo</script>#1": "<script>check-malo</script>" };
    const html = renderTablero(doc, derivar(doc, T0), github);
    assert.ok(!html.includes("<script>alert"), "el script del titulo apareció literal");
    assert.ok(!html.includes("<script>repo"), "el script del repo apareció literal");
    assert.ok(!html.includes("<script>check-malo"), "el script del check de GitHub apareció literal");
    // ...y la forma escapada SÍ está: se pintó, no se ocultó.
    assert.ok(html.includes("&lt;script&gt;alert(1)&lt;/script&gt;"));
  });

  it("ninguna entidad queda cortada: truncar PRIMERO, escapar después (mutante invertir orden)", () => {
    const doc = clon(fixture("prueba999-en-curso.json")) as ProgresoDoc;
    // Un '&' que cae justo en la frontera del truncado: escapar-primero produciría
    // "...&am" (entidad cortada); truncar-primero produce "...&amp;B" completa.
    doc.titulo = "A".repeat(298) + "&" + "B".repeat(100);
    const html = renderTablero(doc, derivar(doc, T0));
    const entidadRota = /&(?!amp;|lt;|gt;|quot;|#39;)/;
    assert.ok(
      !entidadRota.test(html),
      "el HTML tiene un & que no abre una entidad completa: se escapó antes de truncar",
    );
  });

  it("el truncado existe en el render aunque el validador ya rechace >300 (mutante quitar truncado)", () => {
    const doc = clon(fixture("prueba999-en-curso.json")) as ProgresoDoc;
    doc.titulo = "x".repeat(350);
    const html = renderTablero(doc, derivar(doc, T0));
    assert.ok(!html.includes("x".repeat(320)), "el texto de 350 entró entero: no hay truncado");
    assert.ok(html.includes("x".repeat(300) + "…"), "falta el truncado a 300 con marcador");
    // siguiente_paso trunca a 160.
    doc.siguiente_paso = "p".repeat(200);
    const html2 = renderTablero(doc, derivar(doc, T0));
    assert.ok(html2.includes("p".repeat(160) + "…"));
    assert.ok(!html2.includes("p".repeat(170)));
  });

  it("esc y truncar como unidades: el orden queda fijado por el caso frontera", () => {
    const v = "A".repeat(298) + "&" + "B".repeat(100);
    const entidadRota = /&(?!amp;|lt;|gt;|quot;|#39;)/;
    // El orden correcto (truncar → escapar) nunca deja un & que no abra una entidad.
    assert.ok(!entidadRota.test(esc(truncar(v, 300))), "truncar→escapar dejó una entidad rota");
    // El orden invertido (escapar → truncar) CORTA la entidad: es el valor que el
    // render no debe producir jamás, y la razón por la que el orden es ley.
    assert.ok(entidadRota.test(truncar(esc(v), 300)), "escapar→truncar no cortó la entidad; el caso frontera dejó de discriminar");
  });

  it("residuales y eventos se pintan, y el html es determinístico entre llamadas", () => {
    const doc = fixture("prueba999-en-curso.json") as ProgresoDoc;
    const d = derivar(doc, T0);
    const h1 = renderTablero(doc, d);
    const h2 = renderTablero(doc, d);
    assert.equal(h1, h2, "dos renders con los mismos insumos difieren");
    assert.ok(h1.includes("6.2: conteo de"));
    assert.ok(h1.includes("PROPONGO"));
  });
});

describe("fusionarEventos (7.3)", () => {
  const e = (at: string, que: string, carril: string | null = null): Evento => ({ at, que, carril });

  it("append-only: no duplica lo ya visto y NO pierde los previos (mutante perder previos)", () => {
    const e1 = e("2026-09-16T10:00:00Z", "arranque");
    const e2 = e("2026-09-16T11:00:00Z", "APPROVE lead");
    const e3 = e("2026-09-16T12:00:00Z", "mergeado");
    const fusion = fusionarEventos([e1, e2], [e2, e3]);
    assert.deepEqual(fusion, [e1, e2, e3]);
  });

  it("dos eventos con misma clave de contenido (at+carril+que) son el mismo evento", () => {
    const e1 = e("2026-09-16T10:00:00Z", "arranque", "A");
    const fusion = fusionarEventos([e1], [{ at: "2026-09-16T10:00:00Z", que: "arranque", carril: "A" }]);
    assert.equal(fusion.length, 1);
  });

  it("el tope conserva la cola más reciente", () => {
    const previo = Array.from({ length: EVENTOS_TOPE }, (_, i) => e(`2026-09-16T0${i % 10}:${i}Z`, `viejo-${i}`));
    const nuevo = [e("2026-09-17T00:00:00Z", "nuevo")];
    const fusion = fusionarEventos(previo, nuevo);
    assert.equal(fusion.length, EVENTOS_TOPE);
    assert.equal(fusion[fusion.length - 1].que, "nuevo");
    assert.ok(!fusion.some((x) => x.que === "viejo-0"), "recortó por el frente, no por la cola");
  });
});
