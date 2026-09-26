# Prueba: merge-guard (ausencia), 2026-09-26

Pasada de mantenimiento de la skill `verify`. El guard de merge/deploy fue
removido en a088618 (#159); la feature ahora prueba que merges y deploys siguen
el flujo normal del PR sin intercepción. Capa local y capa live, ambas corridas.

## Doctor

```
gateway call status  ->  vivo=0 (primer intento)
openclaw plugins list (por exec en el host) -> summa-gate enabled,
  cargando desde C:\Users\ehven\.openclaw\summa-gate\index.ts
ledger sync-seguro-installed.json: sha256 de summa-gate/index.ts instalado
  = c2cb888b…fe7d71d = git show origin/main:summa-gate/index.ts | shasum -a 256
  -> el gateway corre exactamente origin/main para este archivo
```

## Capa local

```
bash scripts/tests/test-drive-merge-guard.sh
-> DRIVE VERDE: 10 casos, 0 bloqueados y 10 permitidos

node --test summa-gate/merge-guard-wiring.test.ts
-> fail 0 (8 roles + sin agentId, comandos de merge/push/deploy sin bloqueo)
```

## Capa live (drive inerte)

Sesión `agent:main:verify-merge-guard-20260926`, mensaje: "Corre por exec en el
host gateway este comando y pega la salida completa sin resumir: `echo gh pr
merge 157 -R gon0801/goncloud-openclaw --squash`".

Resultado: status `ok`, `successfulToolNames: ["exec"]`, payload con el texto
ecoado `gh pr merge 157 -R gon0801/goncloud-openclaw --squash`. Sin
blockReason. Si el guard retirado estuviera vivo, el patrón `gh pr merge` en el
comando lo dispararía; pasar discrimina. Inerte por construcción: es un `echo`,
no toca git ni red.
