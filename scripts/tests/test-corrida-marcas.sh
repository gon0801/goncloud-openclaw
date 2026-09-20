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
    {"nombre": "ses-lista", "rol": "carril", "cli": "claude", "dueno": "lead", "dir": "/tmp/lista"}
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
    {"nombre": "ses-activa", "rol": "carril", "cli": "grok", "dueno": "lead", "dir": "/tmp/activa-vieja"}
  ]
}
JSON

printf '%s\n' ses-activa ses-lista ses-vieja ses-desconocida >"$T/sesiones"
cp "$T/sesiones" "$T/marcadas"
TMUX_LOG="$T/tmux.log"
cat >"$T/bin/tmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUX_LOG"
case "$1" in
  list-sessions) cat "$TMUX_SESIONES" ;;
  show-environment)
    ses=""
    while [ $# -gt 0 ]; do
      [ "$1" = "-t" ] && { ses="${2#=}"; shift 2; continue; }
      shift
    done
    grep -qxF "$ses" "$TMUX_MARCADAS" && { echo OPENCLAW_WATCH=1; exit 0; }
    exit 1 ;;
  set-environment)
    ses=""
    while [ $# -gt 0 ]; do
      [ "$1" = "-t" ] && { ses="${2#=}"; shift 2; continue; }
      shift
    done
    [ "${TMUX_FALLA_PARA:-}" = "$ses" ] && exit 1
    grep -vxF "$ses" "$TMUX_MARCADAS" >"$TMUX_MARCADAS.tmp" || true
    mv "$TMUX_MARCADAS.tmp" "$TMUX_MARCADAS" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$T/bin/tmux"

export CORRIDA_STATE="$T/state" TMUX_BIN="$T/bin/tmux" TMUX_LOG
export TMUX_SESIONES="$T/sesiones" TMUX_MARCADAS="$T/marcadas"

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

# La reconciliación solo conoce dueños registrados. Cerrada sale; abierta y
# desconocida sobreviven.
salida="$(bash "$CORR" reconciliar-marcas)" || fail "reconciliar-marcas fallo"
grep -qxF ses-vieja "$T/marcadas" && fail "quedo una marca de corrida cerrada"
grep -qxF ses-activa "$T/marcadas" || fail "reconciliar desmarco una corrida abierta"
grep -qxF ses-desconocida "$T/marcadas" || fail "reconciliar adivino sobre una sesion desconocida"
printf '%s\n' "$salida" | grep -qF 'marca conservada (abierta): ses-activa' \
  || fail "reconciliar no reporto la marca con dueña abierta"
printf '%s\n' "$salida" | grep -qF 'marca conservada (desconocida): ses-desconocida' \
  || fail "reconciliar no reporto la marca sin dueño conocido"

echo "VERDE: terminar-sesion y reconciliar-marcas conservan el dueño de cada marca"
