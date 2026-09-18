#!/bin/bash
# TUI de mentira (Fase 9, 9.2): pinta en su STDOUT, cada ~0.2 s, el contenido actual
# de pantalla.txt del directorio recibido (o donde arranca) y termina la pantalla con
# la linea TUI-FALSO. Vive hasta que lo maten (kill-session); bash 3.2, sin limpieza.
D="${1:-$PWD}"
while :; do
  printf '\033[H\033[2J'
  [ -f "$D/pantalla.txt" ] && cat "$D/pantalla.txt"
  printf 'TUI-FALSO\n'
  sleep 0.2
done
