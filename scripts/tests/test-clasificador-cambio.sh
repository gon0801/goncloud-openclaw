#!/bin/bash
# 15.0 (Fase 15, carril S): fixtures del clasificador de carriles de CI.
#
# Contrato que este test afirma (Politica de seleccion aprobada, Plans.md):
#   1. Clasifica POR ARCHIVOS contra la allowlist versionada; nunca por
#      extension sola, titulo o etiqueta.
#   2. Carril fast: exclusivamente los documentos enumerados en la allowlist
#      (Plans.md + los formatos contratados de docs/evidence/** y
#      .saikit/progress/**). El cierre de la fase usa exactamente 4 paths.
#   3. Codigo, mezcla, documentos operativos (markdown que controla
#      comportamiento: agentes, skills, workflow) => completo.
#   4. Borrados cuentan; renombres consideran origen Y destino.
#   5. Fail-closed: base/head inresoluble, historias sin ancestor comun,
#      formato fuera de contrato, allowlist sin la ruta => completo, exit 0
#      (es una seleccion, no un error). Errores de uso/herramienta => exit 2
#      sin veredicto (el job muere rojo y el gate no autoriza omisiones).
#   6. Interfaz para el workflow: stdout es UNA linea (fast|completo) y
#      GITHUB_OUTPUT recibe carril=<...> y motivo=<...>.
#   7. Symlinks (120000), gitlinks (160000) y modos no regulares JAMAS fast,
#      aunque la ruta case con la allowlist: --name-status no muestra modos y
#      un symlink nuevo en arbol de docs se ve igual que un .md. La politica
#      nombra explicitamente symlinks en el carril completo.
#
# Uso: bash scripts/tests/test-clasificador-cambio.sh
set -u
cd "$(dirname "$0")/../.." || exit 1

# Mismo cuidado que scripts/run-checks.sh: un GIT_* exportado haria que los
# repos de juguete "escapen" al repo real.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX 2>/dev/null

RAIZ=$(pwd)
CLASIFICADOR=scripts/clasificar-cambio.sh
ALLOWLIST_REAL=scripts/ci-fast-allowlist.txt
ALLOWLIST=scripts/tests/fixtures/clasificador/allowlist.txt
ALLOWLIST_VACIA=scripts/tests/fixtures/clasificador/allowlist-vacia.txt

[ -f "$RAIZ/$CLASIFICADOR" ] || {
  echo "FAIL: falta $RAIZ/$CLASIFICADOR (este test es el rojo del TDD: implementalo)"
  exit 1
}
# Absolutas: el clasificador corre con cwd en cada repo de juguete.
ALLOWLIST_REAL=$RAIZ/$ALLOWLIST_REAL
ALLOWLIST=$RAIZ/$ALLOWLIST
ALLOWLIST_VACIA=$RAIZ/$ALLOWLIST_VACIA
for f in "$ALLOWLIST_REAL" "$ALLOWLIST" "$ALLOWLIST_VACIA"; do
  [ -f "$f" ] || { echo "FAIL: falta $f"; exit 1; }
done

# git hermetico: la config del usuario (diff.renames, quotepath, alias) no
# puede cambiar lo que el clasificador ve.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fails=0
ok()    { printf '  OK    %s\n' "$1"; }
falla() { printf '  FALLA %s\n' "$1"; fails=$((fails + 1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/test-clasificador.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/plano"

sembrar() { # $1: repo de juguete con la semilla y su commit base
  local d=$1
  mkdir -p "$d/docs/evidence" "$d/.saikit/progress" "$d/summa-gate" \
           "$d/agents/x" "$d/docs/agent-skills/s" "$d/scripts" "$d/.github/workflows"
  printf 'plan\n'             > "$d/Plans.md"
  printf 'evidencia\n'        > "$d/docs/evidence/semilla.md"
  printf '{"fase":7}\n'       > "$d/.saikit/progress/7.json"
  printf 'sesion\n'           > "$d/.saikit/progress/7-sesiones.txt"
  printf 'export const A=1\n' > "$d/summa-gate/lib.ts"
  printf 'agente\n'           > "$d/agents/x/agent.md"
  printf 'skill\n'            > "$d/docs/agent-skills/s/SKILL.md"
  printf 'echo run\n'         > "$d/scripts/run.sh"
  printf 'name: Q\n'          > "$d/.github/workflows/quality.yml"
  git -C "$d" -c init.defaultBranch=main init -q
  git -C "$d" add -A
  git -C "$d" -c user.name=fixture -c user.email=fixture@test commit -qm semilla
}

commit_todo() { # $1: repo; commitea el cambio en curso
  git -C "$1" add -A
  git -C "$1" -c user.name=fixture -c user.email=fixture@test commit -qm cambio
}

# Corre el clasificador dentro del repo $1 con la allowlist $2. El stderr queda
# en $T/stderr para el mensaje de fallo; stdout (el veredicto) es el retorno.
correr() { # repo allowlist base head
  ( cd "$1" && bash "$RAIZ/$CLASIFICADOR" --allowlist "$2" --base "$3" --head "$4" 2>"$T/stderr" )
}

veredicto_es() { # nombre esperado repo allowlist base head
  local nombre=$1 esperado=$2 out rc detalle
  out=$(correr "$3" "$4" "$5" "$6"); rc=$?
  if [ "$rc" -ne 0 ]; then
    detalle=$(tail -2 "$T/stderr" | tr '\n' ' ')
    falla "$nombre: exit $rc con veredicto esperado '$esperado' (stderr: $detalle)"
    return
  fi
  if [ "$out" != "$esperado" ]; then
    detalle=$(tail -2 "$T/stderr" | tr '\n' ' ')
    falla "$nombre: veredicto '$out', esperaba '$esperado' (stderr: $detalle)"
    return
  fi
  ok "$nombre -> $esperado"
}

# (2) docs permitidos: la allowlist clasifica el conjunto de cierre tipico.
d=$T/docs-permitidos; sembrar "$d"
printf 'plan 2\n'                 > "$d/Plans.md"
printf '{"fase":15}\n'            > "$d/.saikit/progress/15.json"
printf 'sesion 15\n'              > "$d/.saikit/progress/15-sesiones.txt"
printf 'medicion\n'               > "$d/docs/evidence/fase15-ci-performance.md"
printf 'log de recibo\n'          > "$d/docs/evidence/gate-recibo-logs-run9.txt"
mkdir -p "$d/docs/evidence/subdir"   # profundidad >0: '**/' tiene que cubrirla
printf 'tabla\n'                  > "$d/docs/evidence/subdir/corpus.md"
commit_todo "$d"
veredicto_es docs-permitidos fast "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# (3) codigo puro.
d=$T/codigo; sembrar "$d"
printf 'export const A=2\n' > "$d/summa-gate/lib.ts"
commit_todo "$d"
veredicto_es codigo completo "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# (3) mezcla: un documento permitido + un script => completo.
d=$T/mezcla; sembrar "$d"
printf 'plan 3\n' > "$d/Plans.md"
printf 'echo run2\n' > "$d/scripts/run.sh"
commit_todo "$d"
veredicto_es mezcla completo "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# (4) borrados: cuentan igual que las altas. Borrar un doc permitido es fast.
d=$T/borrado-doc; sembrar "$d"
git -C "$d" rm -q Plans.md
commit_todo "$d"
veredicto_es borrado-doc fast "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# (4) borrado de codigo.
d=$T/borrado-codigo; sembrar "$d"
git -C "$d" rm -q summa-gate/lib.ts
commit_todo "$d"
veredicto_es borrado-codigo completo "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# (4) borrado mixto: doc permitido + codigo.
d=$T/borrado-mezcla; sembrar "$d"
git -C "$d" rm -q Plans.md scripts/run.sh
commit_todo "$d"
veredicto_es borrado-mezcla completo "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# (4) renombre doc -> doc: origen Y destino permitidos => fast. Se afirma que
# el diff realmente reporto un R (si no, el caso no ejercita la regla).
d=$T/renombre-doc-doc; sembrar "$d"
git -C "$d" mv Plans.md docs/evidence/plan-renombrado.md
commit_todo "$d"
if git -C "$d" diff --name-status --find-renames HEAD~1 HEAD | grep -q '^R'; then
  veredicto_es renombre-doc-doc fast "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"
else
  falla "renombre-doc-doc: el fixture no produjo un R real (no ejercita la regla de renombres)"
fi

# (4) renombre doc -> codigo: el DESTINO cae fuera de contrato.
d=$T/renombre-doc-codigo; sembrar "$d"
git -C "$d" mv Plans.md summa-gate/plan.ts
commit_todo "$d"
if git -C "$d" diff --name-status --find-renames HEAD~1 HEAD | grep -q '^R'; then
  veredicto_es renombre-doc-codigo completo "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"
else
  falla "renombre-doc-codigo: el fixture no produjo un R real"
fi

# (4) renombre codigo -> doc: el ORIGEN cae fuera de contrato aunque el destino
# sea un documento permitido. Sin la regla de origen este caso daria fast.
d=$T/renombre-codigo-doc; sembrar "$d"
git -C "$d" mv summa-gate/lib.ts docs/evidence/lib.md
commit_todo "$d"
if git -C "$d" diff --name-status --find-renames HEAD~1 HEAD | grep -q '^R'; then
  veredicto_es renombre-codigo-doc completo "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"
else
  falla "renombre-codigo-doc: el fixture no produjo un R real"
fi

# (7) modos no regulares JAMAS fast (r3, CodeRabbit Major): `git diff
# --name-status` no muestra modos, asi que un symlink nuevo (o una conversion
# de tipo, o un submodulo) en ruta allowlisted se ve como A/T fast. Cada
# fixture afirma que el diff realmente trae el modo/estado (si no, el caso no
# ejercita la regla), igual que los fixtures de renombre de arriba.

# symlink NUEVO en ruta allowlisted: aparece 'A' y casaria con
# docs/evidence/**/*.md si el clasificador no mira el modo (120000).
d=$T/symlink-nuevo-allowlist; sembrar "$d"
ln -s ../../scripts/run.sh "$d/docs/evidence/informe.md"
commit_todo "$d"
if git -C "$d" diff --raw --find-renames HEAD~1 HEAD | grep -q '120000'; then
  veredicto_es symlink-nuevo-allowlist completo "$d" "$ALLOWLIST" \
    "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"
else
  falla "symlink-nuevo-allowlist: el fixture no produjo un symlink (modo 120000)"
fi

# conversion de tipo (T): archivo regular de la semilla pasa a symlink. Sin la
# regla de modos el 'T' casaria con la allowlist igual que antes del cambio.
d=$T/conversion-a-symlink; sembrar "$d"
rm "$d/docs/evidence/semilla.md"
ln -s ../../Plans.md "$d/docs/evidence/semilla.md"
commit_todo "$d"
if git -C "$d" diff --name-status --find-renames HEAD~1 HEAD | grep -q '^T'; then
  veredicto_es conversion-a-symlink completo "$d" "$ALLOWLIST" \
    "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"
else
  falla "conversion-a-symlink: el fixture no produjo un T real"
fi

# gitlink NUEVO (submodulo) en ruta allowlisted: el nombre .md es el punto del
# caso; el modo 160000 es lo unico que lo delata como no-archivo.
d=$T/gitlink-nuevo-allowlist; sembrar "$d"
r=$T/submodulo
git -C "$r" init -q 2>/dev/null || { mkdir -p "$r" && git -C "$r" init -q; }
git -C "$r" -c user.name=fixture -c user.email=fixture@test commit -qm raiz --allow-empty
sha_sub=$(git -C "$r" rev-parse HEAD)
git -C "$d" update-index --add --cacheinfo 160000,"$sha_sub",docs/evidence/submodulo.md
git -C "$d" -c user.name=fixture -c user.email=fixture@test commit -qm cambio
if git -C "$d" diff --raw --find-renames HEAD~1 HEAD | grep -q '160000'; then
  veredicto_es gitlink-nuevo-allowlist completo "$d" "$ALLOWLIST" \
    "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"
else
  falla "gitlink-nuevo-allowlist: el fixture no produjo un gitlink (modo 160000)"
fi

# (3) documentos operativos: markdown que controla comportamiento NO es fast.
for caso in agents/x/agent.md docs/agent-skills/s/SKILL.md .github/workflows/quality.yml; do
  nombre=documento-operativo-$(printf '%s' "$caso" | tr '/' '-')
  d=$T/$nombre; sembrar "$d"
  printf 'nueva instruccion\n' > "$d/$caso"
  commit_todo "$d"
  veredicto_es "$nombre" completo "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"
done

# (1) formato fuera de contrato: .md en .saikit/progress/ NO esta enumerado.
d=$T/formato-fuera-de-contrato; sembrar "$d"
printf 'notas\n' > "$d/.saikit/progress/notas.md"
commit_todo "$d"
veredicto_es formato-fuera-de-contrato completo "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# (1) codigo en un arbol de docs: el arbol permitido es formato-contratado,
# no una extension suelta ni un directorio abierto.
d=$T/codigo-en-arbol-de-docs; sembrar "$d"
printf 'echo sh\n' > "$d/docs/evidence/script.sh"
commit_todo "$d"
veredicto_es codigo-en-arbol-de-docs completo "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# (5) allowlist vacia: nada es fast por adivinanza; la enumeracion es exhaustiva.
d=$T/allowlist-vacia; sembrar "$d"
printf 'plan 4\n' > "$d/Plans.md"
commit_todo "$d"
veredicto_es allowlist-vacia completo "$d" "$ALLOWLIST_VACIA" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# (5) sin cambios entre base comun y head: nada que probar => fast (postura
# declarada; no confunde "vacio" con "no pude comparar").
d=$T/sin-cambios; sembrar "$d"
h=$(git -C "$d" rev-parse HEAD)
veredicto_es sin-cambios fast "$d" "$ALLOWLIST" "$h" "$h"

# (5) base inresoluble: before invalido (rama nueva, 000...) => completo, exit 0.
d=$T/base-inresoluble; sembrar "$d"
veredicto_es base-inresoluble completo "$d" "$ALLOWLIST" \
  0000000000000000000000000000000000000000 "$(git -C "$d" rev-parse HEAD)"

# (5) historias sin ancestor comun: merge-base imposible => completo, exit 0.
d=$T/historias-independientes; sembrar "$d"
arbol_vacio=$(git -C "$d" hash-object -t tree /dev/null)
raiz_huerfana=$(printf 'huerfano\n' | git -C "$d" -c user.name=f -c user.email=f@t commit-tree "$arbol_vacio")
veredicto_es historias-independientes completo "$d" "$ALLOWLIST" "$raiz_huerfana" "$(git -C "$d" rev-parse HEAD)"

# (5) errores de uso/herramienta: exit 2, sin veredicto (el job debe morir rojo).
d=$T/errores-uso; sembrar "$d"
b=$(git -C "$d" rev-parse HEAD); h=$b
( cd "$d" && bash "$RAIZ/$CLASIFICADOR" >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && ok "uso-sin-args -> exit 2" || falla "uso-sin-args: espero exit 2, llego $rc"
( cd "$d" && bash "$RAIZ/$CLASIFICADOR" --base "$b" --head "$h" --pirotecnia >/dev/null 2>&1 )
[ $? -eq 2 ] && ok "uso-flag-desconocido -> exit 2" || falla "uso-flag-desconocido: espero exit 2"
( cd "$d" && bash "$RAIZ/$CLASIFICADOR" --allowlist "$RAIZ/$T/no-existe.txt" --base "$b" --head "$h" >/dev/null 2>&1 )
[ $? -eq 2 ] && ok "allowlist-inexistente -> exit 2" || falla "allowlist-inexistente: espero exit 2"
( cd "$T/plano" && bash "$RAIZ/$CLASIFICADOR" --allowlist "$ALLOWLIST" --base x --head y >/dev/null 2>&1 )
[ $? -eq 2 ] && ok "no-es-repo-git -> exit 2" || falla "no-es-repo-git: espero exit 2"

# (2) contrato con la allowlist REAL: los 4 paths del cierre de la fase.
d=$T/contrato-real-4-paths; sembrar "$d"
printf 'plan 5\n'                 > "$d/Plans.md"
printf '{"fase":15}\n'            > "$d/.saikit/progress/15.json"
printf 'sesion 15\n'              > "$d/.saikit/progress/15-sesiones.txt"
printf 'evidencia fase 15\n'      > "$d/docs/evidence/fase15-ci-performance.md"
commit_todo "$d"
veredicto_es contrato-real-4-paths fast "$d" "$ALLOWLIST_REAL" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# (3) contrato con la allowlist REAL: el workflow sigue fuera del carril fast.
d=$T/contrato-real-workflow; sembrar "$d"
printf 'name: Q2\n' > "$d/.github/workflows/quality.yml"
commit_todo "$d"
veredicto_es contrato-real-workflow completo "$d" "$ALLOWLIST_REAL" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# (6) interfaz GITHUB_OUTPUT: carril= y motivo= en lineas propias, igual que
# las lee quality.yml (steps.clasificar.outputs.carril).
d=$T/salida-github-output; sembrar "$d"
printf 'plan 6\n' > "$d/Plans.md"
commit_todo "$d"
go=$T/github_output; : > "$go"
( cd "$d" && GITHUB_OUTPUT="$go" bash "$RAIZ/$CLASIFICADOR" \
    --allowlist "$ALLOWLIST" \
    --base "$(git -C "$d" rev-parse HEAD~1)" --head HEAD >/dev/null 2>&1 )
if grep -q '^carril=fast$' "$go" && grep -q '^motivo=' "$go"; then
  ok "salida-github-output -> carril=fast y motivo= presentes"
else
  falla "salida-github-output: GITHUB_OUTPUT no trae carril=fast y motivo= ($(tr '\n' ';' < "$go"))"
fi

# (6) el veredicto de stdout es UNA linea exacta (lo consumen tests y humanos;
# el workflow consume GITHUB_OUTPUT, no esto, pero es el contrato visible).
out=$(correr "$d" "$ALLOWLIST" "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)")
if [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] && [ "$out" = "fast" ]; then
  ok "salida-stdout-unica-linea"
else
  falla "salida-stdout-unica-linea: stdout='$out'"
fi

# (7) la llave no abre su propia puerta (bloqueante 1 de la r1): cualquier
# cambio que toque LOS ARCHIVOS QUE CONTROLAN LA CLASIFICACION clasifica
# completo, sin importar el contenido de la allowlist. El atacante reescribe
# la allowlist a '**' y agrega codigo: sin esta regla el cambio saldria fast
# porque la allowlist consultada (la del head) casa con todo.
d=$T/allowlist-se-reescribe; sembrar "$d"
mkdir -p "$d/src"
printf '**\n'   > "$d/scripts/ci-fast-allowlist.txt"   # el cambio reescribe la llave...
printf 'app\n'  > "$d/src/app.txt"                     # ...y agrega codigo
commit_todo "$d"
veredicto_es allowlist-se-reescribe completo "$d" "$d/scripts/ci-fast-allowlist.txt" \
  "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"

# Igual con el clasificador y con el workflow: aqui la allowlist permisiva
# queda EN LA BASE (fuera del rango), y el cambio toca SOLO el archivo de
# control + codigo. Con la '**' en la base, sin la regla estos saldrian fast.
for caso in scripts/clasificar-cambio.sh .github/workflows/quality.yml; do
  nombre=control-$(printf '%s' "$caso" | tr '/' '-')
  d=$T/$nombre; sembrar "$d"
  printf '**\n' > "$d/scripts/ci-fast-allowlist.txt"
  commit_todo "$d"                       # la llave permisiva entra a la BASE
  mkdir -p "$d/src"
  printf 'cambio\n' > "$d/$caso"
  printf 'app\n'    > "$d/src/app.txt"
  commit_todo "$d"
  veredicto_es "$nombre" completo "$d" "$d/scripts/ci-fast-allowlist.txt" \
    "$(git -C "$d" rev-parse HEAD~1)" "$(git -C "$d" rev-parse HEAD)"
done

if [ "$fails" -gt 0 ]; then
  echo "ROJO: $fails caso(s) del clasificador en fallo"
  exit 1
fi
echo "TODO VERDE: test-clasificador-cambio"
