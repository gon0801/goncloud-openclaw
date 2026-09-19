# Carril M — TDD (rojo inicial por tarea)

## 9.4 estado (2026-09-19)
Rojo inicial (limpio): sin `corrida/estado.sh`, el despachador dice `subcomando
desconocido: estado` y la prueba muere en `FAIL: estado fallo en avanza:
subcomando desconocido: estado` (rc=1), con solo la prueba y los fixtures en el
arbol. Verde tras implementar: `TODO VERDE: test-corrida-estado`.
Cosas que la prueba pega: los seis escenarios byte a byte contra
`scripts/tests/fixtures/estado/<esc>/esperado.txt`; el mensaje (lineas 1-4) pasa
`mensaje_valido` en los seis; `--solo-mensaje` da solo las cuatro lineas; id con
`../`, corrida sin registro y registro fuera de contrato se rechazan; con gh de
mentira "GitHub: una propuesta abierta" / "GitHub: 2 propuestas abiertas"; panel
con escapes, CR y una linea de 6000 caracteres sale limpio y recortado a 5000
(sangria incluida); dos corridas con reloj inyectado dan los mismos bytes.

## 9.5 latido (2026-09-19)
Rojo inicial (limpio): sin el LaunchAgent la prueba muere en `FAIL: falta el
LaunchAgent del latido` (rc=1); con el plist presente pero sin
`corrida/latido.sh` el despachador daria `subcomando desconocido: latido`.
Verde tras implementar latido.sh + plist: `TODO VERDE: test-corrida-latido`.
Lo que la prueba pega: sin corridas abiertas (y con dirs sin registro valido o
cerrados) cero llamadas; primer tick un AVANZA silencioso anotado en
mensajes.jsonl y eventos.jsonl; dos ticks seguidos no duplican; 59 min sin
cambio 0 mensajes y a los 60 uno (mutacion sin latido por hora muere); un
cambio a menos de 15 min del ultimo mensaje no sale (mutacion sin tope);
carril callado 31 min => DETENIDA + system event al vigia con la accion y el
parte; dialogo de 10 min => NECESITO sonora pese al tope y sin duplicar al
tick siguiente (mutacion sin escalamiento muere); dialogo joven sin cobertura
de politica => NECESITO inmediato; vigia hermes deja linea en eventos.jsonl y
cero system event; con el evento al vigia cayendo el mensaje igual sale (y no
se duplica al tick siguiente), y con el envio cayendo el evento igual sale y
mensajes.jsonl anota ok:false honesto.
Mutaciones verificadas muriendo (archivo restaurado tras cada una, con cmp):
sin latido por hora (la rama de los 60 min), sin escalamiento a NECESITO (la
etiqueta deja de ser especial), sin tope de 15 min (todo cambio sale solo).
Incidente propio del diseno, atrapado por la prueba: el NECESITO que bypassaba
el tope bypassaba tambien la deduplicacion por firma y se remandaba cada tick;
ahora solo bypassa el tope cuando la firma cambio (o lleva 15 min sin
contestacion).

## 9.8 CI rojo (2026-09-19)
Rojo inicial (limpio): con el latido de 9.5 corriendo pero sin el chequeo de
CI, `FAIL: CI rojo: salieron 1 mensajes (debia 2: el parte y el aviso)` (rc=1).
Verde tras el chequeo en el tick: `TODO VERDE: test-corrida-latido`.
Lo que la prueba pega: CI de la rama por defecto en fallo => un DETENIDA en
lenguaje de usuario (pasa mensaje_valido, sin shas dentro) y ci-rojo.json en el
directorio de la corrida con sha, autor y archivos; el mismo sha al tick
siguiente => cero mensajes (mutacion sin memoria del sha: un aviso por tick,
muere aqui); CI verde => cero; gh caido => cero avisos de rojo y el latido
sigue lateando (el parte de la corrida sale igual).
Mutacion verificada muriendo (con cmp de restauracion): sin la memoria del sha
avisado, el mismo sha rojo avisa en cada tick y la prueba muere en el caso
"mismo sha => cero".

## Ronda 1 de revision cruzada (2026-09-19)

### MA (bloqueante): gh caido no discriminaba
La seccion de "gh caido" contaba un AVANZA que con GH_CI por defecto verde
nada probaba: ni un estado que con gh vivo SIBA avisado, ni || fail en el tick.
Rework: corrida propia (lat-gh), GH_CI=rojo GH_SHA fijados + GH_CAIDO=1, todo
tick con || fail, y asserts de cero avisos, cero ci-rojo.json y parte AVANZA.
Rojo pegado (mutacion: gh caido tratado como rojo, con el payload fabricado):
`FAIL: con gh caido salio mas que el parte (msgs=2)` (rc=1); restaurado y en
verde. Ademas: todos los tick de la prueba llevan || fail (auditoria grep).

### fix(9.5) no bloqueantes
MI: evento_jsonl colaba EVT_DIR (ruta absoluta) y EVT_AT duplicado en cada
linea (evidencia: lineas con "DIR": "/var/.../lat-her" y "AT" junto a "at");
excluidos del dict. MJ: para hermes la linea de eventos.jsonl ES el aviso; su
escritura ahora decide firma_vigia (caso 9b: eventos.jsonl como directorio,
dos ticks, no se marca enviada). MK: lat_escribir con rc honrado: escritura
caida tras un envio exitoso avisa a stderr y el tick sale rojo (caso 9c).
MD: declarado no-materializado con prueba minima: lib.sh fija TMUX_BIN al
cargarse (command -v tmux con fallback a /opt/homebrew/bin/tmux) y el
despachador carga lib antes que el subcomando; la prueba (0) lo aserta.
ML: confirmado y corregido: este repo es goncloud-openclaw (git remote
get-url origin); el REPO_DIR del plist apuntaba a goncloud-workspace-main
(otro repo: 9.8 hubiera vigilado el CI equivocado). La prueba (0) compara
el origen del plist contra el del repo.

### fix(9.4) no bloqueantes
MB: singulares ("trabaja 1 sesion", "queda 1 hora", "1 minuto") y
"menos de un minuto" para lo recien nacido (casos 1c de la prueba: sesion
unica, hora unica, dialogo de 30 s). MC: approval_since ausente o en 0 ya no
produce la cifra de 29 millones de minutos: escala (edad eterna) y el texto
dice "mucho rato" (caso 1b). ME: dialogo_cubierto casa el patron en la zona
del dialogo (ultimas 5 lineas no vacias), no en salida vieja. Hallazgo 1 de
la seleccion: iso_a_epoch ahora respeta la zona del ISO
(datetime.strptime+timestamp; timegm ignoraba el offset y la ventana salia
descalzada con inicio fuera de UTC). MH: el caso de determinismo tambien
muestra inyectabilidad (reloj +1 h => "3 horas y 58 minutos"); y la nota del
5000/5002 de arriba se corrige: el tope del recorte es 5000 bytes y la prueba
tolera 5002 contando los 2 de sangria. Incidente propio de la ronda: mis
casos nuevos pisaban watch-avanza/paneles-avanza que el caso --solo-mensaje
reusa; ahora usan directorios propios (pan-mb2/wat-mb2, pan-mb3/wat-mb3).

### fix(9.8) no bloqueantes
MM: la consulta filtra por el workflow de calidad (quality.yml); el stub de gh
de la prueba exige ese flag (exit 5 sin el). MN: timed_out y startup_failure
entran al conjunto rojo (caso: GH_CI=timeout avisa y el registro local queda
con el sha nuevo). MO: ci-rojo.json se escribe tras un envio que salio (con
avisado en verdad); envio caido => sin registro mentiroso y reintento al tick
siguiente (caso lat-mo). MP: parseo con separador de unidad (chr 31), un campo
vacio no corre los demas. MQ: los tres gh van con cd && (si el cd falla, no se
consulta al PWD). Mutaciones verificadas muriendo: sin --workflow, solo
failure en el conjunto rojo, y registro escrito aunque el envio cayera.

### Declarado de la ronda (no bloqueantes que no eran de una linea)
- 9.4/2: NECESITO no tiene fixture byte a byte propio en estado (lo cubre la
  prueba de latido con sus greps y validacion); abrir el fixture faltante
  toca diseno de textos, no una linea.
- 9.4/4-5, 7-8: cruce con progress.json y coherencia de mensajes entre
  etiquetas: decisiones del lead sobre la forma del parte, no arreglables
  en una linea sin inventar criterio.
- 9.4/9: la pausa de la ventana no acumula esperas historicas (el vigilante
  no guarda historia); ya declarado en ronda 0.
- 9.4/10: P_FIRMA/P_ACCIONES se ejercitan via latido; la prueba de estado no
  los aserta por su cuenta.
- 9.4/14: panel_limpio deja el detalle del vigia en ASCII plano (igual que
  approval_tail del vigilante); el mensaje a David nunca incluye pantalla.
- 9.4/15: el texto de pantalla se trata como dato: limpio de control y
  truncado antes de entrar al detalle; no se interpreta.
- 9.4/16: el stub de gh de la prueba responde lo pedido; endurecerlo al
  nivel de un gh real es trabajo de prueba, no de producto.
- 9.4/17: los .panel.* temporales de estado se borran en el flujo normal;
  sin trap a mitad de corrida pueden quedar sueltos (sin rm recursivo por
  clausula (a); fuga acotada al directorio de estado de la corrida).
- 9.4/MF: no se pudo verificar con una captura real de glm/muse si la TUI
  antepone vineta a LISTO/ATORADO (no hay capturas a mano aqui); la regex
  actual casa la misma forma que el grep del runbook (^ *(LISTO|ATORADO)).
- 9.4/MG: no hay filtro barato de PRs por corrida (la rama por carril vive
  en el espejo de progreso, no en el registro); el conteo del parte es de
  propuestas abiertas del repo, dicho sin reclamo de pertenencia.
- 9.8/MR: el chequeo de CI vive por corrida: con N corridas abiertas hay N
  consultas y hasta N avisos del mismo sha (memoria por corrida, como pide
  la fila: el registro local es de la corrida). El plan corre una corrida
  a la vez; dedupe global declarado como residual.
- Vigilante: test-tmux-activity-watch.sh es FLAKY bajo carga (reproducido:
  2 de 3 verdes, fallando 2e una vez y 2f otra; carrera del TUI de mentira
  contra la reescritura del archivo de pantalla). Fuera de mi tabla SCOPE:
  declarado, sin tocar. Reintento el commit cuando cae.

## Ronda 2 de revision cruzada (2026-09-19)

### NA (bloqueante): la seccion (0) exigia una ruta de la Mac y revento en CI
Rojo de CI (run 35446921515, textual del BRIEF-r2): `FAIL: el REPO_DIR del
plist (/Users/dn/dev/goncloud-openclaw) no es un clon de este repo: 9.8
vigilaria el CI de otro`. Rework: la relacion plist<->repo se prueba con
fixtures portables — dos `git init` con origin copiado EN CALIENTE del repo
bajo prueba (caso verde) y un origin distinto (caso rojo), plists generados
por sed sobre el real — y el plist real solo se verifica si su REPO_DIR
existe; si no, el caso se salta con el motivo impreso. Rojo de mutacion
(mismo_origin siempre verdadero, que equivale a no mirar el origin):
`FAIL: el REPO_DIR del plist apunta a un repo con otro origin: 9.8
vigilaria el CI de otro` (rc=1); restaurado con cmp. La rama de skip probada
con una ruta inexistente: imprime su motivo y la prueba sigue. El fixture de
git corre con GIT_DIR/GIT_INDEX_FILE unset (leccion del carril N).

### fix(9.5) r2 no bloqueantes
NC: la sonda de TMUX_BIN corre con `unset TMUX_BIN` previo (antes no
discriminaba si la prueba ya lo habia exportado). ND: el grep del stderr de
(9c) exige "no se pudo escribir" (antes "latido.json" casaba con cualquier
traceback que nombrara la ruta). NG: la memoria caida de latido.json tras un
envio exitoso ya no corta el tick: avisa a stderr, sigue con vigia y CI,
anota el evento de mensaje, y el fallo queda en el rc del tick (flag lrc).

### fix(9.4) r2 no bloqueantes
NB: confirmado y arreglado — con approval_since ausente (desde=0) la pausa
de la ventana NO se aplicaba (el guard exigia -gt 0); ahora todo dialogo
pausa, y con inicio desconocido la ventana queda completa (al salir de un
dialogo vuelve a 6 completas, corrida.v1). Caso MC extendido: "(en pausa por
la espera)" y "quedan 6 horas de ventana". NE: la ventana justa no trae "y 0
minutos" ("queda 1 hora de ventana de trabajo"), un resto menor a un minuto
dice "queda menos de un minuto", y el singular "queda 1 minuto" (casos 1d).
NF: min_desde devuelve vacio cuando el hito no se supo y min_en_palabras lo
trata como "mucho rato": sin numeros centinela acoplados.

### Declarado de la ronda 2
- #4: el stub de gh responde el workspace al repo view del fixture; inocuo
  para lo que se aserta (sha, autor y archivos).
- #5: el workflow Quality corre en push a main — confirmado por el lead (la
  corrida 35446921515 es Quality por push sobre main).
- #8: iso offset, ME, MI, MP y MQ sin prueba propia dedicada; cubiertos
  indirectamente por los casos de la bateria.
- #9: tail -5 de la zona de dialogo sin captura real de TUI que lo mida.
- #11: el reintento de hermes no tiene caso propio (el 9b cubre la memoria
  de firma_vigia, no reescribir la linea caida).
- #14: los directorios de (1b)/(1c) se reutilizan entre corridas de la
  prueba; aislados por escenario y sin efecto en los byte a byte.
- #3 cayo con NG atendido; #12 se cierra con NB.

## Ronda 3 de revision cruzada (2026-09-19, cierre)

### RA: el rc del tick tambien en la rama del vigia
La escritura caida de latido.json tras despertar al vigia solo avisaba; ahora
propaga lrc=1 como las otras ramas ("el fallo queda en el rc del tick"
cierto tambien ahi). Caso 9d: memoria crafteada (firma igual y tope vigente
para que el tick no mande mensaje), lead muerto que despierta al vigia, y el
directorio de la corrida en 500 para que la unica escritura posible sea la
que falla. Rojo de mutacion (sin el lrc de la rama del vigia): `FAIL: RA:
con latido.json caido en la rama del vigia el tick salio en verde` (rc=1);
restaurado con cmp.

### Declarado de la ronda 3
- RB: mismo_origin daria verdadero si ambos repos carecieran de origin
  ("" == ""); en la practica este repo tiene origin y el caso rojo usa uno
  explicito.
- RC: el sed de generacion de plists romperia con & o | en la ruta del
  REPO_DIR real; improbable en una ruta local.

## Ronda 4 — veredicto sellado (codex): 9.8 moria en silencio con gh real
Reproduccion del reviewer sobre 630b025: con gh 2.98.0 real,
`gh run list --json headSha,conclusion,status,actor` responde `Unknown JSON
field: "actor"` y sale con error ⇒ out vacio ⇒ el chequeo 9.8 entero se
saltaba sin rastro. Rojo pegado tras hacer el stub fiel al real (rechaza
campos --json desconocidos): `FAIL: CI rojo: salieron 1 mensajes (debia 2:
el parte y el aviso)` (rc=1) — exactamente la omision en silencio.
Arreglo: run list solo con headSha,conclusion,status (verificado contra el
gh real en la VERIFY); el autor sale de la MISMA llamada gh api del commit
(.commit.author.name junto a .files[].filename, cero llamadas extra); y una
consulta de run-list que no responde deja rastro: stderr + linea
tipo gh-fallo en eventos.jsonl (cero mensajes a David sigue vigente: la
DoD de gh caido no cambia). El stub de gh de la prueba queda fiel para
siempre: rechaza campos desconocidos como el real.
