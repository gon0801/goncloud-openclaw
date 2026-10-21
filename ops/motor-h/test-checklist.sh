#!/usr/bin/env bash
# H.5: prueba ops/motor-h/checklist.sh con un ssh falso (sin red ni Mini).
# Casos: (1) todo en orden -> 0; (2) ssh caído -> !=0; (3) health != ok -> !=0;
# (4) sin skill motor -> !=0; (5) con crons *-vigia -> !=0; (6) cron list
# ilegible (-1) -> !=0; (7) prompt-claw presente -> !=0; (8) respuesta sin
# claves -> !=0. Cada caso negativo exige además el mensaje de su causa.
# Uso: bash ops/motor-h/test-checklist.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "ROJO: $1"; exit 1; }
export FAKE_MINI="$T/mini"
mkdir -p "$FAKE_MINI"

cat > "$T/ssh" <<'EOS'
#!/usr/bin/env bash
# ssh falso: traga el script remoto por stdin y responde desde $FAKE_MINI/respuesta.
while [ $# -gt 1 ]; do shift; done
cat > /dev/null
[ -f "$FAKE_MINI/caido" ] && exit 255
cat "$FAKE_MINI/respuesta" 2>/dev/null
exit 0
EOS
chmod +x "$T/ssh"

bien() {
  rm -f "$FAKE_MINI/caido"
  printf 'HEALTH_OK=1\nMOTOR_SKILL=1\nVIGIA_CRONS=0\n' > "$FAKE_MINI/respuesta"
}

corre() { # <home> -> exit code del checklist
  HOME="$1" MOTOR_H_SSH="$T/ssh" MOTOR_H_MINI=falso bash ops/motor-h/checklist.sh > "$T/out" 2>&1
}

HOME_OK="$T/home-ok"
mkdir -p "$HOME_OK"

# (1) todo en orden
bien
corre "$HOME_OK" || fail "(1) con todo en orden el checklist no salió 0: $(cat "$T/out")"
grep -q "VERDE" "$T/out" || fail "(1) sin línea VERDE: $(cat "$T/out")"
echo "ok (1): checklist en verde cuando claw responde, tiene motor, sin vigia ni prompt-claw"

# (2) ssh caído
bien; touch "$FAKE_MINI/caido"
corre "$HOME_OK" && fail "(2) con ssh caído el checklist salió 0"
grep -q "ssh a la Mini falló" "$T/out" || fail "(2) no nombra la causa ssh: $(cat "$T/out")"
echo "ok (2): ssh caído -> !=0 y nombra el ssh"

# (3) claw no responde
bien
printf 'HEALTH_OK=0\nMOTOR_SKILL=1\nVIGIA_CRONS=0\n' > "$FAKE_MINI/respuesta"
corre "$HOME_OK" && fail "(3) con health != ok el checklist salió 0"
grep -q "claw no responde" "$T/out" || fail "(3) no nombra health: $(cat "$T/out")"
echo "ok (3): health != ok -> !=0"

# (4) sin la skill motor
bien
printf 'HEALTH_OK=1\nMOTOR_SKILL=0\nVIGIA_CRONS=0\n' > "$FAKE_MINI/respuesta"
corre "$HOME_OK" && fail "(4) sin la skill motor el checklist salió 0"
grep -q "skill motor" "$T/out" || fail "(4) no nombra la skill: $(cat "$T/out")"
echo "ok (4): sin skill motor -> !=0"

# (5) quedan crons *-vigia
bien
printf 'HEALTH_OK=1\nMOTOR_SKILL=1\nVIGIA_CRONS=2\n' > "$FAKE_MINI/respuesta"
corre "$HOME_OK" && fail "(5) con crons *-vigia el checklist salió 0"
grep -q "crons \*-vigia" "$T/out" || fail "(5) no nombra los crons: $(cat "$T/out")"
echo "ok (5): con crons *-vigia -> !=0"

# (6) cron list ilegible: sin fall-open
bien
printf 'HEALTH_OK=1\nMOTOR_SKILL=1\nVIGIA_CRONS=-1\n' > "$FAKE_MINI/respuesta"
corre "$HOME_OK" && fail "(6) con cron list ilegible el checklist salió 0 (fall-open)"
echo "ok (6): VIGIA_CRONS=-1 -> !=0 (no fall-open)"

# (7) prompt-claw sigue en la Mac
bien
HOME_MAL="$T/home-mal"
mkdir -p "$HOME_MAL/.claude/skills/prompt-claw"
corre "$HOME_MAL" && fail "(7) con prompt-claw presente el checklist salió 0"
grep -q "prompt-claw" "$T/out" || fail "(7) no nombra prompt-claw: $(cat "$T/out")"
echo "ok (7): prompt-claw presente -> !=0"

# (8) respuesta sin las claves (ssh falso o gateway a medias)
: > "$FAKE_MINI/respuesta"
corre "$HOME_OK" && fail "(8) con respuesta vacía el checklist salió 0"
echo "ok (8): respuesta sin claves -> !=0"

echo "VERDE: checklist.sh discrimina los ocho casos"
