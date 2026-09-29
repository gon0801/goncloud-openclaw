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

# (c) Sesion ajena, corrida cerrada y corrida inexistente: rc 1, motivo, sin escribir.
emitir t1 ses-fantasma fin-turno --llave k 2>"$T/err-c1" && fail "(c) la sesion ajena debio fallar"
grep -q . "$T/err-c1" || fail "(c) el rechazo de la sesion ajena no da motivo"
registro t2 cerrada lead-main:lead:zcode,ses-c2:carril:glm
emitir t2 ses-c2 fin-turno --llave k 2>/dev/null && fail "(c) la corrida cerrada debio fallar"
[ "$(n_pend t2)" -eq 0 ] || fail "(c) la corrida cerrada dejo un aviso escrito"
emitir t-inexistente ses-c1 fin-turno --llave k 2>/dev/null && fail "(c) la corrida inexistente debio fallar"
echo "ok (c): sesion ajena, corrida cerrada e inexistente caen con rc 1 y sin escritura"

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

echo "TODO VERDE: test-corrida-avisos (U1)"
