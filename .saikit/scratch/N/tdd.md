# Carril N — TDD (rojo inicial por tarea)

## 9.1 Contratos (2026-09-18)
Rojo inicial: `bash scripts/tests/test-cli-modos.sh` → `FAIL: falta scripts/mac/cli-modos.tsv`
(rc=1), con solo el test y los fixtures en el árbol. Verde tras agregar `cli-modos.tsv`
(12 filas, una por CLI de AGENT_TMUX_TOOLS), `docs/spec/corrida.v1.md`,
`docs/spec/seguimiento.v1.md` y la sección "Corridas autónomas" en `00-project-spec.md`:
`TODO VERDE: test-cli-modos`.
Mutaciones que mueren (verificadas): vigía fuera del conjunto, sesión sin rol, etiqueta
desconocida, y jerga en cinco formas (palabra de lista negra, ruta, --flag, sha, tilde).
