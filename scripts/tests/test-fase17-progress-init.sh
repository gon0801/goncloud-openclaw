#!/usr/bin/env bash
# El arranque de Fase 17 no debe publicar progreso si la ruta local es insegura.
set -u
cd "$(dirname "$0")/../.." || exit 1
runbook=docs/runbooks/autopilot-fase17.md
tmp_progress=$(mktemp -d) || exit 1
trap 'rm -r "$tmp_progress"' EXIT
ln -s ruta-no-confiable "$tmp_progress/.saikit" || exit 1

out=$(
  {
    awk '/^python3 - <<.PY./{capture=1} capture {print; if ($0=="PY") exit}' "$runbook"
    printf '%s\n' 'printf "GATEWAY_INVOCADO\\n"'
  } | (cd "$tmp_progress" && bash) 2>&1
  )
rc=$?
[ "$rc" -ne 0 ] || { printf 'FAIL: el bloque continuó tras rechazar la ruta\n' >&2; exit 1; }
case "$out" in
  *'ATORADO ruta de progreso enlazada'*) : ;;
  *) printf 'FAIL: no explicó la ruta insegura: %s\n' "$out" >&2; exit 1 ;;
esac
case "$out" in
  *GATEWAY_INVOCADO*) printf 'FAIL: siguió hasta la publicación\n' >&2; exit 1 ;;
esac
printf 'VERDE: una ruta de progreso insegura detiene el arranque\n'
