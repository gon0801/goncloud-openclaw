#!/usr/bin/env bash
# Contrato del vigia v3: pendiente vs deployado (Fase 16.3, Task 4).
#
# v2 avisaba " SKILLS " como hecho consumado ("Ya esta en main"). En v3 el
# sync ya no commitea skills: captura a PR (SKILLS_PR) y deploya al mergear
# (SKILLS_DEPLOYED). El vigia reporta el pendiente UNA vez, y al llegar su
# SKILLS_DEPLOYED reporta el deploy UNA vez y salda el pendiente. La salud
# se lee solo del ultimo ciclo completo; FALLO, CONFLICTO y el marcador
# final se preservan; el vigia sigue siendo solo-lectura.
#
# Uso: bash scripts/tests/test-vigia-sync-v3.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }

V3=docs/cron-messages/verif-sync-repos.v3.txt
MD=docs/crons/verif-sync-repos.md
APL=docs/cron-messages/APLICAR_VIGIA_SYNC.sh
ASSERT=scripts/tests/vigia_sync_prueba_assert.py

# (0) Existe, ASCII, LOG= primero, sin sustitucion de comandos.
[ -f "$V3" ] || fail "(0) falta $V3"
python3 - "$V3" <<'PY' || exit 1
import sys
m = open(sys.argv[1], encoding="utf-8").read()
body = m.rstrip("\n")
def fail(x):
    print("ROJO: (0) " + x)
    sys.exit(1)
bad = [c for c in body if ord(c) > 127]
if bad:
    fail("no-ASCII: %r" % bad[:5])
if "$(" in body or "`" in body:
    fail("command substitution / backticks")
if not body.startswith("LOG="):
    fail("LOG= debe ser la primera linea")
PY
echo "ok (0): v3 existe, ASCII, LOG= primero"

# (1) Pendiente: SKILLS_PR se avisa una vez con marcador P.
for a in 'SKILLS_PR' 'pendiente' 'P|' 'VIGIA SYNC PENDIENTE' 'Todavia no esta en el gateway'; do
  grep -qF "$a" "$V3" || fail "(1) falta ancla de pendiente: $a"
done
grep -qE 'una (sola )?vez' "$V3" || fail "(1) sin 'una (sola) vez' para el pendiente"
echo "ok (1): SKILLS_PR pendiente una vez con marcador P"

# (2) Deployado: SKILLS_DEPLOYED se avisa una vez, salda el pendiente.
for a in 'SKILLS_DEPLOYED' 'E|' 'VIGIA SYNC DEPLOYED' 'Ya esta en el gateway'; do
  grep -qF "$a" "$V3" || fail "(2) falta ancla de deployado: $a"
done
grep -qE 'sald' "$V3" || fail "(2) sin regla de saldar el pendiente"
echo "ok (2): SKILLS_DEPLOYED deployado una vez, salda pendiente"

# (3) Salud solo del ultimo ciclo; FALLO/CONFLICTO/marcador se preservan.
for a in 'ULTIMO ciclo' 'FALLO' 'CONFLICTO' '---- ciclo terminado' 'tail -400 de la ruta LOG=' 'la misma ventana'; do
  grep -qF -- "$a" "$V3" || fail "(3) falta ancla de salud: $a"
done
echo "ok (3): salud del ultimo ciclo, FALLO/CONFLICTO/marcador"

# (4) Solo-lectura: NUNCA + verbos git.
grep -q 'NUNCA' "$V3" || fail "(4) sin NUNCA"
for v in 'pull' 'push' 'commit' 'checkout' 'reset'; do
  grep -q "$v" "$V3" || fail "(4) sin verbo prohibido: $v"
done
echo "ok (4): vigia solo-lectura"

# (5) El flujo viejo murio en v3: sin token SKILLS-espaciado ni cierre v2.
grep -q ' SKILLS ' "$V3" && fail "(5) v3 trae el token viejo ' SKILLS '"
grep -q 'Ya esta en main' "$V3" && fail "(5) v3 trae el cierre viejo 'Ya esta en main'"
grep -q "' SKILLS '" "$APL" && fail "(5) el aplicador aun filtra ' SKILLS '"
echo "ok (5): flujo v2 muerto en v3 y aplicador"

# (6) El aplicador apunta a v3 con recorrido D1/D2/D3.
grep -q 'verif-sync-repos.v3.txt' "$APL" || fail "(6) aplicador no apunta a v3.txt"
grep -q 'VIGIA SYNC REPOS v3' "$APL" || fail "(6) aplicador sin ancla v3"
grep -q 'SKILLS_PR' "$APL" || fail "(6) aplicador sin SKILLS_PR"
grep -q 'escribir_log_prueba 1 D1' "$APL" || fail "(6) falta escribir_log_prueba 1 D1"
grep -q 'escribir_log_prueba 0 D2' "$APL" || fail "(6) falta escribir_log_prueba 0 D2"
grep -q 'escribir_log_prueba 2 D3' "$APL" || fail "(6) falta escribir_log_prueba 2 D3"
grep -q 'assert-d3' "$APL" || fail "(6) falta assert-d3 en aplicador"
grep -q 'assert-d3' "$ASSERT" || fail "(6) falta assert-d3 en asertor"
grep -q 'VIGIA SYNC REPOS v3' "$MD" || fail "(6) docs/crons aun en v2"
echo "ok (6): aplicador + asertor + docs en v3 con D3"

echo "TODO VERDE: vigia-sync-v3"
