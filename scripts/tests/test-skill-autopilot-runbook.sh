#!/bin/bash
# La skill que produce los runbooks de autopilot vivía SOLO en
# ~/.claude/skills/autopilot-runbook/SKILL.md, fuera de todo control de
# versiones: trece pasadas de lector la fueron corrigiendo y no había forma de
# ver qué cambió, ni de recuperarla si la Mac se pierde, ni de que otro lead la
# leyera. La copia canónica ahora vive en el repo.
#
# Esta prueba verifica dos cosas distintas:
#  (1) la copia del repo sigue trayendo los doce slots y la pasada de
#      ambigüedad, que es lo que hace que el runbook salga sin preguntas;
#  (2) si la Mac tiene la copia suelta, su contenido está commiteado en alguna
#      ref de este repo. NO se exige que sea idéntica a la de ESTA rama: eso
#      acoplaba cada rama a un archivo global de la máquina y ponía en rojo a
#      quien no lo había tocado. En CI esa copia no existe y el check se salta,
#      declarándolo: el candado que importa contra la deriva es el de la Mac.
#
# Uso: bash scripts/tests/test-skill-autopilot-runbook.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

REPO=docs/agent-skills/autopilot-runbook/SKILL.md
MAC=$HOME/.claude/skills/autopilot-runbook/SKILL.md

[ -r "$REPO" ] || fail "no encuentro la copia canónica: $REPO"

# El .gitignore del repo ignora cualquier carpeta llamada `skills/` porque el
# gateway las regenera. Una copia bajo `docs/skills/` se ve bien en el disco,
# pasa esta prueba en local y llega a CI sin el archivo. Medido 2026-09-16.
git check-ignore -q "$REPO" \
  && fail "$REPO está en .gitignore: el commit no lo lleva y CI se queda sin el archivo"
git ls-files --error-unmatch "$REPO" >/dev/null 2>&1 \
  || echo "aviso: $REPO todavía no está en el índice de git"

# (1) El frontmatter mínimo que la hace descubrible.
head -1 "$REPO" | grep -q '^---$' || fail "$REPO: sin frontmatter"
grep -q '^name: autopilot-runbook$' "$REPO" || fail "$REPO: el name no es autopilot-runbook"
grep -q '^description: Use when ' "$REPO" || fail "$REPO: la description no arranca con 'Use when'"
echo "ok (1): frontmatter con name y description"

# (2) Los doce slots numerados, en orden. Sin ellos la receta no produce un
# documento ejecutable: cada slot cerrado es una pregunta que el lector no hace.
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
  grep -q -E "^$n\. \*\*" "$REPO" || fail "$REPO: falta el slot $n de la receta"
done
echo "ok (2): los doce slots de la receta están"

# (3) Las reglas que trece lecturas dejaron, cada una porque un runbook falló
# por no tenerla. Si alguna se cae, la skill vuelve a producir el runbook que
# ya se sabe que se atora.
for a in 'lead is written as a **role**' \
         'loop-autopilot.md' \
         'by section number' \
         'does NOT restate the loop' \
         'Ambiguity pass' \
         'runbook-progress.v1' \
         'files table' \
         'Dispatch one fresh-context subagent' \
         'test-runbooks-no-contradicen-entorno.sh'; do
  grep -qF "$a" "$REPO" || fail "$REPO: falta el ancla: $a"
done
echo "ok (3): las nueve anclas de reglas están"

# (4) La copia de la Mac, cuando existe, no puede traer contenido que no esté
# commiteado EN NINGUNA parte. Ojo con lo que NO se exige: que sea idéntica a la
# de ESTA rama. La versión anterior lo exigía y acoplaba cada rama a un archivo
# global de la máquina: medido 2026-09-18, una rama sacada de la rama por
# defecto, que no tocaba el skill, se puso roja solo porque otra rama ya había
# actualizado la copia de la Mac. Eso convertía un candado contra la deriva en
# un bloqueo para cualquiera que no tuviera la última versión en su rama.
#
# Lo que sí atrapa, que es el riesgo real: contenido que vive SOLO en la Mac y
# que nadie commiteó, que es como esta skill vivió trece pasadas sin control de
# versiones.
if [ -r "$MAC" ]; then
  if cmp -s "$REPO" "$MAC"; then
    echo "ok (4): la copia de la Mac es idéntica a la de esta rama"
  else
    # ALCANZABLE desde una ref, no solo presente en la base de objetos.
    # Hallazgo del revisor en el PR 88, con reproduccion: `git cat-file -e $h`
    # solo acredita que el blob existe, y eso lo consigue un `git add` de la
    # deriva sin commitear, o un blob que dejo un commit descartado. Se probo
    # exponiendo el blob por GIT_ALTERNATE_OBJECT_DIRECTORIES: contenido que
    # esta en CERO commits pasaba en verde. Se compara contra la version de
    # ESTE archivo en cada ref, que ademas acota el costo al numero de refs.
    h=$(git hash-object "$MAC" 2>/dev/null)
    encontrado=no
    if [ -n "$h" ]; then
      for r in $(git for-each-ref --format='%(refname)'); do
        if [ "$(git rev-parse "$r:$REPO" 2>/dev/null)" = "$h" ]; then encontrado=$r; break; fi
      done
    fi
    if [ "$encontrado" != "no" ]; then
      echo "ok (4): la copia de la Mac no es la de esta rama, pero es la versión de $encontrado ($h)"
    else
      fail "la copia de la Mac tiene contenido que no está commiteado en ninguna rama: diff $REPO $MAC"
    fi
  fi
else
  echo "ok (4): sin copia en la Mac ($MAC); comparación saltada, declarado"
fi

echo "TODO VERDE: skill autopilot-runbook"
