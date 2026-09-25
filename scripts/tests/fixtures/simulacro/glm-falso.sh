#!/bin/sh
# glm de mentira para --ensayo (9.9, piezas a y b): pinta su barra ("yolo") y
# sigue vivo. Si le llega una linea por stdin (el encargo del caso 1), imprime
# el contrato "LISTO 0000000" y se queda vivo esperando mas (preflight y
# cerrar matan la sesion de prueba con kill-session; nunca esperan a que el
# binario termine solo). SIM9_GLM_MUDO=1 hace que NUNCA diga LISTO (para
# probar que el caso 1 queda NO FUNCIONA dentro de su tope, sin colgarse).
echo yolo
while IFS= read -r _linea; do
  [ "${SIM9_GLM_MUDO:-0}" = "1" ] || echo "LISTO 0000000"
done
while :; do sleep 3600 2>/dev/null || sleep 60; done
