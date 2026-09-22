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
# Se ancla en la ASIGNACION ejecutable, no en el texto `git add -A`: ese texto aparece
# antes en un comentario, y anclando ahi la guardia podia colarse entre el comentario y
# el comando real sin que esta prueba lo notara. Hallazgo de CodeRabbit, 2026-09-18.
n_add=$(linea_de '\$addOut = git add -A' "$PS1FILE")
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

# (3b) La guardia colada ENTRE el comentario y el comando real. Es el agujero que
# dejaba anclar en el texto `git add -A`: ahi no hay nada estagiado todavia, asi que la
# guardia no haria nada, y la prueba vieja pasaba igual. Hallazgo de CodeRabbit.
# awk en una pasada no sirve aqui: la guardia va DESPUES del add, asi que al llegar a
# la linea donde hay que insertarla todavia no se ha leido. Se hace en dos pasos.
python3 - "$PS1FILE" "$n_g" "$n_add" "$T/colada.ps1" <<'PY'
import sys
ruta, g, a, destino = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
ls = open(ruta, encoding="utf-8").read().split("\n")
guardia = ls[g - 1]
del ls[g - 1]                      # quitarla de su sitio
ls.insert(a - 1, guardia)          # y colarla justo antes del comando real
open(destino, "w", encoding="utf-8").write("\n".join(ls))
PY
n_g3=$(grep -n 'git restore --staged' "$T/colada.ps1" | head -1 | cut -d: -f1)
n_a3=$(grep -n '\$addOut = git add -A' "$T/colada.ps1" | head -1 | cut -d: -f1)
[ -n "$n_g3" ] && [ -n "$n_a3" ] \
  || fail "(3b) no pude fabricar la version colada; el caso (2) quedaria sin respaldo por ese lado"
[ "$n_g3" -lt "$n_a3" ] \
  || fail "(3b) la version fabricada no quedo con la guardia antes del add (guardia=$n_g3 add=$n_a3)"
echo "ok (3b): una guardia colada antes del comando real tambien queda fuera de la ventana util"

# (4) El tope es un numero y esta declarado, no escondido en la condicion.
grep -qE '\$MAX_MB *= *[0-9]+' "$PS1FILE" \
  || fail "(4) el tope tiene que ser una variable con su numero, para poder cambiarlo sin tocar la logica"
echo "ok (4): el tope esta declarado como variable"

# (5) Queda rastro en el log. Un archivo que aparece y no se sube es justo lo que una
# persona tiene que ver; el vigia lee ese log.
grep -q 'GRANDE no se sube' "$PS1FILE" \
  || fail "(5) la guardia no deja linea en el log: un archivo saltado en silencio nadie lo revisa"
echo "ok (5): cada archivo saltado queda escrito en el log"

# (6) Un ciclo que no commitea nada tiene que dejar rastro. El arreglo del indice
# (PR 80) hacia que el commit se saltara en silencio cuando la guardia vaciaba lo
# estagiado: antes eso se veia como un FALLO de commit, ruido pero VISIBLE. Cambiar
# ruido por silencio habria dejado un repo que deja de subir sin que nadie lo note.
# Hallazgo de kimi en la revision cruzada, 2026-09-18.
grep -q 'NADA estagiado' "$PS1FILE" \
  || fail "(6) sin esa linea, un ciclo que no commitea nada no deja rastro en el log"
grep -q 'rc_diff -eq 1' "$PS1FILE" \
  || fail "(6) el codigo de git tiene que distinguirse: un 128 por indice corrupto no es 'hay trabajo'"
grep -q 'rc_diff -gt 1' "$PS1FILE" \
  || fail "(6) un fallo de git al leer el indice tiene que declararse, no confundirse con trabajo"
echo "ok (6): un ciclo sin nada que commitear deja rastro, y un fallo de git no pasa por trabajo"

# (7) Reorientacion Fase 16: add/guardia/commit viven en el camino de
# workspaces; el camino main delega y no toca git add/commit.
grep -q '# >>> workspace-sync' "$PS1FILE" || fail "(7) sin marcas workspace-sync"
grep -q '# <<< workspace-sync' "$PS1FILE" || fail "(7) sin cierre workspace-sync"
n_w0=$(linea_de '# >>> workspace-sync' "$PS1FILE")
n_w1=$(linea_de '# <<< workspace-sync' "$PS1FILE")
for par in "$n_add/add" "$n_g/guardia" "$n_commit/commit"; do
  n=${par%%/*}; nombre=${par##*/}
  [ "$n" -gt "$n_w0" ] && [ "$n" -lt "$n_w1" ] \
    || fail "(7) $nombre (linea $n) fuera del camino workspace ($n_w0-$n_w1)"
done
T7=$(mktemp -d) || exit 1
trap 'rm -rf "$T" "$T7"' EXIT
python3 - "$PS1FILE" "$T7/main.ps1" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
a = next(i for i, l in enumerate(lines) if "# >>> main-delegate" in l)
b = next(i for i, l in enumerate(lines) if "# <<< main-delegate" in l)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines[a + 1:b]))
PY
grep -Eq 'git (add|commit)' "$T7/main.ps1" \
  && fail "(7) el camino main trae git add/commit: el orquestador es dueno de src/"
echo "ok (7): add/guardia/commit en workspaces; main delega sin add/commit"

echo "TODO VERDE: sync-no-sube-binarios"
