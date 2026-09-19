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

## BRIEF-r2 (2026-09-18): batch 9.2 — temas A,B,D,E,F,G,I,J,K,O,Q,R + H(nucleo)
Rojos por tema (con el defecto puesto, corridas en secuencia):
- D: `FAIL: abrir acepto un id con ../`
- B: `FAIL: abrir piso una corrida existente` (cabeza de los casos B; el resto
  —cron por id, cron rm ruidoso— muto-verificado abajo)
- I: `FAIL: el prefijo SIMULACRO invalida un mensaje valido`
- O/Q y demas casos tardios: implementados en bloque; verificados por mutacion.
Bug propio hallado al integrar: en tmux 3.7 el target `=nombre` exacto NO resuelve
para comandos de PANE (capture-pane, send-keys) — exigen `=nombre:` con colon; los de
SESION (has/set-environment/kill-session) si toman `=nombre` pelado. Medido en vivo.
El CLI de mentira no se comportaba como TUI (no pintaba recibo al consumir): ahora
responde por pantalla y el heuristico de caja vacia distingue de verdad.
Mutaciones que mueren (verificadas, cada una con su FAIL): sin kill-session en el
camino de barra ausente → "la sesion fallida quedo viva" (A); sin chequeo de estado →
"lanzar sobre una corrida cerrada debio negarse" (J); silencio siempre → "NECESITO TU
RESPUESTA salio silenciosa" (R); has-session sin = → "una sesion con prefijo comun
robo el nombre" (E); David en el texto → "el cron no habla de el dueno" (O).
Verde: `TODO VERDE: test-corrida-nucleo` (tambien /bin/bash 3.2). El caso (9b) de
 lanzamientos paralelos paso con y sin lock en las corridas de observacion (la carrera
 es de milisegundos); el lock queda como correccion estructural, no como caso rojo
 determinista — declarado.

## BRIEF-r2 (2026-09-18): batch 9.3 — temas A(preflight), C, C2, P + H(preflight)
Rojo inicial con el defecto puesto: `FAIL: con barra vacia debio dar NO APTO`
(la barra vacia contaba como unknown y el preflight daba APTO sin probar nada; la
tabla ilegible daba APTO ciego igual). Mutaciones que mueren (verificadas, cada una
con su FAIL): sin chequeo de tabla ilegible → "con tabla ilegible debio dar NO APTO"
(C); union reducida a las usadas → "clase declarada y no usada debio dar NO APTO"
(C2); trap de salida anulado → "una senal a mitad dejo viva la sesion de prueba" (A;
el caso usa SIGTERM porque POSIX ignora el SIGINT de los background en scripts).
El caso "vigilante no corre" necesita un pgrep de mentira: el vigilante REAL de la
Mac matchea el patron y contaminaba el caso (hallazgo propio, medido en vivo).
P: centinela con GIT_DIR/GIT_INDEX_FILE hostiles intacto tras preflight, mas anclas
grep de los unset en run-checks.sh y preflight.sh (el ancla es lo que rojea si los
quitan; el centinela prueba que el env hostil no escapa). Los CLIs de mentira anotan
su argv y el test exige que el flag LLEGUE al binario (el caso del flag malo prueba
ademas que su flag llego: la razon es la barra, no el envio). El watch alterado del
caso "vigilante viejo" se restaura antes de los casos que siguen. Verde:
`TODO VERDE: test-corrida-preflight` (tambien /bin/bash 3.2), nucleo y cli-modos
iguales. Incidente propio: el commit del batch 9.2 aborto una vez ("files were
modified by this hook") porque edite archivos mientras corria la bateria del
pre-commit; el indice quedo intacto y el commit entro al segundo intento sin tocar
 el arbol. Leccion: durante un commit con este hook, el arbol se queda quieto.

## BRIEF-r3 (2026-09-18): batch 9.1 — W, X, Y + fc3472e#4-#8,#13
- W: ya estaba arreglado en a22804f (el hallazgo apuntaba a fc3472e); el grep+sed
  se simplifico al sed incondicional que pide el brief. Cubierto por (6b).
- X: rojo `validar_registro: command not found` al cargar solo lib.sh — el criterio
  vivia en la prueba. Ahora validar_registro (con lista dura) es de lib.sh; la prueba
  lo carga con source; abrir se autochequea el registro que escribe (sin rojo posible:
  abrir no puede producir un registro invalido sin inyeccion — declarado).
- Y: rojos con el validador de HEAD: `rm -rf` y `force push` aprobados PASABAN;
  `emergencia` y `dropbox` daban lista dura por substring. Ahora regexes con bordes.
- fc3472e#4: 4 lineas sin salto final se rechazaban y 5 pasaban (wc -l cuenta saltos,
  no lineas) — awk END{print NR}. Los archivos sin salto final se generan al vuelo en
  la prueba: guardados en el repo, el hook de end-of-file los reescribiria y el caso
  dejaria de probar lo que prueba (hallazgo del propio pase; idem el espacio final
  del caso de contenido vacio, que se codifica como "Que cambio:" sin espacio).
- fc3472e#6: `mensaje-forma-sin-avance` pasaba (rc 0 verificado) — la linea 1 ahora
  exige "N de M partes" (CERRADA exento: no queda nada que contar).
- fc3472e#7/#8: mergear/rama/push/rebase/hash-mayus/Comando-en-linea-2/Comando-largo
  pasaban — verificados en el mismo pase rojo.
Bug propio del pase: inverti el exit del awk de marcadores en lineas 1-3 (exit 0 es
limpio); lo cazo el primer verde. corrida_mensaje gana el argumento avance (tercero)
y sus llamadores (cerrar, preflight, pruebas) se actualizan.
Verde: las tres pruebas en TODO VERDE.

## BRIEF-r3 (2026-09-18): batch 9.2 — T + U1-U5 (kimi/a22804f#1-#6)
Rojos con el defecto puesto: `FAIL: un nombre con espacio debio rechazarse` (U2,
cabeza de los casos; U1 setenv, U3 cron sin id y T lock-viejo se agregaron en el
mismo pase y mutan-verifica su caso en el verde). El caso de lock fresco ya pasaba
(comportamiento existente); el de lock viejo, rojo por construccion (el spin de 10 s
terminaba en fallo).
Dos bugs propios del pase, ambos cazados por la prueba:
(1) `find -mmin +1` como condicion por RC: find SIEMPRE sale 0 (match o no); la
condicion ahora mira la salida. En mi shell interactivo ademas `find` es una
funcion que envuelve bfs — enganoso al depurar; la prueba corre bash plano.
(2) Incidente mayor: guardar y restaurar el trap de EXIT con eval, dentro de la
captura `out=$(registro_actualizar ...)`, RE-ARMO el trap del test dentro de la
subshell y al cerrar esta ejecuto `kill-server; rm -rf $T` a mitad de la prueba
("sin registro: t1", trace completo). Rediseno: registro_actualizar solo arma su
rmdir si NO hay trap dueño; si lo hay (preflight), no se pisa y el caso lo cubre el
rompimiento de locks viejos. La prueba captura a archivo, no con $().
Verde: las tres pruebas en TODO VERDE (tambien /bin/bash 3.2).

## BRIEF-r3 (2026-09-18): batch 9.3 — S + U6 + U7 (kimi/229daf4#1-#4)
Rojo por mutacion (los casos se agregaron junto al fix; cada mutacion mata su caso):
- S: pf_limpiar con la sustitucion entrecomillada (una sola palabra con saltos de
  linea) → `FAIL: la senal dejo viva a preflight-t-mul-a` — con dos huerfanas
  preflight-* vivas mas la sesion en curso, ninguna moria. Ahora lee linea a linea.
  El caso A3/S espera a que la sesion exista (poll de has-session), sin sleep fijo.
- U6: el bucle sin-declarar iterando la lista partida → la razon de "red externa"
  usada sin declarar salia como "red"/"externa"; el caso exige la clase entera.
- U7: rb pegado sobre REPO → el runbook guardado absoluto daba "runbook sin leer";
  runbook_de (en lib.sh) resuelve absoluta tal cual y relativa bajo REPO_DIR.
Verde: las tres pruebas en TODO VERDE.

## BRIEF-r4 (2026-09-18): pase final del lead — Z1-Z4
Rojos con el defecto puesto:
- Z1: `runbook_de` desde scripts/mac sin REPO_DIR resolvio contra pwd
  (`scripts/mac/tests/...`); el caso exige la raiz del repo. Ahora el fallback es
  `git rev-parse --show-toplevel` (pwd de ultimo recurso).
- Z2: tras `registro_actualizar`, `trap -p EXIT` seguia ARMADO — el EXIT de quien
  uso el lock romperia un lock vivo de otro tomado entremedias. Ahora se desarma
  (solo si esta funcion fue quien lo puso). Caso (9g) con proceso bash aparte.
- Z3: `FAIL: la limpieza sin id no borro por el id de la lista` — el cleanup sin id
  borraba por nombre a ciegas. Ahora: cron list, id del job por nombre exacto,
  cron rm por ese id, y si el job sigue en la lista el error lo dice. El stub gana
  estado (cron-puesto) para que el job "exista" de verdad.
- Z4-1: `FAIL: registro mutante pasa: dura-rm-separado` (rm -r -f evadia la regex);
  ahora r y f por lookaheads, juntos o separados.
- Z4-2: `Ab12Cd4` (hex mixto) pasaba — un bucle solo-minusc, otro solo-mayusc;
  unificado case-insensitive con digito+y+letra.
- Z4-3: la exencion de CERRADA al "N de M" ya esta en seguimiento.v1.md.
- Z4-4: comentario y aviso del umbral de locks viejos alineados con lo que find
  hace de verdad (a partir de ~2 min).
Verde: las tres pruebas en TODO VERDE (tambien /bin/bash 3.2).

## BRIEF-r5 (2026-09-18): ronda 4 (claude sobre 604e577) — AA, AB, AC, AD
Rojos con el defecto puesto:
- AA: desde /tmp sin REPO_DIR, runbook_de resolvio `/tmp/scripts/...` (pwd). Ahora
  la raiz se deriva del propio lib.sh al cargarse (CORR_REPO_RAIZ, tres niveles
  arriba; instalado en ~/bin/corrida no aplica, documentado) y REPO_DIR inyectado
  gana. El caso z1 compara forma fisica y ruta REAL, y exige que exista.
- AB: `FAIL: registro mutante pasa: dura-rm-largos` (las cuatro formas nuevas
  evadian la regex). Ahora r/f cuentan por FLAG, no por letra suelta: "--force"
  solo aporta f, "--recursive"/-r aportan r, y un cluster corto aporta las letras
  que tenga; pat ya viene lowercase.
- AC: `FAIL: con dos crons homonimos no se quitaron los dos` + demostracion de la
  lista ilegible vistiendose de "se quito". Ahora cron_jobs_de devuelve TODOS los
  ids homonimos, se quitan por id, y la relectura distingue ILEGIBLE (honesto: "no
  se pudo releer") de NINGUNO ("se quito por la lista (N job(s))") de "sigue vivo".
- AD-11: sha256 de 64 pasaba — rango 7-64, fixture nuevo. AD-13: un [CERRADA]
  pelado YA caia por la regex de etiqueta (exige "] "); el calculo del resto se
  endurecio igual (prefijo completo, vacio si no strip). AD-6: disarm ANTES del
  rmdir (sin rojo determinista posible sin inyeccion — declarado). AD-12: parser
  de cron list unificado en cron_dest_de/cron_jobs_de (abrir ya no duplica).
  AD-8: z1 con ruta real y fisica. AD-10: la corrida t-limpio extra fuera; (7)
  no cuenta corridas (solo grepea t1). AD-5: comentario con las dos semanticas
  de find -mmin +1 (BSD >60 s; GNU ~2 min), umbral a proposito.
Bugs propios del pase (cazados por la prueba o el repro): el patron de resto sin
el corchete inicial; y en el stub, cron rm miraba $2 (el id es $3) y el grep -v
con resultado vacio dejaba de hacer mv. Verde: las tres pruebas, tambien /bin/bash.

## BRIEF-r6 (2026-09-18): ronda 5 (kimi sobre bc29489) — BA + BB
- BA: rojo `FAIL: relleno largo entre rm y los flags evita la lista dura` (la
  ventana de 80 chars dejaba pasar el patron con relleno). _rm_recursivo ahora
  mira el resto COMPLETO desde el "rm", por tokens que arrancan con guion.
- BB-3: rojo demostrado — "quitar con rm -f y -restar horas" daba lista dura
  (falso positivo): los tokens largos de una sola letra-por-flag cuentan como
  cluster solo hasta 4 letras; "-restar" (6) es prosa. Los largos siguen
  contando solo por nombre exacto (--recursive/--force).
- BB-4: caso nuevo del ILEGIBLE del PRIMER cron_jobs_de (lista ilegible antes de
  intentar quitar): cobertura verde desde el arranque (el camino ya existia).
- BB-2: comentario de runbook_de ajustado a la verdad (pwd es el fallback final
  si la derivacion fallara).
- BB-5: cron_dest_de con homonimos devuelve el del ULTIMO; eleccion escrita en
  el codigo.
Verde: las tres pruebas, tambien /bin/bash 3.2.
Incidente del pase (entorno, no codigo): la bateria del pre-commit aborto el primer
commit con `FAIL: bateria summa-gate` — `Cannot find package 'openclaw'` desde
summa-gate/index.ts. Hace una hora (commit bc29489) la misma bateria pasaba:
el node_modules que resolvia el paquete desaparecio o nunca llego a este worktree
(agentes concurrentes en la Mac). tablero-runbook/node_modules/openclaw es un
SYMLINK a ~/.openclaw/tools/... creado 14:43 por otra mano; restaure el mismo
enlace para summa-gate (gitignored, cero installs nuevos, mismo patron existente).
Verificado: bateria completa en TODO VERDE.

## BRIEF-r7 (2026-09-18): ronda 6 (claude sobre 7bce512) — CA, CB, CC, CD, CE
- CA/CB/CE-r (MATRIZ completa): rojo inicial `FAIL: matriz: debia ser rojo:
  matriz-rojo-06.json` (`` `rm -rf` `` con comillas invertidas; hoy el split por
  espacios dejaba tokens sucios). _rm_recursivo v3: flags por findall con
  lookbehind (?<![\w-]) sobre el texto YA lowercased (RM -RF cuenta), largos solo
  por nombre exacto, cortos solo si TODAS sus letras son opciones de rm
  (d f i p r v w x: -vvvrf vale, -restar no), y la regla exige r: una -f sola
  jamas cuenta (rm -r dir es rojo). Nota de interpretacion: el caso "--force,"
  de la matriz se codifico como "rm --recursive --force," para no contradecir
  CE-r (f sola limpia).
- MUTACION exigida por el brief verificada: con la regla reducida a `return
  False`, los 16 ROJO de la matriz PASAN (16/16) y la prueba entera cae
  (`FAIL: registro mutante pasa: dura-rmrf`).
- CC: t-ileg2 ahora afirma rc!=0, el mensaje "no se pudo leer la lista" y que NO
  aparece "se quito por la lista"; la lista cae en el PRIMER cron_jobs_de (la del
  destino pasa: LISTA_DESPUES_DE=nl+1). Rojo demostrado rompiendo el mensaje de
  ese camino: `FAIL: la lista ilegible de entrada no se reporta honestamente`.
- CD: cron_dest_de con homonimos — createdAtMs en todos -> el mas reciente; sin
  el y destinos DISTINTOS -> AMBIGUO y abrir falla cerrado ("destinos ambiguos
  entre homonimos"); mismo destino -> ese. Rojo capturado (`con destinos
  ambiguos debio fallar cerrado`). Bug propio del pase: el mensaje decia
  "destinos distintos" y el test grepeaba "ambigu" — alineados.
- CE-9b: trap de limpieza junto al mktemp (cubre fail tempranos) y $FX por argv
  en el heredoc. Interpretacion: el trap borra con rm -f por glob (no recursivo),
  porque la regla del carril veta rm -rf aun bajo /tmp — declarada.
- CE-5: comentario de runbook_de sin prometer el plist: REPO_DIR si esta; si no,
  raiz derivada de lib.sh; pwd ultimo recurso documentado; bajo launchd, inyectar
  REPO_DIR es lo seguro.
Verde: las tres pruebas, tambien /bin/bash 3.2.

## BRIEF-r8 (2026-09-18): hueco del reviewer del kit en cerrar — repro textual
Rojos con el defecto puesto (stub ahora con estado: el cron-1 de cada abrir vive en
cron-puesto, cron rm de un id inexistente falla como el gateway real, y
ENVIO_MODO=mal tumba el envio):
- `FAIL: el fallo del envio de CERRADA no se nombra` — cerrar salia 1 en silencio
  con la corrida a medias (cron quitado, sesiones desmarcadas, registro abierto).
- El reintento quedaba atado: mutacion verificada — sin la tolerancia de
  idempotencia, `FAIL: el reintento de cerrar debio funcionar (rc=1)`.
Arreglo: cerrar idempotente y honesto — (a) el fallo del aviso nombra la falla y en
que quedo la corrida ("reintentar cierra"); (b) el estado pasa a cerrada SOLO
cuando todo cerro; (c) cron rm que falla con el cron YA fuera de la lista cuenta
como exito (verificado con cron_jobs_de; si sigue en la lista o la lista no se
puede leer, error con lo hecho y lo falta). Bugs propios del pase, cazados por la
prueba: el grep -c con || echo 0 duplicaba la salida y rompia la aritmetica del
stub, y el contador de duplicados se contaminaba con los adds normales (ids de
duplicados ahora deterministas por nombre).
Verde: las tres pruebas, tambien /bin/bash 3.2.

## BRIEF-r9 (2026-09-18): hallazgos del reviewer del kit sobre 7d8ab70 — DA-DD
Rojos con el defecto puesto:
- DA: `FAIL: la segunda llamada reenvio el aviso` (regresion: cerrar sobre
  cerrada reenviaba CERRADA). Ahora: estado cerrada → rc=0, "cerrada <id>",
  cero reenvios, ni cron ni sesiones.
- DB: demostrado a mano con el lock tomado — el aviso SALIA y recien despues
  fallaba "lock del registro no cede" (CERRADA en jsonl: 1). Ahora el lock se
  toma ANTES del aviso (registro_lock/escribir/unlock extraidos de
  registro_actualizar): con el lock tomado nada sale, el error dice "el aviso NO
  salio" y lo hecho, y el reintento cierra con UN solo aviso (caso 7b4).
- DC: "quedan: ILEGIBLE" (demostrado leyendo el mensaje) — ahora distingue: la
  lista no se pudo leer ("no se pudo verificar... revisar el cron a mano") de
  ids que quedan de verdad.
- DD: mutacion verificada — sin la rama ILEGIBLE, `FAIL: la ilegibilidad de la
  lista no se nombra`; la forma fail-open (ILEGIBLE como exito) la mata el
  assert de rc!=0 del mismo caso (7b5).
Extra por DB: si el aviso salio pero la escritura del registro fallo, el error
lo dice y el reintento NO reenvia (mensajes.jsonl es la memoria de lo que David
ya recibio: CERRADA ok:true → no se remanda).
Verde: las tres pruebas, tambien /bin/bash 3.2.

## BRIEF-r10 (2026-09-18): bloqueantes del reviewer sobre 2fb5aa2 — EA, EB, EC
- EA: rojo `FAIL: matriz: debia ser rojo: matriz-rojo-16.json` (rm --r build; el
  getopt de GNU abrevia opciones largas y el detector solo miraba --recursive
  exacto). Ahora una opcion larga cuenta si es prefijo de "recursive" (--r, --rec,
  ...); "--dir"/"--resto" no son prefijo y siguen limpios. Matriz: +3 rojo
  (--r, --rec -f, --forc -r) y +1 limpio (--resto).
- EB: una mutacion por cambio, cada una muere en SU caso:
  (1) sin la salida temprana de ya-cerrada → `FAIL: la segunda llamada toco el
      cron` (el caso (7b3) ahora exige cero reenvios Y cero toques de cron — el
      ya-avisado solo enmascara lo primero);
  (2) sin la lectura de mensajes.jsonl → `FAIL: el reintento reenvio el aviso
      (n=2)` (caso nuevo 7b6: aviso enviado + registro_escribir fallando por
      inyeccion de registro.json.tmp como directorio → mensaje honesto "ya salio
      pero", reintento cierra sin reenviar, exactamente un CERRADA en total).
- EC: rojo `FAIL: un rol fuera del conjunto debio rechazarse`; lanzar-sesion
  acepta solo lead|carril (rc 2 antes de crear nada).
Verde: las tres pruebas, tambien /bin/bash 3.2.

## BRIEF-r11 (2026-09-18): accionables de CodeRabbit — FA, FB, FC
- FA: mutacion certificada (sin el chequeo del canal, `FAIL: con el canal de
  mensajes roto debio fallar` — la inyeccion crea mensajes.jsonl como DIRECTORIO,
  que hace fallar el touch sin romper nada mas). Ahora: canal muerto = cron
  retirado + registro borrado + error que lo nombra.
- FB: rojo con el primer mutante (`falta-destino.json sin su motivo`). El
  validador exige presencia/tipo de canal.destino, cli_modos, cron_vigia_id,
  inicio, simulacro (bool) y preaprobaciones lista-o-ausente (antes una
  preaprobacion numerica reventaba el python con TypeError). Hallazgo propio del
  rojo: registro-valido.json NUNCA tuvo canal.destino ni cron_vigia_id — el
  contrato los exigia en produccion (abrir los escribe) pero el fixture de
  referencia no; actualizados los tres fixtures que deben pasar limpio
  (valido, pasa-emergencia, pasa-dropbox) con valores de mentira.
- FC: rojo `FAIL: el flag sin valor no se explica` — con set -u el shift 2 sin
  valor no colgaba pero moria con "unbound variable" criptico; el caso (0c)
  vigila tambien lo eterno (helper colgado: rc 99 si sigue vivo a los 2 s) y
  exige el mensaje "sin valor". Guarda de aridad en abrir (4 flags) y
  lanzar-sesion (2 flags).
Verde: las tres pruebas, tambien /bin/bash 3.2.

## BRIEF-r12 (2026-09-18): la carrera lanzar/cerrar, reproducida y cerrada
Rojo con el repro del reviewer hecho determinista (caso 9h): cli-tarde tarda su
barra 2.5 s; cerrar entra a los 0.8 s (en pleno sondeo) y cierra; lanzar termina y
anota. Hoy: `FAIL: lanzar sobre una corrida que se cerro debio negarse` (rc=0,
ses-tarde viva, marcada y anotada en registro cerrado — tal cual el repro).
Arreglo en dos frentes:
- cerrar toma el lock del registro ANTES de listar sesiones y lo mantiene hasta
  el final (estado, aviso y escritura dentro); el estado-cerrada se lee bajo lock.
- lanzar-sesion re-verifica estado bajo lock justo antes de anotar: corrida ya no
  abierta => desmarca, mata la sesion y error claro ("se cerro mientras se
  lanzaba").
Mutaciones exigidas, ambas muertas: (1) sin la re-verificacion en lanzar →
`FAIL: lanzar sobre una corrida que se cerro debio negarse` (el propio repro);
(2) listado movido antes del lock en cerrar → `FAIL: cerrar lista sesiones antes
de tomar el lock` (ancla de orden en la prueba: la ventana de esa mutacion, ya
con lanzar corregido, es de microsegundos y no es deterministicamente explotable
desde fuera — el ancla la vela; misma tecnica que los anclajes de unset de git).
Incidente propio del pase: para deshacer la mutacion 2 use `git checkout --` sobre
cerrar.sh y ME LLEVO EL FIX SIN COMMITEAR (por eso los respaldos: siempre cp a
/tmp antes de mutar, nunca checkout con trabajo sin commitear). Reescrito y
verificado en verde.
Verde: las tres pruebas, tambien /bin/bash 3.2.
