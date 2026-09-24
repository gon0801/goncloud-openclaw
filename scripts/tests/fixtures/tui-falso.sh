#!/bin/bash
# TUI de mentira (Fase 9, 9.2/9.9): pinta en su STDOUT, con su reloj, el
# contenido actual de pantalla.txt del directorio recibido (o donde arranca) y
# termina la pantalla con la linea TUI-FALSO. Vive hasta que lo maten
# (kill-session); bash 3.2, sin limpieza. 9.9: ademas responde a teclas — el
# read con tope hace de reloj Y de escucha: cada tecla recibida queda en
# teclas.log (epoch y tecla) y, si existe al-aceptar.txt, se copia sobre
# pantalla.txt (asi una corrida de mentira puede "aceptar" un dialogo con un
# Enter, sin teclas de humano).
# El diseno pedia "read -t 0.2" (deja el reloj original de sleep 0.2 en el
# tope de espera): el /bin/bash 3.2.57 de macOS que corre este binario
# (bash 3.2, arriba) rechaza un tope con decimales ("invalid timeout
# specification", medido). Se resuelve con un tope entero de 1s: sigue sin
# teclas de humano y con margen de sobra contra los topes de 5-10s del
# --ensayo (9.9); solo cambia el peor caso de latencia de una tecla, de 0.2s a 1s.
D="${1:-$PWD}"
while :; do
  k=""
  if read -rs -t 1 -n1 k; then
    printf '%s %s\n' "$(date +%s)" "$k" >> "$D/teclas.log"
    [ -f "$D/al-aceptar.txt" ] && cp "$D/al-aceptar.txt" "$D/pantalla.txt"
  fi
  printf '\033[H\033[2J'
  [ -f "$D/pantalla.txt" ] && cat "$D/pantalla.txt"
  printf 'TUI-FALSO\n'
done
