#!/bin/bash
# corrida/autoridad-merge.sh (Task 7): gate PURO de autoridad de merge
# automatico. No ejecuta nada: valida rol, registro, authorization_ref contra
# la tabla versionada de preaprobaciones, alcance (repo/rama/operacion),
# automatic_routing, recibo saikit-entrega.v1 del head y CI vigente; si todo
# pasa, imprime UNA linea de delegacion a corrida.sh compuerta ... merge,
# que es la unica ruta (sin bypass GraphQL directo). 0 = autorizado.
autoridad_merge_verificar() { # $1 rol $2 run $3 reg $4 lane $5 sha $6 evidence $7 receipt
  local rol="$1" run="$2" reg="$3" lane="$4" sha="$5" evidence="$6" receipt="$7"
  ATABLA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preaprobaciones.v1.json" \
  ALANE="$lane" ASHA="$sha" AREG="$reg" AEV="$evidence" ARCP="$receipt" AROL="$rol" \
  python3 - <<'PY'
import json, os, re, sys

ROL_OK = {"implementer", "ingenieria"}
rol = os.environ["AROL"]
if rol not in ROL_OK:
    print(f"FALLO: rol sin autoridad de merge: {rol} (solo implementer/ingenieria)", file=sys.stderr)
    sys.exit(1)

def muere(motivo):
    print(f"FALLO: {motivo}", file=sys.stderr)
    sys.exit(1)

def cargar_json(ruta, motivo):
    try:
        return json.load(open(ruta))
    except Exception:
        muere(motivo)

reg = cargar_json(os.environ["AREG"], "registro de corrida ilegible")
if not isinstance(reg, dict) or reg.get("schema") != "corrida.v2":
    muere("el registro no es corrida.v2")
sha = os.environ["ASHA"]
if not re.fullmatch(r"[0-9a-f]{40}", sha or ""):
    muere("SHA invalido (se esperaba 40 hex minusculas)")
if not isinstance(reg.get("authorization_ref"), str) or not reg.get("authorization_ref"):
    muere("authorization_ref ausente")
auto = (reg.get("automatic_routing") or {}).get("enabled")
if auto is not True:
    muere("automatic_routing.enabled != true")

lane_id = os.environ["ALANE"]
lane = None
for c in reg.get("lanes") or []:
    if isinstance(c, dict) and c.get("id") == lane_id:
        lane = c
if lane is None:
    muere(f"carril inexistente: {lane_id}")

ref = reg["authorization_ref"]
tabla = cargar_json(os.environ["ATABLA"], "tabla de preaprobaciones ilegible")
entrada = None
for p in tabla.get("preaprobaciones") or []:
    if isinstance(p, dict) and p.get("id") == ref:
        entrada = p
if entrada is None:
    muere(f"authorization_ref desconocido: {ref}")
if entrada.get("decision") != "Aprobado":
    muere(f"authorization_ref no aprobado: {ref} ({entrada.get('decision')})")
repo = lane.get("repo") or ""
if entrada.get("repo") and repo and entrada["repo"] != repo:
    muere(f"authorization_ref fuera de alcance: repo {repo}")
rama = lane.get("branch") or ""
pat = str(entrada.get("rama") or "")
if pat and rama:
    if pat.endswith("*"):
        if not rama.startswith(pat[:-1]):
            muere(f"authorization_ref fuera de alcance: rama {rama}")
    elif pat != rama:
        muere(f"authorization_ref fuera de alcance: rama {rama}")
if entrada.get("operacion") not in (None, "", "merge"):
    muere("authorization_ref fuera de alcance: operacion")

ev = cargar_json(os.environ["AEV"], "evidence ilegible")
if ev.get("schema") != "saikit-entrega.v1":
    muere("evidence sin saikit-entrega.v1")
ci = ev.get("ci") or {}
if ci.get("sha") != sha:
    muere("CI no corresponde al SHA pedido")
if ci.get("conclusion") not in ("success", "verde"):
    muere("CI no vigente para el SHA pedido")

rec = cargar_json(os.environ["ARCP"], "recibo del kit ilegible")
if rec.get("schema") != "saikit-entrega.v1":
    muere("recibo sin saikit-entrega.v1")
if rec.get("headRefOid") != sha:
    muere("recibo de un head distinto (expectedHeadOid)")
if rec.get("ci") and rec["ci"].get("sha") not in (None, sha):
    muere("recibo de CI viejo")

# 14.4 r2 B1: el alcance es obligatorio y cierra ante la duda. El repo que
# manda es el de la EVIDENCIA y del RECIBO (la compuerta mergea ese repo);
# el carril puede no traer repo, pero entonces no hay alcance verificable.
repo_evidencia = ev.get("repo") or ""
repo_recibo = rec.get("repo") or ""
repo_preaprobacion = str(entrada.get("repo") or "")
if not repo_evidencia:
    muere("authorization_ref sin alcance: la evidencia no trae repo")
if not repo_recibo:
    muere("authorization_ref sin alcance: el recibo no trae repo")
if not repo_preaprobacion:
    muere("authorization_ref sin alcance: la preaprobacion no declara repo")
if repo_evidencia != repo_recibo:
    muere(f"authorization_ref fuera de alcance: evidencia y recibo de repos distintos ({repo_evidencia} vs {repo_recibo})")
if repo_evidencia != repo_preaprobacion:
    muere(f"authorization_ref fuera de alcance: repo {repo_evidencia} no casa la preaprobacion {repo_preaprobacion}")
rama_pre = str(entrada.get("rama") or "")
if not rama_pre:
    muere("authorization_ref sin alcance: la preaprobacion no declara rama")
if rama and not rama.startswith(rama_pre.rstrip("*").rstrip("/")):
    muere(f"authorization_ref fuera de alcance: rama {rama} no casa {rama_pre}")
if entrada.get("operacion") not in (None, "", "merge"):
    muere("authorization_ref fuera de alcance: operacion")

print("OK")
PY
  local rc=$?
  [ "$rc" -ne 0 ] && return 1
  # Unica ruta de ejecucion: la compuerta del Task 6 (delega al kit del
  # SummonAIKit, que fija expectedHeadOid). Sin bypass GraphQL directo.
  printf 'DELEGAR: bash scripts/mac/corrida.sh compuerta %s %s merge --sha %s --evidence %s\n' \
    "$run" "$lane" "$sha" "$evidence"
  return 0
}

# Wrapper del test/llamador: fija el carril para el gate.
autoridad_merge() { # $1 rol $2 run $3 reg $4 lane $5 sha $6 evidence $7 receipt
  ALANE="$4" autoridad_merge_verificar "$@"
}

# Entrada directa: bash corrida/autoridad-merge.sh <rol> <run> <reg> <lane> <sha> <ev> <receipt>
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  autoridad_merge "$@"
fi
