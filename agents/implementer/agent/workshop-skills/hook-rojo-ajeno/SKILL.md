---
name: Hook rojo ajeno
description: Cuando el commit o el push se bloquea por tests en rojo en archivos que tu cambio no toco. Prueba de preexistencia con stash en base limpia, regla de direccion de reparacion y cuando reintentar un flake de timing.
---

# Hook rojo ajeno

Un rojo fuera de tu diff no se arregla fuera de alcance ni se esquiva
con `--no-verify`. Se demuestra preexistente o se repara solo lo que el
propio test prescriba.

## Pasos

1. Lee el FAIL exacto del log del hook y compáralo contra tu diff
   (`git diff --name-only`): anota test, mensaje y archivos que toca.
   Ningún reintento a ciegas antes de esto.
2. Prueba de preexistencia: `git stash push -- <tus archivos>` (solo tu
   diff, nada más), corre LOS MISMOS tests que enrojecen sobre la base
   limpia y compara salida contra salida:
   - Fallo idéntico en base limpia ⇒ preexistente ambiental: se declara
     con evidencia (test, SHA de la base, mensaje igual) y no se toca.
   - Pasa en base y falla una vez contigo ⇒ flake de timing: reintenta
     una vez y declara el pase aislado.
   - Solo enrojece contigo ⇒ es tuyo: arréglalo en tu diff.
   Cierra con `git stash pop`; si el pop toca archivos de otro commit en
   vuelo, no confíes en el auto-merge silencioso (detalle en
   no-op-commit-drop, paso 6): verifica el contenido contra su copia
   autoritativa antes de commitear.
3. Regla de dirección de reparación: si un rojo preexistente bloquea tu
   commit y el propio test prescribe la reparación (ej. "la copia
   instalada derivó del repo canónico"), aplícala EN LA DIRECCIÓN QUE EL
   TEST PRESCRIBA (repo→local, nunca al revés) y con respaldo previo.
   Lo que ningún test prescriba no se toca aunque desbloquee.
4. Nunca `--no-verify` para pasar por encima del candado: un rojo real
   fuera de tu alcance se reporta al lead con la evidencia del paso 2,
   no se esquiva.

## Criterio de cierre

Commit verde con batería, o bloqueo declarado con los tres datos: test,
fallo idéntico en base limpia (SHA) y por qué no se toca.
