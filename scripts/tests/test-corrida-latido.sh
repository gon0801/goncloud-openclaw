#!/bin/bash
# 9.5 latido + 9.8 rama por defecto en rojo. Con openclaw de mentira (anota, no
# manda), tmux de mentira, gh de mentira y reloj inyectado: cambio => 1 mensaje;
# 59 min sin cambio => 0, 60 => 1; dialogo de 10 min => NECESITO aunque no haya
# pasado el tope; dialogo sin cobertura de politica => NECESITO inmediato; dos
# ticks seguidos no duplican; sin corridas => cero llamadas. El mensaje sale
# aunque falle el evento al vigia, y al reves; hermes lee la linea en
# eventos.jsonl, claw recibe system event. 9.8: CI en fallo => un DETENIDA en
# lenguaje de usuario y registro local con sha, autor y archivos; el mismo sha
# en el tick siguiente => cero (mutacion sin memoria muere); CI verde => cero;
# gh caido => cero avisos y el latido sigue. Uso: bash scripts/tests/test-corrida-latido.sh
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
[ "${GH_CAIDO:-0}" = "1" ] && exit 1
case "$1" in
  run)
    case "$*" in *"--workflow quality.yml"*) ;; *) exit 5;; esac
    # fiel al gh real (2.98.0): --json rechaza campos desconocidos
    campos=""; prev=""
    for a in "$@"; do [ "$prev" = "--json" ] && campos="$a"; prev="$a"; done
    for c in $(printf '%s' "$campos" | tr ',' ' '); do
      case "$c" in headSha|conclusion|status) ;; *)
        printf 'Unknown JSON field: "%s"\n' "$c" >&2
        exit 1;;
      esac
    done
    case "${GH_CI:-verde}" in
      rojo)    c=failure;;
      timeout) c=timed_out;;
      arranque) c=startup_failure;;
      *)       c=success;;
    esac
    if [ "${GH_CI:-verde}" = "verde" ]; then s="${GH_SHA:-abcdef1234567}"; else s="${GH_SHA:-cafe1234567}"; fi
    printf '[{"headSha": "%s", "conclusion": "%s", "status": "completed"}]\n' "$s" "$c";;
  repo)
    printf '{"nameWithOwner": "gon0801/goncloud-workspace-main"}\n';;
  api)
    [ "${GH_API_FALLA:-0}" = "1" ] && exit 1
    printf '{"commit": {"author": {"name": "gon0801"}}, "files": [{"filename": "docs/spec/corrida.v1.md"}, {"filename": "scripts/mac/corrida/lib.sh"}]}\n';;
  *) exit 0;;
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

# (0) el LaunchAgent existe y arranca el latido cada 5 min. La relacion
# plist<->repo se verifica SIN rutas de esta Mac (NA): con un repo de mentira
# cuyo origin se copia en caliente del repo bajo prueba, y un plist generado
# que apunta a el (caso verde); el caso rojo apunta a un repo con OTRO origin y
# debe fallar. El plist real solo se verifica donde su REPO_DIR exista: en CI
# esa ruta no esta y el caso se salta con su motivo impreso. Y lib.sh fija
# TMUX_BIN incluso si el entorno lo trae vacio (NC).
[ -f "$PLIST" ] || fail "falta el LaunchAgent del latido"
grep -q "ai.goncloud.corrida-latido" "$PLIST" || fail "el label del LaunchAgent no es el del plan"
grep -A1 "<key>StartInterval</key>" "$PLIST" | grep -q "<integer>300</integer>" || fail "el LaunchAgent no late cada 5 min"
grep -q "corrida.sh" "$PLIST" && grep -q "latido" "$PLIST" || fail "el LaunchAgent no llama al latido"
grep -q "REPO_DIR" "$PLIST" || fail "el plist no inyecta REPO_DIR al latido"

repo_de_plist() { # $1 plist -> la ruta de su REPO_DIR
  awk '/REPO_DIR/{f=1} f && /<string>/{print; exit}' "$1" | sed 's/.*<string>//; s/<\/string>.*//'
}
mismo_origin() { # $1 repo a revisar, $2 repo de referencia; 0 = mismo origin
  [ -n "$1" ] && [ "$(git -C "$1" remote get-url origin 2>/dev/null)" = "$(git -C "$2" remote get-url origin 2>/dev/null)" ]
}
# El fixture de git de la prueba no hereda el GIT_DIR del hook que la corre
# (leccion del carril N): estos git son solo locales, sin commit ni red.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX
ORIGIN_REAL="$(git remote get-url origin 2>/dev/null || echo sin-origin)"
mkdir -p "$T/na-mismo" "$T/na-otro"
printf 'x\n' >"$T/na-mismo/x"; printf 'x\n' >"$T/na-otro/x"
git -C "$T/na-mismo" init -q && git -C "$T/na-mismo" remote add origin "$ORIGIN_REAL"
git -C "$T/na-otro" init -q && git -C "$T/na-otro" remote add origin "https://example.com/otro/repo.git"
REPO_PLIST_REAL="$(repo_de_plist "$PLIST")"
[ -n "$REPO_PLIST_REAL" ] || fail "el plist no trae una ruta en REPO_DIR"
sed "s|$REPO_PLIST_REAL|$T/na-mismo|" "$PLIST" >"$T/latido-mismo.plist"
sed "s|$REPO_PLIST_REAL|$T/na-otro|" "$PLIST" >"$T/latido-otro.plist"
mismo_origin "$(repo_de_plist "$T/latido-mismo.plist")" . \
  || fail "NA verde: un REPO_DIR con el mismo origin que este repo debe pasar"
if mismo_origin "$(repo_de_plist "$T/latido-otro.plist")" .; then
  fail "el REPO_DIR del plist apunta a un repo con otro origin: 9.8 vigilaria el CI de otro"
fi
if [ -d "$REPO_PLIST_REAL" ]; then
  mismo_origin "$REPO_PLIST_REAL" . \
    || fail "el REPO_DIR del plist real ($REPO_PLIST_REAL) no es un clon de este repo: 9.8 vigilaria el CI de otro"
else
  echo "skip: el REPO_DIR del plist real ($REPO_PLIST_REAL) no existe aqui; la relacion plist<->repo se probo con el fixture"
fi
( unset TMUX_BIN; . scripts/mac/corrida/lib.sh; [ -n "${TMUX_BIN:-}" ] ) \
  || fail "lib.sh no fija TMUX_BIN: en produccion toda sesion saldria muerta"

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
tick "$((T0 + 3540))" || fail "el tick de los 59 min revinto"
[ "$(msgs)" = "1" ] || fail "a los 59 min sin cambio salieron $(msgs) mensajes (debia 0)"
trabajando_en "$((T0 + 3600))"
tick "$((T0 + 3600))" || fail "el tick de los 60 min revinto"
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
tick "$((T0 + 3900))" || fail "el tick del tope revinto"
[ "$(msgs)" = "2" ] || fail "el cambio dentro del tope salio igual (msgs=$(msgs))"

# (5) carril callado 31 min (20 min despues del ultimo mensaje): DETENIDA + vigia despierto.
watch_a m-a "$((T0 + 4800 - 1900))"
watch_a m-lead "$((T0 + 4800 - 120))"
watch_a m-b "$((T0 + 4800 - 120))"
tick "$((T0 + 4800))" || fail "el tick del callado revinto"
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
tick "$T0" || fail "lat-dlg: el primer tick revinto"
[ "$(msgs)" = "1" ] || fail "lat-dlg: el primer tick mando $(msgs) (debia 1)"
watch_a m-a "$((T0 + 300 - 605))" "cafe01-2" "$((T0 + 300 - 605))"
tick "$((T0 + 300))" || fail "el tick del dialogo de 10 min revinto"
[ "$(msgs)" = "2" ] || fail "el dialogo de 10 min no escalo (msgs=$(msgs))"
grep "message send" "$LLAMADAS" | tail -1 | grep -q "NECESITO TU RESPUESTA" || fail "el dialogo de 10 min no salio como NECESITO"
grep "message send" "$LLAMADAS" | tail -1 | grep -q -- "--silent" && fail "NECESITO salio silenciosa"
tick "$((T0 + 600))" || fail "el tercer tick del dialogo revinto"
[ "$(msgs)" = "2" ] || fail "el dialogo parado duplico mensajes (msgs=$(msgs))"
[ "$(evts)" = "1" ] || fail "el dialogo no desperto al vigia una sola vez (evts=$(evts))"

# (7) dialogo joven que la politica no cubre => NECESITO inmediato.
LLAMADAS="$T/l3.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-desc
montar_corrida lat-desc avanza
cp "$FX/dialogo/paneles/m-a.txt" "$PANEL_DIR/m-a.txt"
trabajando_en "$T0"
tick "$T0" || fail "lat-desc: el primer tick revinto"
watch_a m-a "$((T0 + 120 - 120))" "nuevo01-9" "$T0"
tick "$((T0 + 120))" || fail "el tick sin cobertura revinto"
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
tick "$T0" || fail "hermes: el tick revinto"
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
EVENTO_FALLA=1 tick "$((T0 + 300))" || fail "el segundo tick con evento caido revinto"
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

# (9b) hermes con eventos.jsonl sin poder escribirse: la linea ES el aviso; un
# fallo de escritura no se marca como enviada (reintenta al tick siguiente).
LLAMADAS="$T/l9.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-j
montar_corrida lat-j leadmuerto
rm -f "$PANEL_DIR/m-lead.txt"
sed -i.bak 's/"vigia": "claw"/"vigia": "hermes"/' "$CORRIDA_STATE/lat-j/registro.json" && rm -f "$CORRIDA_STATE/lat-j/registro.json.bak"
mkdir "$CORRIDA_STATE/lat-j/eventos.jsonl"   # directorio: el append revienta
watch_a m-a "$((T0 - 120))"
watch_a m-b "$((T0 - 120))"
tick "$T0" >/dev/null 2>&1 || fail "hermes con eventos caido mato el tick"
[ "$(msgs)" = "1" ] || fail "hermes con eventos caido igual mando el mensaje (msgs=$(msgs))"
fv="$(LATJ="$CORRIDA_STATE/lat-j/latido.json" bash -c '. scripts/mac/corrida/lib.sh; json_campo "$LATJ" firma_vigia')"
[ -z "$fv" ] || [ "$fv" = "None" ] || fail "hermes: marco firma_vigia enviada con la linea caida (fv=$fv)"

# (9c) latido.json sin poder escribirse: el aviso stderr existe y el tick sale rojo.
LLAMADAS="$T/l10.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-k
montar_corrida lat-k avanza
trabajando_en "$T0"
mkdir "$CORRIDA_STATE/lat-k/latido.json"   # directorio: el rename revienta
tick "$T0" >"$T/k.out" 2>"$T/k.err" && fail "con latido.json caido el tick salio en verde"
grep -q "no se pudo escribir" "$T/k.err" || fail "la escritura caida de latido.json no avisa en stderr"
rmdir "$CORRIDA_STATE/lat-k/latido.json"

# (9d) RA: la escritura caida de latido.json en la rama del VIGIA tambien pinta
# el tick de rojo. Memoria crafteada para que el tick no mande mensaje (firma
# igual, tope vigente) y un lead muerto que despierta al vigia; el directorio
# queda sin permiso de escritura para que la unica escritura posible sea la que
# falla.
LLAMADAS="$T/l11.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-ra
montar_corrida lat-ra leadmuerto
rm -f "$PANEL_DIR/m-lead.txt"
watch_a m-a "$((T0 - 120))"
watch_a m-b "$((T0 - 120))"
printf '%s\n' '{"firma": "e=DETENIDA|av=2/5|pr=GitHub: sin verificar|ses=m-lead:muerta,m-a:trabajando,m-b:trabajando,", "ult_msj": 1789822900, "etq": "DETENIDA", "firma_vigia": "distinta", "ci_sha": ""}' \
  >"$CORRIDA_STATE/lat-ra/latido.json"
chmod 500 "$CORRIDA_STATE/lat-ra"
tick "$T0" >/dev/null 2>"$T/ra.err" && fail "RA: con latido.json caido en la rama del vigia el tick salio en verde"
grep -q "no se pudo escribir" "$T/ra.err" || fail "RA: la rama del vigia no avisa su escritura caida"
chmod 700 "$CORRIDA_STATE/lat-ra"

# (10) 9.8: la rama por defecto en rojo no pasa en silencio.
LLAMADAS="$T/l7.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-ci
montar_corrida lat-ci avanza
trabajando_en "$T0"
GH_CI=rojo GH_SHA=cafe1234567 tick "$T0" || fail "CI rojo: el tick revinto"
[ "$(msgs)" = "2" ] || fail "CI rojo: salieron $(msgs) mensajes (debia 2: el parte y el aviso)"
grep "message send" "$LLAMADAS" | tail -1 | grep -q "\[DETENIDA\]" || fail "CI rojo: no salio como DETENIDA"
grep -qi "quedo en rojo" "$LLAMADAS" || fail "CI rojo: el aviso no habla en palabras de usuario"
d="$(grep -n "OPENCLAW message send" "$LLAMADAS" | tail -1 | cut -d: -f1)"
tail -n +"$d" "$LLAMADAS" | sed '1s/.* -m //' >"$T/ci-msg.txt"
( . scripts/mac/corrida/lib.sh && mensaje_valido "$T/ci-msg.txt" ) \
  || fail "CI rojo: el aviso no pasa el validador de lenguaje de usuario"
grep -qE '[0-9a-f]{7,}' "$T/ci-msg.txt" && fail "CI rojo: el aviso se filtro un sha o similar"
[ -f "$CORRIDA_STATE/lat-ci/ci-rojo.json" ] || fail "CI rojo: sin registro local donde el lead lee"
CIC="$CORRIDA_STATE/lat-ci/ci-rojo.json" python3 -c "
import json,os
d=json.load(open(os.environ['CIC']))
assert d.get('sha')=='cafe1234567', d
assert d.get('autor')=='gon0801', d
assert any('corrida.v1.md' in a for a in d.get('archivos',[])), d
" || fail "CI rojo: el registro local no trae sha, autor y archivos"
# el mismo sha en el tick siguiente => cero (mutacion sin memoria del sha muere).
GH_CI=rojo GH_SHA=cafe1234567 tick "$((T0 + 300))" || fail "CI rojo: el tick del mismo sha revinto"
[ "$(msgs)" = "2" ] || fail "CI rojo ya avisado volvio a avisar (msgs=$(msgs))"
GH_CI=verde tick "$((T0 + 600))" || fail "el tick con CI verde revinto"
[ "$(msgs)" = "2" ] || fail "CI verde mando mensaje (msgs=$(msgs))"
# MN: un timeout del CI tambien es rojo.
GH_CI=timeout GH_SHA=dead999888777 tick "$((T0 + 660))" || fail "el tick con CI en timeout revinto"
[ "$(msgs)" = "3" ] || fail "un timeout de CI no se aviso (msgs=$(msgs))"
grep "message send" "$LLAMADAS" | tail -1 | grep -q "\[DETENIDA\]" || fail "el timeout no salio como DETENIDA"
CIC="$CORRIDA_STATE/lat-ci/ci-rojo.json" python3 -c "
import json,os
d=json.load(open(os.environ['CIC']))
assert d.get('sha')=='dead999888777', d
" || fail "el registro local quedo con el sha viejo tras el timeout"

# MO: el registro local de rojo se escribe tras un envio que salio; si el envio
# cae, no hay registro con "avisado" mentiroso y el proximo tick reintenta.
LLAMADAS="$T/l9b.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-mo
montar_corrida lat-mo avanza
trabajando_en "$T0"
ENVIO_MODO=mal GH_CI=rojo GH_SHA=beef555aaa111 tick "$T0" >/dev/null 2>&1 || fail "MO: el tick con envio caido revinto"
[ ! -f "$CORRIDA_STATE/lat-mo/ci-rojo.json" ] || fail "MO: registro de rojo escrito con el envio caido"
ENVIO_MODO=ok GH_CI=rojo GH_SHA=beef555aaa111 tick "$((T0 + 300))" >/dev/null 2>&1 || fail "MO: el reintento revinto"
[ -f "$CORRIDA_STATE/lat-mo/ci-rojo.json" ] || fail "MO: el reintento no dejo registro local"
CIC="$CORRIDA_STATE/lat-mo/ci-rojo.json" python3 -c "
import json,os
d=json.load(open(os.environ['CIC']))
assert d.get('sha')=='beef555aaa111' and d.get('avisado'), d
" || fail "MO: el registro del reintento no trae sha y avisado"
# gh caido => cero avisos de rojo en un estado que con gh vivo SI avisaria, y el
# latido sigue. Corrida propia (firma y latido.json iniciales limpios) y reloj
# propio: lo que mide esta seccion es el gh caido, no arrastres de las demas.
LLAMADAS="$T/l8.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-gh
montar_corrida lat-gh avanza
trabajando_en "$T0"
GH_CAIDO=1 GH_CI=rojo GH_SHA=cafe1234567 tick "$T0" >/dev/null 2>"$T/ghc.err" || fail "gh caido: el tick revinto"
[ "$(msgs)" = "1" ] || fail "con gh caido salio mas que el parte (msgs=$(msgs))"
grep -qi "quedo en rojo" "$LLAMADAS" && fail "con gh caido igual se aviso el rojo"
grep "message send" "$LLAMADAS" | tail -1 | grep -q "\[AVANZA\]" || fail "con gh caido el latido dejo de latear"
[ ! -f "$CORRIDA_STATE/lat-gh/ci-rojo.json" ] || fail "con gh caido se escribio registro de rojo"

# (11) TA: run-list sano pero el commit sin metadatos (api caida): sin aviso,
# sin registro, sha sin marcar; y el tick siguiente con la api sana si avisa,
# con autor y archivos completos.
LLAMADAS="$T/l12.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-ta
montar_corrida lat-ta avanza
trabajando_en "$T0"
GH_CI=rojo GH_SHA=ta1234567890 GH_API_FALLA=1 tick "$T0" >/dev/null 2>"$T/ta.err" || fail "TA: el tick con api caida revinto"
[ "$(msgs)" = "1" ] || fail "TA: con el commit sin metadatos salio el aviso igual (msgs=$(msgs))"
grep -qi "quedo en rojo" "$LLAMADAS" && fail "TA: el aviso de rojo salio sin metadatos"
[ ! -f "$CORRIDA_STATE/lat-ta/ci-rojo.json" ] || fail "TA: se escribio ci-rojo.json sin metadatos"
[ "$(evjson lat-ta gh-fallo)" -ge 1 ] 2>/dev/null || fail "TA: el commit sin metadatos no dejo evento gh-fallo"
GH_CI=rojo GH_SHA=ta1234567890 tick "$((T0 + 300))" >/dev/null 2>&1 || fail "TA: el reintento con api sana revinto"
[ "$(msgs)" = "2" ] || fail "TA: el reintento no aviso (msgs=$(msgs))"
grep "message send" "$LLAMADAS" | tail -1 | grep -q "\[DETENIDA\]" || fail "TA: el reintento no salio como DETENIDA"
CIC="$CORRIDA_STATE/lat-ta/ci-rojo.json" python3 -c "
import json,os
d=json.load(open(os.environ['CIC']))
assert d.get('sha')=='ta1234567890', d
assert d.get('autor')=='gon0801' and any('corrida.v1.md' in a for a in d.get('archivos',[])), d
" || fail "TA: el registro del reintento no trae autor y archivos"

# (11b) TB: ci-rojo.json sin poder persistirse => el sha NO queda marcado (el
# tick siguiente vuelve a avisarlo) y el tick deja rastro.
LLAMADAS="$T/l13.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-tb
montar_corrida lat-tb avanza
trabajando_en "$T0"
mkdir "$CORRIDA_STATE/lat-tb/ci-rojo.json"   # directorio: el rename revienta
GH_CI=rojo GH_SHA=tb9876543210 tick "$T0" >/dev/null 2>"$T/tb.err" && fail "TB: el tick con registro caido salio en verde"
grep -q "no se pudo escribir" "$T/tb.err" || fail "TB: el registro caido no avisa"
[ "$(msgs)" = "2" ] || fail "TB: con el registro caido salieron $(msgs) mensajes (debia 2: parte y aviso)"
rmdir "$CORRIDA_STATE/lat-tb/ci-rojo.json"
GH_CI=rojo GH_SHA=tb9876543210 tick "$((T0 + 300))" >/dev/null 2>&1 || fail "TB: el reintento revinto"
[ "$(msgs)" = "3" ] || fail "TB: el sha quedo marcado sin registro; no se reaviso (msgs=$(msgs))"
CIC="$CORRIDA_STATE/lat-tb/ci-rojo.json" python3 -c "
import json,os
assert json.load(open(os.environ['CIC'])).get('sha')=='tb9876543210'
" || fail "TB: el reintento no dejo el registro"

# (11c) TC: si ademas falla anotar el evento, el stderr lo dice (sin mensaje).
LLAMADAS="$T/l14.log"; export LLAMADAS; : > "$LLAMADAS"
solo_dejar lat-tc
montar_corrida lat-tc avanza
trabajando_en "$T0"
mkdir "$CORRIDA_STATE/lat-tc/eventos.jsonl"   # directorio: el append revienta
GH_CAIDO=1 tick "$T0" >/dev/null 2>"$T/tc.err" || fail "TC: el tick con eventos caidos revinto"
grep -q "no se pudo consultar" "$T/tc.err" || fail "TC: falta el diagnostico de la consulta"
grep -q "no se pudo anotar el fallo" "$T/tc.err" || fail "TC: la persistencia caida del evento no avisa"
# SA: la consulta caida deja rastro (stderr + evento), no un salto en silencio.
grep -q "no se pudo consultar" "$T/ghc.err" || fail "SA: la consulta de CI caida no avisa en stderr"
[ "$(evjson lat-gh gh-fallo)" = "1" ] || fail "SA: la consulta de CI caida no dejo evento gh-fallo"

echo "TODO VERDE: test-corrida-latido"
