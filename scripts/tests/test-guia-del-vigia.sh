#!/bin/bash
# Candado de docs/runbooks/guia-del-vigia.md (Fase 9, 9.7): lo que el vigia hace
# ante cada evento. La lee Hermes por SSH (`cat`), asi que es Markdown plano,
# sin HTML. Verifica: (1) existe y no trae marcas HTML; (2) trae una fila por
# cada evento que emite el vigilante, cruzada contra el texto literal de
# scripts/mac/tmux-activity-watch.sh; (3) idem con el Stop hook de Claude Code
# (scripts/mac/claude-stop-openclaw-event.sh); (4) trae la fila del parte del
# latido, cruzada contra docs/spec/seguimiento.v1.md (el latido de M aun no
# esta en main: lo que existe es el contrato que sus mensajes cumplen).
# "Cruzada" vale en los dos sentidos: si el codigo cambia su texto, este test
# falla del lado del codigo y avisa que guia y test quedaron viejos; si la guia
# no nombra un evento que el codigo si emite, falla del lado de la guia.
# Uso: bash scripts/tests/test-guia-del-vigia.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

GUIA=docs/runbooks/guia-del-vigia.md
W=scripts/mac/tmux-activity-watch.sh
H=scripts/mac/claude-stop-openclaw-event.sh
SEG=docs/spec/seguimiento.v1.md

# (1) Existe, y es Markdown plano: ninguna marca HTML. Hermes la lee con `cat`
# por SSH; un <details> o un <br> ahi sale como texto crudo.
[ -f "$GUIA" ] || fail "falta $GUIA"
html=$(grep -n -i -E '<(br|div|span|p|table|details|summary|img|ul|ol|li|h1|h2|h3|h4|h5|h6)[ />]|<a[ />]' "$GUIA" || true)
[ -z "$html" ] || fail "$GUIA trae marcas HTML (Hermes la lee con cat por SSH):
$html"
echo "ok (1): la guia existe y es Markdown plano, sin HTML"

# Fragmento canonico -> archivo de codigo donde vive. Cada fragmento se exige
# en el codigo (si el codigo lo pierde, el test avisa) y en la guia (una fila
# por evento: sin fila, el vigia improvisa).
cruzada() { # $1 fragmento, $2 codigo, $3 que es, $4 accion obligatoria
  grep -qF -- "$1" "$2" || fail "$2 ya no trae '$1': el codigo cambio y la guia ($GUIA) quedo vieja"
  awk -v evento="$1" -v accion="$4" '
    /^\|/ {
      fila = $0
      gsub(/\\\|/, "|", fila)
      if (index(fila, evento) && index(fila, accion)) encontrada = 1
    }
    END { exit encontrada ? 0 : 1 }
  ' "$GUIA" || fail "$GUIA: la fila del evento '$3' no trae su accion '$4'"
}

# (2) Los tres eventos del vigilante, con su texto literal del codigo.
cruzada 'waiting for approval for ' "$W" 'waiting for approval' 'preaprobaciones del registro'
cruzada 'quiet for ' "$W" 'quiet' 'ATORADO sin reporte'
cruzada 'closed | last cwd=' "$W" 'closed' 'relanza una vez'
grep -qF 'closed \| last cwd=' "$GUIA" \
  || fail "$GUIA: la barra de 'closed | last cwd=' rompe la tabla Markdown si no esta escapada"
echo "ok (2): la guia trae una fila por cada evento del vigilante (waiting, quiet, closed)"

# (3) El Stop hook de Claude Code.
cruzada 'turn ended in ' "$H" 'turn ended' 'Reanuda la espera'
echo "ok (3): la guia trae la fila del fin de turno de Claude Code"

# (4) El parte del latido: M aun no esta en main, asi que la fila se cruza
# contra el contrato que esos mensajes cumplen (las cuatro etiquetas cerradas).
for e in AVANZA DETENIDA 'NECESITO TU RESPUESTA' CERRADA; do
  cruzada "$e" "$SEG" "etiqueta $e del parte" 'Lenguaje de usuario'
done
echo "ok (4): la guia trae la fila del parte, con las cuatro etiquetas de seguimiento.v1"

echo "TODO VERDE: guia-del-vigia"
