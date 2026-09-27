#!/usr/bin/env bash
# Doble de test de tools/lib/entrega_contract.sh del kit SummonAIKit.
# Implementa la MISMA interfaz soportada (mismas funciones, codigos y
# prefijo "recibo:") sobre `gh` del PATH (falso en tests). Solo cubre lo que
# la compuerta consume: entrega_recibo_del_pr y entrega_validar. Produccion
# sourcea el kit real via SAIKIT_KIT_DIR; este archivo jamas se instala.
#
# Correspondencia con el kit real (Solo lectura en el repo hermano):
#   entrega_recibo_del_pr <repo> <pr> <sha> [lead] -> ultimo APPROVE lead
#     <sha> con bloque json saikit-entrega.v1; REVOKE posterior del mismo
#     autor con el sha lo anula. 0 hallado, 1 sin recibo o revocado,
#     3 API inaccesible.
#   entrega_validar <recibo|-> <repo> <pr> <sha> -> coords, schema, clase
#     (codigo exige 3 roles distintos, PASS/APPROVE; fast exige autor),
#     ci.workflow/evidencia, sin bloqueantes. 0 cumple, 1 no cumple,
#     3 ilegible.
ENTREGA_SCHEMA="saikit-entrega.v1"

entrega_body_trae_revoke() {
  printf '%s' "$1" | grep -Fq "REVOKE"
}

entrega_recibo_del_pr() {
  if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    printf 'recibo: uso: entrega_recibo_del_pr <repo> <pr> <sha> [lead]\n' >&2
    return 3
  fi
  local repo="$1" pr="$2" sha="$3" lead="${4:-}"
  [ -n "$repo" ] && [ -n "$pr" ] && [ -n "$sha" ] \
    || { printf 'recibo: coordenadas vacias: repo, pr y sha son obligatorios\n' >&2; return 3; }
  local raw
  raw="$(gh api "repos/$repo/issues/$pr/comments" --paginate 2>/dev/null)" \
    || { printf 'recibo: no se pudo consultar los comentarios del PR %s#%s (gh api fallo)\n' "$repo" "$pr" >&2; return 3; }
  case "$raw" in
    *[![:space:]]*) ;;
    *) printf 'recibo: no se pudo consultar los comentarios del PR %s#%s (respuesta vacia)\n' "$repo" "$pr" >&2; return 3 ;;
  esac
  STUB_RAW="$raw" STUB_SHA="$sha" STUB_LEAD="$lead" python3 - <<'PY'
import json,os,re,sys
sha=os.environ["STUB_SHA"]
lead=os.environ.get("STUB_LEAD") or ""
try:
    pages=[json.loads(l) for l in os.environ["STUB_RAW"].splitlines() if l.strip()]
except Exception:
    sys.stderr.write("recibo: no se pudo consultar los comentarios del PR (pagina no-JSON)\n")
    sys.exit(3)
candidato=""; autor=""; revocado=False
for page in pages:
    if not isinstance(page,list):
        sys.stderr.write("recibo: no se pudo consultar los comentarios del PR (la pagina no es una lista)\n")
        sys.exit(3)
    for c in page:
        login=((c.get("user") or {}).get("login")) or ""
        body=c.get("body") or ""
        if lead and login!=lead: continue
        if "REVOKE" in body:
            if candidato and login==autor:
                if sha in body: revocado=True
                else: sys.stderr.write("recibo: aviso: REVOKE visto sin efecto: el comentario de %s no trae el sha completo; el recibo sigue vivo\n"%login)
            continue
        if ("APPROVE lead %s"%sha) not in body: continue
        for b in re.findall(r"```json(.*?)```",body,re.S):
            try: j=json.loads(b)
            except Exception: continue
            if isinstance(j,dict) and j.get("schema")=="saikit-entrega.v1":
                candidato=b; autor=login; revocado=False
                break
if not candidato:
    sys.stderr.write("recibo: sin recibo: el PR no trae un comentario APPROVE lead %s con entrega saikit-entrega.v1\n"%sha)
    sys.exit(1)
if revocado:
    sys.stderr.write("recibo: revocado: el recibo de %s quedo anulado por un REVOKE posterior del mismo autor\n"%sha)
    sys.exit(1)
sys.stdout.write(candidato)
PY
}

entrega_validar() {
  if [ "$#" -ne 4 ]; then
    printf 'recibo: uso: entrega_validar <recibo-json|-> <repo> <pr> <sha>\n' >&2
    return 3
  fi
  local origen="$1" repo="$2" pr="$3" sha="$4"
  [ -n "$repo" ] && [ -n "$pr" ] && [ -n "$sha" ] \
    || { printf 'recibo: coordenadas vacias: repo, pr y sha son obligatorios\n' >&2; return 3; }
  local txt
  if [ "$origen" = "-" ]; then
    txt="$(cat)" || { printf 'recibo: no se pudo leer el recibo de stdin\n' >&2; return 3; }
  else
    [ -f "$origen" ] || { printf 'recibo: no se pudo leer el recibo (%s no existe o no es legible)\n' "$origen" >&2; return 3; }
    txt="$(cat "$origen")" || { printf 'recibo: no se pudo leer el recibo (%s)\n' "$origen" >&2; return 3; }
  fi
  STUB_TXT="$txt" STUB_REPO="$repo" STUB_PR="$pr" STUB_SHA="$sha" python3 - <<'PY'
import json,os,sys
def no(m): sys.stderr.write("recibo: %s\n"%m); sys.exit(1)
try: j=json.loads(os.environ["STUB_TXT"])
except Exception as e: no("JSON invalido: %s"%e)
if not isinstance(j,dict): no("el recibo no es un objeto")
if j.get("schema")!="saikit-entrega.v1": no("schema distinto (se exige saikit-entrega.v1)")
if j.get("repo")!=os.environ["STUB_REPO"]: no("repo distinto")
if str(j.get("pr"))!=os.environ["STUB_PR"]: no("pr distinto")
if j.get("sha")!=os.environ["STUB_SHA"]: no("sha distinto")
clase=j.get("clase") or ""
if clase in ("codigo","configuracion","bug","runbook","documentacion"): roles=True
elif clase in ("editorial","ledger","progreso"): roles=False
else: no("clase desconocida (%s)"%clase)
imp=(j.get("implementer") or {}); ver=(j.get("verifier") or {}); rev=(j.get("reviewer") or {})
if not imp.get("id") or not imp.get("evidencia"): no("falta implementer.id o evidencia")
if roles:
    if not ver.get("id"): no("falta verifier.id")
    if ver.get("resultado")!="PASS": no("verifier.resultado distinto de PASS")
    if not ver.get("evidencia"): no("falta verifier.evidencia")
    if not rev.get("id"): no("falta reviewer.id (sin revision independiente no hay entrega)")
    if rev.get("resultado")!="APPROVE": no("reviewer.resultado distinto de APPROVE")
    if not rev.get("evidencia"): no("falta reviewer.evidencia")
    if imp.get("id")==ver.get("id") or imp.get("id")==rev.get("id") or ver.get("id")==rev.get("id"):
        no("identidad reutilizada en roles independientes")
ci=(j.get("ci") or {})
if not ci.get("workflow") or not ci.get("evidencia"): no("falta ci.workflow o evidencia")
bl=j.get("bloqueantes")
if bl is None: bl=[]
if bl!=[] and bl!={}: no("bloqueante abierto (%s en la lista)"%(len(bl) if isinstance(bl,list) else 1))
PY
}
