#!/bin/bash
# Arnes r2 (19.0-r2): completa la cadena de la linea base con TRANSPORTE REAL
# y atencion del dueño. Encadena: fin del trabajador -> deteccion del vigia ->
# envio REAL por system event a la sesion propia de la corrida de prueba
# (agent:main:sim9-arnes19-<token>, via openclaw-pasarela) -> atencion medida
# en openclaw audit (agent.run.started del gateway) -> inicio del siguiente rol
# (sucesor del CLI siguiente en el anillo; lo lanza el dueño si tiene brazo en
# la Mac y, si no, el lead registrado de la corrida, declarado como tal).
# Todo lo demas queda en sandbox (tmux -L, CORRIDA_STATE, message send y cron
# list doblados por la pasarela; el hook Stop de claude queda NEGADO). Negado
# si un inyectable apunta al estado real.
# uso: medir-r2.sh <token>   (token: claude|kimi|codex|zcode|grok)
set -uo pipefail

TOKEN=${1:-}
case "$TOKEN" in claude|kimi|codex|zcode|grok) ;; *) echo "uso: medir-r2.sh <token>" >&2; exit 2;; esac
case "$TOKEN" in
  zcode)  SUCESOR=codex;;
  codex)  SUCESOR=kimi;;
  kimi)   SUCESOR=grok;;
  grok)   SUCESOR=claude;;
  claude) SUCESOR=zcode;;
esac

ARNES="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ARNES/../../../.." && pwd)"
CORRIDA="$REPO/scripts/mac/corrida.sh"
WATCHER="$REPO/scripts/mac/tmux-activity-watch.sh"
TSV="$REPO/scripts/mac/cli-modos.tsv"
OPENCLAW_REAL="${OPENCLAW_REAL_BIN:-$HOME/.openclaw/bin/openclaw}"
WORK="$ARNES/.tmp/r2-$TOKEN"
SALIDA="$ARNES/salidas/$TOKEN-r2"
# Identidad unica por corrida: una clave de sesion reutilizada no identifica
# la misma ejecucion, y el dueño puede arrastrar cola de la corrida anterior.
ID="arnes19-$TOKEN-$(date +%H%M%S)"
SESION="medicion-$TOKEN"
SESION_SUC="sucesor-$TOKEN"
CLAVE="agent:main:sim9-$ID"

export TMUX_BIN="$ARNES/tmux-arnes"
export ARNES_SOCKET="u3a19r2-$$"
export OPENCLAW_BIN="$ARNES/openclaw-pasarela"
export OPENCLAW_REAL_BIN="$OPENCLAW_REAL"
export DOBLE_LOG="$WORK/doble.jsonl"
export CORRIDA_STATE="$WORK/estado"
export CORRIDA_BIN="$CORRIDA"
export STATE_DIR="$WORK/watch"
export LOG_FILE="$WORK/watch.log"
export QUIET_SECS=10 TICK_SECS=2 LATIDO_SECS=1800 CORR_TOPE_RED=5

case "$CORRIDA_STATE" in "$HOME/.local/state"*) echo "NEGADO: CORRIDA_STATE apunta al estado real" >&2; exit 2;; esac
[ "$(basename "$OPENCLAW_BIN")" = "openclaw-pasarela" ] || { echo "NEGADO: falta la pasarela" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/repo" "$WORK/watch" "$CORRIDA_STATE" "$SALIDA"
cd "$WORK/repo"
git init -q
git config user.email arnes@local
git config user.name arnes
printf 'arnes r2\n' > README.md
git add README.md && git commit -qm "arnes r2"

printf '# Corrida de medicion r2 %s\n\nUna parte y su sucesor.\n' "$TOKEN" > "$WORK/runbook.md"
printf 'Trabajo unico: crea el archivo resultado.txt en la raiz del repositorio con exactamente el texto MEDICION-19.0-%s (una linea). Usalo con tu herramienta nativa de escritura de archivos, no con comandos de terminal. No hagas nada mas: ni commit, ni preguntas, ni archivos extra. Si algo te lo impide, escribe el motivo en bloqueo.txt con tu herramienta de archivos y termina.\n' "$TOKEN" > "$WORK/encargo.txt"
printf 'Prueba de medicion 19.0-r2: crea el archivo resultado-r2.txt en la raiz del repositorio con exactamente el texto MEDICION-R2-%s (una linea), con tu herramienta nativa de archivos y sin terminal. Nada mas.\n' "$SUCESOR" > "$WORK/encargo-sucesor.txt"

WATCH_PID=""; SONDEO_PID=""; CARRERA_PID=""; CARRERA_SUC_PID=""
limpiar() {
  [ -n "$CARRERA_PID" ] && kill "$CARRERA_PID" 2>/dev/null
  [ -n "$CARRERA_SUC_PID" ] && kill "$CARRERA_SUC_PID" 2>/dev/null
  [ -n "$SONDEO_PID" ] && kill "$SONDEO_PID" 2>/dev/null
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
  wait 2>/dev/null
  "$TMUX_BIN" kill-server 2>/dev/null
}
trap 'RC=$?; limpiar; exit $RC' EXIT

: > "$DOBLE_LOG"
"$TMUX_BIN" new-session -d -s arranque -x 80 -y 24 "sleep 7200" 2>/dev/null
"$TMUX_BIN" set-environment -g OPENCLAW_BIN "$OPENCLAW_BIN"
"$TMUX_BIN" set-environment -g DOBLE_LOG "$DOBLE_LOG"

precalentar() { # $1 token: sesion previa responde confianza y espera barra
  local t=$1 fila bin flag barra i
  fila="$(LC_ALL=C awk -F'\t' -v w="$t" '$1==w {print $2 "\t" $3 "\t" $4; exit}' "$TSV")"
  bin="$(printf '%s' "$fila" | cut -f1)"; flag="$(printf '%s' "$fila" | cut -f2)"; barra="$(printf '%s' "$fila" | cut -f3)"
  "$TMUX_BIN" new-session -d -s "precalienta-$t" -x 200 -y 50 -c "$WORK/repo" \
    "/usr/bin/env PATH=\"$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH\" $bin $flag" 2>/dev/null
  i=0
  while [ "$i" -lt 90 ]; do
    "$ARNES/responder-confianza.sh" "$t" "precalienta-$t" "$WORK/repo" >>"$WORK/carrera.log" 2>&1 || true
    "$TMUX_BIN" capture-pane -p -t "=precalienta-$t:" 2>/dev/null | grep -qF -- "$barra" && break
    sleep 1; i=$((i+1))
  done
  "$TMUX_BIN" kill-session -t "=precalienta-$t" 2>/dev/null
}

[ "$TOKEN" = claude ] && precalentar claude
[ "$SUCESOR" = claude ] && precalentar claude

# Offset de relojes Mac <-> gateway: 5 sondas ssh de solo lectura (el remoto
# es Windows: epoch por PowerShell); la mediana de (gateway - Mac) en ms lleva
# la atencion del audit al reloj Mac.
offset_ms=""
sondas=""
for i in 1 2 3 4 5; do
  mac_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
  gw_ms=$(ssh -o BatchMode=yes -o ConnectTimeout=6 gwpc 'powershell -NoProfile -Command "[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()"' 2>/dev/null | tr -d '\r') || gw_ms=""
  case "$gw_ms" in ''|*[!0-9]*) gw_ms="";; esac
  [ -n "$gw_ms" ] && sondas="$sondas $((gw_ms - mac_ms))"
  sleep 0.3
done
[ -n "$sondas" ] && offset_ms=$(printf '%s\n' $sondas | sort -n | sed -n 3p)

"$WATCHER" >"$WORK/watch.out" 2>&1 &
WATCH_PID=$!
sleep 1

python3 "$ARNES/sondeo-fin.py" "$ARNES_SOCKET" "$SESION" "$WORK/repo/resultado.txt" \
  "$WORK/sondeo.jsonl" --tope 300 &
SONDEO_PID=$!

if [ "$TOKEN" = claude ] || [ "$TOKEN" = codex ] || [ "$TOKEN" = kimi ]; then
  (
    i=0
    while [ "$i" -lt 60 ]; do
      "$ARNES/responder-confianza.sh" "$TOKEN" "$SESION" "$WORK/repo" >>"$WORK/carrera.log" 2>&1 && exit 0
      sleep 0.5
      i=$((i + 1))
    done
  ) &
  CARRERA_PID=$!
fi

{
  "$CORRIDA" abrir "$ID" --runbook "$WORK/runbook.md" --vigia hermes \
    --cli-modos "$TSV" --canal-de arnes-canal --simulacro &&
  "$CORRIDA" lanzar-sesion "$ID" lead "$TOKEN" "$WORK/repo" --nombre "$SESION" \
    --encargo "$WORK/encargo.txt"
} >"$WORK/lanzar.out" 2>&1
if [ $? -ne 0 ]; then
  printf '{"veredicto":"LANZAMIENTO-FALLO","token":"%s"}\n' "$TOKEN" > "$WORK/times-r2.json"
  cp "$WORK/lanzar.out" "$SALIDA/lanzar.$(date +%H%M%S).out"
  echo "medir-r2: lanzamiento fallo" >&2
  exit 1
fi

wait $SONDEO_PID 2>/dev/null
SONDEO_PID=""
# El audit del gateway consulta por epoch: la ventana abre antes del envio del
# vigia (que ocurre durante el asentamiento) para no perder el turno que el
# primer aviso despierte.
after_ms=$(python3 -c 'import time; print(int(time.time()*1000) - 2000)')
sleep $((QUIET_SECS + 2 * TICK_SECS + 6))

# Carrera de confianza para el sucesor (la pantalla nueva puede traer dialogo).
case "$SUCESOR" in claude|codex|kimi)
  (
    fin=$(($(date +%s) + 180))
    while [ "$(date +%s)" -lt "$fin" ]; do
      "$ARNES/responder-confianza.sh" "$SUCESOR" "$SESION_SUC" "$WORK/repo" >>"$WORK/carrera.log" 2>&1 && exit 0
      sleep 0.5
    done
  ) &
  CARRERA_SUC_PID=$!
;;esac

CMD="CORRIDA_STATE=$CORRIDA_STATE OPENCLAW_BIN=$OPENCLAW_BIN TMUX_BIN=$TMUX_BIN ARNES_SOCKET=$ARNES_SOCKET bash $CORRIDA lanzar-sesion $ID lead $SUCESOR $WORK/repo --nombre $SESION_SUC --encargo $WORK/encargo-sucesor.txt"
breve=$(printf 'PRÁCTICA de medición 19.0-r2 (corrida de práctica %s; no es para David y no escribas a nadie): el vigía avisó que la sesión %s quedó quieta. Si tienes ejecución en la Mac (host de las CLI), ejecuta exactamente este comando y termina tu turno: %s Si no tienes ejecución en la Mac, termina tu turno escribiendo en tu respuesta: SIN-BRAZO-MAC.' "$ID" "$SESION" "$CMD")
DOBLE_LOG="$DOBLE_LOG" OPENCLAW_REAL_BIN="$OPENCLAW_REAL" bash "$OPENCLAW_BIN" system event \
  --mode now --timeout 10000 --session-key "$CLAVE" --text "$breve" >"$WORK/breve.out" 2>&1
rc_breve=$?

atencion_gw=""
fin_turno_gw=""
lectura=$(python3 "$ARNES/audit-turno.py" "$CLAVE" "$after_ms" started 300)
rc_at=$?
if [ "$rc_at" -eq 0 ]; then
  atencion_gw=${lectura%% *}
  runid=${lectura#* }
  lectura_fin=$(python3 "$ARNES/audit-turno.py" "$CLAVE" "$after_ms" finished 300 "$runid")
  fin_turno_gw=${lectura_fin%% *}
fi

sleep 3
if "$TMUX_BIN" has-session -t "=$SESION_SUC" 2>/dev/null; then
  lanzador="dueno"
else
  lanzador="lead"
  eval "$CMD" >"$WORK/lanzar-sucesor.out" 2>&1
fi

python3 "$ARNES/sondeo-fin.py" "$ARNES_SOCKET" "$SESION_SUC" "$WORK/repo/resultado-r2.txt" \
  "$WORK/sondeo-sucesor.jsonl" --tope 240 --actividad

# El sucesor a veces termina despues de la ventana del sondeo: el archivo es
# la prueba de trabajo, asi que se le da una cola de 90 s solo de archivo.
cola=$(($(date +%s) + 90))
while [ ! -s "$WORK/repo/resultado-r2.txt" ] && [ "$(date +%s)" -lt "$cola" ]; do
  sleep 3
done

kill "$WATCH_PID" 2>/dev/null
WATCH_PID=""
"$CORRIDA" cerrar "$ID" >"$WORK/cerrar.out" 2>&1 || true

python3 - "$WORK" "$TOKEN" "$SUCESOR" "$QUIET_SECS" "$TICK_SECS" "$offset_ms" "$atencion_gw" "$fin_turno_gw" "$lanzador" "$rc_breve" > "$WORK/times-r2.json" <<'PY'
import datetime, json, os, sys
work, token, sucesor, quiet, tick, offset, t0g, t1g, lanzador, rc_breve = sys.argv[1:11]

def filas(n):
    r = os.path.join(work, n)
    if not os.path.isfile(r):
        return []
    out = []
    for linea in open(r):
        linea = linea.strip()
        if linea:
            try:
                out.append(json.loads(linea))
            except ValueError:
                pass
    return out

def epoch_ms_de_wall(w):
    base = datetime.datetime.strptime(w[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    return int(base.timestamp() * 1000) + int(w[20:23])

sondeo = filas("sondeo.jsonl")
envios = [d for d in filas("doble.jsonl") if d.get("estado") == "REAL"]
suc = filas("sondeo-sucesor.jsonl")
resumen = {"token": token, "sucesor": sucesor,
           "config_arnes": {"QUIET_SECS": quiet, "TICK_SECS": tick},
           "offset_gateway_mac_ms": (None if offset == "" else int(offset)),
           "breve_rc": rc_breve}
fins = [r for r in sondeo if r["ev"] == "fin"]
if not fins or not envios:
    resumen["veredicto"] = "SIN-DATOS"
    print(json.dumps(resumen, indent=1))
    sys.exit(0)
t_fin = fins[0]["mono_ns"]
t_envio = min(d["mono_ns"] for d in envios)
pared_envio = min(d["wall"] for d in envios if d["mono_ns"] == t_envio)
resumen["t_fin_wall"] = fins[0]["wall"]
resumen["deteccion_a_envio_s"] = round((t_envio - t_fin) / 1e9, 2)
if t0g:
    resumen["turno_started_gw_ms"] = int(t0g)
    if offset != "":
        atencion_epoch_mac = int(t0g) - int(offset)
        resumen["envio_a_atencion_s"] = round((atencion_epoch_mac - epoch_ms_de_wall(pared_envio)) / 1000, 2)
        resumen["nota_reloj"] = "atencion del audit (reloj gateway) llevada al reloj Mac con el offset medido por ssh; resolucion de sondas ~1 s"
    else:
        resumen["envio_a_atencion_s"] = None
        resumen["nota_reloj"] = "sin sondas ssh: offset desconocido, atencion no comparable con el envio"
if t0g and t1g:
    resumen["turno_del_dueno_s"] = round((int(t1g) - int(t0g)) / 1000, 2)
resumen["lanzador_sucesor"] = lanzador
vivas = [r for r in suc if r["ev"] == "sesion-viva"]
acts = [r for r in suc if r["ev"] == "actividad"]
fins_suc = [r for r in suc if r["ev"] == "fin"]
if vivas:
    resumen["envio_a_sesion_sucesor_s"] = round((vivas[0]["mono_ns"] - t_envio) / 1e9, 2)
if acts:
    resumen["envio_a_actividad_sucesor_s"] = round((acts[0]["mono_ns"] - t_envio) / 1e9, 2)
if fins_suc:
    resumen["sucesor_termino_wall"] = fins_suc[0]["wall"]
contenido = ""
ruta = os.path.join(work, "repo", "resultado-r2.txt")
if os.path.isfile(ruta):
    contenido = open(ruta).read()[:60]
resumen["resultado-r2.txt"] = contenido
resumen["veredicto"] = "OK" if (t0g and contenido.strip().startswith("MEDICION-R2")) else "OK-CON-RESERVAS"
print(json.dumps(resumen, indent=1, ensure_ascii=False))
PY

ESTAMPA="$(date +%H%M%S)"
"$TMUX_BIN" capture-pane -p -t "=$SESION:" >"$WORK/pane-final.log" 2>/dev/null
for f in doble.jsonl sondeo.jsonl sondeo-sucesor.jsonl watch.log lanzar.out breve.out times-r2.json pane-final.log lanzar-sucesor.out; do
  [ -f "$WORK/$f" ] && cp "$WORK/$f" "$SALIDA/$f.$ESTAMPA" 2>/dev/null
done
cp "$CORRIDA_STATE/$ID/registro.json" "$SALIDA/registro.$ESTAMPA" 2>/dev/null

printf '%s %s\n' "$TOKEN" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("veredicto","?"))' "$WORK/times-r2.json")"
