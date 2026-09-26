#!/bin/bash
# corrida/compuerta.sh (Fase 14, Task 6). compuerta <id> <carril> <accion>
# --sha SHA --evidence FILE: relee el PR autoritativo y valida contra el
# contrato del kit instalado, decide puro en corrida-worker.py, registra el
# veredicto y proyecta evidencia de solo lectura. La proyeccion jamas
# sustituye al recibo del kit. Sin kit no hay merge (fail-closed).
# Uso: corrida.sh compuerta <id> <carril> <cross-review|push-pr|ci|coderabbit|merge|deploy|canary|rollback> --sha SHA --evidence FILE
corrida_compuerta() {
  [ "$#" -ge 3 ] || { echo "uso: corrida.sh compuerta <id> <carril> <accion> --sha SHA --evidence FILE" >&2; return 2; }
  local id="$1" carril="$2" accion="$3"; shift 3
  local sha="" evidence=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) [ $# -ge 2 ] || { echo "compuerta: --sha sin valor" >&2; return 2; }
        sha="$2"; shift 2;;
      --evidence) [ $# -ge 2 ] || { echo "compuerta: --evidence sin valor" >&2; return 2; }
        evidence="$2"; shift 2;;
      *) echo "compuerta: flag desconocido $1" >&2; return 2;;
    esac
  done
  case "$accion" in
    cross-review|push-pr|ci|coderabbit|merge|deploy|canary|rollback) ;;
    *) echo "compuerta: accion desconocida: $accion" >&2; return 2;;
  esac
  corrida_id_valido "$id" || { echo "compuerta: id invalido: $id" >&2; return 2; }
  corrida_id_valido "$carril" || { echo "compuerta: carril invalido: $carril" >&2; return 2; }
  case "$sha" in ''|*[!0-9a-fA-F]*) echo "compuerta: sha invalido" >&2; return 2;; esac
  [ -f "$evidence" ] || { echo "compuerta: sin evidencia: $evidence" >&2; return 2; }
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  [ -n "$(lane_campo "$reg" "$carril" id)" ] || { echo "compuerta: sin carril: $carril" >&2; return 1; }
  local repo prn
  repo="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('repo',''))" "$evidence" 2>/dev/null)"
  prn="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('pr',''))" "$evidence" 2>/dev/null)"
  [ -n "$repo" ] && [ -n "$prn" ] || { echo "compuerta: la evidencia no trae repo/pr" >&2; return 2; }

  # El PR autoritativo se relee en cada invocacion; la evidencia aportada
  # jamas sustituye esa lectura.
  local prf rcf rerr
  prf="$(mktemp)" || return 1
  if ! compuerta_leer_pr "$repo" "$prn" "$prf"; then
    rm -f "$prf"
    compuerta_veredicto "$id" "$reg" "$carril" "$accion" "$sha" deny pr-ilegible \
      "no se pudo releer el PR autoritativo" "{}"
    return 1
  fi
  rcf="$(mktemp)" || { rm -f "$prf"; return 1; }
  rerr="$(mktemp)" || { rm -f "$prf" "$rcf"; return 1; }
  local rstatus=0
  if [ "$accion" = "merge" ]; then
    compuerta_kit_merge "$repo" "$prn" "$sha" "$rcf" "$rerr"
    local krc=$?
    if [ "$krc" -eq 3 ]; then
      rm -f "$prf" "$rcf" "$rerr"
      compuerta_veredicto "$id" "$reg" "$carril" "$accion" "$sha" deny recibo-ilegible \
        "no se pudo leer el recibo del PR" "{}"
      return 1
    fi
    if [ "$krc" -eq 2 ]; then
      rm -f "$prf" "$rcf" "$rerr"
      compuerta_veredicto "$id" "$reg" "$carril" "$accion" "$sha" deny kit-no-disponible \
        "sin contrato del kit instalado" "{}"
      return 1
    fi
    if [ "$krc" -ne 0 ]; then
      rstatus=1
    fi
  fi
  local out
  if ! out="$(python3 "$AQUI/corrida-worker.py" gate --record "$reg" --lane "$carril" \
      --action "$accion" --sha "$sha" --evidence "$evidence" --receipt "$rcf" \
      --receipt-status "$rstatus" --receipt-error "$(cat "$rerr" 2>/dev/null)" \
      --pr "$prf" 2>/dev/null)"; then
    rm -f "$prf" "$rcf" "$rerr"
    echo "compuerta: entrada invalida para la compuerta" >&2
    return 2
  fi
  rm -f "$prf" "$rcf" "$rerr"
  local verdict code reason projection updates
  verdict="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['verdict'])")"
  code="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['code'])")"
  reason="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['reason'])")"
  projection="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['projection']))")"
  updates="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['updates']))")"
  compuerta_veredicto "$id" "$reg" "$carril" "$accion" "$sha" "$verdict" "$code" "$reason" \
    "$projection" "$updates" "$rstatus"
  [ "$verdict" = "allow" ]
}

# Lee el PR autoritativo a $3. 0 = leido.
compuerta_leer_pr() { # $1 repo $2 pr $3 salida
  local raw
  raw="$(gh pr view "$2" --repo "$1" --json number,headRefOid,mergedAt,mergeCommit 2>/dev/null)" \
    || return 1
  GH_RAW="$raw" GH_OUT="$3" python3 -c "
import json,os
try: d=json.loads(os.environ['GH_RAW'])
except Exception: raise SystemExit(1)
if not isinstance(d,dict) or not d.get('number'): raise SystemExit(1)
mc=d.get('mergeCommit') or {}
open(os.environ['GH_OUT'],'w').write(json.dumps({
'number':d.get('number'),'head':d.get('headRefOid'),
'merged':bool(d.get('mergedAt')),
'merge_commit':mc.get('oid') if isinstance(mc,dict) else None},sort_keys=True))
" 2>/dev/null || return 1
}

# Valida el recibo con el contrato del kit instalado. 0 = valido ($4 trae el
# JSON); 1 = sin recibo o invalido ($5 trae el motivo); 2 = sin kit; 3 = API.
compuerta_kit_merge() { # $1 repo $2 pr $3 sha $4 recibo $5 err
  local kitdir="${SAIKIT_KIT_DIR:-}"
  if [ -z "$kitdir" ]; then
    kitdir="$(CDPATH= cd -P -- "$CORR_REPO_RAIZ/.." 2>/dev/null && pwd)/summonaikit-claude"
  fi
  local lib="$kitdir/tools/lib/entrega_contract.sh"
  [ -f "$lib" ] || return 2
  # shellcheck disable=SC1091
  . "$lib" || return 2
  entrega_recibo_del_pr "$1" "$2" "$3" >"$4" 2>"$5" || {
    local rc=$?
    [ "$rc" -eq 3 ] && return 3
    return 1
  }
  entrega_validar "$4" "$1" "$2" "$3" >"$5" 2>&1 || {
    local rc=$?
    [ "$rc" -eq 3 ] && return 3
    return 1
  }
  return 0
}

# Imprime ALLOW/DENY, registra gate.* + evidence.* y detiene el carril ante
# un bloqueante repetido. Siempre imprime; el llamador traduce a exit.
compuerta_veredicto() { # $1 id $2 reg $3 lane $4 accion $5 sha $6 verdict $7 code [$8 reason $9 proj $10 upd $11 rstatus]
  local id="$1" reg="$2" lane="$3" accion="$4" sha="$5" verdict="$6" code="$7"
  local reason="${8:-}" proj="${9:-{\}}" upd="${10:-{\}}" rstatus="${11:-0}"
  if [ "$verdict" = "allow" ]; then
    printf 'ALLOW %s %s\n' "$accion" "$code"
  else
    printf 'DENY %s %s %s\n' "$accion" "$code" "$reason"
  fi
  printf '%s\n' "$proj"
  local evf kind
  evf="$(mktemp)" || return 0
  kind="gate.allow"
  [ "$verdict" = "allow" ] || kind="gate.deny"
  CORR_LANE="$lane" CORR_KIND="$kind" CORR_ACC="$accion" CORR_SHA="$sha" \
  CORR_CODE="$code" CORR_REASON="$reason" CORR_PROJ="$proj" CORR_RS="$rstatus" \
  CORR_EVF="$evf" python3 -c "
import json,os
pay={'action':os.environ['CORR_ACC'],'sha':os.environ['CORR_SHA'],'code':os.environ['CORR_CODE'],
'reason':os.environ['CORR_REASON'],'projection':json.loads(os.environ['CORR_PROJ'] or '{}'),
'receipt_status':int(os.environ['CORR_RS'] or 0)}
ev=[{'lane':os.environ['CORR_LANE'],'kind':os.environ['CORR_KIND'],'payload':pay}]
open(os.environ['CORR_EVF'],'w').write(json.dumps(ev))
" 2>/dev/null || { rm -f "$evf"; return 0; }
  lock_tomar "$reg" 2>/dev/null || { rm -f "$evf"; return 0; }
  python3 "$AQUI/corrida-worker.py" state reduce --record "$reg" --events "$evf" >/dev/null 2>&1 || true
  rm -f "$evf"
  if [ "$verdict" = "allow" ] && [ "$upd" != "{}" ] && [ -n "$upd" ]; then
    local evf2
    evf2="$(mktemp)" || { lock_soltar "$reg"; return 0; }
    CORR_LANE="$lane" CORR_UPD="$upd" CORR_EVF="$evf2" python3 -c "
import json,os
upd=json.loads(os.environ['CORR_UPD'] or '{}')
ev=[{'lane':os.environ['CORR_LANE'],'kind':'evidence.'+k,'payload':v if isinstance(v,dict) else {'value':v}} for k,v in upd.items()]
open(os.environ['CORR_EVF'],'w').write(json.dumps(ev))
" 2>/dev/null \
    && python3 "$AQUI/corrida-worker.py" state reduce --record "$reg" --events "$evf2" >/dev/null 2>&1 || true
    rm -f "$evf2"
  fi
  if [ "$code" = "bloqueante-repetido" ]; then
    local evf3
    evf3="$(mktemp)" || { lock_soltar "$reg"; return 0; }
    CORR_LANE="$lane" CORR_EVF="$evf3" python3 -c "
import json,os
open(os.environ['CORR_EVF'],'w').write(json.dumps([{'lane':os.environ['CORR_LANE'],
'kind':'observed.lane.stopped','payload':{'reason':'bloqueante-repetido'}}]))" 2>/dev/null \
    && python3 "$AQUI/corrida-worker.py" state reduce --record "$reg" --events "$evf3" >/dev/null 2>&1 || true
    rm -f "$evf3"
  fi
  lock_soltar "$reg"
  return 0
}
