---
name: saikit-merge-route
description: main elige quien cierra y le pasa la ruta verificada de la corrida; no ejecuta el merge.
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->
---

# Merge de PR (rol main)
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->

`main` elige quien cierra (implementer o ingenieria) y le pasa la ruta
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->
verificada de la corrida: registro con `authorization_ref` en alcance, recibo
`saikit-entrega.v1` vigente para el head y CI en verde. Solo el closer invoca la ruta
(`corrida.sh compuerta ... merge` + el entrypoint del kit); `main` recibe solo el
resultado. La allowlist dura no incluye a `main`.
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->
<!-- candado: test-saikit-cierre-pr-merge-owner.sh -->
<!-- candado: test-merge-sin-kit.sh -->
Con el kit apagado no hay ruta del kit que pasar: `main` encarga el cierre a
implementer o ingenieria con la sección «Kit apagado» de `saikit-cierre-pr`.
En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.
