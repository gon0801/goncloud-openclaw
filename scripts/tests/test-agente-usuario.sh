#!/bin/bash
# Prueba del contrato del agente `usuario` (agents/usuario/agent/AGENTS.md) y de su
# validador de formato (scripts/validar-informe-usuario.sh).
#
# Nace de un caso real: el 2026-09-17 la Fase 7 construyo un tablero, paso sus
# pruebas, CI en verde, tres PR integrados -- y nadie lo abrio nunca. Quien
# construye algo ya sabe por donde funciona; el agente `usuario` prueba solo con
# la promesa en palabras y la ruta humana, nunca con el codigo del cambio.
#
# No hay un runtime de agente que invocar aqui: el contrato lo sigue un modelo en
# su turno. Lo que esta prueba puede comprobar mecanicamente son dos cosas: (1)
# el contrato sigue trayendo, por su texto, las clausulas que hacen que un lector
# no pueda leer el codigo ni arreglar nada -- si una mutacion se las quita, el
# caso (1) se pone rojo; (2) el validador de formato discrimina un informe que
# cumple el contrato de uno que lo rompe, incluido citar un diff plantado en su
# propio directorio.
#
# Uso: bash scripts/tests/test-agente-usuario.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

AGENTS=agents/usuario/agent/AGENTS.md
VALIDADOR=scripts/validar-informe-usuario.sh

[ -r "$AGENTS" ] || fail "falta el contrato: $AGENTS"
[ -x "$VALIDADOR" ] || fail "falta el validador o no es ejecutable: $VALIDADOR"
/bin/bash -n "$VALIDADOR" || fail "$VALIDADOR no parsea con /bin/bash"

# (1) Las anclas del contrato. Cada una es la mutacion que el DoD de la fila 9.11
# pide matar: "si el contrato deja de prohibir leer el codigo, ese caso se pone
# rojo". Se prueba grepeando el texto real, no una copia.
for a in 'No lee el código del cambio' \
         'Ni el diff, ni las pruebas, ni los PR' \
         'No puede arreglar nada' \
         'FUNCIONA <qué vio>' \
         'NO FUNCIONA <qué vio en su lugar>' \
         'NO PUDE PROBARLO <razón>' \
         'docs/evidence/usuario-<fase>-<AAAA-MM-DD>.md'; do
  grep -qF "$a" "$AGENTS" || fail "$AGENTS: falta la clausula del contrato: $a"
done
echo "ok (1): el contrato prohíbe leer el código y arreglar, y define las tres líneas"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# (2) Promesa cumplida: el informe con FUNCIONA y evidencia pasa el validador.
cat >"$T/funciona.txt" <<'EOF'
FUNCIONA la pantalla de estado mostró "Fase 9: 7 de 7 partes" a las 10:32
Ruta: abrí http://127.0.0.1:18789/runbook/tablero/9 en el navegador
EOF
bash "$VALIDADOR" "$T/funciona.txt" \
  || fail "(2) una promesa cumplida con FUNCIONA y evidencia debe pasar el validador"
echo "ok (2): promesa cumplida ⇒ FUNCIONA con evidencia pasa"

# (3) Promesa rota: el informe con NO FUNCIONA, nombrando lo que vio, también pasa
# el validador de formato -- reportar un fallo no es un informe invalido.
cat >"$T/no-funciona.txt" <<'EOF'
NO FUNCIONA la pantalla se quedó en blanco después de cargar 20 segundos
Ruta: abrí http://127.0.0.1:18789/runbook/tablero/9 en el navegador
EOF
bash "$VALIDADOR" "$T/no-funciona.txt" \
  || fail "(3) una promesa rota reportada con NO FUNCIONA debe pasar el validador de formato"
echo "ok (3): promesa rota ⇒ NO FUNCIONA nombrando lo que vio, no lo esperado"

# (4) Sin ruta de acceso: NO PUDE PROBARLO también es un informe valido.
cat >"$T/no-pude.txt" <<'EOF'
NO PUDE PROBARLO la promesa no dijo qué pantalla abrir ni qué comando correr
EOF
bash "$VALIDADOR" "$T/no-pude.txt" \
  || fail "(4) sin ruta de acceso, NO PUDE PROBARLO debe pasar el validador de formato"
echo "ok (4): sin ruta de acceso ⇒ NO PUDE PROBARLO"

# (5) Un informe que no arranca con una de las tres líneas es inválido, sea cual
# sea su contenido. Sin este caso, el validador podría aceptar cualquier texto.
cat >"$T/mal-formato.txt" <<'EOF'
Probé la fila y creo que más o menos funciona, aunque no estoy seguro.
EOF
bash "$VALIDADOR" "$T/mal-formato.txt" 2>/dev/null \
  && fail "(5) un informe que no usa una de las tres líneas debe rechazarse"
echo "ok (5): un informe fuera de las tres líneas del contrato se rechaza"

# (6) El caso central del DoD: se planta el diff del cambio en el directorio del
# agente, y su informe no puede citarlo. Un informe bueno no lo menciona; uno malo
# (el que citaria el codigo, como haria quien ya construyo el cambio) sí.
DIFF_DIR="$T/directorio-del-agente"
mkdir -p "$DIFF_DIR"
MARCADOR="linea-secreta-del-diff-fase9-usuario-xyz"
cat >"$DIFF_DIR/cambio.diff" <<EOF
--- a/scripts/cierre-de-fase.sh
+++ b/scripts/cierre-de-fase.sh
@@ marcador de prueba: $MARCADOR
EOF

cat >"$T/bueno-no-cita-diff.txt" <<'EOF'
FUNCIONA el reporte llegó a Telegram con el texto "Fase 9: 7 de 7"
Ruta: esperé el mensaje de la corrida en el chat de David
EOF
bash "$VALIDADOR" "$T/bueno-no-cita-diff.txt" "$MARCADOR" \
  || fail "(6a) un informe que no cita el diff no puede rechazarse por el patrón prohibido"

cat >"$T/malo-cita-diff.txt" <<EOF
FUNCIONA revisé scripts/cierre-de-fase.sh y vi que suma el check usuario ($MARCADOR)
EOF
bash "$VALIDADOR" "$T/malo-cita-diff.txt" "$MARCADOR" 2>/dev/null \
  && fail "(6b) un informe que cita el diff plantado en su directorio debe rechazarse"
echo "ok (6): un informe que cita el diff plantado en su directorio se rechaza; uno que no lo cita, pasa"

# (7) La mutación central del DoD, en la forma que este repo prueba mutaciones
# textuales: si el contrato dejara de prohibir leer el código, el caso (1) que
# grepea esa cláusula se pondría rojo por su cuenta -- no hay candado de código que
# lo impida, es el propio texto el candado. Se comprueba aquí forzando la ausencia
# sobre una copia y confirmando que el caso (1) discrimina.
COPIA_MUTADA="$T/AGENTS-mutado.md"
grep -v 'No lee el código del cambio' "$AGENTS" > "$COPIA_MUTADA"
grep -qF 'No lee el código del cambio' "$COPIA_MUTADA" \
  && fail "(7) la copia mutada debería haber perdido la cláusula, algo salió mal en el fixture"
echo "ok (7): quitar la cláusula que prohíbe leer el código deja la mutación detectable (caso (1) del contrato real la exige)"

# (8) Exactamente UNA línea de veredicto, no "la primera que calce". Un informe
# contradictorio (NO FUNCIONA y más abajo FUNCIONA) tiene que rechazarse: si el
# validador solo mirara la primera línea, este informe pasaría, y como
# cierre-de-fase.sh toma el veredicto MÁS RECIENTE de un bloque, terminaría
# contando como FUNCIONA. Hallazgo del lead, revisión del PR 150.
cat >"$T/contradictorio.txt" <<'EOF'
NO FUNCIONA la pantalla se quedó en blanco
FUNCIONA en realidad sí cargó, me equivoqué arriba
EOF
bash "$VALIDADOR" "$T/contradictorio.txt" 2>/dev/null \
  && fail "(8) un informe con dos líneas de veredicto contradictorias debe rechazarse"
echo "ok (8): un informe con más de una línea de veredicto se rechaza, aunque la primera sea válida"

# (9) Un patrón prohibido que empieza con "-" (como el encabezado de un diff real,
# "--- a/archivo") no puede tomarse como una opción de grep y colarse: el validador
# tiene que rechazar igual el informe que lo cita.
cat >"$T/cita-encabezado-diff.txt" <<'EOF'
FUNCIONA vi el cambio completo en --- a/scripts/cierre-de-fase.sh
EOF
bash "$VALIDADOR" "$T/cita-encabezado-diff.txt" "--- a/" 2>/dev/null \
  && fail "(9) un patrón prohibido que empieza con '-' debe rechazar igual el informe que lo cita, no tomarse como opción de grep"
echo "ok (9): un patrón prohibido que empieza con '-' se comprueba igual, sin confundirse con una opción de grep"

echo "TODO VERDE: agente usuario"
