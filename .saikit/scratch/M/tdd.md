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

---

# TDD — carril M, Fase 16 (rama fase16/runtime-separation)

Contrato: un commit por Task del plan
`docs/superpowers/plans/2026-09-22-openclaw-runtime-separation.md`.
Cada Task corre sus pruebas en ROJO antes de implementar y en VERDE después.
Solo pruebas focalizadas durante desarrollo; la batería completa la consume
el PR en CI. `git diff --check` + hooks antes de cada handoff.

Formas compartidas (un literal, tres dueños; el test lo fija):

- SECRET_KEY_PATTERN:
  `(?i)(password|passwd|secret|token|bearer|apikey|api[_-]?key|private[_-]?key|pairing|passphrase|credential|session[_-]?key|connection[_-]?string|authorization|cookie|transcript|memory[_-]?content|messages)`
- SECRET_VALUE_PATTERN:
  `(?im)(bearer\s+[A-Za-z0-9._~+/-]+=*|sk-[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|xox[bpras]-[A-Za-z0-9-]+|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----|(?-i:^[A-Z][A-Z0-9_]{2,}=[^\s]{4,}))`

Revision 2026-09-22: el bearer del patron de valor exige piso 16
(`bearer\s+[A-Za-z0-9._~+/-]{16,}={0,2}`): el scan de higiene hallo 5
falsos positivos (prosa espanola y fixtures de 1 a 13 caracteres).

Dueños: `docs/spec/runtime-separation-receipt.v1.schema.json` (campos
`x-secretKeyPattern` / `x-secretValuePattern`),
`scripts/runtime-separation/RuntimeSeparation.psm1` (mismo literal),
`scripts/tests/test-runtime-receipt.sh` (los LEE del schema: paridad
estructural, no por grep).

Ayudas OpenClaw 2026.9.5 (ec9c1a1) capturadas de un `npm install` en scratch
ANTES de codificar (contrato de ejecución del plan): `backup`, `memory`,
`node`, `nodes`, `config` + subhelps (`node run --pair` existe,
`node install` NO trae `--pair`, `nodes status --json`, `memory index
--agent/--force`, `memory search --query/--json`, `memory status
--deep/--json`, `backup create --verify/--json/--output`,
`backup restore <archive> --target`, `backup sqlite create/list/verify/restore`,
`config get <path> --json`, `config validate --json`). Salida íntegra en
scratch del implementador; la evidencia versionada nace en la Task 5, que es
la que fija sintaxis exacta de memoria.

## Task 1 (16.1) — Contratos y CI 2026.9.5

ROJO (2026-09-22, antes de implementar):

- `bash scripts/tests/test-runtime-receipt.sh` →
  `ROJO: (0) falta docs/spec/runtime-separation-receipt.v1.schema.json`
- `bash scripts/tests/test-runtime-layout.sh` →
  `ROJO: (0) falta scripts/runtime-separation/RuntimeSeparation.psm1`

Desviaciones declaradas del plan (la DoD manda sobre la lista de archivos):

- `scripts/run-checks.sh`: SIN cambios. Los tests nuevos entran por el glob
  (contrato Fase 15.1: el glob manda, nadie mantiene listas a mano) y el job
  Windows los invoca directo. Un toque cosmético al runner solo sumaría ruido
  al diff.
- `scripts/tests/test-ci-coverage-contract.sh` (chequeo w): el plan no lo
  cita, pero fija con `grep -qF` el `needs:` EXACTO del gate. La DoD exige
  que el gate dependa de `windows-contract`, así que el pin se actualiza al
  needs nuevo y se agregan las aserciones del par windows (misma regla:
  skipped solo con fast válido). Sin este cambio, cumplir la DoD rompería
  la batería: es el patrón de evolución del propio repo (15.2 hizo lo mismo
  con los shards).

## Task 2 (16.2) — Manifiesto, deploy e higiene

Conjunto de retiro (90 archivos, verificado sin fijaciones en tests):
openclaw.json.broken/clobbered (3), live-bus.env, tls/lego-data account.json,
agents/main/sessions/*.zst, 4 launchers + gateway.cmd.bak-pre-livebus,
SKILL.md.bak-20260912, gateway-watchdog.ps1.bak-20260921, 2 arboles
tablero-runbook.bak-* (58), tmp_* (14), doctor-*.log + doctor-fix-run.ps1 (3),
2 respaldos restore-console.*. Quedan: scripts sueltos de raiz no enumerados
(deploy/smoke/fix/gw/merge/verify) y tls/bin (el plan solo enumera lego-data).

Decisiones: deny siempre gana (sin puntajes); lo no igualado por ninguna
lista falla el test como no-clasificado (ahi nace la decision explicita).
`openclaw config validate` no acepta config de staging (sin --config), asi
que valida en vivo tras reemplazar y revierte si falla; staging valida
clasificacion, parseo PS, compuerta httpTimeoutSec y streams ADS.

ROJO (2026-09-22, antes de implementar):

- `bash scripts/tests/test-deploy-manifest.sh` →
  `ROJO: (0) falta config/runtime-deploy.v1.json`
- `bash scripts/tests/test-deploy-atomic.sh` →
  `ROJO: (0) falta scripts/runtime-separation/Invoke-OpenClawDeploy.ps1`
- `bash scripts/tests/test-repository-hygiene.sh` → rojo (basura trackeada)
- `bash scripts/tests/test-gateway-watchdog.sh` → rojo (falta compuerta en modulo)

## Task 3 (16.3) — Sync con capture, ledger y deploy

Contrato gh stub (fijo para los 6 tests): `pr create` anexa
`create head=H` a $GH_LOG y devuelve URL con N incremental; `pr view N`
lee $GH_STATE (JSON numero -> {state, mergedAt, headRefOid}); `pr list
--head` filtra por rama. Todo lo demas sale 99. Ramas
`auto/skills/yyyyMMddTHHmmssZ-agente`. Ciclo sin cambios no escribe
recibo ni ledger (solo lineas de log): "alter no files" estricto.

ROJO (2026-09-22, antes de implementar): los 6 tests nuevos fallan en (0)
y los 3 reorientados fallan en sus anclas nuevas.

## Ronda de corrección (brief 14 hallazgos, 2026-09-22)

Los ciclos TDD de implementacion de Tasks 4-7 no se registraron; lo que
sigue es lo OBSERVADO al endurecer el codigo y los tests de cada Task
en esta ronda (un carril, secuencial, mutante por fix). Commits
d93ea15 (F1-F6), dec4fc7 (F7-F9), ea2cb76 (F10-F11), dbf3584 (F14).

## Task 4 (16.4) — Vigia v3 + aplicador

F11 (doble corrida D4: misma cola + mismo scratch):

- ROJO: `bash scripts/tests/test-aplicar-vigia-sync-prueba.sh` →
  `ROJO: (12) falta run_two (D4 doble corrida)`.
- VERDE tras `run_two` en APLICAR_VIGIA_SYNC.sh: `TODO VERDE`,
  con `ok (14)` (gateway falso con semantica de scratch: UN add D4,
  2 `cron run` al MISMO tid, 1 fixture antes del run1, runs1 avisa +
  runs2 calla) y `ok (15)` (porcelain igual).
- Mutantes muertos: 2da corrida en job fresco → re-avisa →
  `D4 ASSERT-2 FALLO` (expuesto DENTRO de (14)); asserts D4
  invertidos → `ROJO: (12) D4 aserta en orden distinto`.

F14 (hermeticidad): redirects de las copias (13)/(14) a $T
(backup, evidence, scratch) + check (15) de porcelain.
Mutantes muertos: sin redirects → (14) `sin evidencia runs1+runs2`;
archivo suelto en repo → `ROJO: (15) el worktree cambio`.
Limpieza: 40+ respaldos `backup/2d763be5-*` y evidencias
`vigia-sync-prueba-*` fuera del arbol. `decisions.tsv` es scratch
del lead (01:43, sin escritor en el repo), no salida del test:
se deja y se reporta.

## Task 5 (16.5) — Backup, memoria Ollama, rollback

F3 (rollback confinado + hashes + reparse):

- ROJO: `ROJO: (1) falta ancla: snapshotHash`; con bypass de anclas,
  (3b) muere en `KeyError: 'snapshotHash'`.
- VERDE: `TODO VERDE: memory-migration` con (3k) db-fuera-de-runtime,
  (4h/a-g) registro manipulado (escape db/snapshot, duplicado, campo
  extra, reparse x2), (4h/c) snapshot-distinto → diagnostico, y liga
  migration↔recibo por sha256.
- Mutantes muertos: rollback sin confinamiento db → (4h/a)
  `db escape debio frenar y salio 0`; sin check snapshotHash →
  (4h/c) `restauro con snapshot distinto`; sin reparse db →
  (4h/f); migrate sin confinamiento → (3k).
- Decision: snapshot-distinto va a diagnostico (paralelo a
  escrituras→diagnostico); escape/reparse/duplicado/campo-extra
  frenan en seco. Fixtures de DBs bajo `$T/rt/dbs` para que el
  flujo legitimo pase el confinamiento.

## Task 6 (16.6) — Nodo aislado + cuarentena

F8 (approvals antes del pairing):

- ROJO: `ROJO: (2b) pairing arranco antes de approvals set`.
- VERDE tras reorder (identity → approvals set+readback → pair →
  approve ligado al deviceId): `TODO VERDE: node-isolation` con
  (2g) approve-ajeno.
- Mutantes muertos: orden viejo (pair antes) → (2b); sin ligue
  approve==deviceId → (2g) `approve ajeno debio frenar y salio 0`.

F1+F2 (restore + recovery de cuarentena):

- ROJO: `ROJO: (1) falta ancla: recovery.jsonl`; conductual en
  codigo viejo (bypass de anclas): `ROJO: (2h/a) escape debio
  frenar y salio 0` (movia un archivo fuera de la raiz).
- VERDE: `TODO VERDE: quarantine` con (2h/a-f) inventario
  manipulado sin mover nada, (2i) linea recovery con fsync que
  sobrevive `kill -9` antes del primer movimiento, (2j)
  recovery==inventario, y liga inventario↔recibo por sha256.
- Mutantes muertos: sin containment → (2h/a); sin linea recovery
  → (2i); sin dup-check → (2h/b) `movio con duplicados`; sin
  fase de validacion total → (2f) `restore ocupado debio frenar`.
- Incidentes atrapados por las pruebas: ConvertFrom-Json convierte
  `movedUtc` a datetime (check contra texto crudo, estilo del
  modulo); `rollback.artifact` nulo en fallos invalidaba el recibo
  y enmascaraba el error real (init temprano por rama); `wc -l`
  rellena con espacios en macOS (conteo con `grep -c`).

## Task 7 (16.7/16.8) — Cutover, runbook, watchdog

F6 (prefijos exactos de la maquina de estados):

- ROJO en codigo viejo: `(2j/matrix) status=IN_PROGRESS esperaba
  False, obtuvo True` (aceptaba `["payload"]`).
- VERDE: `TODO VERDE: cutover-transaction` con matriz (2j) de 10
  casos (7 rechazos + 3 aceptaciones).

F7+F9 (runbook §3/§4/§5/§7 + test-cutover-runbook.sh nuevo):

- ROJO: `ROJO: (1) §4 no cambia la accion (/tr) al checkout dedicado`.
- VERDE: `TODO VERDE: cutover-runbook` (accion→read-back→enable,
  ausencia de .git tras mover, -LauncherPaths, -NodeConfigSets +
  -PairingCode, sin pairing manual).
- Mutantes muertos: enable-antes-de-accion → (1); backup sin
  -LauncherPaths → (3). (2) y (4) cubren regresiones que el doc
  original traia (ausencia exigida en §4, pairing manual en §7).

F10 (stand-down real del watchdog):

- ROJO: `FAIL: (t4) sin stand-down con lease vigente` (sin seams,
  la ruta `C:\...` no existe fuera de prod).
- VERDE tras seams env (defaults prod intactos): `PASS
  test-gateway-watchdog` con (t4) lease→stand-down (generacion en
  log, sin sonda), vacio/ausente→procede.
- Mutante muerto: `-ne` por `-eq` en la condicion →
  `FAIL: (t4) sin stand-down con lease vigente`.

## Deploy (Task 2, revision en esta ronda)

F4 (validar en staging antes de publicar): regresion (4b) que deja
runtime byte por byte intacto si la validacion falla.
F5 (journal antes del replace): intencion registrada antes de cada
movimiento + fault injection `OPENCLAW_DEPLOY_FAULT=readback|journal`
(solo tests). Mutante muerto (orden viejo: published antes del
journal): `ROJO: (5b/readback) rollback incompleto: runtime difiere`.
Verde: `TODO VERDE: deploy-atomic`.

## CI rondas 2-4 (paridad 5.1/PS7, post-brief)

F15 (fixture hermetico a init.defaultBranch): ROJO solo en CI
(`(1a) ciclo verde debio salir 0`, 3x `ambiguous argument 'HEAD'`);
en Mac pasaba por `init.defaultBranch=main` global. Repro local:
`HOME=/tmp/fakehome` → mismo ROJO. VERDE con `git init -b main
--bare` en semillas (`TODO VERDE: sync-four-repos` con HOME vacio).

F16 (fechas JSON en 5.1): ROJO solo en windows-contract
(`SMOKE-FAIL: receipt-good`, CI2). Causa: 5.1
(JavaScriptSerializer) deja ISO8601 como [string]; PS7 (Newtonsoft)
lo convierte a [datetime]; el validador exigia [datetime].
Intento fallido documentado: `-Depth 32` en ConvertFrom-Json (CI3:
`NamedParameterNotFound 'Depth'` — 5.1 no tiene ese parametro;
revertido). VERDE con `Test-JsonInstant` ([datetime] o [string] con
forma estricta) en receipt/lease/state + normalizacion en
comparaciones de orden y heartbeat del cutover (803/829).
Mutantes: instant-mismatch/instant-badshape en el humo (26/26).

F17 (Import-Module con ruta relativa en 5.1): CI4 desbloqueo layout
(receipt-good verde en 5.1: hipotesis DateTime confirmada) y cayo en
test-deploy-manifest (5): `cygpath -w` de ruta relativa deja `scripts\...`
sin unidad y 5.1 no la resuelve. Mismo latente en deploy-atomic (7)(8) y
protected-paths (barrido: los demas Import-Module ya eran absolutos).
VERDE local (no-op fuera de Windows): manifest, atomic, protected-paths.
Nota: test-corrida-nucleo fallo en CI4 shard-1 (TUI/tmux, 140s) sin
relacion de codigo con este diff (grep vacio), verde en CI3 y en Mac:
se clasifica flaky pendiente de re-evaluacion en CI5.

F18 (CRLF de powershell.exe vs LF del espejo): CI5 (5) reporto
`desacuerdo ... espejo=deployable modulo=deployable`: veredictos
identicos salvo el CR que 5.1 emite por stdout redirigido. Fix:
`tr -d '\r'` a got.txt antes de comparar (no-op en PS7/Linux).
Barrido: unico sitio que compara texto PS exacto contra espejo.

F19 (deploy-atomic (3) en Windows, diagnostico): CI6 `app.txt no se
publico` con Apply=0. El readback del deploy (Test-HashEqual) garantiza
bytes correctos donde el escribe, asi que el fail ciego no discrimina
contenido-vs-ruta. Se agrego got visible (od -c) a los 3 asserts de (3);
el veredicto de CI7 dira si es skip silencioso (rel corrupto), CR
fantasma u otra cosa. Nota: shard-2 cayo en test-tmux-activity-watch
(2h-bis) con diff CI5->CI6 vacio en esa area: segundo flaky tmux
seguido (tras corrida-nucleo CI4), se re-evalua en CI7.

F20 (arbol fantasma RUNNER~1, causa raiz de F19): CI10 mostro
natSrc shortname con nrec=0 y Apply=0: TEMP trae shortname, 8.3
deshabilitado, cygpath -w lo propaga y PowerShell crea RUNNER~1
literal. El deploy opero 100% en el fantasma (exit 0) y el test miro
el arbol real (v1-app intacto). Fix: TMPDIR bajo el workspace (D:, sin
shortnames) a nivel job en windows-contract + step mkdir. Nota: en
Windows-dev con TEMP similar haria falta lo mismo (sin evidencia; no
se toca nat()).

F21 (stderr nativo + EAP=Stop en 5.1): CI11 source-checkout (2a):
`git fetch` escribe `From ...` a stderr y 5.1 lo convierte en
NativeCommandError terminante (en PS7 no). Fix: `2>$null` donde el
output se descarta y manda el exit: Sync fetch/checkout, Backup bundle
create/verify (git escribe `Enumerating ...`). sync-repos.ps1 no pone
Stop (Continue: a salvo). Lo demas (schtasks/icacls/openclaw en exito
no emiten stderr; try/catch atrapa) se deja con evidencia ausente.

F22 (2-null no basta en 5.1): CI12 mostro que `2>$null` NO evita el
NativeCommandError con EAP=Stop: el throw sale igual. Fix real: EAP
temporal a Continue alrededor de git nativo con output descartado
(Sync fetch/checkout/fetch-branch/worktree, Backup bundle x2). En PS7
es no-op (ya era el efectivo). Lo output-usado (ls-remote, rev-parse,
status) se deja: sin evidencia de stderr-informativo.

F23 (HEAD huerfano, segunda instancia): CI13 avisa-skills (2):
`rev-parse HEAD` fatal en clon de bare sin -b (en PS7 tolerado por
accidente, en 5.1 throw). Fix: `-b <rama>` en los 8 `init --bare`
restantes (7x main, pull-identity a master: ese pushea master).
Verdes con HOME vacio (hermeticos): los 8.

F24 (autocrlf + EAP=Stop en 5.1): CI14 avisa (2): `git add` avisa
`LF will be replaced by CRLF` a stderr (core.autocrlf del runner) y
5.1 lo convierte en throw. Fix: EAP temporal en add/commit/push del
capture (misma familia F22). Aplica tambien a prod Windows-live.

F25 (array envuelto @() en 5.1): CI16 backup (2b) con manifiesto
perfecto: DIAG CI17 mostro `$agents[0].agentId` = Object[]: en 5.1
`@(...|ConvertFrom-Json)` envuelve el array top-level ([[A,B]]); en PS7
desenvuelve. Fix: parseo a escalar + foreach aplanar (identico en ambos,
vacio==0 preservado) en Backup agents, Memory agents, Node rawPend/rawSt
y Sync found. Los `@($x.prop)` sobre variable no envuelven (diag: OK).

F26 (stderr schtasks + EAP=Stop en 5.1): CI18 node (2b): el verify tras
`delete` espera exit!=0, pero el `ERROR:` del stub a stderr lanza en 5.1
antes del chequeo. Fix: EAP temporal en los 3 `schtasks /query`
(dup, verify-borrado, oficial). delete/run/icacls en exito no emiten
stderr: se dejan.

F27 (gateway HTTP con error = vivo, F1): backup (2g2) y memoria (3i2) en
ROJO antes del fix (401 salia 0 y respaldaba/migraba). Fix:
Get-HttpErrorStatus (StatusCode 5.1/7 + fallback textual solo 4xx/5xx,
los octetos de IP son 1xx) y Test-GatewayUp: respuesta HTTP = vivo,
solo conexion rechazada acredita apagado, indeterminado falla cerrado.
Mutante muerto en el camino: segunda senal por proceso openclaw* rompio
los verdes (2b)/(3b) en dev porque OpenClaw.app vive en la Mac; el nombre
de proceso no identifica el endpoint, se quito con comentario. Verdes
tras el fix: test-runtime-backup.sh y test-memory-migration.sh completos.

F28 (bookmark del Event Log sin usar, F2): memoria (3j2) en ROJO antes
del fix (evento 99/bookmark 100 fallaba: la consulta no filtraba). Fix:
bookmark exige exit 0 + EventRecordID (si no, aborta) y la consulta final
filtra EventID 3033/3077 con EventRecordID > bookmark, con exit check de
wevtutil (EAP temporal, idioma F22/F26). Stub wevtutil ahora filtra en
servidor por el umbral de la consulta (sin umbral devuelve todo: eso da
el rojo conductual) y (3j3) inspecciona que la consulta trae
"EventRecordID > 100". (3j4)/(3j5) cubren wevtutil caido y bookmark
invalido. Verde: test-memory-migration.sh completo.

F29 (schtasks /query falla abierto, F3): cutover (3g2) y nodo (2f2) en
ROJO antes del fix (denegado salia 0 y creaba/daba por ausente). Fix:
Get-SchtaskQuery central en RuntimeSeparation.psm1 (+export): present /
absent (solo texto no-encontrado en-US + es + 0x80070002) / unknown;
cutover Test-CutoverTaskExists lanza ante unknown (dispatch lo prefija y
sale 1) y nodo aborta en duplicada indeterminada y en post-borrado no
acreditado. Nota: schtasks CLI no da "no existe" estructurado (mismo
exit), por eso el match bilingue con unknown cerrado. (3g2) incluye
anti-mutante es-absent (procede). Presente/ausente-confirmado ya los
cubrian (3a)/(3f) y (2b)/(2f). Mutante muerto en el camino: $ver pisaba
la version del recibo en nodo (2b recibo invalido); renombrado a $dupVer.
Verdes: test-runtime-cutover-transaction.sh y test-node-isolation.sh.

F30 (cuarentena pierde el recibo en fallos tempranos, F4): (2g2) en ROJO
antes del fix (version vieja moria en "recibo invalido" sin causa ni
recibo: $rbArtifact sin init llegaba $null al rollback). Fix:
$rbArtifact='none' antes del try y Write-ReceiptAtomic envuelto para que
no oculte el error original (en verde sigue lanzando). La prueba exige
causa impresa, exactamente un recibo result=failed con artifact=none
validado contra el esquema via Test-ReceiptObject, y sin movimientos.
Verde: test-quarantine.sh completo.

F31 (menor runbook PSValue, M1): (5) en ROJO antes del fix; runbook
ahora usa $PSVersionTable.PSVersion.ToString() con ancla positiva y
negativa en test-cutover-runbook.sh. Verde.

F32 (menor Test-JsonInstant, M2): humo instant-impossible en ROJO antes
del fix (lanzaba FormatException en vez de $false). Fix: Parse con
cultura invariante + RoundtripKind envuelto en try (imposible -> $false)
y guardas en los casts startedAt/endedAt de Test-ReceiptObject
(veredicto, no throw: contrato del modulo). Humo 28/28 en verde.

F33 (menor subn ventana cerrada, M3): los dos make_copy ahora exigen
exactamente 1 reemplazo con diagnostico (SystemExit con nombre y conteo).
Fuente real da n=1 (test verde); sonda negativa con texto sin loop da
n=0 y aborta con el diagnostico. Verde:
test-aplicar-vigia-sync-prueba.sh completo.

F34 (menor watchdog pwsh obligatoria, M4): verificado, sin cambio:
test-gateway-watchdog.sh falla sin pwsh en PATH (t4) y no trae ningun
SKIP; no se anadio skip.

F35 (registro CodeIntegrity/Operational, revision post-CI25):
Set-OpenClawMemory consultaba 3033/3077 en Application, donde esos
eventos nunca caen: un bloqueo nuevo pasaba inadvertido. ROJO con
stub consciente del registro: `ROJO: (3j) eventos nuevos debio
frenar y salio 0`. Fix: `$evLog` unico con
Microsoft-Windows-CodeIntegrity/Operational usado en bookmark y
consulta final. (3j3) exige ademas ambas consultas al registro
correcto y cero `qe Application`. Verde:
test-memory-migration.sh completo.
