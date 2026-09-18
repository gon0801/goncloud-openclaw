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

## 9.3 Preflight (2026-09-18)
Rojo inicial (limpio, con mv reversible): sin `corrida/preflight.sh` el despachador
dice `subcomando desconocido: preflight` y la prueba falla en `preflight sano debio
dar APTO`. Verde tras implementar: `TODO VERDE: test-corrida-preflight`.
Mutaciones que mueren (verificadas): gh en 401, binario que muere, flag que no entra,
vigilante viejo, ssh declarado en sesion que lo niega, ssh usado sin declarar en la
tabla ( estatico: bloque de comando sin fila de clase). NO APTO manda DETENIDA en
lenguaje de usuario (las razones tecnicas van solo a stdout, jamas al mensaje).

## Fix CI Linux (2026-09-18, PR 81)
CI rojo con 2 fallas propias de Linux, ambas verdes en macOS:
(1) nucleo "el dir no queda 700": en Linux `stat -f` NO falla (es stat de
filesystem) y el `||` nunca caia al `stat -c`; se elige el flag por `uname`.
(2) preflight "vigilante viejo": la prueba copiaba el vigilante del arbol, pero
los hooks retocan el arbol antes de la bateria en CI; ahora el instalado se
escribe desde el mismo blob de origin que preflight compara (el caso rojo sigue
demostrando que la comparacion discrimina).

## Fix CI 2 (2026-09-18, PR 81)
CI volvio rojo en `sin blob de referencia del vigilante`: el checkout de CI no
garantiza origin/main, asi que `git show origin/main:...` falla segun el evento.
La prueba ahora arma su propio repo (init + commit + refs origin/main y
origin/HEAD) y preflight lo usa via REPO_DIR: determinista en local y en CI,
sin red y sin depender del checkout.

## Incidente 2: indice con 16 archivos (2026-09-18)
Durante el hook del commit fix-2, `git status` mostro 533 D + 79 ??: el indice
quedo con solo 16 entradas (el vigilante + 15 fixtures). HEAD intacto (f556b93),
arbol intacto. Para que no aterrizara un commit borrando 533 archivos: (1) copie
de respaldo de los 2 archivos modificados a /tmp/f9-idx-backup/, (2) mate la
cadena git-commit + run-checks del hook (el `&&` evito el push), (3) restaure
solo el indice con `git read-tree HEAD` (arbol sin tocar), (4) verifique diff =
solo mis 2 archivos. Causa probable: maquinaria del stash del hook u otro agente
concurrente en la Mac (habia un run-checks ajeno corriendo); sin evidencia para
afirmar cual. Leccion: ante un indice extranio a mitad de hook, matar el commit
antes de que aterrice es mas barato que reparar historia.

## Causa raiz del indice + incidente 3 (2026-09-18)
Causa raiz encontrada con `ps -E`: pre-commit exporta GIT_DIR, GIT_INDEX_FILE,
GIT_PREFIX (y GIT_AUTHOR_*) a los hooks. La prueba de preflight arma un repo con
`git -C $T/repo ...`: con GIT_DIR absoluto, el `-C` NO aisla y `git add -A` borro
533 entradas del indice real, y `update-ref origin/main HEAD` movio origin/main a
f556b93 (restaurado con `git fetch origin main`). Arreglo en 3 capas: unset en
run-checks.sh (toda la bateria), en test-corrida-preflight.sh (incl. AUTHOR/
COMMITTER) y en corrida_preflight (lecturas contra REPO_DIR). Verificado: prueba
en verde con GIT_DIR/GIT_INDEX_FILE hostiles y refs intactos.
 Incidente 3: al matar mi cadena maté tambien con pkill todo run-checks de la Mac
 (ajenos). Solo aborta su hook sin commitear, pero les hice perder su bateria.
 Leccion: matar por PID exacto, jamas por patron.

## Correccion tras auditoria del lead (BRIEF-r1, 2026-09-18)
Dos hallazgos del PR 81. Rojo inicial con los dos casos nuevos y los defectos
puestos: (10) `FAIL: el cron no senala el directorio de estado de la corrida`
(el mensaje del cron era "Parte de la corrida t1 para el vigia.", no pedia nada);
tras corregir abrir.sh, (11) `FAIL: NECESITO TU RESPUESTA salio silenciosa`
(corrida_mensaje mandaba siempre con --silent). Verde tras ambos arreglos:
`TODO VERDE: test-corrida-nucleo`. El (11) ademas exige que AVANZA siga saliendo
con --silent, y el (10) exige cada 60 min, Telegram, destino del canal, directorio
de estado, "Contesta SOLO con el parte", capture-pane, lenguaje de usuario y, en
 simulacro, pedir el prefijo en el texto del cron.

## BRIEF-r2 (2026-09-18): batch 9.1 — temas L, M, N (+ el patron SIMULACRO del tema I)
Rojo por tema, con el defecto puesto:
- L (forma): `FAIL: forma sin prefijos pasa` (el validador solo contaba lineas y
  etiqueta; tres lineas cualquiera pasaban).
- M (registro): el validador de HEAD aceptaba los 7 mutantes nuevos — `MUTANTE
  ACEPTADO: schema-malo ... lista-dura` (demo contra validar_registro de HEAD con los
  fixtures nuevos).
- N (lista negra/sha): tras arreglar L, `FAIL: jerga (commits) pasa` (los sufijos
  evadian \bcommit\b; "acabada"/"1234567" daban falso sha).
Verde: `TODO VERDE: test-cli-modos` (tambien con /bin/bash 3.2) y
`TODO VERDE: test-corrida-nucleo` sin cambios (corrida_mensaje pasa el validador
nuevo). El validador de mensajes ahora es el de lib.sh probado directo (la copia del
test se borro: un criterio, un lugar). Falsos positivos residuales declarados: "y/o",
fechas "18/09" — falla cerrado a proposito, no se afloja.
