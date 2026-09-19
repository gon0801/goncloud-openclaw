#!/bin/bash
# Prueba de los dos hallazgos de CodeRabbit en el PR #52 sobre saikit-cierre-pr:
#
#  (a) MAYOR, roto al copiarlo: el paso 2 de "Merge por orden del dueño" hacía
#      `ID=$(gh pr view ... --jq '"\(.id) \(.headRefOid)"')` y luego mandaba la
#      mutación con `-f id="$ID" -f oid="$OID"`. `OID` nunca se asignaba y `ID`
#      llevaba los dos valores pegados, así que la ruta de merge autorizada
#      enviaba una entrada GraphQL inválida.
#  (b) MENOR: el encabezado de la skill manda usar la ruta absoluta de `gh`
#      porque el exec del nodo Mac sanea el PATH, pero los ejemplos ejecutables
#      de ese mismo flujo iban con `gh` pelado: copiarlos falla antes de
#      re-apuntar o mergear.
#
# La skill vive duplicada (implementer e ingenieria) y el kit las lee por
# separado: una corrección en una sola copia deja al otro agente con el comando
# roto, así que la igualdad también se verifica aquí.
#
# Lo que NO se marca, a propósito: las prohibiciones (`gh pr merge` citado como
# la forma bloqueada) y el párrafo que documenta la tolerancia léxica del guard,
# donde el texto pelado ES el dato que se está describiendo.
#
# Uso: bash scripts/tests/test-cierre-pr-merge-comando.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# Una skill es la CARPETA, no un archivo suelto. Medido el 2026-09-19: un agente
# repartio saikit-cierre-pr en SKILL.md + MERGE-POR-ORDEN.md desde el gateway y
# solo en SU copia, asi que las dos dejaron de ser iguales. La igualdad que este
# candado exige es la de la skill entera, archivo por archivo.
A=agents/implementer/agent/workshop-skills/saikit-cierre-pr
B=agents/ingenieria/agent/workshop-skills/saikit-cierre-pr

for f in "$A" "$B"; do
  [ -d "$f" ] || fail "no encuentro la skill: $f"
done

# (1) Las dos copias son la misma, con los mismos archivos.
diff -r "$A" "$B" >/dev/null 2>&1 || fail "las dos copias de saikit-cierre-pr difieren: $A vs $B"
echo "ok (1): las dos copias de saikit-cierre-pr son idénticas"

# Sección bajo prueba: los pasos numerados del flujo de merge, del 1 hasta las
# precondiciones. El párrafo que los introduce queda fuera a propósito: ahí
# `gh pr merge` y `gh api` aparecen como prosa sobre lo que el guard bloquea,
# no como comandos que alguien copie. Lo de abajo de las precondiciones es
# documentación de la tolerancia léxica del guard, por la misma razón.
seccion() {
  cat "$1"/*.md 2>/dev/null | awk '/^1\. Merge order for stacked PRs/{f=1} /^Precondiciones \(Fase 6, 6\.5b\)/{f=0} f'
}

# (2) La mutación recibe los DOS valores, y ninguno queda sin origen.
# El bug original (hallazgo mayor de CodeRabbit en #52) era un solo `ID=$(...)` que
# se quedaba con los dos valores pegados mientras `$OID` nunca se asignaba, asi que
# la ruta de merge autorizada mandaba una entrada GraphQL invalida.
# Esto comprueba el FONDO, no una forma concreta: el 2026-09-17 el agente vivo midio
# que `read -r ID OID < <(...)` falla con "syntax error near unexpected token" porque
# el exec por node corre /bin/sh, que no tiene sustitucion de proceso, y reescribio la
# skill para pasar los dos valores literales. Esa correccion era buena y la version
# anterior de esta prueba, que exigia `read -r ID OID`, la habria bloqueado.
for f in "$A" "$B"; do
  s=$(seccion "$f")
  printf '%s\n' "$s" | grep -q -- '-f id=' \
    || fail "$f: el paso 2 ya no manda -f id= a la mutación; esta prueba quedó desalineada"
  printf '%s\n' "$s" | grep -q -- '-f oid=' \
    || fail "$f: el paso 2 ya no manda -f oid= a la mutación; esta prueba quedó desalineada"
  # Si usa la variable $OID, tiene que asignarla en la misma sección. Si pasa el valor
  # literal (<OID> o el sha), no hay variable que asignar y el bug original no cabe.
  if printf '%s\n' "$s" | grep -q 'oid="\$OID"'; then
    # Ojo con el verde falso: la seccion EXPLICA que `read -r ID OID < <(...)` falla,
    # asi que buscar esa cadena a secas la encuentra en la prosa que dice lo contrario.
    # Solo cuenta una asignacion en una linea que no este hablando de un fallo.
    printf '%s\n' "$s" | grep -E 'OID=|read -r ID OID' \
      | grep -v -i -E 'fail|falla|error|no tiene|sin sustitucion|sustitución' \
      | grep -q . \
      || fail "$f: la mutación usa \$OID y la sección no lo asigna en ninguna parte (es el bug de #52)"
  fi
done
echo "ok (2): la mutación recibe id y oid, y toda variable que use queda asignada"

# (3) Ningún ejemplo ejecutable de la sección invoca `gh` pelado.
# Cuenta como invocación un tramo entre backticks que EMPIEZA con `gh ` o con
# `ID=$(gh ` / `read ... gh `. Se descartan las líneas de prohibición.
gh_pelado() {
  { grep -v -i -E 'nunca|never|jam[aá]s|bloquead|prohibid' || true; } \
    | grep -o -E '`[^`]*`' \
    | grep -E '^`(gh|[A-Z]+=\$\(gh|read [^`]*< <\(gh)[[:space:]]' \
    | grep -v -E '\.\.\.`$|^`gh( [a-z-]+)?`$'
}
# El ultimo filtro deja pasar la PROSA: un tramo que termina en `...`, o que es solo
# el nombre del comando sin un solo argumento, habla del comando en vez de invocarlo.
# Lo que se persigue es un ejemplo COPIABLE sin el prefijo del PATH, y ninguna de esas
# dos formas lo es. La skill del 2026-09-17 explica cuando vale -R diciendo que
# "`-R <owner>/<repo>` vale para `gh pr ...` pero `gh api` no tiene ese flag", y sin
# este filtro esa explicacion se leia como un ejemplo ejecutable.
for f in "$A" "$B"; do
  hit=$(seccion "$f" | gh_pelado || true)
  [ -z "$hit" ] || fail "$f: ejemplo ejecutable con gh pelado (el exec del nodo Mac sanea el PATH): $hit"
done
echo "ok (3): los ejemplos ejecutables usan la ruta absoluta de gh"

# (4) El detector discrimina: las formas malas se marcan y las buenas pasan.
for c in '`gh pr view 45 --json state`' \
         '`gh api graphql -f query=x`' \
         '`ID=$(gh pr view 45 --json id)`' \
         '`read -r ID OID < <(gh pr view 45 --json id,headRefOid)`'; do
  printf '%s\n' "$c" | gh_pelado | grep -q . || fail "el detector NO marca: $c"
done
for c in '`/opt/homebrew/bin/gh pr view 45 --json state`' \
         '`read -r ID OID < <(/opt/homebrew/bin/gh pr view 45 --json id,headRefOid)`' \
         'NUNCA intentes el merge: `gh pr merge` está bloqueado'; do
  printf '%s\n' "$c" | gh_pelado | grep -q . && fail "el detector marca de más: $c"
done
echo "ok (4): el detector discrimina con fixtures inline"

# (5) El recorte de sección es lo que protege la prosa del guard, no el patrón:
# ahí `gh -X GET api rate_limit` y compañía son ejemplos de lo que el guard
# tolera, y escritos con ruta absoluta dejarían de documentar lo que documentan.
# Si el recorte se rompe, esa prosa entra al detector y la prueba se vuelve ruido.
for f in "$A" "$B"; do
  s=$(seccion "$f")
  printf '%s\n' "$s" | grep -q 'rate_limit' \
    && fail "$f: el recorte de sección se comió la prosa del guard; (3) marcaría falsos positivos"
  printf '%s\n' "$s" | grep -q 'Merge order for stacked PRs' \
    || fail "$f: el recorte de sección no encuentra el paso 1; la prueba no está mirando nada"
done
echo "ok (5): el recorte deja fuera la prosa del guard y dentro los pasos"

echo "TODO VERDE: saikit-cierre-pr, comando de merge y PATH"
