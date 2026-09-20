# Runbook que declara red externa sin usarla en bloques (Fase 9, 9.3)

Las descargas van a mano cuando hacen falta, fuera de los bloques de comando.

## Clases de comando

| Clase | Ejemplo | Candado |
|---|---|---|
| `gh` | `gh pr checks` | permitido |
| red externa | `curl https://...` | negado en esta sesion |
