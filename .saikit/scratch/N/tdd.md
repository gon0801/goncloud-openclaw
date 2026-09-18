# Carril N — TDD (rojo inicial por tarea)

## 9.1 Contratos (2026-09-18)
Rojo inicial: `bash scripts/tests/test-cli-modos.sh` → `FAIL: falta scripts/mac/cli-modos.tsv`
(rc=1), con solo el test y los fixtures en el árbol. Verde tras agregar `cli-modos.tsv`
(12 filas, una por CLI de AGENT_TMUX_TOOLS), `docs/spec/corrida.v1.md`,
`docs/spec/seguimiento.v1.md` y la sección "Corridas autónomas" en `00-project-spec.md`:
`TODO VERDE: test-cli-modos`.
Mutaciones que mueren (verificadas): vigía fuera del conjunto, sesión sin rol, etiqueta
desconocida, y jerga en cinco formas (palabra de lista negra, ruta, --flag, sha, tilde).

## 9.2 abrir/lanzar-sesion/cerrar (2026-09-18)
Rojo honesto: parcial. La prueba se escribio junto al codigo (no rojo-previo limpio);
la primera corrida dio FAIL por un bug de la propia prueba (el chequeo 8 se
auto-encontraba: el destino vive en el fuente de la prueba; se excluye ese archivo).
Tras el arreglo: `TODO VERDE: test-corrida-nucleo`.
Mutaciones que mueren (verificadas en la prueba): marca despues del primer send-keys
(el orden se lee del log del shim), sin comprobar la barra (sesion mala no recibe
nada), sin reintentar el Enter (shim que traga el primero: el encargo igual llega con
2+ Enter), mandar sin validar (jerga rechazada y no sale del stub), destino en el repo
(grep), tabla del entorno en vez del registro (env -i usa --modo-bueno-9 del registro).
Incidente propio 2026-09-18: intente demostrar el rojo con `git stash push` de un
archivo sin trackear; el push fallo y el `pop` siguiente aplico parcialmente un stash
AJENO (stash@{0}, de fix/corrida-nocturna-claw) en este worktree: dejo M
docs/patches/README.md, UU summa-gate/index.ts y 7 untracked ajenos. Recuperacion:
los untracked ajenos se movieron a /tmp/f9-incident-restore/ (reversible; los
originales siguen en el clon principal), los dos trackeados se restauraron con
`git checkout HEAD --` (arbol igual a fcc088a, diff vacio, stash intacto con sus 4
entradas, clon principal sin tocar). Leccion: el stash es global al repo entre
worktrees; jamas hacer push/pop de stash en un worktree con stashes ajenos.
