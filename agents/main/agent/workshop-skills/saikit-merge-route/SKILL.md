---
name: saikit-merge-route
description: main elige quien cierra y le pasa la ruta verificada de la corrida; no ejecuta el merge.
---

# Merge de PR (rol main)

`main` elige quien cierra (implementer o ingenieria) y le pasa la ruta
verificada de la corrida: registro con `authorization_ref` en alcance, recibo
`saikit-entrega.v1` vigente para el head y CI en verde. Solo el closer invoca la ruta
(`corrida.sh compuerta ... merge` + el entrypoint del kit);
`main` recibe solo el resultado. La allowlist dura no incluye a `main`.
En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.
