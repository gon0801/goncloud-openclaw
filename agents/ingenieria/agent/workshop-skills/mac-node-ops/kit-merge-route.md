# Merge y despliegue

El merge y el despliegue los hace el motor: lo que cambia código va por `motor entrega` (skill `motor`); ningún agente mergea ni despliega a mano. Revisión previa a la entrega: el bot ai-review (DeepSeek) sobre el head, sin bloqueantes abiertos. CodeRabbit es opcional: si comenta, se lee y sus hilos Major/Critical se adjudican; si no comenta o está sin cuota, no frena ni se espera, pero un hilo Major/Critical suyo sin adjudicar frena hasta adjudicarse.
El kit y sus recibos no son requisitos para esta ruta. El motor comprueba `MERGED` y el SHA integrado, publica por el procedimiento del destino y verifica el resultado.
