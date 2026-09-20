#!/usr/bin/env bash
# `scripts/runbook.sh` contesta donde esta el runbook de una fase, y NO contesta de mas.
#
# Por que existe. Medido el 2026-09-18, arrancando la Fase 9: los implementadores no
# encontraban su runbook. Se les dio un enlace de GitHub y el repo es privado; la ruta
# que traian los documentos era la de otra maquina. El archivo estaba en su sitio todo
# el tiempo en las dos maquinas.
#
# Lo que este candado protege no es que el comando exista, sino sus tres propiedades:
#   (a) que falle RUIDOSO y con stdout vacio cuando no hay runbook -- si imprimiera una
#       ruta inexistente, `cd $(runbook.sh 9)` mandaria a alguien a la nada;
#   (b) que la fase sea una clave cerrada -- con `..` o `/` el comando imprimiria la
#       ruta de otro archivo del disco;
#   (c) que la ruta sea absoluta y del clon donde se corre -- es lo unico que hace que
#       la respuesta sirva igual en la Mac, en el gateway y en una maquina nueva.
#
# Uso: bash scripts/tests/test-localizador-de-runbook.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }

LOC=scripts/runbook.sh
[ -f "$LOC" ] || fail "falta $LOC: sin el, cada documento vuelve a fijar una ruta a mano"

# (1) Una fase que existe: ruta absoluta, que apunta a un archivo real, y codigo 0.
ruta=$(bash "$LOC" 9); rc=$?
[ "$rc" -eq 0 ] || fail "(1) la fase 9 tiene runbook y el comando salio $rc"
case "$ruta" in
  /*) : ;;
  *) fail "(1) la ruta tiene que ser absoluta para servir desde cualquier directorio: $ruta" ;;
esac
[ -f "$ruta" ] || fail "(1) el comando imprimio una ruta que no existe: $ruta"
echo "ok (1): una fase con runbook devuelve su ruta absoluta y real"

# (2) La ruta es la del clon donde se corre, no una fija de otra maquina. Es la
# propiedad que hace que la respuesta sirva en el gateway Windows y en una maquina nueva.
aqui=$(pwd -P)
case "$ruta" in
  "$aqui"/*) : ;;
  *) fail "(2) la ruta no cuelga de este clon ($aqui): $ruta" ;;
esac
echo "ok (2): la ruta sale del clon donde se corre, no de una maquina concreta"

# (3) Una fase sin runbook: codigo distinto de 0, razon en stderr y stdout VACIO.
# Lo del stdout vacio es el punto: `cd $(runbook.sh 42)` no debe llevar a ningun lado.
salida=$(bash "$LOC" 42 2>/dev/null); rc=$?
[ "$rc" -ne 0 ] || fail "(3) una fase sin runbook no puede salir 0"
[ -z "$salida" ] || fail "(3) con la fase sin runbook, stdout tiene que quedar vacio y trajo: $salida"
err=$(bash "$LOC" 42 2>&1 >/dev/null)
printf '%s' "$err" | grep -q '42' || fail "(3) el error tiene que nombrar la fase pedida: $err"
printf '%s' "$err" | grep -q '9' || fail "(3) el error tiene que listar las fases que SI estan, para no dejar a nadie adivinando: $err"
echo "ok (3): una fase sin runbook falla ruidoso, con stdout vacio y diciendo cuales si estan"

# (4) La fase es clave cerrada. Sin esto el comando imprime la ruta de otro archivo.
for malo in '../../etc/passwd' '9/../../..' 'a9' '' '.' '..' '9;ls'; do
  salida=$(bash "$LOC" "$malo" 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "(4) la fase '$malo' deberia rechazarse y salio 0"
  [ -z "$salida" ] || fail "(4) la fase '$malo' imprimio algo en stdout: $salida"
done
echo "ok (4): una fase con barras, puntos o letras se rechaza, y sin imprimir nada"

# (5) Discrimina: el caso (4) tiene que morir si alguien quita la validacion. Se prueba
# sobre una COPIA, nunca sobre el archivo del repo.
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/docs/runbooks"
touch "$T/docs/runbooks/autopilot-fase9.md"
# El original rechaza por la VALIDACION y lo dice.
err_ok=$(bash "$LOC" '../../etc/passwd' 2>&1 >/dev/null)
printf '%s' "$err_ok" | grep -q 'fase invalida' \
  || fail "(5) el original tiene que rechazar por la validacion y decirlo; dijo: $err_ok"

# La copia sin validacion tambien falla, pero por OTRA razon. Medir solo el codigo de
# salida aceptaba las dos y no detectaba nada: hay que medir la razon.
python3 - "$LOC" "$T/scripts/runbook.sh" <<'PY'
import re, sys
origen, destino = sys.argv[1], sys.argv[2]
s = open(origen, encoding="utf-8").read()
# El bloque entero, no solo su mensaje: borrar la linea suelta deja un `if` sin cuerpo
# y bash ni siquiera parsea el archivo.
s2 = re.sub(r"\nif ! printf '%s' \"\$FASE\".*?\nfi\n", "\n", s, count=1, flags=re.S)
assert s2 != s, "no pude quitar el bloque de validacion"
open(destino, "w", encoding="utf-8").write(s2)
PY
bash -n "$T/scripts/runbook.sh" \
  || fail "(5) la copia mutada no es bash valido: la asercion de abajo pasaria por no parsear, no por comportamiento"
grep -q 'fase invalida' "$T/scripts/runbook.sh" \
  && fail "(5) no pude fabricar la version sin validacion; el caso (4) quedaria sin respaldo"
err_malo=$(bash "$T/scripts/runbook.sh" '../../etc/passwd' 2>&1 >/dev/null)
printf '%s' "$err_malo" | grep -q 'fase invalida' \
  && fail "(5) la copia mutada NO deberia poder decir 'fase invalida': la mutacion no la quito"
echo "ok (5): el original rechaza por la validacion y la copia mutada no puede, que es lo que hace util al caso (4)"

# (5b) La gramatica es cerrada, no "digitos y punto": `.9`, `9.` y `9..1` no son claves
# de nada y antes pasaban el filtro. Hallazgo de CodeRabbit, 2026-09-18.
for malo in '.9' '9.' '9..1' '1234' '9.1234'; do
  salida=$(bash "$LOC" "$malo" 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "(5b) la fase '$malo' no tiene forma de clave y salio 0"
  [ -z "$salida" ] || fail "(5b) la fase '$malo' imprimio algo en stdout: $salida"
done
echo "ok (5b): la gramatica cerrada rechaza punto suelto, punto final, punto doble y mas de tres digitos"

# (5c) El mensaje de una fase que no existe no puede sugerir una fase imposible. Antes
# listaba con su propio filtro y colaba `8-hallazgos`. Hallazgo de CodeRabbit.
#
# PRECONDICION: hace falta que exista al menos un `autopilot-fase*.md` cuyo sufijo NO
# sea clave de fase. Si un dia nadie lo tiene, (5c) y (6) quedarian verdes sin probar
# nada, porque el grep no podria fallar sobre una lista que ya no lo contiene. Se
# comprueba en vez de suponerse. Hallazgo de kimi, 2026-09-18.
vecinos=0
for f in docs/runbooks/autopilot-fase*.md; do
  [ -f "$f" ] || continue
  n=$(basename "$f" .md); n=${n#autopilot-fase}
  printf '%s' "$n" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3})?$' || vecinos=$((vecinos + 1))
done
[ "$vecinos" -gt 0 ] \
  || fail "(5c) no hay ningun documento vecino que no sea runbook de fase: sin el, este caso y el (6) pasan sin probar nada"

err=$(bash "$LOC" 42 2>&1 >/dev/null)
printf '%s' "$err" | grep -q 'hallazgos' \
  && fail "(5c) el error sugiere '8-hallazgos', que no es una fase: manda a probar algo imposible
$err"

echo "ok (5c): el error de una fase inexistente no sugiere ninguna que no lo sea"

# (6) `--lista` nombra cada fase con runbook, y solo esas. `autopilot-fase8-hallazgos.md`
# existe y NO es el runbook de una fase: si colara, alguien pediria la fase "8-hallazgos".
lista=$(bash "$LOC" --lista); rc=$?
[ "$rc" -eq 0 ] || fail "(6) --lista salio $rc"
printf '%s' "$lista" | grep -qE '^9[[:space:]]' || fail "(6) --lista no nombra la fase 9:
$lista"
printf '%s' "$lista" | grep -q 'hallazgos' && fail "(6) --lista cuela un archivo que no es runbook de fase:
$lista"
echo "ok (6): --lista nombra las fases con runbook y no cuela los documentos vecinos"

# (7) Toda fase con filas en Plans.md tiene runbook localizable. Es el candado que hace
# que la proxima fase no arranque con el mismo problema de hoy.
faltan=""
for f in $(grep -oE '^## Fase [0-9]+' Plans.md 2>/dev/null | awk '{print $3}' | sort -u); do
  bash "$LOC" "$f" >/dev/null 2>&1 || faltan="$faltan $f"
done
if [ -n "$faltan" ]; then
  echo "AVISO: fases del plan sin runbook localizable:$faltan"
  echo "       (no bloquea: una fase puede estar planeada y sin runbook todavia)"
else
  echo "ok (7): toda fase del plan tiene runbook localizable"
fi

echo "TODO VERDE: localizador-de-runbook"
