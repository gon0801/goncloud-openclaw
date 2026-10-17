#!/bin/bash
# sincronizar-pstack.sh contra un cursor/plugins de mentira (PSTACK_TARBALL) y un HOME de mentira:
# la marca disable-model-invocation se apaga solo en el frontmatter, un árbol incompleto falla sin
# tocar la copia anterior, activar enlaza y respalda lo que había, repetir no cambia nada,
# restaurar deshace, y la corrida de launchd avisa cuando falla.
# Uso: bash scripts/tests/test-sincronizar-pstack.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
S="$PWD/scripts/mac/sincronizar-pstack.sh"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

skill() {  # skill <dir> <nombre> <valor de la marca o vacío>
  mkdir -p "$1/$2"
  {
    echo "---"
    if [ "$2" = poteto-mode ]; then echo "name: Poteto Mode"; else echo "name: $2"; fi
    echo "description: prueba"
    [ -n "$3" ] && echo "disable-model-invocation: $3"
    echo "---"
    echo ""
    echo "Cuerpo de $2. Esta línea no es frontmatter:"
    echo "disable-model-invocation: true"
  } > "$1/$2/SKILL.md"
}

arbol() {  # arbol <salida.tgz> [sin-poteto | sin-adaptador | marca-rara]
  local r="$T/arbol-$$-$RANDOM/cursor-plugins-abc1234"
  mkdir -p "$r/harness/pstack/claude-code/agents" "$r/harness/pstack/claude-code/docs/harness" "$r/cursor-team-kit/skills"
  [ "${2:-}" = sin-poteto ] || skill "$r/harness/pstack/claude-code/skills" poteto-mode true
  if [ "${2:-}" = marca-rara ]; then skill "$r/harness/pstack/claude-code/skills" tdd True; else skill "$r/harness/pstack/claude-code/skills" tdd true; fi
  skill "$r/harness/pstack/claude-code/skills" how ""
  [ "${2:-}" = sin-adaptador ] || echo "# adaptador" > "$r/harness/pstack/claude-code/docs/harness/claude-code.md"
  echo "poteto" > "$r/harness/pstack/claude-code/agents/poteto-agent.md"
  echo "sicko" > "$r/harness/pstack/claude-code/agents/comment-sicko.md"
  skill "$r/cursor-team-kit/skills" deslop ""
  skill "$r/cursor-team-kit/skills" otra-del-kit ""
  tar -czf "$1" -C "$(dirname "$r")" "$(basename "$r")"
}

export HOME="$T/home"
mkdir -p "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.claude/agents"
export PSTACK_MIN_SKILLS=3 PSTACK_TEAM_KIT=deslop
arbol "$T/bueno.tgz"
arbol "$T/roto.tgz" sin-poteto
arbol "$T/sin-adaptador.tgz" sin-adaptador
arbol "$T/marca-rara.tgz" marca-rara
RAIZ="$HOME/.agents/pstack-oficial"

# Lo que hay hoy: una skill del espejo viejo (directorio real), un enlace relativo de Claude que
# ya llega bien, y una skill ajena que nadie debe tocar.
skill "$HOME/.agents/skills" poteto-mode ""
echo viejo > "$HOME/.agents/skills/poteto-mode/VIEJO"
ln -s ../../.agents/skills/tdd "$HOME/.claude/skills/tdd"
skill "$HOME/.agents/skills" babysit ""
ln -s ../../.agents/skills/ajena-borrada "$HOME/.claude/skills/ajena-borrada"

# 1. preparar: copia, apaga la marca solo en el frontmatter, deja el ORIGEN.
PSTACK_TARBALL="$T/bueno.tgz" bash "$S" preparar > "$T/p1.log" 2>&1 || { cat "$T/p1.log"; fail "1: preparar falló con el árbol bueno"; }
grep -q '^disable-model-invocation: false$' "$RAIZ/skills/poteto-mode/SKILL.md" || fail "1: la marca de poteto-mode no quedó en false"
[ "$(grep -c '^disable-model-invocation: true$' "$RAIZ/skills/poteto-mode/SKILL.md")" = 1 ] || fail "1: tocó la línea del cuerpo o no la dejó"
grep -q 'disable-model-invocation' "$RAIZ/skills/how/SKILL.md" && [ "$(grep -c '^disable-model-invocation' "$RAIZ/skills/how/SKILL.md")" != 1 ] && fail "1: agregó la marca a una skill sin ella"
[ -f "$RAIZ/skills/deslop/SKILL.md" ] || fail "1: no trajo la skill de cursor-team-kit pedida"
grep -qx 'name: poteto-mode' "$RAIZ/skills/poteto-mode/SKILL.md" || fail "1: el name de exhibición no tomó el de la carpeta"
grep -qx 'name: tdd' "$RAIZ/skills/tdd/SKILL.md" || fail "1: cambió un name que ya coincidía"
[ -e "$RAIZ/skills/otra-del-kit" ] && fail "1: trajo una skill del kit que no se pidió"
grep -q 'cursor-plugins-abc1234' "$RAIZ/ORIGEN" || fail "1: ORIGEN no nombra el árbol"
[ -f "$HOME/.agents/.pstack-oficial-activo" ] && fail "1: preparar no debe activar"
[ -d "$HOME/.agents/skills/poteto-mode" ] && [ ! -L "$HOME/.agents/skills/poteto-mode" ] || fail "1: preparar tocó ~/.agents/skills"

# 2. un árbol sin poteto-mode falla y deja la copia buena intacta.
cp "$RAIZ/ORIGEN" "$T/origen-bueno"
PSTACK_TARBALL="$T/roto.tgz" bash "$S" preparar >/dev/null 2>&1 && fail "2: preparar aceptó un árbol sin poteto-mode"
cmp -s "$RAIZ/ORIGEN" "$T/origen-bueno" || fail "2: el árbol roto pisó la copia buena"
[ -e "$RAIZ.nueva" ] && fail "2: dejó la copia a medias"
PSTACK_TARBALL="$T/sin-adaptador.tgz" bash "$S" preparar >/dev/null 2>&1 && fail "2: preparar aceptó un árbol sin docs/harness/claude-code.md"
cmp -s "$RAIZ/ORIGEN" "$T/origen-bueno" || fail "2: el árbol sin adaptador pisó la copia buena"
PSTACK_TARBALL="$T/marca-rara.tgz" bash "$S" preparar >/dev/null 2>&1 && fail "2: preparar aceptó disable-model-invocation: True"

# 3. activar: enlaza, respalda lo que había, deja en paz lo ajeno y el enlace relativo bueno.
bash "$S" activar > "$T/activar.log" || fail "3: activar falló"
[ "$(readlink "$HOME/.agents/skills/poteto-mode")" = "$RAIZ/skills/poteto-mode" ] || fail "3: ~/.agents/skills/poteto-mode no apunta a la copia"
[ -L "$HOME/.claude/skills/poteto-mode" ] || fail "3: falta el enlace de Claude a poteto-mode"
[ "$(readlink "$HOME/.claude/skills/tdd")" = "../../.agents/skills/tdd" ] || fail "3: rehizo un enlace relativo que ya llegaba bien"
[ "$(readlink "$HOME/.claude/agents/poteto-agent.md")" = "$RAIZ/agents/poteto-agent.md" ] || fail "3: falta el agente poteto-agent"
[ -d "$HOME/.agents/skills/babysit" ] && [ ! -L "$HOME/.agents/skills/babysit" ] || fail "3: tocó una skill ajena"
respaldo="$HOME/.agents/.respaldo-pstack"
[ -f "$respaldo/agents-skills/poteto-mode/VIEJO" ] || fail "3: no respaldó la skill vieja"
[ -f "$HOME/.agents/.pstack-oficial-activo" ] || fail "3: no dejó la marca de activa"
[ -L "$HOME/.claude/skills/ajena-borrada" ] || fail "3: borró un enlace roto ajeno"

# 4. repetir activar no cambia nada ni registra enlaces nuevos.
antes=$(wc -l < "$respaldo/creados.txt" | tr -d " ")
bash "$S" activar >/dev/null || fail "4: el segundo activar falló"
[ "$(wc -l < "$respaldo/creados.txt" | tr -d " ")" = "$antes" ] || fail "4: el segundo activar registró enlaces"
[ -f "$respaldo/agents-skills/poteto-mode/VIEJO" ] || fail "4: el segundo activar pisó el respaldo"

# 4b. alguien cambia un enlace nuestro por contenido propio después de activar: la siguiente
# activación lo guarda aparte, no lo borra.
rm "$HOME/.agents/skills/poteto-mode"; mkdir "$HOME/.agents/skills/poteto-mode"; echo mio > "$HOME/.agents/skills/poteto-mode/MIO"
bash "$S" activar >/dev/null || fail "4b: activar falló"
ls "$respaldo"/agents-skills/poteto-mode.*/MIO >/dev/null 2>&1 || fail "4b: borró el contenido propio que reapareció bajo un nombre ya respaldado"
[ -f "$respaldo/agents-skills/poteto-mode/VIEJO" ] || fail "4b: pisó el respaldo original"
[ "$(readlink "$HOME/.agents/skills/poteto-mode")" = "$RAIZ/skills/poteto-mode" ] || fail "4b: no volvió a enlazar"

# 5. una skill que el original retira deja de estar enlazada, salvo los enlaces que ya estaban.
rm -rf "$RAIZ/skills/how" "$RAIZ/skills/tdd"
bash "$S" activar >/dev/null || fail "5: activar falló tras retirar how"
[ -L "$HOME/.agents/skills/how" ] && fail "5: quedó el enlace roto a how en ~/.agents/skills"
[ -L "$HOME/.claude/skills/how" ] && fail "5: quedó el enlace roto a how en ~/.claude/skills"
[ -L "$HOME/.claude/skills/tdd" ] || fail "5: borró el enlace relativo que ya existía antes de activar"
# una sincronización posterior agrega una skill; restaurar también la deshace.
skill "$RAIZ/skills" nueva ""
bash "$S" activar >/dev/null || fail "5: activar falló con la skill nueva"
[ -L "$HOME/.agents/skills/nueva" ] || fail "5: no enlazó la skill nueva"

# 6. restaurar deshace la activación, también los enlaces de skills que no existían antes.
[ -L "$HOME/.agents/skills/deslop" ] || fail "6: activar no había enlazado deslop"
bash "$S" restaurar >/dev/null || fail "6: restaurar falló"
[ -f "$HOME/.agents/skills/poteto-mode/VIEJO" ] || fail "6: no volvió la skill vieja"
[ -e "$HOME/.agents/skills/deslop" ] || [ -L "$HOME/.agents/skills/deslop" ] && fail "6: quedó el enlace nuevo a deslop"
[ -e "$HOME/.claude/agents/poteto-agent.md" ] && fail "6: quedó el agente nuevo enlazado"
[ -L "$HOME/.agents/skills/nueva" ] && fail "6: quedó el enlace de una activación posterior"
[ -d "$respaldo" ] && fail "6: el respaldo no se archivó tras restaurar"
[ "$(readlink "$HOME/.claude/skills/tdd")" = "../../.agents/skills/tdd" ] || fail "6: restaurar tocó un enlace que activar no creó"
[ -f "$HOME/.agents/.pstack-oficial-activo" ] && fail "6: la marca de activa sigue"

# 7. la corrida de launchd: con el árbol roto avisa y sale 1; con el bueno y activa, activa.
echo '#!/bin/sh
printf "%s\n" "$1" >> "'"$T"'/avisos.txt"' > "$T/aviso.sh"; chmod +x "$T/aviso.sh"
PSTACK_AVISO_CMD="$T/aviso.sh" PSTACK_TARBALL="$T/roto.tgz" bash "$S" >/dev/null 2>&1 && fail "7: la corrida con el árbol roto salió 0"
grep -q 'pstack' "$T/avisos.txt" 2>/dev/null || fail "7: la corrida rota no avisó"
touch "$HOME/.agents/.pstack-oficial-activo"
PSTACK_AVISO_CMD="$T/aviso.sh" PSTACK_TARBALL="$T/bueno.tgz" bash "$S" >/dev/null || fail "7: la corrida buena falló"
[ "$(readlink "$HOME/.agents/skills/poteto-mode")" = "$RAIZ/skills/poteto-mode" ] || fail "7: la corrida buena con la marca no activó"
[ "$(wc -l < "$T/avisos.txt" | tr -d " ")" = 1 ] || fail "7: la corrida buena avisó"
# un activar que falla a media corrida (la carpeta de agentes es un archivo) sale 1 y avisa.
rm -rf "$HOME/.claude/agents"; touch "$HOME/.claude/agents"
PSTACK_AVISO_CMD="$T/aviso.sh" PSTACK_TARBALL="$T/bueno.tgz" bash "$S" >/dev/null 2>&1 && fail "7: la corrida con activar roto salió 0"
[ "$(wc -l < "$T/avisos.txt" | tr -d " ")" = 2 ] || fail "7: activar roto no avisó"
rm -f "$HOME/.claude/agents"; mkdir -p "$HOME/.claude/agents"

# 8. el hook de arranque calla sin la marca y da el aviso con ella.
A="$PWD/scripts/mac/pstack-arranque.sh"
rm -f "$HOME/.agents/.pstack-oficial-activo"
[ -z "$(sh "$A")" ] || fail "8: el hook habló sin la copia activa"
touch "$HOME/.agents/.pstack-oficial-activo"
sh "$A" | grep -q 'Invoke the `poteto-mode` skill' || fail "8: el hook no dio el aviso con la copia activa"
sh "$A" | grep -q 'pstack:poteto-mode' && fail "8: el aviso nombra la skill con el prefijo del port"

echo "OK test-sincronizar-pstack"
