# Merge y despliegue

Cualquier agente puede usar `gh pr merge <PR> --squash --match-head-commit <SHA>` después de CI verde, sin permiso adicional, leyendo los bots y los checks a mano (este repo no tiene receta en `merge.py`). Revisión: el bot ai-review (DeepSeek) sobre el head, sin bloqueantes abiertos. CodeRabbit es opcional: si comenta, se lee y sus hilos Major/Critical se adjudican; si no comenta o está sin cuota, no frena ni se espera, pero un hilo Major/Critical suyo sin adjudicar frena hasta adjudicarse.
Usa `PATH=/opt/homebrew/bin:$PATH` en el nodo Mac. Comprueba `MERGED` y el SHA integrado.
El kit y sus recibos no son requisitos para esta ruta. Publica mediante el procedimiento del destino y verifica el resultado.
