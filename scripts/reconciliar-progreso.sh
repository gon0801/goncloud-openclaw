#!/bin/bash
# reconciliar-progreso.sh: alinea el progreso local con el estado real del PR en GitHub.
#
# Por que existe. Medido 2026-09-20 (Fase 9): los PR 97 y 98 ya estaban MERGED en
# GitHub y el progreso local los tenia detenidos por "esperando sello". El lead podia
# quedar parado por una causa obsoleta: el progreso cuenta carriles, nadie consultaba
# el estado del PR. La regla que implementa: para el estado de un PR manda GitHub
# (spec entrega-sin-sello, "Operacion y migracion"); MERGED prevalece.
#
# Que hace y que NO hace. Para cada carril cuyo detenido_por nombra el sello y que
# tiene PR, consulta `gh pr view <n> --repo <repo> --json state`. Si dice MERGED, el
# carril pasa a mergeado y se limpia SOLO ese motivo (detenido_por), con un evento que
# lo deja rastro. Nada mas: los carriles sin ese motivo, sin PR o con PR abierto no se
# tocan; cierre.at jamas se escribe (que los PR esten mergeados no declara la fase
# cerrada); y no manda mensajes ni toca el gateway: si la firma del parte cambia, el
# aviso lo manda el latido que ya existe (9.5), una sola vez. Corrida de nuevo sobre
# el mismo archivo no cambia nada y lo declara ("sin cambios").
#
# Uso:
#   bash scripts/reconciliar-progreso.sh <progress.json> [otro.json ...]
#   (por ejemplo .saikit/progress/9.json y el espejo de $CORRIDA_STATE)
#
# Env (opcionales, para las pruebas): GH_BIN, CORR_AHORA (epoch determinista).
#
# Salida: 0 si quedo todo consistente (reconciliado o sin cambios); 3 si quedo un
# dato unknown (GitHub no contesto por algun carril candidato: ese carril queda
# exactamente como estaba); 2 de uso o documento fuera de contrato.
set -u

LF='
'

corr_ahora() {
  if [ -n "${CORR_AHORA:-}" ] && printf '%s' "$CORR_AHORA" | grep -qE '^[0-9]+$'; then
    printf '%s' "$CORR_AHORA"
  else
    date +%s
  fi
}

epoch_a_iso() { # $1 epoch -> ISO UTC; vacio si no parsea
  EPE="$1" python3 -c "
import os,time
try: print(time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(int(os.environ['EPE']))))
except Exception: print('')" 2>/dev/null
}

uso() { echo "uso: bash scripts/reconciliar-progreso.sh <progress.json> [otro.json ...]" >&2; exit 2; }

[ $# -ge 1 ] || uso
GH="${GH_BIN:-$(command -v gh 2>/dev/null || true)}"
[ -n "$GH" ] || { echo "reconciliar: sin gh en el PATH; el estado del PR queda unknown" >&2; }

# La lista de archivos, sin duplicados y en orden: el mismo archivo dos veces
# reconciliaria dos veces sus carriles (y duplicaria los eventos).
archivos=""
for f in "$@"; do
  [ -f "$f" ] || { echo "reconciliar: no encuentro el documento: $f" >&2; exit 2; }
  case "$LF$archivos" in *"$LF$f$LF"*) ;; *) archivos="$archivos$f$LF";; esac
done

estado_pr() { # $1 pr, $2 repo -> MERGED|OPEN|<otro> por stdout; 1 si GitHub no contesto
  out="$("$GH" pr view "$1" --repo "$2" --json state 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  ST_PR="$out" python3 -c "
import json, os, sys
try:
    d = json.loads(os.environ['ST_PR'])
    s = d.get('state', '')
except Exception:
    sys.exit(1)
if not isinstance(s, str) or not s:
    sys.exit(1)
print(s)" || return 1
  return 0
}

rc_total=0
hoy="$(epoch_a_iso "$(corr_ahora)")"
for f in $archivos; do
  # Candidatos y documento validados en una pasada: schema runbook-progress.v1 y un
  # carril por id. Un documento fuera de contrato no se adivina: sale 2 sin tocarlo.
  candidatos=$(F="$f" python3 -c "
import json, os, sys
# El documento se valida COMPLETO antes de emitir el primer candidato: si la
# salida mezclara candidatos y ROTO, el case del shell solo veria el principio
# y una re-corrida aplicaria el MERGED a un documento fuera de contrato (medido
# 2026-09-22: con ids duplicados, el MERGED tocaba tambien al carril bloqueado
# por CI y borraba su motivo real). Solo un documento valido imprime candidatos.
def roto(motivo):
    print('ROTO:' + motivo)
    raise SystemExit
try:
    d = json.load(open(os.environ['F']))
except Exception:
    roto('no es json')
if not isinstance(d, dict):
    roto('raiz no es un objeto')
if d.get('schema') != 'runbook-progress.v1':
    roto('schema distinto')
if not isinstance(d.get('carriles'), list):
    roto('sin carriles')
vistos = set()
salida = []
for c in d['carriles']:
    if not isinstance(c, dict) or not isinstance(c.get('id'), str) or not c.get('id'):
        roto('carril sin id')
    if c['id'] in vistos:
        roto('id duplicado: ' + c['id'])
    vistos.add(c['id'])
    pr = c.get('pr')
    motivo = c.get('detenido_por')
    estado = c.get('estado')
    if not isinstance(pr, int) or isinstance(pr, bool) or pr <= 0:
        continue
    if not isinstance(motivo, str) or 'sello' not in motivo.lower():
        continue
    if estado in ('mergeado', 'revertido', 'omitido'):
        continue
    repo = c.get('repo')
    if not isinstance(repo, str):
        repo = ''
    salida.append('%s|%s|%s|%s' % (c['id'], pr, repo, estado))
for linea in salida:
    print(linea)
") || { printf 'reconciliar: no pude validar %s\n' "$f" >&2; exit 2; }
  case "$candidatos" in
    ROTO*) printf 'reconciliar: %s esta fuera de contrato (%s)' "$f" "${candidatos#ROTO:}" >&2; echo; exit 2;;
  esac

  cambios=""
  unknowns=0
  while IFS='|' read -r cid pr repo est; do
    [ -n "$cid" ] || continue
    # gh con --repo vacio ignora el flag y usa el repo del cwd: un PR ajeno
    # con el mismo numero quedaria mergeado. Sin owner/nombre no se consulta.
    # El valor rechazado va en el mensaje: es lo que deja a la prueba distinguir
    # null convertido a cadena vacia (repo "") del None crudo que quedaria si
    # alguien quitara solo la conversion del isinstance.
    if ! printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,38}/[A-Za-z0-9._-]{1,100}$'; then
      unknowns=$((unknowns + 1))
      printf 'unknown carril %s pr %s: repo "%s" ausente o fuera de contrato; no consulto GitHub\n' "$cid" "$pr" "$repo"
      continue
    fi
    if respuesta=$(estado_pr "$pr" "$repo"); then
      if [ "$respuesta" = "MERGED" ]; then
        cambios="$cambios$cid|$pr|$est$LF"
        printf 'carril %s pr %s: MERGED en GitHub; pasa a mergeado y se limpia el motivo "esperando sello"\n' "$cid" "$pr"
      else
        printf 'carril %s pr %s: GitHub dice %s; queda %s\n' "$cid" "$pr" "$respuesta" "$est"
      fi
    else
      unknowns=$((unknowns + 1))
      printf 'unknown carril %s pr %s: GitHub no contesto; queda %s con su motivo\n' "$cid" "$pr" "$est"
    fi
  done <<EOF
$candidatos
EOF

  if [ -n "$cambios" ]; then
    if ! F="$f" CAMBIOS="$cambios" HOY="$hoy" python3 -c "
import json, os
f = os.environ['F']
d = json.load(open(f))
hechos = {}
for linea in os.environ['CAMBIOS'].splitlines():
    if not linea:
        continue
    cid, pr, est = linea.split('|')
    hechos[cid] = (pr, est)
for c in d['carriles']:
    if c['id'] in hechos:
        pr, est = hechos[c['id']]
        c['estado'] = 'mergeado'
        c['detenido_por'] = None
        d.setdefault('eventos', []).append({
            'at': os.environ['HOY'], 'carril': c['id'],
            'que': 'PR %s MERGED en GitHub: reconciliado desde %s, motivo retirado' % (pr, est),
            'situacion': None})
if isinstance(d.get('lead'), dict) and d['lead'].get('actualizado'):
    d['lead']['actualizado'] = os.environ['HOY']
t = f + '.tmp'
open(t, 'w').write(json.dumps(d, ensure_ascii=False, indent=1) + chr(10))
os.chmod(t, os.stat(f).st_mode & 0o777)
os.rename(t, f)
"; then
      printf 'reconciliar: no se pudo escribir %s; el proximo intento repite la reconciliacion\n' "$f" >&2
      rc_total=1
      continue
    fi
    printf 'reconciliado: %d carril(es) en %s\n' "$(printf '%s' "$cambios" | grep -c .)" "$f"
  else
    printf 'sin cambios: %s\n' "$f"
  fi
  [ "$unknowns" -eq 0 ] || rc_total=3
done
exit "$rc_total"
