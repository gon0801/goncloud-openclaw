#!/usr/bin/env bash
# Prueba scripts/lanzar-lead.sh con un tmux real en un socket privado.
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
TM=${TMUX_REAL:-/opt/homebrew/bin/tmux}
[ -x "$TM" ] || { echo "ok: sin tmux en $TM, prueba saltada (declarado)"; exit 0; }
T=$(mktemp -d) || exit 1
L="ll-$$"
TMUX_BIN="$T/tmux"; printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$TM" "$L" > "$TMUX_BIN"; chmod +x "$TMUX_BIN"
export TMUX_BIN
limpia() { "$TM" -L "$L" kill-server 2>/dev/null; rm -rf "$T"; }
trap limpia EXIT
CWD="$T/wt"; mkdir -p "$CWD"
# Los registros de corrida de esta prueba viven en $T, nunca en el estado real.
export CORRIDA_STATE="$T/corridas"; mkdir -p "$CORRIDA_STATE"

# 1. cwd inexistente → 1
out=$(bash scripts/lanzar-lead.sh -s s1 -c "$T/no-existe" -m 'hola -saikit' -- cat 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'ATORADO cwd inexistente' || fail "(1) cwd inexistente: rc=$rc $out"
echo "ok (1): cwd inexistente aborta con 1"

# 2. lanzamiento real: un CLI falso que imprime su prompt y hace eco de lo que recibe
CLI="$T/cli.sh"; printf '#!/bin/sh\nprintf "FAKE> "\nexec cat\n' > "$CLI"; chmod +x "$CLI"
out=$(bash scripts/lanzar-lead.sh -s s1 -c "$CWD" -m 'Lee el runbook y ejecuta la fase -saikit' -p 'FAKE>' -t 15 -- "$CLI" --flag-falso 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "(2) lanzamiento: rc=$rc $out"
printf '%s\n' "$out" | tail -1 | grep -qE "^LISTO s1 " || fail "(2) sin LISTO final: $out"
printf '%s\n' "$out" | grep -q 'marca=OPENCLAW_WATCH=1' || fail "(2) la sesión no quedó marcada: $out"
printf '%s\n' "$out" | grep -q -- '--flag-falso' || fail "(2) el flag no aparece en la línea del proceso: $out"
real=$("$TMUX_BIN" display-message -p -t s1 '#{pane_current_path}')
[ "$(cd "$real" && pwd -P)" = "$(cd "$CWD" && pwd -P)" ] || fail "(2) cwd del proceso: $real"
"$TMUX_BIN" capture-pane -p -t s1 | grep -q 'ejecuta la fase -saikit' || fail "(2) el mensaje no llegó a la pantalla"
echo "ok (2): crea la sesión en el cwd, la marca, espera el prompt y el mensaje entra con su sentinel"

# 3. relanzar con la sesión viva → 2, sin tocarla
out=$(bash scripts/lanzar-lead.sh -s s1 -c "$CWD" -m 'otra -saikit' -- "$CLI" 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'YA-EXISTE s1' || fail "(3) sesión viva: rc=$rc $out"
echo "ok (3): con la sesión viva no relanza (YA-EXISTE, rc 2)"

# 4. prompt que nunca llega → 4 (el CLI falso no imprime nada)
CLI2="$T/mudo.sh"; printf '#!/bin/sh\nexec cat\n' > "$CLI2"; chmod +x "$CLI2"
out=$(bash scripts/lanzar-lead.sh -s s2 -c "$CWD" -m 'x -saikit' -p 'NUNCA>' -t 3 -- "$CLI2" 2>&1); rc=$?
[ "$rc" -eq 4 ] && printf '%s\n' "$out" | grep -q 'ATORADO sin prompt' || fail "(4) sin prompt: rc=$rc $out"
echo "ok (4): sin prompt no manda nada y sale con 4"

# 5. T9 :266: lanzar-lead no relanza una sesion gestionada (encargo_ref o host_id en una
# corrida abierta): la relanza su host. Filas: las dos claves, solo host_id, solo
# encargo_ref, claves vacias con encargo plano, gestionada de una corrida cerrada, un
# registro ilegible de otra corrida y un registro que no se puede recorrer.
reg() { # $1 corrida $2 estado $3 sesion $4 json extra de la entrada
  mkdir -p "$CORRIDA_STATE/$1"
  printf '{"id": "%s", "estado": "%s", "sesiones": [{"nombre": "%s", "rol": "lead", "cli": "glm", "dir": "/tmp"%s}]}\n' \
    "$1" "$2" "$3" "$4" >"$CORRIDA_STATE/$1/registro.json"
}
mkdir -p "$CORRIDA_STATE/r-roto"
printf '{no es json' >"$CORRIDA_STATE/r-roto/registro.json"
for fila in "s5a r5a ambas" "s5h r5h host" "s5r r5r ref"; do
  set -- $fila
  case "$3" in
    ambas) reg "$2" abierta "$1" ', "host_id": "mac-local", "encargo_ref": "/host/inbox/x.json"' ;;
    host) reg "$2" abierta "$1" ', "host_id": "mac-local"' ;;
    ref) reg "$2" abierta "$1" ', "encargo_ref": "/host/inbox/x.json"' ;;
  esac
  out=$(bash scripts/lanzar-lead.sh -s "$1" -c "$CWD" -m 'x -saikit' -p 'FAKE>' -t 5 -- "$CLI" 2>&1); rc=$?
  [ "$rc" -eq 6 ] || fail "(5) gestionada $1 ($3): rc=$rc $out"
  [ "$(printf '%s\n' "$out" | tail -1)" = "ATORADO $1 es una sesion gestionada de la corrida $2 (T9 :266): la relanza su host, no lanzar-lead" ] \
    || fail "(5) gestionada $1 ($3): la ultima linea no es la del ATORADO: $out"
  "$TMUX_BIN" has-session -t "=$1" 2>/dev/null && fail "(5) gestionada $1 ($3): se creo la sesion"
done
reg r6 abierta s6 ', "host_id": "", "encargo_ref": "", "encargo": "/tmp/plano.txt"'
reg r7 cerrada s7 ', "host_id": "mac-local", "encargo_ref": "/host/inbox/x.json"'
for s in s6 s7; do
  out=$(bash scripts/lanzar-lead.sh -s "$s" -c "$CWD" -m 'ruta anterior -saikit' -p 'FAKE>' -t 15 -- "$CLI" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | tail -1 | grep -qE "^LISTO $s " \
    && printf '%s\n' "$out" | grep -qx 'marca=OPENCLAW_WATCH=1' \
    || fail "(5) $s no es gestionada y debia lanzarse marcada: rc=$rc $out"
done
reg r9 abierta s9 ''
printf '{"id": "r9b", "estado": "abierta", "sesiones": 5}\n' >"$CORRIDA_STATE/r9/registro.json"
out=$(bash scripts/lanzar-lead.sh -s s9 -c "$CWD" -m 'x -saikit' -p 'FAKE>' -t 5 -- "$CLI" 2>&1); rc=$?
[ "$rc" -eq 6 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "ATORADO no pude comprobar si s9 es una sesion gestionada" ] \
  || fail "(5) un registro que no se puede recorrer debia frenar el lanzamiento: rc=$rc $out"
"$TMUX_BIN" has-session -t "=s9" 2>/dev/null && fail "(5) con el registro sin recorrer se creo la sesion s9"
echo "ok (5): una sesion gestionada no se relanza (dos claves, una sola, cualquier corrida abierta); claves vacias, corrida cerrada o registro ilegible ajeno, como siempre; sin poder comprobar, no lanza"

# 5c. Filas que faltaban. Cada una con su propio CORRIDA_STATE, para que el
# registro r9 (sesiones: 5) de arriba no las frene.
regen() { # $1 state $2 corrida $3 json completo del registro
  mkdir -p "$1/$2"; printf '%s\n' "$3" >"$1/$2/registro.json"
}
lanza_ok() { # $1 sesion $2 etiqueta; resto: entorno para env
  local s="$1" et="$2"; shift 2
  out=$(env "$@" bash scripts/lanzar-lead.sh -s "$s" -c "$CWD" -m "ruta anterior $s -saikit" -p 'FAKE>' -t 15 -- "$CLI" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | tail -1 | grep -qE "^LISTO $s " \
    && printf '%s\n' "$out" | grep -qx 'marca=OPENCLAW_WATCH=1' \
    || fail "(5c) $et: $s debia lanzarse marcada: rc=$rc $out"
}
frena() { # $1 sesion $2 corrida esperada $3 etiqueta; resto: entorno para env
  local s="$1" c="$2" et="$3"; shift 3
  out=$(env "$@" bash scripts/lanzar-lead.sh -s "$s" -c "$CWD" -m 'x -saikit' -p 'FAKE>' -t 5 -- "$CLI" 2>&1); rc=$?
  [ "$rc" -eq 6 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "ATORADO $s es una sesion gestionada de la corrida $c (T9 :266): la relanza su host, no lanzar-lead" ] \
    || fail "(5c) $et: rc=$rc $out"
  "$TMUX_BIN" has-session -t "=$s" 2>/dev/null && fail "(5c) $et: se creo la sesion $s"
}
G=', "host_id": "mac-local", "encargo_ref": "/host/inbox/x.json"'
# (a) sin CORRIDA_STATE en el entorno: la guarda lee el default ~/.local/state/corridas
H="$T/home"; regen "$H/.local/state/corridas" r10 "{\"id\": \"r10\", \"estado\": \"abierta\", \"sesiones\": [{\"nombre\": \"s10\"$G}]}"
frena s10 r10 "sin CORRIDA_STATE la guarda no leyo el estado por defecto" -u CORRIDA_STATE HOME="$H"
# (b) el mismo nombre en dos corridas abiertas: una entrada plana antes no tapa a la gestionada
S="$T/c-dup"; regen "$S" r11a '{"id": "r11a", "estado": "abierta", "sesiones": [{"nombre": "s11", "encargo": "/tmp/plano.txt"}]}'
regen "$S" r11b "{\"id\": \"r11b\", \"estado\": \"abierta\", \"sesiones\": [{\"nombre\": \"s11\"$G}]}"
frena s11 r11b "nombre repetido en dos corridas abiertas: la primera entrada plana tapo a la gestionada" CORRIDA_STATE="$S"
# (c) <corrida> es el directorio del registro, no su campo id
S="$T/c-id"; regen "$S" r12 "{\"id\": \"otro-id\", \"estado\": \"abierta\", \"sesiones\": [{\"nombre\": \"s12\"$G}]}"
frena s12 r12 "la corrida del ATORADO no es el directorio del registro" CORRIDA_STATE="$S"
# (d) sin directorio de corridas: ruta anterior intacta
lanza_ok s13 "sin directorio de corridas" CORRIDA_STATE="$T/no-hay-corridas"
# (e) registro que no es objeto, entrada que no es objeto, claves null: se saltan
S="$T/c-raros"; regen "$S" r14a '[]'; regen "$S" r14b '{"id": "r14b", "estado": "abierta", "sesiones": ["s14", 7, null]}'
regen "$S" r14c '{"id": "r14c", "estado": "abierta", "sesiones": [{"nombre": "s14", "host_id": null, "encargo_ref": null}]}'
lanza_ok s14 "registro no-objeto, entradas no-objeto y claves null no son gestion" CORRIDA_STATE="$S"
echo "ok (5c): sin CORRIDA_STATE lee el default; nombre repetido entre corridas; la corrida es el directorio; sin corridas, registros raros y null lanzan"

echo "TODO VERDE: lanzar-lead"
