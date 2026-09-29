#!/bin/bash
# Responde el dialogo de confianza de carpeta del arnes 19.0, con los mismos
# fragmentos y teclas que adaptador_confianza_responder (medidos 2026-09-28).
# Solo acepta si la pantalla imprime el worktree del arnes en una linea propia.
# Corre en carrera con la espera de barra de lanzar-sesion; si no hay dialogo,
# sale 1 sin tocar nada.
set -u
BINARIO=$1 SESION=$2 WT=$3
t() { /opt/homebrew/bin/tmux -L "${ARNES_SOCKET:?ARNES_SOCKET requerido}" "$@"; }
case "$BINARIO" in
  claude) FRAGS=('Accessing workspace:' 'Yes, I trust this folder'); TECLAS=(Down Enter);;
  codex)  FRAGS=('Folder access' 'Trust this folder?' 'Trust and continue'); TECLAS=(Enter);;
  kimi)   FRAGS=('Trust this folder?' "Don't trust"); TECLAS=(Enter);;
  *) exit 1;;
esac
pant="$(t capture-pane -p -J -t "=$SESION:" 2>/dev/null)" || exit 1
for f in "${FRAGS[@]}"; do printf '%s' "$pant" | grep -qF -- "$f" || exit 1; done
canon="$(CDPATH= cd -P -- "$WT" 2>/dev/null && pwd)" || exit 1
ok=""
while IFS= read -r l; do
  l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
  if [ "$l" = "$WT" ] || [ "$l" = "$canon" ]; then ok=1; break; fi
done <<EOF
$pant
EOF
[ -n "$ok" ] || exit 1
for k in "${TECLAS[@]}"; do t send-keys -t "=$SESION:" "$k" 2>/dev/null || exit 1; done
echo "confianza respondida para $BINARIO ($WT)" >&2
exit 0
