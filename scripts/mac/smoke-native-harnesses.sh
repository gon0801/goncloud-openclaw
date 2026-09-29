#!/bin/bash
# scripts/mac/smoke-native-harnesses.sh (14.7, Task 10). Driver de humos por
# harness: repo desechable desde origin/main del remoto, arranque por el
# adaptador de produccion (corrida.sh adaptador), entrega de una edicion
# minima, transcripcion y evento de completion, evidencia JSON redactada por
# worker (version, outcome, duracion y ruta de archivo; la transcripcion jamas
# va dentro del JSON) y cierre de tmux y corrida. rc != 0 si un worker pedido
# no llega a passed: un unavailable/skipped nunca cuenta como passed.
# Uso: smoke-native-harnesses.sh --worker <claude|codex|zcode|kimi|cursor|grok|all>
#      [--repo DIR] [--ref origin/main] [--evidence-dir DIR] [--tope SEG]
# El ciclo (abrir/preparar-carril/adaptador/cerrar) es el mismo corrida.sh de
# las corridas reales; este driver no reimplementa nada del ciclo. Pasar
# --repo apuntando al repo principal cuando se corre desde un worktree ligado.
# Inyectables de operacion y prueba: CORRIDA_STATE, OPENCLAW_BIN,
# CORRIDA_WORKERS_REGISTRY, CORRIDA_CLI_MODOS, CORRIDA_RUNBOOK,
# CORRIDA_WORKER_BIN_<ID> (los mismos que resuelve el adaptador) y
# SMOKE_REDACT=0 (solo pruebas: desactiva la redaccion de tokens). TMUX_BIN es
# opcional: sin definir se resuelve igual que corrida/lib.sh (B1 de 14.7-r2;
# el runbook no lo exporta).
set -u
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX
umask 077
if [ -z "${TMUX_BIN:-}" ]; then
  TMUX_BIN="$(command -v tmux 2>/dev/null || true)"
  [ -z "$TMUX_BIN" ] && [ -x /opt/homebrew/bin/tmux ] && TMUX_BIN=/opt/homebrew/bin/tmux
fi
[ -n "${TMUX_BIN:-}" ] || { echo "sin tmux no hay humo" >&2; exit 1; }

uso() { echo "uso: smoke-native-harnesses.sh --worker <claude|codex|zcode|kimi|cursor|grok|all> [--repo DIR] [--ref origin/main] [--evidence-dir DIR] [--tope SEG]" >&2; }

AQUI="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
CORRIDA="${SMOKE_CORRIDA:-$RAIZ/scripts/mac/corrida.sh}"
REG="${CORRIDA_WORKERS_REGISTRY:-$RAIZ/scripts/mac/workers.v1.json}"
MODOS="${CORRIDA_CLI_MODOS:-$RAIZ/scripts/mac/cli-modos.tsv}"
RUNBOOK="${CORRIDA_RUNBOOK:-$RAIZ/docs/runbooks/native-harness-rollout.md}"

pedidos="" repo="" ref="origin/main" ev="" tope="${SMOKE_TOPE:-240}"
while [ $# -gt 0 ]; do
  case "$1" in
    --worker)
      [ $# -ge 2 ] || { uso; exit 2; }
      case "$2" in
        all) pedidos="$pedidos claude codex zcode kimi cursor grok";;
        claude|codex|zcode|kimi|cursor|grok) pedidos="$pedidos $2";;
        *) echo "worker fuera del conjunto: $2" >&2; exit 2;;
      esac
      shift 2;;
    --repo) [ $# -ge 2 ] || { uso; exit 2; }; repo="$2"; shift 2;;
    --ref) [ $# -ge 2 ] || { uso; exit 2; }; ref="$2"; shift 2;;
    --evidence-dir) [ $# -ge 2 ] || { uso; exit 2; }; ev="$2"; shift 2;;
    --tope) [ $# -ge 2 ] || { uso; exit 2; }; tope="$2"; shift 2;;
    *) echo "flag desconocido: $1" >&2; exit 2;;
  esac
done
[ -n "$pedidos" ] || { uso; exit 2; }
[ -f "$CORRIDA" ] || { echo "sin corrida.sh: $CORRIDA" >&2; exit 1; }
[ -r "$REG" ] || { echo "sin registro de workers: $REG" >&2; exit 1; }
[ -r "$MODOS" ] || { echo "sin tabla de modos: $MODOS" >&2; exit 1; }
[ -f "$RUNBOOK" ] || { echo "sin runbook: $RUNBOOK" >&2; exit 1; }
REPO="${repo:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "")}"
[ -n "$REPO" ] && { [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ]; } \
  || { echo "sin repo git: ${REPO:-<no resuelto>} (usa --repo)" >&2; exit 1; }
FECHA="$(date +%Y%m%d-%H%M%S)"
EV="${ev:-${CORRIDA_STATE:-$HOME/.local/state/u3-loop}/native-smoke-$FECHA}"
mkdir -p "$EV" || exit 1

# Un harness real por binario; el id del registro es el representante que el
# selector usaria (fable para claude, coding para kimi).
map_worker() {
  case "$1" in
    claude) printf 'claude_fable\n';;
    codex) printf 'codex\n';;
    zcode) printf 'zcode\n';;
    kimi) printf 'kimi_coding\n';;
    cursor) printf 'cursor\n';;
    grok) printf 'grok\n';;
  esac
}

# La evidencia sale sin tokens: toda forma de credencial conocida en pantalla
# o version se sustituye antes de escribir el archivo.
redacta() {
  if [ "${SMOKE_REDACT:-1}" = "1" ]; then
    sed -E \
      -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTADO]/g' \
      -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTADO]/g' \
      -e 's/AKIA[0-9A-Z]{16}/[REDACTADO]/g' \
      -e 's/sk-ant-[A-Za-z0-9_-]{20,}/[REDACTADO]/g' \
      -e 's/sk-[A-Za-z0-9_-]{20,}/[REDACTADO]/g' \
      -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTADO]/g' \
      -e 's/glpat-[A-Za-z0-9_-]{15,}/[REDACTADO]/g' \
      -e 's/AIza[0-9A-Za-z_-]{30,}/[REDACTADO]/g' \
      -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTADO]/g'
  else
    cat
  fi
}

# escribir_resultado <archivo> <worker> <id> <binario> <version> <outcome>
#   <duracion> <archivo-transcripcion> <arranque> <auth> <entrega>
#   <transcripcion> <completitud> <parada> <nota>
escribir_resultado() {
  W_FILE="$1" W_NAME="$2" W_ID="$3" W_BIN="$4" W_VER="$5" W_OUT="$6" W_DUR="$7" \
  W_ARCH="$8" W_START="$9" W_AUTH="${10}" W_DELIV="${11}" W_TRANS="${12}" \
  W_COMP="${13}" W_STOP="${14}" W_NOTA="${15}" python3 - <<'PY'
import json, os
b = lambda v: v == "1"
r = {
  "worker": os.environ["W_NAME"], "id": os.environ["W_ID"],
  "binario": os.environ["W_BIN"], "version": os.environ["W_VER"],
  "outcome": os.environ["W_OUT"], "duracion_seg": int(os.environ["W_DUR"]),
  "archivo": os.environ["W_ARCH"],
  "chequeos": {"arranque": b(os.environ["W_START"]), "auth": b(os.environ["W_AUTH"]),
               "entrega": b(os.environ["W_DELIV"]), "transcripcion": b(os.environ["W_TRANS"]),
               "completitud": b(os.environ["W_COMP"]), "parada": b(os.environ["W_STOP"])},
  "nota": os.environ["W_NOTA"],
}
json.dump(r, open(os.environ["W_FILE"], "w"), ensure_ascii=False, indent=1, sort_keys=True)
PY
}

marcar() { # $1 evw $2 worker $3 wid $4 bin $5 ver $6 outcome $7 nota
  escribir_resultado "$1/resultado.json" "$2" "$3" "$4" "$5" "$6" "$((SECONDS-t0))" \
    "$1/pantalla.txt" "${arranque:-0}" "${auth:-0}" "${entrega:-0}" \
    "${transcripcion:-0}" "${completitud:-0}" "${parada:-0}" "$7"
  printf 'humo %s: %s (%ss)\n' "$2" "$6" "$((SECONDS-t0))"
}

npedidos=0; pasados=0
for w in $pedidos; do
  npedidos=$((npedidos+1))
  t0=$SECONDS
  evw="$EV/$w"; mkdir -p "$evw"
  arranque=0 auth=0 entrega=0 transcripcion=0 completitud=0 parada=0
  wid="$(map_worker "$w")"
  binario="$(SREG="$REG" WID="$wid" python3 -c '
import json, os
r = json.load(open(os.environ["SREG"]))
ws = [x.get("binary", "") for x in r.get("workers", []) if x.get("id") == os.environ["WID"]]
print(ws[0] if ws else "")
' 2>/dev/null)" || binario=""
  idu="$(printf '%s' "$wid" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
  vvar="CORRIDA_WORKER_BIN_$idu"
  bin="${!vvar:-}"
  [ -n "$bin" ] || bin="$binario"
  bin_ok=""
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    bin_ok="$bin"
  elif [ -n "$bin" ]; then
    bin_ok="$(PATH="$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH" command -v "$bin" 2>/dev/null)"
  fi
  ver=""
  if [ -n "$bin_ok" ]; then
    ver="$("$bin_ok" --version 2>/dev/null | head -1 | redacta)"
  fi
  if [ -z "$bin_ok" ]; then
    marcar "$evw" "$w" "$wid" "$binario" "$ver" "unavailable" "binario ausente: $bin" | tail -1
    falla=1
    continue
  fi
  cid="smoke-$w-$$"
  ses="smoke-$w-$$"
  # La accion health comparte la aridad del dispatch (accion id carril worker
  # sesion) aunque solo lea el worker.
  H="$(bash "$CORRIDA" adaptador health "$cid" c1 "$wid" "$ses" 2>/dev/null)"
  if [ "$H" != "available" ]; then
    marcar "$evw" "$w" "$wid" "$binario" "$ver" "unavailable" "health: ${H:-sin respuesta}" | tail -1
    falla=1
    continue
  fi
  auth=1
  repo_w="$EV/repo-$w"
  if ! git clone --quiet "$REPO" "$repo_w" 2>"$evw/fallos.log"; then
    marcar "$evw" "$w" "$wid" "$binario" "$ver" "unavailable" "clone fallo" | tail -1
    falla=1
    continue
  fi
  base="$(git -C "$repo_w" rev-parse --verify -q "$ref")"
  if [ -z "$base" ] || ! git -C "$repo_w" checkout -q --detach "$base" 2>>"$evw/fallos.log"; then
    marcar "$evw" "$w" "$wid" "$binario" "$ver" "unavailable" "sin $ref en el remoto desechable" | tail -1
    falla=1
    continue
  fi
  if ! bash "$CORRIDA" abrir "$cid" --runbook "$RUNBOOK" --vigia claw --cli-modos "$MODOS" --simulacro \
    >>"$evw/fallos.log" 2>&1; then
    marcar "$evw" "$w" "$wid" "$binario" "$ver" "unavailable" "abrir fallo" | tail -1
    falla=1
    continue
  fi
  wt="$(bash "$CORRIDA" preparar-carril "$cid" c1 "$repo_w" 2>>"$evw/fallos.log")"
  if [ -z "$wt" ]; then
    bash "$CORRIDA" cerrar "$cid" >>"$evw/fallos.log" 2>&1 || true
    marcar "$evw" "$w" "$wid" "$binario" "$ver" "unavailable" "sin carril reservado" | tail -1
    falla=1
    continue
  fi
  printf 'humo %s: anade la linea final "humo %s %s" en README.md y termina.\n' "$w" "$w" "$FECHA" \
    > "$evw/brief.txt"
  if ses_out="$(bash "$CORRIDA" adaptador start "$cid" c1 "$wid" "$ses" "$wt" "$evw/brief.txt" \
    2>>"$evw/fallos.log")" && [ "$ses_out" = "$ses" ]; then
    arranque=1
  else
    bash "$CORRIDA" adaptador stop "$cid" c1 "$wid" "$ses" >>"$evw/fallos.log" 2>&1 || true
    bash "$CORRIDA" cerrar "$cid" >>"$evw/fallos.log" 2>&1 || true
    marcar "$evw" "$w" "$wid" "$binario" "$ver" "unavailable" "start fallo (barra o registro)" | tail -1
    falla=1
    continue
  fi
  d="$(bash "$CORRIDA" adaptador deliver "$cid" c1 "$wid" "$ses" "$evw/brief.txt" 2>>"$evw/fallos.log")"
  [ "$d" = "accepted" ] && entrega=1
  espera=0
  while [ "$espera" -lt "$tope" ]; do
    st="$(bash "$CORRIDA" adaptador inspect "$cid" c1 "$wid" "$ses" 2>>"$evw/fallos.log")" || st="failed"
    case "$st" in
      complete) completitud=1; break;;
      failed|quota|auth-vencida) break;;
    esac
    sleep 2
    espera=$((espera+2))
  done
  # La marca sola no es el trabajo: passed exige la linea del brief en README.md.
  if [ "$completitud" = 1 ] && ! grep -qF "humo $w $FECHA" "$wt/README.md" 2>/dev/null; then
    completitud=0; st="complete sin la linea en README.md"
  fi
  "$TMUX_BIN" capture-pane -p -t "=$ses:" 2>/dev/null | redacta > "$evw/pantalla.txt"
  [ -s "$evw/pantalla.txt" ] && transcripcion=1
  s="$(bash "$CORRIDA" adaptador stop "$cid" c1 "$wid" "$ses" 2>>"$evw/fallos.log")"
  case "$s" in stopped|already_stopped) parada=1;; esac
  bash "$CORRIDA" cerrar "$cid" >>"$evw/fallos.log" 2>&1 || true
  if [ "$arranque$auth$entrega$transcripcion$completitud$parada" = "111111" ]; then
    marcar "$evw" "$w" "$wid" "$binario" "$ver" "passed" "humo completo" | tail -1
    pasados=$((pasados+1))
  else
    marcar "$evw" "$w" "$wid" "$binario" "$ver" "failed" "estado final: ${st:-sin estado}" | tail -1
    falla=1
  fi
done

python3 - "$EV" "$npedidos" "$pasados" <<'PY'
import glob, json, sys
ev = sys.argv[1]
rs = [json.load(open(p)) for p in sorted(glob.glob(ev + "/*/resultado.json"))]
json.dump({"pedidos": int(sys.argv[2]), "pasados": int(sys.argv[3]), "resultados": rs},
          open(ev + "/resumen.json", "w"), ensure_ascii=False, indent=1, sort_keys=True)
PY
printf 'resumen: %s de %s passed; evidencia: %s\n' "$pasados" "$npedidos" "$EV"
[ "${falla:-0}" -eq 0 ] || exit 1
exit 0
