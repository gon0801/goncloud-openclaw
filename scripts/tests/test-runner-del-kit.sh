#!/usr/bin/env bash
# `tests/run.sh` existe y NO se traga el codigo de salida de la bateria.
#
# Por que existe. Medido el 2026-09-18, cerrando la Fase 7: este repo nunca corrio el
# paso que genera `tests/run.sh`, y sin ese archivo el arnes no acredita ninguna prueba
# de este repo como verificacion. El gate de integracion del kit exige esa acreditacion,
# asi que ningun PR podia integrarse por la ruta oficial aunque la bateria entera
# estuviera en verde. El dueno tuvo que integrar dos PRs a mano.
#
# El riesgo que este candado cubre no es que el archivo falte -- eso se ve enseguida --
# sino que un dia alguien lo "arregle" para que no moleste: un `|| true`, un `exit 0` al
# final, o un `bash ... ; exit 0`. Cualquiera de los tres convierte el envoltorio en un
# falso verde para TODO el repo, y encima uno invisible, porque el gate seguiria viendo
# su linea `verified:` y dandola por buena.
#
# Uso: bash scripts/tests/test-runner-del-kit.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }

RUNNER=tests/run.sh

# (1) Existe y es legible. El kit lo invoca con `bash`, asi que no se exige +x: pedir
# `test -x` daria un falso negativo con el archivo en 644, que es como vive en el repo.
[ -f "$RUNNER" ] || fail "falta $RUNNER: sin el, ninguna prueba de este repo cuenta como evidencia para integrar"
[ -r "$RUNNER" ] || fail "$RUNNER existe pero no se puede leer"
echo "ok (1): $RUNNER existe"

# (2) Delega en la bateria real, no reimplementa ni recorta. Si un dia alguien lo apunta
# a otra cosa, este candado lo dice en vez de dejar pasar una bateria distinta de la que
# corre el CI.
grep -q 'scripts/run-checks\.sh' "$RUNNER" \
  || fail "$RUNNER no invoca scripts/run-checks.sh: el runner del kit tiene que correr la bateria real del repo"
echo "ok (2): delega en scripts/run-checks.sh"

# (3) El caso que de verdad importa: el codigo de salida viaja. Se monta un arbol de
# juguete con el MISMO envoltorio y una bateria falsa que sale 3; el envoltorio tiene
# que salir 3 tambien. Sin este caso, un `|| true` agregado manana pasaria desapercibido.
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tests" "$T/scripts"
cp "$RUNNER" "$T/tests/run.sh"
cat > "$T/scripts/run-checks.sh" <<'STUB'
#!/usr/bin/env bash
echo "bateria de juguete: fallo a proposito"
exit 3
STUB
salida=$(bash "$T/tests/run.sh" 2>&1); rc=$?
[ "$rc" -eq 3 ] \
  || fail "(3) la bateria salio 3 y el envoltorio salio $rc: se esta tragando el codigo de salida, y eso es un falso verde para todo el repo
salida: $salida"
echo "ok (3): un fallo de la bateria llega intacto a quien invoca"

# (4) Discrimina: el caso (3) tiene que morir si el envoltorio se vuelve permisivo. Se
# prueba con una copia adulterada, nunca con el archivo del repo.
sed 's|^exec bash scripts/run-checks\.sh.*|bash scripts/run-checks.sh "$@" \|\| true|' "$RUNNER" > "$T/tests/run.sh"
grep -q '|| true' "$T/tests/run.sh" \
  || fail "(4) no pude fabricar la version permisiva; el caso (3) quedaria sin respaldo"
bash "$T/tests/run.sh" >/dev/null 2>&1; rc_malo=$?
[ "$rc_malo" -eq 0 ] \
  || fail "(4) la version permisiva deberia salir 0 y salio $rc_malo: el caso (3) no esta midiendo lo que dice"
echo "ok (4): con un '|| true' el envoltorio sale 0, que es justo lo que (3) impide"

# (5) Y el archivo del repo no tiene ninguna de las tres formas permisivas. Se miran
# SOLO las lineas de codigo: el propio envoltorio explica esas tres formas en su
# comentario, y grepear el archivo entero se marcaba a si mismo por la explicacion.
codigo=$(grep -vE '^[[:space:]]*#' "$RUNNER")
for forma in '|| true' '; exit 0' '&& exit 0'; do
  printf '%s' "$codigo" | grep -qF -- "$forma" \
    && fail "(5) $RUNNER contiene '$forma' en codigo: eso convierte el runner en un falso verde para todo el repo"
done
echo "ok (5): el runner del repo no trae ninguna forma permisiva en su codigo"

echo "TODO VERDE: runner-del-kit"
