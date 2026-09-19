#!/bin/bash
# 9.4 corrida.sh estado: el parte, sin modelo. Los seis escenarios de la fila van
# byte a byte contra fixtures (todo avanza, carril detenido en dialogo, carril
# callado 30 min, carril LISTO sin recoger, lead muerto, corrida cerrada); sin gh
# dice "GitHub: sin verificar", no inventa; panel con secuencias de control o
# 5 000 caracteres sale truncado y limpio. Estado no envia nada: tmux y gh son de
# mentira y ningun openclaw corre. Uso: bash scripts/tests/test-corrida-estado.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
CORR=scripts/mac/corrida.sh
[ -x "$CORR" ] || fail "falta $CORR"
FX=scripts/tests/fixtures/estado
[ -d "$FX" ] || fail "faltan los fixtures de estado"

T=$(mktemp -d) || exit 1
mkdir -p "$T/bin" "$T/corridas" "$T/watch" "$T/paneles"
export CORRIDA_STATE="$T/corridas" WATCH_STATE_DIR="$T/watch" PANEL_DIR="$T/paneles"
# Reloj inyectado: 2026-09-19T13:02:00Z; los registros nacen a las 12:00:00Z.
export CORR_AHORA=1789822920

# tmux de mentira: la sesion existe si tiene panel; capture-pane lo imprime.
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
# gh de mentira: por defecto caido (GitHub: sin verificar); GH_ABIERTAS=n lista n.
cat >"$T/bin/gh-falso" <<'STUB'
#!/bin/sh
[ "${GH_FALLA:-1}" = "1" ] && exit 1
n="${GH_ABIERTAS:-0}"; i=0; sep=""
printf '['
while [ "$i" -lt "$n" ]; do printf '%s{"number": %s}' "$sep" "$((80 + i))"; sep=,; i=$((i+1)); done
printf ']\n'
STUB
chmod +x "$T/bin/tmux-falso" "$T/bin/gh-falso"
export TMUX_BIN="$T/bin/tmux-falso" GH_BIN="$T/bin/gh-falso"

montar() { # $1 escenario; imprime "id paneles watch" con directorios propios
  local id
  id="$(FX="$FX/$1" python3 -c "
import json,os
print(json.load(open(os.path.join(os.environ['FX'],'registro.json')))['id'])")"
  mkdir -p "$CORRIDA_STATE/$id" "$T/paneles-$1" "$T/watch-$1"
  cp "$FX/$1/registro.json" "$FX/$1/progress.json" "$CORRIDA_STATE/$id/"
  cp "$FX/$1"/watch/*.state "$T/watch-$1/" 2>/dev/null
  cp "$FX/$1"/paneles/*.txt "$T/paneles-$1/" 2>/dev/null
  printf '%s %s %s' "$id" "$T/paneles-$1" "$T/watch-$1"
}

# (1) los seis escenarios, byte a byte; y el mensaje (lineas 1-4) pasa seguimiento.v1.
for esc in avanza dialogo callado listo leadmuerto cerrada; do
  read -r id pan wat <<EOF
$(montar "$esc")
EOF
  PANEL_DIR="$pan" WATCH_STATE_DIR="$wat" bash "$CORR" estado "$id" >"$T/$esc.out" 2>"$T/$esc.err" \
    || fail "estado fallo en $esc: $(cat "$T/$esc.err")"
  cmp -s "$T/$esc.out" "$FX/$esc/esperado.txt" \
    || fail "el parte de $esc no es el esperado byte a byte:
$(diff "$FX/$esc/esperado.txt" "$T/$esc.out" | head -8)"
  sed -n '1,4p' "$T/$esc.out" >"$T/$esc.msg"
  ( . scripts/mac/corrida/lib.sh && mensaje_valido "$T/$esc.msg" ) \
    || fail "el mensaje de $esc no pasa seguimiento.v1"
done

# (2) --solo-mensaje: exactamente las cuatro lineas del mensaje.
PANEL_DIR="$T/paneles-avanza" WATCH_STATE_DIR="$T/watch-avanza" \
  bash "$CORR" estado m-avanza --solo-mensaje >"$T/solo.out" 2>/dev/null \
  || fail "--solo-mensaje fallo"
[ "$(awk 'END{print NR}' "$T/solo.out")" = "4" ] || fail "--solo-mensaje no da cuatro lineas"
cmp -s "$T/solo.out" "$T/avanza.msg" || fail "--solo-mensaje no es el mensaje del parte"

# (3) rechazos: id invalido, corrida sin registro, registro fuera de contrato.
bash "$CORR" estado '../fuga' >/dev/null 2>&1 && fail "estado acepto un id con ../"
bash "$CORR" estado inexistente >/dev/null 2>&1 && fail "estado acepto un id sin registro"
mkdir -p "$CORRIDA_STATE/roto"
printf '{"schema": "otra-cosa"}\n' >"$CORRIDA_STATE/roto/registro.json"
out="$(bash "$CORR" estado roto 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "estado acepto un registro fuera de contrato"
printf '%s' "$out" | grep -q "contrato" || fail "el rechazo del registro roto no lo dice"

# (4) gh vivo: una y varias propuestas; y el detalle dice lo mismo que el mensaje.
out="$(GH_FALLA=0 GH_ABIERTAS=1 PANEL_DIR="$T/paneles-avanza" WATCH_STATE_DIR="$T/watch-avanza" bash "$CORR" estado m-avanza)" \
  || fail "estado fallo con gh listando una propuesta"
printf '%s' "$out" | grep -q "GitHub: una propuesta abierta" || fail "con una propuesta no se dice en palabras"
out="$(GH_FALLA=0 GH_ABIERTAS=2 PANEL_DIR="$T/paneles-avanza" WATCH_STATE_DIR="$T/watch-avanza" bash "$CORR" estado m-avanza)" \
  || fail "estado fallo con gh listando dos propuestas"
printf '%s' "$out" | grep -q "GitHub: 2 propuestas abiertas" || fail "con dos propuestas no se cuenta"
printf '%s' "$out" | tail -1 | grep -q "GitHub: 2 propuestas abiertas" || fail "el detalle no trae el recuento"

# (5) panel sucio: secuencias de control y una linea de 6 000 caracteres.
python3 - "$T/paneles-avanza/m-a.txt" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    f.write("carril A \x1b[31mpintando\x1b[0m\r\nlargo: " + "x" * 6000 + "\n\x1b[2Kfinal\x07\n")
PY
PANEL_DIR="$T/paneles-avanza" WATCH_STATE_DIR="$T/watch-avanza" \
  bash "$CORR" estado m-avanza >"$T/sucio.out" 2>/dev/null || fail "el panel sucio rompio estado"
LC_ALL=C grep -q "$(printf '\033')" "$T/sucio.out" && fail "el panel salio con secuencias de escape"
LC_ALL=C grep -q "$(printf '\r')" "$T/sucio.out" && fail "el panel salio con retornos de carro"
grep -q "panel recortado" "$T/sucio.out" || fail "el panel largo no sale recortado"
larga="$(LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m }' "$T/sucio.out")"
[ "$larga" -le 5002 ] || fail "una linea del detalle mide $larga (tope 5 000)"

# (6) determinismo: con reloj inyectado, dos corridas dan los mismos bytes.
PANEL_DIR="$T/paneles-avanza" WATCH_STATE_DIR="$T/watch-avanza" \
  bash "$CORR" estado m-avanza >"$T/d1.out" 2>/dev/null || fail "estado fallo (d1)"
PANEL_DIR="$T/paneles-avanza" WATCH_STATE_DIR="$T/watch-avanza" \
  bash "$CORR" estado m-avanza >"$T/d2.out" 2>/dev/null || fail "estado fallo (d2)"
cmp -s "$T/d1.out" "$T/d2.out" || fail "estado no es determinista con el reloj inyectado"

echo "TODO VERDE: test-corrida-estado"
