#!/bin/bash
# Task 4: mostrar-terminal abre Terminal sobre la sesion tmux del carril;
# si la automatizacion se niega, visibilidad degraded con el attach exacto
# y el worker sigue activo (nunca es fallo del worker).
# Uso: bash scripts/tests/test-corrida-terminal-visible.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CORR=scripts/mac/corrida.sh
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export CORRIDA_STATE="$T/corridas"

mkdir -p "$T/bin" "$T/corridas/run-1"
# Dobles de osascript: ok anota su argv; negado simula la negativa de macOS.
cat >"$T/bin/osascript-ok" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$T/argv-ok.txt"
exit 0
STUB
cat >"$T/bin/osascript-no" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$T/argv-no.txt"
echo "osascript: no se permite la automatizacion" >&2
exit 1
STUB
chmod +x "$T/bin/osascript-ok" "$T/bin/osascript-no"

escribe_registro() {
  python3 - "$T/corridas/run-1/registro.json" <<'PY' || fail "no se escribio el registro"
import json,sys
d={"schema":"corrida.v2","id":"run-1",
   "carriles":{"lane-1":{"branch":"corrida/run-1/lane-1","worktree":"/tmp/wt-9",
   "base_remote_sha":"abc","owner":"lane-1","mode":"write","estado":"activo",
   "worker":"codex","session":"ses-codex-run1"}}}
open(sys.argv[1],'w').write(json.dumps(d)+"\n")
PY
}

# Exito: visible y el attach exacto guardado.
escribe_registro
got="$(OSASCRIPT_BIN="$T/bin/osascript-ok" bash "$CORR" mostrar-terminal run-1 lane-1)" \
  || fail "mostrar-terminal ok fallo"
[ "$got" = "visible" ] || fail "mostrar-terminal ok dio $got"
python3 - "$T/corridas/run-1/registro.json" <<'PY' || fail "visibilidad visible mal guardada"
import json,sys
v=json.load(open(sys.argv[1]))['carriles']['lane-1']['visibility']
assert v['state']=='visible', v
assert v['attach_command']=='/opt/homebrew/bin/tmux attach -t =ses-codex-run1', v
PY
# La sesion validada viaja como unico argv: -e, programa fijo, sesion. El
# programa no trae la sesion interpolada (ni briefs ni rutas del registro).
[ "$(head -n1 "$T/argv-ok.txt")" = "-e" ] || fail "osascript ok sin -e primero"
[ "$(tail -n1 "$T/argv-ok.txt")" = "ses-codex-run1" ] || fail "la sesion no es el unico argv final"
[ "$(grep -cx "ses-codex-run1" "$T/argv-ok.txt")" -eq 1 ] \
  || fail "la sesion aparece fuera de su argv (interpolada)"
grep -q "attach -t =" "$T/argv-ok.txt" || fail "el programa no trae el attach fijo"

# Negacion: degraded con el attach exacto, worker activo, rc 0.
escribe_registro
got="$(OSASCRIPT_BIN="$T/bin/osascript-no" bash "$CORR" mostrar-terminal run-1 lane-1 2>/dev/null)" \
  || fail "la negacion debio salir 0 (degraded, no fallo)"
[ "$got" = "degraded" ] || fail "la negacion dio $got"
python3 - "$T/corridas/run-1/registro.json" <<'PY' || fail "degraded mal guardado o worker tocado"
import json,sys
c=json.load(open(sys.argv[1]))['carriles']['lane-1']
assert c['visibility']['state']=='degraded', c
assert c['visibility']['attach_command']=='/opt/homebrew/bin/tmux attach -t =ses-codex-run1', c
assert c['estado']=='activo', c
PY

# Sesion invalida: se rechaza antes de invocar osascript.
python3 - "$T/corridas/run-1/registro.json" <<'PY' || fail "no se escribio sesion mala"
import json,sys
d={"schema":"corrida.v2","id":"run-1","carriles":{"lane-1":{"mode":"write","session":"ses;mala"}}}
open(sys.argv[1],'w').write(json.dumps(d)+"\n")
PY
rm -f "$T/argv-ok.txt"
OSASCRIPT_BIN="$T/bin/osascript-ok" bash "$CORR" mostrar-terminal run-1 lane-1 >/dev/null 2>&1 \
  && fail "sesion invalida aceptada"
[ ! -e "$T/argv-ok.txt" ] || fail "la sesion invalida llego a osascript"

# Sin sesion persistida: error cerrado, sin visibilidad inventada.
python3 - "$T/corridas/run-1/registro.json" <<'PY' || fail "no se escribio sin sesion"
import json,sys
d={"schema":"corrida.v2","id":"run-1","carriles":{"lane-1":{"mode":"write"}}}
open(sys.argv[1],'w').write(json.dumps(d)+"\n")
PY
OSASCRIPT_BIN="$T/bin/osascript-ok" bash "$CORR" mostrar-terminal run-1 lane-1 >/dev/null 2>&1 \
  && fail "sin sesion debio fallar"
python3 - "$T/corridas/run-1/registro.json" <<'PY' || fail "sin sesion se invento visibilidad"
import json,sys
c=json.load(open(sys.argv[1]))['carriles']['lane-1']
assert 'visibility' not in c, c
PY

echo "TODO VERDE: test-corrida-terminal-visible"
