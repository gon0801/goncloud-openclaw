#!/usr/bin/env python3
"""SUA-05 (4.4 y 4.5): merge.py lee las cinco fuentes y decide con las cinco compuertas.

El gh es un juguete sh que registra el argv y despacha al fixture del store, así
que las pruebas ejercitan el argv real sin red. Los fixtures son los grabados de
#321 (F4 Medium abierto, rate limited), #322 (F1 Medium y dos Major en línea) y
#328 (un Major en línea; F4/F7 descartados), recortados a lo que merge.py consume.
"""

import contextlib
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import merge  # noqa: E402

FIXTURES = ROOT / "scripts" / "tests" / "fixtures" / "agent-work" / "merge"
RECETA = ROOT / "docs/evidence/agent-work/recetas-repos.json"
REPO = "gon0801/goncloud-openclaw"
HEAD321 = "a3967285970254a93c586bd1fbce326db0c6a51b"
HEAD322 = "bc7ddc0f8a95d9cb376d04339f5fc1864bac61ae"
HEAD328 = "9781ded29ec4e1155e824dffa8784cb5aa94c8d5"
MERGE_COMMIT = "0f9cafe000000000000000000000000000000000"

TOY = r"""#!/bin/sh
# gh de juguete (SUA-05 H4): registra el argv y despacha al fixture del store.
d=$(dirname "$0")
oid=0f9cafe000000000000000000000000000000000
printf '%s\n' "$*" >> "$d/argv.log"
case "$*" in
  'pr view '*' --json number,isDraft,headRefOid,state,comments')
    cat "$d/store/pr$3.json" ;;
  'pr view '*' --json state,mergeCommit')
    if [ -f "$d/store/mergeado.json" ]; then
      cat "$d/store/mergeado.json"
    else
      printf '{"state":"OPEN","mergeCommit":null}\n'
    fi ;;
  'pr merge '*)
    if [ -f "$d/store/fallar-merge" ]; then
      printf 'gh: el head del PR ya no es el del --match-head-commit\n' >&2
      exit 1
    fi
    printf '{"state":"MERGED","mergeCommit":{"oid":"%s"}}\n' "$oid" > "$d/store/mergeado.json"
    printf '{"ok":true}\n' ;;
  *actions/runs*)
    cat "$d/store/runs.json" ;;
  *check-runs*)
    cat "$d/store/checkruns.json" ;;
  */status*)
    cat "$d/store/status.json" ;;
  'api graphql'*)
    # Como el gh real: number tipado con -F; con -f llega como texto y GraphQL lo rechaza
    # (medido contra #330: "Variable $number of type Int! was provided invalid value").
    case "$*" in
      *'-F number='*) cat "$d/store/threads.json" ;;
      *) printf 'gh: Variable $number of type Int! was provided invalid value\n' >&2
         exit 1 ;;
    esac ;;
  */pulls/*/comments*)
    cat "$d/store/inline.json" ;;
  */collaborators/*/permission*)
    p=
    for a in "$@"; do
      case $a in */collaborators/*/permission) p=$a ;; esac
    done
    login=${p##*/collaborators/}
    login=${login%%/*}
    if [ -f "$d/store/permiso-$login.json" ]; then
      cat "$d/store/permiso-$login.json"
    else
      printf '{"permission":"admin"}\n'
    fi ;;
  'run view '*'--log-failed')
    cat "$d/store/logfallido.txt" ;;
  'run rerun '*)
    printf '{"ok":true}\n' ;;
  *)
    printf 'gh de juguete: patron inesperado: %s\n' "$*" >&2
    exit 9 ;;
esac
"""


class MergeConToy(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.store = self.tmp / "store"
        self.store.mkdir()
        self.bin = self.tmp / "gh"
        self.bin.write_text(TOY)
        self.bin.chmod(0o755)

    # --- helpers -----------------------------------------------------------

    def montar(self, numero, checkruns=None):
        """Copia los fixtures del PR al store y devuelve el pr.json cargado."""
        archivos = {
            f"pr{numero}.json": f"pr{numero}.json",
            (checkruns or f"pr{numero}-checkruns.json"): "checkruns.json",
            f"pr{numero}-status.json": "status.json",
            f"pr{numero}-threads.json": "threads.json",
            f"pr{numero}-inline.json": "inline.json",
        }
        for origen, destino in archivos.items():
            (self.store / destino).write_text((FIXTURES / origen).read_text())
        return json.loads((self.store / f"pr{numero}.json").read_text())

    def guardar(self, numero, pr):
        (self.store / f"pr{numero}.json").write_text(json.dumps(pr, ensure_ascii=False))

    def reescribir_check(self, nombre, **cambios):
        datos = json.loads((self.store / "checkruns.json").read_text())
        datos["check_runs"] = [
            {**r, **cambios} if r["name"] == nombre else r for r in datos["check_runs"]
        ]
        (self.store / "checkruns.json").write_text(json.dumps(datos))

    def quitar_check(self, nombre):
        datos = json.loads((self.store / "checkruns.json").read_text())
        datos["check_runs"] = [r for r in datos["check_runs"] if r["name"] != nombre]
        (self.store / "checkruns.json").write_text(json.dumps(datos))

    def con_adjudicacion(self, pr, cuerpo):
        pr["comments"].append({"author": {"login": "gon0801"}, "body": cuerpo})

    def escenario_verde(self, numero=321, head=HEAD321, checkruns="rapido-checkruns.json"):
        """El caso feliz: carril rápido. Desde G-sin-candados el F4 Medium abierto no frena, así
        que el caso feliz ya no necesita adjudicación."""
        return self.montar(numero, checkruns=checkruns)

    def correr(self, *argumentos):
        salida, error = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(salida), contextlib.redirect_stderr(error):
            codigo = merge.main([*argumentos, "--gh", str(self.bin)])
        return codigo, salida.getvalue(), error.getvalue()

    def listo(self, numero, sha, repo=REPO):
        return self.correr(
            "listo", str(numero), "--sha", sha, "--repo", repo, "--receta", str(RECETA)
        )

    def lineas_de_log(self):
        return (self.tmp / "argv.log").read_text().splitlines()

    def comentario_del_bot(self, pr):
        candidatos = [
            c
            for c in pr["comments"]
            if "<!-- ai-review:sticky -->" in c["body"] and c["author"]["login"] == "github-actions"
        ]
        return candidatos[-1]

    def severidad_del_hallazgo(self, pr, fid, severidad):
        """Cambia la severidad de un hallazgo del bloque del bot (para probar lo BLOQUEANTE)."""
        cuerpo = self.comentario_del_bot(pr)
        cuerpo["body"] = re.sub(
            rf'({fid}","title":"[^"]*","severity":")\w+', rf"\g<1>{severidad}", cuerpo["body"]
        )
        return pr

    def titulo_del_hallazgo(self, pr, fid, texto):
        """Cambia el título de un hallazgo del bloque del bot (para probar la marca)."""
        cuerpo = self.comentario_del_bot(pr)
        cuerpo["body"] = re.sub(rf'({fid}","title":")[^"]*', rf"\g<1>{texto}", cuerpo["body"])
        return pr

    # --- las tres grabadas, tal cual ----------------------------------------

    def test_pr321_tal_cual_esta_listo_con_el_medium_como_aviso(self):
        # G-sin-candados (David, 2026-10-19): el F4 Medium abierto sin adjudicar avisa y no frena.
        self.montar(321)
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 0)
        self.assertEqual(
            salida,
            '{"avisos":["coderabbit-rate-limited","hallazgo-menor-sin-adjudicar:F4"],'
            '"faltan":[],"listo":true}\n',
        )

    def test_pr322_tal_cual_niega_por_los_dos_mayores_y_avisa_el_f1(self):
        self.montar(322)
        codigo, salida, _ = self.listo(322, HEAD322)
        self.assertEqual(codigo, 1)
        self.assertEqual(
            json.loads(salida),
            {
                "listo": False,
                "faltan": [
                    "hallazgo-sin-adjudicar:cr:4293442167",
                    "hallazgo-sin-adjudicar:cr:4293442176",
                ],
                "avisos": [
                    "coderabbit-rate-limited",
                    "hallazgo-menor-sin-adjudicar:F1",
                    "hallazgo-menor-sin-adjudicar:F5",
                    "hallazgo-menor-sin-adjudicar:F6",
                    "hallazgo-menor-sin-adjudicar:F7",
                ],
            },
        )

    def test_pr328_tal_cual_no_listo_por_el_major_en_linea(self):
        self.montar(328)
        codigo, salida, _ = self.listo(328, HEAD328)
        self.assertEqual(codigo, 1)
        self.assertEqual(
            json.loads(salida),
            {
                "listo": False,
                "faltan": ["hallazgo-sin-adjudicar:cr:4295315734"],
                "avisos": ["coderabbit-rate-limited"],
            },
        )

    # --- compuerta 1: draft y head ------------------------------------------

    def test_carril_rapido_esta_listo_sin_ninguna_adjudicacion(self):
        self.escenario_verde()
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 0)
        self.assertEqual(
            json.loads(salida),
            {
                "listo": True,
                "faltan": [],
                "avisos": ["coderabbit-rate-limited", "hallazgo-menor-sin-adjudicar:F4"],
            },
        )
        # Los permisos se piden SOLO de los autores de líneas de adjudicación: sin adjudicaciones
        # no se pregunta ninguno.
        self.assertEqual(
            [linea for linea in self.lineas_de_log() if "/collaborators/" in linea],
            [],
        )

    def test_es_draft_no_esta_listo(self):
        pr = self.escenario_verde()
        pr["isDraft"] = True
        self.guardar(321, pr)
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["es-draft"])

    def test_head_movido_no_esta_listo(self):
        pr = self.escenario_verde()
        pr["headRefOid"] = "f00d000000000000000000000000000000000000"
        self.guardar(321, pr)
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["head-movido"])

    # --- compuerta 2: CI -----------------------------------------------------

    def test_ci_falta_cuando_un_requerido_no_corrio(self):
        self.escenario_verde()
        self.quitar_check("gate")
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["ci-falta:gate"])

    def test_ci_pendiente_cuando_la_ultima_no_termino(self):
        self.escenario_verde()
        self.reescribir_check("clasificador", status="in_progress", conclusion=None)
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["ci-pendiente:clasificador"])

    def test_ci_rojo_requerido(self):
        self.escenario_verde()
        self.reescribir_check("ci-contract", conclusion="failure")
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["ci-rojo:ci-contract"])

    def test_barrido_rojo_en_check_no_requerido(self):
        self.escenario_verde()
        self.reescribir_check("shards (3/5, 3)", conclusion="failure")
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["ci-rojo:shards (3/5, 3)"])

    def test_dedupe_de_job_reejecutado_pasa_por_la_ultima_corrida(self):
        # shards (1/5, 1) dos veces: la vieja failure y la nueva success; gana la nueva.
        self.escenario_verde(checkruns="dedupe-checkruns.json")
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 0)
        self.assertTrue(json.loads(salida)["listo"])

    # --- compuerta 3: CodeRabbit ---------------------------------------------

    def test_coderabbit_ausente(self):
        self.escenario_verde()
        estado = json.loads((self.store / "status.json").read_text())
        estado["statuses"] = []
        (self.store / "status.json").write_text(json.dumps(estado))
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["coderabbit-ausente"])

    def test_coderabbit_rojo(self):
        self.escenario_verde()
        estado = json.loads((self.store / "status.json").read_text())
        estado["statuses"][0]["state"] = "failure"
        (self.store / "status.json").write_text(json.dumps(estado))
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["coderabbit-rojo:failure"])

    def test_rate_limited_pasa_con_aviso(self):
        # El fixture lo trae ya: success con description "Review rate limited"
        # pasa y se avisa (decisión de David, 2026-09-25).
        self.escenario_verde()
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 0)
        self.assertIn("coderabbit-rate-limited", json.loads(salida)["avisos"])

    def test_hilo_menor_sin_resolver_solo_avisa(self):
        pr = self.montar(328)
        threads = json.loads((self.store / "threads.json").read_text())
        nodos = threads["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
        nodos[0]["isResolved"] = False
        (self.store / "threads.json").write_text(json.dumps(threads, ensure_ascii=False))
        self.con_adjudicacion(
            pr, f"adjudicado cr:4295315734 @{HEAD328}: no-aplica — falso positivo"
        )
        self.guardar(328, pr)
        codigo, salida, _ = self.listo(328, HEAD328)
        self.assertEqual(codigo, 0)
        self.assertEqual(
            json.loads(salida)["avisos"],
            ["coderabbit-rate-limited", "hilo-menor-sin-resolver:cr:4295315700"],
        )

    # --- compuerta 4: el bot --------------------------------------------------

    def test_impostor_con_los_marcadores_no_cuenta(self):
        pr = self.escenario_verde()
        self.comentario_del_bot(pr)["author"]["login"] = "gon0801"
        self.guardar(321, pr)
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["bot-ausente"])

    def test_evidencia_de_otro_head(self):
        pr = self.escenario_verde()
        cuerpo = self.comentario_del_bot(pr)
        cuerpo["body"] = cuerpo["body"].replace(HEAD321, "e" * 40)
        self.guardar(321, pr)
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["evidencia-de-otro-head"])

    def test_revision_parcial_por_partial(self):
        pr = self.escenario_verde()
        cuerpo = self.comentario_del_bot(pr)
        cuerpo["body"] = cuerpo["body"].replace(f"{HEAD321}:complete", f"{HEAD321}:partial")
        self.guardar(321, pr)
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 0)
        # El bloque legible sigue: su Medium abierto avisa aunque la marca esté a medias.
        self.assertEqual(
            json.loads(salida)["avisos"],
            ["coderabbit-rate-limited", "revision-parcial", "hallazgo-menor-sin-adjudicar:F4"],
        )

    def test_revision_parcial_por_forma_legada_sin_findings(self):
        pr = self.escenario_verde()
        cuerpo = self.comentario_del_bot(pr)
        cuerpo["body"] = re.sub(
            r"<!-- ai-review:findings=.*? -->\n?", "", cuerpo["body"], flags=re.DOTALL
        )
        self.guardar(321, pr)
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 0)
        # Sin bloque legible no hay hallazgos que avisar: solo la revisión a medias.
        self.assertEqual(
            json.loads(salida)["avisos"], ["coderabbit-rate-limited", "revision-parcial"]
        )

    def test_un_high_abierto_sin_adjudicar_sigue_negando(self):
        # Lo BLOQUEANTE se queda (David, orden G-sin-candados: High/Critical sin adjudicar frena).
        pr = self.severidad_del_hallazgo(self.escenario_verde(), "F4", "High")
        self.guardar(321, pr)
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["hallazgo-sin-adjudicar:F4"])

    def test_un_medium_marcado_de_credenciales_sigue_negando(self):
        # Lo BLOQUEANTE por marca también: seguridad, datos o credenciales en el título.
        pr = self.titulo_del_hallazgo(
            self.escenario_verde(), "F4", "fuga de credenciales en el archivo de receta"
        )
        self.guardar(321, pr)
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["hallazgo-sin-adjudicar:F4"])

    # --- compuerta 5: hallazgos y adjudicaciones ------------------------------

    def test_adjudicacion_de_head_viejo_no_vale(self):
        pr = self.severidad_del_hallazgo(
            self.montar(321, checkruns="rapido-checkruns.json"), "F4", "High"
        )
        self.con_adjudicacion(
            pr,
            "adjudicado F4 @ed4463879eb3139154ff16cf1e6e5fc1fb01451b: "
            "no-bloqueante — del push anterior",
        )
        self.guardar(321, pr)
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["hallazgo-sin-adjudicar:F4"])

    def test_adjudicacion_sin_permiso_no_cuenta_y_avisa(self):
        pr = self.severidad_del_hallazgo(self.escenario_verde(), "F4", "High")
        self.con_adjudicacion(
            pr, f"adjudicado F4 @{HEAD321}: no-bloqueante — triado, no frena el merge"
        )
        self.guardar(321, pr)
        (self.store / "permiso-gon0801.json").write_text('{"permission":"read"}\n')
        codigo, salida, _ = self.listo(321, HEAD321)
        self.assertEqual(codigo, 1)
        veredicto = json.loads(salida)
        self.assertEqual(veredicto["faltan"], ["hallazgo-sin-adjudicar:F4"])
        self.assertIn("adjudicacion-sin-permiso:gon0801", veredicto["avisos"])

    def test_pr328_con_adjudicacion_cr_esta_listo(self):
        pr = self.montar(328)
        self.con_adjudicacion(
            pr, f"adjudicado cr:4295315734 @{HEAD328}: no-aplica — falso positivo"
        )
        self.guardar(328, pr)
        codigo, salida, _ = self.listo(328, HEAD328)
        self.assertEqual(codigo, 0)
        self.assertTrue(json.loads(salida)["listo"])

    def test_hilo_sin_gemelo_rest_queda_cr_hilo(self):
        pr = self.montar(328)
        (self.store / "inline.json").write_text("[]")
        self.guardar(328, pr)
        codigo, salida, _ = self.listo(328, HEAD328)
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["faltan"], ["hallazgo-sin-adjudicar:cr:hilo-2"])
        self.con_adjudicacion(pr, f"adjudicado cr:hilo-2 @{HEAD328}: no-aplica — falso positivo")
        self.guardar(328, pr)
        codigo, salida, _ = self.listo(328, HEAD328)
        self.assertEqual(codigo, 0)
        self.assertTrue(json.loads(salida)["listo"])

    # --- faltan_por_rollup (la vía barata de M-25, función pura) ---------------

    def test_faltan_por_rollup_con_el_rollup_real_de_pr321(self):
        pr = json.loads((FIXTURES / "pr321.json").read_text())
        checks = ("clasificador", "ci-contract", "gate", "reconcile")
        self.assertEqual(merge.faltan_por_rollup(pr["statusCheckRollup"], checks), [])
        rojo = [dict(e) for e in pr["statusCheckRollup"]]
        for e in rojo:
            if e.get("name") == "gate":
                e["conclusion"] = "FAILURE"
        self.assertEqual(merge.faltan_por_rollup(rojo, checks), ["ci-rojo:gate"])
        self.assertEqual(
            merge.faltan_por_rollup(rojo, (*checks, "no-esta")),
            ["ci-rojo:gate", "ci-falta:no-esta"],
        )

    # --- mergear ---------------------------------------------------------------

    def test_mas_de_cien_hilos_falla_cerrado(self):
        # DeepSeek F7 y CodeRabbit en #330: un hilo sin resolver después del 100 no puede
        # quedar sin mirar.
        pr = self.escenario_verde()
        self.guardar(321, pr)
        threads = json.loads((self.store / "threads.json").read_text())
        threads["data"]["repository"]["pullRequest"]["reviewThreads"]["pageInfo"] = {
            "hasNextPage": True
        }
        (self.store / "threads.json").write_text(json.dumps(threads, ensure_ascii=False))
        codigo, salida, error = self.correr(
            "listo", "321", "--sha", HEAD321, "--repo", REPO, "--receta", str(RECETA)
        )
        self.assertEqual(codigo, 3)
        self.assertIn("más de 100 hilos", salida + error)

    def test_un_sha_corto_se_rechaza_en_el_borde(self):
        # DeepSeek F8 en #330: un sha corto daba head-movido; ahora se pide el completo.
        self.guardar(321, self.escenario_verde())
        codigo, salida, error = self.correr(
            "listo", "321", "--sha", HEAD321[:7], "--repo", REPO, "--receta", str(RECETA)
        )
        self.assertEqual(codigo, 3, salida + error)
        self.assertNotIn("head-movido", salida)
        self.assertIn("40", salida + error)

    def test_mergear_sobre_un_pr_ya_mergeado_con_otro_head_no_certifica(self):
        # DeepSeek F1 en #330: si el PR ya está MERGED con otro head, el recibo no puede
        # certificar como mergeado un sha que nunca entró.
        pr = self.escenario_verde()
        pr["state"] = "MERGED"
        pr["headRefOid"] = "b" * 40
        self.guardar(321, pr)
        codigo, salida, error = self.correr(
            "mergear", "321", "--sha", HEAD321, "--repo", REPO, "--receta", str(RECETA)
        )
        self.assertNotEqual(codigo, 0)
        self.assertIn("head-movido", salida + error)

    def test_mergear_mergea_deja_el_recibo_y_la_recorrida_es_ya_estaba(self):
        pr = self.escenario_verde()
        pr["state"] = "OPEN"
        self.guardar(321, pr)
        codigo, salida, _ = self.correr(
            "mergear", "321", "--sha", HEAD321, "--repo", REPO, "--receta", str(RECETA)
        )
        self.assertEqual(codigo, 0)
        self.assertEqual(
            json.loads(salida),
            {
                "mergeado": True,
                "mergeCommit": MERGE_COMMIT,
                "adjudicaciones": [],
                "avisos": ["coderabbit-rate-limited", "hallazgo-menor-sin-adjudicar:F4"],
            },
        )
        self.assertIn(
            f"pr merge 321 --repo {REPO} --squash --match-head-commit {HEAD321}",
            self.lineas_de_log(),
        )
        # La re-corrida con el PR ya MERGED no vuelve a mergear: es ya-estaba.
        pr["state"] = "MERGED"
        self.guardar(321, pr)
        codigo, salida, _ = self.correr(
            "mergear", "321", "--sha", HEAD321, "--repo", REPO, "--receta", str(RECETA)
        )
        self.assertEqual(codigo, 0)
        self.assertEqual(
            json.loads(salida),
            {"mergeado": True, "ya-estaba": True, "mergeCommit": MERGE_COMMIT},
        )
        self.assertEqual(
            [linea for linea in self.lineas_de_log() if linea.startswith("pr merge ")],
            [f"pr merge 321 --repo {REPO} --squash --match-head-commit {HEAD321}"],
        )

    def test_mergear_no_listo_sale_1_sin_llamar_a_pr_merge(self):
        pr = self.montar(322)
        pr["state"] = "OPEN"
        self.guardar(322, pr)
        codigo, salida, _ = self.correr(
            "mergear", "322", "--sha", HEAD322, "--repo", REPO, "--receta", str(RECETA)
        )
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida)["mergeado"], False)
        self.assertEqual(
            [linea for linea in self.lineas_de_log() if linea.startswith("pr merge ")], []
        )

    def test_mergear_con_head_movido_en_carrera_sale_3(self):
        pr = self.escenario_verde()
        pr["state"] = "OPEN"
        self.guardar(321, pr)
        (self.store / "fallar-merge").write_text("x")
        codigo, _, error = self.correr(
            "mergear", "321", "--sha", HEAD321, "--repo", REPO, "--receta", str(RECETA)
        )
        self.assertEqual(codigo, 3)
        self.assertIn("gh salió 1", error)
        self.assertTrue(any(linea.startswith("pr merge ") for linea in self.lineas_de_log()))

    # --- reintentar ------------------------------------------------------------

    def con_runs(self, runs, log_fallido):
        (self.store / "runs.json").write_text(
            json.dumps({"total_count": len(runs), "workflow_runs": runs})
        )
        (self.store / "logfallido.txt").write_text(log_fallido)

    def reintentar(self):
        return self.correr(
            "reintentar", "321", "--sha", HEAD321, "--repo", REPO, "--receta", str(RECETA)
        )

    def test_reintentar_con_firma_hace_un_solo_rerun_failed(self):
        self.con_runs(
            [
                {
                    "id": 14821033107,
                    "name": "shards (2/5, 2)",
                    "run_attempt": 1,
                    "conclusion": "failure",
                }
            ],
            "2026-10-16T10:12:49Z litellm.exceptions: APITimeoutError: "
            "litellm timed out after 10 seconds\n",
        )
        codigo, salida, _ = self.reintentar()
        self.assertEqual(codigo, 0)
        self.assertEqual(
            json.loads(salida),
            {"reintentado": True, "run": 14821033107, "firma": "timed out after"},
        )
        self.assertEqual(
            [linea for linea in self.lineas_de_log() if linea.startswith("run rerun ")],
            [f"run rerun 14821033107 --repo {REPO} --failed"],
        )

    def test_reintentar_agotado_con_run_attempt_2(self):
        self.con_runs(
            [
                {
                    "id": 14821033107,
                    "name": "shards (2/5, 2)",
                    "run_attempt": 2,
                    "conclusion": "failure",
                }
            ],
            "ECONNRESET en el runner\n",
        )
        codigo, salida, _ = self.reintentar()
        self.assertEqual(codigo, 1)
        self.assertEqual(
            json.loads(salida), {"reintentado": False, "causa": "reintento-agotado:14821033107"}
        )
        self.assertEqual(
            [linea for linea in self.lineas_de_log() if linea.startswith("run rerun ")], []
        )

    def test_reintentar_sin_fallas(self):
        self.con_runs([], "da igual\n")
        codigo, salida, _ = self.reintentar()
        self.assertEqual(codigo, 1)
        self.assertEqual(
            json.loads(salida), {"reintentado": False, "causa": "sin-falla-que-reintentar"}
        )

    def test_reintentar_fallo_real_sin_firma(self):
        self.con_runs(
            [{"id": 99, "name": "gate", "run_attempt": 1, "conclusion": "failure"}],
            "AssertionError: la unión de shards no da el inventario\n",
        )
        codigo, salida, _ = self.reintentar()
        self.assertEqual(codigo, 1)
        self.assertEqual(json.loads(salida), {"reintentado": False, "causa": "fallo-real:99"})

    def test_reintentar_reintenta_solo_el_primero_con_firma(self):
        self.con_runs(
            [
                {"id": 111, "name": "shards (2/5, 2)", "run_attempt": 1, "conclusion": "failure"},
                {"id": 222, "name": "gate", "run_attempt": 1, "conclusion": "failure"},
            ],
            "rate limit: API secondary rate limit\n",
        )
        codigo, salida, _ = self.reintentar()
        self.assertEqual(codigo, 0)
        self.assertEqual(
            json.loads(salida), {"reintentado": True, "run": 111, "firma": "rate limit"}
        )
        self.assertEqual(
            [linea for linea in self.lineas_de_log() if linea.startswith("run rerun ")],
            [f"run rerun 111 --repo {REPO} --failed"],
        )

    def test_reintentar_dedupe_por_nombre_gana_el_run_attempt_mayor(self):
        self.con_runs(
            [
                {"id": 111, "name": "shards (2/5, 2)", "run_attempt": 1, "conclusion": "failure"},
                {"id": 222, "name": "shards (2/5, 2)", "run_attempt": 2, "conclusion": "failure"},
            ],
            "ECONNRESET\n",
        )
        codigo, salida, _ = self.reintentar()
        self.assertEqual(codigo, 1)
        self.assertEqual(
            json.loads(salida), {"reintentado": False, "causa": "reintento-agotado:222"}
        )

    def test_reintentar_un_agotado_no_tapa_a_un_run_que_falta_reintentar(self):
        self.con_runs(
            [
                {"id": 111, "name": "shards (2/5, 2)", "run_attempt": 2, "conclusion": "failure"},
                {"id": 222, "name": "gate", "run_attempt": 1, "conclusion": "failure"},
            ],
            "ECONNRESET en el runner\n",
        )
        codigo, salida, _ = self.reintentar()
        self.assertEqual(codigo, 0)
        self.assertEqual(
            json.loads(salida), {"reintentado": True, "run": 222, "firma": "ECONNRESET"}
        )
        self.assertEqual(
            [linea for linea in self.lineas_de_log() if linea.startswith("run rerun ")],
            [f"run rerun 222 --repo {REPO} --failed"],
        )

    # --- la receta ----------------------------------------------------------------

    def test_repo_sin_receta_sale_3(self):
        with tempfile.TemporaryDirectory() as temp:
            ruta = Path(temp) / "receta.json"
            ruta.write_text(json.dumps({"schema": "agent-work.recetas.v1", "repos": {}}))
            codigo, _, error = self.correr(
                "listo", "321", "--sha", HEAD321, "--repo", "foo/bar", "--receta", str(ruta)
            )
        self.assertEqual(codigo, 3)
        self.assertIn("repo-sin-receta", error)

    def test_receta_con_schema_malo_sale_3(self):
        with tempfile.TemporaryDirectory() as temp:
            ruta = Path(temp) / "receta.json"
            ruta.write_text(json.dumps({"schema": "otro", "repos": {REPO: {}}}))
            codigo, _, error = self.correr("listo", "321", "--sha", HEAD321, "--receta", str(ruta))
        self.assertEqual(codigo, 3)
        self.assertIn("receta", error)

    def test_mergear_exige_squash(self):
        with tempfile.TemporaryDirectory() as temp:
            receta = json.loads(RECETA.read_text())
            receta["repos"][REPO]["metodo"] = "merge"
            ruta = Path(temp) / "receta.json"
            ruta.write_text(json.dumps(receta))
            codigo, _, error = self.correr(
                "mergear", "321", "--sha", HEAD321, "--receta", str(ruta)
            )
        self.assertEqual(codigo, 3)
        self.assertIn("squash", error)


if __name__ == "__main__":
    unittest.main(verbosity=2)
