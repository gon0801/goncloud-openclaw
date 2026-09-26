#!/bin/bash
# La skill que produce los runbooks de autopilot vivía SOLO en
# ~/.claude/skills/autopilot-runbook/SKILL.md, fuera de todo control de
# versiones: trece pasadas de lector la fueron corrigiendo y no había forma de
# ver qué cambió, ni de recuperarla si la Mac se pierde, ni de que otro lead la
# leyera. La copia canónica ahora vive en el repo.
#
# Esta prueba verifica dos cosas distintas:
#  (1) la copia del repo sigue trayendo los quince slots y la pasada de
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

# (2) Los dieciseis slots numerados, en orden. Sin ellos la receta no produce un
# documento ejecutable: cada slot cerrado es una pregunta que el lector no hace.
# Los slots 14 (Seguimiento) y 15 (Clases de comando) nacen en la Fase 9, 9.7:
# sin ellos el runbook no dice quien le habla a David ni el preflight tiene que
# leer. El slot 16 (Promesa observable) nace en la Fase 9, 9.12: sin el, una
# fila del plan puede cerrarse sin que nadie diga que veria un usuario si
# funciona. No se renumera: runbooks y pruebas citan "slot 12" y "slot 13" por
# numero.
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  grep -q -E "^$n\. \*\*" "$REPO" || fail "$REPO: falta el slot $n de la receta"
done
echo "ok (2): los dieciseis slots de la receta están"

# (2-bis) El slot 13 no es prosa: nombra el comando que prueba la entrega y la
# frase de una linea. Medido 2026-09-18: un runbook escrito, revisado y
# commiteado seguia necesitando dos comandos pegados a mano para arrancar, y el
# dueño lo descubrio preguntando "que le digo a claw".
grep -q 'lanzar-fase.sh' "$REPO" \
  || fail "$REPO: el slot 13 no nombra scripts/lanzar-fase.sh, que es lo que hace la entrega comprobable"
grep -q -E 'FIRST command opens the run on the board' "$REPO" \
  || fail "$REPO: el slot 12 perdio el paso de nacimiento (abrir la corrida es el primer comando)"
grep -qF '`corrida`' "$REPO" || fail "$REPO: el slot 12 no nombra la clave corrida"
grep -qF '`proyecto`' "$REPO" || fail "$REPO: el slot 12 no nombra la clave proyecto"
grep -qF '`plan`' "$REPO" || fail "$REPO: el slot 12 no nombra la clave plan"
echo "ok (2-bis): la entrega se prueba con un comando, y la corrida nace con el runbook"

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
         'test-runbooks-no-contradicen-entorno.sh' \
         '14. **Seguimiento.**' \
         '15. **Clases de comando.**' \
         'corrida.sh preflight' \
         '## Clases de comando' \
         'Plantilla del encargo del lead' \
         'espejo de progreso' \
         '16. **Promesa observable.**' \
         'Promesa: <qué vería un humano si funciona> — ruta: <cómo llegaría ahí>.' \
         'Promesa: sin promesa observable.' \
         'agents/usuario/agent/AGENTS.md' \
         'it never reads the diff, the tests or the PR'; do
  grep -qF "$a" "$REPO" || fail "$REPO: falta el ancla: $a"
done
echo "ok (3): las diecinueve anclas de reglas están"

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

primer_comando_abre_corrida() {
  [ -r "$1" ] || return 1
  local cuerpo
  cuerpo=$(awk '
    /^```/ {
      n++
      if (n == 1) next
      if (n >= 2) exit
    }
    n == 1 { print }
  ' "$1") || return 1
  printf '%s\n' "$cuerpo" | grep -qF 'runbook.progress.set' || return 1
  printf '%s\n' "$cuerpo" | grep -qF 'corrida' || return 1
  printf '%s\n' "$cuerpo" | grep -qF 'proyecto' || return 1
  printf '%s\n' "$cuerpo" | grep -qF 'plan' || return 1
  printf '%s\n' "$cuerpo" | grep -qF 'pendiente' || return 1
  return 0
}

FX=scripts/tests/fixtures/skill-autopilot-runbook
BUENO=$FX/autopilot-bueno.md
MALO=$FX/autopilot-malo.md
[ -r "$BUENO" ] || fail "(5) no encuentro el fixture bueno: $BUENO"
[ -r "$MALO" ] || fail "(5) no encuentro el fixture malo: $MALO"
git check-ignore -q "$BUENO" \
  && fail "(5) $BUENO está en .gitignore: el commit no lo lleva y CI se queda sin el archivo"
git check-ignore -q "$MALO" \
  && fail "(5) $MALO está en .gitignore: el commit no lo lleva y CI se queda sin el archivo"
grep -qF tablero "$MALO" \
  || fail "(5) el fixture malo no trae tablero: falta la semilla de la mutación"

casos=()
casos+=("$BUENO	0")
casos+=("$MALO	1")
for f in docs/runbooks/autopilot-fase*.md; do
  [ -f "$f" ] || continue
  n=${f##*/autopilot-fase}
  n=${n%.md}
  case "$n" in *[!0-9]*|'') continue ;; esac
  [ "$n" -gt 12 ] || continue
  casos+=("$f	0")
done

for fila in "${casos[@]}"; do
  path=${fila%%	*}
  expected=${fila#*	}
  if primer_comando_abre_corrida "$path"; then
    got=0
  else
    got=1
  fi
  if [ "$got" -ne "$expected" ]; then
    if [ "$path" = "$MALO" ]; then
      fail "(5) el fixture malo pasó: un candado que solo busca tablero se pondría verde"
    fi
    if [ "$path" = "$BUENO" ]; then
      fail "(5) el fixture bueno no abre la corrida en el primer comando"
    fi
    fail "(5) $path: primer comando no abre la corrida"
  fi
done
echo "ok (5): el primer comando de un runbook nuevo abre la corrida"

echo "TODO VERDE: skill autopilot-runbook"
