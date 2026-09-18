#!/usr/bin/env bash
# El sync del gateway no sube archivos grandes, y su guardia esta DONDE sirve.
#
# Por que existe. Medido el 2026-09-18: el snapshot de las 03:10 subio a la rama por
# defecto `tls/bin/lego.exe` (66 MB) y `tls/bin/lego.zip` (21 MB), que el gateway habia
# dejado ahi. Tumbo el CI tres corridas seguidas -- dos de ellas de PRs ajenos que solo
# heredaron el rojo -- y bloqueo el cierre de las Fases 6 y 7, que exigen la rama por
# defecto en verde. El sync corre en Windows y NO pasa por los candados del repo, asi
# que nada mas lo frenaba.
#
# Lo que este candado protege no es que la guardia exista, sino su POSICION: desestagear
# despues del commit no sirve de nada, y es el error facil de cometer al reordenar el
# script. Por eso el caso (3) fabrica esa version y exige que se detecte.
#
# El script es PowerShell y aqui no hay PowerShell: esta prueba es estructural, como
# `test-sync-pull-identity.sh`, que tambien afirma sobre la linea del .ps1.
#
# Uso: bash scripts/tests/test-sync-no-sube-binarios.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }

PS1FILE=scripts/sync-repos.ps1
[ -f "$PS1FILE" ] || fail "falta $PS1FILE"

linea_de() { grep -n -- "$1" "$2" | head -1 | cut -d: -f1; }

# (1) La guardia existe y desestagea en vez de borrar. Borrar el archivo del disco del
# gateway se llevaria la herramienta que renueva los certificados.
grep -q 'git restore --staged' "$PS1FILE" \
  || fail "(1) $PS1FILE no desestagea nada: un binario que aparezca vuelve a subirse"
grep -qE 'git (rm|clean)' "$PS1FILE" \
  && fail "(1) $PS1FILE borra archivos; la guardia desestagea, no borra: el gateway necesita los suyos en el disco"
echo "ok (1): la guardia desestagea y no borra"

# (2) Esta DESPUES del add y ANTES del commit. Fuera de esa ventana no hace nada.
n_add=$(linea_de 'git add -A' "$PS1FILE")
n_g=$(linea_de 'git restore --staged' "$PS1FILE")
n_commit=$(linea_de 'commit -m "auto: snapshot' "$PS1FILE")
[ -n "$n_add" ] && [ -n "$n_g" ] && [ -n "$n_commit" ] \
  || fail "(2) no encuentro las tres lineas: add=$n_add guardia=$n_g commit=$n_commit"
[ "$n_g" -gt "$n_add" ] \
  || fail "(2) la guardia (linea $n_g) va ANTES del add (linea $n_add): no hay nada estagiado que revisar"
[ "$n_g" -lt "$n_commit" ] \
  || fail "(2) la guardia (linea $n_g) va DESPUES del commit (linea $n_commit): el binario ya se subio"
echo "ok (2): la guardia va entre el add y el commit, que es la unica ventana util"

# (3) Discrimina: con la guardia movida despues del commit, el caso (2) tiene que morir.
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
awk -v g="$n_g" -v c="$n_commit" 'NR==g { guardado=$0; next } { print } NR==c { print guardado }' \
  "$PS1FILE" > "$T/movido.ps1"
n_g2=$(grep -n 'git restore --staged' "$T/movido.ps1" | head -1 | cut -d: -f1)
n_c2=$(grep -n 'commit -m "auto: snapshot' "$T/movido.ps1" | head -1 | cut -d: -f1)
[ -n "$n_g2" ] && [ -n "$n_c2" ] \
  || fail "(3) no pude fabricar la version movida; el caso (2) quedaria sin respaldo"
[ "$n_g2" -gt "$n_c2" ] \
  || fail "(3) la version fabricada no quedo con la guardia despues del commit (guardia=$n_g2 commit=$n_c2)"
echo "ok (3): con la guardia despues del commit, la comprobacion de (2) la detecta"

# (4) El tope es un numero y esta declarado, no escondido en la condicion.
grep -qE '\$MAX_MB *= *[0-9]+' "$PS1FILE" \
  || fail "(4) el tope tiene que ser una variable con su numero, para poder cambiarlo sin tocar la logica"
echo "ok (4): el tope esta declarado como variable"

# (5) Queda rastro en el log. Un archivo que aparece y no se sube es justo lo que una
# persona tiene que ver; el vigia lee ese log.
grep -q 'GRANDE no se sube' "$PS1FILE" \
  || fail "(5) la guardia no deja linea en el log: un archivo saltado en silencio nadie lo revisa"
echo "ok (5): cada archivo saltado queda escrito en el log"

echo "TODO VERDE: sync-no-sube-binarios"
