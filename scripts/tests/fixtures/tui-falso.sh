#!/bin/bash
# TUI de mentira (Fase 9, 9.2): repinta pantalla.txt cada 0.2 s en el directorio que
# recibe (o donde arranca) y termina la pantalla con la linea TUI-FALSO. Bash 3.2.
D="${1:-$PWD}"
i=0
while [ "$i" -lt 5 ]; do
  printf 'trabajando %s\n' "$i" > "$D/pantalla.txt"
  sleep 0.2
  i=$((i + 1))
done
printf 'trabajando\nTUI-FALSO\n' > "$D/pantalla.txt"
