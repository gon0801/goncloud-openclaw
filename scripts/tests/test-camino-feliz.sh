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
  chk "go/no-go unico (merge y deploy)" grep -q 'merge y deploy' "$MAP"
  chk "go/no-go separado (merge y deploy separados)" grep -q 'merge y luego deploy' "$MAP"
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
