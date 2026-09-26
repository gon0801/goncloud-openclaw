#!/bin/bash
# Ronda 7 F2: adaptador_start exige reserva (5 campos + estado reservado) y
# adaptador_registrar_sesion rechaza carril ya activo en vez de sobrescribir
# la sesion viva. Sin tmux real: doble que niega sesiones y anota new-session.
# Uso: bash scripts/tests/test-adaptador-reserva.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/corridas/run-1" "$T/wt" "$T/bin"
export CORRIDA_STATE="$T/corridas"

# Doble tmux: ninguna sesion existe; todo new-session queda en la bitacora.
cat >"$T/bin/tmux-falso" <<'TMSTUB'
#!/bin/sh
if [ "${1:-}" = "has-session" ]; then exit 1; fi
printf '%s\n' "TMUX $*" >> "$TMUX_LOG"
exit 0
TMSTUB
chmod +x "$T/bin/tmux-falso"
export TMUX_BIN="$T/bin/tmux-falso" TMUX_LOG="$T/tmux.log"
: > "$T/tmux.log"

# Binario falso para el worker codex (resolver lo exige tras la reserva).
printf '#!/bin/sh\nexit 0\n' > "$T/bin/codex-falso"
chmod +x "$T/bin/codex-falso"
export CORRIDA_WORKER_BIN_CODEX="$T/bin/codex-falso"

. scripts/mac/corrida/lib.sh
. scripts/mac/corrida/adaptador.sh

REG="$T/corridas/run-1/registro.json"
# Llamada en proceso con salida a archivo (nunca en $(...): el dispatcher
# EXIT del lock re-evalua el trap heredado dentro del subshell y borraria $T).
llama() { # $1 archivo-salida; resto: funcion + args; deja rc en LLAMA_RC y salida en el archivo
  local sal="$1"; shift
  "$@" >"$sal" 2>&1; LLAMA_RC=$?
}


reserva_completa() {
  python3 - "$REG" <<'PYE' || fail "no se escribio reserva completa"
import json,sys
d={"schema":"corrida.v2","id":"run-1",
   "lanes":[{"id":"lane-1","branch":"corrida/run-1/lane-1","worktree":"/tmp/wt-f2",
   "base_remote_sha":"0"*40,"owner":"lane-1","mode":"write","role":"write",
   "estado":"reservado","token":"9-f2"}]}
open(sys.argv[1],"w").write(json.dumps(d)+"\n")
PYE
}

# (1) start sobre carril SIN reserva completa: rechazo antes de crear sesion.
python3 - "$REG" "$T/wt" <<'PYE' || fail "no se escribio registro incompleto"
import json,sys
d={"schema":"corrida.v2","id":"run-1",
   "lanes":[{"id":"lane-1","mode":"write","worktree":sys.argv[2]}]}
open(sys.argv[1],"w").write(json.dumps(d)+"\n")
PYE
llama "$T/sal1.txt" adaptador_start run-1 lane-1 codex ses-nueva "$T/wt"
[ "$LLAMA_RC" -ne 0 ] || fail "start sin reserva debio fallar (salio: $(cat "$T/sal1.txt"))"
out="$(cat "$T/sal1.txt")"
printf '%s' "$out" | grep -q "no esta preparado" \
  || fail "start sin reserva no diagnostica reserva: $out"
grep -q "new-session" "$T/tmux.log" \
  && fail "start sin reserva creo sesion antes de validar"
echo "ok (1): start sin reserva se rechaza sin crear sesion"

# (2) start sobre carril ACTIVO (con sesion viva): rechazo por no reservado.
python3 - "$REG" <<'PYE' || fail "no se escribio carril activo"
import json,sys
d=json.load(open(sys.argv[1]))
d["lanes"]=[{"id":"lane-1","branch":"corrida/run-1/lane-1","worktree":"/tmp/wt-f2",
 "base_remote_sha":"0"*40,"owner":"lane-1","mode":"write","role":"write","estado":"activo",
 "worker":"codex","session":"ses-vieja"}]
json.dump(d,open(sys.argv[1],"w"),indent=1)
PYE
llama "$T/sal2.txt" adaptador_start run-1 lane-1 codex ses-otra "$T/wt"
[ "$LLAMA_RC" -ne 0 ] || fail "start sobre activo debio fallar (salio: $(cat "$T/sal2.txt"))"
out="$(cat "$T/sal2.txt")"
printf '%s' "$out" | grep -q "no esta reservado" \
  || fail "start sobre activo no diagnostica estado: $out"
echo "ok (2): start sobre carril activo se rechaza"

# (3) registrar sobre carril ACTIVO: rechaza y conserva la sesion viva.
llama "$T/sal3.txt" adaptador_registrar_sesion "$REG" lane-1 codex ses-nueva
[ "$LLAMA_RC" -ne 0 ] || fail "registrar sobre activo debio fallar"
out="$(cat "$T/sal3.txt")"
printf '%s' "$out" | grep -q "ya esta activo" \
  || fail "registrar sobre activo no diagnostica sesion viva: $out"
python3 - "$REG" <<'PYE' || fail "registrar sobre activo toco la sesion viva"
import json,sys
c=next((e for e in json.load(open(sys.argv[1]))["lanes"] if e.get("id")=="lane-1"), None)
assert c["session"]=="ses-vieja", c
assert c["estado"]=="activo", c
PYE
echo "ok (3): registrar no sobrescribe la sesion viva"

# (4) registrar sobre RESERVADO: camino feliz, pasa a activo con la sesion.
reserva_completa
adaptador_registrar_sesion "$REG" lane-1 codex ses-nueva \
  || fail "registrar sobre reservado fallo"
python3 - "$REG" <<'PYE' || fail "registrar sobre reservado no activo la sesion"
import json,sys
c=next((e for e in json.load(open(sys.argv[1]))["lanes"] if e.get("id")=="lane-1"), None)
assert c["session"]=="ses-nueva", c
assert c["estado"]=="activo", c
assert c["worker"]=="codex", c
PYE
echo "ok (4): registrar sobre reservado activa la sesion"

echo "TODO VERDE: test-adaptador-reserva"
