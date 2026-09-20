#!/bin/bash
# Las marcas de vigilancia tienen dueño. Terminar una sesión registrada la desmarca
# sin tocar sus compañeras; reconciliar retira solo marcas de corridas cerradas y
# conserva tanto las corridas abiertas como las sesiones desconocidas.
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CORR="$PWD/scripts/mac/corrida.sh"
INSTALA="$PWD/docs/runbooks/autopilot-fase9.md"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/abierta" "$T/state/cerrada" "$T/bin"

cat >"$T/state/abierta/registro.json" <<'JSON'
{
  "schema": "corrida.v1",
  "id": "abierta",
  "estado": "abierta",
  "sesiones": [
    {"nombre": "ses-activa", "rol": "carril", "cli": "codex", "dueno": "lead", "dir": "/tmp/activa"},
    {"nombre": "ses-lista", "rol": "carril", "cli": "claude", "dueno": "lead", "dir": "/tmp/lista"},
    {"nombre": "ses-prestada", "rol": "carril", "cli": "claude", "dueno": "lead", "dir": "/tmp/prestada"}
  ]
}
JSON
cat >"$T/state/cerrada/registro.json" <<'JSON'
{
  "schema": "corrida.v1",
  "id": "cerrada",
  "estado": "cerrada",
  "sesiones": [
    {"nombre": "ses-vieja", "rol": "carril", "cli": "grok", "dueno": "lead", "dir": "/tmp/vieja"},
    {"nombre": "ses-activa", "rol": "carril", "cli": "grok", "dueno": "lead", "dir": "/tmp/activa-vieja"},
    {"nombre": "ses-reusada", "rol": "carril", "cli": "grok", "dueno": "lead", "dir": "/tmp/reusada-vieja"}
  ]
}
JSON

printf '%s\n' ses-activa ses-lista ses-prestada ses-vieja ses-desconocida ses-reusada >"$T/sesiones"
cp "$T/sesiones" "$T/marcadas"
printf '%s\t%s\n' \
  ses-activa abierta \
  ses-lista abierta \
  ses-prestada otra \
  ses-vieja cerrada \
  ses-reusada abierta >"$T/duenos"
TMUX_LOG="$T/tmux.log"
cat >"$T/bin/tmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUX_LOG"
case "$1" in
  list-sessions) cat "$TMUX_SESIONES" ;;
  has-session)
    ses=""
    while [ $# -gt 0 ]; do
      [ "$1" = "-t" ] && { ses="${2#=}"; shift 2; continue; }
      shift
    done
    grep -qxF "$ses" "$TMUX_SESIONES" ;;
  new-session)
    ses=""
    while [ $# -gt 0 ]; do
      [ "$1" = "-s" ] && { ses="$2"; shift 2; continue; }
      shift
    done
    grep -qxF "$ses" "$TMUX_SESIONES" 2>/dev/null || printf '%s\n' "$ses" >>"$TMUX_SESIONES" ;;
  capture-pane) printf '%s\n' "${TMUX_BARRA:-READY}" ;;
  kill-session)
    ses=""
    while [ $# -gt 0 ]; do
      [ "$1" = "-t" ] && { ses="${2#=}"; shift 2; continue; }
      shift
    done
    grep -vxF "$ses" "$TMUX_SESIONES" >"$TMUX_SESIONES.tmp" || true
    mv "$TMUX_SESIONES.tmp" "$TMUX_SESIONES"
    grep -vxF "$ses" "$TMUX_MARCADAS" >"$TMUX_MARCADAS.tmp" || true
    mv "$TMUX_MARCADAS.tmp" "$TMUX_MARCADAS"
    awk -F '\t' -v s="$ses" '$1 != s' "$TMUX_DUENOS" >"$TMUX_DUENOS.tmp" || true
    mv "$TMUX_DUENOS.tmp" "$TMUX_DUENOS" ;;
  show-environment)
    ses="" var=""
    while [ $# -gt 0 ]; do
      [ "$1" = "-t" ] && { ses="${2#=}"; shift 2; continue; }
      var="$1"
      shift
    done
    if [ "$var" = "OPENCLAW_WATCH_RUN" ]; then
      run=$(awk -F '\t' -v s="$ses" '$1==s { print $2; exit }' "$TMUX_DUENOS")
      [ -n "$run" ] && { echo "OPENCLAW_WATCH_RUN=$run"; exit 0; }
      exit 1
    fi
    grep -qxF "$ses" "$TMUX_MARCADAS" && { echo OPENCLAW_WATCH=1; exit 0; }
    exit 1 ;;
  set-environment)
    ses="" quitar=false var="" valor=""
    shift
    while [ $# -gt 0 ]; do
      [ "$1" = "-t" ] && { ses="${2#=}"; shift 2; continue; }
      [ "$1" = "-u" ] && { quitar=true; var="$2"; shift 2; continue; }
      var="$1"; valor="${2:-}"; break
    done
    [ "${TMUX_FALLA_PARA:-}" = "$ses" ] && exit 1
    if [ "$quitar" = true ]; then
      if [ "${TMUX_RACE:-}" = "1" ] && [ "$ses" = "ses-race" ] && [ "$var" = "OPENCLAW_WATCH" ]; then
        grep -vxF "$ses" "$TMUX_SESIONES" >"$TMUX_SESIONES.tmp" || true
        mv "$TMUX_SESIONES.tmp" "$TMUX_SESIONES"
        : >"$TMUX_RACE_READY"
        i=0
        while [ ! -f "$TMUX_RACE_MARKED" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
      fi
      if [ "$var" = "OPENCLAW_WATCH" ]; then
        grep -vxF "$ses" "$TMUX_MARCADAS" >"$TMUX_MARCADAS.tmp" || true
        mv "$TMUX_MARCADAS.tmp" "$TMUX_MARCADAS"
      else
        awk -F '\t' -v s="$ses" '$1 != s' "$TMUX_DUENOS" >"$TMUX_DUENOS.tmp" || true
        mv "$TMUX_DUENOS.tmp" "$TMUX_DUENOS"
      fi
    elif [ "$var" = "OPENCLAW_WATCH" ]; then
      grep -qxF "$ses" "$TMUX_MARCADAS" 2>/dev/null || printf '%s\n' "$ses" >>"$TMUX_MARCADAS"
      [ "${TMUX_RACE:-}" = "1" ] && [ "$ses" = "ses-race" ] && : >"$TMUX_RACE_MARKED"
    else
      awk -F '\t' -v s="$ses" '$1 != s' "$TMUX_DUENOS" >"$TMUX_DUENOS.tmp" || true
      printf '%s\t%s\n' "$ses" "$valor" >>"$TMUX_DUENOS.tmp"
      mv "$TMUX_DUENOS.tmp" "$TMUX_DUENOS"
    fi ;;
  *) exit 2 ;;
esac
SH
chmod +x "$T/bin/tmux"

export CORRIDA_STATE="$T/state" TMUX_BIN="$T/bin/tmux" TMUX_LOG
export TMUX_SESIONES="$T/sesiones" TMUX_MARCADAS="$T/marcadas" TMUX_DUENOS="$T/duenos"
export TMUX_BARRA=READY

# El procedimiento que instala corrida.sh debe copiar los subcomandos que el
# runbook general manda usar. Una copia fija incompleta rompe solo en la Mac viva.
grep -Eq 'for f in .*terminar-sesion.*reconciliar-marcas' "$INSTALA" \
  || fail "la instalacion de corrida no incluye los subcomandos de marcas"

# Una sesión registrada puede finalizar sin afectar a las demás de la corrida.
bash "$CORR" terminar-sesion abierta ses-lista >/dev/null \
  || fail "terminar-sesion rechazo una sesion registrada"
grep -qxF ses-lista "$T/marcadas" && fail "terminar-sesion dejo la marca de ses-lista"
grep -qxF ses-activa "$T/marcadas" || fail "terminar-sesion desmarco la sesion activa vecina"

# Repetir converge al mismo estado.
bash "$CORR" terminar-sesion abierta ses-lista >/dev/null \
  || fail "terminar-sesion no es idempotente"

antes=$(wc -l <"$TMUX_LOG" | tr -d ' ')
bash "$CORR" terminar-sesion abierta ses-ajena >/dev/null 2>&1 \
  && fail "terminar-sesion acepto una sesion fuera del registro"
despues=$(wc -l <"$TMUX_LOG" | tr -d ' ')
[ "$antes" = "$despues" ] || fail "una sesion ajena llego a tmux"

# Si tmux no puede retirar la marca, el comando falla ruidosamente.
export TMUX_FALLA_PARA=ses-activa
bash "$CORR" terminar-sesion abierta ses-activa >/dev/null 2>&1 \
  && fail "terminar-sesion oculto el fallo de tmux"
grep -qxF ses-activa "$T/marcadas" || fail "el stub perdio la marca pese al fallo"
unset TMUX_FALLA_PARA

# La pertenencia historica al registro no autoriza a quitar la marca de otra
# corrida que reutilizo ese nombre.
bash "$CORR" terminar-sesion abierta ses-prestada >/dev/null \
  || fail "terminar-sesion fallo al conservar una sesion de otro dueño"
grep -qxF ses-prestada "$T/marcadas" \
  || fail "terminar-sesion retiro la marca de otra corrida"
grep -q $'^ses-prestada\totra$' "$T/duenos" \
  || fail "terminar-sesion retiro el dueño de otra corrida"

# Aunque la marca publique una corrida cerrada, cualquier registro abierto que
# aun reclame el nombre impide retirarla.
awk -F '\t' '$1 != "ses-activa"' "$T/duenos" >"$T/duenos.tmp"
printf '%s\t%s\n' ses-activa cerrada >>"$T/duenos.tmp"
mv "$T/duenos.tmp" "$T/duenos"

# La reconciliación solo conoce dueños registrados. Cerrada sale; abierta y
# desconocida sobreviven.
salida="$(bash "$CORR" reconciliar-marcas)" || fail "reconciliar-marcas fallo"
grep -qxF ses-vieja "$T/marcadas" && fail "quedo una marca de corrida cerrada"
grep -qxF ses-activa "$T/marcadas" || fail "reconciliar desmarco una corrida abierta"
grep -qxF ses-desconocida "$T/marcadas" || fail "reconciliar adivino sobre una sesion desconocida"
grep -qxF ses-reusada "$T/marcadas" \
  || fail "reconciliar desmarco una sesion nueva antes de que entrara al registro"
printf '%s\n' "$salida" | grep -qF 'marca conservada (abierta): ses-activa' \
  || fail "reconciliar no reporto la marca con dueña abierta"
printf '%s\n' "$salida" | grep -qF 'marca conservada (desconocida): ses-desconocida' \
  || fail "reconciliar no reporto la marca sin dueño conocido"

# Reproduce la carrera real: reconciliar decide sobre una sesion vieja cerrada;
# mientras va a desmarcarla, lanzar-sesion reutiliza el nombre. Sin un lock comun,
# el unset tardio cae sobre la sesion nueva y el vigilante deja de verla.
mkdir -p "$T/state/race-open" "$T/state/race-closed"
cat >"$T/modos.tsv" <<'TSV'
sh	sh		READY
TSV
cat >"$T/state/race-open/registro.json" <<JSON
{"id":"race-open","estado":"abierta","cli_modos":"$T/modos.tsv","sesiones":[]}
JSON
cat >"$T/state/race-closed/registro.json" <<'JSON'
{"id":"race-closed","estado":"cerrada","sesiones":[{"nombre":"ses-race"}]}
JSON
printf '%s\n' ses-race >"$T/sesiones"
printf '%s\n' ses-race >"$T/marcadas"
printf '%s\t%s\n' ses-race race-closed >"$T/duenos"
export TMUX_RACE=1 TMUX_RACE_READY="$T/race-ready" TMUX_RACE_MARKED="$T/race-marked"
bash "$CORR" reconciliar-marcas >"$T/race-recon.out" 2>&1 & recon_pid=$!
i=0
while [ ! -f "$TMUX_RACE_READY" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
[ -f "$TMUX_RACE_READY" ] || fail "la reproduccion no alcanzo la ventana de reconciliacion"
bash "$CORR" lanzar-sesion race-open carril sh "$T" --nombre ses-race >"$T/race-launch.out" 2>&1 & launch_pid=$!
wait "$recon_pid" || fail "reconciliar fallo durante la reproduccion concurrente"
wait "$launch_pid" || fail "lanzar-sesion fallo durante la reproduccion concurrente"
grep -qxF ses-race "$T/marcadas" \
  || fail "reconciliar retiro la marca de la sesion nueva con nombre reutilizado"
grep -q '"nombre": "ses-race"' "$T/state/race-open/registro.json" \
  || fail "lanzar-sesion no registro la sesion nueva"
linea_dueno=$(grep -nF 'set-environment -t =ses-race OPENCLAW_WATCH_RUN race-open' "$TMUX_LOG" | tail -1 | cut -d: -f1)
linea_marca=$(grep -nF 'set-environment -t =ses-race OPENCLAW_WATCH 1' "$TMUX_LOG" | tail -1 | cut -d: -f1)
[ -n "$linea_dueno" ] && [ -n "$linea_marca" ] && [ "$linea_dueno" -lt "$linea_marca" ] \
  || fail "lanzar-sesion no publico el dueño antes de hacer visible la marca"
unset TMUX_RACE TMUX_RACE_READY TMUX_RACE_MARKED

# Un lock viejo por reloj, pero cuyo PID sigue vivo, no se roba. El token debe
# permanecer byte-identico mientras un segundo proceso intenta tomarlo.
lock_state="$T/lock-state"
mkdir -p "$lock_state"
CORRIDA_STATE="$lock_state" CORR_LOCK_VIEJO=1 bash -c '
  . scripts/mac/corrida/lib.sh
  marcas_lock_tomar || exit 2
  printf "%s" "$MARCAS_LOCK_TOKEN" >"$CORRIDA_STATE/holder-token"
  sleep 8
' & holder_pid=$!
i=0
while [ ! -f "$lock_state/holder-token" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
[ -f "$lock_state/holder-token" ] || fail "el dueño no publico el token del lock"
sleep 2
CORRIDA_STATE="$lock_state" CORR_LOCK_VIEJO=1 bash -c '
  . scripts/mac/corrida/lib.sh
  marcas_lock_tomar
' >"$T/contender.out" 2>&1 & contender_pid=$!
sleep 1
token_antes=$(cat "$lock_state/holder-token")
token_despues=$(cat "$lock_state/.marcas.lock/token" 2>/dev/null || true)
[ "$token_despues" = "$token_antes" ] || fail "un lock activo fue robado solo por antigüedad"
kill "$contender_pid" 2>/dev/null || true
wait "$contender_pid" 2>/dev/null || true
wait "$holder_pid" || fail "el dueño vivo del lock fallo"

# El dispatcher EXIT limpia los dos locks anidados y conserva un trap ajeno.
exit_state="$T/exit-state"
mkdir -p "$exit_state/r1"
CORRIDA_STATE="$exit_state" FOREIGN_TRAP_FILE="$T/foreign-trap" bash -c '
  . scripts/mac/corrida/lib.sh
  trap '\''printf trap >>"$FOREIGN_TRAP_FILE"'\'' EXIT
  marcas_lock_tomar || exit 2
  lock_tomar "$CORRIDA_STATE/r1/registro.json" || exit 3
  kill -TERM $$
' >/dev/null 2>&1
[ "$?" -eq 143 ] || fail "el proceso de prueba no salio por TERM como se esperaba"
[ ! -d "$exit_state/.marcas.lock" ] || fail "EXIT dejo el lock global"
[ ! -d "$exit_state/r1/.lock" ] || fail "EXIT dejo el lock del registro"
[ "$(cat "$T/foreign-trap" 2>/dev/null)" = "trap" ] \
  || fail "el dispatcher no preservo exactamente una ejecucion del trap ajeno"

echo "VERDE: terminar-sesion y reconciliar-marcas conservan el dueño de cada marca"
