# Prueba: merge-guard, 2026-09-16

Corrida para probar la skill `verify` recién generada, siguiendo sus propias
instrucciones de punta a punta. Capa **local**: prueba que el hook está
registrado y que su veredicto es el correcto. **No** prueba que el plugin esté
cargado en el gateway; eso solo lo dice `plugins list` y aquí no se corrió.

## Doctor

```
gateway call status  ->  vivo=0
```

Al primer intento salió `vivo=1` y el gateway estaba arriba: cinco sondas
seguidas contestaron, tres en menos de cinco segundos. De ahí salió la regla de
dos intentos que ahora trae el doctor.

## Drive

Hook `before_tool_call` con matcher `exec`, registrado contra un host falso con
el patrón de `role.test.ts`, y disparado con seis comandos.

```
OK   bloquea  subcomando de merge de la CLI
        comando: gh pr merge 12 -R o/r --squash
        mensaje: Merge bloqueado por summa-gate: `gh pr merge` está prohibido desde el agente (también encadenado con &&/;). El merge lo hace el operador o el flujo autorizado del repo.
OK   bloquea  misma orden encadenada
        comando: echo hola && gh pr merge 12
        mensaje: Merge bloqueado por summa-gate: `gh pr merge` está prohibido desde el agente (también encadenado con &&/;). El merge lo hace el operador o el flujo autorizado del repo.
OK   bloquea  push a rama protegida
        comando: git push origin main
        mensaje: Push bloqueado por summa-gate: `git push` a master/main está prohibido desde el agente (incluye origin master, +master, HEAD:main, refs/heads/main y delete-ref :main).
OK   bloquea  ruta de merge de la API
        comando: gh api repos/o/r/pulls/1/merge -X PUT
        mensaje: Merge bloqueado por summa-gate: `gh api …/merge` está prohibido desde el agente. El merge lo hace el operador o el flujo autorizado del repo.
OK   pasa     push a rama de trabajo
        comando: git push origin feature/x
OK   pasa     lectura inofensiva
        comando: gh pr view 12 --json state

DRIVE VERDE: 6 casos, 4 bloqueados y 2 permitidos
```

## Bateria completa, sobre el mismo arbol

```
OK: verify-corpus

TODO VERDE
```
