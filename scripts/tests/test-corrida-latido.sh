#!/bin/bash
# 9.5 latido: el seguimiento garantizado. Con openclaw de mentira (anota, no
# manda), tmux de mentira, gh de mentira y reloj inyectado: cambio => 1 mensaje;
# 59 min sin cambio => 0, 60 => 1; dialogo de 10 min => NECESITO aunque no haya
# pasado el tope; dialogo sin cobertura de politica => NECESITO inmediato; dos
# ticks seguidos no duplican; sin corridas => cero llamadas. El mensaje sale
# aunque falle el evento al vigia, y al reves. Herme(s) lee la linea en
# eventos.jsonl, claw recibe system event. Uso: bash scripts/tests/test-corrida-latido.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
CORR=scripts/mac/corrida.sh
[ -x "$CORR" ] || fail "falta $CORR"
FX=scripts/tests/fixtures/estado
PLIST=scripts/mac/ai.goncloud.corrida-latido.plist

T=$(mktemp -d) || exit 1
mkdir -p "$T/bin" "$T/corridas" "$T/watch" "$T/paneles"
export CORRIDA_STATE="$T/corridas" WATCH_STATE_DIR="$T/watch" PANEL_DIR="$T/paneles"
# Reloj base: 2026-09-19T13:02:00Z; los registros de fixture nacen a las 12:00Z.
T0=1789822920

cat >"$T/bin/tmux-falso" <<'STUB'
#!/bin/sh
t=""; prev=""
for a in "$@"; do [ "$prev" = "-t" ] && t="$a"; prev="$a"; done
s=$(printf '%s' "$t" | sed 's/^=//; s/:$//')
case "$1" in
  has-session)  [ -n "$s" ] && [ -f "$PANEL_DIR/$s.txt" ] && exit 0; exit 1;;
  capture-pane) if [ -n "$s" ] && [ -f "$PANEL_DIR/$s.txt" ]; then cat "$PANEL_DIR/$s.txt"; exit 0; fi; exit 1;;
esac
exit 1
STUB
cat >"$T/bin/gh-falso" <<'STUB'
#!/bin/sh
printf '%s\n' "GH $*" >> "${GH_LOG:-/dev/null}"
case "$1" in
  run)
    if [ "${GH_CI:-verde}" = "rojo" ]; then
      printf '[{"headSha": "%s", "conclusion": "failure", "status": "completed", "actor": {"login": "%s"}}]\n' \
        "${GH_SHA:-cafe1234567}" "${GH_AUTOR:-gon0801}"
    else
      printf '[{"headSha": "%s", "conclusion": "success", "status": "completed", "actor": {"login": "%s"}}]\n' \
        "${GH_SHA:-abcdef1234567}" "${GH_AUTOR:-gon0801}"
    fi;;
  api)
    printf '{"files": [{"filename": "docs/spec/corrida.v1.md"}, {"filename": "scripts/mac/corrida/lib.sh"}]}\n';;
  *) exit "${GH_RC:-0}";;
esac
exit 0
STUB
cat >"$T/bin/openclaw" <<'STUB'
#!/bin/sh
printf '%s\n' "OPENCLAW $*" >> "$LLAMADAS"
case "$*" in
  *"message send"*) [ "${ENVIO_MODO:-ok}" = "mal" ] && exit 1; exit 0;;
  *"system event"*) [ "${EVENTO_FALLA:-0}" = "1" ] && exit 1; exit 0;;
esac
exit 0
STUB
chmod +x "$T/bin/tmux-falso" "$T/bin/gh-falso" "$T/bin/openclaw"
export TMUX_BIN="$T/bin/tmux-falso" GH_BIN="$T/bin/gh-falso" OPENCLAW_BIN="$T/bin/openclaw"
export GH_LOG="$T/gh.log"
LLAMADAS="$T/llamadas.log"; export LLAMADAS

montar_corrida() { # $1 id, $2 escenario base; registra sesiones y paneles del fixture
  mkdir -p "$CORRIDA_STATE/$1"
  sed "s/\"m-avanza\"/\"$1\"/" "$FX/$2/registro.json" > "$CORRIDA_STATE/$1/registro.json"
  cp "$FX/$2/progress.json" "$CORRIDA_STATE/$1/"
  cp "$FX/$2"/paneles/*.txt "$PANEL_DIR/" 2>/dev/null
  : > "$CORRIDA_STATE/$1/mensajes.jsonl"
}
watch_a() { # $1 sesion, $2 since, $3 approval, $4 approval_since
  printf 'hash=1-1\nsince=%s\nnotified=0\npath=/p\napproval=%s\napproval_at=%s\napproval_since=%s\nnotified_at=0\n' \
    "$2" "${3:-}" "${4:-0}" "${4:-0}" > "$WATCH_STATE_DIR/$1.state"
}
trabajando_en() { # $1 epoch: las tres sesiones con pantalla reciente
  local s
  for s in m-lead m-a m-b; do watch_a "$s" "$(( $1 - 120 ))"; done
}
tick() { CORR_AHORA="$1" bash "$CORR" latido; }
msgs() { local n; n="$(grep -c "message send" "$LLAMADAS" 2>/dev/null)"; printf '%s' "${n:-0}"; }
evts() { local n; n="$(grep -c "system event" "$LLAMADAS" 2>/dev/null)"; printf '%s' "${n:-0}"; }
solo_dejar() { # $@ ids que siguen abiertas: el resto se cierra (no comparten sesion)
  local d id
  for d in "$CORRIDA_STATE"/*/; do
    [ -f "${d%/}/registro.json" ] || continue
    id="$(basename "$d")"
    case " $* " in *" $id "*) continue;; esac
    sed -i.bak 's/"estado": "abierta"/"estado": "cerrada"/' "${d%/}/registro.json" \
      && rm -f "${d%/}/registro.json.bak"
  done
}
evjson() { # $1 corrida, $2 tipo -> cantidad de lineas de ese tipo
  [ -f "$CORRIDA_STATE/$1/eventos.jsonl" ] || { echo 0; return; }
  EVTJ="$CORRIDA_STATE/$1/eventos.jsonl" EVTT="$2" python3 -c "
import json,os
n=0
try:
  for l in open(os.environ['EVTJ']):
    d=json.loads(l)
    n+= 1 if d.get('tipo')==os.environ['EVTT'] else 0
except Exception: pass
print(n)" 2>/dev/null
}

# (0) el LaunchAgent existe y arranca el latido cada 5 min.
[ -f "$PLIST" ] || fail "falta el LaunchAgent del latido"
grep -q "ai.goncloud.corrida-latido" "$PLIST" || fail "el label del LaunchAgent no es el del plan"
grep -A1 "<key>StartInterval</key>" "$PLIST" | grep -q "<integer>300</integer>" || fail "el LaunchAgent no late cada 5 min"
grep -q "corrida.sh" "$PLIST" && grep -q "latido" "$PLIST" || fail "el LaunchAgent no llama al latido"

# (1) sin corridas abiertas no hace nada: ni mensajes ni eventos (y rc 0).
mkdir -p "$CORRIDA_STATE/basura" "$CORRIDA_STATE/sin-registro"
printf 'no soy json\n' >"$CORRIDA_STATE/basura/registro.json"
montar_corrida lat-cerrada cerrada
sed -i.bak 's/"m-cerrada"/"lat-cerrada"/' "$CORRIDA_STATE/lat-cerrada/registro.json" && rm -f "$CORRIDA_STATE/lat-cerrada/registro.json.bak"
: > "$LLAMADAS"
tick "$T0" || fail "el latido fallo sin corridas abiertas"
[ "$(msgs)" = "0" ] || fail "sin corridas abiertas salieron $(msgs) llamadas"
[ "$(evts)" = "0" ] || fail "sin corridas abiertas desperto al vigia"
[ ! -e "$CORRIDA_STATE/basura/latido.json" ] || fail "el latido le hablo a un dir sin registro valido"

# (2) primer tick: un AVANZA; dos ticks seguidos no duplican.
montar_corrida lat-1 avanza
trabajando_en "$T0"
tick "$T0" || fail "el primer tick del latido fallo"
[ "$(msgs)" = "1" ] || fail "el primer tick mando $(msgs) mensajes (debia 1)"
grep "message send" "$LLAMADAS" | tail -1 | grep -q "\[AVANZA\]" || fail "el primer mensaje no es AVANZA"
grep "message send" "$LLAMADAS" | tail -1 | grep -q -- "--silent" || fail "lo rutinario no sale silencioso"
grep -q '"etiqueta": "AVANZA", "ok": true' "$CORRIDA_STATE/lat-1/mensajes.jsonl" || fail "el mensaje no quedo anotado"
[ -f "$CORRIDA_STATE/lat-1/latido.json" ] || fail "el latido no dejo memoria"
[ "$(evjson lat-1 mensaje)" = "1" ] || fail "el mensaje no quedo en eventos.jsonl"
trabajando_en "$((T0 + 300))"
tick "$((T0 + 300))" || fail "el segundo tick fallo"
[ "$(msgs)" = "1" ] || fail "dos ticks seguidos duplicaron (msgs=$(msgs)"
[ "$(evjson lat-1 mensaje)" = "1" ] || fail "dos ticks seguidos duplicaron eventos"

# (3) 59 min sin cambio => 0; 60 => 1 (mutacion sin latido por hora).
trabajando_en "$((T0 + 3540))"
tick "$((T0 + 3540))"
[ "$(msgs)" = "1" ] || fail "a los 59 min sin cambio salieron $(msgs) mensajes (debia 0)"
trabajando_en "$((T0 + 3600))"
tick "$((T0 + 3600))"
[ "$(msgs)" = "2" ] || fail "a los 60 min sin cambio salieron $(msgs) mensajes (debia 1)"
grep "message send" "$LLAMADAS" | tail -1 | grep -q "\[AVANZA\]" || fail "el mensaje de la hora no es AVANZA"

# (4) tope: un cambio a menos de 15 min del ultimo mensaje no sale solo (mutacion sin tope).
python3 - "$CORRIDA_STATE/lat-1/progress.json" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
d['carriles'][1]['estado']='mergeado'
json.dump(d,open(p,'w'),indent=1)
PY
tick "$((T0 + 3900))"
[ "$(msgs)" = "2" ] || fail "el cambio dentro del tope salio igual (msgs=$(msgs))"

# (5) carril callado 31 min (20 min despues del ultimo mensaje): DETENIDA + vigia despierto.
watch_a m-a "$((T0 + 4800 - 1900))"
watch_a m-lead "$((T0 + 4800 - 120))"
watch_a m-b "$((T0 + 4800 - 120))"
tick "$((T0 + 4800))"
[ "$(msgs)" = "3" ] || fail "el carril callado no genero su mensaje (msgs=$(msgs))"
grep "message send" "$LLAMADAS" | tail -1 | grep -q "\[DETENIDA\]" || fail "el carril callado no salio como DETENIDA"
[ "$(evts)" = "1" ] || fail "el vigia no se desperto con el carril callado (evts=$(evts))"
grep "system event" "$LLAMADAS" | tail -1 | grep -q "relanzar" || fail "el evento al vigia no trae la accion"
grep "system event" "$LLAMADAS" | tail -1 | grep -q "DETENIDA" || fail "el evento al vigia no trae el parte"
[ "$(evjson lat-1 evento-vigia)" = "1" ] || fail "el evento al vigia no quedo en eventos.jsonl"

# (6) dialogo de 10 min => NECESITO aunque no haya pasado el tope; y no duplica.
LLAMADAS="$T/l2.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-dlg
montar_corrida lat-dlg dialogo
trabajando_en "$T0"
tick "$T0"
[ "$(msgs)" = "1" ] || fail "lat-dlg: el primer tick mando $(msgs) (debia 1)"
watch_a m-a "$((T0 + 300 - 605))" "cafe01-2" "$((T0 + 300 - 605))"
tick "$((T0 + 300))"
[ "$(msgs)" = "2" ] || fail "el dialogo de 10 min no escalo (msgs=$(msgs))"
grep "message send" "$LLAMADAS" | tail -1 | grep -q "NECESITO TU RESPUESTA" || fail "el dialogo de 10 min no salio como NECESITO"
grep "message send" "$LLAMADAS" | tail -1 | grep -q -- "--silent" && fail "NECESITO salio silenciosa"
tick "$((T0 + 600))"
[ "$(msgs)" = "2" ] || fail "el dialogo parado duplico mensajes (msgs=$(msgs))"
[ "$(evts)" = "1" ] || fail "el dialogo no desperto al vigia una sola vez (evts=$(evts))"

# (7) dialogo joven que la politica no cubre => NECESITO inmediato.
LLAMADAS="$T/l3.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-desc
montar_corrida lat-desc avanza
cp "$FX/dialogo/paneles/m-a.txt" "$PANEL_DIR/m-a.txt"
trabajando_en "$T0"
tick "$T0"
watch_a m-a "$((T0 + 120 - 120))" "nuevo01-9" "$T0"
tick "$((T0 + 120))"
[ "$(msgs)" = "2" ] || fail "el dialogo sin cobertura no escalo (msgs=$(msgs))"
grep "message send" "$LLAMADAS" | tail -1 | grep -q "NECESITO TU RESPUESTA" || fail "el dialogo sin cobertura no es NECESITO"

# (8) vigia hermes: la linea va a eventos.jsonl, sin system event.
LLAMADAS="$T/l4.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-her
montar_corrida lat-her leadmuerto
rm -f "$PANEL_DIR/m-lead.txt"
sed -i.bak 's/"vigia": "claw"/"vigia": "hermes"/' "$CORRIDA_STATE/lat-her/registro.json" && rm -f "$CORRIDA_STATE/lat-her/registro.json.bak"
watch_a m-a "$((T0 - 120))"
watch_a m-b "$((T0 - 120))"
tick "$T0"
[ "$(msgs)" = "1" ] || fail "hermes: el mensaje del lead muerto no salio (msgs=$(msgs))"
[ "$(evts)" = "0" ] || fail "hermes: se mando un system event (evts=$(evts))"
[ "$(evjson lat-her evento-vigia)" = "1" ] || fail "hermes: no quedo linea en eventos.jsonl"
EVTJ="$CORRIDA_STATE/lat-her/eventos.jsonl" python3 -c "
import json,os
ls=[json.loads(l) for l in open(os.environ['EVTJ'])]
e=[x for x in ls if x.get('tipo')=='evento-vigia']
assert e and e[0].get('vigia')=='hermes' and 'relanzar' in e[0].get('accion',''), e
" || fail "la linea de hermes no trae vigia y accion"

# (9) independencia: el mensaje sale aunque falle el evento, y al reves.
LLAMADAS="$T/l5.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-ind
montar_corrida lat-ind leadmuerto
rm -f "$PANEL_DIR/m-lead.txt"
watch_a m-a "$((T0 - 120))"
watch_a m-b "$((T0 - 120))"
EVENTO_FALLA=1 tick "$T0" || fail "el latido murio con el evento al vigia fallando"
[ "$(msgs)" = "1" ] || fail "con el evento cayendo el mensaje no salio (msgs=$(msgs))"
watch_a m-a "$((T0 + 180))"
watch_a m-b "$((T0 + 180))"
EVENTO_FALLA=1 tick "$((T0 + 300))"
[ "$(msgs)" = "1" ] || fail "con el evento cayendo se duplico el mensaje (msgs=$(msgs))"
LLAMADAS="$T/l6.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-ind2
montar_corrida lat-ind2 leadmuerto
rm -f "$PANEL_DIR/m-lead.txt"
watch_a m-a "$((T0 - 120))"
watch_a m-b "$((T0 - 120))"
ENVIO_MODO=mal tick "$T0" || fail "el latido murio con el envio cayendo"
[ "$(evts)" = "1" ] || fail "con el mensaje cayendo el vigia no se desperto (evts=$(evts))"
grep -q '"ok": false' "$CORRIDA_STATE/lat-ind2/mensajes.jsonl" || fail "el envio caido no quedo anotado honesto"

echo "TODO VERDE: test-corrida-latido"
