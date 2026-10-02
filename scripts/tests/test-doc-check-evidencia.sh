#!/usr/bin/env bash
# Repro local del paso "Checks documentales del rango" (doc-check) de
# .github/workflows/quality.yml: todo archivo cambiado en el rango
# merge-base(origin/main, <head>)..<head> que haga match con
# docs/evidence/*.md|docs/evidence/*.txt debe ser no vacio y su primera linea
# debe arrancar con "# ". Sale 1 nombrando cada archivo fuera de contrato.
# Sin argumentos evalua HEAD. Con un commit como argumento evalua ese head:
# sirve para reproducir el rojo historico (19e3ee3, antes de los titulos) y
# para mutaciones sobre commits efimeros sin mover la rama.
# Recorre TODO el rango, no una lista fija, para que ninguna evidencia nueva
# quede fuera del chequeo.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

hs=${1:-HEAD}
mb=$(git merge-base origin/main "$hs")
rc=0
n=0
while IFS= read -r -d '' f; do
  n=$((n + 1))
  case $f in
    docs/evidence/*.md|docs/evidence/*.txt)
      if [ "$(git cat-file -s "$hs:$f")" -eq 0 ]; then
        echo "doc-check-repro: $f esta vacio" >&2
        rc=1
        continue
      fi
      # sed y no head: git show | head cierra la tuberia al imprimir la
      # primera linea y con pipefail el SIGPIPE mata el paso con evidencia
      # valida; sed consume toda la entrada (mismo motivo que el paso de CI).
      primera=$(git show "$hs:$f" | sed -n '1p')
      case $primera in
        '# '*) ;;
        *)
          echo "doc-check-repro: $f no arranca con titulo '# '" >&2
          rc=1
          ;;
      esac ;;
  esac
done < <(git -c core.quotepath=false diff --name-only --diff-filter=d -z "$mb" "$hs")

if [ "$rc" -ne 0 ]; then
  echo "doc-check-repro: RECHAZADO ($n archivo(s) en el rango)" >&2
  exit 1
fi
echo "doc-check-repro: OK ($n archivo(s) en el rango)"
