#!/bin/sh
# glm de mentira para --ensayo (9.9, pieza a): solo lo que preflight.sh
# necesita para probar la fila "glm" de la tabla de modos — pintar su barra
# ("yolo") y seguir vivo hasta que lo maten (preflight y lanzar-sesion matan
# la sesion de prueba con kill-session, nunca esperan a que el binario
# termine solo).
echo yolo
while :; do sleep 3600 2>/dev/null || sleep 60; done
