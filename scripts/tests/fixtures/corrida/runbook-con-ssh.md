# Runbook con ssh declarado (Fase 9, 9.3)

Se abre sesion asi:

```
ssh sesion-remota true
gh pr checks 1
```

## Clases de comando

| Clase | Ejemplo | Candado |
|---|---|---|
| `gh` | `gh pr checks` | permitido |
| `ssh` | `ssh sesion-remota` | negado en esta sesion |
