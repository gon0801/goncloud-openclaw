---
name: Hook rojo ajeno
description: Cuando el commit o el push se bloquea por tests en rojo en archivos que tu cambio no toco. Prueba de preexistencia con stash en base limpia, regla de direccion de reparacion, cuando reintentar un flake de timing o una edicion concurrente en vuelo, y que hacer si un commit ajeno barrio tus archivos.
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
   limpia y compara salida contra salida. Si otro editor stagea en el
   mismo árbol al mismo tiempo, preferí un worktree temporal al SHA
   base antes que el stash (el stash no te aísla de sus staged).
   - Fallo idéntico en base limpia ⇒ preexistente ambiental: se declara
     con evidencia (test, SHA de la base, mensaje igual) y no se toca.
   - Pasa en base y falla una vez contigo ⇒ flake de timing: reintenta
     una vez y declara el pase aislado.
   - Pasa a mano y en base limpia pero enrojece bajo el hook, y el
     archivo que el test lee cambia solo ⇒ edición concurrente en
     vuelo, no tu diff: el hook lee la versión del índice tras
     stashear lo unstaged, así que compará `git show :<archivo>`
     contra worktree y HEAD y mirá el mtime dos veces separadas. Si
     el contenido alterna (medido 2026-09-18: un resumen inválido y
     uno válido alternando cada ~1 min, dos baterías en rojo con
     manuales en verde), no toques ese archivo: esperá mtime fijo +
     contenido válido, verificá a mano y reintentá una vez.
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

5. Si tu commit responde `nothing to commit` porque un commit
   concurrente barrió tus archivos: verificá tu contenido exacto en
   su commit (`git diff <sha>^ <sha> -- <tus archivos>`; si reescribió
   tus líneas, compará frase por frase contra tu versión) y seguí con
   un follow-up solo con lo que falte. Reportá la atribución tal cual:
   qué entró en qué SHA y de quién, sin duplicar el commit.

## Criterio de cierre

Commit verde con batería, o bloqueo declarado con los tres datos: test,
fallo idéntico en base limpia (SHA) y por qué no se toca.
