#!/bin/bash
# 19.1 U1/B2: prueba de `corrida.sh avisos` (contrato corrida-aviso.v1) y del Stop
# hook con identidad de corrida. Ninguna prueba toca el estado real: CORRIDA_STATE
# apunta a un temporal, TMUX_BIN a un doble que responde desde archivos y deja las
# teclas en una bitacora, y corrida.sh/openclaw del hook a dobles que cuentan
# llamadas. Uso: bash scripts/tests/test-corrida-avisos.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CORR=scripts/mac/corrida.sh
CORR_ABS="$PWD/scripts/mac/corrida.sh"
[ -f "$CORR" ] || fail "falta $CORR"
/bin/bash -n "$CORR" || fail "$CORR no parsea"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

export CORRIDA_STATE="$T/corridas"

# Doble de tmux: has-session y capture-pane salen de archivos; TODA llamada queda
# en la bitacora, asi el despertar al lead se verifica por sus teclas.
TECLAS="$T/teclas.log"; : >"$TECLAS"
LEAD_VIVA="$T/lead-viva"; echo 1 >"$LEAD_VIVA"
PANTALLA_LEAD="$T/pantalla-lead.txt"; printf 'trabajando en la parte 2\n' >"$PANTALLA_LEAD"
cat >"$T/tmux-falso" <<TMSTUB
#!/bin/sh
printf '%s\n' "TMUX \$*" >> "$TECLAS"
case "\$1" in
  has-session) [ "\$(cat "$LEAD_VIVA" 2>/dev/null)" = "1" ] && exit 0 || exit 1;;
  capture-pane) cat "$PANTALLA_LEAD" 2>/dev/null; exit 0;;
  *) exit 0;;
esac
TMSTUB
chmod +x "$T/tmux-falso"
export TMUX_BIN="$T/tmux-falso"

registro() { # $1 id $2 estado $3 sesiones "nombre:rol:cli,..." (la primera lead si su rol lo dice)
  mkdir -p "$CORRIDA_STATE/$1"
  R_ID="$1" R_ESTADO="$2" R_SES="$3" R_DIR="$CORRIDA_STATE/$1" python3 - <<'PY'
import json, os
ses = []
for spec in os.environ['R_SES'].split(','):
    if not spec:
        continue
    n, r, c = spec.split(':')
    ses.append({'nombre': n, 'rol': r, 'cli': c, 'dueno': 'lead', 'dir': '/tmp'})
json.dump({'id': os.environ['R_ID'], 'estado': os.environ['R_ESTADO'], 'sesiones': ses},
          open(os.path.join(os.environ['R_DIR'], 'registro.json'), 'w'))
PY
}
emitir() { bash "$CORR_ABS" avisos emitir "$@"; }
avisos_dir() { printf '%s/%s/avisos' "$CORRIDA_STATE" "$1"; }
n_pend() { ls "$(avisos_dir "$1")"/*.json 2>/dev/null | wc -l | tr -d ' '; }
json_leer() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$1" "$2"; }

# (a) Emision feliz: un aviso corrida-aviso.v1 valido y el lead doble despierto.
registro t1 abierta lead-main:lead:zcode,ses-c1:carril:glm
out=$(emitir t1 ses-c1 fin-turno --llave senal-1 "termino la parte 2"); rc=$?
[ "$rc" -eq 0 ] || fail "(a) emitir feliz debio salir 0 (rc=$rc): $out"
D="$(avisos_dir t1)"
n=$(ls "$D"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -eq 1 ] || fail "(a) esperaba un aviso, hubo $n"
F=$(ls "$D"/*.json)
ID=$(basename "$F" .json)
case "$ID" in t1-ses-c1-fin-turno-*) ;; *) fail "(a) el id no sigue corrida-sesion-tipo-hash: $ID";; esac
[ "$(json_leer "$F" schema)" = "corrida-aviso.v1" ] || fail "(a) schema incorrecto: $(json_leer "$F" schema)"
[ "$(json_leer "$F" id)" = "$ID" ] || fail "(a) el id del documento no es el del archivo"
[ "$(json_leer "$F" corrida)" = "t1" ] || fail "(a) corrida incorrecta"
[ "$(json_leer "$F" sesion)" = "ses-c1" ] || fail "(a) sesion incorrecta"
[ "$(json_leer "$F" rol)" = "carril" ] || fail "(a) el rol debe salir del registro"
[ "$(json_leer "$F" cli)" = "glm" ] || fail "(a) el cli debe salir del registro"
[ "$(json_leer "$F" tipo)" = "fin-turno" ] || fail "(a) tipo incorrecto"
[ "$(json_leer "$F" detalle)" = "termino la parte 2" ] || fail "(a) detalle incorrecto"
creado=$(json_leer "$F" creado)
case "$creado" in ''|*[!0-9]*) fail "(a) creado no es epoch-ms: $creado";; esac
ahora=$(python3 -c 'import time; print(int(time.time()*1000))')
[ $((ahora - creado)) -lt 60000 ] || fail "(a) creado no es ahora: $creado"
grep -q 'send-keys -t =lead-main: -l -- corrida.sh avisos atender t1' "$TECLAS" \
  || fail "(a) no desperto al lead: $(cat "$TECLAS")"
grep -q 'send-keys -t =lead-main: Enter' "$TECLAS" || fail "(a) falto el Enter del despertar"
echo "ok (a): emision feliz escribe un aviso valido y despierta al lead"

# (b) Duplicado con la misma llave: un solo archivo, sin reescribir ni re-despertar.
: >"$TECLAS"
emitir t1 ses-c1 fin-turno --llave senal-1 "texto distinto" \
  || fail "(b) el duplicado debio salir 0"
n=$(n_pend t1)
[ "$n" -eq 1 ] || fail "(b) el duplicado debio dejar un solo archivo, hubo $n"
grep -q 'send-keys' "$TECLAS" && fail "(b) el duplicado re-desperto al lead"
[ "$(json_leer "$F" detalle)" = "termino la parte 2" ] || fail "(b) el duplicado reescribio el aviso"
# Otra llave, mismo tipo: identidad distinta, otro aviso.
emitir t1 ses-c1 fin-turno --llave senal-2 || fail "(b) otra llave debio emitir"
[ "$(n_pend t1)" -eq 2 ] || fail "(b) la otra llave debio dejar otro archivo"
echo "ok (b): la misma llave deduplica por identidad, otra llave emite otro aviso"

# (c) Sesion ajena, corrida cerrada y corrida inexistente: rc 3 (rechazo definitivo, no se reintenta), motivo, sin escribir.
emitir t1 ses-fantasma fin-turno --llave k 2>"$T/err-c1" && fail "(c) la sesion ajena debio fallar"
grep -q . "$T/err-c1" || fail "(c) el rechazo de la sesion ajena no da motivo"
[ "$(cat "$T/err-c1")" = "avisos emitir: la sesion ses-fantasma no esta en el registro de t1" ] \
  || fail "(c) el rechazo de la sesion ajena no es el literal: $(cat "$T/err-c1")"
registro t2 cerrada lead-main:lead:zcode,ses-c2:carril:glm
emitir t2 ses-c2 fin-turno --llave k 2>/dev/null && fail "(c) la corrida cerrada debio fallar"
[ "$(n_pend t2)" -eq 0 ] || fail "(c) la corrida cerrada dejo un aviso escrito"
emitir t-inexistente ses-c1 fin-turno --llave k 2>/dev/null && fail "(c) la corrida inexistente debio fallar"
echo "ok (c): sesion ajena, corrida cerrada e inexistente caen con rc 3 y sin escritura"

# (d) Dueno ocupado (dialogo en pantalla) o lead inexistente: sin teclas, pendiente persiste.
registro t3 abierta lead-main:lead:zcode,ses-c3:carril:glm
printf 'Permission - Bash\n> Allow once\n waiting for approval\n' >"$PANTALLA_LEAD"
: >"$TECLAS"
emitir t3 ses-c3 aprobacion --llave d1 || fail "(d) con el lead ocupado debia salir 0 igual"
[ "$(n_pend t3)" -eq 1 ] || fail "(d) el pendiente no persistio con el lead ocupado"
grep -q 'send-keys' "$TECLAS" && fail "(d) le mando teclas a un lead con dialogo de aprobacion"
echo 0 >"$LEAD_VIVA"
registro t4 abierta lead-main:lead:zcode,ses-c4:carril:glm
emitir t4 ses-c4 fin-turno --llave d2 || fail "(d) sin sesion lead debia salir 0 igual"
[ "$(n_pend t4)" -eq 1 ] || fail "(d) el pendiente no persistio sin lead vivo"
echo 1 >"$LEAD_VIVA"
printf 'trabajando en la parte 2\n' >"$PANTALLA_LEAD"
echo "ok (d): dueno ocupado o lead ausente no reciben teclas y el pendiente persiste"

# (e) Atender reclama TODO por rename, marca atendido y corre reconciliar UNA vez.
registro t5 abierta lead-main:lead:zcode,ses-c5:carril:glm,ses-c5b:carril:glm
emitir t5 ses-c5 fin-turno --llave e1 || fail "(e) precondicion: emitir e1"
emitir t5 ses-c5b aprobacion --llave e2 || fail "(e) precondicion: emitir e2"
[ "$(n_pend t5)" -eq 2 ] || fail "(e) precondicion: faltan pendientes"
CCLOG="$T/corrida-cuentas.log"; : >"$CCLOG"
CC="$T/corrida-cuenta"
cat >"$CC" <<CSTUB
#!/bin/sh
printf '%s\n' "\$*" >> "$CCLOG"
exit 0
CSTUB
chmod +x "$CC"
CORRIDA_BIN="$CC" bash "$CORR_ABS" avisos atender t5 || fail "(e) atender fallo"
[ "$(n_pend t5)" -eq 0 ] || fail "(e) atender no reclamo los pendientes"
T5="$CORRIDA_STATE/t5/avisos/tratados"
n=$(ls "$T5"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -eq 2 ] || fail "(e) esperaba 2 avisos en tratados, hubo $n"
for f in "$T5"/*.json; do
  at=$(json_leer "$f" atendido)
  case "$at" in ''|*[!0-9]*) fail "(e) falta atendido epoch-ms en $f";; esac
done
n=$(grep -c '^reconciliar t5$' "$CCLOG")
[ "$n" -eq 1 ] || fail "(e) reconciliar debio llamarse UNA vez, se llamo $n: $(cat "$CCLOG")"
grep -q '"tipo": *"avisos-atendidos"' "$CORRIDA_STATE/t5/eventos.jsonl" \
  || fail "(e) falta la anotacion en eventos.jsonl: $(cat "$CORRIDA_STATE/t5/eventos.jsonl" 2>&1)"
out=$(bash "$CORR_ABS" avisos atender t5); rc=$?
[ "$rc" -eq 0 ] || fail "(e) atender sin pendientes debio salir 0 (rc=$rc)"
printf '%s' "$out" | grep -q 'sin pendientes' || fail "(e) atender sin pendientes no lo dice: $out"
n=$(grep -c '^reconciliar t5$' "$CCLOG")
[ "$n" -eq 1 ] || fail "(e) el atender sin pendientes volvio a llamar reconciliar"
echo "ok (e): atender reclama por rename, marca atendido y corre reconciliar una sola vez"

# (f) Aviso tardio: sesion que ya no esta registrada o corrida que se cerro
# mientras el pendiente vivia: queda en tratados con descartado y motivo.
registro t6 abierta lead-main:lead:zcode,ses-c6:carril:glm
emitir t6 ses-c6 fin-turno --llave f1 || fail "(f) precondicion: emitir f1"
registro t6 abierta lead-main:lead:zcode
bash "$CORR_ABS" avisos atender t6 || fail "(f) atender t6 fallo"
TF=$(ls "$CORRIDA_STATE/t6/avisos/tratados"/*.json | head -1)
[ -n "$TF" ] || fail "(f) falta el aviso en tratados"
[ "$(json_leer "$TF" descartado)" != "" ] || fail "(f) el aviso tardio no quedo descartado con motivo"
registro t7 abierta lead-main:lead:zcode,ses-c7:carril:glm
emitir t7 ses-c7 cierre --llave f2 || fail "(f) precondicion: emitir f2"
registro t7 cerrada lead-main:lead:zcode,ses-c7:carril:glm
bash "$CORR_ABS" avisos atender t7 || fail "(f) atender t7 fallo"
TF=$(ls "$CORRIDA_STATE/t7/avisos/tratados"/*.json | head -1)
[ "$(json_leer "$TF" descartado)" != "" ] || fail "(f) el aviso de corrida cerrada no quedo descartado"
n=$(grep -c '^reconciliar' "$CCLOG")
[ "$n" -eq 1 ] || fail "(f) los avisos descartados no deben correr reconciliar (hubo $n)"
echo "ok (f): aviso tardio de sesion fuera del registro o corrida cerrada queda descartado con motivo"

# (g) Aviso + tick simultaneos: dos emitir concurrentes con la misma llave dejan UN archivo.
registro t8 abierta lead-main:lead:zcode,ses-c8:carril:glm
emitir t8 ses-c8 fin-turno --llave misma & p1=$!
emitir t8 ses-c8 fin-turno --llave misma & p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
[ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] || fail "(g) un emitir concurrente fallo (r1=$r1 r2=$r2)"
[ "$(n_pend t8)" -eq 1 ] || fail "(g) dos emitir concurrentes dejaron $(n_pend t8) archivos"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$(ls "$(avisos_dir t8)"/*.json)" \
  || fail "(g) el archivo superviviente no es JSON valido"
echo "ok (g): dos emitir concurrentes con la misma llave convergen en un solo aviso"

# (h) Reversa CORRIDA_AVISOS=0: nada se escribe, nada se despierta, nada se reclama.
registro t9 abierta lead-main:lead:zcode,ses-c9:carril:glm
: >"$TECLAS"
CORRIDA_AVISOS=0 emitir t9 ses-c9 fin-turno --llave h1 || fail "(h) la reversa debio salir 0"
[ "$(n_pend t9)" -eq 0 ] || fail "(h) la reversa escribio un aviso"
grep -q 'send-keys' "$TECLAS" && fail "(h) la reversa desperto al lead"
mkdir -p "$(avisos_dir t9)"
printf '{"schema":"corrida-aviso.v1","sesion":"ses-c9"}\n' >"$(avisos_dir t9)/t9-ses-c9-fin-turno-manual.json"
CORRIDA_AVISOS=0 bash "$CORR_ABS" avisos atender t9 || fail "(h) la reversa de atender debio salir 0"
[ -f "$(avisos_dir t9)/t9-ses-c9-fin-turno-manual.json" ] || fail "(h) la reversa reclamo el pendiente"
[ -d "$(avisos_dir t9)/tratados" ] && fail "(h) la reversa creo tratados"
CORRIDA_AVISOS=0 bash "$CORR_ABS" avisos despertar t9 || fail "(h) la reversa de despertar debio salir 0"
grep -q 'send-keys' "$TECLAS" && fail "(h) la reversa desperto con despertar"
echo "ok (h): CORRIDA_AVISOS=0 deja emitir, atender y despertar en no-op"

# (i) Metadatos invalidos: tipo fuera del conjunto, llave vacia, detalle >200: rc 2, sin escribir.
emitir t9 ses-c9 tipo-raro --llave k 2>/dev/null; rc=$?
[ "$rc" -eq 2 ] || fail "(i) el tipo fuera del conjunto debio salir 2, salio $rc"
emitir t9 ses-c9 fin-turno --llave "" 2>/dev/null; rc=$?
[ "$rc" -eq 2 ] || fail "(i) la llave vacia debio salir 2, salio $rc"
emitir t9 ses-c9 fin-turno --llave k "$(python3 -c 'print("x"*201)')" 2>/dev/null; rc=$?
[ "$rc" -eq 2 ] || fail "(i) el detalle de 201 caracteres debio salir 2, salio $rc"
[ "$(n_pend t9)" -eq 1 ] || fail "(i) los metadatos invalidos escribieron algo"
emitir t9 ses-c9 fin-turno 2>/dev/null; rc=$?
[ "$rc" -eq 2 ] || fail "(i) emitir sin --llave debio salir 2, salio $rc"
echo "ok (i): metadatos invalidos caen con rc 2 y sin escritura"

# (j) Despertar: reintenta SOLO el paso de despertar sobre pendientes existentes,
# sin reescribirlos; sin pendientes no manda teclas.
registro t10 abierta lead-main:lead:zcode,ses-c10:carril:glm
bash "$CORR_ABS" avisos despertar t10 || fail "(j) despertar sin pendientes debio salir 0"
grep -q 'send-keys' "$TECLAS" && fail "(j) despertar sin pendientes mando teclas"
printf 'Permission - Bash\nwaiting for approval\n' >"$PANTALLA_LEAD"
emitir t10 ses-c10 aprobacion --llave j1 || fail "(j) precondicion: emitir con lead ocupado"
grep -q 'send-keys' "$TECLAS" && fail "(j) precondicion: el emitir desperto con el lead ocupado"
printf 'trabajando en la parte 2\n' >"$PANTALLA_LEAD"
: >"$TECLAS"
bash "$CORR_ABS" avisos despertar t10 || fail "(j) despertar fallo"
grep -q 'send-keys -t =lead-main: -l -- corrida.sh avisos atender t10' "$TECLAS" \
  || fail "(j) despertar no mando las teclas: $(cat "$TECLAS")"
[ "$(n_pend t10)" -eq 1 ] || fail "(j) despertar no debe reescribir ni consumir pendientes"
echo "ok (j): despertar reintenta el despertar del lead sin tocar los pendientes"

# (k) El Stop hook con identidad de corrida (19.1 U3). Invocacion con env y
# dobles propios: nunca se ejecuta el hook instalado de nadie ni el openclaw real.
H=scripts/mac/claude-stop-openclaw-event.sh
if [ -f "$H" ]; then
  /bin/bash -n "$H" || fail "(k) $H no parsea con /bin/bash"
  HOOK_T="$T/hook"; mkdir -p "$HOOK_T"
  TRANSCRIPT="$HOOK_T/transcript.jsonl"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"listo"}]}}\n' >"$TRANSCRIPT"
  MTIME=$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$TRANSCRIPT")
  HOOK_JSON=$(python3 -c "
import json
print(json.dumps({'cwd': '/tmp/hook', 'session_id': 'abc123', 'transcript_path': '$TRANSCRIPT', 'hook_event_name': 'Stop', 'stop_hook_active': False}))
")
  OCALLS="$T/hook-openclaw.log"; : >"$OCALLS"
  STUB_OC="$T/openclaw-stub"
  cat >"$STUB_OC" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$OCALLS"
STUB
  chmod +x "$STUB_OC"
  HCALLS="$T/hook-corrida.log"; : >"$HCALLS"
  STUB_HC="$T/corrida-stub"
  cat >"$STUB_HC" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$HCALLS"
exit 0
STUB
  chmod +x "$STUB_HC"
  RUN_FILE="$T/hook-run"; : >"$RUN_FILE"
  MARK_FILE="$T/hook-mark"; echo 1 >"$MARK_FILE"
  MANAGED_FILE="$T/hook-managed"; : >"$MANAGED_FILE"
  DISPLAY_STUB="$T/tmux-display-stub"
  cat >"$DISPLAY_STUB" <<STUB
#!/bin/sh
if [ "\$1" = "display-message" ]; then echo "claude-orbit"; exit 0; fi
if [ "\$2" = "OPENCLAW_WATCH" ]; then
  if [ "\$(cat "$MARK_FILE")" = "1" ]; then echo "OPENCLAW_WATCH=1"; exit 0; fi
  echo "unknown variable: OPENCLAW_WATCH" >&2; exit 1
fi
if [ "\$2" = "OPENCLAW_WATCH_RUN" ]; then
  r=\$(cat "$RUN_FILE")
  if [ -n "\$r" ]; then echo "OPENCLAW_WATCH_RUN=\$r"; exit 0; fi
  echo "unknown variable: OPENCLAW_WATCH_RUN" >&2; exit 1
fi
if [ "\$2" = "AGENT_WORK_MANAGED" ]; then
  if [ "\$(cat "$MANAGED_FILE")" = "1" ]; then echo "AGENT_WORK_MANAGED=1"; exit 0; fi
  echo "unknown variable: AGENT_WORK_MANAGED" >&2; exit 1
fi
exit 0
STUB
  chmod +x "$DISPLAY_STUB"
  hook_run() {
    TMUX=fake TMUX_BIN="$DISPLAY_STUB" OPENCLAW_BIN="$STUB_OC" CORRIDA_BIN="$STUB_HC" \
      bash -c "printf '%s' '$HOOK_JSON' | bash '$H'; echo \$?" | tail -1
  }
  espera_log() { # $1 archivo, $2 lineas esperadas
    local i=0
    while [ "$(wc -l <"$1" | tr -d ' ')" -lt "$2" ] && [ "$i" -lt 50 ]; do
      sleep 0.1; i=$((i + 1))
    done
  }

  echo "sim9-HOOK" >"$RUN_FILE"
  rc=$(hook_run)
  [ "$rc" = "0" ] || fail "(k) el hook con run debio salir 0, salio $rc"
  espera_log "$HCALLS" 1
  grep -q "^avisos emitir sim9-HOOK claude-orbit fin-turno --llave $MTIME\$" "$HCALLS" \
    || fail "(k) el hook con run no mando el aviso fin-turno con la llave del mtime: $(cat "$HCALLS")"
  [ "$(wc -l <"$OCALLS" | tr -d ' ')" -eq 0 ] || fail "(k) el hook con run NO debia mandar el evento: $(cat "$OCALLS")"
  echo "ok (k-con-run): el hook de una corrida manda avisos emitir con la llave del mtime y nada a vigia-mac"

  : >"$HCALLS"; : >"$OCALLS"; : >"$RUN_FILE"
  rc=$(hook_run)
  [ "$rc" = "0" ] || fail "(k) el hook sin run debio salir 0, salio $rc"
  espera_log "$OCALLS" 1
  grep -q -- '--session-key agent:main:vigia-mac' "$OCALLS" \
    || fail "(k) sin run el hook debia mandar a agent:main:vigia-mac: $(cat "$OCALLS")"
  grep -q 'claude-orbit' "$OCALLS" || fail "(k) el evento sin run perdio la sesion: $(cat "$OCALLS")"
  [ "$(wc -l <"$HCALLS" | tr -d ' ')" -eq 0 ] || fail "(k) sin run no debia llamarse a corrida.sh: $(cat "$HCALLS")"
  echo "ok (k-sin-run): sin corrida la llamada del hook es identica a la de siempre"

  echo "sim9-HOOK" >"$RUN_FILE"; : >"$HCALLS"; : >"$OCALLS"
  rc=$(CORRIDA_AVISOS=0 hook_run)
  [ "$rc" = "0" ] || fail "(k) el hook con la reversa debio salir 0, salio $rc"
  espera_log "$OCALLS" 1
  grep -q -- '--session-key agent:main:vigia-mac' "$OCALLS" \
    || fail "(k) con CORRIDA_AVISOS=0 el evento debia salir como hoy: $(cat "$OCALLS")"
  [ "$(wc -l <"$HCALLS" | tr -d ' ')" -eq 0 ] || fail "(k) la reversa no debia llamar a corrida.sh: $(cat "$HCALLS")"
  echo "ok (k-reversa): CORRIDA_AVISOS=0 devuelve el hook a la ruta de vigia-mac"

  echo 1 >"$MANAGED_FILE"; : >"$HCALLS"; : >"$OCALLS"
  rc=$(hook_run)
  [ "$rc" = "0" ] || fail "(k-managed) el hook gestionado debio salir 0, salio $rc"
  sleep 0.2
  [ ! -s "$HCALLS" ] && [ ! -s "$OCALLS" ] \
    || fail "(k-managed) Stop sin informe desperto un modelo: $(cat "$HCALLS" "$OCALLS")"
  echo "ok (k-managed): Stop gestionado sin informe no despierta modelo"
else
  echo "SKIP (k): falta $H"
fi

# (l) F1 r9: el lock no cede -> atender sale 1 SIN reclamar nada. Los
# pendientes siguen en avisos/ (el reintento del vigia sigue vivo) y no
# queda nada varado en tratados/ sin marca de estado.
registro tl abierta lead-main:lead:zcode,ses-l1:carril:glm
emitir tl ses-l1 fin-turno --llave l1 "parte l lista" >/dev/null || fail "(l) precondicion: emitir l1"
mkdir "$CORRIDA_STATE/tl/.lock"
out=$(CORR_LOCK_INTENTOS=5 bash "$CORR_ABS" avisos atender tl 2>&1); rc=$?
rmdir "$CORRIDA_STATE/tl/.lock" 2>/dev/null
[ "$rc" -eq 1 ] || fail "(l) atender con lock ajeno debia salir 1 (rc=$rc): $out"
printf '%s' "$out" | grep -q 'no cedio' || fail "(l) la razon del fallo debia decirse: $out"
[ "$(n_pend tl)" -ge 1 ] || fail "(l) el pendiente debia seguir en avisos/, no varado en tratados/"
[ "$(ls "$CORRIDA_STATE/tl/avisos/tratados"/*.json 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ] \
  || fail "(l) tratados/ debia quedar vacio si el lock no cedio"
echo "ok (l): con el lock no cedido, atender no reclama nada y sale 1"

# (m) F2 r9: un dialogo que SOLO casa con la expresion completa del vigia
# ("Run this command?" no esta en la copia estrecha) frena el despertar:
# ni una tecla dentro del dialogo y el pendiente sigue para el reintento.
registro tm abierta lead-main:lead:zcode,ses-m1:carril:glm
printf 'trabajando en la parte 3\n\nRun this command?\n' >"$PANTALLA_LEAD"
: >"$TECLAS"
emitir tm ses-m1 fin-turno --llave m1 "parte m" >/dev/null || fail "(m) precondicion: emitir m1"
if grep -q 'send-keys' "$TECLAS"; then
  fail "(m) el guard tecleo dentro del dialogo 'Run this command?': $(grep 'send-keys' "$TECLAS" | head -2 | tr '\n' ';')"
fi
[ "$(n_pend tm)" -ge 1 ] || fail "(m) el pendiente debia seguir en avisos/ tras el guard"
echo "ok (m): un dialogo Run this command? frena el despertar sin teclear"
printf 'trabajando en la parte 2\n' >"$PANTALLA_LEAD"

# (n) B1 r11: un segundo atender solo trata lo que reclamo en esa pasada.
# Los tratados viejos conservan su sello, un descartado viejo no pasa a
# atendido aunque su sesion vuelva al registro, y el conteo no da negativo.
registro tn abierta lead-main:lead:zcode,ses-n1:carril:glm,ses-n2:carril:glm
emitir tn ses-n1 fin-turno --llave n1 >/dev/null || fail "(n) precondicion: emitir n1"
CORRIDA_BIN="$CC" bash "$CORR_ABS" avisos atender tn >/dev/null || fail "(n) primer atender fallo"
TN="$CORRIDA_STATE/tn/avisos/tratados"
FN1=$(ls "$TN"/tn-ses-n1-*.json)
sello1=$(json_leer "$FN1" atendido)
emitir tn ses-n2 fin-turno --llave n2 >/dev/null || fail "(n) precondicion: emitir n2"
registro tn abierta lead-main:lead:zcode,ses-n1:carril:glm
CORRIDA_BIN="$CC" bash "$CORR_ABS" avisos atender tn >/dev/null || fail "(n) segundo atender fallo"
FN2=$(ls "$TN"/tn-ses-n2-*.json)
[ -n "$(json_leer "$FN2" descartado)" ] || fail "(n) precondicion: n2 debia quedar descartado"
registro tn abierta lead-main:lead:zcode,ses-n1:carril:glm,ses-n2:carril:glm
sleep 1
emitir tn ses-n1 fin-turno --llave n3 >/dev/null || fail "(n) precondicion: emitir n3"
out=$(CORRIDA_BIN="$CC" bash "$CORR_ABS" avisos atender tn) || fail "(n) tercer atender fallo"
[ "$out" = "avisos: 1 atendidos, 0 descartados" ] || fail "(n) el tercer atender debia tratar solo n3: $out"
[ "$(json_leer "$FN1" atendido)" = "$sello1" ] || fail "(n) el atendido viejo de n1 recibio un sello nuevo"
[ -z "$(json_leer "$FN2" atendido)" ] || fail "(n) el descartado viejo de n2 quedo atendido y descartado a la vez"
echo "ok (n): atender solo trata lo que reclamo en su pasada"

# (p) F11 C2-r1: el recordatorio (misma llave -> mismo id) no debe pisar el
# tratado previo: el tratado conserva su sello y el duplicado queda en
# tratados como descartado con motivo.
registro tp abierta lead-main:lead:zcode,ses-p1:carril:glm
emitir tp ses-p1 aprobacion --llave p1 "parte p1" >/dev/null || fail "(p) precondicion: emitir p1"
CORRIDA_BIN="$CC" bash "$CORR_ABS" avisos atender tp >/dev/null || fail "(p) primer atender fallo"
VIEJO=$(ls "$CORRIDA_STATE/tp/avisos/tratados/"*p1*.json | head -1)
SELLO_VIEJO=$(json_leer "$VIEJO" atendido)
[ -n "$SELLO_VIEJO" ] || fail "(p) precondicion: el primer atender no anoto atendido"
sleep 1
emitir tp ses-p1 aprobacion --llave p1 "recordatorio 60 min" >/dev/null || fail "(p) precondicion: emitir recordatorio"
[ "$(n_pend tp)" -eq 1 ] || fail "(p) el recordatorio debia dejar un pendiente (misma llave, mismo id)"
out=$(CORRIDA_BIN="$CC" bash "$CORR_ABS" avisos atender tp); rc=$?
[ "$rc" -eq 0 ] || fail "(p) segundo atender fallo (rc=$rc): $out"
[ "$(json_leer "$VIEJO" atendido)" = "$SELLO_VIEJO" ]   || fail "(p) el tratado previo fue pisado por el recordatorio con el mismo id ($SELLO_VIEJO -> $(json_leer "$VIEJO" atendido))"
DUP=$(ls "$CORRIDA_STATE/tp/avisos/tratados/"duplicado-*p1*.json 2>/dev/null | head -1)
[ -n "$DUP" ] || fail "(p) el duplicado debia quedar en tratados con marca propia"
[ "$(json_leer "$DUP" descartado)" != "" ] || fail "(p) el duplicado debia quedar descartado con motivo"
printf '%s' "$out" | grep -q 'avisos: 0 atendidos, 1 descartados'   || fail "(p) el segundo atender debia contar 0 atendidos y 1 descartado: $out"
echo "ok (p): el recordatorio con la misma llave no pisa el tratado previo"


# (o) B2 r11: despertar recibe varias corridas en una llamada y despierta a cada una.
registro to1 abierta lead-main:lead:zcode,ses-o1:carril:glm
registro to2 abierta lead-main:lead:zcode,ses-o2:carril:glm
printf 'Permission - Bash\nwaiting for approval\n' >"$PANTALLA_LEAD"
emitir to1 ses-o1 fin-turno --llave o1 >/dev/null || fail "(o) precondicion: emitir o1"
emitir to2 ses-o2 fin-turno --llave o2 >/dev/null || fail "(o) precondicion: emitir o2"
printf 'trabajando en la parte 2\n' >"$PANTALLA_LEAD"
: >"$TECLAS"
bash "$CORR_ABS" avisos despertar to1 to2 || fail "(o) despertar con dos corridas fallo"
grep -q -- '-- corrida.sh avisos atender to1$' "$TECLAS" || fail "(o) no desperto a to1: $(cat "$TECLAS")"
grep -q -- '-- corrida.sh avisos atender to2$' "$TECLAS" || fail "(o) no desperto a to2: $(cat "$TECLAS")"
echo "ok (o): despertar con varias corridas despierta a cada una"

# (q) T9 :265: una sesion gestionada (encargo_ref o host_id con valor) la reporta su
# host al solicitante; emitir la rechaza con rc 3 sin escribir ni despertar al lead,
# y atender descarta con motivo un pendiente viejo de ella. Filas: las dos claves,
# solo host_id, solo encargo_ref; claves vacias, null y encargo plano se emiten.
registro_q() { # $1 id: lead-main y una sesion por fila de la tabla
  mkdir -p "$CORRIDA_STATE/$1"
  R_ID="$1" R_DIR="$CORRIDA_STATE/$1" python3 - <<'PY'
import json, os
base = {'rol': 'carril', 'cli': 'glm', 'dueno': 'lead', 'dir': '/tmp'}
filas = [('lead-main', {'rol': 'lead', 'cli': 'zcode'}),
         ('g-ab', {'host_id': 'mac-local', 'encargo_ref': '/host/inbox/ab.json'}),
         ('g-h', {'host_id': 'mac-local'}),
         ('g-r', {'encargo_ref': '/host/inbox/r.json'}),
         ('g-v', {'host_id': '', 'encargo_ref': ''}),
         ('g-n', {'host_id': None, 'encargo_ref': None}),
         ('p-e', {'encargo': '/tmp/plano.txt'})]
ses = [dict(base, nombre=n, **extra) for n, extra in filas]
json.dump({'id': os.environ['R_ID'], 'estado': 'abierta', 'sesiones': ses},
          open(os.path.join(os.environ['R_DIR'], 'registro.json'), 'w'))
PY
}
registro_q t20
for s in g-ab g-h g-r; do
  : >"$TECLAS"
  emitir t20 "$s" fin-turno --llave "q-$s" 2>"$T/err-q"; rc=$?
  [ "$rc" -eq 3 ] || fail "(q) emitir sobre la gestionada $s debio salir 3 (rc=$rc)"
  [ "$(cat "$T/err-q")" = "avisos emitir: la sesion $s de t20 es gestionada (T9 :265): la reporta su host" ] \
    || fail "(q) el rechazo de $s no es el literal: $(cat "$T/err-q")"
  [ "$(n_pend t20)" -eq 0 ] || fail "(q) emitir sobre la gestionada $s dejo un aviso escrito"
  grep -q 'send-keys' "$TECLAS" && fail "(q) emitir sobre la gestionada $s desperto al lead: $(cat "$TECLAS")"
done
k=0
for s in g-v g-n p-e; do
  : >"$TECLAS"; k=$((k + 1))
  emitir t20 "$s" fin-turno --llave "q-$s" || fail "(q) $s no es gestionada y debio emitirse"
  [ "$(n_pend t20)" -eq "$k" ] || fail "(q) $s no dejo su aviso (hay $(n_pend t20))"
  grep -q 'send-keys -t =lead-main: -l -- corrida.sh avisos atender t20' "$TECLAS" \
    || fail "(q) el aviso de $s no desperto al lead: $(cat "$TECLAS")"
done
printf '{"schema":"corrida-aviso.v1","sesion":"g-ab","tipo":"fin-turno"}\n' >"$(avisos_dir t20)/t20-g-ab-fin-turno-viejo.json"
: >"$CCLOG"
out=$(CORRIDA_BIN="$CC" bash "$CORR_ABS" avisos atender t20) || fail "(q) atender t20 fallo"
[ "$out" = "avisos: 3 atendidos, 1 descartados" ] || fail "(q) atender t20 no conto el descarte de la gestionada: $out"
[ "$(json_leer "$CORRIDA_STATE/t20/avisos/tratados/t20-g-ab-fin-turno-viejo.json" descartado)" = "la sesion g-ab es gestionada: la reporta su host" ] \
  || fail "(q) el pendiente viejo de g-ab no quedo descartado con su motivo"
[ "$(grep -c '^reconciliar t20$' "$CCLOG")" -eq 1 ] || fail "(q) reconciliar debio llamarse una vez: $(cat "$CCLOG")"
registro_q t21
mkdir -p "$(avisos_dir t21)"
printf '{"schema":"corrida-aviso.v1","sesion":"g-h","tipo":"cierre"}\n' >"$(avisos_dir t21)/t21-g-h-cierre-viejo.json"
out=$(CORRIDA_BIN="$CC" bash "$CORR_ABS" avisos atender t21) || fail "(q) atender t21 fallo"
[ "$out" = "avisos: 0 atendidos, 1 descartados" ] || fail "(q) con solo la gestionada atender debio descartarla: $out"
grep -q '^reconciliar t21$' "$CCLOG" && fail "(q) el descarte de una gestionada corrio reconciliar"
[ -e "$CORRIDA_STATE/t21/eventos.jsonl" ] && grep -q 'avisos-atendidos' "$CORRIDA_STATE/t21/eventos.jsonl" \
  && fail "(q) el descarte de una gestionada anoto avisos-atendidos"
# Pendiente viejo de una gestionada con solo encargo_ref: tambien se descarta.
registro_q t22
mkdir -p "$(avisos_dir t22)"
printf '{"schema":"corrida-aviso.v1","sesion":"g-r","tipo":"cierre"}\n' >"$(avisos_dir t22)/t22-g-r-cierre-viejo.json"
: >"$CCLOG"
out=$(CORRIDA_BIN="$CC" bash "$CORR_ABS" avisos atender t22) || fail "(q) atender t22 fallo"
[ "$out" = "avisos: 0 atendidos, 1 descartados" ] || fail "(q) un pendiente viejo de g-r (solo encargo_ref) debio descartarse: $out"
grep -q '^reconciliar t22$' "$CCLOG" && fail "(q) el pendiente viejo de g-r corrio reconciliar"
# La guarda va antes del dedupe: con un pendiente viejo del mismo id, sigue saliendo 3.
registro_q t23
mkdir -p "$(avisos_dir t23)"
h=$(printf '%s' q-dup | shasum -a 1 | cut -c1-10)
printf '{"schema":"corrida-aviso.v1","sesion":"g-ab","tipo":"fin-turno"}\n' >"$(avisos_dir t23)/t23-g-ab-fin-turno-$h.json"
: >"$TECLAS"
emitir t23 g-ab fin-turno --llave q-dup 2>"$T/err-q"; rc=$?
[ "$rc" -eq 3 ] || fail "(q) con un pendiente del mismo id, emitir sobre g-ab debio salir 3 (rc=$rc)"
grep -q 'send-keys' "$TECLAS" && fail "(q) con un pendiente del mismo id, emitir sobre g-ab desperto al lead"
# La pertenencia es por nombre exacto: g-a no es gestionada aunque g-ab si.
mkdir -p "$CORRIDA_STATE/t24"
R_DIR="$CORRIDA_STATE/t24" python3 - <<'PY'
import json, os
b = {'rol': 'carril', 'cli': 'glm', 'dueno': 'lead', 'dir': '/tmp'}
ses = [dict(b, nombre='lead-main', rol='lead', cli='zcode'), dict(b, nombre='g-a'),
       dict(b, nombre='g-ab', host_id='mac-local', encargo_ref='/host/inbox/ab.json')]
json.dump({'id': 't24', 'estado': 'abierta', 'sesiones': ses}, open(os.path.join(os.environ['R_DIR'], 'registro.json'), 'w'))
PY
mkdir -p "$(avisos_dir t24)"
printf '{"schema":"corrida-aviso.v1","sesion":"g-a","tipo":"cierre"}\n' >"$(avisos_dir t24)/t24-g-a-cierre-viejo.json"
out=$(CORRIDA_BIN="$CC" bash "$CORR_ABS" avisos atender t24) || fail "(q) atender t24 fallo"
[ "$out" = "avisos: 1 atendidos, 0 descartados" ] || fail "(q) g-a no es gestionada (g-ab si): su pendiente debio atenderse: $out"
# despertar no despierta al lead por un pendiente viejo de una gestionada, y si por uno valido.
registro_q t31
mkdir -p "$(avisos_dir t31)"
printf '{"schema":"corrida-aviso.v1","sesion":"g-h","tipo":"cierre"}\n' >"$(avisos_dir t31)/t31-g-h-cierre-viejo.json"
: >"$TECLAS"
bash "$CORR_ABS" avisos despertar t31 || fail "(q) despertar t31 fallo"
grep -q 'send-keys' "$TECLAS" && fail "(q) despertar desperto al lead por un pendiente de una gestionada: $(cat "$TECLAS")"
printf '{"schema":"corrida-aviso.v1","sesion":"p-e","tipo":"cierre"}\n' >"$(avisos_dir t31)/t31-p-e-cierre-viejo.json"
bash "$CORR_ABS" avisos despertar t31 || fail "(q) despertar t31 con un valido fallo"
grep -q 'send-keys -t =lead-main: -l -- corrida.sh avisos atender t31' "$TECLAS" \
  || fail "(q) despertar no desperto al lead por el pendiente valido de p-e: $(cat "$TECLAS")"
echo "ok (q): una gestionada no emite (rc 3, sin aviso ni teclas) y su pendiente viejo se descarta; claves vacias, null y encargo plano, como siempre"

echo "TODO VERDE: test-corrida-avisos (U1 + U3 hook)"
