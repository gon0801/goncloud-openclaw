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

## Ronda 5 — CodeRabbit sobre r4 (20:05Z)

### TA (Major): aviso y registro sin metadatos
Rojo pegado (pre-fix, con el stub en GH_API_FALLA=1): `FAIL: TA: con el
commit sin metadatos salio el aviso igual (msgs=2)`. Arreglo: run-list sano
pero commit sin autor o archivos (o sin slug) se trata como fallo de
consulta: stderr + evento gh-fallo (motivo commit sin metadatos), cero
aviso, cero ci-rojo.json y el sha sin marcar. Caso (11): el reintento con
la api sana avisa y el registro trae autor y archivos.

### TB (Major): lci marcado sin registro
ci-rojo.json que no persiste ya no marca el sha: stderr, lrc=1, evento
ci-rojo ok=false; el proximo tick reavisa y reintenta el registro. Caso
(11b): registro como directorio => tick rojo con rastro, reintento reavisa
(msgs 3) y deja el registro. Rojo de mutacion: persistir el sha marcado sin
registro muere con `FAIL: TB: el sha quedo marcado sin registro; no se
reaviso (msgs=2)`. Nota honesta del camino: mi primer intento de mutacion
murio por un error de sintaxis mio (no valia) y el segundo (marcar lci solo
en memoria) resulto inerte — lo que el caso vigila de verdad es la MEMORIA
PERSISTIDA, que es la que cruza ticks.

### TC (Minor): el evento gh-fallo no se comprueba
Las dos llamadas de gh-fallo (consulta y commit sin metadatos) comprueban el
rc de evento_jsonl y dejan "y no se pudo anotar el fallo de gh" en stderr,
sin mensaje a David. Caso (11c): gh caido + eventos.jsonl como directorio =>
el stderr trae el diagnostico de la consulta Y el de la persistencia caida.
Rojo de mutacion (sin la comprobacion): muere con el FAIL de (11c).

---
# (continuación Fase 13 — mismo carril M)

# TDD carril M — evidencia

## 13.5 — convencion de dos copias

### Rojo primero (antes de corregir el .txt)
```
ROJO: (1) docs/crons/verif-digest-20h.md fence != verif-digest-20h.v1.txt: las dos copias divergieron (el aplicador usaria el .txt)
EXIT:1
```
Causa: el .txt aun decia "1 hora adelante de CDMX"; el .md (y el cron vivo) ya tenian la correccion del 2026-09-12 (pedir NY+CDMX al sistema, sin restar).

### Verde despues
```
ok (1): verif-digest-20h.md ↔ verif-digest-20h.v1.txt (fence=txt, id vivo, cierre en linea propia)
ok (1ex): verif-sync-repos en MD_SIN_TXT (sin .txt por ahora)
...
ok (3): mutante de una palabra deja rojo
ok (4): un .txt nuevo sin .md deja rojo
TODO VERDE: crons-dos-copias
```

### Mutantes
- Cambiar una palabra del .txt (PROPOSITO→PROPOSITO_X) → mismo ROJO de (1).
- Agregar `cron-fantasma.v1.txt` sin .md → el chequeo (2) sale rojo.

### Formato de id vivo (elegido por M; runbook §atores)
`Id vivo: \`<uuid>\`.` en el encabezado de ambos `.md`:
- verif-digest-20h → c812d541-bc38-4a5d-9bef-49239a9cee03
- verif-sync-repos → 2d763be5-6390-4ccf-a3a4-621c91c41e94

## 13.2 — (pendiente)

## 13.2 — sync avisa skills

### Rojo primero (antes de las marcas en sync-repos.ps1)
```
ROJO: (0) faltan marcas # >>> skills-cambiadas — la funcion no se puede extraer
EXIT:1
```

### Verde despues
```
ok (0)..ok (6)
TODO VERDE: sync-avisa-skills
TODO VERDE: crons-dos-copias  (verif-sync-repos ya no es excepcion; apareado a v2.txt)
```

### Mutantes
- Llamado SKILLS movido despues del commit → fuera de la ventana de (2).
- Quitar el try/catch del flujo → rojo en (2)/(0).
- Funcion contra repo temporal: solo `s/SKILL.md` (no `otro/no-skill.txt`).
- throw forzado → `SKILLS error:` y el ciclo sigue.

### Aplicador
`APLICAR_VIGIA_SYNC.sh --test` (seco) escribio `.pre.json`/`.post.json` con `payload.message` == v2.txt y agentId/schedule/toolsAllow/enabled intactos. No edito el gateway.

## r1 — el mutante «quitar el llamado» ahora muere

### Antes del arreglo (reproduccion)
Borrar la linea `$skillsSnap = Get-OpenclawSkillsCambiadasStaged -RepoRoot $r` o reemplazarla por `$skillsSnap = $null` dejaba el test en VERDE (rc=0): el chequeo (2) anclaba solo en `SKILLS error:` (el catch), que sobrevivia.

### Mutante A (linea borrada) → ROJO
```
ROJO: (2) falta el llamado Get-OpenclawSkillsCambiadasStaged -RepoRoot $r en el flujo (borrarlo o anularlo a $null debe dejar rojo aqui)
MUT_A_EXIT:1
```

### Mutante B (`$skillsSnap = $null`) → ROJO
```
ROJO: (2) falta el llamado Get-OpenclawSkillsCambiadasStaged -RepoRoot $r en el flujo (borrarlo o anularlo a $null debe dejar rojo aqui)
MUT_B_EXIT:1
```

### Restituido → VERDE
```
ok (2): el llamado Get-OpenclawSkillsCambiadasStaged -RepoRoot $r va entre la guardia y el commit (linea 128)
...
TODO VERDE: sync-avisa-skills
TODO VERDE: crons-dos-copias
```

## r2 — dos huecos del test de dos copias

### Hueco 1 (antes): mutantes no ejercían el chequeo (1)
Con la comparación `[ "$got" = "$want" ]` anulada a `:`, el test seguía VERDE e imprimía «ok (3)».

### Hueco 1 (despues): anular la comparación → ROJO
```
ROJO: (3) mutante: cambiar una palabra del .txt debio hacer fallar el chequeo (1) real y paso
EXIT:1
```

### Hueco 2 (antes): cualquier uuid del .md bastaba
Borrar la linea `Id vivo: …` dejaba VERDE (encontraba el uuid del job en el cuerpo).

### Hueco 2 (despues): sin la linea Id vivo → ROJO
```
ROJO: (1) docs/crons/verif-digest-20h.md no declara su id vivo (falta la linea 'Id vivo: <uuid>')
EXIT:1
```

### Restituido
```
ok (3): mutante de una palabra deja rojo el chequeo (1) real
ok (4): un .txt nuevo sin .md deja rojo el chequeo (2) real
TODO VERDE: crons-dos-copias
TODO VERDE: sync-avisa-skills
```

## r3 — ventana del log, --test D1/D2, y el ? de C

### Hueco 1: tail-80 perdia SKILLS
```
{ echo "<linea SKILLS>"; seq 80; } | tail -80 | grep -c " SKILLS "  → 0
{ echo "<linea SKILLS>"; seq 80; } | tail -400 | grep -c " SKILLS " → 1
```
Arreglo: PASO 1 y PASO 3b usan la misma ventana `tail -400` (declarada: cubre varios ciclos; minimo obligatorio).

### Hueco 3: "?" restaurado
`"Lo reviso ahora? Responde SI y lo veo."` (como el v1).

### Hueco 2: --test declara D1/D2
```
bash docs/cron-messages/APLICAR_VIGIA_SYNC.sh --test  → EXIT 0
recorrido D1/D2 impreso (vigia-sync-prueba-D1/D2, --tools exec, LOG=prueba, SKILLS de 43097da)
SECO: no se crearon jobs. Falta la corrida real en Q2:
  VIGIA_SYNC_EJECUTAR=1 docs/cron-messages/APLICAR_VIGIA_SYNC.sh --test
```

### Tests
```
TODO VERDE: crons-dos-copias
TODO VERDE: sync-avisa-skills
```

## r4 — D1/D2 escriben fixture, aserciones y rm verificado

### Huecos (antes)
1. Solo NOTAs: D2 leia el mismo log que D1.
2. Sin aserciones: exit 0 aunque D1 no nombre verifier.
3. `cron rm` fallido → exit 0.

### Arreglo
- `escribir_log_prueba` via `cron add --command` (cola+SKILLS antes de D1; cola sin SKILLS antes de D2).
- `vigia_sync_prueba_assert.py`: assert-d1 / assert-d2 / assert-rm.
- `rm_y_verificar`: rm + cron list + assert-rm.

### Test en seco (`test-aplicar-vigia-sync-prueba.sh`)
```
ok (1): D1 con verifier+archivos → PASS
ok (2): D1 vacio → FAIL
ok (3): D2 sin aviso D → PASS
ok (4): D2 con aviso D → FAIL
ok (5): rm fallido → FAIL
ok (6): rm OK pero sigue en list → FAIL
ok (7): rm verificado → PASS
ok (8): mutante que acepta D1 vacio queda expuesto
ok (9): el aplicador escribe fixture, aserta resultado y verifica rm
TODO VERDE: aplicar-vigia-sync-prueba
```
Mutante: quitar `escribir_log_prueba 1 D1` → ROJO (9).

### --test seco
EXIT 0; declara escritura de fixture + asserts; no crea jobs (corrida real: VIGIA_SYNC_EJECUTAR=1).

## r5 — aserciones estrictas y franja de silencio

### Repros (antes → ahora EXIT 1)
```
assert-d1 {status:error, … verifier …} → ASSERT_FAIL: run no exitoso (completionStatus=failed)
assert-d2 {} → ASSERT_FAIL: sin entradas
assert-rm … unknown → ASSERT_FAIL: UNKNOWN: no pude leer cron list
```

### Legitimos (EXIT 0)
d1-ok con `VIGIA SYNC SKILLS agentes=verifier n=…`; d2-ok callado; rm absent; rm fallido → 1.

### Franja
`VIGIA_SYNC_EJECUTAR=1 --test` se rehúsa entre 23:00-08:00 CDMX (`en_franja_silencio_cdmx`).

### Test
`TODO VERDE: aplicar-vigia-sync-prueba` (casos 1-12).

## r6 — franja conductual, contrato UNA linea, jobs=[]

### Hueco 1: franja solo por grep
Antes: `grep en_franja_silencio_cdmx` → VERDE aunque `if false; then` anule el guard.
Ahora: copia hermetica bajo scratch; mock dentro → exit≠0 + «franja de silencio»; mock fuera → no bloquea; guard anulado → expuesto.

### Hueco 2: contrato partido con DOTALL
```
assert-d1 summary="VIGIA SYNC SKILLS agentes=verifier\ntexto n=1 skill.md" → EXIT 1
```
`_linea_contrato_d1` exige UNA linea; mutante DOTALL queda expuesto.

### No-bloqueante: jobs=[]
```
list-status {"jobs":[]} → absent   (antes: unknown via `jobs or d`)
list-status sin clave jobs → unknown
```

### VERIFY
```
ok (3b): D1 contrato partido → FAIL
ok (3c): mutante DOTALL …
ok (10b): jobs=[] → absent; mutante jobs-or …
ok (13): franja conductual (in→abort, out→ok); guard anulado queda expuesto
TODO VERDE: aplicar-vigia-sync-prueba
TODO VERDE: crons-dos-copias
TODO VERDE: sync-avisa-skills
bash scripts/run-checks.sh → exit 0
```

## Q2 — aplicador REAL contra el gateway (2026-09-20)

Espera: sleep hasta `02:26:05Z` (fuera de ventana cerrada 01:55–02:25Z; CDMX 20:26, fuera de silencio 23–08).

### 1. Edit vivo
```
bash docs/cron-messages/APLICAR_VIGIA_SYNC.sh → EXIT 0
backup: 2d763be5-…20260920T022705Z-74654.{pre,post}.json
message post == verif-sync-repos.v2.txt (8157 B)
agentId/schedule/toolsAllow/enabled intactos vs pre
```

### 2. D1/D2 (VIGIA_SYNC_EJECUTAR=1 --test)
Intento 1–2: ABORTO `write-job … no corrio` — `cron run` sale ≠0 porque el job de escritura iba con delivery announce→last (fall-closed) aunque el comando escribía el log (stdout `1`).
Arreglo mínimo: `--no-deliver` en `escribir_log_prueba` (igual que D1/D2).
Reintento:
```
fixture D1 OK → D1 id=42ee6ef5… status=ok succeeded 74s → ASSERT_OK assert-d1 + rm absent
fixture D2 OK → D2 id=2f5b83bc… status=ok succeeded 44s → ASSERT_OK assert-d2 + rm absent
PRUEBA D1/D2 terminada VERDE
summary D1: CASO D + linea SKILLS verifier + archivos
summary D2: VIGIA SYNC OK ciclo=… (callado en D)
```

### 3. Re-lectura
`openclaw cron get 2d763be5-…` message == post.json == v2.txt.

### 4. Commits
`fix(13.2): --no-deliver en write-jobs del fixture` + `chore(13.2): respaldo pre/post del vigia v2 aplicado`.
