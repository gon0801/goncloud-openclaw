#!/bin/bash
# T3 (discrimina #5): census v4c en gonserver. CORRER SOLO EN FASE B (post 13:35Z,
# fuera de ventanas de cron — el script lo verifica solo):
# el caso (b) deja temporales de root a proposito y los limpia al final; si se
# interrumpe a medias, re-correr la limpieza o los .cv2q* de root rompen al cron.
# Uso como root: ./t3_census.sh <v4b_path> <v4c_path> <D>
#   v4b = copia del script viejo (para el rojo), v4c = candidato, D = YYYY-MM-DD.
# Hace queries reales read-only (claw_ro) contra odoo-db-1.
# Exit 0 = todo PASS (incluye rojo-b reproducido); 1 = FAIL; 2 = precondicion.
set -u
[ "$(id -u)" -eq 0 ] || { echo "T3: correr como root"; exit 2; }
V4B="${1:?uso: t3_census.sh <v4b> <v4c> <D>}"; V4C="${2:?falta v4c}"; D="${3:?falta D}"
[ -f "$V4B" ] && [ -f "$V4C" ] || { echo "T3: falta v4b o v4c"; exit 2; }
now_min() { date -u +%H:%M | awk -F: '{print $1*60+$2}'; }
in_win() { # $1=HH:MM $2=HH:MM -> 0 si ahora dentro
  a=$(echo "$1" | awk -F: '{print $1*60+$2}'); b=$(echo "$2" | awk -F: '{print $1*60+$2}'); n=$(now_min)
  [ "$n" -ge "$a" ] && [ "$n" -lt "$b" ]
}
for w in "12:55 13:35" "13:40 14:05" "16:55 17:25" "01:55 02:25"; do
  # shellcheck disable=SC2086
  if in_win $w; then echo "T3 ABORTO: dentro de ventana cerrada ($w UTC)."; exit 2; fi
done
PASS=0; FAIL=0; REDB=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
BAK="$(mktemp -d /tmp/t3bak.XXXXXX)"; chown claw:claw "$BAK"
cleanup() { # borra .cv2q* creados por el test (cualquier dueno) y restaura previos
  rm -f /tmp/.cv2q1 /tmp/.cv2q2 /tmp/.cv2q3 /tmp/.cv2q2b 2>/dev/null
  for f in "$BAK"/.cv2q*; do [ -f "$f" ] && mv "$f" /tmp/; done
  rmdir "$BAK" 2>/dev/null
}
trap cleanup EXIT
# aparta .cv2q* existentes para un entorno controlado (se restauran al salir)
for f in /tmp/.cv2q1 /tmp/.cv2q2 /tmp/.cv2q3 /tmp/.cv2q2b; do
  [ -f "$f" ] && mv "$f" "$BAK"/
done
leftovers() { ls -d /tmp/cv2.* /tmp/.cv2q* 2>/dev/null | wc -l; }
sent5() { # $1=salida -> 0 si trae 4 Q-sentinels + CENSUS_V2_OK
  S=0
  for s in Q1_OK Q2_OK Q3_OK ALERTA_ML_FUERA_VENTANA CENSUS_V2_OK; do
    echo "$1" | grep -q "$s" && S=$((S+1))
  done
  [ "$S" -eq 5 ]
}

echo "### T3 caso c: v4c sin command-substitution"
C="$(grep -c '\$(' "$V4C" || true)"
[ "$C" -eq 0 ] && ok "grep -c '\$(' = 0" || bad "hay $C lineas con \$("

echo "### T3 caso d: pgpass con ':' (la linea awk real de v4c extrae password completo)"
AWKPROG="$(sed -n "s/.*\(awk -F: '[^']*'\).*/\1/p" "$V4C" | head -1)"
printf 'dbhost:5432:EHV:claw_ro:pa:ss:wo:rd\ndbhost:5432:EHV:claw_ro:simple\n' > "$BAK/pgtest"
GOT1="$(eval "$AWKPROG $BAK/pgtest" 2>/dev/null)"
printf 'dbhost:5432:EHV:claw_ro:simple\n' > "$BAK/pgtest2"
GOT2="$(eval "$AWKPROG $BAK/pgtest2" 2>/dev/null)"
[ -n "$AWKPROG" ] && [ "$GOT1" = 'pa:ss:wo:rd' ] && [ "$GOT2" = 'simple' ] \
  && ok "awk extrae password completo con y sin ':'" \
  || bad "awk=[$AWKPROG] got1=[$GOT1] got2=[$GOT2]"

echo "### T3 caso a: v4c como claw (5 sentinels+OK, exit 0, sin restos)"
OUT="$(runuser -u claw -- bash "$V4C" "$D" 2>&1)"; RC=$?
sent5 "$OUT" && [ "$RC" -eq 0 ] && [ "$(leftovers)" -eq 0 ] \
  && ok "5/5 exit 0, sin /tmp/cv2.* ni .cv2q*" \
  || bad "rc=$RC restos=$(leftovers) out=[$(echo "$OUT" | tail -c 300)]"

echo "### T3 caso b-ROJO: v4b root planta, luego claw (esperado: Permission denied)"
bash "$V4B" "$D" >/dev/null 2>&1; RCR=$?
PLANTED=0; ROOTOWN=0
for f in /tmp/.cv2q1 /tmp/.cv2q2 /tmp/.cv2q3 /tmp/.cv2q2b; do
  [ -f "$f" ] && PLANTED=$((PLANTED+1))
  [ -f "$f" ] && [ "$(stat -c %U "$f")" = root ] && ROOTOWN=$((ROOTOWN+1))
done
OUT="$(runuser -u claw -- bash "$V4B" "$D" 2>&1)"; RCC=$?
if [ "$RCR" -eq 0 ] && [ "$PLANTED" -ge 1 ] && [ "$ROOTOWN" -eq "$PLANTED" ] \
   && [ "$RCC" -ne 0 ] && echo "$OUT" | grep -q 'Permission denied'; then
  REDB=1; echo "ROJO-B OK: root planto $PLANTED archivos, claw fallo con Permission denied (rc=$RCC)"
else
  bad "rojo-b NO reproducido: root rc=$RCR plantados=$PLANTED/$ROOTOWN root, claw rc=$RCC out=[$(echo "$OUT" | tail -c 200)]"
fi
rm -f /tmp/.cv2q1 /tmp/.cv2q2 /tmp/.cv2q3 /tmp/.cv2q2b

echo "### T3 caso b-VERDE: v4c root una vez, luego claw (esperado: ambos OK)"
bash "$V4C" "$D" >/dev/null 2>&1; RCR=$?
OUT="$(runuser -u claw -- bash "$V4C" "$D" 2>&1)"; RCC=$?
sent5 "$OUT" && [ "$RCR" -eq 0 ] && [ "$RCC" -eq 0 ] && [ "$(leftovers)" -eq 0 ] \
  && ok "v4c root rc=0 + claw 5/5 rc=0, sin restos" \
  || bad "root rc=$RCR claw rc=$RCC restos=$(leftovers) out=[$(echo "$OUT" | tail -c 300)]"

echo "### T3 resultado: PASS=$PASS FAIL=$FAIL REDB=$REDB"
[ "$FAIL" -eq 0 ] && [ "$REDB" -eq 1 ]
