#!/bin/bash
# Filas del ledger de Plans.md que un diff agrega, una por linea en stdin (sin
# el '+' del diff). La forma | <n>.<n>[letra] | ... | ... | ... | cc:... | exige
# exactamente 5 columnas. El id admite una letra final (14.13a) igual que
# arranque-de-fase.sh y cierre-de-fase.sh; sin ella esas filas no se revisaban.
rc=0
while IFS= read -r cuerpo; do
  if printf '%s\n' "$cuerpo" | grep -Eq '^\|[[:space:]]*[0-9]+\.[0-9]+[a-z]?[[:space:]]*\|'; then
    if ! printf '%s\n' "$cuerpo" | grep -Eq '^\|[[:space:]]*[0-9]+\.[0-9]+[a-z]?[[:space:]]*\|[^|]*\|[^|]*\|[^|]*\|[^|]*\|[[:space:]]*$'; then
      printf 'doc-check: Plans.md fila tocada sin 5 columnas: %s\n' "$cuerpo" >&2
      rc=1
    fi
  fi
done
exit "$rc"
