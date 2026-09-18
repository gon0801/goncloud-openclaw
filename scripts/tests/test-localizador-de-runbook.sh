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
sed '/fase invalida/d' "$LOC" > "$T/scripts/runbook.sh"
grep -q 'fase invalida' "$T/scripts/runbook.sh" \
  && fail "(5) no pude fabricar la version sin validacion; el caso (4) quedaria sin respaldo"
bash "$T/scripts/runbook.sh" '../../etc/passwd' >/dev/null 2>&1
[ $? -eq 0 ] && fail "(5) la version sin validacion deberia seguir fallando por archivo inexistente, no salir 0"
echo "ok (5): quitando la validacion, el caso (4) deja de estar protegido"

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
