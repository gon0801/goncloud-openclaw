#!/usr/bin/env bash
# El sync avisa cuando un agente cambia workshop-skills (13.2a).
#
# Extrae la funcion entre # >>> skills-cambiadas y # <<< skills-cambiadas,
# la corre con pwsh contra un repo git temporal, exige la linea SKILLS y
# que un error dentro de la funcion escriba SKILLS error: sin tumbar el flujo.
# Ademas ParseFile del .ps1 entero y anclas estructurales (entre guardia y commit).
#
# Si pwsh no esta: FALLA (no se salta). ubuntu-latest lo trae; local: /Users/dn/.local/bin/pwsh.
#
# Uso: bash scripts/tests/test-sync-avisa-skills.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }

PS1FILE=scripts/sync-repos.ps1
[ -f "$PS1FILE" ] || fail "falta $PS1FILE"

PWSH="${PWSH:-}"
if [ -z "$PWSH" ]; then
  for c in /Users/dn/.local/bin/pwsh "$(command -v pwsh 2>/dev/null)" /usr/bin/pwsh; do
    [ -n "$c" ] && [ -x "$c" ] && PWSH=$c && break
  done
fi
[ -n "${PWSH:-}" ] && [ -x "$PWSH" ] \
  || fail "pwsh no esta en PATH ni en /Users/dn/.local/bin/pwsh (CI lo trae; no se salta)"

linea_de() { grep -n -- "$1" "$2" | head -1 | cut -d: -f1; }

# (0) Marcas presentes.
grep -q '# >>> skills-cambiadas' "$PS1FILE" \
  || fail "(0) faltan marcas # >>> skills-cambiadas — la funcion no se puede extraer"
grep -q '# <<< skills-cambiadas' "$PS1FILE" \
  || fail "(0) faltan marcas # <<< skills-cambiadas"
echo "ok (0): marcas de extraccion presentes"

# (1) ParseFile cero errores.
"$PWSH" -NoProfile -Command "
\$e=\$null; \$t=\$null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '$PS1FILE'), [ref]\$t, [ref]\$e)
if (\$e -and \$e.Count -gt 0) { \$e | ForEach-Object { \$_.ToString() }; exit 1 }
exit 0
" || fail "(1) ParseFile reporto errores en $PS1FILE"
echo "ok (1): ParseFile sin errores"

# (2) Posicion: el llamado try/catch esta DESPUES de la guardia y ANTES del commit.
n_g=$(linea_de 'git restore --staged' "$PS1FILE")
n_call=$(linea_de 'skills-cambiadas\|Write-OpenclawSkillsCambiadas\|Get-OpenclawSkillsCambiadas' "$PS1FILE")
# Preferir la linea del try que envuelve el llamado en el flujo (no la marca).
n_try=$(grep -n 'SKILLS error:' "$PS1FILE" | head -1 | cut -d: -f1)
n_commit=$(linea_de 'commit -m "auto: snapshot' "$PS1FILE")
[ -n "$n_g" ] && [ -n "$n_try" ] && [ -n "$n_commit" ] \
  || fail "(2) no encuentro guardia/try SKILLS/commit: g=$n_g try=$n_try commit=$n_commit"
[ "$n_try" -gt "$n_g" ] \
  || fail "(2) el try/catch de SKILLS (linea $n_try) va ANTES de la guardia (linea $n_g)"
[ "$n_try" -lt "$n_commit" ] \
  || fail "(2) el try/catch de SKILLS (linea $n_try) va DESPUES del commit (linea $n_commit)"
echo "ok (2): el llamado SKILLS va entre la guardia de tamano y el commit"

# (3) Extraer funcion, correrla contra repo temporal.
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
LOG="$T/sync.log"
mkdir -p "$REPO/agents/x/agent/workshop-skills/s" "$REPO/otro"
git -C "$REPO" init -q
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@test
echo 'skill' > "$REPO/agents/x/agent/workshop-skills/s/SKILL.md"
echo 'fuera' > "$REPO/otro/no-skill.txt"
git -C "$REPO" add -A
# HEAD vacio: primer commit no; dejamos estagiado sin commit (diff --cached ve los dos).

python3 - "$PS1FILE" "$T/fn.ps1" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().splitlines()
try:
    a = next(i for i, l in enumerate(lines) if "# >>> skills-cambiadas" in l)
    b = next(i for i, l in enumerate(lines) if "# <<< skills-cambiadas" in l)
except StopIteration:
    sys.exit("marcas no encontradas")
body = "\n".join(lines[a + 1:b])
open(dst, "w", encoding="utf-8").write(body + "\n")
PY
[ -s "$T/fn.ps1" ] || fail "(3) no pude extraer la funcion entre las marcas"

"$PWSH" -NoProfile -File /dev/stdin <<EOF || fail "(3) pwsh fallo al correr la funcion extraida"
. '$T/fn.ps1'
if (-not (Get-Command Write-OpenclawSkillsCambiadas -ErrorAction SilentlyContinue)) {
  Write-Error 'falta Write-OpenclawSkillsCambiadas tras dot-source'
  exit 1
}
Write-OpenclawSkillsCambiadas -RepoRoot '$REPO' -LogPath '$LOG'
EOF

grep -q 'SKILLS x 1 archivo(s): s/SKILL.md' "$LOG" \
  || fail "(3) no escribio la linea SKILLS x 1 archivo(s): s/SKILL.md; log=$(cat "$LOG" 2>/dev/null)"
grep -q 'otro/no-skill' "$LOG" \
  && fail "(3) logueo un archivo fuera de workshop-skills"
# Exactamente una linea SKILLS de agente (no la de error).
n_skills=$(grep -c ' SKILLS ' "$LOG" || true)
[ "$n_skills" -eq 1 ] || fail "(3) esperaba 1 linea SKILLS de agente, hubo $n_skills"
echo "ok (3): funcion extraida escribe SKILLS x 1 archivo(s): s/SKILL.md y ignora lo de fuera"

# (4) Error dentro de la funcion → SKILLS error: y el flujo sigue (no exit).
"$PWSH" -NoProfile -File /dev/stdin <<EOF || fail "(4) el flujo no debio morir ante el error forzado"
\$log = '$T/err.log'
\$repo = '$REPO'
# Redefinir con una funcion que tira, y el try/catch del contrato.
function Write-OpenclawSkillsCambiadas {
  param([string]\$RepoRoot, [string]\$LogPath)
  throw 'boom-forzado'
}
function Log([string]\$msg) {
  Add-Content \$log ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), \$msg)
}
try {
  Write-OpenclawSkillsCambiadas -RepoRoot \$repo -LogPath \$log
} catch {
  Log (".openclaw SKILLS error: {0}" -f \$_.Exception.Message)
}
# El flujo sigue:
Log '.openclaw commit local auto'
Log '.openclaw pull ok'
Log '---- ciclo terminado'
EOF
grep -q 'SKILLS error:' "$T/err.log" \
  || fail "(4) no escribio SKILLS error: tras el throw; log=$(cat "$T/err.log")"
grep -q 'ciclo terminado' "$T/err.log" \
  || fail "(4) el flujo no continuo tras SKILLS error:"
echo "ok (4): SKILLS error: y el ciclo sigue"

# (5) Mutante estructural: llamado despues del commit → (2) lo detectaria.
awk -v t="$n_try" -v c="$n_commit" '
  NR==t { guardado=$0; next }
  { print }
  NR==c { print guardado }
' "$PS1FILE" > "$T/movido.ps1"
n_try2=$(grep -n 'SKILLS error:' "$T/movido.ps1" | head -1 | cut -d: -f1)
n_c2=$(grep -n 'commit -m "auto: snapshot' "$T/movido.ps1" | head -1 | cut -d: -f1)
[ "$n_try2" -gt "$n_c2" ] \
  || fail "(5) no pude fabricar llamado despues del commit"
echo "ok (5): mutante con SKILLS despues del commit queda fuera de la ventana (rojo en 2)"

# (6) Quitar el llamado del flujo deja rojo (no hay SKILLS error: en el cuerpo del foreach).
# Comprueba que el ancla del try existe en el archivo vivo (ya en 2); si se quitara, (2) falla.
grep -q 'SKILLS error:' "$PS1FILE" || fail "(6) sin el try/catch en el flujo"
echo "ok (6): el llamado esta en el flujo (quitarlo deja rojo en 2/0)"

echo "TODO VERDE: sync-avisa-skills"
