# Merge y despliegue

Cualquier agente puede usar `gh pr merge <PR> --squash --match-head-commit <SHA>` después de CI y CodeRabbit aprobados, sin permiso adicional, leyendo los bots y los checks a mano (este repo no tiene receta en `merge.py`).
Usa `PATH=/opt/homebrew/bin:$PATH` en el nodo Mac. Comprueba `MERGED` y el SHA integrado.
El kit y sus recibos no son requisitos para esta ruta. Publica mediante el procedimiento del destino y verifica el resultado.
