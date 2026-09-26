#!/bin/bash
# Respaldo de workspaces (scripts/mac/respaldo-workspaces.sh): conducta real contra
# remotos bare de juguete y una fuente local en lugar del SSH.
#
#   1. Primera corrida: cada repo recibe respaldo/runtime; master no se toca.
#   2. La rama es espejo exacto del vivo: sin .git vivo, sin lo que ya no existe.
#   3. Segunda corrida sin cambios: cero commits nuevos.
#   4. Un cambio en el vivo: commit nuevo en la rama; master sigue igual.
#   5. Un workspace que no llegó entero: falla y su respaldo no se borra.
#   6. Una rama que no es respaldo/*: se rechaza antes de tocar nada.
#   7. Archivos enormes: se omiten, no rompen el push.
#   8. Nunca --force; por SSH solo `tar -c`; el plist es válido y apunta al script;
#      el remoto por defecto es HTTPS (launchd no tiene agente SSH con llaves).
#   9-12. Lock huérfano se recupera, lock vivo se respeta, config SSH ilegible aborta,
#         un PID reusado por otro proceso no retiene el lock.
#
# Uso: bash scripts/tests/test-respaldo-workspaces.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"
S="$REPO/scripts/mac/respaldo-workspaces.sh"
P="$REPO/scripts/mac/ai.goncloud.respaldo-workspaces.plist"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export GIT_CONFIG_GLOBAL="$SB/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name prueba; git config --global user.email prueba@example.invalid
git config --global init.defaultBranch master

# Remotos bare con un master que trae un archivo que el vivo ya no tiene.
for r in goncloud-workspace-main goncloud-workspace-operaciones goncloud-workspace-ingenieria; do
  git init -q --bare "$SB/remotos/$r.git"
  w="$SB/semilla-$r"; git init -q "$w"
  printf 'viejo\n' > "$w/viejo.md"; printf 'id viejo\n' > "$w/IDENTITY.md"
  git -C "$w" add . && git -C "$w" commit -qm semilla && git -C "$w" push -q "$SB/remotos/$r.git" HEAD:master
done
master_sha() { git -C "$SB/remotos/$1.git" rev-parse master; }
rama_sha() { git -C "$SB/remotos/$1.git" rev-parse -q --verify refs/heads/respaldo/runtime; }
rama_arbol() { git -C "$SB/remotos/$1.git" ls-tree -r --name-only respaldo/runtime | LC_ALL=C sort | tr '\n' ' '; }
M0="$(master_sha goncloud-workspace-main)"

# Fuente viva de juguete.
F="$SB/vivo"
for ws in workspace workspace-operaciones workspace-ingenieria; do
  mkdir -p "$F/$ws/memory" "$F/$ws/.git"
  printf 'id %s\n' "$ws" > "$F/$ws/IDENTITY.md"
  printf 'nota\n' > "$F/$ws/memory/2026-09-24.md"
  printf 'x\n' > "$F/$ws/.git/config"
done

correr() {
  RESPALDO_DIR="$SB/clones" RESPALDO_FUENTE="$F" RESPALDO_REMOTO_BASE="$SB/remotos" \
    RESPALDO_MAX_MB=1 "$@" bash "$S" > "$SB/salida" 2>&1
}

# 1 y 2
correr env || { cat "$SB/salida"; fail "la primera corrida falló"; }
for r in goncloud-workspace-main goncloud-workspace-operaciones goncloud-workspace-ingenieria; do
  rama_sha "$r" >/dev/null || fail "$r: no se creó respaldo/runtime"
  [ "$(rama_arbol "$r")" = "IDENTITY.md memory/2026-09-24.md " ] \
    || fail "$r: la rama no es espejo del vivo: [$(rama_arbol "$r")]"
done
[ "$(master_sha goncloud-workspace-main)" = "$M0" ] || fail "master cambió"

# 3
R1="$(rama_sha goncloud-workspace-main)"
correr env || fail "la segunda corrida falló"
[ "$(rama_sha goncloud-workspace-main)" = "$R1" ] || fail "una corrida sin cambios creó un commit"
grep -q "sin cambios" "$SB/salida" || fail "la corrida sin cambios no lo reportó"

# 4
printf 'nota nueva\n' > "$F/workspace/memory/2026-09-25.md"
correr env || fail "la corrida con cambio falló"
[ "$(rama_sha goncloud-workspace-main)" != "$R1" ] || fail "un cambio vivo no generó commit"
git -C "$SB/remotos/goncloud-workspace-main.git" merge-base --is-ancestor "$R1" respaldo/runtime \
  || fail "el respaldo reescribió historia (no es fast-forward)"
[ "$(master_sha goncloud-workspace-main)" = "$M0" ] || fail "master cambió tras un cambio vivo"

# 5
RI="$(rama_sha goncloud-workspace-ingenieria)"
rm -f "$F/workspace-ingenieria/IDENTITY.md"
correr env && fail "un workspace incompleto no hizo fallar la corrida"
grep -q "goncloud-workspace-ingenieria: FALLA" "$SB/salida" || fail "no nombró el repo incompleto"
[ "$(rama_sha goncloud-workspace-ingenieria)" = "$RI" ] || fail "se tocó el respaldo del workspace incompleto"
printf 'id\n' > "$F/workspace-ingenieria/IDENTITY.md"

# 6
correr env RESPALDO_RAMA=master && fail "aceptó empujar a master"
[ "$(master_sha goncloud-workspace-main)" = "$M0" ] || fail "master cambió con RESPALDO_RAMA=master"

# 7
dd if=/dev/zero of="$F/workspace/grande.bin" bs=1024 count=2048 2>/dev/null
correr env || { cat "$SB/salida"; fail "un archivo enorme rompió la corrida"; }
grep -q "omitido por tamaño" "$SB/salida" || fail "no reportó el archivo enorme"
git -C "$SB/remotos/goncloud-workspace-main.git" ls-tree -r --name-only respaldo/runtime | grep -qx grande.bin \
  && fail "el archivo enorme llegó al respaldo"

# 9. Lock huérfano (dueño muerto): se recupera y el respaldo corre.
mkdir -p "$SB/clones/.lock"; echo "999999 Thu 1 Jan 00:00:00 1970" > "$SB/clones/.lock/dueno"
correr env || { cat "$SB/salida"; fail "un lock huérfano detuvo el respaldo"; }
grep -q "lock huérfano" "$SB/salida" || fail "no reportó la recuperación del lock huérfano"
[ -e "$SB/clones/.lock" ] && fail "el lock quedó tomado al terminar"

# 10. Lock con dueño vivo: se respeta y no se toca.
yo="$$ $(ps -o lstart= -p $$ | tr -s ' ')"
mkdir -p "$SB/clones/.lock"; printf '%s' "$yo" > "$SB/clones/.lock/dueno"
correr env; rc=$?
[ "$rc" -eq 3 ] || fail "con el lock de un proceso vivo no salió con 3 (rc=$rc)"
[ "$(cat "$SB/clones/.lock/dueno")" = "$yo" ] || fail "se robó el lock de un proceso vivo"
rm -rf "$SB/clones/.lock"

# 11. Config de SSH ilegible: aborta nombrando la causa, sin intentar SSH.
mkdir -p "$SB/home/.openclaw"; printf '{ gateway: {} }\n' > "$SB/home/.openclaw/openclaw.json"
printf '#!/bin/sh\nexit 1\n' > "$SB/oc-roto"; chmod +x "$SB/oc-roto"
OPENCLAW_BIN="$SB/oc-roto" RESPALDO_DIR="$SB/clones" RESPALDO_FUENTE=ssh bash "$S" > "$SB/salida" 2>&1; rc=$?
[ "$rc" -eq 4 ] || fail "config ilegible no salió con 4 (rc=$rc)"
grep -q "no se pudo leer gateway.remote" "$SB/salida" || fail "config ilegible sin causa nombrada"
grep -q "no se pudo copiar" "$SB/salida" && fail "con la config ilegible igual intentó SSH"

# 12. PID reusado: el PID del lock existe (es este shell) pero con otra hora de
#     inicio, así que es otro proceso y el lock se recupera.
mkdir -p "$SB/clones/.lock"; echo "$$ Thu 1 Jan 00:00:00 1970" > "$SB/clones/.lock/dueno"
correr env || { cat "$SB/salida"; fail "un PID reusado retuvo el lock"; }
grep -q "lock huérfano" "$SB/salida" || fail "no trató el PID reusado como huérfano"

# 8
grep -vE '^[[:space:]]*#' "$S" | grep -nE -- '--force|push -f|\+HEAD:|\+refs/' && fail "el respaldo puede forzar un push"
ssh_cmd="$(grep -E '^[[:space:]]*"\$SSH_TARGET"' "$S")"
case "$ssh_cmd" in *'"tar -cf - -C'*) ;; *) fail "por SSH corre algo que no es tar -c: [$ssh_cmd]" ;; esac
grep -q 'RESPALDO_REMOTO_BASE:-https://github.com/' "$S" \
  || fail "el remoto por defecto no es HTTPS (bajo launchd no hay agente SSH con llaves)"
python3 - "$P" <<'E' || fail "plist inválido o no apunta al script"
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
assert d['Label']=='ai.goncloud.respaldo-workspaces'
assert d['ProgramArguments'][-1].endswith('/respaldo-workspaces.sh')
assert d['StartCalendarInterval']['Hour']==4 and not d.get('KeepAlive')
E

echo "ok: respaldo de workspaces de un solo sentido, espejo, idempotente, sin tocar master"
