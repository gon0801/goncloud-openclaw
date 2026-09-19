# Runbook que declara psql sin usarlo en bloques (Fase 9, 9.3)

La base se consulta a mano cuando hace falta, fuera de los bloques de comando.

## Clases de comando

| Clase | Ejemplo | Candado |
|---|---|---|
| `gh` | `gh pr checks` | permitido |
| `psql` | `psql -U dn` | negado en esta sesion |
