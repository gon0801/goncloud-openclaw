#!/bin/bash
# T3 (discrimina #5): census v4c en gonserver. CORRER SOLO EN FASE B (post 13:35Z):
# el caso (b) deja temporales de root a proposito y los limpia al final; si se
# interrumpe a medias, re-correr la limpieza o los .cv2q* de root rompen al cron.
# Uso como root: ./t3_census.sh <v4b_path> <v4c_path> <D>
#   v4b = copia del script viejo (para el rojo), v4c = candidato, D = YYYY-MM-DD.
# Hace queries reales read-only (claw_ro) contra odoo-db-1.
# Exit 0 = todo PASS.
set -u
V4B="${1:?uso: t3_census.sh <v4b> <v4c> <D>}"; V4C="${2:?falta v4c}"; D="${3:?falta D}"
[ -f "$V4B" ] && [ -f "$V4C" ] || { echo "T3: falta v4b o v4c"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
BAK="$(mktemp -d /tmp/t3bak.XXXXXX)"; chown claw:claw "$BAK"
cleanup() { # restaura .cv2q* previos y limpia restos root del test
  for f in /tmp/.cv2q1 /tmp/.cv2q2 /tmp/.cv2q3 /tmp/.cv2q2b; do
    [ -f "$f" ] && [ "$(stat -c %U "$f")" = root ] && rm -f "$f"
  done
  for f in "$BAK"/.cv2q*; do [ -f "$f" ] && mv "$f" /tmp/; done
  rmdir "$BAK" 2>/dev/null
}
trap cleanup EXIT
# aparta .cv2q* existentes (de claw o root) para un entorno controlado
for f in /tmp/.cv2q1 /tmp/.cv2q2 /tmp/.cv2q3 /tmp/.cv2q2b; do
  [ -f "$f" ] && mv "$f" "$BAK"/
done

echo "### T3 caso c: v4c sin command-substitution"
C="$(grep -c '\$(' "$V4C" || true)"
[ "$C" = 0 ] && ok "grep -c '\$(' = 0" || bad "hay $C lineas con \$("

echo "### T3 caso a: v4c como claw (4 sentinels + CENSUS_V2_OK, sin restos)"
OUT="$(runuser -u claw -- bash "$V4C" "$D" 2>&1)"; RC=$?
S=0
for s in Q1_OK Q2_OK Q3_OK ALERTA_ML_FUERA_VENTANA CENSUS_V2_OK; do
  echo "$OUT" | grep -q "$s" && S=$((S+1))
done
LEFT="$(ls -d /tmp/cv2.* 2>/dev/null | wc -l)"
[ "$S" = 5 ] && [ "$RC" = 0 ] && [ "$LEFT" = 0 ] \
  && ok "5/5 sentinels+OK exit 0, /tmp/cv2.* vacio" \
  || bad "sent=$S/5 rc=$RC restos=$LEFT out=[$(echo "$OUT" | tail -c 300)]"

echo "### T3 caso b-ROJO: v4b root una vez, luego claw (esperado: FAIL)"
runuser -u claw -- true
bash "$V4B" "$D" >/dev/null 2>&1; RCR=$?
OUT="$(runuser -u claw -- bash "$V4B" "$D" 2>&1)"; RCC=$?
echo "$OUT" | grep -Eq 'Permission denied|CENSUS_V2_FAIL' && [ "$RCC" != 0 ] \
  && bad "ROJO reproducido: root rc=$RCR luego claw rc=$RCC falla" \
  || ok "v4b no fallo (inesperado; root rc=$RCR claw rc=$RCC)"
for f in /tmp/.cv2q1 /tmp/.cv2q2 /tmp/.cv2q3 /tmp/.cv2q2b; do
  [ -f "$f" ] && [ "$(stat -c %U "$f")" = root ] && rm -f "$f"
done

echo "### T3 caso b-VERDE: v4c root una vez, luego claw (esperado: OK)"
bash "$V4C" "$D" >/dev/null 2>&1; RCR=$?
OUT="$(runuser -u claw -- bash "$V4C" "$D" 2>&1)"; RCC=$?
LEFT="$(ls -d /tmp/cv2.* 2>/dev/null | wc -l)"
echo "$OUT" | grep -q CENSUS_V2_OK && [ "$RCC" = 0 ] && [ "$LEFT" = 0 ] \
  && ok "v4c root rc=$RCR + claw rc=0 OK, sin restos" \
  || bad "root rc=$RCR claw rc=$RCC restos=$LEFT out=[$(echo "$OUT" | tail -c 300)]"

echo "### T3 resultado: PASS=$PASS FAIL=$FAIL (el rojo-b cuenta como FAIL esperado)"
[ "$FAIL" = 1 ]  # solo el rojo-b debe fallar
