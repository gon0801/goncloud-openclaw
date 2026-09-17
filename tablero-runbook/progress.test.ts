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

import { validarProgreso } from "./lib.ts";

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8"));
}

describe("validarProgreso sobre fixtures (7.1)", () => {
  for (const nombre of ["fase6-en-curso", "fase6-cerrada", "fase6-diez-prs"]) {
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
    for (const nombre of ["fase6-en-curso", "fase6-cerrada", "fase6-diez-prs"]) {
      const crudo = readFileSync(new URL(`./fixtures/${nombre}.json`, import.meta.url), "utf8");
      assert.ok(!crudo.includes("omitido"), `${nombre} no debería contener 'omitido'`);
    }
  });
});
