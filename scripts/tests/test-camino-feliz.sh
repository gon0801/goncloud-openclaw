#!/usr/bin/env bash
# 6.4: test del mapa del camino feliz (rojo primero contra origin/main:
# el archivo del mapa no existe ahi).
set -u
cd "$(dirname "$0")/../.." || exit 1
MAP=docs/runbooks/camino-feliz-producto.md
fails=0
chk() { # chk <desc> <cmd...>
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "OK: $desc"; else echo "FALLO: $desc"; fails=$((fails+1)); fi
}
chk "mapa existe" test -f "$MAP"
if [ -f "$MAP" ]; then
  for s in agent-dispatch post-merge-closure owner-report-delivery; do
    chk "skill $s nombrada en el mapa" grep -q "$s" "$MAP"
    chk "skill $s existe" test -f "agents/main/agent/workshop-skills/$s/SKILL.md"
  done
  chk "skill saikit-cierre-pr nombrada en el mapa" grep -q "saikit-cierre-pr" "$MAP"
  chk "skill saikit-cierre-pr existe" test -f "agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md"
  chk "skill goncloud-ssh-ops nombrada en el mapa" grep -q "goncloud-ssh-ops" "$MAP"
  chk "skill goncloud-ssh-ops existe" test -f "agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md"
  # anclas de los dos tipos de go/no-go
  chk "go/no-go unico (merge y deploy)" grep -q 'sin permiso adicional' "$MAP"
  row7=$(awk -F '|' '$2 ~ /^ *7 *$/ {print; exit}' "$MAP")
  row8=$(awk -F '|' '$2 ~ /^ *8 *$/ {print; exit}' "$MAP")
  row9=$(awk -F '|' '$2 ~ /^ *9 *$/ {print; exit}' "$MAP")
  if printf '%s' "$row7" | grep -q 'Permiso permanente' && ! printf '%s' "$row7" | grep -qE 'PR integrado|merge y luego deploy|comprueba la publicación'; then
    echo "OK: paso 7 declara permiso sin repetir merge ni deploy"
  else
    echo "FALLO: paso 7 repite merge o deploy"
    fails=$((fails+1))
  fi
  if printf '%s' "$row8" | grep -q 'PR `MERGED`' && printf '%s' "$row9" | grep -q 'Smoke verde'; then
    echo "OK: merge en paso 8 y deploy en paso 9"
  else
    echo "FALLO: merge y deploy no están en sus pasos"
    fails=$((fails+1))
  fi
  section_h2() {
    awk -v h="$1" '
      index($0, h) == 1 {grab=1; print; next}
      grab && /^## / {exit}
      grab {print}
    ' "$MAP"
  }
  filas_datos() {
    awk '
      /^\|[-:| ]+\|$/ {next}
      /^\|/ { if (hdr++) n++; }
      END { print n+0 }
    '
  }
  row10=$(awk -F '|' '$2 ~ /^ *10 *$/ {print; exit}' "$MAP")
  [ -n "$row10" ] || { echo "FALLO: falta la fila 10 del flujo"; fails=$((fails+1)); }
  paso=$(printf '%s\n' "$row10" | awk -F '|' '{print $3}')
  cierre=$(printf '%s\n' "$row10" | awk -F '|' '{print $5}')
  if printf '%s' "$paso" | grep -q 'Live <SHA> en <URL>'; then echo "OK: Live SHA en celda Paso 10"; else echo "FALLO: Live SHA en celda Paso 10"; fails=$((fails+1)); fi
  if printf '%s' "$cierre" | grep -q 'Live <SHA> en <URL>'; then echo "OK: Live SHA en celda Cierre 10"; else echo "FALLO: Live SHA en celda Cierre 10"; fails=$((fails+1)); fi
  flujo=$(section_h2 '## Flujo principal')
  if printf '%s\n' "$flujo" | grep -q 'vuelve al brief'; then echo "OK: regresion vuelve al brief en Flujo principal"; else echo "FALLO: regresion vuelve al brief en Flujo principal"; fails=$((fails+1)); fi
  nvar=$(section_h2 '## Variantes' | filas_datos)
  nblo=$(section_h2 '## Bloqueos' | filas_datos)
  if [ "$nvar" -ge 1 ]; then echo "OK: tabla Variantes tiene $nvar fila(s)"; else echo "FALLO: tabla Variantes vacia o solo encabezado"; fails=$((fails+1)); fi
  if [ "$nblo" -ge 1 ]; then echo "OK: tabla Bloqueos tiene $nblo fila(s)"; else echo "FALLO: tabla Bloqueos vacia o solo encabezado"; fails=$((fails+1)); fi
  # sin GraphQL
  c=$(grep -c "GraphQL" "$MAP" || true)
  [ "$c" = "0" ] && echo "OK: cero GraphQL en el mapa" || { echo "FALLO: GraphQL aparece $c veces en el mapa"; fails=$((fails+1)); }
  # ninguna linea del mapa duplica textualmente una line de las 4 skills
  dup=0
  for s in agents/main/agent/workshop-skills/agent-dispatch/SKILL.md \
           agents/main/agent/workshop-skills/post-merge-closure/SKILL.md \
           agents/main/agent/workshop-skills/owner-report-delivery/SKILL.md \
           agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md; do
    while IFS= read -r line; do
      [ ${#line} -lt 40 ] && continue
      if grep -qxF -e "$line" "$MAP"; then echo "FALLO: linea duplicada de $s: ${line:0:60}"; dup=$((dup+1)); fi
    done < "$s"
  done
  [ "$dup" = "0" ] || fails=$((fails+1))
fi
if [ $fails -gt 0 ]; then echo "ROJO: $fails fallo(s) en el mapa del camino feliz"; exit 1; fi
echo "VERDE: mapa del camino feliz cumple la DoD de 6.4"
