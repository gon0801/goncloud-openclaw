#!/bin/bash
# TUI de mentira (Fase 9, 9.2/9.9): pinta en su STDOUT, con su reloj, el
# contenido actual de pantalla.txt del directorio recibido (o donde arranca) y
# termina la pantalla con la linea TUI-FALSO. Vive hasta que lo maten
# (kill-session); bash 3.2, sin limpieza. 9.9: ademas responde a teclas — el
# read con tope hace de reloj Y de escucha: cada tecla recibida SIEMPRE queda
# en teclas.log (epoch y tecla), pero solo Enter "acepta" (copia al-aceptar.txt
# sobre pantalla.txt) y solo Escape "cancela" (copia al-cancelar.txt, si
# existe); cualquier otra tecla no cambia la pantalla. Sin distinguir la tecla,
# un Esc por error se veria como un "acepta" (FUNCIONA falso). Con `read -n1`,
# tmux send-keys Enter llega como cadena vacia (el CR que tmux manda se pierde
# como delimitador de read, medido con tmux real) y Escape llega como el byte
# ESC ($'\e', tambien medido con tmux real): son los dos valores que se
# distinguen, nunca "cualquier tecla".
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
    case "$k" in
      '') [ -f "$D/al-aceptar.txt" ] && cp "$D/al-aceptar.txt" "$D/pantalla.txt";;
      $'\e') [ -f "$D/al-cancelar.txt" ] && cp "$D/al-cancelar.txt" "$D/pantalla.txt";;
    esac
  fi
  printf '\033[H\033[2J'
  [ -f "$D/pantalla.txt" ] && cat "$D/pantalla.txt"
  printf 'TUI-FALSO\n'
done
