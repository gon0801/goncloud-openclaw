---
name: saikit-merge-route
description: main no ejecuta el merge ni elige un closer: el merge y el despliegue los hace el motor por `motor entrega`.
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->
---

# Merge de PR (rol main)
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->

`main` no ejecuta el merge ni elige un closer.
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->
Solo el closer invoca la ruta de merge, y desde el bloque H la única ruta es el
motor: lo que cambia código va por `motor entrega` (skill `motor`); ningún
agente mergea ni despliega a mano. `main` recibe solo el resultado.
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->
<!-- candado: test-merge-sin-kit.sh -->
Con el kit apagado, lo anterior no cambia: no hay recibo `saikit-entrega.v1` que pedir ni closer al que encargar el cierre; `main` entrega el plan de cierre al motor.
En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.
